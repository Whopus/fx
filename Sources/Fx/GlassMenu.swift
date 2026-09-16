import AppKit
import OSLog
import QuartzCore
import SwiftUI

private let glassMenuLog = Logger(subsystem: "com.fx.desktop", category: "GlassMenu")

/// Values describe rows; actions stay with the view that owns the operation.
struct GlassMenuEntry: Identifiable {
    enum Kind { case action, separator, heading }

    let id: String
    var title: String = ""
    var icon: String?
    var detail: String?
    var count: Int?
    var selected = false
    var enabled = true
    var destructive = false
    var disclosure = false
    var keepsOpen = false
    var kind: Kind = .action
    var action: @MainActor () -> Void = {}

    static func separator(_ id: String = "separator") -> Self {
        Self(id: id, enabled: false, kind: .separator)
    }

    static func heading(_ title: String, detail: String? = nil) -> Self {
        Self(id: "heading-\(title)", title: title, detail: detail, enabled: false, kind: .heading)
    }
}

enum GlassMenuDensity {
    case standard, catalog

    func height(of entry: GlassMenuEntry) -> CGFloat {
        switch entry.kind {
        case .separator: 11
        case .heading: self == .catalog ? 68 : (entry.detail == nil ? 30 : 48)
        case .action: self == .catalog ? 52 : (entry.detail == nil ? 36 : 42)
        }
    }

    static func material(scheme: ColorScheme, reduceTransparency: Bool) -> Glass {
        if reduceTransparency { return .regular }
        return scheme == .dark ? .clear.tint(.black.opacity(0.45)).interactive() : .clear.interactive()
    }
}

/// The label keeps its existing layout. The surface is hosted above the window's
/// content, so a menu inside a card or scroll view is never clipped by that view.
struct GlassMenu<Label: View>: View {
    let entries: [GlassMenuEntry]
    var width: CGFloat = 240
    var density: GlassMenuDensity = .standard
    var accessibilityTitle: String = "菜单"
    var isPresented: Binding<Bool>?
    var onOpen: () -> Void = {}
    @ViewBuilder var label: () -> Label

    @State private var localPresentation = false

    private var presentation: Binding<Bool> { isPresented ?? $localPresentation }

    var body: some View {
        Button {
            glassMenuLog.notice("trigger \(accessibilityTitle, privacy: .public) presented=\(presentation.wrappedValue)")
            if !presentation.wrappedValue { onOpen() }
            presentation.wrappedValue.toggle()
        } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle)
        .background {
            // Read the value in `body`, not only inside the Button action. Without
            // this dependency SwiftUI may not update the representable for the
            // menu's private @State binding, leaving the requested presentation
            // change pending until some unrelated view update occurs.
            GlassMenuAnchor(presentation: presentation, presented: presentation.wrappedValue,
                            entries: entries, width: width,
                            density: density, accessibilityTitle: accessibilityTitle)
        }
    }
}

/// Keyboard state is independent of rendering and can be checked without a GUI.
struct GlassMenuNavigation {
    var highlighted: String?
    var scrollTarget: String?

    mutating func move(by offset: Int, in entries: [GlassMenuEntry]) {
        let selectable = entries.filter { $0.kind == .action && $0.enabled }
        guard !selectable.isEmpty else { highlighted = nil; scrollTarget = nil; return }
        let start = selectable.firstIndex { $0.id == highlighted }
            ?? selectable.firstIndex { $0.selected }
        let index = start.map { ($0 + offset % selectable.count + selectable.count) % selectable.count }
            ?? (offset > 0 ? 0 : selectable.count - 1)
        highlighted = selectable[index].id
        scrollTarget = highlighted
    }

    func activation(in entries: [GlassMenuEntry]) -> GlassMenuEntry? {
        let eligible = entries.filter { $0.kind == .action && $0.enabled }
        return eligible.first { $0.id == highlighted } ?? eligible.first { $0.selected } ?? eligible.first
    }
}

struct GlassMenuLayout {
    let frame: CGRect
    let opensBelow: Bool

    init(anchor: CGRect, size: CGSize, bounds: CGRect) {
        let safe = bounds.insetBy(dx: 8, dy: 8)
        let width = min(size.width, max(0, safe.width))
        let below = max(0, anchor.minY - 8 - safe.minY)
        let above = max(0, safe.maxY - anchor.maxY - 8)
        opensBelow = below >= size.height || below >= above
        let height = min(size.height, opensBelow ? below : above)
        let x = min(max(anchor.maxX - width, safe.minX), safe.maxX - width)
        let y = opensBelow ? anchor.minY - 8 - height : anchor.maxY + 8
        frame = CGRect(x: x, y: min(max(y, safe.minY), safe.maxY - height), width: width, height: height)
    }
}

