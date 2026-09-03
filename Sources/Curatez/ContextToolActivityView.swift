import Foundation
import SwiftUI

enum ContextToolFamily: Equatable {
    case bash
    case read
    case edit
    case write
    case search
    case web
    case subagent
    case skill
    case generic
}

struct ContextToolDiffCell: Equatable {
    enum Kind: Equatable {
        case unchanged
        case addition
        case removal
        case ellipsis
    }

    let kind: Kind
    let lineNumber: Int?
    let text: String
}

struct ContextToolDiffRow: Equatable {
    let old: ContextToolDiffCell?
    let new: ContextToolDiffCell?
}

struct ContextToolDiffDocument: Equatable {
    let rows: [ContextToolDiffRow]
    let removalCount: Int
    let additionCount: Int

    static let empty = ContextToolDiffDocument(rows: [], removalCount: 0, additionCount: 0)

    static func writing(_ content: String) -> ContextToolDiffDocument {
        let lines = content.components(separatedBy: "\n")
        return ContextToolDiffDocument(
            rows: lines.enumerated().map { index, text in
                ContextToolDiffRow(
                    old: nil,
                    new: ContextToolDiffCell(kind: .addition, lineNumber: index + 1, text: text)
                )
            },
            removalCount: 0,
            additionCount: lines.count
        )
    }

    static func replacing(_ replacements: [([String], [String])]) -> ContextToolDiffDocument {
        var rows: [ContextToolDiffRow] = []
        var oldLineNumber = 1
        var newLineNumber = 1
        var removalCount = 0
        var additionCount = 0

        for (replacementIndex, replacement) in replacements.enumerated() {
            if replacementIndex > 0 {
                rows.append(ContextToolDiffRow(
                    old: ContextToolDiffCell(kind: .ellipsis, lineNumber: nil, text: "…"),
                    new: ContextToolDiffCell(kind: .ellipsis, lineNumber: nil, text: "…")
                ))
            }

            let (oldLines, newLines) = replacement
            let rowCount = max(oldLines.count, newLines.count)
            for index in 0..<rowCount {
                let oldCell: ContextToolDiffCell?
                if index < oldLines.count {
                    oldCell = ContextToolDiffCell(
                        kind: .removal,
                        lineNumber: oldLineNumber,
                        text: oldLines[index]
                    )
                    oldLineNumber += 1
                    removalCount += 1
                } else {
                    oldCell = nil
                }

                let newCell: ContextToolDiffCell?
                if index < newLines.count {
                    newCell = ContextToolDiffCell(
                        kind: .addition,
                        lineNumber: newLineNumber,
                        text: newLines[index]
                    )
                    newLineNumber += 1
                    additionCount += 1
                } else {
                    newCell = nil
                }
                rows.append(ContextToolDiffRow(old: oldCell, new: newCell))
            }
        }

        return ContextToolDiffDocument(
            rows: rows,
            removalCount: removalCount,
            additionCount: additionCount
        )
    }

