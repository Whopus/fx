import Foundation
import UniformTypeIdentifiers

enum ContextCellKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case context
    case tool
    case skill
    case subagent
    case query
    case output
    case placeholder

    var id: Self { self }
}

struct ContextRunCost: Codable, Equatable, Sendable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double
    var total: Double
}

struct ContextRunUsage: Codable, Equatable, Sendable {
    var input: Int?
    var output: Int?
    var cacheRead: Int?
    var cacheWrite: Int?
    var reasoning: Int?
    var totalTokens: Int?
    var cost: ContextRunCost?
}

struct ContextRunEvent: Codable, Equatable, Sendable {
    var type: String
    var time: String
    var data: JSONValue
    var parentToolCallId: String?
}

struct ContextRunStep: Codable, Equatable, Sendable {
    var type: String
    var text: String?
    var id: String?
    var name: String?
    var arguments: JSONValue?
    var details: JSONValue? = nil
    var isError: Bool?
}

struct ContextRunRound: Codable, Equatable, Sendable {
    var index: Int
    var queryCellId: String
    var final: String
    var steps: [ContextRunStep]?
    var startedAt: String
    var endedAt: String
}

struct ContextRunResult: Codable, Equatable, Sendable {
    var runID: String?
    var status: String
    var runtime: String?
    var model: String?
    var error: String?
    var final: String
    var totalTokens: Int?
    var usage: ContextRunUsage?
    var rounds: [ContextRunRound]?
    var messages: [JSONValue]?
    var events: [ContextRunEvent]?
    var startedAt: Date
    var endedAt: Date

    init(
        runID: String? = nil,
        status: String,
        runtime: String? = nil,
        model: String? = nil,
        error: String? = nil,
        final: String,
        totalTokens: Int? = nil,
        usage: ContextRunUsage? = nil,
        rounds: [ContextRunRound]? = nil,
        messages: [JSONValue]? = nil,
        events: [ContextRunEvent]? = nil,
        startedAt: Date,
        endedAt: Date
    ) {
        self.runID = runID
        self.status = status
        self.runtime = runtime
        self.model = model
        self.error = error
        self.final = final
        self.totalTokens = totalTokens ?? usage?.totalTokens
        self.usage = usage
        self.rounds = rounds
        self.messages = messages
        self.events = events
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "runId"
        case status, runtime, model, error, final, totalTokens, usage, rounds, messages, events, startedAt, endedAt
    }
}

struct ContextNotebookAttachment: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var mediaType: String
    var data: Data

    init(
        id: UUID = UUID(),
        name: String,
        mediaType: String,
        data: Data
    ) {
        self.id = id
        self.name = name
        self.mediaType = mediaType
        self.data = data
    }
}

struct ContextNotebookItem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var kind: ContextCellKind
    var title: String
    var body: String
    var detail: String
    var sourceRecordID: UUID?
    var run: ContextRunResult?
    var tools: [String]?
    var skills: [String]?
    var model: String?
    var fork: Bool?
    var attachments: [ContextNotebookAttachment]?

    init(
        id: UUID = UUID(),
        kind: ContextCellKind,
        title: String = "",
        body: String = "",
        detail: String = "",
        sourceRecordID: UUID? = nil,
        run: ContextRunResult? = nil,
        tools: [String]? = nil,
        skills: [String]? = nil,
        model: String? = nil,
        fork: Bool? = nil,
        attachments: [ContextNotebookAttachment]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.detail = detail
        self.sourceRecordID = sourceRecordID
        self.run = run
        self.tools = tools
        self.skills = skills
        self.model = model
        self.fork = fork
        self.attachments = attachments
    }

    var hasQueryContent: Bool {
        guard kind == .query else { return false }
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return attachments?.contains(where: {
            $0.mediaType.hasPrefix("image/") && !$0.data.isEmpty
        }) == true
    }
}

/// A run result intentionally keeps cumulative rounds so a later query can resume the
/// complete agent conversation. Each output card, however, should only render the rounds
/// introduced by that run.
enum ContextOutputPresentation {
    static func rounds(for item: ContextNotebookItem, in items: [ContextNotebookItem]) -> [ContextRunRound] {
        guard item.kind == .output,
              let currentRounds = item.run?.rounds,
              !currentRounds.isEmpty,
              let itemIndex = items.firstIndex(where: { $0.id == item.id }) else {
            return []
        }

        let previousRounds = items[..<itemIndex]
            .reversed()
            .first(where: { $0.kind == .output && $0.run != nil })?
            .run?.rounds ?? []
        guard !previousRounds.isEmpty else { return currentRounds }

        let previousKeys = Set(previousRounds.map(roundKey))
        return currentRounds.filter { !previousKeys.contains(roundKey($0)) }
    }

