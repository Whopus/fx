import Foundation
import SwiftUI

private final class ContextMarkdownBlocksBox: NSObject {
    let value: [ContextMarkdownBlock]
    init(_ value: [ContextMarkdownBlock]) { self.value = value }
}

private final class ContextMarkdownInlineBox: NSObject {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

@MainActor
private final class ContextMarkdownRenderCache {
    static let shared = ContextMarkdownRenderCache()

    private let blockCache = NSCache<NSString, ContextMarkdownBlocksBox>()
    private let inlineCache = NSCache<NSString, ContextMarkdownInlineBox>()

    private init() {
        blockCache.countLimit = 256
        blockCache.totalCostLimit = 24 * 1_024 * 1_024
        inlineCache.countLimit = 2_048
        inlineCache.totalCostLimit = 8 * 1_024 * 1_024
    }

    func blocks(for markdown: String) -> [ContextMarkdownBlock] {
        let key = markdown as NSString
        if let cached = blockCache.object(forKey: key) { return cached.value }
        let parsed = ContextMarkdownParser.parse(markdown)
        blockCache.setObject(
            ContextMarkdownBlocksBox(parsed),
            forKey: key,
            cost: markdown.utf8.count
        )
        return parsed
    }

    func inline(for source: String) -> AttributedString {
        let key = source as NSString
        if let cached = inlineCache.object(forKey: key) { return cached.value }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        inlineCache.setObject(
            ContextMarkdownInlineBox(parsed),
            forKey: key,
            cost: source.utf8.count
        )
        return parsed
    }
}

enum ContextMarkdownTone: Equatable {
    case primary
    case secondary
}

enum ContextMarkdownLayout: Equatable {
    case standard
    case editorDocument
}

enum ContextMarkdownTableAlignment: Equatable {
    case leading
    case center
    case trailing
}

enum ContextMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unordered(indent: Int, text: String)
    case ordered(indent: Int, marker: String, text: String)
    case quote(String)
    case code(language: String?, text: String)
    case table(headers: [String], alignments: [ContextMarkdownTableAlignment], rows: [[String]])
    case divider
}

enum ContextMarkdownParser {
    static func parse(_ markdown: String) -> [ContextMarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [ContextMarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = fence(in: trimmed) {
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence) {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: codeLines.joined(separator: "\n")))
                continue
            }

            if let table = table(in: lines, startingAt: index) {
                blocks.append(table.block)
                index = table.nextIndex
                continue
            }

            if isDivider(trimmed) {
                blocks.append(.divider)
                index += 1
                continue
            }

            if let heading = heading(in: trimmed) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if let item = unorderedItem(in: line) {
                blocks.append(.unordered(indent: item.indent, text: item.text))
                index += 1
                continue
            }

            if let item = orderedItem(in: line) {
                blocks.append(.ordered(indent: item.indent, marker: item.marker, text: item.text))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoteLines.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            var paragraphLines: [String] = [trimmed]
            index += 1
            while index < lines.count {
                let candidate = lines[index]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                guard !candidateTrimmed.isEmpty,
                      !isBlockStart(lines, at: index, line: candidate, trimmed: candidateTrimmed) else { break }
                paragraphLines.append(candidateTrimmed)
                index += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
        }

        return blocks
    }

    private static func isBlockStart(_ lines: [String], at index: Int, line: String, trimmed: String) -> Bool {
        fence(in: trimmed) != nil
            || table(in: lines, startingAt: index) != nil
            || isDivider(trimmed)
            || heading(in: trimmed) != nil
            || unorderedItem(in: line) != nil
            || orderedItem(in: line) != nil
            || trimmed.hasPrefix(">")
    }

    private static func table(
        in lines: [String],
        startingAt index: Int
    ) -> (block: ContextMarkdownBlock, nextIndex: Int)? {
        guard lines.indices.contains(index + 1),
              let headers = tableCells(in: lines[index]),
              let delimiterCells = tableCells(in: lines[index + 1]),
              !headers.isEmpty,
              headers.count == delimiterCells.count else { return nil }

        let alignments = delimiterCells.compactMap(tableAlignment(in:))
        guard alignments.count == headers.count else { return nil }

        var rows: [[String]] = []
        var nextIndex = index + 2
        while lines.indices.contains(nextIndex) {
            let candidate = lines[nextIndex]
            guard !candidate.trimmingCharacters(in: .whitespaces).isEmpty,
                  var cells = tableCells(in: candidate) else { break }
            if cells.count < headers.count {
                cells.append(contentsOf: repeatElement("", count: headers.count - cells.count))
            } else if cells.count > headers.count {
                cells = Array(cells.prefix(headers.count))
            }
            rows.append(cells)
            nextIndex += 1
        }

        return (.table(headers: headers, alignments: alignments, rows: rows), nextIndex)
    }

