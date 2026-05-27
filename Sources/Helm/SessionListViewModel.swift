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

    private let store = SessionStore()
    private var all: [(project: String, sessions: [ChatSession])] = []
    private var ticker: Timer?
    private var hideOlderThan: TimeInterval = HelmConfig.load().hideOlderThan

    /// Hard cap on rows shown per project in the default view; the rest collapse into a
    /// "+N older" tail (still reachable by search or by expanding the project).
    private let perProjectCap = 5

    /// Advance the age clock every 30s while the panel is open (no per-second churn).
    func startTicking() {
        now = Date()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
    }

    func stopTicking() {
        ticker?.invalidate()
        ticker = nil
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
        all = store.grouped()
        applyFilter()
    }

    /// Scan the filesystem off the main thread, then apply on main. Cached data stays
    /// visible until the fresh scan lands, so the panel never blocks on I/O.
    func reloadInBackground() {
        Task.detached(priority: .userInitiated) {
            let grouped = SessionStore().grouped()
            await self.ingest(grouped)
        }
    }

    private func ingest(_ grouped: [(project: String, sessions: [ChatSession])]) {
        hideOlderThan = HelmConfig.load().hideOlderThan   // pick up config edits on resummon
        all = grouped
        applyFilter()
    }

    /// Optimistic update for a self-initiated kill: flip the row to dead immediately
    /// rather than waiting for the next poll to notice the process exited. The follow-up
    /// reload reconciles (and agrees — the pid really is gone).
    func markDead(_ sessionId: String) {
        all = all.map { group in
            (group.project, group.sessions.map { $0.sessionId == sessionId ? $0.markedDead() : $0 })
        }
        applyFilter()
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

    private func applyFilter() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let searching = !q.isEmpty
        let clock = now

        // Focus mode: one project, fully revealed (no cap, no recency cutoff). Typing exits
        // focus into the cross-project search below.
        if !searching, let focus = focusedProject {
            if let group = all.first(where: { $0.project == focus }), !group.sessions.isEmpty {
                groups = [DisplayGroup(project: group.project, sessions: group.sessions, hiddenCount: 0)]
                reconcileSelection()
                return
            }
            focusedProject = nil   // focused project vanished — fall through to the full list
        }

        let filtered: [DisplayGroup] = all.compactMap { group in
            // While searching, span everything — every project (incl. legacy "Other"),
            // no recency cutoff, no collapse — and rank by fuzzy match across all fields.
            if searching {
                let rows = group.sessions.filter { SessionStore.matches($0, query: q) }
                return rows.isEmpty ? nil : DisplayGroup(project: group.project, sessions: rows, hiddenCount: 0)
            }

            // Default view is a switcher, not an archive:
            // 1. Legacy "Other" is search-only — it never takes space in the default list.
            if group.project == "Other" { return nil }
            // 2. Recency cutoff, but a live row is never hidden.
            let recent = group.sessions.filter { s in
                s.isLive || !SessionStore.isOlderThan(hideOlderThan, lastActive: s.lastActive, now: clock)
            }
            guard !recent.isEmpty else { return nil }
            // 3. Hard cap per project — show at most `perProjectCap` rows (live-first,
            //    newest-first, as store.grouped() already sorts). The rest collapse behind
            //    a "+N older" tail; ⌘↓ (or tapping the tail) focuses to reveal them all.
            guard recent.count > perProjectCap else {
                return DisplayGroup(project: group.project, sessions: recent, hiddenCount: 0)
            }
            let shown = Array(recent.prefix(perProjectCap))
            return DisplayGroup(project: group.project, sessions: shown, hiddenCount: recent.count - shown.count)
        }
        groups = filtered
        reconcileSelection()
    }

    /// Keep a valid selection: preserve if still visible, else first row.
    private func reconcileSelection() {
        let flat = groups.flatMap(\.sessions)
        if selection == nil || !flat.contains(where: { $0.sessionId == selection }) {
            selection = flat.first?.sessionId
        }
    }
}
