import Carbon

@MainActor final class PauseHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private(set) var registrationStatus: OSStatus = noErr

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<PauseHotKey>.fromOpaque(context).takeUnretainedValue().action()
            }
            return noErr
        }, 1, &spec, context, &handler)
        guard installed == noErr else { registrationStatus = installed; return }
        let id = EventHotKeyID(signature: 0x4C504C4E, id: 1)
        registrationStatus = RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey | cmdKey), id,
                            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
