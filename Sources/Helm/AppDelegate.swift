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

    // Summon hotkey: ⌥Space.
    private let hotKeyCode = UInt32(kVK_Space)
    private let hotKeyMods = UInt32(optionKey)

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
            NSLog("Helm: failed to register global hotkey (⌥Space may be taken).")
        }

        model.reloadInBackground()   // warm the cache so the first summon is instant
    }

    // MARK: Show / hide

    private func toggle() { panel.isVisible ? hide() : show() }

    private func show() {
        panel.positionUpperMiddle()
        panel.makeKeyAndOrderFront(nil)   // nonactivating: keys come to us, app stays inactive
        installKeyMonitor()
        model.startTicking()              // age labels count up while open
        model.reloadInBackground()        // show instantly with cached data; refresh behind it
    }

    private func hide() {
        removeKeyMonitor()
        model.stopTicking()
        model.exitFocus()                 // next summon starts at the full list
        panel.orderOut(nil)               // focus returns to whatever was active (the terminal)
    }

    // MARK: Actions

    private func pick(_ session: ChatSession) {
        hide()
        TerminalDispatcher.resume(sessionId: session.sessionId, cwd: session.cwd, pid: session.pid)
    }

    private func newChat() {
        let cwd = model.selectedSession?.cwd
        hide()
        TerminalDispatcher.newChat(cwd: cwd?.nonEmpty ?? NSHomeDirectory())
    }

    /// Kill the selected live session (idle → dead) and close its terminal pane. Resolve
    /// the pane (via tty) before terminating, or `ps` can't map the pid. Only live rows
    /// have a pid; the row stays as a resumable cold row afterward.
    private func killSelected() {
        guard let s = model.selectedSession, let pid = s.pid else { return }
        TerminalDispatcher.closePane(pid: pid)
        SessionStore.terminate(pid)
        SessionStore.clearState(s.sessionId)   // SessionEnd hook won't run on a killed proc
        model.markDead(s.sessionId)            // optimistic: flip to dead now, don't await poll
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.model.reloadInBackground()   // reconcile with the filesystem
        }
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
        let option = event.modifierFlags.contains(.option)

        switch Int(event.keyCode) {
        case kVK_Escape:
            if model.focusedProject != nil { model.exitFocus() } else { hide() }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let s = model.selectedSession { pick(s) };   return true
        case kVK_DownArrow where cmd: model.focusSelectedProject();       return true
        case kVK_UpArrow where cmd:   model.exitFocus();                  return true
        case kVK_DownArrow:   model.clearSelection(); model.move(by: 1);  return true
        case kVK_UpArrow:     model.clearSelection(); model.move(by: -1); return true
        case kVK_ANSI_A where cmd: model.selectAllQuery();  return true
        case kVK_Delete:
            if cmd        { model.clearQuery() }
            else if option { model.deleteWordBack() }
            else           { model.backspaceQuery() }
            return true
        case kVK_ANSI_N where cmd: newChat();               return true
        case kVK_ANSI_X where cmd: killSelected();          return true
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
