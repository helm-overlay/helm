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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = RootView(
            shell: shell,
            attention: attentionModel,
            newChat: newChatModel,
            onLaunchNewChat:     { [weak self] in self?.newChatInProject($0) },
            onOpenAttention:     { [weak self] in self?.openAttentionItem($0) })
        panel = OverlayPanel(content: NSHostingView(rootView: root))
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }

        // Refit the panel whenever the launcher's content count changes while it's shown, so
        // it keeps hugging its rows.
        attentionModel.$sections
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.panel.isVisible,
                      !self.shell.newChatActive else { return }   // picker owns the frame while it's up
                self.resizePanel()
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

        attentionModel.reloadInBackground() // warm caches so the first summon is instant
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

    /// Size the panel to fit the launcher's content.
    private func resizePanel() {
        panel.setLauncherFrame(contentHeight: attentionContentHeight())
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
        resizePanel()                     // size before it's visible
        panel.summon()
        installKeyMonitor()
        attentionModel.startTicking()
        attentionModel.reloadInBackground()
    }

    private func hide() {
        shell.closeNewChat()
        removeKeyMonitor()
        attentionModel.stopTicking()
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
        let choices = SessionStore.projectChoices(
            workspaceFolders: HelmConfig.load().resolvedWorkspaceFolders(),
            sessions: attentionModel.cachedSessions)
        newChatModel.open(choices, preselect: contextProject())
        shell.openNewChat()
        panel.setPickerFrame(contentHeight: newChatContentHeight())
    }

    /// Close the picker and restore the launcher's frame.
    private func closeNewChatPicker() {
        guard shell.newChatActive else { return }
        shell.closeNewChat()
        resizePanel()
    }

    private func newChatInProject(_ choice: ProjectChoice) {
        shell.closeNewChat()
        hide()
        TerminalDispatcher.newChat(cwd: choice.path)
    }

    /// The project to pre-select when the picker opens: whatever the current view is focused
    /// on. nil (→ most-recently-active) for views with no project context.
    private func contextProject() -> String? {
        (attentionModel.selectedItem as? ChatSession)?.project
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

    /// ⌘X in the launcher: terminate the selected row. A session is killed; a building Jenkins
    /// build is stopped. Beeps for anything else (a PR, a finished build) so the keystroke
    /// always gives feedback.
    private func killSelectedAttention() {
        switch attentionModel.selectedItem {
        case let session as ChatSession where session.pid != nil:
            TerminalDispatcher.closePane(pid: session.pid!)
            attentionModel.kill(session)
        case let job as JenkinsJob where job.building:
            attentionModel.stopBuild(job)
        default:
            NSSound.beep()
        }
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
                attentionModel.reloadInBackground()
            } catch {
                NSLog("Helm: failed to save workspace folders: \(error)")
                NSSound.beep()
            }
        }

        if shouldRestorePanel { show() }
    }

    /// Open an attention-launcher row via its own primary action — the row owns what Enter
    /// does, so this never branches on the concrete row type (a new `.openURL` source needs no
    /// change here). The session resume still casts, since terminal-pane focus needs the row.
    private func openAttentionItem(_ item: any AttentionItem) {
        switch item.primaryAction {
        case .resumeSession:
            if let session = item as? ChatSession { pick(session) }
        case .openURL(let url):
            openURL(url)
        case .newChat(_, let cwd):
            hide(); TerminalDispatcher.newChat(cwd: cwd)
        }
    }

    private func openURL(_ raw: String) {
        guard let url = URL(string: raw) else {
            NSLog("Helm: attention row url is unopenable: \(raw)")
            return
        }
        hide()
        NSWorkspace.shared.open(url)
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

        // ⌘N opens the picker; ⌘O adds a workspace folder.
        if cmd {
            if Int(event.keyCode) == kVK_ANSI_N { openNewChatPicker(); return true }
            if Int(event.keyCode) == kVK_ANSI_O { addWorkspaceFolders(); return true }
        }
        return handleAttention(event, cmd: cmd, option: option)
    }

    /// Picker keys: ↵ launches a chat in the selected project, esc backs out to the view you
    /// were on (not a full dismiss), ↑↓ move the project list, ⌘N toggles it back off. Editing
    /// the query line (typing, caret movement, paste, delete) is shared with the attention view.
    private func handleNewChat(_ event: NSEvent, cmd: Bool, option: Bool) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape:      closeNewChatPicker(); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let c = newChatModel.selectedChoice { newChatInProject(c) } else { NSSound.beep() }
            return true
        case kVK_ANSI_N where cmd: closeNewChatPicker(); return true   // ⌘N toggles it back off
        case kVK_Delete where cmd: newChatModel.clearQuery(); return true
        default: break
        }
        return handleQueryEditing(event, cmd: cmd, option: option, model: newChatModel)
    }

    private func handleAttention(_ event: NSEvent, cmd: Bool, option: Bool) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape:                                            hide(); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let item = attentionModel.selectedItem { openAttentionItem(item) }
            return true
        case kVK_ANSI_X where cmd: killSelectedAttention(); return true
        case kVK_Delete where cmd:
            // ⌘⌫ depends on what's active: clear the query while you're searching, otherwise
            // terminate the highlighted row (session kill / building-job stop).
            if attentionModel.query.isEmpty { killSelectedAttention() } else { attentionModel.clearQuery() }
            return true
        default: break
        }
        return handleQueryEditing(event, cmd: cmd, option: option, model: attentionModel)
    }

    /// Editing keys shared by both launcher query lines, so the two stay identical by
    /// construction: ↑↓ move the row selection; ←→ (and ⌥/⌘ variants) move the caret; ⌫/⌥⌫
    /// delete; ⌘A selects all; ⌘V pastes; any other printable input is inserted at the caret.
    private func handleQueryEditing(_ event: NSEvent, cmd: Bool, option: Bool, model: any QueryEditable) -> Bool {
        switch Int(event.keyCode) {
        case kVK_DownArrow:   model.clearSelection(); model.move(by: 1);  return true
        case kVK_UpArrow:     model.clearSelection(); model.move(by: -1); return true
        case kVK_LeftArrow:
            if cmd { model.moveCursorToStart() } else if option { model.moveWord(by: -1) } else { model.moveCursor(by: -1) }
            return true
        case kVK_RightArrow:
            if cmd { model.moveCursorToEnd() } else if option { model.moveWord(by: 1) } else { model.moveCursor(by: 1) }
            return true
        case kVK_ANSI_A where cmd: model.selectAllQuery(); return true
        case kVK_ANSI_V where cmd: return pasteIntoQuery(model)
        case kVK_Delete:
            if option { model.deleteWordBack() } else { model.backspaceQuery() }
            return true
        default: break
        }
        return appendIfPrintable(event, cmd: cmd, to: { model.appendQuery($0) })
    }

    /// ⌘V: insert the pasteboard's plain text at the caret. A search line is single-line, so
    /// newlines collapse to spaces.
    private func pasteIntoQuery(_ model: any QueryEditable) -> Bool {
        guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else { return true }
        let flattened = s.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        model.appendQuery(flattened)
        return true
    }

    /// Insert typed input at the caret (no ⌘). Accepts any actual text — letters, digits, and
    /// punctuation alike — while rejecting the function-key and control scalars that arrows,
    /// escape, and friends report so they fall through to their own handling.
    private func appendIfPrintable(_ event: NSEvent, cmd: Bool, to append: @escaping (String) -> Void) -> Bool {
        guard !cmd, let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy(isInsertableScalar) else {
            return false
        }
        append(chars)
        return true
    }

    /// True for a scalar that should land in the query: not a control character, and not in the
    /// private-use range AppKit uses for arrows/F-keys/Home/End and other non-text keys.
    private func isInsertableScalar(_ scalar: Unicode.Scalar) -> Bool {
        !CharacterSet.controlCharacters.contains(scalar) && !(scalar.value >= 0xF700 && scalar.value <= 0xF8FF)
    }
}

/// The editing surface both launcher view models expose to the shared key handler.
@MainActor
protocol QueryEditable: AnyObject {
    var query: String { get }
    func appendQuery(_ s: String)
    func backspaceQuery()
    func deleteWordBack()
    func clearQuery()
    func moveCursor(by delta: Int)
    func moveWord(by delta: Int)
    func moveCursorToStart()
    func moveCursorToEnd()
    func selectAllQuery()
    func clearSelection()
    func move(by delta: Int)
}

extension AttentionListViewModel: QueryEditable, QueryLineModel {}
extension NewChatViewModel: QueryEditable, QueryLineModel {}
