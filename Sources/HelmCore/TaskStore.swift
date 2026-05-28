import Foundation

/// Reads the task-vault markdown files into `VaultTask` rows for the overlay.
///
/// Vault   : ~/Home/task-vault/{tasks,archive}/*.md  (one file per task, YAML frontmatter)
/// Schema  : see ~/Home/task-vault/CLAUDE.md
///
/// Parsing matches `list-tasks.py` so this store and the MCP server / scheduler
/// see exactly the same fields. The frontmatter "parser" is the same naive
/// `split-on-first-colon` line walker the Python uses — fine here because the
/// schema is flat and timestamps quote nothing.
public struct TaskStore {
    public let vaultDir: URL

    public init(vaultDir: URL? = nil, home: String = NSHomeDirectory()) {
        self.vaultDir = vaultDir
            ?? URL(fileURLWithPath: home).appendingPathComponent("Home/task-vault")
    }

    // MARK: Public API

    /// Read both buckets, sorted for display. Active by (status, mtime desc);
    /// archive by mtime desc. Unreadable / unparseable files are skipped.
    public func load() -> (active: [VaultTask], archive: [VaultTask]) {
        let active = Self.sortActive(read(vaultDir.appendingPathComponent("tasks"), archived: false))
        let archive = Self.sortArchive(read(vaultDir.appendingPathComponent("archive"), archived: true))
        return (active, archive)
    }

    // MARK: Pure parsing (unit-tested without the filesystem)

    /// Parse one task file's text into a VaultTask. `mtime` and `basename` come from the
    /// caller so this stays pure. Returns nil only on an unrecognised status — every
    /// other malformation degrades to a default (status: todo, title: basename, …)
    /// rather than dropping the row, matching the widget's tolerance.
    public static func parse(text: String, basename: String, mtime: Date, archived: Bool) -> VaultTask {
        let fm = parseFrontmatter(text)
        let title = h1Title(text) ?? basename
        let (done, total) = countSubtasks(text)
        let status = TaskStatus(parsing: fm["status"]) ?? .todo
        let source = resolveSource(jira: fm["jira"], slack: fm["slack"])
        return VaultTask(
            basename: basename, title: title, status: status, source: source,
            archived: archived, mtime: mtime, subtasksDone: done, subtasksTotal: total,
            due: parseISO(fm["due"]),
            checkIn: parseISO(fm["check_in"]),
            wipSince: parseISO(fm["wip_since"])
        )
    }

