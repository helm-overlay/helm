import Cocoa
import SwiftUI
import Carbon.HIToolbox
import Combine
import HelmCore

/// Reap dead sessions' state files off the main thread (pure filesystem work, no UI).
private func reapDeadState() {
    _Concurrency.Task.detached(priority: .utility) { SessionStore().reapDeadState() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: OverlayPanel!
    private let shell = AppShellModel()
    private let attentionModel = AttentionListViewModel()
    private let model = SessionListViewModel()
    private let tasksModel = TaskListViewModel()
    private let prsModel = PRListViewModel()
    private let newChatModel = NewChatViewModel()
    private var hotKey: GlobalHotKey?
    private var jumpHotKey: GlobalHotKey?
    private var keyMonitor: Any?
    private var reaper: Timer?
    private var notifyTimer: Timer?
    private var notifier: SessionNotifier!
    private var cancellables = Set<AnyCancellable>()

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
            attention: attentionModel,
            sessions: model,
            tasks: tasksModel,
            prs: prsModel,
            newChat: newChatModel,
            onPickSession:       { [weak self] in self?.pick($0) },
            onNewChat:           { [weak self] in self?.openNewChatPicker() },
            onLaunchNewChat:     { [weak self] in self?.newChatInProject($0) },
            onOpenTask:          { [weak self] in self?.openTask($0) },
            onCycleTask:         { [weak self] in self?.tasksModel.cycleSelected() },
            onOpenSource:        { [weak self] in self?.openSource($0) },
            onOpenPR:            { [weak self] in self?.openPR($0) },
            onOpenAttention:     { [weak self] in self?.openAttentionItem($0) },
            onResize:            { [weak self] in self?.resizePanel(for: $0) },
            onDismiss:           { [weak self] in self?.hide() })
        panel = OverlayPanel(content: NSHostingView(rootView: root))
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }

        // View-switch resizing is driven by RootView (onResize), timed to the slide's gap.
        // Here we only react to the launcher's content count changing while it's shown, so
        // the panel keeps fitting its rows.
        attentionModel.$sessions
            .combineLatest(attentionModel.$attentionPRs)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.panel.isVisible, self.shell.view == .attention,
                      !self.shell.newChatActive else { return }   // picker owns the frame while it's up
                self.resizePanel(for: .attention)
            }
            .store(in: &cancellables)

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

        model.reloadInBackground(animated: false) // warm caches so the first summon is instant
        tasksModel.reloadInBackground()
        prsModel.reloadInBackground()
        attentionModel.reloadInBackground()
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

    /// Size the panel for a view: compact (fit-to-content) for the attention launcher,
    /// generous for everything else. Instant — the slide masks the size change.
    private func resizePanel(for view: AppView) {
        if view == .attention {
            panel.setLauncherFrame(contentHeight: attentionContentHeight())
        } else {
            panel.setGenerousFrame()
        }
    }

    /// Estimated height of the launcher's content — header + footer + its visible rows and
    /// section headers. Approximate (matches the SwiftUI row metrics); the list scrolls if
    /// it's off, so it never clips.
    private func attentionContentHeight() -> CGFloat {
        let header: CGFloat = 46, footer: CGFloat = 40, dividers: CGFloat = 2, listVPad: CGFloat = 12
        let rowHeight: CGFloat = 33, sectionHeight: CGFloat = 24
        let rows = max(1, attentionModel.visibleRowCount)         // ≥1 for the empty-state line
        return header + footer + dividers + listVPad
            + CGFloat(attentionModel.visibleSectionCount) * sectionHeight
            + CGFloat(rows) * rowHeight
    }

    private func show() {
        shell.closeNewChat()              // a fresh summon never reopens the picker
        shell.snap(to: .attention)        // each summon snaps to the launcher (no slide)
        resizePanel(for: .attention)      // size before it's visible
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        attentionModel.startTicking()
        model.startTicking()
        tasksModel.startTicking()
        prsModel.startTicking()
        attentionModel.reloadInBackground()
        model.reloadInBackground(animated: false)
        model.resetNav()                  // each summon begins focused on the LIVE rail
        tasksModel.reloadInBackground()
        prsModel.reloadInBackground()
    }

    private func hide() {
        shell.closeNewChat()
        removeKeyMonitor()
        attentionModel.stopTicking()
        model.stopTicking()
        tasksModel.stopTicking()
        prsModel.stopTicking()
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

    /// ⌘N (any view): open the new-chat picker over the current view. Seeded from the warm
    /// session cache and pre-selected to the project you're looking at — so ⌘N then ↵ starts
    /// a chat in the current project, while typing retargets to any other tracked one.
    private func openNewChatPicker() {
        guard !shell.newChatActive else { return }
        newChatModel.open(model.projectChoices(), preselect: contextProject())
        shell.openNewChat()
        panel.setPickerFrame(contentHeight: newChatContentHeight())
    }

    /// Close the picker and restore the underlying view's frame.
    private func closeNewChatPicker() {
        guard shell.newChatActive else { return }
        shell.closeNewChat()
        resizePanel(for: shell.view)
    }

    private func newChatInProject(_ choice: ProjectChoice) {
        shell.closeNewChat()
        hide()
        TerminalDispatcher.newChat(cwd: choice.path)
    }

    /// The project to pre-select when the picker opens: whatever the current view is focused
    /// on. nil (→ most-recently-active) for views with no project context.
    private func contextProject() -> String? {
        switch shell.view {
        case .sessions:  return model.selectedProject
        case .attention: return (attentionModel.selectedItem as? ChatSession)?.project
        case .tasks, .prs: return nil
        }
    }

    /// Estimated picker height — query line + footer + its visible project rows, capped so a
    /// long list scrolls rather than growing the panel past the frame cap.
    private func newChatContentHeight() -> CGFloat {
        let header: CGFloat = 46, footer: CGFloat = 40, dividers: CGFloat = 2, listVPad: CGFloat = 12
        let rowHeight: CGFloat = 44
        let rows = max(1, min(newChatModel.choices.count, 9))
        return header + footer + dividers + listVPad + CGFloat(rows) * rowHeight
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

    /// ⌘X in the launcher: kill the selected session row. Beeps for a non-session row (a PR
    /// can't be killed) so the keystroke gives feedback either way.
    private func killSelectedAttention() {
        guard let session = attentionModel.selectedItem as? ChatSession, let pid = session.pid else {
            NSSound.beep(); return
        }
        TerminalDispatcher.closePane(pid: pid)
        attentionModel.kill(session)
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

    private func openPR(_ pr: PullRequest) {
        guard let url = URL(string: pr.url) else {
            NSLog("Helm: PR url is unopenable: \(pr.url)")
            return
        }
        hide()
        NSWorkspace.shared.open(url)
    }

    /// Open an attention-launcher row by its concrete type — resume a session, open a PR.
    private func openAttentionItem(_ item: any AttentionItem) {
        if let session = item as? ChatSession { pick(session) }
        else if let pr = item as? PullRequest { openPR(pr) }
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

        // The new-chat picker is a modal overlay: while it's up it owns every keystroke.
        if shell.newChatActive { return handleNewChat(event, cmd: cmd, option: option) }

        // ⌘N anywhere opens the picker; ⌘<digit> selects the view at that slot; ⌘O adds a
        // folder. All global to every view — a new AppView case is reachable with no edit.
        if cmd {
            if Int(event.keyCode) == kVK_ANSI_N { openNewChatPicker(); return true }
            if let digit = Self.digitKeyCodes[Int(event.keyCode)], let view = AppView.forDigit(digit) {
                shell.select(view); return true
            }
            if Int(event.keyCode) == kVK_ANSI_O { addWorkspaceFolders(); return true }
        }
        switch shell.view {
        case .attention: return handleAttention(event, cmd: cmd, option: option)
        case .sessions:  return handleSessions(event, cmd: cmd, option: option)
        case .tasks:     return handleTasks(event, cmd: cmd, option: option)
        case .prs:       return handlePRs(event, cmd: cmd, option: option)
        }
    }

    /// Picker keys: ↵ launches a chat in the selected project, esc backs out to the view you
    /// were on (not a full dismiss), arrows move, the rest is typeahead over project names.
    private func handleNewChat(_ event: NSEvent, cmd: Bool, option: Bool) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape:      closeNewChatPicker(); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let c = newChatModel.selectedChoice { newChatInProject(c) } else { NSSound.beep() }
            return true
        case kVK_DownArrow:   newChatModel.clearSelection(); newChatModel.move(by: 1);  return true
        case kVK_UpArrow:     newChatModel.clearSelection(); newChatModel.move(by: -1); return true
        case kVK_ANSI_A where cmd: newChatModel.selectAllQuery(); return true
        case kVK_ANSI_N where cmd: closeNewChatPicker();         return true   // ⌘N toggles it back off
        case kVK_Delete:
            if cmd        { newChatModel.clearQuery() }
            else if option { newChatModel.deleteWordBack() }
            else           { newChatModel.backspaceQuery() }
            return true
        default: break
        }
        return appendIfPrintable(event, cmd: cmd, to: { [weak self] in self?.newChatModel.appendQuery($0) })
    }

    private func handleAttention(_ event: NSEvent, cmd: Bool, option: Bool) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape:                                            hide(); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let item = attentionModel.selectedItem { openAttentionItem(item) }
            return true
        case kVK_DownArrow:   attentionModel.clearSelection(); attentionModel.move(by: 1);  return true
        case kVK_UpArrow:     attentionModel.clearSelection(); attentionModel.move(by: -1); return true
        case kVK_ANSI_A where cmd: attentionModel.selectAllQuery();  return true
        case kVK_ANSI_X where cmd: killSelectedAttention();         return true
        case kVK_Delete:
            if cmd        { attentionModel.clearQuery() }
            else if option { attentionModel.deleteWordBack() }
            else           { attentionModel.backspaceQuery() }
            return true
        default: break
        }
        return appendIfPrintable(event, cmd: cmd, to: { [weak self] in self?.attentionModel.appendQuery($0) })
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

    private func handlePRs(_ event: NSEvent, cmd: Bool, option: Bool) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape:                                          hide(); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let pr = prsModel.selectedPR { openPR(pr) };       return true
        case kVK_DownArrow:   prsModel.clearSelection(); prsModel.move(by: 1);  return true
        case kVK_UpArrow:     prsModel.clearSelection(); prsModel.move(by: -1); return true
        case kVK_ANSI_A where cmd: prsModel.selectAllQuery();     return true
        case kVK_Delete:
            if cmd        { prsModel.clearQuery() }
            else if option { prsModel.deleteWordBack() }
            else           { prsModel.backspaceQuery() }
            return true
        default: break
        }
        return appendIfPrintable(event, cmd: cmd, to: { [weak self] in self?.prsModel.appendQuery($0) })
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
