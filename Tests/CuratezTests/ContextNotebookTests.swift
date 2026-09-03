import Foundation
import XCTest
@testable import Curatez

final class ContextNotebookTests: XCTestCase {
    func testLiveRunEventBatcherPreservesTextAndStructuralOrder() throws {
        func delta(_ text: String, time: String = "2026-08-31T00:00:00Z") -> ContextRunEvent {
            ContextRunEvent(
                type: "message_update",
                time: time,
                data: .object([
                    "type": .string("message_update"),
                    "assistantMessageEvent": .object([
                        "type": .string("text_delta"),
                        "contentIndex": .number(0),
                        "delta": .string(text)
                    ])
                ]),
                parentToolCallId: nil
            )
        }

        let ended = ContextRunEvent(
            type: "message_end",
            time: "2026-08-31T00:00:01Z",
            data: .object(["type": .string("message_end")]),
            parentToolCallId: nil
        )
        var batcher = ContextRunEventBatcher()
        XCTAssertTrue(batcher.consume(delta("Hello"), now: 0).isEmpty)
        XCTAssertTrue(batcher.consume(delta(", "), now: 0.01).isEmpty)
        let emitted = batcher.consume(delta("world"), now: 0.02) + batcher.consume(ended, now: 0.03)

        XCTAssertEqual(emitted.count, 2)
        XCTAssertEqual(emitted[1], ended)
        guard case .object(let data) = emitted[0].data,
              case .object(let update) = data["assistantMessageEvent"],
              case .string(let text) = update["delta"] else {
            return XCTFail("Expected one compact text delta")
        }
        XCTAssertEqual(text, "Hello, world")
    }

    func testFxModelSettingsLoadsStringsObjectsAndDefaultModel() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CuratezFxModelSettings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"""
        {
          "defaultModel": "deepseek/deepseek-v4-flash",
          "models": [
            "deepseek/deepseek-v4-flash",
            { "provider": "bailian", "model": "qwen3.7-max", "name": "Qwen Max" },
            {
              "spec": "anthropic/claude-sonnet",
              "name": "Claude Sonnet",
              "reasoningEfforts": ["low", "high", "max"]
            }
          ]
        }
        """#.utf8).write(to: url)

        let settings = FxModelSettings.load(from: url)

