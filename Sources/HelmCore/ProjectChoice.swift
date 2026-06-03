import Foundation

/// One launchable project in the new-chat picker: a tracked workspace folder, the path a
/// new chat `cd`s into, and how recently it last saw a session — the signal that floats the
/// projects you actually work in to the top, so the common case is summon → ⌘N → ↵.
public struct ProjectChoice: Identifiable, Equatable {
    public let name: String        // folder basename — the display name and grouping key
    public let path: String        // absolute directory a new chat launches in
    public let lastActive: Date?   // most-recent session here; nil if the folder is untouched
    public let liveCount: Int      // sessions currently running here

    public var id: String { path }

    public init(name: String, path: String, lastActive: Date?, liveCount: Int) {
        self.name = name
        self.path = path
        self.lastActive = lastActive
        self.liveCount = liveCount
    }
}

extension SessionStore {
    /// The new-chat picker's project list: one row per tracked workspace folder, ranked
    /// recent-first. Membership comes from `workspaceFolders` alone — a freshly added,
    /// never-used folder still launches — while `sessions` supply each folder's recency and
    /// live tally for the ranking and glyphs. Sessions outside any tracked folder ("Other",
    /// the ~/Home launchpad) are ignored: the picker is tracked-workspaces-only by design.
    public static func projectChoices(workspaceFolders: [String], sessions: [ChatSession]) -> [ProjectChoice] {
        let byProject = Dictionary(grouping: sessions, by: \.project)
        var seen = Set<String>()
        let choices = workspaceFolders.compactMap { folder -> ProjectChoice? in
            let path = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }   // a folder listed twice yields one row
            let name = URL(fileURLWithPath: path).lastPathComponent
            let rows = byProject[name] ?? []
            return ProjectChoice(name: name, path: path,
                                 lastActive: rows.map(\.lastActive).max(),
                                 liveCount: rows.filter(\.isLive).count)
        }
        return choices.sorted(by: rankProjectChoice)
    }

    /// Recent-first: a folder with activity outranks one without; two active folders sort by
    /// recency; two untouched folders alphabetically.
    static func rankProjectChoice(_ a: ProjectChoice, _ b: ProjectChoice) -> Bool {
        switch (a.lastActive, b.lastActive) {
        case let (l?, r?):  return l > r
        case (.some, nil):  return true
        case (nil, .some):  return false
        case (nil, nil):    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Filter the picker list by a fuzzy query over folder name and path — the same
    /// subsequence matcher as session search. Empty query leaves the ranked order intact.
    public static func filterProjectChoices(_ choices: [ProjectChoice], query: String) -> [ProjectChoice] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return choices }
        return choices.filter { fuzzy($0.name, q) || fuzzy($0.path, q) }
    }
}
