import SwiftUI
import HelmCore

struct DisplayGroup: Identifiable {
    let project: String
    let sessions: [ChatSession]
    let hiddenCount: Int        // collapsed cold rows; >0 → render the "+N older" tail
    let expanded: Bool          // tail is open → render the "show less" tail
    var id: String { project }
}

@MainActor
final class SessionListViewModel: ObservableObject {
    @Published private(set) var groups: [DisplayGroup] = []
    @Published private(set) var query: String = ""
    @Published var selection: String?          // sessionId
    @Published private(set) var now: Date = Date()   // clock for age labels; ticks while visible

    private let store = SessionStore()
    private var all: [(project: String, sessions: [ChatSession])] = []
    private var ticker: Timer?
    private var hideOlderThan: TimeInterval = HelmConfig.load().hideOlderThan
    private var expanded: Set<String> = []          // projects whose collapsed tail is open

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

    // MARK: Query (typeahead)

    func appendQuery(_ s: String) { query += s; applyFilter() }
    func backspaceQuery() { if !query.isEmpty { query.removeLast(); applyFilter() } }

    /// Open/close a project's collapsed "+N older" tail.
    func toggleExpanded(_ project: String) {
        if expanded.contains(project) { expanded.remove(project) } else { expanded.insert(project) }
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

        let filtered: [DisplayGroup] = all.compactMap { group in
            // While searching, span everything — every project (incl. legacy "Other"),
            // no recency cutoff, no collapse — and rank by fuzzy match across all fields.
            if searching {
                let rows = group.sessions.filter { SessionStore.matches($0, query: q) }
                return rows.isEmpty ? nil
                    : DisplayGroup(project: group.project, sessions: rows, hiddenCount: 0, expanded: false)
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
            //    a "+N older" tail even when recent, and are still reachable via search.
            let collapsible = recent.count > perProjectCap
            let isOpen = expanded.contains(group.project)
            if !collapsible || isOpen {
                return DisplayGroup(project: group.project, sessions: recent,
                                    hiddenCount: 0, expanded: collapsible && isOpen)
            }
            let shown = Array(recent.prefix(perProjectCap))
            return DisplayGroup(project: group.project, sessions: shown,
                                hiddenCount: recent.count - shown.count, expanded: false)
        }
        groups = filtered

        // Keep a valid selection: preserve if still visible, else first row.
        let flat = filtered.flatMap(\.sessions)
        if selection == nil || !flat.contains(where: { $0.sessionId == selection }) {
            selection = flat.first?.sessionId
        }
    }
}