        XCTAssertEqual(settings.defaultModel, "deepseek/deepseek-v4-flash")
        XCTAssertEqual(settings.models.map(\.spec), [
            "deepseek/deepseek-v4-flash",
            "bailian/qwen3.7-max",
            "anthropic/claude-sonnet"
        ])
        XCTAssertEqual(settings.models[1].name, "Qwen Max")
        XCTAssertEqual(settings.models[2].reasoningEfforts, [.low, .high, .max])
        XCTAssertEqual(settings.resolvedModel(explicitModel: ""), "deepseek/deepseek-v4-flash")
        XCTAssertEqual(settings.resolvedModel(explicitModel: "anthropic/claude-sonnet"), "anthropic/claude-sonnet")
    }

    func testReasoningEffortPersistsAndExportsToRuntime() throws {
        let query = ContextNotebookItem(kind: .query, body: "Solve this carefully")
        let notebook = ContextNotebook(
            title: "Reasoning",
            model: "sub2api/gpt-5.6-sol",
            reasoning: .xhigh,
            items: [query]
        )
        let encoded = try JSONEncoder.curatez.encode(notebook)
        let decoded = try JSONDecoder.curatez.decode(ContextNotebook.self, from: encoded)
        XCTAssertEqual(decoded.reasoning, .xhigh)

        let payload = ContextRuntimePayload(
            notebook: decoded,
            collectionURL: FileManager.default.temporaryDirectory,
            records: [],
            contexts: [:],
            mediaURLs: [:]
        )
        let data = try ContextPiRunner.makeRuntimeNotebook(payload, queryID: query.id)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let agent = try XCTUnwrap((json["cells"] as? [[String: Any]])?.first)
        XCTAssertEqual(agent["reasoning"] as? String, "xhigh")
    }

    func testFreshQueryHasNoPresetTitleOrContent() {
        let notebook = ContextNotebook.fresh(title: "Context")
        let query = notebook.items.first(where: { $0.kind == .query })
        let system = notebook.items.first(where: { $0.kind == .system })

        XCTAssertEqual(query?.title, "")
        XCTAssertEqual(query?.body, "")
        XCTAssertEqual(system?.title, "Default System Prompt")
    }

    func testVersionOnePresetQueryTitleMigratesToEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CuratezQueryMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var notebook = ContextNotebook.fresh(title: "Context")
        notebook.version = 1
        notebook.items = [ContextNotebookItem(kind: .query, title: "Query", body: "Editable question")]
        try JSONEncoder.curatez.encode(notebook).write(
            to: ContextNotebookRepository.url(in: root),
            options: [.atomic]
        )

        let migrated = try ContextNotebookRepository.load(from: root, title: "Context")
        XCTAssertEqual(migrated.version, 4)
        XCTAssertEqual(migrated.items.first?.title, "")
        XCTAssertEqual(migrated.items.first?.body, "Editable question")
    }

    func testVersionTwoQueryTitleBecomesContentWhenBodyIsEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CuratezSingleQueryFieldTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var notebook = ContextNotebook.fresh(title: "Context")
        notebook.version = 2
        notebook.items = [ContextNotebookItem(kind: .query, title: "What changed?")]
        try JSONEncoder.curatez.encode(notebook).write(
            to: ContextNotebookRepository.url(in: root),
            options: [.atomic]
        )

        let migrated = try ContextNotebookRepository.load(from: root, title: "Context")
        XCTAssertEqual(migrated.version, 4)
        XCTAssertEqual(migrated.items.first?.title, "")
        XCTAssertEqual(migrated.items.first?.body, "What changed?")
    }

    func testVersionThreeDefaultSystemTitleMigratesWithoutRenamingCustomPrompts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CuratezSystemTitleMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var notebook = ContextNotebook.fresh(title: "Context")
        notebook.version = 3
        notebook.items = [
            ContextNotebookItem(
                kind: .system,
                title: "System",
                body: ContextNotebook.defaultSystemBody
            ),
            ContextNotebookItem(kind: .system, title: "System", body: "A custom prompt")
        ]
        try JSONEncoder.curatez.encode(notebook).write(
            to: ContextNotebookRepository.url(in: root),
            options: [.atomic]
        )

        let migrated = try ContextNotebookRepository.load(from: root, title: "Context")
        XCTAssertEqual(migrated.version, 4)
        XCTAssertEqual(migrated.items[0].title, "Default System Prompt")
        XCTAssertEqual(migrated.items[1].title, "System")
    }

    func testNotebookPersistsAndExportsCuratezAgentSchema() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CuratezNotebookTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var notebook = ContextNotebook.fresh(title: "Research Context")
        notebook.items.insert(
            ContextNotebookItem(kind: .context, title: "Reference", body: "Verified source material"),
            at: 1
        )
        notebook.items[2].body = "Summarize the reference."
        try ContextNotebookRepository.save(notebook, to: root)

        let reloaded = try ContextNotebookRepository.load(from: root, title: "Ignored")
        XCTAssertEqual(reloaded, notebook)

        let payload = ContextRuntimePayload(
            notebook: reloaded,
            collectionURL: root,
            records: [],
            contexts: [:],
            mediaURLs: [:]
        )
        let data = try ContextPiRunner.makeRuntimeNotebook(payload, queryID: reloaded.items[2].id)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let topCells = try XCTUnwrap(json["cells"] as? [[String: Any]])
        let agent = try XCTUnwrap(topCells.first)
        let cells = try XCTUnwrap(agent["cells"] as? [[String: Any]])

        XCTAssertEqual(agent["type"] as? String, "agent")
        XCTAssertEqual(cells.compactMap { $0["type"] as? String }, ["system", "context", "query"])
        XCTAssertEqual((cells.last?["content"] as? [[String: String]])?.first?["text"], "Summarize the reference.")
    }

    func testSubagentExportsCompletePiDefinition() throws {
        let query = ContextNotebookItem(kind: .query, body: "Investigate this")
        let subagent = ContextNotebookItem(
            kind: .subagent,
            title: "scout",
            body: "Return verified facts.",
            detail: "Research focused questions",
            tools: ["read", "search"],
            skills: ["research"],
            model: "anthropic/claude-sonnet",
            fork: true
        )
        let notebook = ContextNotebook(title: "Subagent", model: "", items: [subagent, query])
        let payload = ContextRuntimePayload(
            notebook: notebook,
            collectionURL: FileManager.default.temporaryDirectory,
            records: [],
            contexts: [:],
            mediaURLs: [:]
        )

        let data = try ContextPiRunner.makeRuntimeNotebook(payload, queryID: query.id)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let agent = try XCTUnwrap((json["cells"] as? [[String: Any]])?.first)
        let cell = try XCTUnwrap((agent["cells"] as? [[String: Any]])?.first)

        XCTAssertEqual(cell["type"] as? String, "subagent")
        XCTAssertEqual(cell["name"] as? String, "scout")
        XCTAssertEqual(cell["description"] as? String, "Research focused questions")
        XCTAssertEqual(cell["system"] as? String, "Return verified facts.")
        XCTAssertEqual(cell["tools"] as? [String], ["read", "search"])
        XCTAssertEqual(cell["skills"] as? [String], ["research"])
        XCTAssertEqual(cell["model"] as? String, "anthropic/claude-sonnet")
        XCTAssertEqual(cell["fork"] as? Bool, true)
    }

    func testReferencedImageContentExportsAsAnImageAttachment() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CuratezCoverContextTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordID = UUID()
        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let imageURL = root.appendingPathComponent("original-image.png")
        try imageData.write(to: imageURL)
        let query = ContextNotebookItem(kind: .query, title: "Query", body: "Describe the cover")
        let notebook = ContextNotebook(
            title: "Cover Context",
            model: "",
            items: [
                ContextNotebookItem(kind: .context, title: "Saved item", sourceRecordID: recordID),
                query
            ]
        )
        let payload = ContextRuntimePayload(
            notebook: notebook,
            collectionURL: root,
            records: [],
            contexts: [recordID: "Saved item context"],
            mediaURLs: [recordID: imageURL]
        )

        let data = try ContextPiRunner.makeRuntimeNotebook(payload, queryID: query.id)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let topCells = try XCTUnwrap(json["cells"] as? [[String: Any]])
        let agent = try XCTUnwrap(topCells.first)
        let cells = try XCTUnwrap(agent["cells"] as? [[String: Any]])
        let context = try XCTUnwrap(cells.first(where: { ($0["type"] as? String) == "context" }))
        let attachments = try XCTUnwrap(context["attachments"] as? [[String: Any]])
        let attachment = try XCTUnwrap(attachments.first)

        XCTAssertEqual(attachment["mediaType"] as? String, "image/png")
        XCTAssertEqual(attachment["data"] as? String, imageData.base64EncodedString())
        XCTAssertEqual(attachment["name"] as? String, "original-image.png")
    }

    func testQueryImagePersistsAndExportsAsMultimodalContent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CuratezQueryImageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let attachment = ContextNotebookAttachment(
            name: "pasted-image-1.png",
            mediaType: "image/png",
            data: imageData
        )
        let query = ContextNotebookItem(
            kind: .query,
            body: "Describe this image",
            attachments: [attachment]
        )
        let notebook = ContextNotebook(title: "Multimodal", model: "", items: [query])
        try ContextNotebookRepository.save(notebook, to: root)

        let reloaded = try ContextNotebookRepository.load(from: root, title: "Ignored")
        XCTAssertEqual(reloaded.items.first?.attachments, [attachment])
        XCTAssertTrue(try XCTUnwrap(reloaded.items.first).hasQueryContent)

        let payload = ContextRuntimePayload(
            notebook: reloaded,
            collectionURL: root,
            records: [],
            contexts: [:],
            mediaURLs: [:]
        )
        let data = try ContextPiRunner.makeRuntimeNotebook(payload, queryID: query.id)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let topCells = try XCTUnwrap(json["cells"] as? [[String: Any]])
        let agent = try XCTUnwrap(topCells.first)
        let cells = try XCTUnwrap(agent["cells"] as? [[String: Any]])
        let exportedQuery = try XCTUnwrap(cells.first(where: { ($0["type"] as? String) == "query" }))
        let content = try XCTUnwrap(exportedQuery["content"] as? [[String: Any]])

        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "Describe this image")
        XCTAssertEqual(content[1]["type"] as? String, "image")
        XCTAssertEqual(content[1]["mediaType"] as? String, "image/png")
        XCTAssertEqual(content[1]["data"] as? String, imageData.base64EncodedString())
    }

    func testImageOnlyQueryCountsAsRunnableContent() {
        let query = ContextNotebookItem(
            kind: .query,
            attachments: [ContextNotebookAttachment(
                name: "image.png",
                mediaType: "image/png",
                data: Data([1, 2, 3])
            )]
        )

        XCTAssertTrue(query.hasQueryContent)
    }

    func testContextItemUsesItsPreviewSnapshotBeforeLiveRecordContext() throws {
        let recordID = UUID()
        let query = ContextNotebookItem(kind: .query, body: "Answer from context")
        let notebook = ContextNotebook(
            title: "Context snapshot",
            model: "",
            items: [
                ContextNotebookItem(
                    kind: .context,
                    title: "Saved item",
                    body: "Exact Context Preview snapshot",
                    sourceRecordID: recordID
                ),
                query
            ]
        )
        let payload = ContextRuntimePayload(
            notebook: notebook,
            collectionURL: FileManager.default.temporaryDirectory,
            records: [],
            contexts: [recordID: "Newer live record value"],
            mediaURLs: [:]
        )

        let data = try ContextPiRunner.makeRuntimeNotebook(payload, queryID: query.id)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let agent = try XCTUnwrap((json["cells"] as? [[String: Any]])?.first)
        let cells = try XCTUnwrap(agent["cells"] as? [[String: Any]])
        let context = try XCTUnwrap(cells.first(where: { ($0["type"] as? String) == "context" }))

        XCTAssertEqual(context["content"] as? String, "Exact Context Preview snapshot")
    }

    func testRuntimeNotebookCarriesCompleteOutputAndAllQueryRoundsForResume() throws {
        let firstQuery = ContextNotebookItem(kind: .query, body: "First question")
        let secondQuery = ContextNotebookItem(kind: .query, body: "Follow up")
        let messages: [JSONValue] = [
            .object([
                "role": .string("user"),
                "content": .array([.object(["type": .string("text"), "text": .string("First question")])])
            ]),
            .object([
                "role": .string("assistant"),
                "content": .array([.object([
                    "type": .string("toolCall"),
                    "id": .string("call-1"),
                    "name": .string("echo"),
                    "arguments": .object(["text": .string("fact")])
                ])])
            ]),
            .object([
                "role": .string("toolResult"),
                "toolCallId": .string("call-1"),
                "toolName": .string("echo"),
                "content": .array([.object(["type": .string("text"), "text": .string("fact")])])
            ])
        ]
        let result = ContextRunResult(
            runID: "run-1",
            status: "completed",
            runtime: "pi",
            model: "deepseek/deepseek-v4-flash",
            final: "First answer",
            usage: ContextRunUsage(
                input: 10,
                output: 5,
                cacheRead: 2,
                cacheWrite: 1,
                reasoning: 3,
                totalTokens: 21,
                cost: ContextRunCost(input: 0.1, output: 0.2, cacheRead: 0.01, cacheWrite: 0.02, total: 0.33)
            ),
            rounds: [ContextRunRound(
                index: 1,
                queryCellId: firstQuery.id.uuidString.lowercased(),
                final: "First answer",
                steps: [ContextRunStep(
                    type: "tool-call",
                    text: nil,
                    id: "call-1",
                    name: "echo",
                    arguments: .object(["text": .string("fact")]),
                    isError: nil
                )],
                startedAt: "2026-08-30T00:00:00Z",
                endedAt: "2026-08-30T00:00:01Z"
            )],
            messages: nil,
            events: [ContextRunEvent(
                type: "tool_execution_end",
                time: "2026-08-30T00:00:01Z",
                data: .object(["toolName": .string("echo")]),
                parentToolCallId: nil
            )],
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101)
        )
        let output = ContextNotebookItem(kind: .output, title: "Output", body: result.final, run: result)
        let notebook = ContextNotebook(title: "Resume", model: "", items: [firstQuery, output, secondQuery])
        let payload = ContextRuntimePayload(
            notebook: notebook,
            collectionURL: FileManager.default.temporaryDirectory,
            records: [],
            contexts: [:],
            mediaURLs: [:],
            continuationMessages: messages
        )

        let data = try ContextPiRunner.makeRuntimeNotebook(payload, queryID: secondQuery.id)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let topCells = try XCTUnwrap(json["cells"] as? [[String: Any]])
        let agent = try XCTUnwrap(topCells.first(where: { ($0["type"] as? String) == "agent" }))
        let outputJSON = try XCTUnwrap(topCells.first(where: { ($0["type"] as? String) == "output" }))
        let agentCells = try XCTUnwrap(agent["cells"] as? [[String: Any]])

        XCTAssertEqual(agentCells.filter { ($0["type"] as? String) == "query" }.count, 2)
        XCTAssertEqual(outputJSON["runId"] as? String, "run-1")
        XCTAssertEqual((outputJSON["messages"] as? [Any])?.count, messages.count)
        XCTAssertEqual(((outputJSON["rounds"] as? [[String: Any]])?.first)?["final"] as? String, "First answer")
        XCTAssertEqual(((outputJSON["usage"] as? [String: Any])?["totalTokens"] as? NSNumber)?.intValue, 21)
    }

    func testMultipleOutputsRemainInNotebookAndNewestOutputDrivesContinuation() throws {
        let firstQuery = ContextNotebookItem(kind: .query, body: "First question")
        let secondQuery = ContextNotebookItem(kind: .query, body: "Second question")
        let thirdQuery = ContextNotebookItem(kind: .query, body: "Third question")
        let firstRun = ContextRunResult(
            runID: "run-1",
            status: "completed",
            runtime: "pi",
            model: "deepseek/deepseek-v4-flash",
            final: "First answer",
            rounds: [ContextRunRound(
                index: 1,
                queryCellId: firstQuery.id.uuidString.lowercased(),
                final: "First answer",
                startedAt: "2026-08-30T00:00:00Z",
                endedAt: "2026-08-30T00:00:01Z"
            )],
            messages: [.object(["role": .string("assistant"), "content": .string("First answer")])],
            events: [],
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101)
        )
        let secondRun = ContextRunResult(
            runID: "run-2",
            status: "completed",
            runtime: "pi",
            model: "deepseek/deepseek-v4-flash",
            final: "Second answer",
            rounds: [
                ContextRunRound(
                    index: 1,
                    queryCellId: firstQuery.id.uuidString.lowercased(),
                    final: "First answer",
                    startedAt: "2026-08-30T00:00:00Z",
                    endedAt: "2026-08-30T00:00:01Z"
                ),
                ContextRunRound(
                    index: 2,
                    queryCellId: secondQuery.id.uuidString.lowercased(),
                    final: "Second answer",
                    startedAt: "2026-08-30T00:00:02Z",
                    endedAt: "2026-08-30T00:00:03Z"
                )
            ],
            messages: [.object(["role": .string("assistant"), "content": .string("Second answer")])],
            events: [],
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 103)
        )
        let firstOutput = ContextNotebookItem(kind: .output, title: "Output", body: firstRun.final, run: firstRun)
        let secondOutput = ContextNotebookItem(kind: .output, title: "Output", body: secondRun.final, run: secondRun)
        let notebook = ContextNotebook(
            title: "Multiple Outputs",
            model: "",
            items: [firstQuery, firstOutput, secondQuery, secondOutput, thirdQuery]
        )
        let payload = ContextRuntimePayload(
            notebook: notebook,
            collectionURL: FileManager.default.temporaryDirectory,
            records: [],
            contexts: [:],
            mediaURLs: [:]
        )

        let data = try ContextPiRunner.makeRuntimeNotebook(payload, queryID: thirdQuery.id)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let topCells = try XCTUnwrap(json["cells"] as? [[String: Any]])
        let runtimeOutput = try XCTUnwrap(topCells.first(where: { ($0["type"] as? String) == "output" }))
        let agent = try XCTUnwrap(topCells.first(where: { ($0["type"] as? String) == "agent" }))
        let agentCells = try XCTUnwrap(agent["cells"] as? [[String: Any]])

        XCTAssertEqual(notebook.items.filter { $0.kind == .output }.count, 2)
        XCTAssertEqual(topCells.filter { ($0["type"] as? String) == "output" }.count, 1)
        XCTAssertEqual(runtimeOutput["runId"] as? String, "run-2")
        XCTAssertEqual(runtimeOutput["final"] as? String, "Second answer")
        XCTAssertEqual(agentCells.filter { ($0["type"] as? String) == "query" }.count, 3)
        XCTAssertEqual(ContextOutputPresentation.rounds(for: firstOutput, in: notebook.items).map(\.final), ["First answer"])
        XCTAssertEqual(ContextOutputPresentation.rounds(for: secondOutput, in: notebook.items).map(\.final), ["Second answer"])
        let roundsByItem = ContextOutputPresentation.roundsByItem(in: notebook.items)
        XCTAssertEqual(roundsByItem[firstOutput.id]?.map(\.final), ["First answer"])
        XCTAssertEqual(roundsByItem[secondOutput.id]?.map(\.final), ["Second answer"])
    }

    func testMarkdownParserPreservesBlockStructureAndInlineContent() {
        let markdown = """
        # Heading

        A paragraph with **bold** text.

        - first item
          - nested item
        1. ordered item

        > quoted text

        ```swift
        let answer = 42
        ```

        ---
        """

        XCTAssertEqual(ContextMarkdownParser.parse(markdown), [
            .heading(level: 1, text: "Heading"),
            .paragraph("A paragraph with **bold** text."),
            .unordered(indent: 0, text: "first item"),
            .unordered(indent: 1, text: "nested item"),
            .ordered(indent: 0, marker: "1.", text: "ordered item"),
            .quote("quoted text"),
            .code(language: "swift", text: "let answer = 42"),
            .divider
        ])
    }

    func testMarkdownParserRecognizesGFMTableRowsAndAlignment() {
        let markdown = """
        线上统计：

        | 指标 | 数量 | 备注 |
        |:---|---:|:---:|
        | Active Connection | 155 | **healthy** |
        | Rank 覆盖率 | 8.71% | `partial` |

        完成。
        """

        XCTAssertEqual(ContextMarkdownParser.parse(markdown), [
            .paragraph("线上统计："),
            .table(
                headers: ["指标", "数量", "备注"],
                alignments: [.leading, .trailing, .center],
                rows: [
                    ["Active Connection", "155", "**healthy**"],
                    ["Rank 覆盖率", "8.71%", "`partial`"]
                ]
            ),
            .paragraph("完成。")
        ])
    }

    func testToolPresentationUsesSpecializedMinimalSummaries() {
        let bash = ContextToolPresentation.make(
            name: "bash",
            payload: .object([
                "command": .string("swift test"),
                "timeout": .number(30)
            ]),
            fallbackText: "",
            isResult: false
        )
        XCTAssertEqual(bash.family, .bash)
        XCTAssertEqual(bash.action, "Run")
        XCTAssertEqual(bash.summary, "$ swift test")
        XCTAssertEqual(bash.metadata, "timeout 30s")

        let bashResult = ContextToolPresentation.make(
            name: "bash",
            payload: nil,
            fallbackText: "first\nsecond\nthird\nfourth",
            isResult: true
        )
        XCTAssertEqual(bashResult.result, "first\nsecond …")

        let read = ContextToolPresentation.make(
            name: "read",
            payload: .object([
                "path": .string("Sources/App.swift"),
                "offset": .number(20),
                "limit": .number(10)
            ]),
            fallbackText: "",
            isResult: false
        )
        XCTAssertEqual(read.family, .read)
        XCTAssertEqual(read.summary, "Sources/App.swift")
        XCTAssertEqual(read.metadata, "lines 20–29")

        let edit = ContextToolPresentation.make(
            name: "edit",
            payload: .object([
                "path": .string("Sources/App.swift"),
                "edits": .array([
                    .object(["oldText": .string("let old = true"), "newText": .string("let new = true")]),
                    .object(["oldText": .string("remove()"), "newText": .string("replace()")])
                ])
            ]),
            fallbackText: "",
            isResult: false
        )
        XCTAssertEqual(edit.family, .edit)
        XCTAssertEqual(edit.action, "Edit")
        XCTAssertEqual(edit.metadata, "2 changes")
        XCTAssertEqual(edit.diff.rows, [
            ContextToolDiffRow(
                old: ContextToolDiffCell(kind: .removal, lineNumber: 1, text: "let old = true"),
                new: ContextToolDiffCell(kind: .addition, lineNumber: 1, text: "let new = true")
            ),
            ContextToolDiffRow(
                old: ContextToolDiffCell(kind: .ellipsis, lineNumber: nil, text: "…"),
                new: ContextToolDiffCell(kind: .ellipsis, lineNumber: nil, text: "…")
            ),
            ContextToolDiffRow(
                old: ContextToolDiffCell(kind: .removal, lineNumber: 2, text: "remove()"),
                new: ContextToolDiffCell(kind: .addition, lineNumber: 2, text: "replace()")
            )
        ])
        XCTAssertEqual(edit.diff.removalCount, 2)
        XCTAssertEqual(edit.diff.additionCount, 2)

        let write = ContextToolPresentation.make(
            name: "write",
            payload: .object(["path": .string("tmp.txt"), "content": .string("hello\nworld")]),
            fallbackText: "",
            isResult: false
        )
        XCTAssertEqual(write.summary, "tmp.txt")
        XCTAssertEqual(write.diff.rows, [
            ContextToolDiffRow(
                old: nil,
                new: ContextToolDiffCell(kind: .addition, lineNumber: 1, text: "hello")
            ),
            ContextToolDiffRow(
                old: nil,
                new: ContextToolDiffCell(kind: .addition, lineNumber: 2, text: "world")
            )
        ])

        let completedEdit = ContextToolPresentation.make(
            name: "edit",
            payload: .object([
                "path": .string("Sources/App.swift"),
                "oldText": .string("return old"),
                "newText": .string("return new")
            ]),
            fallbackText: "",
            isResult: false,
            resultPayload: .object([
                "diff": .string(" 9 let value = true\n-10 return old\n+10 return new\n 11 }")
            ])
        )
        XCTAssertEqual(completedEdit.diff.rows, [
            ContextToolDiffRow(
                old: ContextToolDiffCell(kind: .unchanged, lineNumber: 9, text: "let value = true"),
                new: ContextToolDiffCell(kind: .unchanged, lineNumber: 9, text: "let value = true")
            ),
            ContextToolDiffRow(
                old: ContextToolDiffCell(kind: .removal, lineNumber: 10, text: "return old"),
                new: ContextToolDiffCell(kind: .addition, lineNumber: 10, text: "return new")
            ),
            ContextToolDiffRow(
                old: ContextToolDiffCell(kind: .unchanged, lineNumber: 11, text: "}"),
                new: ContextToolDiffCell(kind: .unchanged, lineNumber: 11, text: "}")
            )
        ])

        let result = ContextToolPresentation.make(
            name: "bash",
            payload: .object([
                "content": .array([.object(["type": .string("text"), "text": .string("29 tests passed")])])
            ]),
            fallbackText: "",
            isResult: true
        )
        XCTAssertEqual(result.result, "29 tests passed")

        let readResult = ContextToolPresentation.make(
            name: "read",
            payload: .object([
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string("A very large file body that must not be rendered")
                ])])
            ]),
            fallbackText: "A very large file body that must not be rendered",
            isResult: true
        )
        XCTAssertEqual(readResult.visibleResult(isRunning: false, isError: false), "Successfully")
        XCTAssertEqual(readResult.visibleResult(isRunning: false, isError: true), "Failed")
        XCTAssertEqual(readResult.visibleResult(isRunning: true, isError: false), "Reading…")

        let persistedEditResult = ContextToolPresentation.make(
            name: "edit",
            payload: .object(["diff": .string("-1 hello world\n+1 你好")]),
            fallbackText: "Successfully replaced 1 block(s) in tmp.txt.",
            isResult: true
        )
        XCTAssertEqual(persistedEditResult.result, "Successfully replaced 1 block(s) in tmp.txt.")
    }

    func testLiveToolCallAndResultMergeIntoOneActivityEntry() {
        var activity = ContextLiveActivity()
        activity.apply(ContextRunEvent(
            type: "tool_execution_start",
            time: "2026-08-30T00:00:00Z",
            data: .object([
                "toolCallId": .string("call-1"),
                "toolName": .string("write"),
                "args": .object(["path": .string("tmp.txt"), "content": .string("hello")])
            ]),
            parentToolCallId: nil
        ))
        activity.apply(ContextRunEvent(
            type: "tool_execution_end",
            time: "2026-08-30T00:00:01Z",
            data: .object([
                "toolCallId": .string("call-1"),
                "toolName": .string("write"),
                "result": .object([
                    "content": .array([.object(["type": .string("text"), "text": .string("Successfully wrote 5 bytes")])])
                ]),
                "isError": .bool(false)
            ]),
            parentToolCallId: nil
        ))

        XCTAssertEqual(activity.entries.count, 1)
        XCTAssertEqual(activity.entries[0].kind, .toolCall)
        XCTAssertEqual(activity.entries[0].toolCallID, "call-1")
        XCTAssertEqual(activity.entries[0].resultDetail, "Successfully wrote 5 bytes")
        XCTAssertFalse(activity.entries[0].isResultRunning)
    }

    @MainActor
    func testCompletedRunIsSavedAsReloadableSessionItem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CuratezSessionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = CaptureStore(rootURL: root)
        let messages: [JSONValue] = [
            .object(["role": .string("user"), "content": .array([.object(["type": .string("text"), "text": .string("What matters?")])])]),
            .object(["role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string("A concise answer grounded in the supplied context.")])])])
        ]
        let result = ContextRunResult(
            runID: "persisted-run",
            status: "completed",
            runtime: "pi",
            model: "deepseek/deepseek-v4-flash",
            error: nil,
            final: "A concise answer grounded in the supplied context.",
            totalTokens: 144,
            usage: ContextRunUsage(input: 100, output: 44, cacheRead: nil, cacheWrite: nil, reasoning: nil, totalTokens: 144, cost: nil),
            rounds: [ContextRunRound(index: 1, queryCellId: "query-1", final: "A concise answer grounded in the supplied context.", steps: [], startedAt: "2026-08-30T00:00:00Z", endedAt: "2026-08-30T00:00:01Z")],
            messages: messages,
            events: [ContextRunEvent(type: "agent_end", time: "2026-08-30T00:00:01Z", data: .object([:]), parentToolCallId: nil)],
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 110)
        )
        let session = try store.saveSession(query: "What matters?", result: result)

        XCTAssertEqual(session.space, .session)
        XCTAssertEqual(session.tags, ["session", "pi-agent"])
        XCTAssertTrue(try XCTUnwrap(store.originalTextContent(for: session)).contains("## Query\nWhat matters?"))
        XCTAssertTrue(try XCTUnwrap(store.originalTextContent(for: session)).contains("## Output"))

        let reloaded = CaptureStore(rootURL: root)
        let saved = try XCTUnwrap(reloaded.records.first(where: { $0.id == session.id }))
        XCTAssertEqual(saved.space, .session)
        XCTAssertEqual(saved.itemDescription, "A concise answer grounded in the supplied context.")
        let folder = try XCTUnwrap(store.containerURL(for: saved))
        let persistedMessages = try JSONDecoder.curatez.decode(
            [JSONValue].self,
            from: Data(contentsOf: folder.appendingPathComponent("messages.json"))
        )
        XCTAssertEqual(persistedMessages, messages)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("runtime-output.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("events.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("rounds.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("usage.json").path))
    }

    @MainActor
    func testSavedSessionReloadsItsEditableNotebook() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CuratezEditableSession-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let query = ContextNotebookItem(kind: .query, body: "Inspect this project")
        let notebook = ContextNotebook(
            title: "Editable",
            model: "deepseek/deepseek-v4-flash",
            items: [query]
        )
        let store = CaptureStore(rootURL: root)
        let session = try store.saveSession(notebook: notebook)

        XCTAssertEqual(try store.notebook(forSession: session.id), notebook)

        let reloaded = CaptureStore(rootURL: root)
        XCTAssertEqual(try reloaded.notebook(forSession: session.id), notebook)
    }

    @MainActor
    func testNotebookExternalizesHeavyEventsAndContinuationMessages() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CuratezCompactSession-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let messages: [JSONValue] = [
            .object(["role": .string("assistant"), "content": .string("continue me")])
        ]
        let events = [ContextRunEvent(
            type: "tool_execution_end",
            time: "2026-08-31T00:00:00Z",
            data: .object(["output": .string(String(repeating: "x", count: 200_000))]),
            parentToolCallId: nil
        )]
        let result = ContextRunResult(
            runID: "heavy-run",
            status: "completed",
            final: "Done",
            rounds: [],
            messages: messages,
            events: events,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101)
        )
        let notebook = ContextNotebook(
            title: "Heavy",
            model: "",
            items: [ContextNotebookItem(kind: .output, title: "Output", body: "Done", run: result)]
        )
        let store = CaptureStore(rootURL: root)
        let session = try store.saveSession(notebook: notebook)
        let folder = try XCTUnwrap(store.containerURL(for: session))
        let notebookData = try Data(contentsOf: folder.appendingPathComponent("notebook.json"))
        let persistedEvents = try JSONDecoder.curatez.decode(
            [ContextRunEvent].self,
            from: Data(contentsOf: folder.appendingPathComponent("events.json"))
        )

        XCTAssertLessThan(notebookData.count, 20_000)
        XCTAssertEqual(persistedEvents, events)

        let reloaded = CaptureStore(rootURL: root)
        let editable = try reloaded.notebook(forSession: session.id)
        XCTAssertNil(editable.items.last?.run?.messages)
        XCTAssertNil(editable.items.last?.run?.events)
        XCTAssertEqual(reloaded.continuationMessages(forSession: session.id), messages)
    }

    @MainActor
    func testSavingFreshEditorsCreatesIndependentSessionItems() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CuratezIndependentSessions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = CaptureStore(rootURL: root)
        var first = ContextNotebook.fresh(title: "First")
        first.items[first.items.count - 1].body = "First independent query"
        var second = ContextNotebook.fresh(title: "Second")
        second.items[second.items.count - 1].body = "Second independent query"

        let firstRecord = try store.saveSession(notebook: first)
        let secondRecord = try store.saveSession(notebook: second)

        XCTAssertNotEqual(firstRecord.id, secondRecord.id)
        XCTAssertEqual(store.records.filter { $0.space == .session }.count, 2)
        XCTAssertTrue(try XCTUnwrap(store.originalTextContent(for: firstRecord)).contains("First independent query"))
        XCTAssertTrue(try XCTUnwrap(store.originalTextContent(for: secondRecord)).contains("Second independent query"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try XCTUnwrap(store.containerURL(for: firstRecord))
                .appendingPathComponent("notebook.json").path
        ))
    }

    @MainActor
    func testUpsertingAnActiveSessionUpdatesTheSameRecordAndTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CuratezSessionUpsertTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = CaptureStore(rootURL: root)
        var notebook = ContextNotebook.fresh(title: "Auto Save")
        notebook.items[notebook.items.count - 1].body = "First query"
        let created = try store.upsertSession(notebook: notebook, sessionID: nil)
        let originalFolder = try XCTUnwrap(store.containerURL(for: created))

        let messages: [JSONValue] = [
            .object(["role": .string("user"), "content": .array([.object(["type": .string("text"), "text": .string("First query")])])]),
            .object(["role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string("Updated answer")])])])
        ]
        let result = ContextRunResult(
            runID: "same-run",
            status: "completed",
            runtime: "pi",
            model: "deepseek/deepseek-v4-flash",
            final: "Updated answer",
            messages: messages,
            events: [],
            startedAt: Date(timeIntervalSince1970: 200),
            endedAt: Date(timeIntervalSince1970: 201)
        )
        notebook.items.append(ContextNotebookItem(kind: .output, title: "Output", body: result.final, run: result))

        let updated = try store.upsertSession(notebook: notebook, sessionID: created.id)

        XCTAssertEqual(updated.id, created.id)
        XCTAssertEqual(store.records.filter { $0.space == .session }.count, 1)
        XCTAssertEqual(store.containerURL(for: updated), originalFolder)
        XCTAssertEqual(updated.itemDescription, "Updated answer")
        let persistedMessages = try JSONDecoder.curatez.decode(
            [JSONValue].self,
            from: Data(contentsOf: originalFolder.appendingPathComponent("messages.json"))
        )
        XCTAssertEqual(persistedMessages, messages)
        let persistedNotebook = try JSONDecoder.curatez.decode(
            ContextNotebook.self,
            from: Data(contentsOf: originalFolder.appendingPathComponent("notebook.json"))
        )
        XCTAssertNil(persistedNotebook.items.last?.run?.messages)
        XCTAssertNil(persistedNotebook.items.last?.run?.events)
        let editableNotebook = try store.notebook(forSession: updated.id)
        XCTAssertNil(editableNotebook.items.last?.run?.messages)
        XCTAssertNil(editableNotebook.items.last?.run?.events)
        XCTAssertEqual(store.continuationMessages(forSession: updated.id), messages)
    }

    @MainActor
    func testSessionArtifactsWorkspaceIsCreatedInsideItsSessionFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CuratezSessionArtifactsWorkspace-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = CaptureStore(rootURL: root)
        let session = try store.upsertSession(
            notebook: ContextNotebook.fresh(title: "New Session"),
            sessionID: nil
        )
        let sessionURL = try XCTUnwrap(store.containerURL(for: session))
        let artifactsURL = try store.artifactsDirectoryURL(forSession: session.id)

        XCTAssertEqual(artifactsURL.deletingLastPathComponent(), sessionURL)
        XCTAssertEqual(artifactsURL.lastPathComponent, "Artifacts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactsURL.path))
    }

    func testRunCancellationRecordsAStopRequest() {
        let cancellation = ContextRunCancellation()
        XCTAssertFalse(cancellation.isCancellationRequested)

        cancellation.cancel()

        XCTAssertTrue(cancellation.isCancellationRequested)
    }
}
