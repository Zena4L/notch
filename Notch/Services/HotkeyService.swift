import Carbon.HIToolbox

/// System-wide keyboard shortcuts through Carbon's hot key API, which,
/// unlike key-event taps, doesn't need Accessibility permission.
final class HotkeyService {
    private var handlers: [UInt32: () -> Void] = [:]
    private var hotKeys: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            let service = Unmanaged<HotkeyService>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { service.handlers[hotKeyID.id]?() }
            return noErr
        }, 1, &spec, context, &eventHandler)
    }

    /// Registers `shortcut`. Returns false if it isn't set or another app already owns it.
    @discardableResult
    func register(_ shortcut: KeyShortcut, action: @escaping () -> Void) -> Bool {
        guard shortcut.isSet else { return false }
        return register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, action: action)
    }

    func unregisterAll() {
        for ref in hotKeys { UnregisterEventHotKey(ref) }
        hotKeys.removeAll()
        handlers.removeAll()
    }

    /// `keyCode` is a `kVK_…` constant; `modifiers` combines `cmdKey`, `optionKey`, etc.
    @discardableResult
    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) -> Bool {
        let id = EventHotKeyID(signature: OSType(0x4E54_4348), id: nextID)  // 'NTCH'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("Notch: couldn't register shortcut \(keyCode) (status \(status)) — another app may be using it")
            return false
        }
        hotKeys.append(ref)
        handlers[nextID] = action
        nextID += 1
        return true
    }
}