@Observable @MainActor
private final class GlassMenuSession {
    var entries: [GlassMenuEntry] = []
    var density: GlassMenuDensity = .standard
    var scheme: ColorScheme = .light
    var reduceTransparency = false
    var visible = false
    var navigation = GlassMenuNavigation()
    @ObservationIgnored var choose: ((GlassMenuEntry) -> Void)?
}

private struct GlassMenuSurface: View {
    let session: GlassMenuSession
    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            if session.visible {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(session.entries) { entry in
                                row(entry)
                                    .frame(height: session.density.height(of: entry))
                                    .id(entry.id)
                            }
                        }
                        .background(GlassMenuScrollViewConfigurator())
                    }
                    .scrollIndicators(.never)
                    .scrollBounceBehavior(.basedOnSize)
                    .onChange(of: session.navigation.scrollTarget) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
                .padding(8)
                .background {
                    if session.reduceTransparency {
                        RoundedRectangle(cornerRadius: 28).fill(Color(nsColor: .windowBackgroundColor))
                    }
                }
                .glassEffect(GlassMenuDensity.material(scheme: session.scheme,
                    reduceTransparency: session.reduceTransparency), in: RoundedRectangle(cornerRadius: 28))
                .glassEffectID("options", in: glassNamespace)
                .shadow(color: .black.opacity(0.10), radius: 14, x: 0, y: 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(session.scheme)
    }

    @ViewBuilder
    private func row(_ entry: GlassMenuEntry) -> some View {
        switch entry.kind {
        case .separator:
            Divider().padding(.horizontal, 12)
        case .heading:
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title).font(.system(size: session.density == .catalog ? 17 : 12, weight: .semibold))
                if let detail = entry.detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
        case .action:
            Button {
                guard session.visible, entry.enabled else { return }
                session.choose?(entry)
            } label: {
                HStack(spacing: session.density == .catalog ? 12 : 9) {
                    if let icon = entry.icon {
                        Image(systemName: icon)
                            .font(.system(size: session.density == .catalog ? 18 : 13))
                            .symbolRenderingMode(.monochrome)
                            .frame(width: session.density == .catalog ? 24 : 18)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title)
                            .font(.system(size: session.density == .catalog ? 15 : 12, weight: .medium))
                            .lineLimit(1)
                        if let detail = entry.detail {
                            Text(detail).font(.system(size: session.density == .catalog ? 11.5 : 10))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if let count = entry.count {
                        Text(verbatim: String(count)).font(.system(size: 12, weight: .medium))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    if session.density == .catalog || entry.selected {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                            .opacity(entry.selected ? 1 : 0).frame(width: 14)
                    }
                    if entry.disclosure {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(entry.destructive ? Color.red : Color.primary)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .background {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.primary.opacity(session.navigation.highlighted == entry.id ? 0.17 : entry.selected ? 0.055 : 0))
                }
                .opacity(entry.enabled ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(!entry.enabled)
            .onHover { hovering in
                if hovering && entry.enabled { session.navigation.highlighted = entry.id }
                else if session.navigation.highlighted == entry.id { session.navigation.highlighted = nil }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([entry.title, entry.detail].compactMap { $0 }.joined(separator: ", "))
            .accessibilityValue(entry.count.map(String.init) ?? "")
            .accessibilityAddTraits(entry.selected ? [.isSelected] : [])
        }
    }
}

private struct GlassMenuAnchor: NSViewRepresentable {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var enabled
    @Binding var presentation: Bool
    let presented: Bool
    let entries: [GlassMenuEntry]
    let width: CGFloat
    let density: GlassMenuDensity
    let accessibilityTitle: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        context.coordinator.anchor = view
        view.changed = { [weak owner = context.coordinator] in owner?.scheduleRefresh() }
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        let owner = context.coordinator
        owner.presentation = $presentation
        owner.presented = presented
        owner.entries = entries
        owner.width = width
        owner.density = density
        owner.scheme = scheme
        owner.reduceMotion = reduceMotion
        owner.reduceTransparency = reduceTransparency
        owner.enabled = enabled
        owner.accessibilityTitle = accessibilityTitle
        owner.scheduleRefresh()
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        view.changed = nil
        coordinator.close(updateBinding: false, animated: false)
        coordinator.anchor = nil
    }

    final class AnchorView: NSView {
        var changed: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); changed?() }
        override func setFrameOrigin(_ origin: NSPoint) {
            guard frame.origin != origin else { return }
            super.setFrameOrigin(origin); changed?()
        }
        override func setFrameSize(_ size: NSSize) {
            guard frame.size != size else { return }
            super.setFrameSize(size); changed?()
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private static weak var active: Coordinator?
        weak var anchor: AnchorView?
        var presentation: Binding<Bool>?
        var presented = false
        var entries: [GlassMenuEntry] = []
        var width: CGFloat = 240
        var density: GlassMenuDensity = .standard
        var scheme: ColorScheme = .light
        var reduceMotion = false
        var reduceTransparency = false
        var enabled = true
        var accessibilityTitle = "菜单"
        private let session = GlassMenuSession()
        private var host: MenuHostingView?
        private weak var overlayContainer: NSView?
        private weak var parentWindow: NSWindow?
        private weak var previousResponder: NSResponder?
        private var eventMonitor: Any?
        private var refreshScheduled = false
        private var generation = 0
        private var closing = false
        private var searchPrefix = ""
        private var lastTypingTime: TimeInterval = 0

        isolated deinit { tearDown() }

        func scheduleRefresh() {
            guard !refreshScheduled else { return }
            refreshScheduled = true
            // Refresh after SwiftUI's update pass, coalescing repeated layout
            // notifications. No task or timer survives the owning anchor.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                self.refresh()
            }
        }

        private func refresh() {
            if presented {
                glassMenuLog.notice("refresh \(self.accessibilityTitle, privacy: .public) anchor=\(self.anchor != nil) window=\(self.anchor?.window != nil) visible=\(self.anchor?.window?.isVisible == true) enabled=\(self.enabled)")
            }
            guard let anchor, let window = anchor.window, window.isVisible, enabled else {
                close(updateBinding: true, animated: false)
                return
            }
            guard presented else { close(updateBinding: false); return }
            session.entries = entries
            session.density = density
            session.scheme = scheme
            session.reduceTransparency = reduceTransparency
            if let host {
                position()
                if closing || !session.visible {
                    closing = false
                    Self.active?.closeIfDifferent(from: self)
                    Self.active = self
                    installHandlers(window: window)
                    schedulePresentation(of: host)
                }
                return
            }
            Self.active?.closeIfDifferent(from: self)
            Self.active = self
            session.navigation = GlassMenuNavigation()
            searchPrefix = ""
            session.choose = { [weak self] entry in
                guard let self, self.session.visible, entry.enabled else { return }
                if !entry.keepsOpen { self.close(updateBinding: true) }
                entry.action()
            }
            let host = MenuHostingView(rootView: GlassMenuSurface(session: session))
            host.clipsToBounds = false
            host.setAccessibilityRole(.popover)
            host.setAccessibilityLabel(accessibilityTitle)
            guard let content = window.contentView, let overlayContainer = content.superview else {
                presentation?.wrappedValue = false
                return
            }
            self.host = host
            self.overlayContainer = overlayContainer
            parentWindow = window
            previousResponder = window.firstResponder
            // The hosting controller's root view cannot accept AppKit siblings.
            // Its common parent can, and keeps the menu in the same compositing
            // surface so clear glass retains the live liquid-glass refraction.
            overlayContainer.addSubview(host, positioned: .above, relativeTo: content)
            position()
            installHandlers(window: window)
            schedulePresentation(of: host)
        }

        /// Reveals the menu on the next run-loop turn, after the hidden glass
        /// container has been committed in its final geometry. The first time a
        /// menu opens, the container is created in this same refresh pass;
        /// animating immediately would merge the container's creation and its
        /// content insertion into one transaction and produce a different first
        /// reveal. Forcing a layout/display commit first makes every open,
        /// including the first, animate identically to a re-open.
        private func schedulePresentation(of host: NSView) {
            commitLayout(of: host)
            generation &+= 1
            let opening = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == opening, self.presented else { return }
                self.commitLayout(of: self.host)
                withAnimation(self.reduceMotion ? nil : .default) { self.session.visible = true }
                glassMenuLog.notice("shown \(self.accessibilityTitle, privacy: .public) frame=\(String(describing: self.host?.frame), privacy: .public)")
            }
        }

        private func commitLayout(of host: NSView?) {
            guard let host else { return }
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            CATransaction.flush()
        }

        private func closeIfDifferent(from other: Coordinator) {
            if self !== other { close(updateBinding: true, animated: false) }
        }

        @objc private func position() {
            guard let anchor, let window = anchor.window, let content = window.contentView,
                  let host, let overlayContainer else { return }
            let button = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let bounds = window.convertToScreen(content.convert(content.bounds, to: nil))
            let height = entries.reduce(CGFloat(16)) { $0 + density.height(of: $1) } + CGFloat(max(0, entries.count - 1)) * 2
            let layout = GlassMenuLayout(anchor: button, size: CGSize(width: width, height: height), bounds: bounds)
            let hostFrame = overlayContainer.convert(window.convertFromScreen(layout.frame), from: nil)
            if host.frame != hostFrame { host.frame = hostFrame }
        }

        private func installHandlers(window: NSWindow) {
            removeHandlers()
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                guard let self, let anchor = self.anchor, let host = self.host else { return event }
                if event.type == .keyDown {
                    if self.handleKey(event) { return nil }
                } else {
                    let insideButton = event.window === anchor.window && anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
                    let insideMenu = event.window === host.window && host.bounds.contains(host.convert(event.locationInWindow, from: nil))
                    if !insideButton && !insideMenu { self.close(updateBinding: true) }
                }
                return event
            }
            let center = NotificationCenter.default
            for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, NSWindow.didResignKeyNotification] {
                center.addObserver(self, selector: #selector(dismissImmediately), name: name, object: window)
            }
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                center.addObserver(self, selector: #selector(position), name: name, object: window)
            }
            center.addObserver(self, selector: #selector(position), name: NSView.boundsDidChangeNotification, object: nil)
            center.addObserver(self, selector: #selector(dismissImmediately), name: NSApplication.didResignActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(dismissImmediately), name: NSMenu.didBeginTrackingNotification, object: nil)
        }

        private func handleKey(_ event: NSEvent) -> Bool {
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
            switch event.keyCode {
            case 53: close(updateBinding: true)
            case 125: session.navigation.move(by: 1, in: entries)
            case 126: session.navigation.move(by: -1, in: entries)
            case 48: session.navigation.move(by: event.modifierFlags.contains(.shift) ? -1 : 1, in: entries)
            case 36, 76, 49:
                if let entry = session.navigation.activation(in: entries) { session.choose?(entry) }
            default:
                guard let characters = event.characters, characters.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { return false }
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastTypingTime > 1 { searchPrefix = "" }
                lastTypingTime = now
                searchPrefix += characters
                let match = entries.first { $0.enabled && $0.kind == .action && $0.title.range(of: searchPrefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil }
                if let match { session.navigation.highlighted = match.id; session.navigation.scrollTarget = match.id }
            }
            return true
        }

        @objc private func dismissImmediately() { close(updateBinding: true, animated: false) }

        func close(updateBinding: Bool, animated: Bool = true) {
            if host != nil { glassMenuLog.notice("close \(self.accessibilityTitle, privacy: .public) binding=\(self.presentation?.wrappedValue == true) update=\(updateBinding) animated=\(animated)") }
            if updateBinding, presentation?.wrappedValue == true { presentation?.wrappedValue = false }
            guard host != nil else { return }
            if !animated || reduceMotion { tearDown(); return }
            guard !closing else { return }
            closing = true
            generation &+= 1
            let closingGeneration = generation
            removeHandlers()
            restoreFocus()
            withAnimation(.default, completionCriteria: .removed) {
                session.visible = false
            } completion: { [weak self] in
                guard let self, self.generation == closingGeneration, self.closing else { return }
                self.tearDown()
            }
        }

        private func removeHandlers() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            NotificationCenter.default.removeObserver(self)
        }

        private func restoreFocus() {
            if let parentWindow, let previousResponder,
               let responder = parentWindow.firstResponder as? NSView, let host,
               responder === host || responder.isDescendant(of: host) {
                parentWindow.makeFirstResponder(previousResponder)
            }
        }

        private func tearDown() {
            generation &+= 1
            removeHandlers()
            restoreFocus()
            session.visible = false
            session.choose = nil
            session.entries = []
            host?.removeFromSuperview()
            host = nil
            overlayContainer = nil
            parentWindow = nil
            previousResponder = nil
            closing = false
            if Self.active === self { Self.active = nil }
        }
    }
}

private final class MenuHostingView: NSHostingView<GlassMenuSurface> {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        rootView.session.visible ? super.hitTest(point) : nil
    }
}

/// Removes the SwiftUI `ScrollView`'s AppKit scroller entirely. A visible or
/// would-be scroller reserves width and can toggle on and off as the menu's
/// content size settles, which makes the hosted menu jitter. The menu still
/// scrolls with the trackpad or wheel; it just never draws or reserves a bar.
private struct GlassMenuScrollViewConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { GlassMenuScrollerlessView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class GlassMenuScrollerlessView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        configureEnclosingScrollView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureEnclosingScrollView()
    }

    private func configureEnclosingScrollView() {
        guard let scrollView = enclosingScrollView else { return }
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.drawsBackground = false
        // The menu only needs to follow the underlying window's scroll, not its
        // own; suppressing this clip view's bounds notifications avoids feeding
        // the coordinator's reposition pass while the menu lays out.
        scrollView.contentView.postsBoundsChangedNotifications = false
    }
}
