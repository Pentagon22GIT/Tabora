import AppKit
import Carbon

enum GlobalShortcutDispatchPolicy {
    static func handles(
        eventSignature: OSType,
        managerSignature: OSType,
        hasRegisteredAction: Bool
    ) -> Bool {
        eventSignature == managerSignature && hasRegisteredAction
    }
}

final class GlobalShortcutManager {
    private let signature: OSType
    private var hotKeys: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    init(signature: OSType = OSType(0x534E4150)) {
        self.signature = signature
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard let action = manager.actions[id.id],
                  GlobalShortcutDispatchPolicy.handles(
                    eventSignature: id.signature,
                    managerSignature: manager.signature,
                    hasRegisteredAction: true
                  ) else {
                // Multiple managers are installed on the application target.
                // A signature mismatch belongs to a later handler and must not
                // be reported as consumed by this manager.
                return OSStatus(eventNotHandledErr)
            }
            action()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    deinit {
        clear()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func register(bindings: [ShortcutAction: ShortcutBinding], handler: @escaping (ShortcutAction) -> Void) {
        clear()
        var identifier: UInt32 = 1
        for action in ShortcutAction.allCases {
            guard let binding = bindings[action] else { continue }
            var hotKey: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: identifier)
            let status = RegisterEventHotKey(binding.keyCode, carbonModifiers(from: binding.modifiers), id, GetApplicationEventTarget(), 0, &hotKey)
            if status == noErr, let hotKey {
                hotKeys.append(hotKey)
                actions[identifier] = { handler(action) }
                identifier += 1
            }
        }
    }

    /// Registers one session-local hot key. A separate signature prevents the
    /// transient Assist handler from consuming another manager's action ID.
    @discardableResult
    func register(
        binding: ShortcutBinding,
        handler: @escaping () -> Void
    ) -> Bool {
        clear()
        var hotKey: EventHotKeyRef?
        let identifier: UInt32 = 1
        let id = EventHotKeyID(signature: signature, id: identifier)
        let status = RegisterEventHotKey(
            binding.keyCode,
            carbonModifiers(from: binding.modifiers),
            id,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard status == noErr, let hotKey else { return false }
        hotKeys.append(hotKey)
        actions[identifier] = handler
        return true
    }

    func clear() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        actions.removeAll()
    }

    private func carbonModifiers(from raw: UInt32) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(raw))
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
