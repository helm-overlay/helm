import Foundation

/// Display state of a chat row, derived from the live registry + liveness check.
public enum SessionState: String, Equatable {
    case liveBusy   // alive process, status == busy   → orbiting satellite
    case liveIdle   // alive process, status == idle   → parked satellite
    case cold       // no live process; resumable      → dashed ring
}

/// Why a `liveIdle` session stopped — distinguishes "waiting on me" from "ready for me
/// to look". Derived from the transcript tail (see `SessionStore.classifyIdleTail`).
/// Structural signals (an unanswered question/permission) are high-confidence; the
/// trailing-"?" check is high-precision but low-recall, so `needsReview` is "nothing
/// pending that we can detect", not a guarantee of completion.
public enum IdleReason: String, Equatable {
    case needsInput   // ended awaiting the user (decision / permission / a question)
    case needsReview  // concluded with nothing detectably pending — done, come look
}

/// One row in the overlay: a Claude session, live or historical, joined on `sessionId`.
public struct ChatSession: Identifiable, Equatable {
    public let sessionId: String
    public let cwd: String
    public let project: String       // grouping key (~/projects/<name>, else "Other")
    public let label: String
    public let branch: String?       // git branch, for search matching only
    public let state: SessionState
    public let idleReason: IdleReason?   // non-nil only when state == .liveIdle
    public let kind: String?         // "interactive" / "bg", live rows only
    public let pid: Int32?           // live rows only
    public let lastActive: Date      // transcript file mtime (history) or now (live-only)

    public var id: String { sessionId }
    public var isLive: Bool { state != .cold }
    public var needsInput: Bool { state == .liveIdle && idleReason == .needsInput }
    /// Idle and finished (or pending classification) — done, ready for you to review.
    public var needsReview: Bool { state == .liveIdle && idleReason != .needsInput }

    public init(sessionId: String, cwd: String, project: String, label: String,
                state: SessionState, kind: String?, pid: Int32?, lastActive: Date,
                branch: String? = nil, idleReason: IdleReason? = nil) {
        self.sessionId = sessionId; self.cwd = cwd; self.project = project
        self.label = label; self.branch = branch; self.state = state; self.kind = kind
        self.pid = pid; self.lastActive = lastActive; self.idleReason = idleReason
    }

    public func with(idleReason: IdleReason?) -> ChatSession {
        ChatSession(sessionId: sessionId, cwd: cwd, project: project, label: label,
                    state: state, kind: kind, pid: pid, lastActive: lastActive,
                    branch: branch, idleReason: idleReason)
    }

    /// A dead (cold) copy — for optimistic UI after we kill the process ourselves,
    /// before the next filesystem poll confirms it. Stays resumable from history.
    public func markedDead() -> ChatSession {
        ChatSession(sessionId: sessionId, cwd: cwd, project: project, label: label,
                    state: .cold, kind: nil, pid: nil, lastActive: lastActive,
                    branch: branch, idleReason: nil)
    }

    /// Synthetic row for an empty project group — selectable so ⌘N / Enter has somewhere
    /// to land. Not a real session: its `sessionId` carries `placeholderPrefix`; the
    /// dispatch path treats Enter as "new chat here" instead of "resume".
    public static let placeholderPrefix = "__placeholder__"
    public static func placeholder(forProject project: String, cwd: String) -> ChatSession {
        ChatSession(sessionId: placeholderPrefix + project, cwd: cwd, project: project,
                    label: "(no chats yet — ⌘N to start)", state: .cold,
                    kind: nil, pid: nil, lastActive: .distantPast)
    }
    public var isPlaceholder: Bool { sessionId.hasPrefix(Self.placeholderPrefix) }
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
