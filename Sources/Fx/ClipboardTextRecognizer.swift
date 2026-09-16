import Foundation

enum ClipboardTextContent: Equatable {
    case webURL(URL)
    case text(String)
}

enum ClipboardTextRecognizer {
    static func recognize(_ rawValue: String) -> ClipboardTextContent {
        let text = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = webURL(from: text) else {
            return .text(text)
        }
        return .webURL(url)
    }

    private static func webURL(from text: String) -> URL? {
        guard !text.isEmpty,
              text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return nil
        }

        if let explicitURL = validatedWebURL(text) {
            return explicitURL
        }

        guard !text.contains("://"),
              !text.hasPrefix("."),
              !text.hasSuffix(".") else {
            return nil
        }
        return validatedWebURL("https://\(text)")
    }

    private static func validatedWebURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              isPlausibleHost(host),
              let url = components.url else {
            return nil
        }
        return url
    }

    private static func isPlausibleHost(_ host: String) -> Bool {
        let lowercased = host.lowercased()
        if lowercased == "localhost" { return true }

        if lowercased.contains(":"),
           lowercased.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) {
            return true
        }

        let ipv4Parts = lowercased.split(separator: ".", omittingEmptySubsequences: false)
        if ipv4Parts.count == 4,
           ipv4Parts.allSatisfy({ part in
               !part.isEmpty && part.allSatisfy(\.isNumber) && Int(part).map { (0...255).contains($0) } == true
           }) {
            return true
        }

        let labels = lowercased.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ label in
                  !label.isEmpty
                      && !label.hasPrefix("-")
                      && !label.hasSuffix("-")
                      && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
              }),
              let topLevelDomain = labels.last,
              topLevelDomain.count >= 2,
              topLevelDomain.allSatisfy(\.isLetter) else {
            return false
        }
        return true
    }
}
