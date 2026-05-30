import SwiftUI
import HelmCore

struct DisplayGroup: Identifiable {
    let project: String
    let sessions: [ChatSession]
    let hiddenCount: Int        // capped rows behind the "+N older" tail; >0 → render it
    var id: String { project }
}

@MainActor
final class SessionListViewModel: ObservableObject {
    @Published private(set) var groups: [DisplayGroup] = []
    @Published private(set) var query: String = ""
    @Published private(set) var querySelected: Bool = false   // ⌘A: whole query highlighted
    @Published private(set) var lastEdit: Date = Date()        // anchors the cursor blink phase
    @Published var selection: String?          // sessionId
    @Published private(set) var now: Date = Date()   // clock for age labels; ticks while visible
    @Published private(set) var focusedProject: String?   // drilled into one project; others hidden

    private var all: [(project: String, sessions: [ChatSession])] = []
    private var ticker: Timer?
    private var liveTicker: Timer?
    private var hideOlderThan: TimeInterval = HelmConfig.load().hideOlderThan

    /// Guards `reloadInBackground` so a slow full scan (reads all transcript history) can't
    /// stack behind rapid re-summons — a later scan landing before an earlier one would
    /// apply stale data.
    private var isReloading = false

    /// Sessions we've killed but whose process may still be exiting. While a sessionId is
    /// here, every reconcile forces its row to cold — otherwise the per-second live ticker
    /// reads the still-alive process back out of the registry and snaps the row to idle.
    private var killing: Set<String> = []

    /// Hard cap on rows shown per project in the default view; the rest collapse into a
    /// "+N older" tail (still reachable by search or by expanding the project).
    private let perProjectCap = 3

