import Foundation

/// Display state of a chat row, derived from the live registry + liveness check.
public enum SessionState: String, Equatable {
    case liveBusy   // alive process, status == busy   → 🟢
    case liveIdle   // alive process, status == idle   → ⚪
    case cold       // no live process; resumable      → ·
}

/// One row in the overlay: a Claude session, live or historical, joined on `sessionId`.
public struct ChatSession: Identifiable, Equatable {
    public let sessionId: String
    public let cwd: String
    public let project: String       // grouping key (~/projects/<name>, else "Other")
    public let label: String
    public let state: SessionState
    public let kind: String?         // "interactive" / "bg", live rows only
    public let pid: Int32?           // live rows only
    public let lastActive: Date      // transcript file mtime (history) or now (live-only)

    public var id: String { sessionId }
    public var isLive: Bool { state != .cold }

    public init(sessionId: String, cwd: String, project: String, label: String,
                state: SessionState, kind: String?, pid: Int32?, lastActive: Date) {
        self.sessionId = sessionId; self.cwd = cwd; self.project = project
        self.label = label; self.state = state; self.kind = kind
        self.pid = pid; self.lastActive = lastActive
    }
}

/// A currently-running session, read from ~/.claude/sessions/<pid>.json.
public struct LiveRecord: Equatable {
    public let pid: Int32
    public let sessionId: String
    public let kind: String?
    public let status: String?       // "busy" / "idle"
    public let name: String?
    public init(pid: Int32, sessionId: String, kind: String?, status: String?, name: String?) {
        self.pid = pid; self.sessionId = sessionId; self.kind = kind
        self.status = status; self.name = name
    }
}

/// A session transcript, read from ~/.claude/projects/*/<sessionId>.jsonl.
public struct HistoryRecord: Equatable {
    public let sessionId: String
    public let cwd: String?
    public let gitBranch: String?
    public let aiTitle: String?
    public let entrypoint: String?   // "cli" = user-started; "sdk-py" etc = automation
    public let lastActive: Date
    public init(sessionId: String, cwd: String?, gitBranch: String?, aiTitle: String?,
                entrypoint: String? = nil, lastActive: Date) {
        self.sessionId = sessionId; self.cwd = cwd; self.gitBranch = gitBranch
        self.aiTitle = aiTitle; self.entrypoint = entrypoint; self.lastActive = lastActive
    }
}

extension String {
    public var nonEmpty: String? { isEmpty ? nil : self }
}
