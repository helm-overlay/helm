import SwiftUI
import HelmCore

/// State for the tasks view. Parallels `SessionListViewModel` — typeahead filter,
/// keyboard selection, click-to-cycle status — but the data comes from the markdown
/// vault, not the Claude session registry.
///
/// Two display tricks the widget uses, ported faithfully:
/// 1. **Optimistic status override** (5s TTL): cycling a row updates the displayed
///    status immediately, before the disk write completes. The next reload sees the
///    real value and the override expires naturally.
/// 2. **Reorder freeze** (3s window): cycling normally re-sorts the row to a new slot
///    (wip → top, done → bottom). That would jank a double-click. We freeze the
///    visible order for 3s of click inactivity so successive clicks land on the same
///    row before it moves.
@MainActor
final class TaskListViewModel: ObservableObject {
    @Published private(set) var active: [VaultTask] = []     // displayed active rows
    @Published private(set) var archive: [VaultTask] = []    // matches when searching
    @Published private(set) var query: String = ""
    @Published private(set) var querySelected: Bool = false
    @Published private(set) var lastEdit: Date = Date()
    @Published var selection: String?     // basename of selected row
    @Published private(set) var now: Date = Date()

    private let store = TaskStore()
    private let mutator = TaskMutator()
    private var raw: (active: [VaultTask], archive: [VaultTask]) = ([], [])

    private var overrides: [String: (status: TaskStatus, at: Date)] = [:]
    private var frozenOrder: [String]?
    private var lastInteractionAt: Date?

    private var ticker: Timer?
    private var pollTicker: Timer?
    /// Guards `reloadInBackground` against stacking when the 1s poll fires faster than a
    /// vault scan completes.
    private var isReloading = false

    /// Optimistic override expiry — after this, the disk-read value wins again.
    private let overrideTTL: TimeInterval = 5
    /// Click-inactivity window during which row order is held still.
    private let reorderFreezeWindow: TimeInterval = 3
    /// Cap on archive matches surfaced while searching (matches the widget).
    private let archiveMatchCap = 8

    var openCount: Int { raw.active.filter { $0.status != .done }.count }
    var doneCount: Int { raw.active.filter { $0.status == .done }.count }

    // MARK: Visibility

