import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import ScreenCaptureKit

@MainActor
final class AppServices: ObservableObject {
    let store: CaptureStore
    let capture: CaptureCoordinator
    let islandActivity: CuratezIslandActivityController

    init() {
        let store = CaptureStore()
        let islandActivity = CuratezIslandActivityController()
        self.store = store
        self.islandActivity = islandActivity
        capture = CaptureCoordinator(store: store, islandActivity: islandActivity)
    }
}

@MainActor
final class CaptureCoordinator: NSObject, ObservableObject {
    @Published private(set) var isCaptureModeEnabled = false
    @Published private(set) var statusMessage: String?
    private(set) var lastBrowserName: String?

    private let store: CaptureStore
    private let islandActivity: CuratezIslandActivityController
    private let hotKeys = GlobalHotKeyManager()
    private let tooltip = CaptureTooltipController()
    private let pasteboard = NSPasteboard.general
    private var pasteboardTimer: Timer?
    private var mouseMonitor: Any?
    private var selectionInspectionTask: Task<Void, Never>?
    private var statusResetTask: Task<Void, Never>?
    private var lastPasteboardChange = 0
    private var lastCandidateFingerprint: String?
    private var lastBrowserApplication: NSRunningApplication?
    private var hasStarted = false

    init(store: CaptureStore, islandActivity: CuratezIslandActivityController) {
        self.store = store
        self.islandActivity = islandActivity
        super.init()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        lastPasteboardChange = pasteboard.changeCount

        hotKeys.register(
            id: 1,
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: UInt32(cmdKey)
        ) { [weak self] in
            self?.toggleCaptureMode()
        }
        hotKeys.register(
            id: 2,
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: UInt32(cmdKey | optionKey)
        ) { [weak self] in
            self?.captureBrowserSnapshot()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        rememberBrowserIfNeeded(NSWorkspace.shared.frontmostApplication)
    }

    private func startCaptureObservation() {
        guard pasteboardTimer == nil, mouseMonitor == nil else { return }
        pasteboardTimer = Timer.scheduledTimer(
            timeInterval: 0.45,
            target: self,
            selector: #selector(checkPasteboard),
            userInfo: nil,
            repeats: true
        )
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .keyUp]) { [weak self] event in
            let mayHaveChangedSelection = event.type == .leftMouseUp
                || event.modifierFlags.contains(.shift)
                || (event.keyCode == UInt16(kVK_ANSI_A) && event.modifierFlags.contains(.command))
            guard mayHaveChangedSelection else { return }
            Task { @MainActor in
                self?.scheduleSelectionInspection()
            }
        }
    }

    private func stopCaptureObservation() {
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        selectionInspectionTask?.cancel()
        selectionInspectionTask = nil
    }

    private func scheduleSelectionInspection() {
        guard isCaptureModeEnabled else { return }
        selectionInspectionTask?.cancel()
        selectionInspectionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.inspectSelectedText()
            self?.selectionInspectionTask = nil
        }
    }

    func toggleCaptureMode() {
        isCaptureModeEnabled.toggle()
        tooltip.close()
        lastCandidateFingerprint = nil
        lastPasteboardChange = pasteboard.changeCount

        if isCaptureModeEnabled {
            startCaptureObservation()
            islandActivity.set(.captureReady)
            if AXIsProcessTrusted() {
                showStatus("采集模式已开启 · 选中文本或复制图片即可收藏")
            } else {
                // Do not call AXIsProcessTrustedWithOptions(prompt: true) on
                // every toggle. During development a changed code signature
                // can make TCC briefly report false even when an older build
                // is listed in Settings, which otherwise causes a prompt loop.
                showStatus("采集模式已开启 · 辅助功能权限未生效时请在系统设置中重新勾选 Curatez")
            }
        } else {
            stopCaptureObservation()
            islandActivity.set(.idle)
            showStatus("采集模式已关闭")
        }
    }

    func captureBrowserSnapshot() {
        Task {
            await performBrowserSnapshot()
        }
    }

    @objc private func checkPasteboard() {
        let change = pasteboard.changeCount
        guard change != lastPasteboardChange else { return }
        lastPasteboardChange = change
        guard isCaptureModeEnabled else { return }

        if let image = NSImage(pasteboard: pasteboard) {
            present(candidate: .copiedImage(image), fingerprint: "image:\(change)")
            return
        }

        let copiedString = pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string)
        if let text = copiedString?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            switch ClipboardTextRecognizer.recognize(text) {
            case .webURL(let url):
                let candidate: CaptureCandidate = VideoSupport.isPlayableRemoteURL(url)
                    ? .copiedVideoURL(url)
                    : .copiedURL(url)
                present(candidate: candidate, fingerprint: "url:\(url.absoluteString)")
            case .text(let text):
                present(candidate: .copiedText(text), fingerprint: "text:\(text.hashValue)")
            }
        }
    }

    private func inspectSelectedText() {
        guard isCaptureModeEnabled, AXIsProcessTrusted() else { return }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedValue else { return }

        let focusedElement = focusedValue as! AXUIElement
        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success,
              let selectedText = selectedValue as? String else { return }

        let cleanText = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanText.count >= 2 else { return }
        present(candidate: .selectedText(cleanText), fingerprint: "selection:\(cleanText.hashValue)")
    }

    private func present(candidate: CaptureCandidate, fingerprint: String) {
        guard fingerprint != lastCandidateFingerprint else { return }
        lastCandidateFingerprint = fingerprint
        let task = taskKind(for: candidate)
        islandActivity.set(CuratezIslandActivity(task: task, status: .needsAttention))

        tooltip.show(
            candidate: candidate,
            onSave: { [weak self] in
                guard let self else { return }
                do {
                    switch candidate {
                    case .selectedText(let text), .copiedText(let text):
                        try self.store.saveText(text, sourceURL: self.currentBrowserURL())
                    case .copiedURL(let url):
                        try self.store.saveLink(url)
                    case .copiedVideoURL(let url):
                        try self.store.saveVideoURL(url)
                    case .copiedImage(let image):
                        try self.store.saveImage(image, sourceURL: self.currentBrowserURL())
                    }
                    self.islandActivity.showTransient(
                        CuratezIslandActivity(task: task, status: .succeeded),
                        revertingTo: self.restingIslandActivity
                    )
                    self.showStatus("已加入 \(self.store.selectedCollection?.name ?? "收藏文件夹")")
                } catch {
                    self.islandActivity.showTransient(
                        CuratezIslandActivity(task: task, status: .failed),
                        revertingTo: self.restingIslandActivity
                    )
                    self.showStatus("保存失败：\(error.localizedDescription)")
                }
            },
            onDismiss: { [weak self] in
                guard let self else { return }
                self.islandActivity.set(self.restingIslandActivity)
            }
        )
    }

    private func performBrowserSnapshot() async {
        let task = CuratezTaskKind.browserSnapshot
        islandActivity.set(CuratezIslandActivity(task: task, status: .processing))
        guard let browser = resolvedBrowserApplication() else {
            showTaskFailure(task)
            showStatus("请先打开并使用 Safari、Chrome、Arc、Edge 或 Brave")
            return
        }

        if !CGPreflightScreenCaptureAccess() {
            let granted = CGRequestScreenCaptureAccess()
            guard granted else {
                showTaskFailure(task)
                showStatus("需要在系统设置中允许 Curatez 录制屏幕")
                return
            }
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
            guard let window = content.windows
                .filter({ $0.owningApplication?.processID == browser.processIdentifier && $0.frame.width > 300 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                showTaskFailure(task)
                showStatus("没有找到可见的浏览器窗口")
                return
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scale = backingScale(for: window.frame)
            configuration.width = max(1, Int(window.frame.width * scale))
            configuration.height = max(1, Int(window.frame.height * scale))
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            let url = browserURL(for: browser)
            let title = window.title?.isEmpty == false ? window.title! : "\(browser.localizedName ?? "Browser") snapshot"
            try await store.saveSnapshot(image, title: title, sourceURL: url)
            islandActivity.showTransient(
                CuratezIslandActivity(task: task, status: .succeeded),
                revertingTo: restingIslandActivity
            )
            showStatus(url == nil ? "页面快照已保存（浏览器未授权读取网址）" : "页面快照和网址已保存")
        } catch {
            showTaskFailure(task)
            showStatus("页面快照失败：\(error.localizedDescription)")
        }
    }

    private var restingIslandActivity: CuratezIslandActivity {
        isCaptureModeEnabled ? .captureReady : .idle
    }

    private func taskKind(for candidate: CaptureCandidate) -> CuratezTaskKind {
        switch candidate {
        case .selectedText, .copiedText: .captureText
        case .copiedURL: .captureLink
        case .copiedVideoURL: .captureVideo
        case .copiedImage: .captureImage
        }
    }

    private func showTaskFailure(_ task: CuratezTaskKind) {
        islandActivity.showTransient(
            CuratezIslandActivity(task: task, status: .failed),
            revertingTo: restingIslandActivity
        )
    }

    private func backingScale(for rect: CGRect) -> CGFloat {
        NSScreen.screens.first(where: { $0.frame.intersects(rect) })?.backingScaleFactor ?? 2
    }

    @objc private func applicationActivated(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        rememberBrowserIfNeeded(app)
    }

    private func rememberBrowserIfNeeded(_ application: NSRunningApplication?) {
        guard let application, Self.supportedBrowserIDs.contains(application.bundleIdentifier ?? "") else { return }
        lastBrowserApplication = application
        lastBrowserName = application.localizedName
    }

    private func resolvedBrowserApplication() -> NSRunningApplication? {
        if let current = NSWorkspace.shared.frontmostApplication,
           Self.supportedBrowserIDs.contains(current.bundleIdentifier ?? "") {
            rememberBrowserIfNeeded(current)
            return current
        }
        return lastBrowserApplication?.isTerminated == false ? lastBrowserApplication : nil
    }

    private func currentBrowserURL() -> String? {
        guard let browser = resolvedBrowserApplication() else { return nil }
        return browserURL(for: browser)
    }

    private func browserURL(for application: NSRunningApplication) -> String? {
        guard let bundleID = application.bundleIdentifier else { return nil }
        let tabExpression = bundleID == "com.apple.Safari"
            ? "URL of current tab of front window"
            : "URL of active tab of front window"
        let source = "tell application id \"\(bundleID)\" to get \(tabExpression)"
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
    }

    private func showStatus(_ message: String) {
        statusResetTask?.cancel()
        statusMessage = message
        statusResetTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(3.2))
            } catch {
                return
            }
            guard !Task.isCancelled, self?.statusMessage == message else { return }
            self?.statusMessage = nil
            self?.statusResetTask = nil
        }
    }

    private static let supportedBrowserIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.brave.Browser"
    ]

}
