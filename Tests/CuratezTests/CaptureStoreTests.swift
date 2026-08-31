import AppKit
import XCTest
@testable import Curatez

final class CaptureStoreTests: XCTestCase {
    @MainActor
    func testLibraryWorkingDirectoryPersistsWithoutMovingLibraryStorage() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("CuratezWorkingDirectory-\(UUID().uuidString)", isDirectory: true)
        let cwd = root.appendingPathComponent("Project", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: cwd, withIntermediateDirectories: true)

        let store = CaptureStore(rootURL: root.appendingPathComponent("AppData", isDirectory: true))
        let library = try XCTUnwrap(store.selectedCollection)
        XCTAssertEqual(store.workingDirectoryURL(for: library), store.folderURL(for: library))

        try store.setWorkingDirectory(cwd, for: library.id)
        XCTAssertEqual(store.folderURL(for: try XCTUnwrap(store.selectedCollection)), store.folderURL(for: library))
        XCTAssertEqual(store.workingDirectoryURL(for: try XCTUnwrap(store.selectedCollection)), cwd.standardizedFileURL)

        let reloaded = CaptureStore(rootURL: root.appendingPathComponent("AppData", isDirectory: true))
        let reloadedLibrary = try XCTUnwrap(reloaded.selectedCollection)
        XCTAssertEqual(reloaded.folderURL(for: reloadedLibrary), store.folderURL(for: library))
        XCTAssertEqual(reloaded.workingDirectoryURL(for: reloadedLibrary), cwd.standardizedFileURL)

