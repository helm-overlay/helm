import SwiftUI
import HelmCore

/// State for the new-chat picker — the small overlay that launches a fresh `claude` in any
/// tracked project. Pure consumer of already-loaded data: it's seeded with the project list
/// each time it opens (built from the warm session cache), then filters/selects in memory.
/// No filesystem scan of its own — opening it is instant.
@MainActor
final class NewChatViewModel: ObservableObject {
    @Published private(set) var choices: [ProjectChoice] = []   // ranked recent-first, unfiltered
    @Published private(set) var query: String = ""
    @Published private(set) var querySelected: Bool = false
    @Published private(set) var lastEdit: Date = Date()
    @Published var selection: String?                           // ProjectChoice.id (path)

    /// The current query's matches, ranked order preserved.
    var filtered: [ProjectChoice] { SessionStore.filterProjectChoices(choices, query: query) }

    var selectedChoice: ProjectChoice? { filtered.first { $0.id == selection } }

    /// (Re)seed the picker as it opens. `preselect` names the project to land on (the one
    /// the user was looking at when they hit ⌘N); when it isn't in the list — or isn't
    /// given — selection falls to the top row, i.e. the most-recently-active project.
    func open(_ choices: [ProjectChoice], preselect: String? = nil) {
        self.choices = choices
        query = ""
        querySelected = false
        lastEdit = Date()
        selection = choices.first { $0.name == preselect }?.id ?? choices.first?.id
    }

    // MARK: Query (typeahead) — mirrors the other launchers so editing feels identical.

    func appendQuery(_ s: String) {
        if querySelected { query = ""; querySelected = false }
        query += s; lastEdit = Date(); reconcileSelection()
    }

    func backspaceQuery() {
        if querySelected { clearQuery(); return }
        guard !query.isEmpty else { return }
        query.removeLast(); lastEdit = Date(); reconcileSelection()
    }

    func deleteWordBack() {
        if querySelected { clearQuery(); return }
        guard !query.isEmpty else { return }
        var s = query[...]
        while let c = s.last, c == " " { s = s.dropLast() }
        while let c = s.last, c != " " { s = s.dropLast() }
        query = String(s); lastEdit = Date(); reconcileSelection()
    }

    func clearQuery() {
        querySelected = false; lastEdit = Date()
        guard !query.isEmpty else { return }
        query = ""; reconcileSelection()
    }

    func selectAllQuery() { querySelected = !query.isEmpty }
    func clearSelection() { querySelected = false }

    // MARK: Selection (arrows)

    func move(by delta: Int) {
        let rows = filtered
        guard !rows.isEmpty else { selection = nil; return }
        let cur = rows.firstIndex { $0.id == selection } ?? -1
        let next = max(0, min(rows.count - 1, cur + delta))
        selection = rows[next].id
    }

    /// Keep the highlight on a still-visible row as the query narrows the list — fall to the
    /// top match when the selected project filters out.
    private func reconcileSelection() {
        let rows = filtered
        if selection == nil || !rows.contains(where: { $0.id == selection }) {
            selection = rows.first?.id
        }
    }
}
