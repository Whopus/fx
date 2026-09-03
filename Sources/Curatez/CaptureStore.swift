import AppKit
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct CollectionFolder: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var path: String
    var workingDirectoryPath: String? = nil
}

enum CaptureCoverKind: String, Codable, Hashable, Sendable {
    case image
    case video
}

struct CaptureDetailTab: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case markdown
        case plainText
        case image
        case video
        case file

        var id: Self { self }
        var fileExtension: String? {
            switch self {
            case .markdown: "md"
            case .plainText: "txt"
            case .image, .video, .file: nil
            }
        }
        var displayName: String {
            switch self {
            case .markdown: "Markdown"
            case .plainText: "Text"
            case .image: "Image"
            case .video: "Video"
            case .file: "File"
            }
        }
        var isTextEditable: Bool { self == .markdown || self == .plainText }
    }

    let id: UUID
    var title: String
    var fileName: String
    var kind: Kind
}

struct CaptureAgentConfiguration: Codable, Hashable, Sendable {
    var tools: [String] = []
    var skills: [String] = []
    var model: String? = nil
    var fork: Bool = false
}

struct CaptureRecord: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case link
        case video
        case image
        case browserSnapshot
    }

    let id: UUID
    var kind: Kind
    var title: String
    var text: String?
    var fileName: String?
    var sourceURL: String?
    var createdAt: Date
    var pixelWidth: Double?
    var pixelHeight: Double?
    var thumbnailFileName: String?
    var durationSeconds: Double?
    var isSaved: Bool
    var isTrashed: Bool
    var containerFolderName: String? = nil
    var coverFileName: String? = nil
    var coverKind: CaptureCoverKind? = nil
    var coverThumbnailFileName: String? = nil
    var tags: [String]? = nil
    var itemDescription: String? = nil
    var detailTabs: [CaptureDetailTab]? = nil
    var space: CaptureSpace? = nil
    var agentConfiguration: CaptureAgentConfiguration? = nil
}

enum CaptureSpace: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case system
    case context
    case query
    case tool
    case skill
    case subagent
    case session

    var id: Self { self }

    var displayName: String {
        switch self {
        case .system: "System"
        case .context: "Context"
        case .query: "Query"
        case .tool: "Tool"
        case .skill: "Skill"
        case .subagent: "Subagent"
        case .session: "Session"
        }
    }

    var icon: String {
        switch self {
        case .system: "gearshape"
        case .context: "square.stack.3d.up"
        case .query: "text.bubble"
        case .tool: "wrench.and.screwdriver"
        case .skill: "sparkles"
        case .subagent: "person.2"
        case .session: "bubble.left.and.text.bubble.right"
        }
    }

    var summary: String {
        switch self {
        case .system: "系统指令与行为约束"
        case .context: "参考资料与已收藏内容"
        case .query: "问题和任务输入"
        case .tool: "可调用工具定义"
        case .skill: "可复用技能说明"
        case .subagent: "子智能体角色配置"
        case .session: "模型运行与输出记录"
        }
    }
}

private struct CollectionConfiguration: Codable {
    var folders: [CollectionFolder]
    var selectedFolderID: UUID?
}

private struct ImageCoverPayload: Sendable {
    let fullData: Data
    let previewData: Data?
}

private struct NotebookSessionSnapshot {
    let title: String
    let content: String
    let description: String
    let result: ContextRunResult?
}

private struct JustOneAPIContextDefinition: Decodable {
    let platformID: String
    let title: String
    let description: String
    let content: String
}

@MainActor
final class CaptureStore: ObservableObject {
    @Published private(set) var records: [CaptureRecord] = []
    @Published private(set) var collections: [CollectionFolder] = []
    @Published private(set) var selectedCollectionID: UUID?

    private let fileManager = FileManager.default
    private let rootURL: URL
    private let configurationURL: URL
    private let legacyRecordsURL: URL
    private let automaticallyInstallsBuiltinTools: Bool

    init(rootURL overrideRootURL: URL? = nil) {
        let shouldInstallBuiltins = overrideRootURL == nil
        automaticallyInstallsBuiltinTools = shouldInstallBuiltins
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        rootURL = overrideRootURL
            ?? applicationSupport.appendingPathComponent("Curatez", isDirectory: true)
        configurationURL = rootURL.appendingPathComponent("collections.json")
        legacyRecordsURL = rootURL.appendingPathComponent("captures.json")

        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        loadConfigurationOrBootstrap()
        if shouldInstallBuiltins, let sourceURL = sodaSystemPromptSourceURL() {
            _ = try? installSodaSystemPromptIfNeeded(sourceURL: sourceURL)
        }
        if shouldInstallBuiltins {
            _ = try? installBuiltinToolsIfNeeded()
        }
        if shouldInstallBuiltins, let sourceURL = justOneAPIContextsSourceURL() {
            _ = try? installJustOneAPIContextsIfNeeded(sourceURL: sourceURL)
        }
    }

    var selectedCollection: CollectionFolder? {
        collections.first { $0.id == selectedCollectionID }
    }

    func folderURL(for collection: CollectionFolder) -> URL {
        URL(fileURLWithPath: collection.path, isDirectory: true).standardizedFileURL
    }

    /// The Library remains the storage root; only Agent and tool execution uses this directory.
    func workingDirectoryURL(for collection: CollectionFolder) -> URL {
        guard let path = collection.workingDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return folderURL(for: collection)
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    func setWorkingDirectory(_ url: URL?, for collectionID: UUID) throws {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        if let url {
            let normalizedURL = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: normalizedURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw CaptureStoreError.workingDirectoryUnavailable
            }
            collections[index].workingDirectoryPath = normalizedURL.path
        } else {
            collections[index].workingDirectoryPath = nil
        }
        persistConfiguration()
    }

    func selectCollection(_ id: UUID) {
        guard collections.contains(where: { $0.id == id }) else { return }
        selectedCollectionID = id
        loadRecords()
        if automaticallyInstallsBuiltinTools {
            _ = try? installBuiltinToolsIfNeeded(in: id)
        }
        persistConfiguration()
    }

