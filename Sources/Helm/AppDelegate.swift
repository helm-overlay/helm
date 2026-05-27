import Cocoa
import SwiftUI
import Carbon.HIToolbox
import HelmCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: OverlayPanel!
    private let model = SessionListViewModel()
    private var hotKey: GlobalHotKey?
    private var keyMonitor: Any?

    // Default summon hotkey: ⌃⌥⌘H  (mnemonic: Helm). Unlikely to clash.
    private let hotKeyCode = UInt32(kVK_ANSI_H)
    private let hotKeyMods = UInt32(controlKey | optionKey | cmdKey)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = OverlayView(model: model,
                               onPick: { [weak self] in self?.pick($0) },
                               onNewChat: { [weak self] in self?.newChat() },
                               onDismiss: { [weak self] in self?.hide() })
        panel = OverlayPanel(content: NSHostingView(rootView: root))

        hotKey = GlobalHotKey(keyCode: hotKeyCode, modifiers: hotKeyMods) { [weak self] in
            self?.toggle()
        }
        if hotKey == nil {
            NSLog("Helm: failed to register global hotkey (⌃⌥⌘H may be taken).")
        }
    }

    // MARK: Show / hide

    private func toggle() { panel.isVisible ? hide() : show() }

    private func show() {
        model.reload()
        panel.positionAtTop()
        panel.makeKeyAndOrderFront(nil)   // nonactivating: keys come to us, app stays inactive
        installKeyMonitor()
    }

    private func hide() {
        removeKeyMonitor()
        panel.orderOut(nil)               // focus returns to whatever was active (the terminal)
    }

    // MARK: Actions

    private func pick(_ session: ChatSession) {
        hide()
        TerminalDispatcher.resume(sessionId: session.sessionId, cwd: session.cwd)
    }

    private func newChat() {
        let cwd = model.selectedSession?.cwd
        hide()
        TerminalDispatcher.newChat(cwd: cwd?.nonEmpty ?? NSHomeDirectory())
    }

    // MARK: Key handling (local monitor while visible)

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true if the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.contains(.command)

        switch Int(event.keyCode) {
        case kVK_Escape:      hide();                       return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let s = model.selectedSession { pick(s) };   return true
        case kVK_DownArrow:   model.move(by: 1);            return true
        case kVK_UpArrow:     model.move(by: -1);           return true
        case kVK_Delete:      model.backspaceQuery();       return true
        case kVK_ANSI_N where cmd: newChat();               return true
        default: break
        }

        // Typeahead: printable characters extend the filter query.
        if !cmd, let chars = event.charactersIgnoringModifiers,
           chars.count == 1, let c = chars.first, !c.isASCII || c.isLetter || c.isNumber || c == " " || c == "-" || c == "_" {
            model.appendQuery(chars)
            return true
        }
        return false
    }
}
