import SwiftUI

/// Live metrics for a scroll view's content and viewport, used to place a
/// custom scroll marker without relying on the system indicator.
struct ThinScrollMetrics: Equatable {
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var offsetY: CGFloat = 0
}

/// Replaces the system scroll indicator with the app's compact black marker: a
/// two-point capsule, twelve to twenty-eight points tall, drawn only while the
/// content actually overflows. The marker matches the sidebar's
/// `ContextThinVerticalScrollView` so every scrollable surface reads the same.
private struct ThinScrollIndicatorModifier: ViewModifier {
    @State private var metrics = ThinScrollMetrics()

    private var hasOverflow: Bool {
        metrics.contentHeight > metrics.viewportHeight + 1
    }

    private var thumbHeight: CGFloat {
        guard metrics.contentHeight > 0, metrics.viewportHeight > 0 else { return 0 }
        return min(28, max(12, metrics.viewportHeight * metrics.viewportHeight / metrics.contentHeight))
    }

    private var thumbOffset: CGFloat {
        let scrollableHeight = max(metrics.contentHeight - metrics.viewportHeight, 1)
        let availableTrackHeight = max(metrics.viewportHeight - thumbHeight, 0)
        let progress = min(max(metrics.offsetY / scrollableHeight, 0), 1)
        return progress * availableTrackHeight
    }

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: ThinScrollMetrics.self) { geometry in
                ThinScrollMetrics(
                    contentHeight: geometry.contentSize.height,
                    viewportHeight: geometry.containerSize.height,
                    offsetY: geometry.contentOffset.y
                )
            } action: { _, newValue in
                metrics = newValue
            }
            .overlay(alignment: .topTrailing) {
                if hasOverflow {
                    Capsule()
                        .fill(.black.opacity(0.82))
                        .frame(width: 2, height: thumbHeight)
                        .padding(.trailing, 1)
                        .offset(y: thumbOffset)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

extension View {
    /// Swaps the native scroll indicator for the app-wide thin black marker.
    func thinScrollIndicator() -> some View {
        modifier(ThinScrollIndicatorModifier())
    }
}