    static func parsingDisplayDiff(_ diff: String) -> ContextToolDiffDocument {
        struct ParsedLine {
            let marker: Character
            let lineNumber: Int?
            let text: String
            let isEllipsis: Bool
        }

        func parse(_ line: String) -> ParsedLine? {
            guard let marker = line.first, marker == "+" || marker == "-" || marker == " " else {
                return nil
            }
            var remainder = line.dropFirst()
            while remainder.first == " " { remainder = remainder.dropFirst() }
            if remainder == "..." || remainder == "…" {
                return ParsedLine(marker: marker, lineNumber: nil, text: "…", isEllipsis: true)
            }
            let digits = remainder.prefix { $0.isNumber }
            guard !digits.isEmpty, let lineNumber = Int(digits) else { return nil }
            remainder = remainder.dropFirst(digits.count)
            if remainder.first == " " { remainder = remainder.dropFirst() }
            return ParsedLine(
                marker: marker,
                lineNumber: lineNumber,
                text: String(remainder),
                isEllipsis: false
            )
        }

        var rows: [ContextToolDiffRow] = []
        var pendingOld: [ContextToolDiffCell] = []
        var pendingNew: [ContextToolDiffCell] = []
        var removalCount = 0
        var additionCount = 0

        func flushChanges() {
            let rowCount = max(pendingOld.count, pendingNew.count)
            guard rowCount > 0 else { return }
            for index in 0..<rowCount {
                rows.append(ContextToolDiffRow(
                    old: index < pendingOld.count ? pendingOld[index] : nil,
                    new: index < pendingNew.count ? pendingNew[index] : nil
                ))
            }
            pendingOld.removeAll(keepingCapacity: true)
            pendingNew.removeAll(keepingCapacity: true)
        }

        for line in diff.components(separatedBy: "\n") {
            guard let parsed = parse(line) else { continue }
            switch parsed.marker {
            case "-":
                pendingOld.append(ContextToolDiffCell(
                    kind: .removal,
                    lineNumber: parsed.lineNumber,
                    text: parsed.text
                ))
                removalCount += 1
            case "+":
                pendingNew.append(ContextToolDiffCell(
                    kind: .addition,
                    lineNumber: parsed.lineNumber,
                    text: parsed.text
                ))
                additionCount += 1
            default:
                flushChanges()
                if parsed.isEllipsis {
                    rows.append(ContextToolDiffRow(
                        old: ContextToolDiffCell(kind: .ellipsis, lineNumber: nil, text: "…"),
                        new: ContextToolDiffCell(kind: .ellipsis, lineNumber: nil, text: "…")
                    ))
                } else {
                    let newLineNumber = parsed.lineNumber.map { $0 + additionCount - removalCount }
                    rows.append(ContextToolDiffRow(
                        old: ContextToolDiffCell(
                            kind: .unchanged,
                            lineNumber: parsed.lineNumber,
                            text: parsed.text
                        ),
                        new: ContextToolDiffCell(
                            kind: .unchanged,
                            lineNumber: newLineNumber,
                            text: parsed.text
                        )
                    ))
                }
            }
        }
        flushChanges()

        return ContextToolDiffDocument(
            rows: rows,
            removalCount: removalCount,
            additionCount: additionCount
        )
    }
}

struct ContextToolPresentation: Equatable {
    let family: ContextToolFamily
    let name: String
    let action: String
    let icon: String
    let summary: String?
    let metadata: String?
    let result: String?
    let diff: ContextToolDiffDocument

    /// The Read payload remains available to the runtime and persisted Session,
    /// but its potentially large file contents are never painted in the activity UI.
    func visibleResult(isRunning: Bool, isError: Bool) -> String {
        if family == .read {
            if isRunning { return "Reading…" }
            return isError ? "Failed" : "Successfully"
        }
        return result?.isEmpty == false ? result! : "Completed"
    }

    static func make(
        name rawName: String,
        payload: JSONValue?,
        fallbackText: String,
        isResult: Bool,
        resultPayload: JSONValue? = nil
    ) -> ContextToolPresentation {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let family = family(for: name)
        let object = objectValue(payload) ?? [:]

        if isResult {
            let fallbackResult = cleanResult(
                family == .bash ? firstLines(of: fallbackText, limit: 2) : fallbackText
            )
            let payloadResult = resultText(from: payload, family: family) ?? ""
            return ContextToolPresentation(
                family: family,
                name: name.isEmpty ? "tool" : name,
                action: "Result",
                icon: icon(for: family),
                summary: nil,
                metadata: nil,
                result: fallbackResult.isEmpty
                    ? cleanResult(family == .bash ? firstLines(of: payloadResult, limit: 2) : payloadResult)
                    : fallbackResult,
                diff: .empty
            )
        }

        let summary: String?
        let metadata: String?
        switch family {
        case .bash:
            summary = string(in: object, keys: ["command", "cmd", "script"]).map { "$ \($0)" }
            metadata = number(in: object, keys: ["timeout"]).map { "timeout \(compactNumber($0))s" }

        case .read:
            summary = string(in: object, keys: ["path", "file", "file_path"])
            metadata = readRange(in: object)

        case .edit:
            summary = string(in: object, keys: ["path", "file", "file_path"])
            let count = array(in: object, keys: ["edits", "changes"])?.count
                ?? (object["oldText"] == nil && object["old_text"] == nil ? 0 : 1)
            metadata = count > 0 ? "\(count) \(count == 1 ? "change" : "changes")" : nil

        case .write:
            summary = string(in: object, keys: ["path", "file", "file_path"])
            metadata = string(in: object, keys: ["content", "text"]).map {
                ByteCountFormatter.string(fromByteCount: Int64($0.utf8.count), countStyle: .file)
            }

        case .search:
            summary = string(in: object, keys: ["query", "pattern", "needle", "text", "glob"])
            metadata = string(in: object, keys: ["path", "cwd", "directory", "root"])

        case .web:
            summary = string(in: object, keys: ["url", "query", "q", "href"])
            metadata = string(in: object, keys: ["method", "domain"])

        case .subagent:
            summary = string(in: object, keys: ["task", "prompt", "message", "objective"])
            metadata = string(in: object, keys: ["agent", "name", "subagent"])

        case .skill:
            summary = string(in: object, keys: ["name", "skill", "path"])
            metadata = string(in: object, keys: ["action"])

        case .generic:
            summary = genericSummary(object: object, payload: payload, fallbackText: fallbackText)
            metadata = nil
        }

        return ContextToolPresentation(
            family: family,
            name: name.isEmpty ? "tool" : name,
            action: action(for: family),
            icon: icon(for: family),
            summary: summary,
            metadata: metadata,
            result: nil,
            diff: diffDocument(for: family, object: object, resultPayload: resultPayload)
        )
    }

