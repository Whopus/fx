import CoreGraphics
import Foundation

/// Polls the modifier-only shortcut off the main actor. Modifier-only chords
/// cannot be registered through Carbon hot keys, but their 20 Hz sampling does
/// not need to interrupt SwiftUI layout or animation work.
@MainActor
final class ModifierChordMonitor {
    private var poller: ModifierFlagPoller?

    func start(callback: @escaping @MainActor @Sendable () -> Void) {
        stop()
        let poller = ModifierFlagPoller(callback: callback)
        self.poller = poller
        poller.start()
    }

    func stop() {
        poller?.stop()
        poller = nil
    }
}

private final class ModifierFlagPoller: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.curatez.modifier-chord",
        qos: .userInteractive
    )
    private let callback: @MainActor @Sendable () -> Void
    private var timer: DispatchSourceTimer?
    private var isChordLatched = false

    init(callback: @escaping @MainActor @Sendable () -> Void) {
        self.callback = callback
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(50),
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in
            self?.pollModifierKeys()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        isChordLatched = false
    }

    private func pollModifierKeys() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let commandAndControl = flags.contains(.maskCommand) && flags.contains(.maskControl)
        let conflictingModifier = flags.contains(.maskAlternate) || flags.contains(.maskShift)
        let isChordDown = commandAndControl && !conflictingModifier

        if isChordDown, !isChordLatched {
            isChordLatched = true
            let callback = callback
            DispatchQueue.main.async {
                callback()
            }
        } else if !isChordDown {
            isChordLatched = false
        }
    }
}
