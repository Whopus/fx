import Carbon.HIToolbox
import Foundation

final class GlobalHotKeyManager: @unchecked Sendable {
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var callbacks: [UInt32: @MainActor () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                // More than one manager installs a handler on the application
                // event target. An earlier manager must not consume a hotkey it
                // does not own, or the manager that registered that id never
                // sees it (capture ids 1/2 were swallowed by the window manager).
                return manager.invoke(id: hotKeyID.id) ? noErr : OSStatus(eventNotHandledErr)
            },
            1,
            &eventType,
            context,
            &eventHandler
        )
    }

    func register(
        id: UInt32,
        keyCode: UInt32,
        modifiers: UInt32,
        callback: @escaping @MainActor () -> Void
    ) {
        unregister(id: id)
        callbacks[id] = callback

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: fourCharacterCode("CRTZ"), id: id)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        if status == noErr, let reference {
            hotKeys[id] = reference
        }
    }

    func unregister(id: UInt32) {
        if let reference = hotKeys.removeValue(forKey: id) {
            UnregisterEventHotKey(reference)
        }
        callbacks.removeValue(forKey: id)
    }

    @discardableResult
    private func invoke(id: UInt32) -> Bool {
        guard let callback = callbacks[id] else { return false }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                callback()
            }
        }
        return true
    }

    deinit {
        for hotKey in hotKeys.values {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }
}

private func fourCharacterCode(_ string: String) -> FourCharCode {
    string.utf8.reduce(0) { ($0 << 8) + FourCharCode($1) }
}