    @discardableResult
    func installSodaSystemPromptIfNeeded(sourceURL: URL) throws -> CaptureRecord? {
        let markerURL = rootURL.appendingPathComponent(".soda-system-prompt-installed")
        guard !fileManager.fileExists(atPath: markerURL.path) else { return nil }
        guard let library = collections.first(where: {
            $0.name.localizedCaseInsensitiveCompare("Library") == .orderedSame
        }) else { return nil }

        let libraryURL = folderURL(for: library)
        let markerTag = "builtin:soda-system-prompt"
        let decoder = JSONDecoder.curatez
        let existing = (try? fileManager.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.compactMap { child -> CaptureRecord? in
            guard let data = try? Data(contentsOf: child.appendingPathComponent("metadata.json")) else { return nil }
            return try? decoder.decode(CaptureRecord.self, from: data)
        }.first(where: { ($0.tags ?? []).contains(markerTag) })
        if existing != nil {
            try Data().write(to: markerURL, options: [.atomic])
            return nil
        }

        let prompt = try String(contentsOf: sourceURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        let id = UUID()
        let title = "Soda Engineering System Prompt"
        let folderName = "\(sanitizedFolderComponent(title))-\(id.uuidString.prefix(8))"
        let itemURL = libraryURL.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: itemURL, withIntermediateDirectories: false)
        var completed = false
        defer { if !completed { try? fileManager.removeItem(at: itemURL) } }

        try prompt.write(
            to: itemURL.appendingPathComponent("system.md"),
            atomically: true,
            encoding: .utf8
        )
        let record = CaptureRecord(
            id: id,
            kind: .text,
            title: title,
            text: prompt,
            fileName: "system.md",
            sourceURL: nil,
            createdAt: Date(),
            pixelWidth: nil,
            pixelHeight: nil,
            thumbnailFileName: nil,
            durationSeconds: nil,
            isSaved: true,
            isTrashed: false,
            containerFolderName: folderName,
            tags: ["system", "soda", "builtin", markerTag],
            itemDescription: "Soda engineering methodology and system instructions.",
            space: .system
        )
        try writeMetadata(record, to: itemURL)
        try Data().write(to: markerURL, options: [.atomic])
        if selectedCollectionID == library.id {
            records.insert(record, at: 0)
        }
        completed = true
        return record
    }

    /// Install Curatez-owned capability declarations into every managed Library. These records do
    /// not enable anything by themselves: a tool is registered with the runtime only
    /// after its Tool item is explicitly added to an Agent notebook.
    @discardableResult
    func installBuiltinToolsIfNeeded(in collectionID: UUID? = nil) throws -> [CaptureRecord] {
        struct Definition {
            let name: String
            let description: String
        }

        let definitions = [
            Definition(
                name: "read",
                description: "Read text files and supported images. Use offset and limit to inspect large files in sections."
            ),
            Definition(
                name: "edit",
                description: "Edit one file using exact, non-overlapping text replacements and return a structured diff."
            ),
            Definition(
                name: "bash",
                description: "Execute a shell command in the current Collection and return streamed stdout and stderr."
            ),
            Definition(
                name: "write",
                description: "Create or overwrite a file, creating parent directories when needed."
            ),
            Definition(
                name: "search",
                description: "Call an exact endpoint_id with params from a platform Context. Schema: name!:type=default{enum}; ! is required. code=0 succeeds; data is the payload; next_step paginates. External calls may incur charges."
            )
        ]
        let targetCollections: [CollectionFolder]
        if let collectionID {
            targetCollections = collections.filter { $0.id == collectionID }
        } else {
            targetCollections = collections
        }
        var installed: [CaptureRecord] = []

        for library in targetCollections {
            let libraryURL = folderURL(for: library)
            let decoder = JSONDecoder.curatez
            let existingRecords = (try? fileManager.contentsOfDirectory(
                at: libraryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ))?.compactMap { child -> CaptureRecord? in
                guard let data = try? Data(contentsOf: child.appendingPathComponent("metadata.json")) else {
                    return nil
                }
                return try? decoder.decode(CaptureRecord.self, from: data)
            } ?? []
            let existingByMarker = existingRecords.reduce(into: [String: CaptureRecord]()) { result, record in
                for tag in record.tags ?? [] where tag.hasPrefix("builtin:tool:") {
                    result[tag] = record
                }
            }

            for definition in definitions {
                let markerTag = "builtin:tool:\(definition.name)"
                let desiredTags = ["tool", "builtin", markerTag]
                if var existing = existingByMarker[markerTag],
                   let container = existing.containerFolderName {
                    let needsUpdate = existing.title != definition.name
                        || existing.text != definition.description
                        || existing.itemDescription != definition.description
                        || existing.tags != desiredTags
                        || existing.space != .tool
                    guard needsUpdate else { continue }
                    let itemURL = libraryURL.appendingPathComponent(container, isDirectory: true)
                    try definition.description.write(
                        to: itemURL.appendingPathComponent("tool.md"),
                        atomically: true,
                        encoding: .utf8
                    )
                    existing.title = definition.name
                    existing.text = definition.description
                    existing.fileName = "tool.md"
                    existing.tags = desiredTags
                    existing.itemDescription = definition.description
                    existing.space = .tool
                    try writeMetadata(existing, to: itemURL)
                    if selectedCollectionID == library.id,
                       let index = records.firstIndex(where: { $0.id == existing.id }) {
                        records[index] = existing
                    }
                    installed.append(existing)
                    continue
                }

                let id = UUID()
                let folderName = "\(sanitizedFolderComponent(definition.name))-\(id.uuidString.prefix(8))"
                let itemURL = libraryURL.appendingPathComponent(folderName, isDirectory: true)
                try fileManager.createDirectory(at: itemURL, withIntermediateDirectories: false)
                var completed = false
                defer { if !completed { try? fileManager.removeItem(at: itemURL) } }

                try definition.description.write(
                    to: itemURL.appendingPathComponent("tool.md"),
                    atomically: true,
                    encoding: .utf8
                )
                let record = CaptureRecord(
                    id: id,
                    kind: .text,
                    title: definition.name,
                    text: definition.description,
                    fileName: "tool.md",
                    sourceURL: nil,
                    createdAt: Date(),
                    pixelWidth: nil,
                    pixelHeight: nil,
                    thumbnailFileName: nil,
                    durationSeconds: nil,
                    isSaved: true,
                    isTrashed: false,
                    containerFolderName: folderName,
                    tags: desiredTags,
                    itemDescription: definition.description,
                    space: .tool
                )
                try writeMetadata(record, to: itemURL)
                if selectedCollectionID == library.id {
                    records.insert(record, at: 0)
                }
                installed.append(record)
                completed = true
            }
        }

        return installed
    }

    /// Install one concise capability and parameter guide per search platform.
    /// The generated source intentionally contains no API credential.
    @discardableResult
    func installJustOneAPIContextsIfNeeded(sourceURL: URL) throws -> [CaptureRecord] {
        let definitions = try JSONDecoder().decode(
            [JustOneAPIContextDefinition].self,
            from: Data(contentsOf: sourceURL)
        )
        guard let library = collections.first(where: {
            $0.name.localizedCaseInsensitiveCompare("Library") == .orderedSame
        }) else { return [] }

        let libraryURL = folderURL(for: library)
        let decoder = JSONDecoder.curatez
        let existingRecords = (try? fileManager.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.compactMap { child -> CaptureRecord? in
            guard let data = try? Data(contentsOf: child.appendingPathComponent("metadata.json")) else {
                return nil
            }
            return try? decoder.decode(CaptureRecord.self, from: data)
        } ?? []
        let existingByPlatform = existingRecords.reduce(into: [String: CaptureRecord]()) { result, record in
            guard let platformTag = (record.tags ?? []).first(where: { $0.hasPrefix("platform:") }) else {
                return
            }
            result[String(platformTag.dropFirst("platform:".count))] = record
        }
        var installed: [CaptureRecord] = []

        for definition in definitions {
            let platformID = definition.platformID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !platformID.isEmpty else { continue }
            let markerTag = "builtin:context:platform-search:\(platformID)"
            let desiredTags = ["context", "builtin", "platform:\(platformID)", markerTag]
            if var existing = existingByPlatform[platformID],
               let container = existing.containerFolderName {
                let needsUpdate = existing.title != definition.title
                    || existing.text != definition.content
                    || existing.itemDescription != definition.description
                    || existing.tags != desiredTags
                    || existing.sourceURL != nil
                    || existing.space != .context
                guard needsUpdate else { continue }
                let itemURL = libraryURL.appendingPathComponent(container, isDirectory: true)
                try definition.content.write(
                    to: itemURL.appendingPathComponent("context.md"),
                    atomically: true,
                    encoding: .utf8
                )
                existing.title = definition.title
                existing.text = definition.content
                existing.fileName = "context.md"
                existing.tags = desiredTags
                existing.itemDescription = definition.description
                existing.sourceURL = nil
                existing.space = .context
                try writeMetadata(existing, to: itemURL)
                if selectedCollectionID == library.id,
                   let index = records.firstIndex(where: { $0.id == existing.id }) {
                    records[index] = existing
                }
                installed.append(existing)
                continue
            }

            let id = UUID()
            let folderName = "\(sanitizedFolderComponent(definition.title))-\(id.uuidString.prefix(8))"
            let itemURL = libraryURL.appendingPathComponent(folderName, isDirectory: true)
            try fileManager.createDirectory(at: itemURL, withIntermediateDirectories: false)
            var completed = false
            defer { if !completed { try? fileManager.removeItem(at: itemURL) } }

            try definition.content.write(
                to: itemURL.appendingPathComponent("context.md"),
                atomically: true,
                encoding: .utf8
            )
            let record = CaptureRecord(
                id: id,
                kind: .text,
                title: definition.title,
                text: definition.content,
                fileName: "context.md",
                sourceURL: nil,
                createdAt: Date(),
                pixelWidth: nil,
                pixelHeight: nil,
                thumbnailFileName: nil,
                durationSeconds: nil,
                isSaved: true,
                isTrashed: false,
                containerFolderName: folderName,
                tags: desiredTags,
                itemDescription: definition.description,
                space: .context
            )
            try writeMetadata(record, to: itemURL)
            if selectedCollectionID == library.id {
                records.insert(record, at: 0)
            }
            installed.append(record)
            completed = true
        }
        return installed
    }

    @discardableResult
    func addCollection(at selectedURL: URL) throws -> CollectionFolder {
        let url = selectedURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CaptureStoreError.collectionFolderUnavailable
        }
        guard fileManager.isWritableFile(atPath: url.path) else {
            throw CaptureStoreError.collectionFolderNotWritable
        }

        if let existing = collections.first(where: { folderURL(for: $0) == url }) {
            selectCollection(existing.id)
            return existing
        }

        let collection = CollectionFolder(id: UUID(), name: url.lastPathComponent, path: url.path)
        collections.append(collection)
        selectedCollectionID = collection.id
        persistConfiguration()
        loadRecords()
        if automaticallyInstallsBuiltinTools {
            _ = try installBuiltinToolsIfNeeded(in: collection.id)
        }
        return collection
    }

    func renameCollection(_ id: UUID, to proposedName: String) throws {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !name.contains("/"),
              !name.contains(":"),
              name != ".",
              name != ".." else {
            throw CaptureStoreError.invalidCollectionName
        }

        let oldURL = folderURL(for: collections[index])
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        guard oldURL != newURL else { return }
        guard !fileManager.fileExists(atPath: newURL.path) else {
            throw CaptureStoreError.collectionNameAlreadyExists
        }

        try fileManager.moveItem(at: oldURL, to: newURL)
        collections[index].name = name
        collections[index].path = newURL.path
        persistConfiguration()
        if selectedCollectionID == id { loadRecords() }
    }

    func deleteCollection(_ id: UUID) throws {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        let url = folderURL(for: collections[index])
        guard isSafeDeletionTarget(url) else {
            throw CaptureStoreError.unsafeCollectionDeletion
        }

        if fileManager.fileExists(atPath: url.path) {
            var resultingURL: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
        }

        collections.remove(at: index)
        if selectedCollectionID == id {
            selectedCollectionID = collections.indices.contains(index)
                ? collections[index].id
                : collections.last?.id
        }
        persistConfiguration()
        loadRecords()
    }

    func fileURL(for record: CaptureRecord) -> URL? {
        guard let fileName = record.fileName else { return nil }
        return itemFolderURL(for: record)?.appendingPathComponent(fileName)
    }

    /// Media that is part of the captured content itself. Custom gallery covers
    /// are deliberately excluded from Agent context.
    func contextMediaURL(for record: CaptureRecord) -> URL? {
        switch record.kind {
        case .image, .browserSnapshot:
            return fileURL(for: record)
        case .text, .link, .video:
            return nil
        }
    }

    func thumbnailURL(for record: CaptureRecord) -> URL? {
        guard let thumbnailFileName = record.thumbnailFileName else { return nil }
        return itemFolderURL(for: record)?.appendingPathComponent(thumbnailFileName)
    }

    func coverURL(for record: CaptureRecord) -> URL? {
        guard let coverFileName = record.coverFileName else { return nil }
        return itemFolderURL(for: record)?.appendingPathComponent(coverFileName)
    }

    func coverPreviewURL(for record: CaptureRecord) -> URL? {
        if let fileName = record.coverThumbnailFileName {
            return itemFolderURL(for: record)?.appendingPathComponent(fileName)
        }
        return coverURL(for: record)
    }

    func galleryMediaURLs(for record: CaptureRecord) -> (preview: URL?, video: URL?) {
        guard let itemURL = itemFolderURL(for: record) else { return (nil, nil) }
        let cover = record.coverFileName.map { itemURL.appendingPathComponent($0) }
        if record.coverKind == .video {
            let preview = record.coverThumbnailFileName.map { itemURL.appendingPathComponent($0) }
            return (preview, cover)
        }
        let preview = record.coverThumbnailFileName.map { itemURL.appendingPathComponent($0) } ?? cover
        return (preview, nil)
    }

    func containerURL(for record: CaptureRecord) -> URL? {
        itemFolderURL(for: record)
    }

    /// Each Session owns a dedicated workspace for Agent and tool output. Keeping
    /// it beneath the Session record prevents one Session's artifacts from
    /// appearing in another Session's sidebar.
    func artifactsDirectoryURL(forSession sessionID: UUID) throws -> URL {
        guard let record = records.first(where: {
            $0.id == sessionID && $0.space == .session && !$0.isTrashed
        }), let sessionURL = itemFolderURL(for: record) else {
            throw CaptureStoreError.sessionNotebookUnavailable
        }

        let artifactsURL = sessionURL.appendingPathComponent("Artifacts", isDirectory: true)
        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: artifactsURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CaptureStoreError.sessionArtifactsUnavailable
            }
        } else {
            try fileManager.createDirectory(at: artifactsURL, withIntermediateDirectories: true)
        }
        return artifactsURL.standardizedFileURL
    }

    func replaceCover(for id: UUID, with image: NSImage) throws {
        guard let data = image.pngData else { throw CaptureStoreError.imageEncodingFailed }
        try replaceCoverData(data, for: id)
    }

    func replaceCover(for id: UUID, from sourceURL: URL) async throws {
        let payload = try await Task.detached(priority: .userInitiated) {
            guard let image = NSImage(contentsOf: sourceURL),
                  let data = image.pngData else {
                throw CaptureStoreError.imageEncodingFailed
            }
            return ImageCoverPayload(
                fullData: data,
                previewData: Self.pngThumbnailData(from: sourceURL, maxPixelSize: 1_600)
            )
        }.value
        guard let index = records.firstIndex(where: { $0.id == id }),
              let itemURL = itemFolderURL(for: records[index]) else {
            throw CaptureStoreError.collectionFolderUnavailable
        }
        let coverID = UUID().uuidString.lowercased()
        let fileName = "cover-\(coverID).png"
        let previewName = payload.previewData == nil ? nil : "cover-preview-\(coverID).png"
        let destinationURL = itemURL.appendingPathComponent(fileName)
        let previewURL = previewName.map { itemURL.appendingPathComponent($0) }
        try await Task.detached(priority: .userInitiated) {
            try payload.fullData.write(to: destinationURL, options: .atomic)
            if let previewData = payload.previewData, let previewURL {
                try previewData.write(to: previewURL, options: .atomic)
            }
        }.value
        let previousRecord = records[index]
        removePreviousCoverFiles(
            for: previousRecord,
            keeping: Set([fileName, previewName].compactMap { $0 })
        )
        var updatedRecord = previousRecord
        updatedRecord.coverFileName = fileName
        updatedRecord.coverKind = .image
        updatedRecord.coverThumbnailFileName = previewName
        try writeMetadata(updatedRecord, to: itemURL)
        records[index] = updatedRecord
    }

    nonisolated private static func pngThumbnailData(from sourceURL: URL, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else { return nil }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private func replaceCoverData(_ data: Data, for id: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == id }),
              let itemURL = itemFolderURL(for: records[index]) else {
            throw CaptureStoreError.collectionFolderUnavailable
        }
        let fileName = "cover-\(UUID().uuidString.lowercased()).png"
        try data.write(to: itemURL.appendingPathComponent(fileName), options: .atomic)
        let previousRecord = records[index]
        removePreviousCoverFiles(for: previousRecord, keeping: Set([fileName]))
        var updatedRecord = previousRecord
        updatedRecord.coverFileName = fileName
        updatedRecord.coverKind = .image
        updatedRecord.coverThumbnailFileName = nil
        try writeMetadata(updatedRecord, to: itemURL)
        records[index] = updatedRecord
    }

    func replaceCoverVideo(for id: UUID, from sourceURL: URL) async throws {
        guard let index = records.firstIndex(where: { $0.id == id }),
              let itemURL = itemFolderURL(for: records[index]) else {
            throw CaptureStoreError.collectionFolderUnavailable
        }
        let fileExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension.lowercased()
        let coverID = UUID().uuidString.lowercased()
        let fileName = "cover-video-\(coverID).\(fileExtension)"
        let destinationURL = itemURL.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try await Task.detached {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }.value

        let asset = AVURLAsset(url: destinationURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_600, height: 1_600)
        let posterName = "cover-poster-\(coverID).png"
        let posterURL = itemURL.appendingPathComponent(posterName)
        guard let result = try? await generator.image(at: CMTime(seconds: 0.25, preferredTimescale: 600)) else {
            try? fileManager.removeItem(at: destinationURL)
            throw CaptureStoreError.videoCoverGenerationFailed
        }
        let posterImage = result.image
        guard let posterData = await Task.detached(priority: .userInitiated, operation: {
            NSImage(
                cgImage: posterImage,
                size: NSSize(width: posterImage.width, height: posterImage.height)
            ).pngData
        }).value else {
            try? fileManager.removeItem(at: destinationURL)
            throw CaptureStoreError.videoCoverGenerationFailed
        }
        try await Task.detached(priority: .userInitiated) {
            try posterData.write(to: posterURL, options: .atomic)
        }.value

        let previousRecord = records[index]
        removePreviousCoverFiles(for: previousRecord, keeping: Set([fileName, posterName]))
        var updatedRecord = previousRecord
        updatedRecord.coverFileName = fileName
        updatedRecord.coverKind = .video
        updatedRecord.coverThumbnailFileName = posterName
        try writeMetadata(updatedRecord, to: itemURL)
        records[index] = updatedRecord
    }

    func removeCover(for id: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == id }),
              let itemURL = itemFolderURL(for: records[index]) else { return }
        let previousRecord = records[index]
        removePreviousCoverFiles(for: previousRecord, keeping: Set<String>())
        var updatedRecord = previousRecord
        updatedRecord.coverFileName = nil
        updatedRecord.coverKind = nil
        updatedRecord.coverThumbnailFileName = nil
        try writeMetadata(updatedRecord, to: itemURL)
        records[index] = updatedRecord
    }

    func updateDetails(
        for id: UUID,
        title: String,
        tags: [String],
        description: String
    ) throws {
        guard let index = records.firstIndex(where: { $0.id == id }),
              let itemURL = itemFolderURL(for: records[index]) else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw CaptureStoreError.invalidItemTitle }
        var updatedRecord = records[index]
        updatedRecord.title = cleanTitle
        updatedRecord.tags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let cleanDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedRecord.itemDescription = cleanDescription.isEmpty ? nil : cleanDescription
        try writeMetadata(updatedRecord, to: itemURL)
        records[index] = updatedRecord
    }

    @discardableResult
    func addDetailTab(for id: UUID, title proposedTitle: String, kind: CaptureDetailTab.Kind) throws -> CaptureDetailTab {
        guard let index = records.firstIndex(where: { $0.id == id }),
              let itemURL = itemFolderURL(for: records[index]) else {
            throw CaptureStoreError.collectionFolderUnavailable
        }
        let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CaptureStoreError.invalidDetailTabName }
        guard let fileExtension = kind.fileExtension else {
            throw CaptureStoreError.invalidDetailTabType
        }
        let baseName = sanitizedFolderComponent(title)
        var fileName = "\(baseName).\(fileExtension)"
        var counter = 2
        while fileManager.fileExists(atPath: itemURL.appendingPathComponent(fileName).path) {
            fileName = "\(baseName)-\(counter).\(fileExtension)"
            counter += 1
        }
        try "".write(to: itemURL.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        let tab = CaptureDetailTab(id: UUID(), title: title, fileName: fileName, kind: kind)
        var updatedRecord = records[index]
        var tabs = updatedRecord.detailTabs ?? []
        tabs.append(tab)
        updatedRecord.detailTabs = tabs
        try writeMetadata(updatedRecord, to: itemURL)
        records[index] = updatedRecord
        return tab
    }

    @discardableResult
    func importDetailTabFile(for id: UUID, from sourceURL: URL) async throws -> CaptureDetailTab {
        guard let index = records.firstIndex(where: { $0.id == id }),
              let itemURL = itemFolderURL(for: records[index]) else {
            throw CaptureStoreError.collectionFolderUnavailable
        }
        let originalBase = sourceURL.deletingPathExtension().lastPathComponent
        let baseName = sanitizedFolderComponent(originalBase)
        let fileExtension = sourceURL.pathExtension
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        var fileName = "\(baseName)\(suffix)"
        var counter = 2
        while fileManager.fileExists(atPath: itemURL.appendingPathComponent(fileName).path) {
            fileName = "\(baseName)-\(counter)\(suffix)"
            counter += 1
        }
        let destinationURL = itemURL.appendingPathComponent(fileName)
        try await Task.detached {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }.value

        let kind = detailTabKind(for: sourceURL)
        let tab = CaptureDetailTab(
            id: UUID(),
            title: originalBase.isEmpty ? sourceURL.lastPathComponent : originalBase,
            fileName: fileName,
            kind: kind
        )
        do {
            var updatedRecord = records[index]
            var tabs = updatedRecord.detailTabs ?? []
            tabs.append(tab)
            updatedRecord.detailTabs = tabs
            try writeMetadata(updatedRecord, to: itemURL)
            records[index] = updatedRecord
            return tab
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    func fileURL(for tab: CaptureDetailTab, in record: CaptureRecord) -> URL? {
        itemFolderURL(for: record)?.appendingPathComponent(tab.fileName)
    }

    func content(for tab: CaptureDetailTab, in record: CaptureRecord) -> String {
        guard let itemURL = itemFolderURL(for: record) else { return "" }
        return (try? String(contentsOf: itemURL.appendingPathComponent(tab.fileName), encoding: .utf8)) ?? ""
    }

    func originalTextContent(for record: CaptureRecord) -> String? {
        if let fileURL = fileURL(for: record),
           let text = try? String(contentsOf: fileURL, encoding: .utf8),
           !text.isEmpty {
            return text
        }
        guard let text = record.text, !text.isEmpty else { return nil }
        return text
    }

    func context(for record: CaptureRecord) -> String {
        if (record.tags ?? []).contains(where: { $0.hasPrefix("builtin:context:platform-search:") }) {
            let description = record.itemDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let heading = description.isEmpty ? record.title : "\(record.title) — \(description)"
            let content = originalContextContent(for: record).trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? heading : "\(heading)\n\(content)"
        }

        var sections: [String] = ["Title: \(record.title)"]

        if let tags = record.tags, !tags.isEmpty {
            sections.append("Tags: \(tags.joined(separator: ", "))")
        }
        if let description = record.itemDescription, !description.isEmpty {
            sections.append("Description:\n\(description)")
        }
        let originalContent = originalContextContent(for: record)
        sections.append("Content:\n\(originalContent)")

        if let sourceURL = record.sourceURL,
           !sourceURL.isEmpty,
           !originalContent.contains(sourceURL) {
            sections.append("Source: \(sourceURL)")
        }

        if let tabs = record.detailTabs, !tabs.isEmpty {
            for tab in tabs {
                let value: String
                switch tab.kind {
                case .markdown, .plainText:
                    let text = content(for: tab, in: record)
                    value = text.isEmpty ? "(Empty)" : text
                case .image, .video, .file:
                    value = tab.fileName
                }
                sections.append("[\(tab.title)]:\n\(value)")
            }
        }

        return sections.joined(separator: "\n\n")
    }

    func saveContent(_ content: String, for tabID: UUID, in recordID: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              let tab = records[index].detailTabs?.first(where: { $0.id == tabID }),
              let itemURL = itemFolderURL(for: records[index]) else { return }
        try content.write(to: itemURL.appendingPathComponent(tab.fileName), atomically: true, encoding: .utf8)
    }

    func deleteDetailTab(_ tabID: UUID, from recordID: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              let tabIndex = records[index].detailTabs?.firstIndex(where: { $0.id == tabID }),
              let itemURL = itemFolderURL(for: records[index]),
              let tab = records[index].detailTabs?[tabIndex] else { return }
        let fileURL = itemURL.appendingPathComponent(tab.fileName)
        if fileManager.fileExists(atPath: fileURL.path) {
            var resultingURL: NSURL?
            try fileManager.trashItem(at: fileURL, resultingItemURL: &resultingURL)
        }
        var updatedRecord = records[index]
        updatedRecord.detailTabs?.remove(at: tabIndex)
        try writeMetadata(updatedRecord, to: itemURL)
        records[index] = updatedRecord
    }

    @discardableResult
    func saveText(_ text: String, sourceURL: String? = nil) throws -> CaptureRecord {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = cleanText.replacingOccurrences(of: "\n", with: " ").prefix(54)
        let displayTitle = title.isEmpty ? "Selected text" : String(title)
        let id = UUID()
        let item = try prepareItemFolder(id: id, title: displayTitle)
        var completed = false
        defer { if !completed { try? fileManager.removeItem(at: item.url) } }

        try cleanText.write(to: item.url.appendingPathComponent("content.txt"), atomically: true, encoding: .utf8)
        try writeSourceURLIfNeeded(sourceURL, into: item.url)

        let record = CaptureRecord(
            id: id, kind: .text,
            title: displayTitle, text: cleanText, fileName: "content.txt", sourceURL: sourceURL,
            createdAt: Date(), pixelWidth: nil, pixelHeight: nil,
            thumbnailFileName: nil, durationSeconds: nil,
            isSaved: true, isTrashed: false, containerFolderName: item.name
        )
        try insert(record, in: item.url)
        completed = true
        return record
    }

    @discardableResult
    func saveAgentItem(
        space: CaptureSpace,
        title: String,
        detail: String,
        body: String,
        configuration: CaptureAgentConfiguration? = nil
    ) throws -> CaptureRecord {
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyTitle = String(cleanBody.replacingOccurrences(of: "\n", with: " ").prefix(72))
        let fallback = bodyTitle.isEmpty ? space.displayName : bodyTitle
        let displayTitle = cleanTitle.isEmpty ? fallback : cleanTitle
        let id = UUID()
        let item = try prepareItemFolder(id: id, title: displayTitle)
        var completed = false
        defer { if !completed { try? fileManager.removeItem(at: item.url) } }

        let fileName = "\(space.rawValue).md"
        let storedBody = cleanBody.isEmpty ? cleanDetail : cleanBody
        try storedBody.write(to: item.url.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        let record = CaptureRecord(
            id: id,
            kind: .text,
            title: displayTitle,
            text: storedBody,
            fileName: fileName,
            sourceURL: nil,
            createdAt: Date(),
            pixelWidth: nil,
            pixelHeight: nil,
            thumbnailFileName: nil,
            durationSeconds: nil,
            isSaved: true,
            isTrashed: false,
            containerFolderName: item.name,
            tags: [space.rawValue],
            itemDescription: cleanDetail.isEmpty ? nil : cleanDetail,
            space: space,
            agentConfiguration: configuration
        )
        try insert(record, in: item.url)
        completed = true
        return record
    }

    func updateOriginalText(for id: UUID, text: String) throws {
        guard let index = records.firstIndex(where: { $0.id == id }),
              let itemURL = itemFolderURL(for: records[index]),
              let fileName = records[index].fileName else { return }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try cleaned.write(to: itemURL.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        var updated = records[index]
        updated.text = cleaned
        try writeMetadata(updated, to: itemURL)
        records[index] = updated
    }

    @discardableResult
    func saveSession(query: String, result: ContextRunResult) throws -> CaptureRecord {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanFinal = result.final.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleSeed = cleanQuery.isEmpty ? "AI Session" : cleanQuery
        let title = String(titleSeed.replacingOccurrences(of: "\n", with: " ").prefix(72))
        let id = UUID()
        let item = try prepareItemFolder(id: id, title: title)
        var completed = false
        defer { if !completed { try? fileManager.removeItem(at: item.url) } }

        var sections = ["# \(title)", "", "## Query", cleanQuery, "", "## Output", cleanFinal]
        if let model = result.model, !model.isEmpty {
            sections.append(contentsOf: ["", "## Runtime", "- Model: \(model)"])
            if let totalTokens = result.totalTokens {
                sections.append("- Tokens: \(totalTokens)")
            }
            sections.append("- Status: \(result.status)")
        }
        if let error = result.error, !error.isEmpty {
            sections.append(contentsOf: ["", "## Error", error])
        }
        let content = sections.joined(separator: "\n")
        try content.write(to: item.url.appendingPathComponent("session.md"), atomically: true, encoding: .utf8)
        try writeRunArtifacts(result, to: item.url)

        let record = CaptureRecord(
            id: id,
            kind: .text,
            title: title,
            text: content,
            fileName: "session.md",
            sourceURL: nil,
            createdAt: result.endedAt,
            pixelWidth: nil,
            pixelHeight: nil,
            thumbnailFileName: nil,
            durationSeconds: nil,
            isSaved: true,
            isTrashed: false,
            containerFolderName: item.name,
            tags: ["session", "pi-agent"],
            itemDescription: cleanFinal.isEmpty ? result.error : String(cleanFinal.prefix(320)),
            space: .session
        )
        try insert(record, in: item.url)
        completed = true
        return record
    }

    @discardableResult
    func saveSession(notebook: ContextNotebook) throws -> CaptureRecord {
        try upsertSession(notebook: notebook, sessionID: nil)
    }

    func notebook(forSession sessionID: UUID) throws -> ContextNotebook {
        guard let record = records.first(where: {
            $0.id == sessionID && $0.space == .session && !$0.isTrashed
        }), let itemURL = itemFolderURL(for: record) else {
            throw CaptureStoreError.sessionNotebookUnavailable
        }
        let notebookURL = itemURL.appendingPathComponent("notebook.json")
        guard let data = try? Data(contentsOf: notebookURL),
              var notebook = try? JSONDecoder.curatez.decode(ContextNotebook.self, from: data) else {
            throw CaptureStoreError.sessionNotebookUnavailable
        }

        let latestOutputIndex = notebook.items.lastIndex(where: { $0.kind == .output && $0.run != nil })
        for index in notebook.items.indices where notebook.items[index].kind == .output {
            notebook.items[index].run?.messages = nil
            notebook.items[index].run?.events = nil
        }
        if let latestOutputIndex, var latestRun = notebook.items[latestOutputIndex].run {
            if latestRun.rounds == nil {
                latestRun.rounds = decodeArtifact(
                    [ContextRunRound].self,
                    named: "rounds.json",
                    in: itemURL
                )
            }
            if latestRun.usage == nil {
                latestRun.usage = decodeArtifact(
                    ContextRunUsage.self,
                    named: "usage.json",
                    in: itemURL
                )
            }
            notebook.items[latestOutputIndex].run = latestRun
        }

        // Transparently migrate older Sessions that duplicated large event logs
        // inside notebook.json. The canonical events/messages artifacts stay put.
        if data.count > 1_000_000,
           let compactData = try? JSONEncoder.curatez.encode(compactedNotebook(notebook)) {
            try? compactData.write(to: notebookURL, options: [.atomic])
        }
        return notebook
    }

    /// The agent transcript is intentionally kept outside the SwiftUI notebook
    /// value. It is loaded only when starting a continuation run.
    func continuationMessages(forSession sessionID: UUID?) -> [JSONValue]? {
        guard let sessionID,
              let record = records.first(where: {
                  $0.id == sessionID && $0.space == .session && !$0.isTrashed
              }),
              let itemURL = itemFolderURL(for: record) else {
            return nil
        }
        return decodeArtifact([JSONValue].self, named: "messages.json", in: itemURL)
    }

    /// Persist the editor into one stable Session record. A nil or stale id
    /// creates a Session; a live Session id updates that record in place.
    @discardableResult
    func upsertSession(notebook: ContextNotebook, sessionID: UUID?) throws -> CaptureRecord {
        if let sessionID,
           let index = records.firstIndex(where: {
               $0.id == sessionID && $0.space == .session && !$0.isTrashed
           }),
           let itemURL = itemFolderURL(for: records[index]) {
            let snapshot = notebookSessionSnapshot(for: notebook)
            try writeNotebookSession(notebook, snapshot: snapshot, to: itemURL)

            var updated = records[index]
            updated.kind = .text
            updated.title = snapshot.title
            updated.text = snapshot.content
            updated.fileName = "session.md"
            updated.isSaved = true
            updated.isTrashed = false
            updated.tags = ["session", "notebook"]
            updated.itemDescription = snapshot.description
            updated.space = .session
            try writeMetadata(updated, to: itemURL)
            records[index] = updated
            return updated
        }

        return try createNotebookSession(notebook)
    }

    private func createNotebookSession(_ notebook: ContextNotebook) throws -> CaptureRecord {
        let snapshot = notebookSessionSnapshot(for: notebook)
        let id = UUID()
        let item = try prepareItemFolder(id: id, title: snapshot.title)
        var completed = false
        defer { if !completed { try? fileManager.removeItem(at: item.url) } }

        try writeNotebookSession(notebook, snapshot: snapshot, to: item.url)
        let record = CaptureRecord(
            id: id,
            kind: .text,
            title: snapshot.title,
            text: snapshot.content,
            fileName: "session.md",
            sourceURL: nil,
            createdAt: Date(),
            pixelWidth: nil,
            pixelHeight: nil,
            thumbnailFileName: nil,
            durationSeconds: nil,
            isSaved: true,
            isTrashed: false,
            containerFolderName: item.name,
            tags: ["session", "notebook"],
            itemDescription: snapshot.description,
            space: .session
        )
        try insert(record, in: item.url)
        completed = true
        return record
    }

    private func notebookSessionSnapshot(for notebook: ContextNotebook) -> NotebookSessionSnapshot {
        let meaningfulItems = notebook.items.filter { $0.kind != .placeholder }
        let lastQuery = meaningfulItems.last(where: { $0.kind == .query })?.body
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let titleSeed = lastQuery.isEmpty ? "New Session" : lastQuery
        let title = String(titleSeed.replacingOccurrences(of: "\n", with: " ").prefix(72))

        var sections = ["# \(title)"]
        let configuredModel = notebook.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredModel.isEmpty {
            sections.append(contentsOf: ["", "- Model: \(configuredModel)"])
        }
        for notebookItem in meaningfulItems {
            let label = notebookItem.kind.rawValue.capitalized
            sections.append(contentsOf: ["", "## \(label)"])
            let itemTitle = notebookItem.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !itemTitle.isEmpty && itemTitle.localizedCaseInsensitiveCompare(label) != .orderedSame {
                sections.append("**\(itemTitle)**")
            }
            let detail = notebookItem.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty { sections.append(detail) }
            let body = notebookItem.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { sections.append(body) }
            if let run = notebookItem.run {
                if let model = run.model, !model.isEmpty { sections.append("Model: \(model)") }
                sections.append("Status: \(run.status)")
            }
        }

        let content = sections.joined(separator: "\n")
        let lastOutput = meaningfulItems.last(where: { $0.kind == .output })
        let descriptionSource = lastOutput?.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = descriptionSource?.isEmpty == false
            ? descriptionSource!
            : lastQuery
        return NotebookSessionSnapshot(
            title: title,
            content: content,
            description: description.isEmpty ? "Saved Context notebook" : String(description.prefix(320)),
            result: lastOutput?.run
        )
    }

    private func writeNotebookSession(
        _ notebook: ContextNotebook,
        snapshot: NotebookSessionSnapshot,
        to itemURL: URL
    ) throws {
        try snapshot.content.write(
            to: itemURL.appendingPathComponent("session.md"),
            atomically: true,
            encoding: .utf8
        )
        if let result = snapshot.result {
            try writeRunArtifacts(result, to: itemURL)
        } else {
            clearRunArtifacts(in: itemURL)
        }
        try JSONEncoder.curatez.encode(compactedNotebook(notebook)).write(
            to: itemURL.appendingPathComponent("notebook.json"),
            options: [.atomic]
        )
    }

    private func compactedNotebook(_ notebook: ContextNotebook) -> ContextNotebook {
        var compact = notebook
        for index in compact.items.indices where compact.items[index].kind == .output {
            compact.items[index].run?.messages = nil
            compact.items[index].run?.events = nil
        }
        return compact
    }

    private func decodeArtifact<Value: Decodable>(
        _ type: Value.Type,
        named fileName: String,
        in folderURL: URL
    ) -> Value? {
        guard let data = try? Data(contentsOf: folderURL.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder.curatez.decode(type, from: data)
    }

    private func clearRunArtifacts(in folderURL: URL) {
        for fileName in ["runtime-output.json", "messages.json", "events.json", "rounds.json", "usage.json"] {
            let url = folderURL.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func writeRunArtifacts(_ result: ContextRunResult, to folderURL: URL) throws {
        let encoder = JSONEncoder.curatez
        let runtimeOutputURL = folderURL.appendingPathComponent("runtime-output.json")
        if result.events != nil || !fileManager.fileExists(atPath: runtimeOutputURL.path) {
            try encoder.encode(result).write(to: runtimeOutputURL, options: [.atomic])
        }
        let messagesURL = folderURL.appendingPathComponent("messages.json")
        if let messages = result.messages {
            try encoder.encode(messages).write(to: messagesURL, options: [.atomic])
        } else if !fileManager.fileExists(atPath: messagesURL.path) {
            try encoder.encode([JSONValue]()).write(to: messagesURL, options: [.atomic])
        }
        let eventsURL = folderURL.appendingPathComponent("events.json")
        if let events = result.events {
            try encoder.encode(events).write(to: eventsURL, options: [.atomic])
        } else if !fileManager.fileExists(atPath: eventsURL.path) {
            try encoder.encode([ContextRunEvent]()).write(to: eventsURL, options: [.atomic])
        }
        try encoder.encode(result.rounds ?? []).write(
            to: folderURL.appendingPathComponent("rounds.json"),
            options: [.atomic]
        )
        if let usage = result.usage {
            try encoder.encode(usage).write(
                to: folderURL.appendingPathComponent("usage.json"),
                options: [.atomic]
            )
        }
    }

    @discardableResult
    func saveLink(_ url: URL) throws -> CaptureRecord {
        let displayHost = url.host()?.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        let path = url.path(percentEncoded: false)
        let displayPath = path == "/" ? "" : path
        let title = String((displayHost.map { $0 + displayPath } ?? url.absoluteString).prefix(72))
        let id = UUID()
        let item = try prepareItemFolder(id: id, title: title)
        var completed = false
        defer { if !completed { try? fileManager.removeItem(at: item.url) } }
        try writeSourceURLIfNeeded(url.absoluteString, into: item.url)

        let record = CaptureRecord(
            id: id, kind: .link,
            title: title, text: nil, fileName: nil, sourceURL: url.absoluteString,
            createdAt: Date(), pixelWidth: nil, pixelHeight: nil,
            thumbnailFileName: nil, durationSeconds: nil,
            isSaved: true, isTrashed: false, containerFolderName: item.name
        )
        try insert(record, in: item.url)
        completed = true
        return record
    }

    @discardableResult
    func saveVideoURL(_ url: URL) throws -> CaptureRecord {
        let title = videoTitle(for: url)
        let id = UUID()
        let item = try prepareItemFolder(id: id, title: title)
        var completed = false
        defer { if !completed { try? fileManager.removeItem(at: item.url) } }
        try writeSourceURLIfNeeded(url.absoluteString, into: item.url)

        let record = CaptureRecord(
            id: id, kind: .video,
            title: title, text: nil, fileName: nil, sourceURL: url.absoluteString,
            createdAt: Date(), pixelWidth: 16, pixelHeight: 9,
            thumbnailFileName: nil, durationSeconds: nil,
            isSaved: true, isTrashed: false, containerFolderName: item.name
        )
        try insert(record, in: item.url)
        completed = true
        return record
    }

    @discardableResult
    func importVideo(from sourceURL: URL) async throws -> CaptureRecord {
        let id = UUID()
        let title = sourceURL.deletingPathExtension().lastPathComponent
        let item = try prepareItemFolder(id: id, title: title)
        let fileExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension.lowercased()
        let fileName = "video.\(fileExtension)"
        let destinationURL = item.url.appendingPathComponent(fileName)
        var completed = false
        defer { if !completed { try? fileManager.removeItem(at: item.url) } }

        try await Task.detached {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }.value

        let asset = AVURLAsset(url: destinationURL)
        let loadedDuration = try await asset.load(.duration).seconds
        let duration = loadedDuration.isFinite && loadedDuration >= 0 ? loadedDuration : 0
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 1_600, height: 1_600)

        var thumbnailFileName: String?
        var pixelWidth: Double? = 16
        var pixelHeight: Double? = 9
        let thumbnailTime = CMTime(seconds: min(max(duration * 0.08, 0), 2), preferredTimescale: 600)
        if let result = try? await imageGenerator.image(at: thumbnailTime) {
            let image = result.image
            let name = "poster.png"
            let thumbnailURL = item.url.appendingPathComponent(name)
            let data = await Task.detached(priority: .userInitiated) {
                NSImage(
                    cgImage: image,
                    size: NSSize(width: image.width, height: image.height)
                ).pngData
            }.value
            if let data {
                try? await Task.detached(priority: .userInitiated) {
                    try data.write(to: thumbnailURL, options: .atomic)
                }.value
                thumbnailFileName = name
                pixelWidth = Double(image.width)
                pixelHeight = Double(image.height)
            }
        }

        let record = CaptureRecord(
            id: id, kind: .video,
            title: title, text: nil, fileName: fileName, sourceURL: nil,
            createdAt: Date(), pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            thumbnailFileName: thumbnailFileName, durationSeconds: duration > 0 ? duration : nil,
            isSaved: true, isTrashed: false, containerFolderName: item.name
        )
        try insert(record, in: item.url)
        completed = true
        return record
    }

    @discardableResult
    func saveImage(
        _ image: NSImage,
        kind: CaptureRecord.Kind = .image,
        title: String = "Copied image",
        sourceURL: String? = nil
    ) throws -> CaptureRecord {
        guard let data = image.pngData else { throw CaptureStoreError.imageEncodingFailed }

        let id = UUID()
        let item = try prepareItemFolder(id: id, title: title)
        var completed = false
        defer { if !completed { try? fileManager.removeItem(at: item.url) } }
        let fileName = kind == .browserSnapshot ? "snapshot.png" : "image.png"
        try data.write(to: item.url.appendingPathComponent(fileName), options: .atomic)
        try writeSourceURLIfNeeded(sourceURL, into: item.url)

        let record = CaptureRecord(
            id: id, kind: kind, title: title,
            text: nil, fileName: fileName, sourceURL: sourceURL,
            createdAt: Date(), pixelWidth: image.size.width, pixelHeight: image.size.height,
            thumbnailFileName: nil, durationSeconds: nil,
            isSaved: true, isTrashed: false, containerFolderName: item.name
        )
        try insert(record, in: item.url)
        completed = true
        return record
    }

    @discardableResult
    func saveSnapshot(_ image: CGImage, title: String, sourceURL: String?) async throws -> CaptureRecord {
        let pixelWidth = image.width
        let pixelHeight = image.height
        guard let data = await Task.detached(priority: .userInitiated, operation: {
            NSImage(
                cgImage: image,
                size: NSSize(width: pixelWidth, height: pixelHeight)
            ).pngData
        }).value else {
            throw CaptureStoreError.imageEncodingFailed
        }

        let id = UUID()
        let item = try prepareItemFolder(id: id, title: title)
        var completed = false
        defer { if !completed { try? fileManager.removeItem(at: item.url) } }
        let destinationURL = item.url.appendingPathComponent("snapshot.png")
        try await Task.detached(priority: .userInitiated) {
            try data.write(to: destinationURL, options: .atomic)
        }.value
        try writeSourceURLIfNeeded(sourceURL, into: item.url)

        let record = CaptureRecord(
            id: id, kind: .browserSnapshot, title: title,
            text: nil, fileName: "snapshot.png", sourceURL: sourceURL,
            createdAt: Date(), pixelWidth: Double(pixelWidth), pixelHeight: Double(pixelHeight),
            thumbnailFileName: nil, durationSeconds: nil,
            isSaved: true, isTrashed: false, containerFolderName: item.name
        )
        try insert(record, in: item.url)
        completed = true
        return record
    }

    func update(_ id: UUID, mutation: (inout CaptureRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var updatedRecord = records[index]
        mutation(&updatedRecord)
        guard let itemURL = itemFolderURL(for: updatedRecord) else { return }
        try? writeMetadata(updatedRecord, to: itemURL)
        records[index] = updatedRecord
    }

    func deleteRecord(_ id: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == id }),
              let itemURL = itemFolderURL(for: records[index]) else { return }
        var resultingURL: NSURL?
        try fileManager.trashItem(at: itemURL, resultingItemURL: &resultingURL)
        records.remove(at: index)
    }

    /// Permanently remove an editor-created Session draft. This intentionally does
    /// not use Trash: the record only exists as crash-safe run state until the user
    /// explicitly chooses to keep the Session.
    func discardSessionDraft(_ id: UUID) throws {
        guard let index = records.firstIndex(where: {
            $0.id == id && $0.space == .session
        }), let itemURL = itemFolderURL(for: records[index]) else { return }
        try fileManager.removeItem(at: itemURL)
        records.remove(at: index)
    }

    private func loadConfigurationOrBootstrap() {
        if let data = try? Data(contentsOf: configurationURL),
           let configuration = try? JSONDecoder.curatez.decode(CollectionConfiguration.self, from: data) {
            collections = configuration.folders
            selectedCollectionID = configuration.selectedFolderID.flatMap { selectedID in
                collections.contains(where: { $0.id == selectedID }) ? selectedID : nil
            } ?? collections.first?.id
            loadRecords()
            return
        }

        let libraryURL = rootURL.appendingPathComponent("Library", isDirectory: true)
        try? fileManager.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        let collection = CollectionFolder(id: UUID(), name: "Library", path: libraryURL.path)
        collections = [collection]
        selectedCollectionID = collection.id
        migrateLegacyRecords(into: libraryURL)
        persistConfiguration()
        loadRecords()
    }

    private func migrateLegacyRecords(into libraryURL: URL) {
        guard let data = try? Data(contentsOf: legacyRecordsURL),
              let legacyRecords = try? JSONDecoder.curatez.decode([CaptureRecord].self, from: data) else { return }

        for var record in legacyRecords {
            let folderName = record.id.uuidString
            let itemURL = libraryURL.appendingPathComponent(folderName, isDirectory: true)
            try? fileManager.createDirectory(at: itemURL, withIntermediateDirectories: true)
            record.containerFolderName = folderName

            if let fileName = record.fileName {
                let oldURL = rootURL.appendingPathComponent(fileName)
                let newURL = itemURL.appendingPathComponent(fileName)
                if fileManager.fileExists(atPath: oldURL.path), !fileManager.fileExists(atPath: newURL.path) {
                    try? fileManager.copyItem(at: oldURL, to: newURL)
                }
            } else if record.kind == .text, let text = record.text {
                record.fileName = "content.txt"
                try? text.write(to: itemURL.appendingPathComponent("content.txt"), atomically: true, encoding: .utf8)
            }

            if let thumbnailFileName = record.thumbnailFileName {
                let oldURL = rootURL.appendingPathComponent(thumbnailFileName)
                let newURL = itemURL.appendingPathComponent(thumbnailFileName)
                if fileManager.fileExists(atPath: oldURL.path), !fileManager.fileExists(atPath: newURL.path) {
                    try? fileManager.copyItem(at: oldURL, to: newURL)
                }
            }
            try? writeSourceURLIfNeeded(record.sourceURL, into: itemURL)
            try? writeMetadata(record, to: itemURL)
        }
    }

    private func loadRecords() {
        guard let collection = selectedCollection else {
            records = []
            return
        }
        let folder = folderURL(for: collection)
        guard let children = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            records = []
            return
        }

        let decoder = JSONDecoder.curatez
        var loadedRecords: [CaptureRecord] = []
        loadedRecords.reserveCapacity(children.count)
        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let data = try? Data(contentsOf: child.appendingPathComponent("metadata.json")),
                  var record = try? decoder.decode(CaptureRecord.self, from: data) else { continue }
            record.containerFolderName = child.lastPathComponent
            loadedRecords.append(record)
        }
        records = loadedRecords.sorted { $0.createdAt > $1.createdAt }
    }

    private func prepareItemFolder(id: UUID, title: String) throws -> (name: String, url: URL) {
        guard let collection = selectedCollection else { throw CaptureStoreError.noActiveCollection }
        let root = folderURL(for: collection)
        guard fileManager.fileExists(atPath: root.path) else { throw CaptureStoreError.collectionFolderUnavailable }
        let name = "\(sanitizedFolderComponent(title))-\(id.uuidString.prefix(8))"
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return (name, url)
    }

    private func itemFolderURL(for record: CaptureRecord) -> URL? {
        guard let collection = selectedCollection else { return nil }
        return folderURL(for: collection).appendingPathComponent(
            record.containerFolderName ?? record.id.uuidString,
            isDirectory: true
        )
    }

    private func insert(_ record: CaptureRecord, in itemURL: URL) throws {
        try writeMetadata(record, to: itemURL)
        records.insert(record, at: 0)
    }

    private func writeMetadata(_ record: CaptureRecord, to itemURL: URL) throws {
        let data = try JSONEncoder.curatez.encode(record)
        try data.write(to: itemURL.appendingPathComponent("metadata.json"), options: .atomic)
    }

    private func writeSourceURLIfNeeded(_ sourceURL: String?, into itemURL: URL) throws {
        guard let sourceURL, !sourceURL.isEmpty else { return }
        try sourceURL.write(to: itemURL.appendingPathComponent("source.url.txt"), atomically: true, encoding: .utf8)
    }

    private func persistConfiguration() {
        let configuration = CollectionConfiguration(folders: collections, selectedFolderID: selectedCollectionID)
        guard let data = try? JSONEncoder.curatez.encode(configuration) else { return }
        try? data.write(to: configurationURL, options: .atomic)
    }

    private func sodaSystemPromptSourceURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "soda-engineering-system", withExtension: "md") {
            return bundled
        }
        let development = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/soda-engineering-system.md")
        return fileManager.fileExists(atPath: development.path) ? development : nil
    }

    private func justOneAPIContextsSourceURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "justoneapi-contexts", withExtension: "json") {
            return bundled
        }
        let development = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/justoneapi-contexts.json")
        return fileManager.fileExists(atPath: development.path) ? development : nil
    }

    private func sanitizedFolderComponent(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\n\r\t").union(.controlCharacters)
        let parts = value.components(separatedBy: forbidden).filter { !$0.isEmpty }
        let joined = parts.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return String((joined.isEmpty ? "Item" : joined).prefix(48))
    }

    private func removePreviousCoverFiles(for record: CaptureRecord, keeping fileNames: Set<String>) {
        guard let itemURL = itemFolderURL(for: record) else { return }
        for fileName in [record.coverFileName, record.coverThumbnailFileName].compactMap({ $0 })
            where !fileNames.contains(fileName) {
            try? fileManager.removeItem(at: itemURL.appendingPathComponent(fileName))
        }
    }

    private func isSafeDeletionTarget(_ url: URL) -> Bool {
        let target = url.standardizedFileURL
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        let protected = [
            URL(fileURLWithPath: "/", isDirectory: true),
            home,
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Library", isDirectory: true)
        ].map(\.standardizedFileURL)
        return !protected.contains(target) && target.pathComponents.count >= 4
    }

    private func videoTitle(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent.removingPercentEncoding
        if let name, !name.isEmpty { return name }
        return url.host() ?? "Video"
    }

    private func detailTabKind(for url: URL) -> CaptureDetailTab.Kind {
        if url.pathExtension.lowercased() == "md" { return .markdown }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .file }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return .video }
        if type.conforms(to: .plainText) { return .plainText }
        return .file
    }

    private func originalContextContent(for record: CaptureRecord) -> String {
        switch record.kind {
        case .text:
            if let text = originalTextContent(for: record) { return text }
            return "(Empty)"
        case .link:
            if let text = record.text, !text.isEmpty { return text }
            return record.sourceURL ?? "(Empty)"
        case .image, .browserSnapshot:
            if let fileURL = fileURL(for: record) { return "[Image] \(fileURL.path)" }
            return record.sourceURL.map { "[Image] \($0)" } ?? "[Image unavailable]"
        case .video:
            if let fileURL = fileURL(for: record) { return "[Video] \(fileURL.path)" }
            return record.sourceURL.map { "[Video] \($0)" } ?? "[Video unavailable]"
        }
    }

}

