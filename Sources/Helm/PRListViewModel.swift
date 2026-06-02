import SwiftUI
import HelmCore

/// State for the PRs view. Parallels `TaskListViewModel` — typeahead filter, keyboard
/// selection — but the data comes from `gh` over the network, so it polls on a slow cadence
/// (30s) and on summon rather than every second, and shows a loading state on a cold start.
@MainActor
final class PRListViewModel: ObservableObject {
    @Published private(set) var prs: [PullRequest] = []     // displayed rows
    @Published private(set) var query: String = ""
    @Published private(set) var querySelected: Bool = false
    @Published private(set) var lastEdit: Date = Date()
    @Published private(set) var loading: Bool = false        // cold start, nothing cached yet
    @Published var selection: String?                        // PullRequest.id

    private var raw: [PullRequest] = []
    private var pollTicker: Timer?
    private var isReloading = false

    var reviewCount: Int { raw.filter(\.reviewRequestedFromMe).count }
    var mineCount: Int { raw.filter(\.isMine).count }

    // MARK: Visibility

    /// Poll `gh` every 15s while the panel is open — PRs change on human timescales and each
    /// fetch is a network round-trip (one GraphQL call), so a 1s cadence (like tasks) would
    /// be wasteful. A fresh fetch also runs on every summon (see `show()`), so reopening the
    /// panel after acting on a PR reflects the change without waiting for the tick.
    func startTicking() {
        pollTicker?.invalidate()
        pollTicker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadInBackground() }
        }
    }

    func stopTicking() { pollTicker?.invalidate(); pollTicker = nil }

    // MARK: Reload

    func reloadInBackground() {
        guard !isReloading else { return }
        isReloading = true
        if raw.isEmpty { loading = true }
        _Concurrency.Task.detached(priority: .utility) {
            let fetched = PRSource().fetchAll()
            await self.ingest(fetched)
        }
    }

    private func ingest(_ fetched: [PullRequest]) {
        isReloading = false
        loading = false
        let unchanged = fetched == raw
        raw = fetched
        if unchanged { return }
        recompute(animated: true)
    }

    // MARK: Filter

    private func recompute(animated: Bool) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? raw : raw.filter { PRSource.matches($0, query: q) }
        commit(filtered, animated: animated)
    }

    private func commit(_ rows: [PullRequest], animated: Bool) {
        guard animated else { prs = rows; reconcileSelection(); return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            prs = rows
            reconcileSelection()
        }
    }

    private func reconcileSelection() {
        if selection == nil || !prs.contains(where: { $0.id == selection }) {
            selection = prs.first?.id
        }
    }

    // MARK: Query (typeahead) — same surface as the other views

    func appendQuery(_ s: String) {
        if querySelected { query = ""; querySelected = false }
        query += s; lastEdit = Date(); recompute(animated: false)
    }

    func backspaceQuery() {
        if querySelected { clearQuery(); return }
        guard !query.isEmpty else { return }
        query.removeLast(); lastEdit = Date(); recompute(animated: false)
    }

    func deleteWordBack() {
        if querySelected { clearQuery(); return }
        guard !query.isEmpty else { return }
        var s = query[...]
        while let c = s.last, c == " " { s = s.dropLast() }
        while let c = s.last, c != " " { s = s.dropLast() }
        query = String(s); lastEdit = Date(); recompute(animated: false)
    }

    func clearQuery() {
        querySelected = false; lastEdit = Date()
        guard !query.isEmpty else { return }
        query = ""; recompute(animated: false)
    }

    func selectAllQuery() { querySelected = !query.isEmpty }
    func clearSelection() { querySelected = false }

    // MARK: Selection (arrows)

    var selectedPR: PullRequest? { prs.first { $0.id == selection } }

    func move(by delta: Int) {
        guard !prs.isEmpty else { selection = nil; return }
        let cur = prs.firstIndex { $0.id == selection } ?? -1
        let next = max(0, min(prs.count - 1, cur + delta))
        selection = prs[next].id
    }
}
