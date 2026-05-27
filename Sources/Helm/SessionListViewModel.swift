import SwiftUI
import HelmCore

struct DisplayGroup: Identifiable {
    let project: String
    let sessions: [ChatSession]
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
        all = grouped
        applyFilter()
    }

    // MARK: Query (typeahead)

    func appendQuery(_ s: String) { query += s; applyFilter() }
    func backspaceQuery() { if !query.isEmpty { query.removeLast(); applyFilter() } }

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
        let filtered: [DisplayGroup] = all.compactMap { group in
            guard !q.isEmpty else { return DisplayGroup(project: group.project, sessions: group.sessions) }
            let hits = group.sessions.filter {
                $0.label.lowercased().contains(q) || group.project.lowercased().contains(q)
            }
            return hits.isEmpty ? nil : DisplayGroup(project: group.project, sessions: hits)
        }
        groups = filtered

        // Keep a valid selection: preserve if still visible, else first row.
        let flat = filtered.flatMap(\.sessions)
        if selection == nil || !flat.contains(where: { $0.sessionId == selection }) {
            selection = flat.first?.sessionId
        }
    }
}