enum CaptureStoreError: LocalizedError {
    case noActiveCollection
    case collectionFolderUnavailable
    case collectionFolderNotWritable
    case invalidCollectionName
    case collectionNameAlreadyExists
    case unsafeCollectionDeletion
    case imageEncodingFailed
    case videoCoverGenerationFailed
    case invalidItemTitle
    case invalidDetailTabName
    case invalidDetailTabType
    case workingDirectoryUnavailable
    case sessionNotebookUnavailable
    case sessionArtifactsUnavailable

    var errorDescription: String? {
        switch self {
        case .noActiveCollection: "请先通过顶部的 + 选择一个收藏文件夹。"
        case .collectionFolderUnavailable: "收藏文件夹不存在或无法访问。"
        case .collectionFolderNotWritable: "所选文件夹不可写。"
        case .invalidCollectionName: "文件夹名称不能为空，也不能包含 / 或 :。"
        case .collectionNameAlreadyExists: "同级目录中已经存在同名文件夹。"
        case .unsafeCollectionDeletion: "为保护数据，不能把系统目录或常用主目录作为可删除的收藏标签。"
        case .imageEncodingFailed: "图片编码失败。"
        case .videoCoverGenerationFailed: "无法从这个视频生成封面预览。"
        case .invalidItemTitle: "Title 不能为空。"
        case .invalidDetailTabName: "内容 Tab 名称不能为空。"
        case .invalidDetailTabType: "图片、视频和其他文件请使用导入文件。"
        case .workingDirectoryUnavailable: "所选工作目录不存在或无法访问。"
        case .sessionNotebookUnavailable: "这个 Session 缺少可编辑的 notebook 数据。"
        case .sessionArtifactsUnavailable: "这个 Session 的 Artifacts 目录不可用。"
        }
    }
}

extension JSONEncoder {
    static var curatez: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var curatez: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension NSImage {
    var pngData: Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