    private static func roundKey(_ round: ContextRunRound) -> String {
        "\(round.index)\u{1F}\(round.queryCellId)\u{1F}\(round.startedAt)"
    }
}

struct ContextNotebook: Codable, Equatable, Sendable {
    static let fileName = ".curatez-context.json"
    static let defaultSystemTitle = "Default System Prompt"
    static let defaultSystemBody = "You are a thoughtful AI assistant. Use the supplied context faithfully and make uncertainty explicit."

    var version = 4
    var id = UUID()
    var title: String
    var model: String
    var reasoning: FxReasoningEffort? = nil
    var items: [ContextNotebookItem]

    static func fresh(title: String) -> Self {
        ContextNotebook(
            title: title,
            model: "",
            reasoning: .low,
            items: [
                ContextNotebookItem(
                    kind: .system,
                    title: defaultSystemTitle,
                    body: defaultSystemBody
                ),
                ContextNotebookItem(kind: .query)
            ]
        )
    }
}

enum FxReasoningEffort: String, Codable, CaseIterable, Identifiable, Sendable {
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "X-High"
        case .max: "Max"
        }
    }
}

struct FxModelOption: Identifiable, Equatable, Sendable {
    let spec: String
    let name: String
    let reasoningEfforts: [FxReasoningEffort]

    init(spec: String, name: String, reasoningEfforts: [FxReasoningEffort] = []) {
        self.spec = spec
        self.name = name
        self.reasoningEfforts = reasoningEfforts
    }

    var id: String { spec }
}

struct FxModelSettings: Equatable, Sendable {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".fx/settings.json")

    var defaultModel: String?
    var models: [FxModelOption]

    static let empty = FxModelSettings(defaultModel: nil, models: [])
    static let runtimeDefaults = FxModelSettings(
        defaultModel: "sub2api/gpt-5.6-sol",
        models: [
            FxModelOption(
                spec: "sub2api/gpt-5.6-sol",
                name: "GPT-5.6 Sol",
                reasoningEfforts: FxReasoningEffort.allCases
            ),
            FxModelOption(spec: "deepseek/deepseek-v4-flash", name: "DeepSeek V4 Flash"),
            FxModelOption(spec: "deepseek/deepseek-v4-pro", name: "DeepSeek V4 Pro"),
            FxModelOption(spec: "bailian/qwen3.7-flash", name: "Qwen 3.7 Flash (百炼)"),
            FxModelOption(spec: "bailian/qwen3.7-max", name: "Qwen 3.7 Max (百炼)")
        ]
    )

    static func load(from url: URL = fileURL) -> FxModelSettings {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return url.standardizedFileURL == fileURL.standardizedFileURL ? .runtimeDefaults : .empty
        }

        let defaultModel = clean(file.defaultModel) ?? runtimeDefaults.defaultModel
        var seen = Set<String>()
        var models = file.models.compactMap { entry -> FxModelOption? in
            guard let spec = entry.resolvedSpec, seen.insert(spec).inserted else { return nil }
            return FxModelOption(
                spec: spec,
                name: clean(entry.name) ?? spec,
                reasoningEfforts: entry.reasoningEfforts ?? []
            )
        }
        if let defaultModel, seen.insert(defaultModel).inserted {
            let fallback = runtimeDefaults.models.first(where: { $0.spec == defaultModel })
            models.insert(
                FxModelOption(
                    spec: defaultModel,
                    name: fallback?.name ?? defaultModel,
                    reasoningEfforts: fallback?.reasoningEfforts ?? []
                ),
                at: 0
            )
        }
        return FxModelSettings(defaultModel: defaultModel, models: models)
    }

    func resolvedModel(explicitModel: String) -> String? {
        Self.clean(explicitModel) ?? defaultModel
    }

    func displayName(for spec: String) -> String {
        models.first(where: { $0.spec == spec })?.name
            ?? Self.runtimeDefaults.models.first(where: { $0.spec == spec })?.name
            ?? spec
    }

    private static func clean(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? nil : cleaned
    }

    private struct File: Decodable {
        var defaultModel: String?
        var models: [Entry]

        private enum CodingKeys: String, CodingKey {
            case defaultModel
            case models
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel)
            models = try container.decodeIfPresent([Entry].self, forKey: .models) ?? []
        }
    }

    private struct Entry: Decodable {
        var spec: String?
        var id: String?
        var model: String?
        var provider: String?
        var name: String?
        var reasoningEfforts: [FxReasoningEffort]?

        var resolvedSpec: String? {
            if let spec = FxModelSettings.clean(spec) { return spec }
            let modelID = FxModelSettings.clean(model) ?? FxModelSettings.clean(id)
            guard let modelID else { return nil }
            if modelID.contains("/") { return modelID }
            guard let provider = FxModelSettings.clean(provider) else { return modelID }
            return "\(provider)/\(modelID)"
        }

        private enum CodingKeys: String, CodingKey {
            case spec
            case id
            case model
            case provider
            case name
            case reasoningEfforts
        }

        init(from decoder: Decoder) throws {
            if let value = try? decoder.singleValueContainer().decode(String.self) {
                spec = value
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            spec = try container.decodeIfPresent(String.self, forKey: .spec)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            provider = try container.decodeIfPresent(String.self, forKey: .provider)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            reasoningEfforts = try container.decodeIfPresent([FxReasoningEffort].self, forKey: .reasoningEfforts)
        }
    }
}

