import SwiftUI
import HelmCore

/// State for the attention launcher — the small default view. Two urgency-ranked sections:
/// sessions that want you (needs-input / review), then PRs that want you (review-requested /
/// CI-failed / changes-requested / ready). Currently-working sessions trail in a dimmed
/// section so the launcher doubles as a "what's live" glance.
///
/// Sessions and PRs refresh on independent cadences — sessions every ~1.5s (cheap local
/// reads, and their state flips fast) and PRs every 15s (one network round-trip) — merged
/// from per-source caches so a slow PR fetch never holds back live session state.
@MainActor
final class AttentionListViewModel: ObservableObject {
    /// Attention sessions first (needs-input, then review), busy/working sessions last —
    /// one section, ranked by urgency, like the old per-project lists.
    @Published private(set) var sessions: [ChatSession] = []
    @Published private(set) var attentionPRs: [PullRequest] = []        // rank ≤ 1
    @Published private(set) var query: String = ""
    @Published private(set) var querySelected: Bool = false
    @Published private(set) var lastEdit: Date = Date()
    @Published private(set) var loading: Bool = false
    @Published var selection: String?                                   // AttentionItem.id

    private var cachedSessions: [ChatSession] = []
    private var cachedPRs: [PullRequest] = []
    private var loadedSessions = false
    private var loadedPRs = false

    private var sessionTicker: Timer?
    private var prTicker: Timer?
    private var reloadingSessions = false
    private var reloadingPRs = false
    /// Sessions we've killed but whose process may still be exiting — suppressed from the
    /// list until a reload confirms them gone, so a mid-teardown poll can't resurrect them.
    private var killed: Set<String> = []

    var attentionCount: Int { sessions.filter { $0.reason.wantsAttention }.count + attentionPRs.count }
    var workingCount: Int { sessions.filter { $0.reason == .live }.count }

    // MARK: Visibility

    func startTicking() {
        sessionTicker?.invalidate()
        sessionTicker = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSessions() }
        }
        prTicker?.invalidate()
        prTicker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadPRs() }
        }
    }

    func stopTicking() {
        sessionTicker?.invalidate(); sessionTicker = nil
        prTicker?.invalidate(); prTicker = nil
    }

    func reloadInBackground() {
        loading = !loadedSessions && !loadedPRs
        reloadSessions()
        reloadPRs()
    }

    // MARK: Reload (per source)

    private func reloadSessions() {
        guard !reloadingSessions else { return }
        reloadingSessions = true
        _Concurrency.Task.detached(priority: .utility) {
            let s = SessionStore().load()
            await self.ingestSessions(s)
        }
    }

    private func reloadPRs() {
        guard !reloadingPRs else { return }
        reloadingPRs = true
        _Concurrency.Task.detached(priority: .utility) {
            let p = PRSource().fetchAll()
            await self.ingestPRs(p)
        }
    }

    private func ingestSessions(_ s: [ChatSession]) {
        reloadingSessions = false
        loadedSessions = true
        cachedSessions = s.filter { !killed.contains($0.id) }
        recompute()
    }

    // MARK: Kill (⌘X)

    /// Terminate a session and drop it immediately; the process teardown runs off the main
    /// thread, and the row stays suppressed until that completes so a poll can't bring it back.
    func kill(_ session: ChatSession) {
        guard let pid = session.pid else { return }
        killed.insert(session.id)
        cachedSessions.removeAll { $0.id == session.id }
        recompute()
        _Concurrency.Task.detached(priority: .userInitiated) {
            SessionStore.clearState(agent: session.agent, sessionId: session.sessionId)
            SessionStore.terminateAndWait(pid)
            await self.finishKill(session.id)
        }
    }

    private func finishKill(_ id: String) {
        killed.remove(id)
        reloadSessions()
    }

    private func ingestPRs(_ p: [PullRequest]) {
        reloadingPRs = false
        loadedPRs = true
        cachedPRs = p
        recompute()
    }

    // MARK: Merge / filter

    private func recompute() {
        loading = false
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()

        // Attention (rank ≤ 1) and working (rank 2 .live) sessions in one list, urgency-ordered
        // so working naturally falls to the bottom. Cold sessions never appear here.
        let sess = cachedSessions
            .filter { ($0.reason.wantsAttention || $0.reason == .live) && Self.matches($0, query: q) }
            .sorted(by: byUrgency)
        let prs = cachedPRs
            .filter { $0.reason.wantsAttention && Self.matches($0, query: q) }
            .sorted(by: byUrgency)

        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            sessions = sess
            attentionPRs = prs
            reconcileSelection()
        }
    }

    /// Louder (lower rank) first, then newest — within a single type's section.
    private func byUrgency<T: AttentionItem>(_ a: T, _ b: T) -> Bool {
        a.reason.rank != b.reason.rank ? a.reason.rank < b.reason.rank : a.lastActive > b.lastActive
    }

    /// Type-agnostic match over the contract — title (label / PR title) and subtitle
    /// (project·branch / repo#number).
    static func matches(_ item: any AttentionItem, query q: String) -> Bool {
        guard !q.isEmpty else { return true }
        return item.title.lowercased().contains(q)
            || (item.subtitle?.lowercased().contains(q) ?? false)
    }

    private func reconcileSelection() {
        let ids = flat.map(\.id)
        if selection == nil || !ids.contains(where: { $0 == selection }) {
            selection = ids.first
        }
    }

    // MARK: Query (typeahead)

    func appendQuery(_ s: String) {
        if querySelected { query = ""; querySelected = false }
        query += s; lastEdit = Date(); recompute()
    }

    func backspaceQuery() {
        if querySelected { clearQuery(); return }
        guard !query.isEmpty else { return }
        query.removeLast(); lastEdit = Date(); recompute()
    }

    func deleteWordBack() {
        if querySelected { clearQuery(); return }
        guard !query.isEmpty else { return }
        var s = query[...]
        while let c = s.last, c == " " { s = s.dropLast() }
        while let c = s.last, c != " " { s = s.dropLast() }
        query = String(s); lastEdit = Date(); recompute()
    }

    func clearQuery() {
        querySelected = false; lastEdit = Date()
        guard !query.isEmpty else { return }
        query = ""; recompute()
    }

    func selectAllQuery() { querySelected = !query.isEmpty }
    func clearSelection() { querySelected = false }

    // MARK: Selection (arrows)

    /// Sessions (attention then working), then PRs — the visible top-to-bottom order.
    private var flat: [any AttentionItem] {
        sessions.map { $0 as any AttentionItem }
            + attentionPRs.map { $0 as any AttentionItem }
    }

    var selectedItem: (any AttentionItem)? { flat.first { $0.id == selection } }

    func move(by delta: Int) {
        let rows = flat
        guard !rows.isEmpty else { selection = nil; return }
        let cur = rows.firstIndex { $0.id == selection } ?? -1
        let next = max(0, min(rows.count - 1, cur + delta))
        selection = rows[next].id
    }

    // MARK: Layout

    /// Visible row + section-header count, for sizing the launcher panel to its content.
    var visibleRowCount: Int { sessions.count + attentionPRs.count }
    var visibleSectionCount: Int {
        [!sessions.isEmpty, !attentionPRs.isEmpty].filter { $0 }.count
    }
}
