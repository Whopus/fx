import AppKit
import ImageIO
import SwiftUI

/// Loads and downsamples local images away from the main actor, then reuses the
/// decoded result across SwiftUI redraws. This is especially important for
/// browser snapshots and high-resolution covers inside the masonry gallery.
struct CachedLocalImage: View {
    let url: URL
    var maxPixelSize: CGFloat = 1_200
    var contentMode: ContentMode = .fill
    var showsProgress = false

    @State private var image: NSImage?

    private var cacheKey: NSString {
        "\(url.standardizedFileURL.path)|\(Int(maxPixelSize.rounded(.up)))" as NSString
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Color.clear
            }
        }
        .task(id: cacheKey) {
            if let cached = LocalImageCache.shared.image(forKey: cacheKey) {
                image = cached
                return
            }

            let requestedSize = maxPixelSize
            let loaded = await Task.detached(priority: .userInitiated) {
                Self.downsample(url: url, maxPixelSize: requestedSize)
            }.value
            guard !Task.isCancelled, let loaded else { return }
            let decoded = NSImage(
                cgImage: loaded,
                size: NSSize(width: loaded.width, height: loaded.height)
            )
            LocalImageCache.shared.insert(decoded, forKey: cacheKey, pixelCost: loaded.width * loaded.height)
            image = decoded
        }
    }

    nonisolated private static func downsample(url: URL, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded(.up)))
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

@MainActor
private final class LocalImageCache {
    static let shared = LocalImageCache()

    private let storage = NSCache<NSString, NSImage>()

    private init() {
        storage.countLimit = 160
        storage.totalCostLimit = 256 * 1_024 * 1_024
    }

    func image(forKey key: NSString) -> NSImage? {
        storage.object(forKey: key)
    }

    func insert(_ image: NSImage, forKey key: NSString, pixelCost: Int) {
        storage.setObject(image, forKey: key, cost: pixelCost * 4)
    }
}