    private static func tableCells(in line: String) -> [String]? {
        let source = line.trimmingCharacters(in: .whitespaces)
        guard source.contains("|") else { return nil }

        var cells: [String] = []
        var cell = ""
        var isEscaped = false
        var isInsideCode = false
        var foundSeparator = false

        for character in source {
            if character == "`", !isEscaped {
                isInsideCode.toggle()
                cell.append(character)
            } else if character == "|", !isEscaped, !isInsideCode {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
                foundSeparator = true
            } else {
                cell.append(character)
            }

            if character == "\\", !isEscaped {
                isEscaped = true
            } else {
                isEscaped = false
            }
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))

        guard foundSeparator else { return nil }
        if source.hasPrefix("|"), cells.first?.isEmpty == true { cells.removeFirst() }
        if source.hasSuffix("|"), cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    private static func tableAlignment(in source: String) -> ContextMarkdownTableAlignment? {
        let delimiter = source.trimmingCharacters(in: .whitespaces)
        let hasLeadingColon = delimiter.hasPrefix(":")
        let hasTrailingColon = delimiter.hasSuffix(":")
        let dashes = delimiter.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
        if hasLeadingColon && hasTrailingColon { return .center }
        if hasTrailingColon { return .trailing }
        return .leading
    }

    private static func fence(in line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let remainder = line.dropFirst(hashes)
        guard remainder.first?.isWhitespace == true else { return nil }
        return (hashes, remainder.trimmingCharacters(in: .whitespaces))
    }

    private static func unorderedItem(in line: String) -> (indent: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2,
              let marker = trimmed.first,
              marker == "-" || marker == "*" || marker == "+",
              trimmed.dropFirst().first?.isWhitespace == true else { return nil }
        return (indentLevel(in: line), String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    private static func orderedItem(in line: String) -> (indent: Int, marker: String, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let suffix = trimmed.dropFirst(digits.count)
        guard let punctuation = suffix.first,
              punctuation == "." || punctuation == ")",
              suffix.dropFirst().first?.isWhitespace == true else { return nil }
        return (
            indentLevel(in: line),
            String(digits) + String(punctuation),
            String(suffix.dropFirst()).trimmingCharacters(in: .whitespaces)
        )
    }

    private static func indentLevel(in line: String) -> Int {
        let width = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(into: 0) { width, character in
            width += character == "\t" ? 4 : 1
        }
        return width / 2
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let marker = compact.first, marker == "-" || marker == "*" || marker == "_" else {
            return false
        }
        return compact.allSatisfy { $0 == marker }
    }
}

struct ContextMarkdownDocument: View, Equatable {
    let markdown: String
    let baseFontSize: CGFloat
    let tone: ContextMarkdownTone
    let layout: ContextMarkdownLayout

    init(
        markdown: String,
        baseFontSize: CGFloat,
        tone: ContextMarkdownTone,
        layout: ContextMarkdownLayout = .standard
    ) {
        self.markdown = markdown
        self.baseFontSize = baseFontSize
        self.tone = tone
        self.layout = layout
    }

    private var foreground: Color {
        tone == .primary ? .primary : .secondary.opacity(0.76)
    }

    private var blockSpacing: CGFloat {
        tone == .primary ? 10 : 7
    }

    var body: some View {
        let blocks = ContextMarkdownRenderCache.shared.blocks(for: markdown)
        LazyVStack(alignment: .leading, spacing: layout == .standard ? blockSpacing : 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block)
                    .padding(
                        .top,
                        layout == .editorDocument
                            ? editorSpacing(before: block, after: index > 0 ? blocks[index - 1] : nil)
                            : 0
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func blockView(_ block: ContextMarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .foregroundStyle(foreground)
                .lineSpacing(4)
                .padding(.top, layout == .standard && level <= 2 ? 3 : 0)

        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .font(.system(size: baseFontSize))
                .foregroundStyle(foreground)
                .lineSpacing(tone == .primary ? 5 : 4)

        case .unordered(let indent, let text):
            HStack(alignment: .top, spacing: 7) {
                Circle()
                    .fill(foreground.opacity(0.88))
                    .frame(width: 4, height: 4)
                    .frame(width: 12, height: baseFontSize + 5, alignment: .center)
                Text(inlineMarkdown(text))
                    .font(.system(size: baseFontSize))
                    .lineSpacing(tone == .primary ? 5 : 4)
            }
            .foregroundStyle(foreground)
            .padding(.leading, CGFloat(indent) * 16)

        case .ordered(let indent, let marker, let text):
            HStack(alignment: .top, spacing: 7) {
                Text(marker)
                    .font(.system(size: baseFontSize, weight: .medium))
                    .frame(minWidth: 18, alignment: .trailing)
                Text(inlineMarkdown(text))
                    .font(.system(size: baseFontSize))
                    .lineSpacing(tone == .primary ? 5 : 4)
            }
            .foregroundStyle(foreground)
            .padding(.leading, CGFloat(indent) * 16)

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.32))
                    .frame(width: 2)
                Text(inlineMarkdown(text))
                    .font(.system(size: baseFontSize))
                    .italic()
                    .foregroundStyle(foreground.opacity(0.88))
                    .lineSpacing(tone == .primary ? 5 : 4)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 7) {
                if let language {
                    Text(language)
                        .font(.system(size: max(10, baseFontSize - 3), weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.62))
                }
                ScrollView(.horizontal) {
                    Text(text)
                        .font(.system(size: max(11, baseFontSize - 1), design: .monospaced))
                        .foregroundStyle(foreground)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))

        case .table(let headers, let alignments, let rows):
            ScrollView(.horizontal) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(headers.enumerated()), id: \.offset) { column, text in
                            tableCell(
                                text,
                                alignment: alignments[column],
                                isHeader: true,
                                showsTrailingRule: column < headers.count - 1,
                                showsBottomRule: true
                            )
                        }
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { column, text in
                                tableCell(
                                    text,
                                    alignment: alignments[column],
                                    isHeader: false,
                                    showsTrailingRule: column < row.count - 1,
                                    showsBottomRule: rowIndex < rows.count - 1
                                )
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
                }
            }
            .scrollIndicators(.hidden)