    private static func family(for name: String) -> ContextToolFamily {
        switch name {
        case "bash", "shell", "exec", "exec_command", "terminal": .bash
        case "read", "read_file", "view", "open_file": .read
        case "edit", "apply_patch", "patch", "replace": .edit
        case "write", "write_file", "create_file": .write
        case "search", "grep", "rg", "glob", "find", "ls", "list", "list_files": .search
        case "web", "browse", "browser", "fetch", "open_url", "web_search", "search_query": .web
        case "subagent", "spawn_agent", "delegate", "task": .subagent
        case "skill", "load_skill", "read_skill": .skill
        default: .generic
        }
    }

    private static func action(for family: ContextToolFamily) -> String {
        switch family {
        case .bash: "Run"
        case .read: "Read"
        case .edit: "Edit"
        case .write: "Write"
        case .search: "Search"
        case .web: "Browse"
        case .subagent: "Delegate"
        case .skill: "Load skill"
        case .generic: "Use tool"
        }
    }

    private static func icon(for family: ContextToolFamily) -> String {
        switch family {
        case .bash: "terminal"
        case .read: "doc.text"
        case .edit: "pencil.line"
        case .write: "square.and.pencil"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .subagent: "person.2"
        case .skill: "sparkles"
        case .generic: "wrench"
        }
    }

    private static func readRange(in object: [String: JSONValue]) -> String? {
        let offset = number(in: object, keys: ["offset", "line", "start_line"])
        let limit = number(in: object, keys: ["limit", "line_count", "count"])
        if let offset, let limit {
            return "lines \(compactNumber(offset))–\(compactNumber(offset + max(0, limit - 1)))"
        }
        if let offset { return "from line \(compactNumber(offset))" }
        if let limit { return "\(compactNumber(limit)) lines" }
        return nil
    }

    private static func resultText(from payload: JSONValue?, family: ContextToolFamily) -> String? {
        guard let payload else { return nil }
        if let object = objectValue(payload), let content = object["content"], let text = contentText(content), !text.isEmpty {
            return text
        }
        if let text = contentText(payload), !text.isEmpty { return text }
        if family == .edit,
           let details = nestedObject(payload, key: "details") ?? objectValue(payload),
           let diff = string(in: details, keys: ["diff", "patch"]) {
            return diff
        }
        return nil
    }

    private static func diffDocument(
        for family: ContextToolFamily,
        object: [String: JSONValue],
        resultPayload: JSONValue?
    ) -> ContextToolDiffDocument {
        switch family {
        case .write:
            guard let content = string(in: object, keys: ["content", "text"]) else { return .empty }
            return .writing(content)

        case .edit:
            if let resultPayload,
               let details = nestedObject(resultPayload, key: "details") ?? objectValue(resultPayload),
               let displayDiff = string(in: details, keys: ["diff"]),
               !displayDiff.isEmpty {
                let parsed = ContextToolDiffDocument.parsingDisplayDiff(displayDiff)
                if !parsed.rows.isEmpty { return parsed }
            }

            var replacements: [[String: JSONValue]] = []
            if let edits = array(in: object, keys: ["edits", "changes"]) {
                replacements = edits.compactMap(objectValue)
            } else if string(in: object, keys: ["oldText", "old_text"]) != nil {
                replacements = [object]
            }

            let pairs = replacements.map { replacement in
                let oldText = string(in: replacement, keys: ["oldText", "old_text", "before"])
                let newText = string(in: replacement, keys: ["newText", "new_text", "after"])
                return (
                    oldText?.components(separatedBy: "\n") ?? [],
                    newText?.components(separatedBy: "\n") ?? []
                )
            }
            return .replacing(pairs)

        default:
            return .empty
        }
    }