    /// While the panel is open: advance the age clock every 30s, and poll the vault
    /// every 1s to pick up disk-side changes (jira-sync cron, manual edits, the widget).
    func startTicking() {
        now = Date()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        pollTicker?.invalidate()
        pollTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadInBackground() }
        }
    }

    func stopTicking() {
        ticker?.invalidate(); ticker = nil
        pollTicker?.invalidate(); pollTicker = nil
    }

    // MARK: Reload

    func reloadInBackground() {
        guard !isReloading else { return }
        isReloading = true
        _Concurrency.Task.detached(priority: .utility) {
            let r = TaskStore().load()
            await self.ingest(r)
        }
    }

    private func ingest(_ r: (active: [VaultTask], archive: [VaultTask])) {
        isReloading = false
        // Skip the published-property churn when the disk hasn't changed (avoids a
        // SwiftUI redraw every 1s for nothing).
        if r.active == raw.active && r.archive == raw.archive { return }
        raw = r
        recompute(animated: true)
    }

    // MARK: Cycle (status flip)

    /// Cycle the selected row's status. Optimistic — UI flips now, disk write runs off
    /// the main thread. Reorder freeze is engaged so the row holds its slot for 3s.
    func cycleSelected() {
        guard let basename = selection,
              let row = raw.active.first(where: { $0.basename == basename }) else { return }
        let current = overrides[basename]?.status ?? row.status
        let next = current.next
        let displayed = active.map(\.basename)
        overrides[basename] = (next, Date())
        frozenOrder = displayed
        lastInteractionAt = Date()
        recompute(animated: false)   // status pill flips instantly; row stays put
        _Concurrency.Task.detached(priority: .userInitiated) { [mutator] in
            do {
                try mutator.setStatus(basename: basename, to: next)
            } catch {
                NSLog("Helm: set-status failed for \(basename): \(error)")
            }
            await self.reloadInBackground()
        }
    }

    // MARK: Filter / merge / freeze

    private func recompute(animated: Bool) {
        let clock = Date()
        // Drop stale overrides (anything older than TTL); also drop any whose value
        // already matches the disk row (no reason to keep an override that agrees).
        overrides = overrides.filter { entry in
            clock.timeIntervalSince(entry.value.at) < overrideTTL
                && raw.active.first(where: { $0.basename == entry.key })?.status != entry.value.status
        }

        var merged: [VaultTask] = raw.active.map { row in
            overrides[row.basename].map { row.withStatus($0.status) } ?? row
        }

        // Re-sort to the natural (status, mtime) order if not frozen, else keep the
        // displayed order — pulled-in rows that weren't in the freeze order land at end.
        if let order = frozenOrder, let last = lastInteractionAt,
           clock.timeIntervalSince(last) < reorderFreezeWindow {
            var pool = Dictionary(uniqueKeysWithValues: merged.map { ($0.basename, $0) })
            var ordered: [VaultTask] = []
            for name in order {
                if let row = pool.removeValue(forKey: name) { ordered.append(row) }
            }
            // Anything new (a task added since the freeze started) appends at the end,
            // sorted naturally so the tail is at least internally consistent.
            ordered.append(contentsOf: TaskStore.sortActive(Array(pool.values)))
            merged = ordered
        } else {
            frozenOrder = nil
            lastInteractionAt = nil
            merged = TaskStore.sortActive(merged)
        }

        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let displayed: [VaultTask]
        let arc: [VaultTask]
        if q.isEmpty {
            displayed = merged
            arc = []
        } else {
            displayed = merged.filter { TaskStore.matches($0, query: q) }
            arc = Array(raw.archive.filter { TaskStore.matches($0, query: q) }.prefix(archiveMatchCap))
        }

        commit(active: displayed, archive: arc, animated: animated)
    }

    private func commit(active: [VaultTask], archive: [VaultTask], animated: Bool) {
        guard animated else {
            self.active = active
            self.archive = archive
            reconcileSelection()
            return
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            self.active = active
            self.archive = archive
            reconcileSelection()
        }
    }

    private func reconcileSelection() {
        let all = active + archive
        if selection == nil || !all.contains(where: { $0.basename == selection }) {
            selection = all.first?.basename
        }
    }

    // MARK: Query (typeahead) — same surface as SessionListViewModel

    func appendQuery(_ s: String) {
        if querySelected { query = ""; querySelected = false }
        query += s
        lastEdit = Date()
        recompute(animated: false)
    }

    func backspaceQuery() {
        if querySelected { clearQuery(); return }
        guard !query.isEmpty else { return }
        query.removeLast()
        lastEdit = Date()
        recompute(animated: false)
    }

    func deleteWordBack() {
        if querySelected { clearQuery(); return }
        guard !query.isEmpty else { return }
        var s = query[...]
        while let c = s.last, c == " " { s = s.dropLast() }
        while let c = s.last, c != " " { s = s.dropLast() }
        query = String(s)
        lastEdit = Date()
        recompute(animated: false)
    }

    func clearQuery() {
        querySelected = false
        lastEdit = Date()
        guard !query.isEmpty else { return }
        query = ""
        recompute(animated: false)
    }

    func selectAllQuery() { querySelected = !query.isEmpty }
    func clearSelection() { querySelected = false }

    // MARK: Selection (arrows)

    private var visibleFlat: [VaultTask] { active + archive }

    var selectedTask: VaultTask? {
        visibleFlat.first { $0.basename == selection }
    }

    func move(by delta: Int) {
        let flat = visibleFlat
        guard !flat.isEmpty else { selection = nil; return }
        let cur = flat.firstIndex { $0.basename == selection } ?? -1
        let next = max(0, min(flat.count - 1, cur + delta))
        selection = flat[next].basename
    }
}
