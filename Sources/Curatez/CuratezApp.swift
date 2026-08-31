import AppKit
import Carbon.HIToolbox
import SwiftUI

private enum MainWindowMetrics {
    static let defaultWidth: CGFloat = 960
    static let defaultHeight: CGFloat = 650
}

@main
struct CuratezApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(services.store)
                .environmentObject(services.capture)
                .frame(minWidth: 840, minHeight: 420)
                .ignoresSafeArea(.container, edges: .top)
                .background(
                    InitialWindowConfigurator(
                        width: MainWindowMetrics.defaultWidth,
                        height: MainWindowMetrics.defaultHeight
                    ) { window in
                        appDelegate.attachMainWindow(
                            window,
                            islandActivity: services.islandActivity,
                            captureCoordinator: services.capture
                        )
                    }
                )
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(
            width: MainWindowMetrics.defaultWidth,
            height: MainWindowMetrics.defaultHeight
        )
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let reopenNotification = Notification.Name("com.curatez.desktop.reopen-main-window")

    private let modifierChordMonitor = ModifierChordMonitor()
    private let quitHotKey = GlobalHotKeyManager()
    private let islandController = CuratezIslandWindowController()
    private weak var mainWindow: NSWindow?
    private weak var previouslyActiveApplication: NSRunningApplication?
    private var hasEstablishedInitialState = false
    private var isTransitioning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handOffToExistingInstanceIfNeeded() {
            return
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleExternalReopen(_:)),
            name: Self.reopenNotification,
            object: nil
        )
        NSApp.setActivationPolicy(.accessory)

        modifierChordMonitor.start { [weak self] in
            self?.toggleWindowMode()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        modifierChordMonitor.stop()
        quitHotKey.unregister(id: 90)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        reopenMainWindow()
        return true
    }

    private func handOffToExistingInstanceIfNeeded() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard let existingInstance = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != currentPID })
        else {
            return false
        }

        DistributedNotificationCenter.default().post(
            name: Self.reopenNotification,
            object: nil,
            userInfo: nil
        )
        existingInstance.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
        return true
    }

    @objc
    private func handleExternalReopen(_ notification: Notification) {
        reopenMainWindow()
    }

    private func reopenMainWindow() {
        if mainWindow?.isVisible != true, !isTransitioning {
            expandFromIsland()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func attachMainWindow(
        _ window: NSWindow,
        islandActivity: CuratezIslandActivityController,
        captureCoordinator: CaptureCoordinator
    ) {
        mainWindow = window
        islandController.observe(islandActivity)
        // Register global capture hotkeys before the real window is folded
        // away. A SwiftUI `.task` owned by the hidden ContentView is not a
        // reliable lifecycle hook while the app lives as a non-key island.
        captureCoordinator.start()
        configureMainWindow(window)

        guard !hasEstablishedInitialState else { return }
        hasEstablishedInitialState = true
        collapseToIsland(animated: false)
    }

    private func configureMainWindow(_ window: NSWindow) {
        window.title = "Curatez"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // A borderless NSWindow cannot become key by default. That still allows
        // mouse-only buttons to work, but text fields never receive keyboard focus.
        // Keep the same chrome-free appearance with a transparent full-size titlebar
        // while retaining the normal key-window behavior of a titled window.
        window.styleMask = [.titled, .resizable, .fullSizeContentView]
        window.isMovableByWindowBackground = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 4
        window.contentView?.layer?.cornerCurve = .continuous
        window.contentView?.layer?.masksToBounds = true
        window.contentView?.layer?.borderWidth = 0
        window.contentView?.layer?.borderColor = NSColor.clear.cgColor

        if let screen = preferredScreen {
            window.setFrameOrigin(
                NSPoint(
                    x: screen.frame.midX - window.frame.width / 2,
                    y: screen.frame.midY - window.frame.height / 2
                )
            )
        }
    }

    private var preferredScreen: NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    }

    private func toggleWindowMode() {
        guard !isTransitioning else { return }
        if mainWindow?.isVisible == true {
            collapseToIsland()
        } else {
            expandFromIsland()
        }
    }

    private func collapseToIsland(animated: Bool = true) {
        guard let mainWindow else { return }
        isTransitioning = true
        quitHotKey.unregister(id: 90)
        islandController.collapse(window: mainWindow, animated: animated) { [weak self] in
            guard let self else { return }
            self.isTransitioning = false
            self.previouslyActiveApplication?.activate()
        }
    }

    private func expandFromIsland() {
        guard let mainWindow else { return }
        isTransitioning = true
        previouslyActiveApplication = NSWorkspace.shared.frontmostApplication
        quitHotKey.register(
            id: 90,
            keyCode: UInt32(kVK_ANSI_W),
            modifiers: UInt32(cmdKey)
        ) {
            NSApp.terminate(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        islandController.expand(window: mainWindow) { [weak self] in
            self?.isTransitioning = false
        }
    }
}

private struct InitialWindowConfigurator: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat
    let onWindowReady: @MainActor (NSWindow) -> Void

    init(
        width: CGFloat,
        height: CGFloat,
        onWindowReady: @escaping @MainActor (NSWindow) -> Void
    ) {
        self.width = width
        self.height = height
        self.onWindowReady = onWindowReady
    }

    func makeNSView(context: Context) -> WindowReaderView {
        WindowReaderView(width: width, height: height, onWindowReady: onWindowReady)
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {}
}

private final class WindowReaderView: NSView {
    private let initialSize: NSSize
    private let onWindowReady: @MainActor (NSWindow) -> Void
    private var hasConfiguredWindow = false

    init(
        width: CGFloat,
        height: CGFloat,
        onWindowReady: @escaping @MainActor (NSWindow) -> Void
    ) {
        initialSize = NSSize(width: width, height: height)
        self.onWindowReady = onWindowReady
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !hasConfiguredWindow else { return }
        hasConfiguredWindow = true

        // Apply after SwiftUI/AppKit window restoration has completed.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.setContentSize(self.initialSize)
            window.center()
            self.onWindowReady(window)
        }
    }
}
