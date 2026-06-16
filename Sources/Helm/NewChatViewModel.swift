import SwiftUI
import HelmCore

/// State for the new-chat picker — the small overlay that launches a fresh `claude` in any
/// tracked project. Pure consumer of already-loaded data: it's seeded with the project list
/// each time it opens (built from the warm session cache), then filters/selects in memory.
/// No filesystem scan of its own — opening it is instant.
@MainActor
final class NewChatViewModel: ObservableObject {
    @Published private(set) var choices: [ProjectChoice] = []   // ranked recent-first, unfiltered
    @Published private(set) var field = QueryField()
    @Published private(set) var lastEdit: Date = Date()
    @Published var selection: String?                           // ProjectChoice.id (path)

    var query: String { field.text }
    var querySelected: Bool { field.selectedAll }
    var queryBeforeCursor: String { field.beforeCursor }
    var queryAfterCursor: String { field.afterCursor }

    /// The current query's matches, ranked order preserved.
    var filtered: [ProjectChoice] { SessionStore.filterProjectChoices(choices, query: query) }

    var selectedChoice: ProjectChoice? { filtered.first { $0.id == selection } }

    /// (Re)seed the picker as it opens. `preselect` names the project to land on (the one
    /// the user was looking at when they hit ⌘N); when it isn't in the list — or isn't
    /// given — selection falls to the most-recently-active *project*, skipping the pinned
    /// Singular Chats launchpad so ⌘N then ↵ never starts a drive-by by accident.
    func open(_ choices: [ProjectChoice], preselect: String? = nil) {
        self.choices = choices
        field = QueryField()
        lastEdit = Date()
        selection = choices.first { $0.name == preselect }?.id
            ?? choices.first { !$0.isLaunchpad }?.id
            ?? choices.first?.id
    }

    // MARK: Query (editable filter line) — mirrors the other launchers so editing feels identical.

    /// Text edits narrow the project list; caret moves don't.
    private func edit(_ change: (inout QueryField) -> Void) { change(&field); lastEdit = Date(); reconcileSelection() }
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