        case .divider:
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)
                .padding(.vertical, 3)
        }
    }

    private func tableCell(
        _ text: String,
        alignment: ContextMarkdownTableAlignment,
        isHeader: Bool,
        showsTrailingRule: Bool,
        showsBottomRule: Bool
    ) -> some View {
        Text(inlineMarkdown(text))
            .font(.system(size: baseFontSize, weight: isHeader ? .semibold : .regular))
            .foregroundStyle(foreground)
            .lineSpacing(tone == .primary ? 4 : 3)
            .padding(.horizontal, 11)
            .padding(.vertical, isHeader ? 8 : 7)
            .frame(
                minWidth: 92,
                idealWidth: 170,
                maxWidth: 360,
                alignment: swiftUIAlignment(alignment)
            )
            .background(isHeader ? Color.black.opacity(0.032) : .clear)
            .overlay(alignment: .trailing) {
                if showsTrailingRule {
                    Rectangle().fill(Color.secondary.opacity(0.12)).frame(width: 1)
                }
            }
            .overlay(alignment: .bottom) {
                if showsBottomRule {
                    Rectangle().fill(Color.secondary.opacity(0.12)).frame(height: 1)
                }
            }
    }

    private func swiftUIAlignment(_ alignment: ContextMarkdownTableAlignment) -> Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func inlineMarkdown(_ source: String) -> AttributedString {
        ContextMarkdownRenderCache.shared.inline(for: source)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        if layout == .editorDocument {
            switch level {
            case 1: return baseFontSize + 5
            case 2: return baseFontSize + 3
            case 3: return baseFontSize + 2
            default: return baseFontSize + 1
            }
        }
        return switch level {
        case 1: baseFontSize + 8
        case 2: baseFontSize + 5
        case 3: baseFontSize + 3
        default: baseFontSize + 1
        }
    }

    /// Compact, block-aware rhythm scaled for Curatez's 13pt editor body.
    /// Headings establish sections, list rows stay grouped, and rich blocks
    /// breathe without creating GitHub-sized gaps in the notebook canvas.
    private func editorSpacing(
        before block: ContextMarkdownBlock,
        after previous: ContextMarkdownBlock?
    ) -> CGFloat {
        guard let previous else { return 0 }

        switch block {
        case .heading:
            if case .heading = previous { return 10 }
            return 18

        case .unordered, .ordered:
            switch previous {
            case .unordered, .ordered:
                return 4
            case .heading:
                return 7
            default:
                return 10
            }

        case .paragraph:
            switch previous {
            case .heading:
                return 7
            case .unordered, .ordered, .quote, .code, .table:
                return 10
            case .divider:
                return 14
            case .paragraph:
                return 10
            }

        case .quote, .code, .table:
            if case .heading = previous { return 8 }
            return 12

        case .divider:
            return 16
        }
    }
}
