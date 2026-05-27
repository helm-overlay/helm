import Carbon.HIToolbox
import Foundation

/// Thin wrapper over Carbon's process-wide hotkey API. Works without Accessibility
/// permission for standard modifier+key combos.
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onFire: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, onFire: @escaping () -> Void) {
        self.onFire = onFire

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().onFire()
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
        guard installed == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x484C_4D31), id: 1)  // 'HLM1'
        let registered = RegisterEventHotKey(keyCode, modifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
        guard registered == noErr else { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
