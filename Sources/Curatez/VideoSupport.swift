import Foundation

enum VideoSupport {
    private static let playableExtensions: Set<String> = ["mp4", "mov", "m4v", "m3u8"]

    static func isPlayableRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return playableExtensions.contains(url.pathExtension.lowercased())
    }
}