        try reloaded.setWorkingDirectory(nil, for: reloadedLibrary.id)
        XCTAssertEqual(reloaded.workingDirectoryURL(for: try XCTUnwrap(reloaded.selectedCollection)), reloaded.folderURL(for: reloadedLibrary))
    }

    @MainActor
    func testEveryManagedItemTypePersistsOnARecord() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CuratezItemTypes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = CaptureStore(rootURL: root)
        let record = try store.saveText("Reusable tool definition")
        store.update(record.id) { $0.space = .tool }

        let reloaded = CaptureStore(rootURL: root)
        XCTAssertEqual(reloaded.records.first(where: { $0.id == record.id })?.space, .tool)
        XCTAssertEqual(
            CaptureSpace.allCases,
            [.system, .context, .query, .tool, .skill, .subagent, .session]
        )
    }

    @MainActor
    func testSubagentDefinitionAndEditableBodyPersist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CuratezSubagentItem-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = CaptureStore(rootURL: root)
        let record = try store.saveAgentItem(
            space: .subagent,
            title: "scout",
            detail: "Find verified facts",
            body: "Return concise evidence.",
            configuration: CaptureAgentConfiguration(
                tools: ["read", "search"],
                skills: ["research"],
                model: "anthropic/claude-sonnet",
                fork: true
            )
        )
        try store.updateOriginalText(for: record.id, text: "Return cited evidence only.")

        let reloaded = CaptureStore(rootURL: root)
        let saved = try XCTUnwrap(reloaded.records.first(where: { $0.id == record.id }))
        XCTAssertEqual(saved.space, .subagent)
        XCTAssertEqual(saved.itemDescription, "Find verified facts")
        XCTAssertEqual(saved.agentConfiguration?.tools, ["read", "search"])
        XCTAssertEqual(saved.agentConfiguration?.skills, ["research"])
        XCTAssertEqual(saved.agentConfiguration?.model, "anthropic/claude-sonnet")
        XCTAssertEqual(saved.agentConfiguration?.fork, true)
        XCTAssertEqual(reloaded.originalTextContent(for: saved), "Return cited evidence only.")
    }

    @MainActor
    func testSodaSystemPromptInstallsOnceIntoLibraryEvenWhenAnotherCollectionIsSelected() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("CuratezSodaSystem-\(UUID().uuidString)", isDirectory: true)
        let otherCollection = root.appendingPathComponent("Other", isDirectory: true)
        let sourceURL = root.appendingPathComponent("soda-system.md")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: otherCollection, withIntermediateDirectories: true)
        try "Full Soda system prompt".write(to: sourceURL, atomically: true, encoding: .utf8)

        let store = CaptureStore(rootURL: root.appendingPathComponent("AppData", isDirectory: true))
        let libraryID = try XCTUnwrap(store.collections.first(where: { $0.name == "Library" })?.id)
        let other = try store.addCollection(at: otherCollection)
        XCTAssertEqual(store.selectedCollectionID, other.id)

        let installed = try XCTUnwrap(store.installSodaSystemPromptIfNeeded(sourceURL: sourceURL))
        XCTAssertEqual(installed.space, .system)
        XCTAssertTrue(store.records.isEmpty, "Installing into Library must not change the selected collection's records")
        XCTAssertNil(try store.installSodaSystemPromptIfNeeded(sourceURL: sourceURL))

        store.selectCollection(libraryID)
        let saved = try XCTUnwrap(store.records.first(where: { $0.id == installed.id }))
        XCTAssertEqual(saved.title, "Soda Engineering System Prompt")
        XCTAssertEqual(store.originalTextContent(for: saved), "Full Soda system prompt")
        XCTAssertTrue((saved.tags ?? []).contains("builtin:soda-system-prompt"))
    }

    @MainActor
    func testBuiltinToolsInstallOnceIntoEveryLibraryAsInactiveDeclarations() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("CuratezBuiltinTools-\(UUID().uuidString)", isDirectory: true)
        let appData = root.appendingPathComponent("AppData", isDirectory: true)
        let otherCollection = root.appendingPathComponent("Other", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: otherCollection, withIntermediateDirectories: true)

        let store = CaptureStore(rootURL: appData)
        let libraryID = try XCTUnwrap(store.collections.first(where: { $0.name == "Library" })?.id)
        let other = try store.addCollection(at: otherCollection)
        XCTAssertEqual(store.selectedCollectionID, other.id)

        let installed = try store.installBuiltinToolsIfNeeded()
        XCTAssertEqual(installed.count, 10)
        XCTAssertEqual(Set(installed.map(\.title)), Set(["read", "edit", "bash", "write", "search"]))
        XCTAssertTrue(installed.allSatisfy { $0.space == .tool })
        XCTAssertEqual(Set(store.records.map(\.title)), Set(["read", "edit", "bash", "write", "search"]))
        XCTAssertTrue(try store.installBuiltinToolsIfNeeded().isEmpty)

        store.selectCollection(libraryID)
        let builtins = store.records.filter { ($0.tags ?? []).contains("builtin") && $0.space == .tool }
        XCTAssertEqual(Set(builtins.map(\.title)), Set(["read", "edit", "bash", "write", "search"]))

        store.selectCollection(other.id)
        let otherBuiltins = store.records.filter { ($0.tags ?? []).contains("builtin") && $0.space == .tool }
        XCTAssertEqual(Set(otherBuiltins.map(\.title)), Set(["read", "edit", "bash", "write", "search"]))
    }

    @MainActor
    func testJustOneAPIInstallsOneSchemaContextPerPlatformExactlyOnce() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("CuratezJustOneAPIContexts-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("contexts.json")
        let source: [[String: String]] = [
            [
                "platformID": "xiaohongshu",
                "title": "小红书 · JustOneAPI",
                "description": "小红书能力与 schema",
                "content": "# 小红书\n\n`xiaohongshu.search_note_v4`",
            ],
            [
                "platformID": "douyin",
                "title": "抖音 · JustOneAPI",
                "description": "抖音能力与 schema",
                "content": "# 抖音\n\n`douyin.search_video_v1`",
            ],
        ]
        try JSONSerialization.data(withJSONObject: source).write(to: sourceURL)

        let store = CaptureStore(rootURL: root.appendingPathComponent("AppData", isDirectory: true))
        let libraryID = try XCTUnwrap(store.collections.first(where: { $0.name == "Library" })?.id)
        let installed = try store.installJustOneAPIContextsIfNeeded(sourceURL: sourceURL)

        XCTAssertEqual(Set(installed.map(\.title)), Set(["小红书 · JustOneAPI", "抖音 · JustOneAPI"]))
        XCTAssertTrue(installed.allSatisfy { $0.space == .context })
        XCTAssertTrue(installed.allSatisfy { ($0.tags ?? []).contains(where: { $0.hasPrefix("platform:") }) })
        XCTAssertTrue(try store.installJustOneAPIContextsIfNeeded(sourceURL: sourceURL).isEmpty)

        store.selectCollection(libraryID)
        let contexts = store.records.filter {
            ($0.tags ?? []).contains(where: { $0.hasPrefix("builtin:context:platform-search:") })
        }
        XCTAssertEqual(contexts.count, 2)
        let xiaohongshu = try XCTUnwrap(contexts.first(where: { $0.title == "小红书 · JustOneAPI" }))
        XCTAssertTrue(store.originalTextContent(for: xiaohongshu)?.contains("search_note_v4") == true)
        XCTAssertNil(xiaohongshu.sourceURL)
        XCTAssertEqual(
            store.context(for: xiaohongshu),
            "小红书 · JustOneAPI — 小红书能力与 schema\n# 小红书\n\n`xiaohongshu.search_note_v4`"
        )
        XCTAssertFalse(store.context(for: xiaohongshu).contains("Tags:"))
    }

    @MainActor
    func testDiscardingAnUncommittedSessionDraftRemovesItsFolderPermanently() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("CuratezDiscardSession-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let store = CaptureStore(rootURL: root)
        let session = try store.saveSession(notebook: .fresh(title: "Disposable"))
        let folder = try XCTUnwrap(store.containerURL(for: session))
        XCTAssertTrue(fileManager.fileExists(atPath: folder.path))

        try store.discardSessionDraft(session.id)

        XCTAssertFalse(store.records.contains(where: { $0.id == session.id }))
        XCTAssertFalse(fileManager.fileExists(atPath: folder.path))
    }

    @MainActor
    func testCollectionStoresEachCaptureInItsOwnFolderAndReloadsIt() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("CuratezTests-\(UUID().uuidString)", isDirectory: true)
        let appData = testRoot.appendingPathComponent("AppData", isDirectory: true)
        let collectionURL = testRoot.appendingPathComponent("Research", isDirectory: true)
        try fileManager.createDirectory(at: collectionURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let store = CaptureStore(rootURL: appData)
        let collection = try store.addCollection(at: collectionURL)
        let record = try store.saveText("A complete context note")
        let itemFolder = try XCTUnwrap(store.containerURL(for: record))

        XCTAssertEqual(store.selectedCollectionID, collection.id)
        XCTAssertEqual(itemFolder.deletingLastPathComponent(), collectionURL.standardizedFileURL)
        XCTAssertTrue(fileManager.fileExists(atPath: itemFolder.appendingPathComponent("content.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: itemFolder.appendingPathComponent("metadata.json").path))
        XCTAssertEqual(
            try String(contentsOf: itemFolder.appendingPathComponent("content.txt"), encoding: .utf8),
            "A complete context note"
        )

        let reloadedStore = CaptureStore(rootURL: appData)
        XCTAssertEqual(reloadedStore.selectedCollectionID, collection.id)
        XCTAssertEqual(reloadedStore.records.map(\.id), [record.id])
    }

    @MainActor
    func testEveryContentTypeCanReceiveAnIndependentCover() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("CuratezCoverTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let store = CaptureStore(rootURL: testRoot)
        let textRecord = try store.saveText("Text can have a visual cover")
        let cover = NSImage(size: NSSize(width: 32, height: 24), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }

        try store.replaceCover(for: textRecord.id, with: cover)
        let updated = try XCTUnwrap(store.records.first(where: { $0.id == textRecord.id }))
        let coverURL = try XCTUnwrap(store.coverURL(for: updated))

        XCTAssertTrue(updated.coverFileName?.hasPrefix("cover-") == true)
        XCTAssertEqual(coverURL.pathExtension, "png")
        XCTAssertEqual(updated.coverKind, .image)
        XCTAssertTrue(fileManager.fileExists(atPath: coverURL.path))
        XCTAssertNotNil(NSImage(contentsOf: coverURL))
        XCTAssertNil(store.contextMediaURL(for: updated), "A text item's custom cover must not enter Agent context")

        let capturedImage = try store.saveImage(cover, title: "Original image content")
        XCTAssertEqual(
            store.contextMediaURL(for: capturedImage),
            store.fileURL(for: capturedImage),
            "Original captured images remain multimodal context"
        )
    }

    @MainActor
    func testImportedImageCoverCreatesPersistentGalleryPreview() async throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("CuratezCoverPreviewTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let store = CaptureStore(rootURL: testRoot)
        let record = try store.saveText("Preview-backed cover")
        let sourceImage = NSImage(size: NSSize(width: 2_400, height: 1_600), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let sourceURL = testRoot.appendingPathComponent("source-cover.tiff")
        try XCTUnwrap(sourceImage.tiffRepresentation).write(to: sourceURL, options: .atomic)

        try await store.replaceCover(for: record.id, from: sourceURL)
        let updated = try XCTUnwrap(store.records.first(where: { $0.id == record.id }))
        let previewName = try XCTUnwrap(updated.coverThumbnailFileName)
        let containerURL = try XCTUnwrap(store.containerURL(for: updated))
        let previewURL = containerURL.appendingPathComponent(previewName)
        let media = store.galleryMediaURLs(for: updated)

        XCTAssertEqual(updated.coverKind, .image)
        XCTAssertTrue(previewName.hasPrefix("cover-preview-"))
        XCTAssertTrue(fileManager.fileExists(atPath: previewURL.path))
        XCTAssertEqual(media.preview, previewURL)
        XCTAssertNil(media.video)
    }

    @MainActor
    func testDefaultDetailsAndFileTabsPersistAsRealFiles() async throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("CuratezDetailTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let store = CaptureStore(rootURL: testRoot)
        let record = try store.saveText("Original captured text")
        try store.updateDetails(
            for: record.id,
            title: "Research note",
            tags: ["design", "context"],
            description: "A concise description"
        )
        let tab = try store.addDetailTab(for: record.id, title: "Notes", kind: .markdown)
        try store.saveContent("# Notes\n\nIndependent markdown content.", for: tab.id, in: record.id)

        let sourceImageURL = testRoot.appendingPathComponent("reference.png")
        let sourceImage = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let sourceBitmap = try XCTUnwrap(sourceImage.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let sourcePNG = try XCTUnwrap(sourceBitmap.representation(using: .png, properties: [:]))
        try sourcePNG.write(to: sourceImageURL)
        let imageTab = try await store.importDetailTabFile(for: record.id, from: sourceImageURL)

        let updated = try XCTUnwrap(store.records.first(where: { $0.id == record.id }))
        let itemFolder = try XCTUnwrap(store.containerURL(for: updated))
        XCTAssertEqual(updated.title, "Research note")
        XCTAssertEqual(updated.tags, ["design", "context"])
        XCTAssertEqual(updated.itemDescription, "A concise description")
        XCTAssertEqual(updated.detailTabs, [tab, imageTab])
        XCTAssertEqual(tab.fileName, "Notes.md")
        XCTAssertEqual(imageTab.kind, .image)
        XCTAssertTrue(fileManager.fileExists(atPath: itemFolder.appendingPathComponent(imageTab.fileName).path))
        XCTAssertEqual(
            try String(contentsOf: itemFolder.appendingPathComponent("Notes.md"), encoding: .utf8),
            "# Notes\n\nIndependent markdown content."
        )

        let reloaded = CaptureStore(rootURL: testRoot)
        let reloadedRecord = try XCTUnwrap(reloaded.records.first(where: { $0.id == record.id }))
        XCTAssertEqual(reloadedRecord.detailTabs, [tab, imageTab])
        XCTAssertEqual(reloaded.content(for: tab, in: reloadedRecord), "# Notes\n\nIndependent markdown content.")
    }

    @MainActor
    func testContextCombinesMetadataOriginalContentAndTypedTabs() async throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("CuratezContextTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let store = CaptureStore(rootURL: testRoot)
        let record = try store.saveText("Original research excerpt")
        try store.updateDetails(
            for: record.id,
            title: "Context export",
            tags: ["research", "reference"],
            description: "Everything needed by the clipboard context."
        )
        let notesTab = try store.addDetailTab(for: record.id, title: "Notes", kind: .plainText)
        try store.saveContent("A supporting note.", for: notesTab.id, in: record.id)

        let imageURL = testRoot.appendingPathComponent("reference.png")
        let image = NSImage(size: NSSize(width: 12, height: 8), flipped: false) { rect in
            NSColor.systemPurple.setFill()
            rect.fill()
            return true
        }
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: imageURL)
        try store.replaceCover(for: record.id, with: image)
        let imageTab = try await store.importDetailTabFile(for: record.id, from: imageURL)

        let videoURL = testRoot.appendingPathComponent("clip.mov")
        try Data("test-video-placeholder".utf8).write(to: videoURL)
        let videoTab = try await store.importDetailTabFile(for: record.id, from: videoURL)

        let updated = try XCTUnwrap(store.records.first(where: { $0.id == record.id }))
        let context = store.context(for: updated)
        let coverPath = try XCTUnwrap(store.coverURL(for: updated)).path
        let imagePath = try XCTUnwrap(store.fileURL(for: imageTab, in: updated)).path
        let videoPath = try XCTUnwrap(store.fileURL(for: videoTab, in: updated)).path

        XCTAssertTrue(context.contains("Title: Context export"))
        XCTAssertTrue(context.contains("Tags: research, reference"))
        XCTAssertTrue(context.contains("Everything needed by the clipboard context."))
        XCTAssertTrue(context.contains("Original research excerpt"))
        XCTAssertTrue(context.contains("[Notes]:\nA supporting note."))
        XCTAssertTrue(context.contains("[\(imageTab.title)]:\n\(imageTab.fileName)"))
        XCTAssertTrue(context.contains("[\(videoTab.title)]:\n\(videoTab.fileName)"))
        XCTAssertFalse(context.contains("Tabs:"))
        XCTAssertFalse(context.contains(imagePath))
        XCTAssertFalse(context.contains(videoPath))
        XCTAssertFalse(context.contains("Cover:"))
        XCTAssertFalse(context.contains(coverPath))
    }

    @MainActor
    func testRenamingATabRenamesTheBackingFolder() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("CuratezRenameTests-\(UUID().uuidString)", isDirectory: true)
        let appData = testRoot.appendingPathComponent("AppData", isDirectory: true)
        let originalURL = testRoot.appendingPathComponent("Original", isDirectory: true)
        try fileManager.createDirectory(at: originalURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let store = CaptureStore(rootURL: appData)
        let collection = try store.addCollection(at: originalURL)
        try store.renameCollection(collection.id, to: "Renamed")

        let renamed = try XCTUnwrap(store.collections.first(where: { $0.id == collection.id }))
        XCTAssertEqual(renamed.name, "Renamed")
        XCTAssertFalse(fileManager.fileExists(atPath: originalURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: testRoot.appendingPathComponent("Renamed").path))
    }
}
