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
    private var hotKey: GlobalHotKey?
    private var jumpHotKey: GlobalHotKey?
    private var keyMonitor: Any?
    private var reaper: Timer?
    private var notifyTimer: Timer?
    private var notifier: SessionNotifier!

    /// Last session the jump hotkey landed on, so repeated presses cycle through the
    /// sessions wanting attention rather than re-opening the same one.
    private var jumpCursor: String?

    // Summon hotkey: ⌥Space. Jump-to-next-attention: ⌥⇧Space.
    private let hotKeyCode = UInt32(kVK_Space)
    private let hotKeyMods = UInt32(optionKey)
    private let jumpHotKeyMods = UInt32(optionKey | shiftKey)

    /// ANSI keyCodes for the 1–9 row keys, mapped to their digit. The codes aren't
    /// contiguous, so they're spelled out rather than offset from kVK_ANSI_1.
    private static let digitKeyCodes: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = RootView(
            shell: shell,
            sessions: model,
            tasks: tasksModel,
            onPickSession:       { [weak self] in self?.pick($0) },
            onNewChat:           { [weak self] in self?.newChat() },
            onOpenTask:          { [weak self] in self?.openTask($0) },
            onCycleTask:         { [weak self] in self?.tasksModel.cycleSelected() },
            onOpenSource:        { [weak self] in self?.openSource($0) },
            onDismiss:           { [weak self] in self?.hide() })
        panel = OverlayPanel(content: NSHostingView(rootView: root))
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }

        hotKey = GlobalHotKey(keyCode: hotKeyCode, modifiers: hotKeyMods, id: 1) { [weak self] in
            self?.toggle()
        }
        if hotKey == nil {
            NSLog("Helm: failed to register global hotkey (⌥Space may be taken).")
        }

        // ⌥⇧Space jumps straight to the session that wants you — no list, no scanning.
        jumpHotKey = GlobalHotKey(keyCode: hotKeyCode, modifiers: jumpHotKeyMods, id: 2) { [weak self] in
            self?.jumpToNextAttention()
        }
        if jumpHotKey == nil {
            NSLog("Helm: failed to register jump hotkey (⌥⇧Space may be taken).")
        }

        model.reloadInBackground(animated: false) // warm both caches so the first summon is instant
        tasksModel.reloadInBackground()
        startReaping()
        startNotifying()
    }

    private func startReaping() {
        reapDeadState()
        reaper = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            reapDeadState()
        }
    }

    /// Watch session state for attention crossings and notify — independent of the panel's
    /// own ticker, which only runs while visible. Resuming from a banner jumps into the
    /// session, mirroring the jump hotkey.
    private func startNotifying() {
        notifier = SessionNotifier { [weak self] sessionId, agent, cwd in
            self?.resumeFromNotification(sessionId: sessionId, agent: agent, cwd: cwd)
        }
        notifier.requestAuthorization()
        pollNotifications()
        notifyTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollNotifications() }
        }
    }

    private func pollNotifications() {
        let visible = panel.isVisible
        _Concurrency.Task.detached(priority: .utility) {
            let rows = SessionStore().load()
            await MainActor.run { self.notifier.reconcile(rows, panelVisible: visible) }
        }
    }

    /// Resolve the (possibly changed) session fresh and resume it; fall back to the id/cwd
    /// carried in the banner if it's no longer in the list.
    private func resumeFromNotification(sessionId: String, agent: AgentKind, cwd: String?) {
        if panel.isVisible { hide() }
        _Concurrency.Task.detached(priority: .userInitiated) {
            let match = SessionStore().load().first { $0.sessionId == sessionId && $0.agent == agent }
            await MainActor.run {
                if let match { TerminalDispatcher.resume(match) }
                else { TerminalDispatcher.resume(sessionId: sessionId, cwd: cwd) }
            }
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
        model.reloadInBackground(animated: false)
        model.resetNav()                  // each summon begins focused on the LIVE rail
        tasksModel.reloadInBackground()
    }

    private func hide() {
        removeKeyMonitor()
        model.stopTicking()
        tasksModel.stopTicking()
        panel.orderOut(nil)
    }

    // MARK: Actions

    private func pick(_ session: ChatSession) {
        hide()
        if session.isPlaceholder {
            TerminalDispatcher.newChat(cwd: session.cwd)
        } else {
            TerminalDispatcher.resume(session)
        }
    }

    private func newChat() {
        let cwd = model.selectedSession?.cwd
        hide()
        TerminalDispatcher.newChat(cwd: cwd?.nonEmpty ?? NSHomeDirectory())
    }

    /// ⌥⇧Space: jump straight to the session that wants you — needs-input first, then
    /// needs-review — cycling through them on repeated presses. Loads fresh so it works
    /// with the panel closed; beeps if nothing is waiting on you.
    private func jumpToNextAttention() {
        let after = jumpCursor
        _Concurrency.Task.detached(priority: .userInitiated) {
            let next = SessionStore.nextAttentionSession(in: SessionStore().load(), after: after)
            await MainActor.run {
                guard let next else { NSSound.beep(); return }
                self.jumpCursor = next.id
                if self.panel.isVisible { self.hide() }
                TerminalDispatcher.resume(next)
            }
        }
    }

    private func killSelected() {
        guard let s = model.selectedSession, let pid = s.pid else { return }
        TerminalDispatcher.closePane(pid: pid)
        model.kill(s, pid: pid)
    }

    private func addWorkspaceFolders() {
        DispatchQueue.main.async { [weak self] in
            self?.presentWorkspaceFolderPicker()
        }
    }

    private func presentWorkspaceFolderPicker() {
        let shouldRestorePanel = panel.isVisible
        if shouldRestorePanel { hide() }

        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = true
        picker.canCreateDirectories = false
        picker.prompt = "Add"
        picker.message = "Choose project folders to show in Helm."

        NSApp.activate(ignoringOtherApps: true)
        let response = picker.runModal()
        if response == .OK {
            do {
                _ = try HelmConfig.addWorkspaceFolders(picker.urls.map(\.path))
                model.reloadInBackground()
            } catch {
                NSLog("Helm: failed to save workspace folders: \(error)")
                NSSound.beep()
            }
        }

        if shouldRestorePanel { show() }
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
        guard let parsed = URL(string: url) else {
            NSLog("Helm: task source URL is unopenable: \(url)")
            return
        }
        NSWorkspace.shared.open(parsed)
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

        // View switching: ⌘<digit> selects the view at that slot in AppView.allCases.
        // Global to every view; a new AppView case is reachable here with no edit.
        if cmd {
            if let digit = Self.digitKeyCodes[Int(event.keyCode)], let view = AppView.forDigit(digit) {
                shell.view = view; return true
            }
            if Int(event.keyCode) == kVK_ANSI_O { addWorkspaceFolders(); return true }
        }
        switch shell.view {
        case .sessions: return handleSessions(event, cmd: cmd, option: option)
        case .tasks:    return handleTasks(event, cmd: cmd, option: option)
        }
    }

    private func handleSessions(_ event: NSEvent, cmd: Bool, option: Bool) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape:      hide();                                      return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let s = model.selectedSession { pick(s) };   return true
        case kVK_DownArrow:   model.clearSelection(); model.navDown();  return true
        case kVK_UpArrow:     model.clearSelection(); model.navUp();    return true
        case kVK_LeftArrow:   model.clearSelection(); model.navLeft();  return true
        case kVK_RightArrow:  model.clearSelection(); model.navRight(); return true
        case kVK_ANSI_A where cmd: model.selectAllQuery();  return true
        case kVK_Delete:
            if cmd {
                if model.query.isEmpty {
                    if !model.removeSelectedWorkspaceFolder() { NSSound.beep() }
                } else {
                    model.clearQuery()
                }
            } else if option { model.deleteWordBack() }
            else             { model.backspaceQuery() }
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
