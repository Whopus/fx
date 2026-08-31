import AppKit
import SwiftUI

enum CaptureCandidate {
    case selectedText(String)
    case copiedText(String)
    case copiedURL(URL)
    case copiedVideoURL(URL)
    case copiedImage(NSImage)
}

@MainActor
final class CaptureTooltipController {
    private var panel: CaptureTooltipPanel?

    func show(
        candidate: CaptureCandidate,
        onSave: @escaping @MainActor () -> Void,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        close()

        let size = candidate.panelSize
        let panel = CaptureTooltipPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let content = CaptureTooltipView(
            candidate: candidate,
            onSave: { [weak self] in
                onSave()
                self?.close()
            },
            onDismiss: { [weak self] in
                onDismiss()
                self?.close()
            }
        )
        panel.contentView = NSHostingView(rootView: content)
        panel.setFrameOrigin(position(for: size))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func position(for size: NSSize) -> NSPoint {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let preferred = NSPoint(x: cursor.x + 14, y: cursor.y - size.height - 14)
        return NSPoint(
            x: min(max(preferred.x, visible.minX + 10), visible.maxX - size.width - 10),
            y: min(max(preferred.y, visible.minY + 10), visible.maxY - size.height - 10)
        )
    }
}

private final class CaptureTooltipPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private extension CaptureCandidate {
    var panelSize: NSSize {
        switch self {
        case .selectedText, .copiedText: NSSize(width: 360, height: 154)
        case .copiedURL, .copiedVideoURL: NSSize(width: 380, height: 170)
        case .copiedImage: NSSize(width: 360, height: 224)
        }
    }
}

private struct CaptureTooltipView: View {
    let candidate: CaptureCandidate
    let onSave: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: candidate.iconName)
                    .font(.system(size: 13, weight: .semibold))
                Text(candidate.question)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Curatez")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            candidatePreview

            HStack(spacing: 8) {
                Spacer()
                Button("忽略", action: onDismiss)
                    .buttonStyle(TooltipSecondaryButtonStyle())
                Button("加入收藏", action: onSave)
                    .buttonStyle(TooltipPrimaryButtonStyle())
            }
        }
        .padding(16)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.55)))
    }

    @ViewBuilder
    private var candidatePreview: some View {
        switch candidate {
        case .selectedText(let text), .copiedText(let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .copiedURL(let url), .copiedVideoURL(let url):
            VStack(alignment: .leading, spacing: 4) {
                Text(url.host() ?? "网页链接")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(url.absoluteString)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .copiedImage(let image):
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: 112)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private extension CaptureCandidate {
    var iconName: String {
        switch self {
        case .selectedText, .copiedText: "text.quote"
        case .copiedURL: "link"
        case .copiedVideoURL: "play.rectangle"
        case .copiedImage: "photo"
        }
    }

    var question: String {
        switch self {
        case .selectedText: "把选中内容加入收藏？"
        case .copiedText: "把复制的文本加入收藏？"
        case .copiedURL: "把复制的链接加入收藏？"
        case .copiedVideoURL: "把复制的视频加入收藏？"
        case .copiedImage: "把复制的图片加入收藏？"
        }
    }
}

private struct TooltipPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(.black.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(Capsule())
    }
}

private struct TooltipSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(.gray.opacity(configuration.isPressed ? 0.2 : 0.1))
            .clipShape(Capsule())
    }
}
