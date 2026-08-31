import SwiftUI

struct GalleryAspectRatioKey: LayoutValueKey {
    static let defaultValue: CGFloat = 1
}

struct MasonryLayout: Layout {
    var columns: Int
    var spacing: CGFloat = 24
    var layoutSignature = 0

    struct Cache {
        var frames: [CGRect] = []
        var size: CGSize = .zero
        var columns = 0
        var spacing: CGFloat = -1
        var layoutSignature = 0
        var aspectRatios: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        // Keep valid geometry across child-state updates such as hover. The
        // signature check in `sizeThatFits` invalidates only real layout data.
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let width = proposal.width ?? 1_000
        if cache.frames.count != subviews.count
            || abs(cache.size.width - width) > 0.5
            || cache.columns != columns
            || cache.spacing != spacing
            || cache.layoutSignature != layoutSignature {
            let aspectRatios = subviews.map { max(0.2, $0[GalleryAspectRatioKey.self]) }
            calculateFrames(width: width, aspectRatios: aspectRatios, cache: &cache)
        }
        return cache.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        if cache.frames.count != subviews.count
            || abs(cache.size.width - bounds.width) > 0.5
            || cache.columns != columns
            || cache.spacing != spacing
            || cache.layoutSignature != layoutSignature {
            let aspectRatios = subviews.map { max(0.2, $0[GalleryAspectRatioKey.self]) }
            calculateFrames(width: bounds.width, aspectRatios: aspectRatios, cache: &cache)
        }

        for (index, subview) in subviews.enumerated() where index < cache.frames.count {
            let frame = cache.frames[index].offsetBy(dx: bounds.minX, dy: bounds.minY)
            subview.place(
                at: frame.origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func calculateFrames(width: CGFloat, aspectRatios: [CGFloat], cache: inout Cache) {
        let count = max(1, columns)
        let columnWidth = max(1, (width - CGFloat(count - 1) * spacing) / CGFloat(count))
        var heights = Array(repeating: CGFloat.zero, count: count)
        var frames: [CGRect] = []

        for aspectRatio in aspectRatios {
            let column = heights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            let height = max(120, columnWidth / aspectRatio)
            let origin = CGPoint(
                x: CGFloat(column) * (columnWidth + spacing),
                y: heights[column]
            )
            frames.append(CGRect(origin: origin, size: CGSize(width: columnWidth, height: height)))
            heights[column] += height + spacing
        }

        cache.frames = frames
        cache.size = CGSize(width: width, height: max(0, (heights.max() ?? 0) - spacing))
        cache.columns = columns
        cache.spacing = spacing
        cache.layoutSignature = layoutSignature
        cache.aspectRatios = aspectRatios
    }
}