    private static func contentText(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text):
            return text
        case .array(let values):
            let parts = values.compactMap { value -> String? in
                if case .string(let text) = value { return text }
                guard let object = objectValue(value) else { return nil }
                return string(in: object, keys: ["text", "content", "message"])
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        case .object(let object):
            return string(in: object, keys: ["text", "content", "message", "output", "result"])
        default:
            return nil
        }
    }

    private static func genericSummary(
        object: [String: JSONValue],
        payload: JSONValue?,
        fallbackText: String
    ) -> String? {
        if let direct = string(in: object, keys: ["query", "path", "command", "task", "text", "url", "name"]) {
            return direct
        }
        if let payload, let pretty = prettyJSON(payload), !pretty.isEmpty { return pretty }
        return fallbackText.isEmpty ? nil : fallbackText
    }

    private static func cleanResult(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keep terminal rendering bounded without splitting or scanning the full output.
    /// The complete payload remains untouched in the Session transcript.
    private static func firstLines(of text: String, limit: Int) -> String {
        guard limit > 0, !text.isEmpty else { return "" }
        var searchStart = text.startIndex
        for lineIndex in 0..<limit {
            guard let newline = text.range(of: "\n", range: searchStart..<text.endIndex) else {
                return text
            }
            if lineIndex == limit - 1 {
                guard newline.upperBound < text.endIndex else {
                    return String(text[..<newline.lowerBound])
                }
                return String(text[..<newline.lowerBound]) + " …"
            }
            searchStart = newline.upperBound
        }
        return text
    }

    private static func objectValue(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let object) = value else { return nil }
        return object
    }

    private static func nestedObject(_ value: JSONValue, key: String) -> [String: JSONValue]? {
        guard let object = objectValue(value) else { return nil }
        return objectValue(object[key])
    }

    private static func string(in object: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if case .string(let value)? = object[key], !value.isEmpty { return value }
        }
        return nil
    }

    private static func number(in object: [String: JSONValue], keys: [String]) -> Double? {
        for key in keys {
            if case .number(let value)? = object[key] { return value }
        }
        return nil
    }

    private static func array(in object: [String: JSONValue], keys: [String]) -> [JSONValue]? {
        for key in keys {
            if case .array(let value)? = object[key] { return value }
        }
        return nil
    }

    private static func compactNumber(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func prettyJSON(_ value: JSONValue) -> String? {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: pretty, encoding: .utf8)
    }
}

struct ContextToolActivityView: View {
    let name: String
    let arguments: JSONValue?
    let argumentText: String
    let resultPayload: JSONValue?
    let resultText: String?
    let isResultRunning: Bool
    let isResultError: Bool

    @State private var isResultExpanded = false
    @State private var isDiffExpanded = false

    private var presentation: ContextToolPresentation {
        .make(
            name: name,
            payload: arguments,
            fallbackText: argumentText,
            isResult: false,
            resultPayload: resultPayload
        )
    }

    private var taobaoCall: ContextTaobaoSearchCall? {
        ContextTaobaoSearchCall.parse(arguments)
    }

    private var resultPresentation: ContextToolPresentation? {
        guard isResultRunning || resultPayload != nil || resultText != nil else { return nil }
        return .make(name: name, payload: resultPayload, fallbackText: resultText ?? "Completed", isResult: true)
    }

    private var showsSummaryInline: Bool {
        presentation.family == .read || presentation.family == .edit || presentation.family == .write
    }

    private var inlineLabel: String {
        if showsSummaryInline, let summary = presentation.summary, !summary.isEmpty { return summary }
        return presentation.name
    }

    private var resultLineCount: Int {
        max(1, visibleResult.components(separatedBy: .newlines).count)
    }

    private var canExpandResult: Bool {
        guard presentation.family != .read else { return false }
        return resultLineCount > 12 || visibleResult.count > 1_200
    }

    private var visibleResult: String {
        resultPresentation?.visibleResult(
            isRunning: isResultRunning,
            isError: isResultError
        ) ?? "Completed"
    }

    @ViewBuilder
    var body: some View {
        if let taobaoCall {
            ContextTaobaoSearchActivityView(
                call: taobaoCall,
                resultPayload: resultPayload,
                resultText: resultText,
                isRunning: isResultRunning,
                isError: isResultError
            )
        } else {
            genericBody
        }
    }