enum ContextNotebookRepository {
    static func url(in collectionURL: URL) -> URL {
        collectionURL.appendingPathComponent(ContextNotebook.fileName)
    }

    static func load(from collectionURL: URL, title: String) throws -> ContextNotebook {
        let fileURL = url(in: collectionURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .fresh(title: title)
        }
        var notebook = try JSONDecoder.curatez.decode(ContextNotebook.self, from: Data(contentsOf: fileURL))
        if notebook.version < 2 {
            // Version 1 populated every Query title with the type name. Query has no
            // preset title: keep "Query" only as the sidebar/field placeholder.
            for index in notebook.items.indices
                where notebook.items[index].kind == .query && notebook.items[index].title == "Query" {
                notebook.items[index].title = ""
            }
            notebook.version = 2
        }
        if notebook.version < 3 {
            // Query is a single editable content field. Preserve an old custom title
            // as the query itself only when no body had been entered yet.
            for index in notebook.items.indices where notebook.items[index].kind == .query {
                let oldTitle = notebook.items[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
                let body = notebook.items[index].body.trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty && !oldTitle.isEmpty && oldTitle != "Query" {
                    notebook.items[index].body = oldTitle
                }
                notebook.items[index].title = ""
            }
            notebook.version = 3
        }
        if notebook.version < 4 {
            // Rename only Curatez's untouched built-in prompt. User-authored System
            // titles and prompts must remain exactly as they were saved.
            for index in notebook.items.indices where
                notebook.items[index].kind == .system &&
                notebook.items[index].sourceRecordID == nil &&
                notebook.items[index].title == "System" &&
                notebook.items[index].body == ContextNotebook.defaultSystemBody {
                notebook.items[index].title = ContextNotebook.defaultSystemTitle
            }
            notebook.version = 4
        }
        return notebook
    }

    static func save(_ notebook: ContextNotebook, to collectionURL: URL) throws {
        try JSONEncoder.curatez.encode(notebook).write(
            to: url(in: collectionURL),
            options: [.atomic]
        )
    }
}

enum ContextNotebookError: LocalizedError {
    case noQuery
    case runtimeNotFound
    case nodeNotFound
    case malformedOutput
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .noQuery:
            "请先添加一个非空的 Query Cell。"
        case .runtimeNotFound:
            "找不到 Curatez 内置 Agent Runtime。请重新构建 Curatez.app。"
        case .nodeNotFound:
            "找不到 Node.js。Curatez Agent Runtime 需要 Node.js 22.19 或更高版本。"
        case .malformedOutput:
            "pi agent 已结束，但没有生成可读取的 Output Cell。"
        case .launchFailed(let message):
            "无法运行 pi agent：\(message)"
        }
    }
}

struct ContextRuntimePayload: Sendable {
    let notebook: ContextNotebook
    let collectionURL: URL
    let records: [CaptureRecord]
    let contexts: [UUID: String]
    let mediaURLs: [UUID: URL]
}

enum ContextPiRunner {
    static func run(
        _ payload: ContextRuntimePayload,
        onEvent: @escaping @MainActor @Sendable (ContextRunEvent) -> Void = { _ in }
    ) async throws -> ContextRunResult {
        let query = payload.notebook.items.last {
            $0.hasQueryContent
        }
        guard let query else { throw ContextNotebookError.noQuery }

        let runtimeCLI = try findRuntimeCLI()
        let nodeURL = try findNode()
        let runID = UUID().uuidString.lowercased()
        let notebookURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("curatez-\(runID).runtime.json")
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("curatez-\(runID).log")
        let eventLogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("curatez-\(runID).events.ndjson")

        let data = try makeRuntimeNotebook(payload, queryID: query.id)
        try data.write(to: notebookURL, options: [.atomic])
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)

