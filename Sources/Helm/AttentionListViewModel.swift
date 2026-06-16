import SwiftUI
import HelmCore

/// One displayed row plus view-only flags the model computed for it.
struct FeedRow: Identifiable {
    let item: any AttentionItem
    let expiringSoon: Bool    // about to drop off the feed (source.expiringSoon)
    var id: String { item.id }
}

/// One source's rows in the attention launcher, rendered as a titled section.
struct FeedSection: Identifiable {
    let id: String            // source id
    let title: String         // section header
    let presentation: AnyAttentionSourcePresentation
    let rows: [FeedRow]
}

/// State for the attention launcher — the default view. Source-driven: it holds a list of
/// `AttentionSource`s and renders each one's promoted rows as a titled section, urgency-ranked.
/// Adding a row type means adding a source to the list — nothing here changes.
///
/// Each source refreshes on its own cadence (`refreshPolicy`) into its own cache slice, so a
/// slow network source (PRs, 15s) never holds back a fast local one (sessions, 1.5s). The VM
/// owns this per-source concurrency itself rather than awaiting all sources together.
@MainActor
final class AttentionListViewModel: ObservableObject {
    /// One section per source with promoted rows, in source-registration order.
    @Published private(set) var sections: [FeedSection] = []
    @Published private(set) var field = QueryField()
    @Published private(set) var lastEdit: Date = Date()
    @Published private(set) var loading: Bool = false
    @Published var selection: String?                                   // AttentionItem.id

    var query: String { field.text }
    var querySelected: Bool { field.selectedAll }
    var queryBeforeCursor: String { field.beforeCursor }
    var queryAfterCursor: String { field.afterCursor }

    private let registrations: [AttentionSourceRegistration]

    private var sources: [any AttentionSource] { registrations.map(\.source) }
    private var cache: [String: [any AttentionItem]] = [:]              // keyed by source.id
    private var timers: [String: Timer] = [:]
    private var reloading: Set<String> = []                             // per-source reentrancy guard
    private var loaded: Set<String> = []                                // sources that have reported once
    /// Sessions we've killed but whose process may still be exiting — suppressed from the
    /// list until a reload confirms them gone, so a mid-teardown poll can't resurrect them.
    private var killed: Set<String> = []

    /// The registration point: add an integration by adding its source and presentation here.
    init(registrations: [AttentionSourceRegistration] = AttentionSourceRegistration.defaults) {
        self.registrations = registrations
    }

    var attentionCount: Int { flat.filter { $0.reason.wantsAttention }.count }
    var workingCount: Int { flat.filter { $0.reason == .live }.count }

    // MARK: Visibility

