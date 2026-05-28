import Cocoa
import SwiftUI
import Carbon.HIToolbox
import HelmCore

/// Reap dead sessions' state files off the main thread (pure filesystem work, no UI).
private func reapDeadState() {
    _Concurrency.Task.detached(priority: .utility) { SessionStore().reapDeadState() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: OverlayPanel!
    private let shell = AppShellModel()
    private let model = SessionListViewModel()
    private let tasksModel = TaskListViewModel()
    private var newProjectModel = ProjectCreateViewModel()
    private var hotKey: GlobalHotKey?
    private var keyMonitor: Any?
    private var reaper: Timer?

    // Summon hotkey: ⌥Space.
    private let hotKeyCode = UInt32(kVK_Space)
    private let hotKeyMods = UInt32(optionKey)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = RootView(
            shell: shell,
            sessions: model,
            tasks: tasksModel,
            newProject: newProjectModel,
            onPickSession:       { [weak self] in self?.pick($0) },
            onNewChat:           { [weak self] in self?.newChat() },
            onOpenTask:          { [weak self] in self?.openTask($0) },
            onCycleTask:         { [weak self] in self?.tasksModel.cycleSelected() },
            onOpenSource:        { [weak self] in self?.openSource($0) },
            onCancelNewProject:  { [weak self] in self?.dismissNewProject() },
            onCreatedProject:    { [weak self] in self?.afterProjectCreated($0) },
            onDismiss:           { [weak self] in self?.hide() })
        panel = OverlayPanel(content: NSHostingView(rootView: root))
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }

        hotKey = GlobalHotKey(keyCode: hotKeyCode, modifiers: hotKeyMods) { [weak self] in
            self?.toggle()
        }
        if hotKey == nil {
            NSLog("Helm: failed to register global hotkey (⌥Space may be taken).")
        }

        model.reloadInBackground()        // warm both caches so the first summon is instant
        tasksModel.reloadInBackground()
        startReaping()
    }

    private func startReaping() {
        reapDeadState()
        reaper = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            reapDeadState()
        }
    }

    // MARK: Show / hide

    private func toggle() { panel.isVisible ? hide() : show() }

    private func show() {
        shell.view = .sessions            // each summon starts on sessions (the primary use)
        panel.positionUpperMiddle()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        model.startTicking()
        tasksModel.startTicking()
        model.reloadInBackground()
        tasksModel.reloadInBackground()
    }

    private func hide() {
        removeKeyMonitor()
        model.stopTicking()
        tasksModel.stopTicking()
        model.exitFocus()
        panel.orderOut(nil)
    }

    // MARK: Actions

    private func pick(_ session: ChatSession) {
        hide()
        if session.isPlaceholder {
            TerminalDispatcher.newChat(cwd: session.cwd)
        } else {
            TerminalDispatcher.resume(sessionId: session.sessionId, cwd: session.cwd, pid: session.pid)
        }
    }

    private func newChat() {
        let cwd = model.selectedSession?.cwd
        hide()
        TerminalDispatcher.newChat(cwd: cwd?.nonEmpty ?? NSHomeDirectory())
    }

    /// Open the new-project form over the sessions view. A fresh ViewModel each summon
    /// so the form starts clean (drops any partial state from a previous open).
    private func presentNewProject() {
        newProjectModel = ProjectCreateViewModel()
        shell.presentingNewProject = true
    }

    private func dismissNewProject() {
        shell.presentingNewProject = false
    }

    /// All worktrees succeeded → drop the form, hide the panel, and drop the user into
    /// a fresh chat at the project root so they can bootstrap PROJECT.md immediately.
    private func afterProjectCreated(_ projectRoot: URL) {
        shell.presentingNewProject = false
        hide()
        model.reloadInBackground()        // surface the new project in the sessions list
        TerminalDispatcher.newChat(cwd: projectRoot.path)
    }

    private func killSelected() {
        guard let s = model.selectedSession, let pid = s.pid else { return }
        TerminalDispatcher.closePane(pid: pid)
        model.kill(sessionId: s.sessionId, pid: pid)
    }

    /// Open a task's markdown file in the user's editor. Defaults to `zed`; the
    /// `taskEditor` config field picks something else (`code`, `cursor`, `open` for the
    /// macOS default). The vault path is hardcoded; matches the widget.
    private func openTask(_ task: VaultTask) {
        let folder = task.archived ? "archive" : "tasks"
        let path = "\(NSHomeDirectory())/Home/task-vault/\(folder)/\(task.basename).md"
        hide()
        let editor = HelmConfig.load().taskEditor
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = editor.argv + [path]
        try? p.run()
    }

    /// Open a task's source URL (Jira ticket / Slack thread) in the default browser
    /// or Slack desktop app. The Slack deep-link rewrite (jumping to the desktop
    /// client instead of the browser) the widget does is deferred — keep the simple
    /// `open <url>` path for now.
    private func openSource(_ source: TaskSource) {
        let url: String
        switch source {
        case .jira(_, let u):  url = u
        case .slack(let u):    url = u
        }
        NSWorkspace.shared.open(URL(string: url)!)
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
        let shift = event.modifierFlags.contains(.shift)

        // Form-up: only intercept Esc (dismiss form) plus the standard edit shortcuts —
        // those need to be re-dispatched through the responder chain because an
        // LSUIElement app with no main menu won't auto-route them to the field editor.
        if shell.presentingNewProject {
            if Int(event.keyCode) == kVK_Escape {
                dismissNewProject(); return true
            }
            if cmd, let sel = standardEditSelector(keyCode: Int(event.keyCode), shift: shift) {
                NSApp.sendAction(sel, to: nil, from: nil)
                return true
            }
            return false
        }

        // View switching: ⌘1 = sessions, ⌘2 = tasks. Global to both views.
        if cmd {
            switch Int(event.keyCode) {
            case kVK_ANSI_1: shell.view = .sessions; return true
            case kVK_ANSI_2: shell.view = .tasks;    return true
            default: break
            }
        }
        // ⌘⇧N = open new-project form (any view).
        if cmd && shift && Int(event.keyCode) == kVK_ANSI_N {
            presentNewProject(); return true
        }

        switch shell.view {
        case .sessions: return handleSessions(event, cmd: cmd, option: option)
        case .tasks:    return handleTasks(event, cmd: cmd, option: option)
        }
    }

    private func handleSessions(_ event: NSEvent, cmd: Bool, option: Bool) -> Bool {
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
        return appendIfPrintable(event, cmd: cmd, to: { [weak self] in self?.model.appendQuery($0) })
    }

    private func handleTasks(_ event: NSEvent, cmd: Bool, option: Bool) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape:                                            hide(); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if cmd { tasksModel.cycleSelected() }
            else if let t = tasksModel.selectedTask { openTask(t) }
            return true
        case kVK_DownArrow:   tasksModel.clearSelection(); tasksModel.move(by: 1);  return true
        case kVK_UpArrow:     tasksModel.clearSelection(); tasksModel.move(by: -1); return true
        case kVK_ANSI_A where cmd: tasksModel.selectAllQuery();  return true
        case kVK_Delete:
            if cmd        { tasksModel.clearQuery() }
            else if option { tasksModel.deleteWordBack() }
            else           { tasksModel.backspaceQuery() }
            return true
        default: break
        }
        return appendIfPrintable(event, cmd: cmd, to: { [weak self] in self?.tasksModel.appendQuery($0) })
    }

    /// Walk the responder chain for the standard edit verbs. Returning a selector means
    /// "this is ⌘<key> for selectAll / copy / paste / cut / undo / redo"; nil means we
    /// don't recognize the chord.
    private func standardEditSelector(keyCode: Int, shift: Bool) -> Selector? {
        switch keyCode {
        case kVK_ANSI_A: return #selector(NSText.selectAll(_:))
        case kVK_ANSI_C: return #selector(NSText.copy(_:))
        case kVK_ANSI_V: return #selector(NSText.paste(_:))
        case kVK_ANSI_X: return #selector(NSText.cut(_:))
        case kVK_ANSI_Z: return shift ? Selector(("redo:")) : Selector(("undo:"))
        default: return nil
        }
    }

    /// Typeahead: a printable character (no ⌘) extends the active view's filter query.
    private func appendIfPrintable(_ event: NSEvent, cmd: Bool, to append: @escaping (String) -> Void) -> Bool {
        guard !cmd, let chars = event.charactersIgnoringModifiers,
              chars.count == 1, let c = chars.first,
              !c.isASCII || c.isLetter || c.isNumber || c == " " || c == "-" || c == "_" else {
            return false
        }
        append(chars)
        return true
    }
}
