import Carbon

@MainActor
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let pressed: () -> Void
    private let released: () -> Void

    init(pressed: @escaping () -> Void, released: @escaping () -> Void) {
        self.pressed = pressed
        self.released = released
    }

    @discardableResult
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_K), modifiers: UInt32 = UInt32(cmdKey | shiftKey)) -> OSStatus {
        unregister()
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
                hotKey.pressed()
            } else {
                hotKey.released()
            }
            return noErr
        }, types.count, &types, pointer, &handler)
        guard handlerStatus == noErr else { return handlerStatus }

        let id = EventHotKeyID(signature: OSType(0x4B484149), id: 1)
        let registrationStatus = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        if registrationStatus != noErr {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
        }
        return registrationStatus
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