    /// Extract the YAML frontmatter (between the first `---` fences) into a flat
    /// `[key: value]` dictionary. Values are trimmed; missing fence ⇒ empty dict.
    /// Split on first colon only, so iso8601 timestamps (which contain colons)
    /// survive — same trick as `list-tasks.py`.
    static func parseFrontmatter(_ text: String) -> [String: String] {
        guard text.hasPrefix("---\n") else { return [:] }
        let rest = text.dropFirst(4)
        guard let endRange = rest.range(of: "\n---") else { return [:] }
        let block = rest[..<endRange.lowerBound]
        var out: [String: String] = [:]
        for line in block.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = val }
        }
        return out
    }

    /// First `# Title` line in the body, trimmed; nil if none.
    static func h1Title(_ text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# ") {
                let t = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : t
            }
        }
        return nil
    }

    /// Count GFM checkboxes (`- [ ]` / `- [x]`) with non-empty body text. Empty
    /// trailing `- [ ]` placeholders from the template are not counted (the widget
    /// requires `m.group(2).strip()`).
    static func countSubtasks(_ text: String) -> (done: Int, total: Int) {
        var done = 0, total = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.drop(while: { $0 == " " || $0 == "\t" })
            guard line.hasPrefix("- [") else { continue }
            // After "- [" the layout is <mark>]<space+><body>. Empty body ⇒ skip
            // (matches the Python regex's `\s+(.+)$` — the bare `- [ ]` template
            // placeholder is intentionally not counted).
            let afterPrefix = line.dropFirst(3)
            guard let mark = afterPrefix.first, "xX ".contains(mark),
                  afterPrefix.dropFirst().first == "]" else { continue }
            let body = afterPrefix.dropFirst(2).drop(while: { $0 == " " || $0 == "\t" })
            guard !body.isEmpty else { continue }
            total += 1
            if mark == "x" || mark == "X" { done += 1 }
        }
        return (done, total)
    }

    /// Jira > Slack precedence, matching the widget. Bare keys (`MOBPC-1234`) get
    /// expanded into the BrowserStack Jira URL; full URLs pass through.
    static func resolveSource(jira: String?, slack: String?) -> TaskSource? {
        if let j = jira?.nonEmpty {
            let url = j.hasPrefix("http") ? j : "https://browserstack.atlassian.net/browse/\(j)"
            let key = j.hasPrefix("http")
                ? (j.split(separator: "/").last.map(String.init) ?? j)
                : j
            return .jira(key: key, url: url)
        }
        if let s = slack?.nonEmpty { return .slack(url: s) }
        return nil
    }

    /// Lenient iso8601 parse: accepts `2026-05-12T17:00:00`, `…Z`, or `…+00:00`.
    /// Used for `due`, `check_in`, `wip_since`. Empty/nil ⇒ nil.
    static func parseISO(_ s: String?) -> Date? {
        guard let raw = s?.nonEmpty else { return nil }
        let fmts: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime],
            [.withInternetDateTime, .withFractionalSeconds],
            [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime],
        ]
        let f = ISO8601DateFormatter()
        for opts in fmts {
            f.formatOptions = opts
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }

    // MARK: Sort

    public static func sortActive(_ rows: [VaultTask]) -> [VaultTask] {
        rows.sorted {
            if $0.status.sortRank != $1.status.sortRank { return $0.status.sortRank < $1.status.sortRank }
            return $0.mtime > $1.mtime
        }
    }

    public static func sortArchive(_ rows: [VaultTask]) -> [VaultTask] {
        rows.sorted { $0.mtime > $1.mtime }
    }

    // MARK: Search

    /// Fuzzy subsequence match across title, basename, and source key/URL — same shape
    /// as `SessionStore.matches`. Query is assumed lowercased.
    public static func matches(_ t: VaultTask, query q: String) -> Bool {
        guard !q.isEmpty else { return true }
        if SessionStore.fuzzy(t.title, q) { return true }
        if SessionStore.fuzzy(t.basename, q) { return true }
        switch t.source {
        case .jira(let key, _)? where SessionStore.fuzzy(key, q): return true
        case .slack? where SessionStore.fuzzy("slack", q):        return true
        default: return false
        }
    }

    // MARK: Age flags

    /// Days of `wip` before a row goes amber (stale). Matches `STALE_WIP_DAYS` in JSX.
    public static let staleWipDays: Int = 3

    /// Derive overdue / check-in / stale-wip flags + a short label for the row.
    /// `done` and archived rows always read as none. Priorities: overdue → check-in
    /// → stale-wip → none.
    public static func ageFlags(for task: VaultTask, now: Date) -> TaskAgeFlags {
        if task.archived || task.status == .done { return .none }
        if let due = task.due, due < now {
            let days = Int(now.timeIntervalSince(due) / 86_400)
            return TaskAgeFlags(overdue: true, checkin: false, staleWip: false,
                                label: days > 0 ? "\(days)d late" : "due")
        }
        if let ci = task.checkIn, ci < now {
            return TaskAgeFlags(overdue: false, checkin: true, staleWip: false, label: "check in")
        }
        if task.status == .wip, let since = task.wipSince {
            let days = Int(now.timeIntervalSince(since) / 86_400)
            if days >= staleWipDays {
                return TaskAgeFlags(overdue: false, checkin: false, staleWip: true,
                                    label: "\(days)d wip")
            }
        }
        return .none
    }

    // MARK: Filesystem

    private func read(_ dir: URL, archived: Bool) -> [VaultTask] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var out: [VaultTask] = []
        for f in files where f.pathExtension == "md" {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            out.append(Self.parse(text: text,
                                  basename: f.deletingPathExtension().lastPathComponent,
                                  mtime: mtime, archived: archived))
        }
        return out
    }
}