    /// Start each source on its declared cadence: `.interval` sources get a timer; `.push`
    /// sources drive their own updates via `start(onChange:)`; `.onSummonOnly` refresh only
    /// on `reloadInBackground`.
    func startTicking() {
        stopTicking()
        for source in sources {
            switch source.refreshPolicy {
            case .interval(let seconds):
                timers[source.id] = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reload(source) }
                }
            case .push:
                source.start { [weak self] items in
                    _Concurrency.Task { @MainActor in self?.ingest(items, from: source) }
                }
            case .onSummonOnly:
                break
            }
        }
    }

    func stopTicking() {
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
        sources.forEach { $0.stop() }
    }

    func reloadInBackground() {
        loading = loaded.isEmpty
        sources.forEach { reload($0) }
    }

    // MARK: Reload (per source)

    private func reload(_ source: any AttentionSource) {
        guard !reloading.contains(source.id) else { return }
        reloading.insert(source.id)
        _Concurrency.Task.detached(priority: .utility) {
            let items = await source.allItems()
            await self.ingest(items, from: source)
        }
    }

    private func ingest(_ items: [any AttentionItem], from source: any AttentionSource) {
        reloading.remove(source.id)
        loaded.insert(source.id)
        cache[source.id] = items.filter { !killed.contains($0.id) }
        recompute()
    }

    // MARK: Kill (⌘X)

    /// Terminate a session and drop it immediately; the process teardown runs off the main
    /// thread, and the row stays suppressed until that completes so a poll can't bring it back.
    func kill(_ session: ChatSession) {
        guard let pid = session.pid else { return }
        let owner = sourceID(holding: session.id)
        killed.insert(session.id)
        for key in cache.keys { cache[key]?.removeAll { $0.id == session.id } }
        recompute()
        _Concurrency.Task.detached(priority: .userInitiated) {
            SessionStore.clearState(agent: session.agent, sessionId: session.sessionId)
            SessionStore.terminateAndWait(pid)
            await self.finishKill(session.id, owner: owner)
        }
    }

    private func finishKill(_ id: String, owner: String?) {
        killed.remove(id)
        if let owner, let source = sources.first(where: { $0.id == owner }) { reload(source) }
        else { reloadInBackground() }
    }

    /// ⌘X on a building Jenkins row: POST `/stop` to abort it, then re-poll the source so the
    /// row settles (aborted → drops out of the feed). The build is dropped optimistically; a
    /// reload restores it if the abort didn't take.
    func stopBuild(_ job: JenkinsJob) {
        let owner = sourceID(holding: job.id)
        guard let source = sources.first(where: { $0.id == "jenkins" }) as? JenkinsSource else { return }
        killed.insert(job.id)
        for key in cache.keys { cache[key]?.removeAll { $0.id == job.id } }
        recompute()
        _Concurrency.Task.detached(priority: .userInitiated) {
            source.stop(job)
            await self.finishKill(job.id, owner: owner)
        }
    }

    /// Which source's cache slice currently holds `id` — so a kill reloads only that source.
    private func sourceID(holding id: String) -> String? {
        cache.first { $0.value.contains { $0.id == id } }?.key
    }

    // MARK: Merge / filter

    private func recompute() {
        loading = false
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let searching = !q.isEmpty
        // At rest each source contributes its promoted rows (the attention feed). The moment
        // you type, the gate drops and the full cached inventory is searched instead, so cold
        // sessions and non-urgent PRs surface — resting = push, expansion = pull. Either way,
        // rows rank by urgency (loudest first, then newest); empty sections drop.
        let next: [FeedSection] = registrations.compactMap { registration in
            let source = registration.source
            let pool = cache[source.id] ?? []
            let visible = (searching ? pool.filter { $0.matches(q) } : pool.filter(source.promotes))
                .sorted(by: AttentionFeed.precedes)
            let rows = visible.map { FeedRow(item: $0, expiringSoon: !searching && source.expiringSoon($0)) }
            return rows.isEmpty ? nil : FeedSection(id: source.id,
                                                    title: source.title,
                                                    presentation: registration.presentation,
                                                    rows: rows)
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            sections = next
            reconcileSelection()
        }
    }

    private func reconcileSelection() {
        let ids = flat.map(\.id)
        if selection == nil || !ids.contains(where: { $0 == selection }) {
            selection = ids.first
        }
    }

    // MARK: Query (editable filter line)

    /// Text edits change the filter, so they recompute the feed; caret moves don't.
    private func edit(_ change: (inout QueryField) -> Void) { change(&field); lastEdit = Date(); recompute() }
    private func navigate(_ change: (inout QueryField) -> Void) { change(&field); lastEdit = Date() }

    func appendQuery(_ s: String) { edit { $0.insert(s) } }
    func backspaceQuery() { edit { $0.backspace() } }
    func deleteWordBack() { edit { $0.deleteWordBack() } }
    func clearQuery() { edit { $0.clear() } }

    func moveCursor(by delta: Int) { navigate { $0.moveCursor(by: delta) } }
    func moveWord(by delta: Int) { navigate { $0.moveWord(by: delta) } }
    func moveCursorToStart() { navigate { $0.moveToStart() } }
    func moveCursorToEnd() { navigate { $0.moveToEnd() } }

    func selectAllQuery() { navigate { $0.selectAll() } }
    func clearSelection() { navigate { $0.deselect() } }

    // MARK: Selection (arrows)

    /// Sources top-to-bottom, each source's rows in display order — the visible flat order.
    private var flat: [any AttentionItem] { sections.flatMap(\.rows).map(\.item) }

    var selectedItem: (any AttentionItem)? { flat.first { $0.id == selection } }

    /// Every cached session row (incl. cold), for seeding the new-chat picker's project list
    /// without a fresh filesystem read. Drawn from the source caches, type-filtered.
    var cachedSessions: [ChatSession] {
        cache.values.flatMap { $0 }.compactMap { $0 as? ChatSession }
    }

    func move(by delta: Int) {
        let rows = flat
        guard !rows.isEmpty else { selection = nil; return }
        let cur = rows.firstIndex { $0.id == selection } ?? -1
        let next = max(0, min(rows.count - 1, cur + delta))
        selection = rows[next].id
    }

    // MARK: Layout

    /// Visible row + section-header count, for sizing the launcher panel to its content.
    var visibleRowCount: Int { flat.count }
    var visibleSectionCount: Int { sections.count }
}