    private var genericBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: presentation.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.66))
                    .frame(width: 15, height: 18, alignment: .leading)

                HStack(spacing: 7) {
                    Text(presentation.action)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.78))
                    Text(inlineLabel)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.58))
                    if let metadata = presentation.metadata, !metadata.isEmpty {
                        Text("·  \(metadata)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary.opacity(0.58))
                    }
                    if !presentation.diff.rows.isEmpty {
                        Spacer(minLength: 14)
                        HStack(spacing: 7) {
                            Text("−\(presentation.diff.removalCount)")
                                .foregroundStyle(ContextDiffPalette.removalText)
                            Text("+\(presentation.diff.additionCount)")
                                .foregroundStyle(ContextDiffPalette.additionText)
                        }
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !showsSummaryInline, let summary = presentation.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.72))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 25)
            }

            if !presentation.diff.rows.isEmpty {
                ContextToolDiffView(
                    document: presentation.diff,
                    isExpanded: $isDiffExpanded
                )
                .padding(.leading, 25)
            }

            if resultPresentation != nil {
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 28, height: 1)
                    .padding(.vertical, 2)
                    .padding(.leading, 25)

                HStack(alignment: .top, spacing: 8) {
                    Group {
                        if isResultRunning {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.secondary.opacity(0.66))
                        } else {
                            Image(systemName: isResultError ? "xmark.circle" : "checkmark.circle")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(isResultError ? Color.red.opacity(0.72) : Color.secondary.opacity(0.64))
                        }
                    }
                    .frame(width: 13, height: 16)

                    Text(visibleResult)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(isResultError ? Color.red.opacity(0.72) : Color.secondary.opacity(0.74))
                        .lineSpacing(3)
                        .lineLimit(presentation.family == .bash ? 2 : (isResultExpanded ? nil : 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 25)

                if canExpandResult {
                    Button(isResultExpanded ? "Show less" : "Show all · \(resultLineCount) lines") {
                        isResultExpanded.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.62))
                    .padding(.leading, 25)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ContextToolDiffView: View {
    let document: ContextToolDiffDocument
    @Binding var isExpanded: Bool

    private let collapsedLimit = 24

    private var visibleRows: ArraySlice<ContextToolDiffRow> {
        isExpanded ? document.rows[...] : document.rows.prefix(collapsedLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LazyVStack(spacing: 0) {
                ForEach(Array(visibleRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ContextToolDiffCellView(cell: row.old)
                            .frame(maxWidth: .infinity)

                        Rectangle()
                            .fill(Color.secondary.opacity(0.09))
                            .frame(width: 1)

                        ContextToolDiffCellView(cell: row.new)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(minHeight: 24)
                }
            }

            if document.rows.count > collapsedLimit {
                Rectangle()
                    .fill(Color.secondary.opacity(0.08))
                    .frame(height: 1)

                Button(isExpanded ? "Show less" : "Show full diff · \(document.rows.count) rows") {
                    isExpanded.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.62))
                .padding(.horizontal, 8)
                .frame(height: 27)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.018))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private enum ContextDiffPalette {
    static let removalText = Color(red: 0.72, green: 0.19, blue: 0.21).opacity(0.78)
    static let additionText = Color(red: 0.10, green: 0.43, blue: 0.23).opacity(0.82)
    static let removalBackground = Color(red: 0.99, green: 0.955, blue: 0.955)
    static let additionBackground = Color(red: 0.95, green: 0.98, blue: 0.96)
}

private struct ContextToolDiffCellView: View {
    let cell: ContextToolDiffCell?

    private var background: Color {
        switch cell?.kind {
        case .removal: ContextDiffPalette.removalBackground
        case .addition: ContextDiffPalette.additionBackground
        default: Color.white
        }
    }

    private var gutterBackground: Color {
        Color.clear
    }

    private var contentColor: Color {
        switch cell?.kind {
        case .ellipsis: Color.secondary.opacity(0.48)
        default: Color.primary.opacity(0.74)
        }
    }

    var body: some View {
        ZStack {
            background

            if cell == nil {
                Color.secondary.opacity(0.018)
            }

            HStack(spacing: 0) {
                Text(cell?.lineNumber.map(String.init) ?? "")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.38))
                    .frame(width: 28, alignment: .trailing)
                    .padding(.trailing, 5)
                    .frame(maxHeight: .infinity)
                    .background(gutterBackground)

                Text(changeMarker)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(markerColor)
                    .frame(width: 13, alignment: .center)

                Text(cell?.text.isEmpty == false ? cell!.text : " ")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(contentColor)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .padding(.trailing, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: 24)
    }

    private var changeMarker: String {
        switch cell?.kind {
        case .removal: "−"
        case .addition: "+"
        default: ""
        }
    }

    private var markerColor: Color {
        switch cell?.kind {
        case .removal: ContextDiffPalette.removalText
        case .addition: ContextDiffPalette.additionText
        default: Color.clear
        }
    }
}
