import Carbon.HIToolbox
import Foundation

/// Thin wrapper over Carbon's process-wide hotkey API. Works without Accessibility
/// permission for standard modifier+key combos.
///
/// All instances share ONE installed event handler that dispatches by hotkey id to the
/// matching callback. Installing a handler per instance is wrong: each handler sees
/// *every* hotkey-pressed event, and returning `noErr` consumes it — so a second hotkey's
/// handler swallows the first hotkey's event before the first handler ever runs.
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private let hotKeyID: UInt32

    private static var callbacks: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false

    /// `id` distinguishes multiple hotkeys; the shared handler routes the fired
    /// `EventHotKeyID.id` to the callback registered under it.
    init?(keyCode: UInt32, modifiers: UInt32, id hotKeyID: UInt32 = 1, onFire: @escaping () -> Void) {
        self.hotKeyID = hotKeyID
        Self.installSharedHandler()
        Self.callbacks[hotKeyID] = onFire

        let id = EventHotKeyID(signature: OSType(0x484C_4D31), id: hotKeyID)  // 'HLM' + id
        let registered = RegisterEventHotKey(keyCode, modifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
        guard registered == noErr else {
            Self.callbacks[hotKeyID] = nil
            return nil
        }
    }

    /// Install the single shared hotkey-pressed handler once. It reads the fired
    /// `EventHotKeyID` and invokes the callback registered under that id.
    private static func installSharedHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return noErr }
            var fired = EventHotKeyID()
            let s = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                      EventParamType(typeEventHotKeyID), nil,
                                      MemoryLayout<EventHotKeyID>.size, nil, &fired)
            if s == noErr, let cb = GlobalHotKey.callbacks[fired.id] { cb() }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = (status == noErr)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        GlobalHotKey.callbacks[hotKeyID] = nil
    }
}
