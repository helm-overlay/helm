import SwiftUI
import HelmCore

struct DisplayGroup: Identifiable {
    let project: String
    let sessions: [ChatSession]
    let hiddenCount: Int        // capped rows behind the "+N older" tail; >0 → render it
    var id: String { project }
}

/// One row in the project master column: a project with its live/cold tallies.
struct ProjectSummary: Identifiable {
    let project: String
    let liveCount: Int
    let coldCount: Int
    var id: String { project }
}

/// Which list the keyboard is driving. Up/down navigate within the focused zone; the
/// arrow keys cross between zones (down/up to/from LIVE; left/right between the two panes).
enum NavZone: Equatable { case live, projects, cold }

@MainActor
final class SessionListViewModel: ObservableObject {
    @Published private(set) var groups: [DisplayGroup] = []
    @Published private(set) var query: String = ""
    @Published private(set) var querySelected: Bool = false   // ⌘A: whole query highlighted
    @Published private(set) var lastEdit: Date = Date()        // anchors the cursor blink phase
    @Published private(set) var now: Date = Date()   // clock for age labels; ticks while visible
    @Published var zone: NavZone = .live                  // which list the keyboard drives
    @Published var liveSelection: String?                 // highlighted row in the LIVE rail
    @Published var selectedProject: String?               // master-column selection driving the detail pane
    @Published var coldSelection: String?                 // highlighted row in the cold detail / search results
    @Published private(set) var suppressAnimations = false // true while applying a baseline panel load

    private var all: [(project: String, sessions: [ChatSession])] = []
    private var ticker: Timer?
    private var liveTicker: Timer?
    private var hideOlderThan: TimeInterval = HelmConfig.load().hideOlderThan

    /// Guards `reloadInBackground` so a slow full scan (reads all transcript history) can't
    /// stack behind rapid re-summons — a later scan landing before an earlier one would
    /// apply stale data.
    private var isReloading = false

