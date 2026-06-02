import Foundation

/// One notification to post: a session that just crossed into an attention state.
public struct SessionNotification: Equatable {
    public let sessionId: String
    public let agent: AgentKind
    public let reason: IdleReason     // .needsInput (blocked on you) or .needsReview (done)
    public let label: String
    public let project: String
    public let cwd: String
    public let summary: String?       // the Stop-hook one-liner, when present

    public init(sessionId: String, agent: AgentKind, reason: IdleReason,
                label: String, project: String, cwd: String, summary: String?) {
        self.sessionId = sessionId; self.agent = agent; self.reason = reason
        self.label = label; self.project = project; self.cwd = cwd; self.summary = summary
    }

    /// Stable per-session id so a later state for the same session replaces its banner
    /// rather than stacking a second one.
    public var notificationId: String { "\(agent.rawValue):\(sessionId)" }
}

/// Pure transition detector: given the previously-seen attention verdict per session and
/// the current rows, decide which sessions just *entered* (or changed) an attention state
/// and therefore warrant a notification. Filesystem-free and unit-tested.
///
/// A notification fires when a session's attention verdict differs from what we last saw —
/// so a fresh `needsReview`/`needsInput`, or a flip between the two, notifies once; a
/// session that stays in the same verdict across polls does not re-notify. A session that
/// leaves attention (back to busy, or gone cold/closed) is dropped from the map, so a later
/// re-entry notifies again.
public enum NotificationPlanner {
    /// - Parameters:
    ///   - previous: the verdict map returned by the prior call (empty on first run).
    ///   - rows: the current merged session list.
    /// - Returns: the notifications to post and the new verdict map to carry forward.
    public static func plan(previous: [String: IdleReason], rows: [ChatSession])
        -> (notifications: [SessionNotification], state: [String: IdleReason]) {
        var state: [String: IdleReason] = [:]
        var notifications: [SessionNotification] = []

        for row in rows {
            // Attention is a liveIdle-only property; busy/cold rows carry no verdict.
            guard row.state == .liveIdle, let reason = row.idleReason else { continue }
            state[row.id] = reason
            if previous[row.id] != reason {
                notifications.append(SessionNotification(
                    sessionId: row.sessionId, agent: row.agent, reason: reason,
                    label: row.label, project: row.project, cwd: row.cwd,
                    summary: row.attentionSummary))
            }
        }
        return (notifications, state)
    }
}
