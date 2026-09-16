import Foundation

/// Immutable file locations captured on the store's actor. File reads and text
/// assembly can then run without retaining the store or its selected collection.
struct CaptureTextSource: Sendable {
    let record: CaptureRecord
    let originalURL: URL?
    let tabURLs: [UUID: URL]

    var originalText: String? {
        if let text = text(at: originalURL), !text.isEmpty { return text }
        return record.text.flatMap { $0.isEmpty ? nil : $0 }
    }

    func context(originalText: String? = nil) -> String {
        let content: String
        switch record.kind {
        case .text:
            content = originalText ?? self.originalText ?? "(Empty)"
        case .link:
            content = record.text.flatMap { $0.isEmpty ? nil : $0 } ?? record.sourceURL ?? "(Empty)"
        case .image, .browserSnapshot:
            content = originalURL.map { "[Image] \($0.path)" }
                ?? record.sourceURL.map { "[Image] \($0)" } ?? "[Image unavailable]"
        case .video:
            content = originalURL.map { "[Video] \($0.path)" }
                ?? record.sourceURL.map { "[Video] \($0)" } ?? "[Video unavailable]"
        }
        if (record.tags ?? []).contains(where: { $0.hasPrefix("builtin:context:platform-search:") }) {
            let description = record.itemDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let heading = description.isEmpty ? record.title : "\(record.title) — \(description)"
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? heading : "\(heading)\n\(trimmed)"
        }

        var sections = ["Title: \(record.title)"]
        if let tags = record.tags, !tags.isEmpty {
            sections.append("Tags: \(tags.joined(separator: ", "))")
        }
        if let description = record.itemDescription, !description.isEmpty {
            sections.append("Description:\n\(description)")
        }
        sections.append("Content:\n\(content)")
        if let sourceURL = record.sourceURL, !sourceURL.isEmpty, !content.contains(sourceURL) {
            sections.append("Source: \(sourceURL)")
        }
        for tab in record.detailTabs ?? [] {
            let value: String
            switch tab.kind {
            case .markdown, .plainText:
                let body = text(at: tabURLs[tab.id]) ?? ""
                value = body.isEmpty ? "(Empty)" : body
            case .image, .video, .file:
                value = tab.fileName
            }
            sections.append("[\(tab.title)]:\n\(value)")
        }
        return sections.joined(separator: "\n\n")
    }

    // Non-actor async functions use the generic executor with this package's
    // Swift 6 settings (NonisolatedNonsendingByDefault is not enabled).
    func loadDetail() async throws -> (original: String, context: String) {
        try Task.checkCancellation()
        let original = originalText ?? ""
        let context = context(originalText: original.isEmpty ? "(Empty)" : original)
        try Task.checkCancellation()
        return (original, context)
    }

    private func text(at url: URL?) -> String? {
        guard let url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