    /// Sessions we've killed but whose process may still be exiting. While a full row ID is
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

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Cross-project live sessions — the pinned LIVE rail. Attention-first (needs-input,
    /// then needs-review), then newest. Hidden while searching.
    var liveRail: [ChatSession] {
        guard !isSearching else { return [] }
        return all.flatMap(\.sessions).filter(\.isLive).sorted { a, b in
            if a.needsInput != b.needsInput { return a.needsInput }
            if a.needsReview != b.needsReview { return a.needsReview }
            return a.lastActive > b.lastActive
        }
    }

    /// Projects for the master column with live/cold tallies. Legacy "Other" is search-only.
    var projectSummaries: [ProjectSummary] {
        all.compactMap { g in
            guard g.project != "Other" else { return nil }
            return ProjectSummary(project: g.project,
                                  liveCount: g.sessions.filter(\.isLive).count,
                                  coldCount: g.sessions.filter { !$0.isLive }.count)
        }
    }

    /// Launchable projects for the new-chat picker: every tracked workspace folder, ranked
    /// recent-first, with its launch path. Built from the already-loaded session cache plus
    /// the configured folders — no extra filesystem scan, so the picker opens instantly.
    func projectChoices() -> [ProjectChoice] {
        SessionStore.projectChoices(workspaceFolders: HelmConfig.load().resolvedWorkspaceFolders(),
                                    sessions: all.flatMap(\.sessions))
    }

    /// Detail-pane rows. Searching → global fuzzy matches across every project (live +
    /// cold). Otherwise → the selected project's cold history (live lives in the rail).
    var detailRows: [ChatSession] {
        if isSearching {
            let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            return all.flatMap(\.sessions)
                .filter { SessionStore.matches($0, query: q) }
                .sorted { $0.lastActive > $1.lastActive }
        }
        guard let p = selectedProject,
              let g = all.first(where: { $0.project == p }) else { return [] }
        return g.sessions.filter { !$0.isLive }.sorted { $0.lastActive > $1.lastActive }
    }

    var liveCount: Int { all.flatMap(\.sessions).filter(\.isLive).count }
    var totalCount: Int { all.flatMap(\.sessions).count }

    /// The session ↵ / ⌘X act on, resolved from the focused zone. In the projects zone
    /// that's the selected project's first cold (else first live) row, so ⌘N lands in the
    /// right working directory.
    var selectedSession: ChatSession? {
        if isSearching { return detailRows.first { $0.id == coldSelection } }
        switch zone {
        case .live:     return liveRail.first { $0.id == liveSelection }
        case .cold:     return detailRows.first { $0.id == coldSelection }
        case .projects: return detailRows.first ?? liveRail.first { $0.project == selectedProject }
        }
    }

    /// Synchronous reload (probe/tests).
    func reload() {
        hideOlderThan = HelmConfig.load().hideOlderThan
        all = SessionStore().grouped()
        applyFilter()
    }

    /// Scan the filesystem off the main thread, then apply on main. Cached data stays
    /// visible until the fresh scan lands, so the panel never blocks on I/O.
    func reloadInBackground(animated: Bool = true) {
        guard !isReloading else { return }
        isReloading = true
        Task.detached(priority: .userInitiated) {
            let grouped = SessionStore().grouped()
            await self.ingest(grouped, animated: animated)
        }
    }

    private func ingest(_ grouped: [(project: String, sessions: [ChatSession])], animated: Bool = true) {
        isReloading = false
        hideOlderThan = HelmConfig.load().hideOlderThan   // pick up config edits on resummon
        all = SessionStore.group(suppressKilled(grouped.flatMap(\.sessions)),
                                 includeEmpty: SessionStore().listProjects())
        applyFilter(animated: animated)   // sessions appearing/leaving slide rather than snap
    }

    var canRemoveSelectedWorkspaceFolder: Bool {
        selectedWorkspaceFolderPath() != nil
    }

    @discardableResult
    func removeSelectedWorkspaceFolder() -> Bool {
        guard query.isEmpty, let path = selectedWorkspaceFolderPath() else { return false }
        do {
            _ = try HelmConfig.removeWorkspaceFolder(path)
            if selectedProject == URL(fileURLWithPath: path).lastPathComponent {
                selectedProject = nil   // reconciles to another project on the next load
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
    func kill(_ session: ChatSession, pid: Int32) {
        killing.insert(session.id)
        SessionStore.clearState(agent: session.agent, sessionId: session.sessionId)   // SessionEnd hook won't run on a killed proc
        markDead(session.id)
        Task.detached(priority: .userInitiated) {
            SessionStore.terminateAndWait(pid)
            await self.finishKill(session.id)
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
            (group.project, group.sessions.map { $0.id == sessionId ? $0.markedDead() : $0 })
        }
        applyFilter(animated: true)   // the killed row slides down to its cold slot as it dies
    }

    /// Force any in-flight-kill row to cold regardless of what the registry says, so a
    /// still-exiting process can't reconcile back to a live row mid-teardown.
    private func suppressKilled(_ rows: [ChatSession]) -> [ChatSession] {
        guard !killing.isEmpty else { return rows }
        return rows.map { killing.contains($0.id) ? $0.markedDead() : $0 }
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

    // MARK: Navigation
    //
    // Three zones stacked LIVE (top) over PROJECTS | COLD (side by side). Up/down move
    // within the focused zone and only cross at its edge: down off the last LIVE row drops
    // into PROJECTS; up off the top of either pane returns to LIVE. Left/right cross between
    // the two panes (PROJECTS ⇄ COLD). While searching it's one flat results list.

    func navDown() {
        if isSearching { step(&coldSelection, in: detailRows, by: 1); return }
        switch zone {
        case .live:     if !step(&liveSelection, in: liveRail, by: 1) { enterProjects() }
        case .projects: stepProject(by: 1)
        case .cold:     step(&coldSelection, in: detailRows, by: 1)
        }
    }

    func navUp() {
        if isSearching { step(&coldSelection, in: detailRows, by: -1); return }
        switch zone {
        case .live:     step(&liveSelection, in: liveRail, by: -1)
        case .projects: if !stepProject(by: -1) { enterLive() }
        case .cold:     if !step(&coldSelection, in: detailRows, by: -1) { enterLive() }
        }
    }

    func navLeft()  { if zone == .cold { zone = .projects } }
    func navRight() { if zone == .projects { enterCold() } }

    /// Mouse path: clicking a project focuses the PROJECTS zone and shows its history.
    func selectProject(_ project: String) {
        selectedProject = project
        coldSelection = detailRows.first?.id
        zone = .projects
    }

    /// Step the highlight within `rows`; returns false (without moving) when already at the
    /// edge in the travel direction, so callers can cross into the neighbouring zone.
    @discardableResult
    private func step(_ sel: inout String?, in rows: [ChatSession], by delta: Int) -> Bool {
        guard !rows.isEmpty else { return false }
        let cur = rows.firstIndex { $0.id == sel } ?? (delta > 0 ? -1 : rows.count)
        let next = cur + delta
        guard next >= 0, next < rows.count else { return false }
        sel = rows[next].id
        return true
    }

    @discardableResult
    private func stepProject(by delta: Int) -> Bool {
        let ps = projectSummaries
        guard !ps.isEmpty else { return false }
        let cur = ps.firstIndex { $0.project == selectedProject } ?? 0
        let next = cur + delta
        guard next >= 0, next < ps.count else { return false }
        selectedProject = ps[next].project
        coldSelection = detailRows.first?.id   // reset the cold highlight for the new project
        return true
    }

    private func enterProjects() {
        zone = .projects
        ensureProjectSelection()
    }

    private func enterCold() {
        guard !detailRows.isEmpty else { return }   // nothing to drill into; stay put
        zone = .cold
        if coldSelection == nil || !detailRows.contains(where: { $0.id == coldSelection }) {
            coldSelection = detailRows.first?.id
        }
    }

    private func enterLive() {
        guard !liveRail.isEmpty else { return }      // no rail to return to; stay put
        zone = .live
        if liveSelection == nil || !liveRail.contains(where: { $0.id == liveSelection }) {
            liveSelection = liveRail.last?.id        // land on the row nearest the panes
        }
    }

    /// Each summon starts focused on the LIVE rail (falling back to PROJECTS if nothing is
    /// running), so the keyboard always begins from a predictable place.
    func resetNav() {
        zone = liveRail.isEmpty ? .projects : .live
        reconcileSelection()
    }

    // MARK: Filtering

    /// `animated` is set only on the refresh/kill paths (rows appearing, leaving, or
    /// re-sorting), so those glide; typing the filter stays instant.
    private func applyFilter(animated: Bool = false) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let searching = !q.isEmpty
        let clock = now

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
            suppressAnimations = true
            groups = newGroups
            reconcileSelection()
            DispatchQueue.main.async { [weak self] in self?.suppressAnimations = false }
            return
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            groups = newGroups
            reconcileSelection()
        }
    }

    /// Keep every zone's selection valid as rows appear/leave: the master project first
    /// (the detail depends on it), then the live and cold highlights, then the focused zone
    /// itself (don't sit in an empty rail/detail).
    private func reconcileSelection() {
        ensureProjectSelection()
        if liveSelection == nil || !liveRail.contains(where: { $0.id == liveSelection }) {
            liveSelection = liveRail.first?.id
        }
        if coldSelection == nil || !detailRows.contains(where: { $0.id == coldSelection }) {
            coldSelection = detailRows.first?.id
        }
        if zone == .live && liveRail.isEmpty { zone = .projects }
        if zone == .cold && detailRows.isEmpty { zone = .projects }
    }

    /// Keep a valid master selection: preserve if still present, else the project of the
    /// most-attention-worthy live session, else the first project.
    private func ensureProjectSelection() {
        let ps = projectSummaries
        if selectedProject == nil || !ps.contains(where: { $0.project == selectedProject }) {
            selectedProject = liveRail.first?.project ?? ps.first?.project
        }
    }

    private func selectedWorkspaceFolderPath() -> String? {
        guard let project = selectedProject else { return nil }
        return workspaceFolderPath(for: project)
    }

    private func workspaceFolderPath(for project: String) -> String? {
        HelmConfig.load().resolvedWorkspaceFolders().first {
            URL(fileURLWithPath: $0).lastPathComponent == project
        }
    }
}