        defer {
            try? FileManager.default.removeItem(at: notebookURL)
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: eventLogURL)
        }

        let process = Process()
        process.executableURL = nodeURL
        var arguments = [
            runtimeCLI.path,
            "run",
            notebookURL.path,
            "--agent",
            "curatez-agent",
            "--event-log",
            eventLogURL.path,
            "--event-stream"
        ]
        if payload.notebook.items.contains(where: { $0.kind == .output && $0.run?.messages?.isEmpty == false }) {
            arguments.append("--continue")
        }
        arguments += FxModelSettings.load().resolvedModel(explicitModel: payload.notebook.model).map {
            ["--model", $0]
        } ?? []
        process.arguments = arguments
        process.currentDirectoryURL = payload.collectionURL
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = logHandle

        let eventTask = Task {
            do {
                for try await line in outputPipe.fileHandleForReading.bytes.lines {
                    guard let data = line.data(using: .utf8),
                          let event = try? JSONDecoder.curatez.decode(ContextRunEvent.self, from: data) else {
                        continue
                    }
                    await onEvent(event)
                }
            } catch {
                // Process termination closes stdout. A complete run is decoded
                // from the notebook below, so a pipe-close error is non-fatal.
            }
        }

        let status: Int32
        do {
            status = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { completed in
                    continuation.resume(returning: completed.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            eventTask.cancel()
            try? outputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            throw error
        }
        try? outputPipe.fileHandleForWriting.close()
        await eventTask.value
        try? outputPipe.fileHandleForReading.close()
        try? logHandle.close()

        if let result = try? decodeResult(from: notebookURL) {
            return result
        }
        let log = (try? String(contentsOf: logURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if status != 0 || !log.isEmpty {
            throw ContextNotebookError.launchFailed(log.isEmpty ? "进程退出码 \(status)" : log)
        }
        throw ContextNotebookError.malformedOutput
    }

    static func makeRuntimeNotebook(_ payload: ContextRuntimePayload, queryID: UUID) throws -> Data {
        var cells: [[String: Any]] = []
        let queryIndex = payload.notebook.items.firstIndex(where: { $0.id == queryID }) ?? payload.notebook.items.endIndex
        for (index, item) in payload.notebook.items.enumerated() {
            guard item.kind != .output, item.kind != .placeholder else { continue }
            if item.kind == .query {
                if index > queryIndex { continue }
                if !item.hasQueryContent { continue }
            }

            let id = item.id.uuidString.lowercased()
            switch item.kind {
            case .system:
                guard !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                cells.append(["id": id, "type": "system", "content": item.body])
            case .context:
                var context: [String: Any] = ["id": id, "type": "context"]
                let resolved = item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? item.sourceRecordID.flatMap { payload.contexts[$0] } ?? ""
                    : item.body
                if !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    context["content"] = resolved
                }
                if let recordID = item.sourceRecordID,
                   let mediaURL = payload.mediaURLs[recordID],
                   let attachment = attachment(from: mediaURL) {
                    context["attachments"] = [attachment]
                }
                cells.append(context)
            case .query:
                var content: [[String: Any]] = []
                if !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    content.append(["type": "text", "text": item.body])
                }
                for attachment in item.attachments ?? []
                    where attachment.mediaType.hasPrefix("image/") && !attachment.data.isEmpty {
                    content.append([
                        "type": "image",
                        "mediaType": attachment.mediaType,
                        "data": attachment.data.base64EncodedString(),
                        "name": attachment.name
                    ])
                }
                cells.append([
                    "id": id,
                    "type": "query",
                    "content": content
                ])
            case .tool:
                cells.append([
                    "id": id,
                    "type": "tool",
                    "name": item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    "description": item.detail
                ])
            case .skill:
                cells.append([
                    "id": id,
                    "type": "skill",
                    "name": item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    "description": item.detail,
                    "instructions": item.body
                ])
            case .subagent:
                var subagent: [String: Any] = [
                    "id": id,
                    "type": "subagent",
                    "name": item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    "description": item.detail,
                    "system": item.body,
                    "fork": item.fork ?? false
                ]
                if let tools = item.tools, !tools.isEmpty { subagent["tools"] = tools }
                if let skills = item.skills, !skills.isEmpty { subagent["skills"] = skills }
                if let model = item.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
                    subagent["model"] = model
                }
                cells.append(subagent)
            case .output, .placeholder:
                break
            }
        }

        let agent: [String: Any] = [
            "id": "curatez-agent",
            "type": "agent",
            "name": payload.notebook.title,
            "toolExecution": "parallel",
            "reasoning": (payload.notebook.reasoning ?? .low).rawValue,
            "cells": cells
        ]
        let root: [String: Any] = [
            "version": 1,
            "id": payload.notebook.id.uuidString.lowercased(),
            "title": payload.notebook.title,
            "cells": [agent] + (try previousRuntimeOutput(from: payload.notebook).map { [$0] } ?? [])
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static func previousRuntimeOutput(from notebook: ContextNotebook) throws -> [String: Any]? {
        guard let result = notebook.items.last(where: { $0.kind == .output && $0.run != nil })?.run else {
            return nil
        }
        var output: [String: Any] = [
            "id": "curatez-agent:output",
            "type": "output",
            "forAgent": "curatez-agent",
            "runId": result.runID ?? UUID().uuidString.lowercased(),
            "status": result.status,
            "final": result.final,
            "events": try jsonObject(result.events ?? []),
            "startedAt": ISO8601DateFormatter().string(from: result.startedAt),
            "endedAt": ISO8601DateFormatter().string(from: result.endedAt)
        ]
        if let runtime = result.runtime { output["runtime"] = runtime }
        if let model = result.model { output["model"] = model }
        if let error = result.error { output["error"] = error }
        if let rounds = result.rounds { output["rounds"] = try jsonObject(rounds) }
        if let messages = result.messages { output["messages"] = try jsonObject(messages) }
        if let usage = result.usage { output["usage"] = try jsonObject(usage) }
        return output
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder.curatez.encode(value))
    }

    private static func attachment(from url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        let mediaType = type?.preferredMIMEType ?? "application/octet-stream"
        guard mediaType.hasPrefix("image/") else { return nil }
        return [
            "id": UUID().uuidString.lowercased(),
            "name": url.lastPathComponent,
            "mediaType": mediaType,
            "data": data.base64EncodedString(),
            "size": data.count
        ]
    }

    private static func findRuntimeCLI() throws -> URL {
        let manager = FileManager.default
        var candidates: [URL] = []
        if let configured = ProcessInfo.processInfo.environment["CURATEZ_RUNTIME_PATH"] {
            let url = URL(fileURLWithPath: configured)
            candidates.append(url.hasDirectoryPath ? url.appendingPathComponent("dist/cli.js") : url)
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("CuratezRuntime/dist/cli.js"))
        }
        candidates.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Runtime/dist/cli.js")
        )
        candidates.append(
            URL(fileURLWithPath: manager.currentDirectoryPath)
                .appendingPathComponent("Runtime/dist/cli.js")
        )
        guard let runtime = candidates.first(where: { manager.fileExists(atPath: $0.path) }) else {
            throw ContextNotebookError.runtimeNotFound
        }
        return runtime
    }

    private static func findNode() throws -> URL {
        let manager = FileManager.default
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        guard let path = candidates.first(where: manager.isExecutableFile(atPath:)) else {
            throw ContextNotebookError.nodeNotFound
        }
        return URL(fileURLWithPath: path)
    }

    private static func decodeResult(from url: URL) throws -> ContextRunResult {
        let notebook = try JSONDecoder().decode(RuntimeRunNotebook.self, from: Data(contentsOf: url))
        guard let output = notebook.cells.last(where: { $0.type == "output" }) else {
            throw ContextNotebookError.malformedOutput
        }
        return ContextRunResult(
            runID: output.runID,
            status: output.status ?? "failed",
            runtime: output.runtime,
            model: output.model,
            error: output.error,
            final: output.final ?? "",
            totalTokens: output.usage?.totalTokens,
            usage: output.usage,
            rounds: output.rounds,
            messages: output.messages,
            events: output.events,
            startedAt: ISO8601DateFormatter().date(from: output.startedAt ?? "") ?? Date(),
            endedAt: ISO8601DateFormatter().date(from: output.endedAt ?? "") ?? Date()
        )
    }
}

private struct RuntimeRunNotebook: Decodable {
    let cells: [RuntimeRunCell]
}

private struct RuntimeRunCell: Decodable {
    let type: String
    let runID: String?
    let status: String?
    let runtime: String?
    let model: String?
    let error: String?
    let final: String?
    let usage: ContextRunUsage?
    let rounds: [ContextRunRound]?
    let messages: [JSONValue]?
    let events: [ContextRunEvent]?
    let startedAt: String?
    let endedAt: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case runID = "runId"
        case status, runtime, model, error, final, usage, rounds, messages, events, startedAt, endedAt
    }
}
