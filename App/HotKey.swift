import Carbon.HIToolbox

/// A global keyboard shortcut (works while other apps are in front). Default: ⌘⇧1.
final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private static var nextID: UInt32 = 1

    private var ref: EventHotKeyRef?
    private let id: UInt32

    init(keyCode: UInt32 = UInt32(kVK_ANSI_1), modifiers: UInt32 = UInt32(cmdKey | shiftKey), action: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        Self.installHandlerIfNeeded()
        Self.actions[id] = action
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C42_4C54) /* 'LBLT' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { NSLog("LabelIt: couldn't register shortcut (\(status)); another app may be using it.") }
    }

    isolated deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.actions[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            // Carbon delivers hot keys on the main thread.
            MainActor.assumeIsolated { HotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
