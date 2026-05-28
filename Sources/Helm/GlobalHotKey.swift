import Carbon.HIToolbox
import Foundation

/// Thin wrapper over Carbon's process-wide hotkey API. Works without Accessibility
/// permission for standard modifier+key combos.
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onFire: () -> Void
    private let hotKeyID: UInt32

    /// `id` distinguishes multiple hotkeys: each instance installs its own app-target
    /// handler, which sees *every* hotkey-pressed event, so the handler filters on the
    /// fired `EventHotKeyID` and only fires for its own id.
    init?(keyCode: UInt32, modifiers: UInt32, id hotKeyID: UInt32 = 1, onFire: @escaping () -> Void) {
        self.onFire = onFire
        self.hotKeyID = hotKeyID

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            var fired = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &fired)
            if status == noErr, fired.id == me.hotKeyID { me.onFire() }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
        guard installed == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x484C_4D31), id: hotKeyID)  // 'HLM' + id
        let registered = RegisterEventHotKey(keyCode, modifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
        guard registered == noErr else { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
