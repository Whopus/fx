import AppKit
import Foundation
@testable import Fx

/// Shared by XCTest and the offline command-line runner. All I/O stays inside
/// the supplied temporary directory; no app launch, credentials, or network.
@MainActor
enum EngineeringChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }

    static func run(in root: URL) async throws {
        try checkItemTypeCounts()
        try checkGlassPlacement()
        try checkGlassNavigation()
        try checkContextCompression()
        try await checkContextAndPreparation(in: root.appendingPathComponent("context"))
        try checkBuiltinReloads(in: root.appendingPathComponent("builtins"))
        try checkGallery(in: root.appendingPathComponent("gallery"))
        try await checkImportReentrancy(in: root.appendingPathComponent("imports"))
        try await checkArtifacts(in: root.appendingPathComponent("artifacts"))
        try await checkCancelledRun(in: root)
        if ProcessInfo.processInfo.environment["FX_RUNTIME_PATH"]?.hasSuffix("/runtime-smoke.mjs") == true {
            try await checkRuntimeProcess(in: root)
        }
        print("PASS: context bytes, selective preparation, gallery invalidation, media ownership, artifact scans, cancellation")
    }

    private static func checkItemTypeCounts() throws {
        var records: [CaptureRecord] = []
        for space in CaptureSpace.allCases {
            for _ in 0..<2 {
                records.append(CaptureRecord(id: UUID(), kind: .text, title: "Fixture",
                    createdAt: Date(timeIntervalSince1970: 0), isSaved: true, isTrashed: false, space: space))
            }
        }
        var legacy = records[0]
        legacy.space = nil
        records.append(legacy)
        var trashed = records[0]
        trashed.isTrashed = true
        records.append(trashed)
        let counts = ItemTypeMenu.counts(in: records)
        for space in CaptureSpace.allCases {
            let expected = records.filter { !$0.isTrashed && ($0.space ?? .context) == space }.count
            try require(counts[space, default: 0] == expected, "Item Types menu changed type counts")
        }
        try require(ItemTypeMenu.counts(in: [])[.context, default: 0] == 0, "Empty menu count changed")

        // The native menu rows must mirror the counts and mark the current
        // selection, since AppKit draws the checkmark and badge from these.
        let options = ItemTypeMenu.options(selection: .query, records: records)
        try require(options.map(\.space) == CaptureSpace.allCases, "Native menu lost or reordered item types")
        try require(options.filter(\.selected).map(\.space) == [.query], "Native menu selected the wrong type")
        for option in options {
            try require(option.title == option.space.displayName && !option.icon.isEmpty,
                        "Native menu row lost its title or icon")
            try require(option.count == counts[option.space, default: 0], "Native menu row count diverged")
        }
        print("PASS: item type counts, legacy context classification, and trash exclusion")
    }

    private static func checkGlassPlacement() throws {
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 316, height: 462)
        let below = GlassMenuLayout(anchor: CGRect(x: -750, y: 820, width: 100, height: 36), size: size, bounds: screen)
        try require(below.opensBelow && screen.contains(below.frame), "Glass placement below anchor changed")
        let above = GlassMenuLayout(anchor: CGRect(x: -750, y: 30, width: 100, height: 36), size: size, bounds: screen)
        try require(!above.opensBelow && screen.contains(above.frame), "Glass placement above anchor changed")
        for x in [-1440.0, -50.0] {
            let edge = GlassMenuLayout(anchor: CGRect(x: x, y: 820, width: 100, height: 36), size: size, bounds: screen)
            try require(screen.insetBy(dx: 8, dy: 8).contains(edge.frame), "Glass escaped a screen edge")
        }
        let compactBounds = CGRect(x: 0, y: 0, width: 840, height: 420)
        let compact = GlassMenuLayout(anchor: CGRect(x: 710, y: 360, width: 110, height: 36), size: size, bounds: compactBounds)
        try require(compactBounds.contains(compact.frame) && compact.frame.height < size.height,
                    "Small windows must scroll instead of clipping menu options")
        let narrowBounds = CGRect(x: 0, y: 0, width: 220, height: 600)
        let narrow = GlassMenuLayout(anchor: CGRect(x: 155, y: 550, width: 40, height: 30), size: size, bounds: narrowBounds)
        try require(narrowBounds.insetBy(dx: 8, dy: 8).contains(narrow.frame), "Wide menus escaped narrow windows")
        let longMenu = GlassMenuLayout(anchor: CGRect(x: 600, y: 760, width: 120, height: 28),
            size: CGSize(width: 238, height: 2_000), bounds: CGRect(x: 0, y: 0, width: 840, height: 840))
        try require(longMenu.frame.height <= 744 && longMenu.opensBelow, "Long model lists must fit and scroll")
        print("PASS: glass placement, screen edges, and negative monitor coordinates")
    }

    private static func checkGlassNavigation() throws {
        var invoked: [String] = []
        let entries = [
            GlassMenuEntry.heading("Types"),
            GlassMenuEntry(id: "disabled", title: "Disabled", enabled: false) { invoked.append("disabled") },
            GlassMenuEntry(id: "first", title: "First") { invoked.append("first") },
            .separator(),
            GlassMenuEntry(id: "selected", title: "Selected", selected: true) { invoked.append("selected") },
            GlassMenuEntry(id: "submenu", title: "Reasoning", disclosure: true, keepsOpen: true) { invoked.append("submenu") }
        ]
        var navigation = GlassMenuNavigation()
        try require(navigation.activation(in: entries)?.id == "selected", "Default activation lost current selection")
        navigation.move(by: 1, in: entries)
        try require(navigation.highlighted == "submenu" && navigation.scrollTarget == "submenu", "Arrow navigation did not start at selected row")
        try require(navigation.activation(in: entries)?.keepsOpen == true, "Reasoning submenu must stay open")
        navigation.move(by: 1, in: entries)
        try require(navigation.highlighted == "first", "Navigation did not wrap or skipped enabled row")
        navigation.move(by: -1, in: entries)
        try require(navigation.highlighted == "submenu", "Reverse navigation did not wrap")
        navigation.highlighted = "disabled"
        navigation.activation(in: entries)?.action()
        try require(invoked == ["selected"], "Disabled rows can be activated")
        let unavailable = entries.filter { $0.kind != .action || !$0.enabled }
        navigation.move(by: 1, in: unavailable)
        try require(navigation.highlighted == nil && navigation.activation(in: unavailable) == nil, "Empty/disabled menus have an active action")
        print("PASS: shared glass navigation, disabled items, and submenu actions")
    }

    private static func checkContextCompression() throws {
        let outputRun = ContextRunResult(
            status: "completed", final: "A long answer",
            messages: [.string("large transcript")], events: [],
            startedAt: Date(timeIntervalSince1970: 1), endedAt: Date(timeIntervalSince1970: 2)
        )
        let notebook = ContextNotebook(
            title: "Compression fixture", model: "", reasoning: .low,
            items: [
                ContextNotebookItem(kind: .system, title: "System", body: "Keep all important constraints"),
                ContextNotebookItem(kind: .context, title: "Obsolete", body: "Repeated content"),
                ContextNotebookItem(kind: .output, title: "Output", body: "A long answer", run: outputRun)
            ]
        )
        let originals = ContextCompression.sections(from: notebook)
        try require(originals.map(\.kind) == [.system, .context], "Compression included other section types")
        var proposed = originals
        proposed[0].body = "Keep constraints"
        proposed[1].title = ""
        proposed[1].detail = ""
        proposed[1].body = ""
        let encoded = try JSONEncoder.fx.encode(proposed)
        let response = "```json\n{\"sections\":\(String(decoding: encoded, as: UTF8.self))}\n```"
        let decoded = try ContextCompression.decode(response, matching: originals)
        try require(decoded == proposed, "Compression JSON did not preserve section order and identity")
        let applied = try ContextCompression.applying(decoded, to: notebook)
        try require(applied.items.count == 2, "An empty compressed section was not deleted")
        try require(applied.items[0].id == notebook.items[0].id, "Compression changed a retained section identity")
        try require(applied.items[1] == notebook.items[2], "Compression changed output or its continuation transcript")
        var mismatched = proposed
        mismatched.swapAt(0, 1)
        var rejectedMismatch = false
        do { _ = try ContextCompression.applying(mismatched, to: notebook) }
        catch { rejectedMismatch = true }
        try require(rejectedMismatch, "Compression accepted reordered sections")
        var rejectedMissingQuery = false
        do { _ = try ContextCompression.requestNotebook(for: notebook) }
        catch ContextCompressionError.noQuery { rejectedMissingQuery = true }
        try require(rejectedMissingQuery, "Compression ran without a Query to guide relevance")

        let currentQuery = ContextNotebookItem(
            kind: .query, title: "Current task", body: "Keep only the deployment context",
            attachments: [ContextNotebookAttachment(
                name: "task.png", mediaType: "image/png", data: Data([1, 2, 3])
            )]
        )
        var withQuery = notebook
        withQuery.items += [
            ContextNotebookItem(kind: .query, body: "Previous unrelated task"),
            currentQuery,
            ContextNotebookItem(kind: .query, body: "  ")
        ]
        let request = try ContextCompression.requestNotebook(for: withQuery)
        struct CompressionRequest: Decodable {
            let currentQuery: ContextCompressionSection
            let sections: [ContextCompressionSection]
        }
        let requestBody = request.items[1].body
        let jsonStart = requestBody.firstIndex(of: "{")!
        let input = try JSONDecoder.fx.decode(
            CompressionRequest.self, from: Data(requestBody[jsonStart...].utf8)
        )
        try require(input.currentQuery == ContextCompressionSection(item: currentQuery), "Compression did not use the latest runnable Query")
        try require(input.sections == originals, "Query guidance changed the compression scope")
        try require(request.items[1].attachments == currentQuery.attachments, "Compression lost Query images")
        let appliedWithQuery = try ContextCompression.applying(decoded, to: withQuery)
        try require(Array(appliedWithQuery.items.suffix(3)) == Array(withQuery.items.suffix(3)), "Compression modified Query cells")
        print("PASS: system/context compression scope, identity, deletion, parsing, and output preservation")
    }

    private static func checkBuiltinReloads(in root: URL) throws {
        let store = CaptureStore(rootURL: root)
        let collectionID = store.selectedCollectionID!

        // Legacy installers wrote builtin Tool cards into every collection, and
        // an older one duplicated them. The one-time purge must trash exactly
        // those cards and leave user-authored Tool cards alone.
        let legacy = try store.saveAgentItem(space: .tool, title: "read", detail: "Legacy", body: "Legacy")
        try store.updateDetails(
            for: legacy.id,
            title: "read",
            tags: ["tool", "builtin", "builtin:tool:read"],
            description: "Legacy"
        )
        let userTool = try store.saveAgentItem(space: .tool, title: "my_tool", detail: "User", body: "User")
        try store.updateDetails(for: userTool.id, title: "my_tool", tags: ["tool"], description: "User")
        store.selectCollection(collectionID)

        try store.purgeLegacyBuiltinToolCardsIfNeeded()
        try require(store.records.first { $0.id == legacy.id } == nil, "Legacy builtin Tool card survived the purge")
        try require(store.records.first { $0.id == userTool.id } != nil, "The purge removed a user-authored Tool card")

        // The migration marks itself complete, so a second pass is a no-op.
        let later = try store.saveAgentItem(space: .tool, title: "edit", detail: "Legacy", body: "Legacy")
        try store.updateDetails(
            for: later.id,
            title: "edit",
            tags: ["tool", "builtin", "builtin:tool:edit"],
            description: "Legacy"
        )
        try store.purgeLegacyBuiltinToolCardsIfNeeded()
        try require(store.records.first { $0.id == later.id } != nil, "The purge migration ran twice")

        let promptURL = root.appendingPathComponent("prompt.md")
        try "System instructions".write(to: promptURL, atomically: true, encoding: .utf8)
        try require(try store.installSodaSystemPromptIfNeeded(sourceURL: promptURL) != nil, "System prompt did not install")
        try require(try store.installSodaSystemPromptIfNeeded(sourceURL: promptURL) == nil, "System prompt installed twice")

        let contextsURL = root.appendingPathComponent("contexts.json")
        let definitions = [["platformID": "test", "title": "Test", "description": "Schema", "content": "Endpoint definition"]]
        try JSONSerialization.data(withJSONObject: definitions).write(to: contextsURL)
        let contexts = try store.installJustOneAPIContextsIfNeeded(sourceURL: contextsURL)
        try require(contexts.count == 1 && contexts[0].space == .context, "Platform context did not install")
        try require(try store.installJustOneAPIContextsIfNeeded(sourceURL: contextsURL).isEmpty, "Platform context installed twice")
    }

    private static func checkContextAndPreparation(in root: URL) async throws {
        let store = CaptureStore(rootURL: root)
        let record = try store.saveText("Original body", sourceURL: "https://example.com")
        try store.updateDetails(for: record.id, title: "  Title  ", tags: ["alpha", " 中文 "], description: " Detail ")
        let tab = try store.addDetailTab(for: record.id, title: "Notes", kind: .markdown)
        try store.saveContent("# Note\n", for: tab.id, in: record.id)
        let current = store.records[0]
        let expected = "Title: Title\n\nTags: alpha, 中文\n\nDescription:\nDetail\n\nContent:\nOriginal body\n\nSource: https://example.com\n\n[Notes]:\n# Note\n"
        try require(store.context(for: current) == expected, "Context formatting changed")
        let detail = try await store.textSource(for: current).loadDetail()
        try require(detail.original == "Original body" && detail.context == expected, "Detail context disagrees with copy context")
        let contentURL = store.fileURL(for: current)!
        try "External edit".write(to: contentURL, atomically: true, encoding: .utf8)
        try require(store.context(for: current).contains("Content:\nExternal edit"), "External file edits are stale")
        try "".write(to: contentURL, atomically: true, encoding: .utf8)
        try require(store.originalTextContent(for: current) == "Original body", "Empty-file fallback changed")

        var builtin = current
        builtin.tags = ["builtin:context:platform-search:test"]
        let source = CaptureTextSource(record: builtin, originalURL: contentURL, tabURLs: [:])
        try require(source.context() == "Title — Detail\nOriginal body", "Builtin context formatting changed")
        for kind in [CaptureRecord.Kind.link, .image, .browserSnapshot, .video] {
            var media = current
            media.kind = kind
            let source = CaptureTextSource(record: media, originalURL: contentURL, tabURLs: [:])
            let detail = try await source.loadDetail()
            try require(detail.context == source.context(), "Media detail context disagrees for \(kind)")
        }

        let unused = try store.saveText("Must not enter this run")
        var notebook = ContextNotebook.fresh(title: "Check")
        notebook.items = [
            ContextNotebookItem(kind: .context, sourceRecordID: record.id),
            ContextNotebookItem(kind: .query, body: "Question")
        ]
        let preparation = store.prepareRuntime(notebook: notebook, workingDirectoryURL: root, sessionID: nil)
        try require(preparation.textSources.map(\.record.id) == [record.id], "Unreferenced records enter runtime preparation")
        let payload = try await preparation.load()
        try require(payload.contexts[record.id] == expected && payload.contexts[unused.id] == nil, "Runtime context differs")
        let baseline = ContextRuntimePayload(notebook: notebook, collectionURL: root,
            contexts: Dictionary(store.records.map { ($0.id, store.context(for: $0)) }, uniquingKeysWith: { first, _ in first }),
            mediaURLs: [:])
        let queryID = notebook.items.last!.id
        try require(try ContextPiRunner.makeRuntimeNotebook(payload, queryID: queryID)
            == ContextPiRunner.makeRuntimeNotebook(baseline, queryID: queryID), "Selective preparation changed runtime JSON")
        notebook.items[0].body = "Frozen preview"
        let frozen = store.prepareRuntime(notebook: notebook, workingDirectoryURL: root, sessionID: nil)
        try require(frozen.textSources.isEmpty, "Frozen context still reads live files")
        let cancelled = Task { try await preparation.load() }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw Failure(description: "Cancelled preparation completed")
        } catch is CancellationError {}
    }

    private static func checkGallery(in root: URL) throws {
        let store = CaptureStore(rootURL: root)
        let originalCollection = store.selectedCollectionID!
        for index in 0..<200 { _ = try store.saveText("Gallery item \(index)") }
        let first = store.gallerySnapshot(in: .context)
        let second = store.gallerySnapshot(in: .context)
        try require(first.items.count == 200, "Gallery lost items")
        let reused = first.items.withUnsafeBufferPointer { a in
            second.items.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress }
        }
        try require(reused, "Unchanged gallery remapped its items")
        let id = store.records[0].id
        store.update(id) { $0.title = "Changed"; $0.coverFileName = "cover.png"; $0.coverKind = .image }
        let updated = store.gallerySnapshot(in: .context)
        try require(updated.items[0].title == "Changed" && updated.items[0].imageURL != nil, "Gallery cache missed metadata change")
        store.update(id) { $0.space = .query }
        try require(store.gallerySnapshot(in: .context).items.count == 199, "Gallery cache missed type change")
        try require(store.gallerySnapshot(in: .query).items.map(\.id) == [id], "Query gallery identity changed")
        store.update(id) { $0.isTrashed = true }
        try require(store.gallerySnapshot(in: .query).items.isEmpty, "Trashed item remained visible")
        let other = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        _ = try store.addCollection(at: other)
        try require(store.gallerySnapshot(in: .context).items.isEmpty, "Previous collection leaked into new gallery")
        store.selectCollection(originalCollection)
        try require(store.gallerySnapshot(in: .context).items.count == 199, "Collection reload lost content")

        let clock = ContinuousClock()
        var consumed = 0
        let mappingTime = clock.measure {
            for _ in 0..<100 {
                let items = store.records.filter { !$0.isTrashed && ($0.space ?? .context) == .context }.map {
                    let media = store.galleryMediaURLs(for: $0)
                    return GalleryItem(capture: $0, coverPreviewURL: media.preview, coverVideoURL: media.video)
                }
                consumed += items.count
            }
        }
        let cacheTime = clock.measure {
            for _ in 0..<100 { consumed += store.gallerySnapshot(in: .context).items.count }
        }
        try require(consumed == 39_800, "Benchmark discarded data")
        print("Gallery diagnostic (200 records, 100 reads): remap \(mappingTime), cached \(cacheTime)")
    }

    private static func checkImportReentrancy(in root: URL) async throws {
        let manager = FileManager.default
        let store = CaptureStore(rootURL: root)
        let collection = store.selectedCollectionID!
        let record = try store.saveText("Import target")
        let itemURL = store.containerURL(for: record)!
        let sourceURL = root.appendingPathComponent("source.bin")
        try Data(repeating: 7, count: 8 * 1_024 * 1_024).write(to: sourceURL)
        // The child mutation runs after import captures its item URL and yields
        // to copy the file, deterministically invalidating the old array index.
        let insertion = Task { @MainActor in try store.saveText("Inserted during copy") }
        let tab = try await store.importDetailTabFile(for: record.id, from: sourceURL)
        let inserted = try await insertion.value
        try require(store.records.first { $0.id == record.id }?.detailTabs?.contains(tab) == true, "Import committed to stale array index")
        try require(store.records.first { $0.id == inserted.id }?.detailTabs == nil, "Import changed an unrelated record")

        let otherURL = root.appendingPathComponent("Other", isDirectory: true)
        try manager.createDirectory(at: otherURL, withIntermediateDirectories: true)
        let switchCollection = Task { @MainActor in try store.addCollection(at: otherURL) }
        let second = try await store.importDetailTabFile(for: record.id, from: sourceURL)
        _ = try await switchCollection.value
        try require(store.records.isEmpty, "Import published into another collection")
        let persisted = try JSONDecoder.fx.decode(CaptureRecord.self, from: Data(contentsOf: itemURL.appendingPathComponent("metadata.json")))
        try require(persisted.detailTabs?.contains(second) == true, "Import did not persist in its original collection")
        store.selectCollection(collection)
        try require(store.records.first { $0.id == record.id }?.detailTabs?.count == 2, "Imported tabs did not survive reload")

        let imageURL = root.appendingPathComponent("cover.tiff")
        let image = NSImage(size: NSSize(width: 64, height: 48), flipped: false) { rect in
            NSColor.blue.setFill(); rect.fill(); return true
        }
        guard let data = image.tiffRepresentation else { throw Failure(description: "Image fixture failed") }
        try data.write(to: imageURL)
        let titleEdit = Task { @MainActor in
            store.update(record.id) { $0.title = "Edited during decode" }
            _ = try store.saveText("Another insertion")
        }
        try await store.replaceCover(for: record.id, from: imageURL)
        try await titleEdit.value
        let covered = store.records.first { $0.id == record.id }!
        try require(covered.title == "Edited during decode" && covered.coverKind == .image, "Cover lost a concurrent edit")
        try require(covered.coverThumbnailFileName != nil, "Cover preview missing")

        // Force only the metadata commit to fail. Existing media must remain
        // usable, and neither synchronous nor asynchronous replacement may
        // leave an unreferenced new cover behind.
        let metadataURL = itemURL.appendingPathComponent("metadata.json")
        let backupURL = root.appendingPathComponent("metadata-backup.json")
        try manager.moveItem(at: metadataURL, to: backupURL)
        try manager.createDirectory(at: metadataURL, withIntermediateDirectories: false)
        let previousFiles = Set(try manager.contentsOfDirectory(atPath: itemURL.path))
        var failed = false
        do { try store.replaceCover(for: record.id, with: image) } catch { failed = true }
        try require(failed, "Synchronous cover accepted a failed metadata commit")
        failed = false
        do { try await store.replaceCover(for: record.id, from: imageURL) } catch { failed = true }
        try require(failed, "Asynchronous cover accepted a failed metadata commit")
        failed = false
        do { try store.removeCover(for: record.id) } catch { failed = true }
        try require(failed, "Cover removal accepted a failed metadata commit")
        try require(store.records.first { $0.id == record.id } == covered, "Failed commit changed visible metadata")
        try require(Set(try manager.contentsOfDirectory(atPath: itemURL.path)) == previousFiles, "Failed commit deleted old media or leaked new media")
        try manager.removeItem(at: metadataURL)
        try manager.moveItem(at: backupURL, to: metadataURL)
    }

    private static func checkArtifacts(in root: URL) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("Folder 10"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Folder 2"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("z.txt"))
        try Data().write(to: root.appendingPathComponent(".hidden"))
        try Data().write(to: root.appendingPathComponent("Folder 10/metadata.json"))
        let entries = try await SessionArtifactTreeModel.scanDirectory(root)
        try require(entries.map(\.name) == ["Folder 2", "Folder 10", "z.txt"], "Artifact ordering/hidden policy changed")
        let filtered = try await SessionArtifactTreeModel.scanDirectory(root, excludingManagedItemDirectories: true)
        try require(filtered.map(\.name) == ["Folder 2", "z.txt"], "Managed directory filtering changed")
        let model = SessionArtifactTreeModel()
        let later = Task { @MainActor in
            await model.configure(rootURL: root, excludedTopLevelPaths: [], excludesManagedItemDirectories: true)
        }
        await model.configure(rootURL: root, excludedTopLevelPaths: [], excludesManagedItemDirectories: false)
        await later.value
        try require(model.childrenByDirectory[root.standardizedFileURL]?.map(\.name) == ["Folder 2", "z.txt"], "An obsolete scan overwrote new exclusions")
        await model.refreshLoadedDirectories()
        try require(model.loadingDirectories.isEmpty, "Artifact loading state leaked")
        let cancelled = Task { try await SessionArtifactTreeModel.scanDirectory(root) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw Failure(description: "Cancelled scan completed")
        } catch is CancellationError {}
    }

    private static func checkCancelledRun(in root: URL) async throws {
        let payload = ContextRuntimePayload(notebook: .fresh(title: "Cancelled"), collectionURL: root, contexts: [:], mediaURLs: [:])
        let task = Task { try await ContextPiRunner.run(payload) }
        task.cancel()
        do {
            _ = try await task.value
            throw Failure(description: "Cancelled run reached process launch")
        } catch is CancellationError {}
    }

    private static func checkRuntimeProcess(in root: URL) async throws {
        func payload(_ query: String) -> ContextRuntimePayload {
            var notebook = ContextNotebook.fresh(title: "Offline")
            notebook.items = [ContextNotebookItem(kind: .query, body: query)]
            return ContextRuntimePayload(notebook: notebook, collectionURL: root, contexts: [:], mediaURLs: [:])
        }
        var activity = ContextLiveActivity()
        let result = try await ContextPiRunner.run(payload("complete")) { event in activity.apply(event) }
        try require(result.final == String(repeating: "字", count: 128), "Process output decoding changed")
        try require(activity.entries.last?.detail == result.final, "Pipe batching lost text or final event")
        for _ in 0..<3 {
            do {
                _ = try await ContextPiRunner.run(payload("fail"))
                throw Failure(description: "Failed subprocess was accepted")
            } catch ContextNotebookError.launchFailed(let log) {
                try require(log.contains("intentional offline fixture failure"), "Subprocess stderr was lost")
            }
        }
        @MainActor final class Owner {
            var task: Task<ContextRunResult, Error>?
        }
        let owner = Owner()
        owner.task = Task {
            try await ContextPiRunner.run(payload("cancel")) { event in
                if event.type == "fx/round_start" { owner.task?.cancel() }
            }
        }
        let started = ContinuousClock.now
        do {
            _ = try await owner.task!.value
            throw Failure(description: "Task cancellation did not stop the subprocess")
        } catch ContextNotebookError.cancelled {}
        owner.task = nil
        try require(started.duration(to: .now) < .seconds(10), "Cancellation waited for the fixture timeout")
        print("PASS: real subprocess stdout, stderr, Unicode batching, and task-to-process cancellation")
    }
}