    /// While the panel is open: advance the age clock every 30s (the "5m ago" labels — no
    /// per-second churn), and re-check live state every 1s so a session flipping
    /// busy↔idle↔dead is reflected without waiting for the next summon.
    func startTicking() {
        now = Date()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        liveTicker?.invalidate()
        liveTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLiveState() }
        }
    }

    func stopTicking() {
        ticker?.invalidate()
        ticker = nil
        liveTicker?.invalidate()
        liveTicker = nil
    }

    /// Per-second live refresh: re-read only the live registry (+ idle verdicts) and
    /// reconcile cached rows. Cold rows can't change, so history is never re-scanned. A
    /// brand-new live session (no cached row) triggers one full reload to fetch its label.
    func refreshLiveState() {
        let snapshot = all.flatMap(\.sessions)
        guard !snapshot.isEmpty else { return }
        Task.detached(priority: .utility) {
            let (rows, newSessions) = SessionStore().refreshLiveState(snapshot)
            if newSessions {
                await self.ingest(SessionStore().grouped())
            } else if rows != snapshot {   // nothing moved → skip the redraw/animation
                await self.applyLiveRefresh(rows)
            }
        }
    }

    private func applyLiveRefresh(_ rows: [ChatSession]) {
        all = SessionStore.group(suppressKilled(rows), includeEmpty: SessionStore().listProjects())
        applyFilter(animated: true)   // a row going live/dead slides to its new slot
    }

    var liveCount: Int { all.flatMap(\.sessions).filter(\.isLive).count }
    var totalCount: Int { all.flatMap(\.sessions).count }

    /// Flattened, in display order — the navigation order for arrow keys.
    private var visibleFlat: [ChatSession] { groups.flatMap(\.sessions) }

    var selectedSession: ChatSession? {
        visibleFlat.first { $0.sessionId == selection }
    }

    /// Synchronous reload (probe/tests).
    func reload() {
        hideOlderThan = HelmConfig.load().hideOlderThan
        all = SessionStore().grouped()
        applyFilter()
    }

    /// Scan the filesystem off the main thread, then apply on main. Cached data stays
    /// visible until the fresh scan lands, so the panel never blocks on I/O.
    func reloadInBackground() {
        guard !isReloading else { return }
        isReloading = true
        Task.detached(priority: .userInitiated) {
            let grouped = SessionStore().grouped()
            await self.ingest(grouped)
        }
    }

    private func ingest(_ grouped: [(project: String, sessions: [ChatSession])]) {
        isReloading = false
        hideOlderThan = HelmConfig.load().hideOlderThan   // pick up config edits on resummon
        all = SessionStore.group(suppressKilled(grouped.flatMap(\.sessions)),
                                 includeEmpty: SessionStore().listProjects())
        applyFilter(animated: true)   // sessions appearing/leaving slide rather than snap
    }

    var canRemoveSelectedWorkspaceFolder: Bool {
        selectedWorkspaceFolderPath() != nil
    }

    @discardableResult
    func removeSelectedWorkspaceFolder() -> Bool {
        guard query.isEmpty, let path = selectedWorkspaceFolderPath() else { return false }
        do {
            _ = try HelmConfig.removeWorkspaceFolder(path)
            if focusedProject == URL(fileURLWithPath: path).lastPathComponent {
                focusedProject = nil
            }
            reloadInBackground()
            return true
        } catch {
            NSLog("Helm: failed to remove workspace folder: \(error)")
            return false
        }
    }

    /// Kill a live session. Flip its row to dead now (optimistic), mark it as killing so no
    /// reconcile resurrects it, then SIGTERM→SIGKILL off the main thread; once the process
    /// is confirmed gone, drop the guard and reload — the registry now agrees it's dead.
    func kill(sessionId: String, pid: Int32) {
        killing.insert(sessionId)
        SessionStore.clearState(sessionId)   // SessionEnd hook won't run on a killed proc
        markDead(sessionId)
        Task.detached(priority: .userInitiated) {
            SessionStore.terminateAndWait(pid)
            await self.finishKill(sessionId)
        }
    }

    private func finishKill(_ sessionId: String) {
        killing.remove(sessionId)
        reloadInBackground()
    }

    /// Flip a row to dead immediately and slide it to its cold slot. Used by `kill` and
    /// kept separate so the optimistic update and the process teardown stay decoupled.
    private func markDead(_ sessionId: String) {
        all = all.map { group in
            (group.project, group.sessions.map { $0.sessionId == sessionId ? $0.markedDead() : $0 })
        }
        applyFilter(animated: true)   // the killed row slides down to its cold slot as it dies
    }

    /// Force any in-flight-kill row to cold regardless of what the registry says, so a
    /// still-exiting process can't reconcile back to a live row mid-teardown.
    private func suppressKilled(_ rows: [ChatSession]) -> [ChatSession] {
        guard !killing.isEmpty else { return rows }
        return rows.map { killing.contains($0.sessionId) ? $0.markedDead() : $0 }
    }

    // MARK: Query (typeahead)

    func appendQuery(_ s: String) {
        if querySelected { query = ""; querySelected = false }   // typing replaces the selection
        query += s
        lastEdit = Date()
        applyFilter()
    }

    func backspaceQuery() {
        if querySelected { clearQuery(); return }
        guard !query.isEmpty else { return }
        query.removeLast()
        lastEdit = Date()
        applyFilter()
    }

    /// ⌥⌫ — drop the trailing word (and any whitespace before it).
    func deleteWordBack() {
        if querySelected { clearQuery(); return }
        guard !query.isEmpty else { return }
        var s = query[...]
        while let c = s.last, c == " " { s = s.dropLast() }
        while let c = s.last, c != " " { s = s.dropLast() }
        query = String(s)
        lastEdit = Date()
        applyFilter()
    }

    /// ⌘⌫ — clear the whole query (cursor is always at end, so this is delete-to-start).
    func clearQuery() {
        querySelected = false
        lastEdit = Date()
        guard !query.isEmpty else { return }
        query = ""
        applyFilter()
    }

    /// ⌘A — select the whole query; the next keystroke replaces or clears it.
    func selectAllQuery() { querySelected = !query.isEmpty }

    func clearSelection() { querySelected = false }

    /// ⌘↓ — drill into the project the cursor is in: show only it, fully revealed.
    func focusSelectedProject() {
        guard focusedProject == nil,
              let project = groups.first(where: { g in g.sessions.contains { $0.sessionId == selection } })?.project
        else { return }
        focusedProject = project
        applyFilter()
    }

    /// Mouse path: the "+N older" tail toggles focus on its project.
    func toggleFocus(_ project: String) {
        focusedProject = (focusedProject == project) ? nil : project
        applyFilter()
    }

    /// Esc / ⌘↑ — back out of focus to the full list.
    func exitFocus() {
        guard focusedProject != nil else { return }
        focusedProject = nil
        applyFilter()
    }

    // MARK: Selection

    func move(by delta: Int) {
        let flat = visibleFlat
        guard !flat.isEmpty else { selection = nil; return }
        let cur = flat.firstIndex { $0.sessionId == selection } ?? -1
        let next = max(0, min(flat.count - 1, cur + delta))
        selection = flat[next].sessionId
    }

    // MARK: Filtering

    /// `animated` is set only on the refresh/kill paths (rows appearing, leaving, or
    /// re-sorting), so those glide; typing the filter stays instant.
    private func applyFilter(animated: Bool = false) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let searching = !q.isEmpty
        let clock = now

        // Focus mode: one project, fully revealed (no cap, no recency cutoff). Typing exits
        // focus into the cross-project search below.
        if !searching, let focus = focusedProject {
            if let group = all.first(where: { $0.project == focus }), !group.sessions.isEmpty {
                commit([DisplayGroup(project: group.project, sessions: group.sessions, hiddenCount: 0)], animated: animated)
                return
            }
            focusedProject = nil   // focused project vanished — fall through to the full list
        }

        let filtered: [DisplayGroup] = all.compactMap { group in
            // While searching, span everything — every project (incl. legacy "Other"),
            // no recency cutoff, no collapse — and rank by fuzzy match across all fields.
            if searching {
                if group.sessions.isEmpty { return nil }   // empty group can't match
                let rows = group.sessions.filter { SessionStore.matches($0, query: q) }
                return rows.isEmpty ? nil : DisplayGroup(project: group.project, sessions: rows, hiddenCount: 0)
            }

            // Default view is a switcher, not an archive:
            // 1. Legacy "Other" is search-only — it never takes space in the default list.
            if group.project == "Other" { return nil }
            // 2. Singular Chats (one-offs in ~/Home) shows live rows only — cold rows here are
            //    throwaway and only surface via search.
            let isSingularChats = group.project == SessionStore.singularChatsGroup
            let recent = group.sessions.filter { s in
                if isSingularChats { return s.isLive }
                return s.isLive || !SessionStore.isOlderThan(hideOlderThan, lastActive: s.lastActive, now: clock)
            }
            if recent.isEmpty {
                let cwd = isSingularChats
                    ? "\(NSHomeDirectory())/Home"
                    : workspaceFolderPath(for: group.project) ?? ""
                return DisplayGroup(project: group.project,
                                    sessions: [.placeholder(forProject: group.project, cwd: cwd)],
                                    hiddenCount: 0)
            }
            // 3. Hard cap per project — show at most `perProjectCap` rows (live-first,
            //    newest-first, as store.grouped() already sorts). The rest collapse behind
            //    a "+N older" tail; ⌘↓ (or tapping the tail) focuses to reveal them all.
            guard recent.count > perProjectCap else {
                return DisplayGroup(project: group.project, sessions: recent, hiddenCount: 0)
            }
            let shown = Array(recent.prefix(perProjectCap))
            return DisplayGroup(project: group.project, sessions: shown, hiddenCount: recent.count - shown.count)
        }
        commit(filtered, animated: animated)
    }

    /// Single place the published `groups` changes, optionally inside a spring so SwiftUI
    /// drives the row insertion/removal transitions and the re-sort slide.
    private func commit(_ newGroups: [DisplayGroup], animated: Bool) {
        guard animated else {
            groups = newGroups
            reconcileSelection()
            return
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            groups = newGroups
            reconcileSelection()
        }
    }

    /// Keep a valid selection: preserve if still visible, else first row.
    private func reconcileSelection() {
        let flat = groups.flatMap(\.sessions)
        if selection == nil || !flat.contains(where: { $0.sessionId == selection }) {
            selection = flat.first?.sessionId
        }
    }

    private func selectedWorkspaceFolderPath() -> String? {
        let project = focusedProject
            ?? groups.first(where: { group in group.sessions.contains { $0.sessionId == selection } })?.project
        guard let project else { return nil }
        return workspaceFolderPath(for: project)
    }

    private func workspaceFolderPath(for project: String) -> String? {
        HelmConfig.load().workspaceFolders.first {
            URL(fileURLWithPath: $0).lastPathComponent == project
        }
    }
}
