import Foundation

/// A task's lifecycle. Mirrors the four states the markdown vault uses; `set-status.py`
/// rejects anything else. Legacy `in-progress` (older files) is read as `wip`.
public enum TaskStatus: String, Equatable, CaseIterable {
    case todo, wip, blocked, done

    public init?(parsing raw: String?) {
        switch (raw ?? "").lowercased() {
        case "todo":               self = .todo
        case "wip", "in-progress": self = .wip
        case "blocked":            self = .blocked
        case "done":               self = .done
        default:                   return nil
        }
    }

    /// Click-cycle order, matching `cycle` in the widget JSX.
    public var next: TaskStatus {
        switch self {
        case .todo:    return .wip
        case .wip:     return .blocked
        case .blocked: return .done
        case .done:    return .todo
        }
    }

    /// Display-sort priority for active rows (wip first, then todo, blocked, done last).
    var sortRank: Int {
        switch self { case .wip: 0; case .todo: 1; case .blocked: 2; case .done: 3 }
    }
}

/// The clickable source pill on a row. Jira takes precedence when both are set
/// (matches `list-tasks.py`).
public enum TaskSource: Equatable {
    case jira(key: String, url: String)
    case slack(url: String)
}

/// One row in the tasks view, parsed from a single markdown file in
/// `~/Home/task-vault/{tasks,archive}/`.
public struct VaultTask: Identifiable, Equatable {
    public let basename: String          // filename minus `.md`; the stable id
    public let title: String             // h1 if present, else basename
    public let status: TaskStatus
    public let source: TaskSource?
    public let archived: Bool
    public let mtime: Date
    public let subtasksDone: Int
    public let subtasksTotal: Int
    public let due: Date?
    public let checkIn: Date?
    public let wipSince: Date?

    public var id: String { (archived ? "a:" : "") + basename }

    public init(basename: String, title: String, status: TaskStatus, source: TaskSource?,
                archived: Bool, mtime: Date, subtasksDone: Int = 0, subtasksTotal: Int = 0,
                due: Date? = nil, checkIn: Date? = nil, wipSince: Date? = nil) {
        self.basename = basename; self.title = title; self.status = status
        self.source = source; self.archived = archived; self.mtime = mtime
        self.subtasksDone = subtasksDone; self.subtasksTotal = subtasksTotal
        self.due = due; self.checkIn = checkIn; self.wipSince = wipSince
    }

    /// New row with an overridden status — used by the optimistic UI before the disk
    /// write lands and the next reload sees the new value.
    public func withStatus(_ s: TaskStatus) -> VaultTask {
        VaultTask(basename: basename, title: title, status: s, source: source,
                  archived: archived, mtime: mtime, subtasksDone: subtasksDone,
                  subtasksTotal: subtasksTotal, due: due, checkIn: checkIn, wipSince: wipSince)
    }
}

/// Age-derived display flags. Mirrors `ageFlags()` in the widget JSX so the SwiftUI
/// view doesn't need to recompute the rules. Mutually exclusive in priority order:
/// overdue beats checkin beats stale-wip.
public struct TaskAgeFlags: Equatable {
    public let overdue: Bool       // due < now
    public let checkin: Bool       // check_in < now (soft amber)
    public let staleWip: Bool      // wip_since > STALE_WIP_DAYS ago
    public let label: String       // "3d late" / "due" / "check in" / "5d wip" / ""

    public static let none = TaskAgeFlags(overdue: false, checkin: false, staleWip: false, label: "")
}
