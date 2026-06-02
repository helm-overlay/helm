import Foundation

/// One notification to post: a session that just crossed into an attention state.
public struct SessionNotification: Equatable {
    public let sessionId: String
    public let agent: AgentKind
    public let reason: IdleReason     // .needsInput (blocked on you) or .needsReview (done)
    public let label: String
    public let project: String
    public let cwd: String
    public let pid: Int32?            // live process, for the "is its terminal focused?" check
    public let summary: String?       // the Stop-hook one-liner, when present

    public init(sessionId: String, agent: AgentKind, reason: IdleReason,
                label: String, project: String, cwd: String, pid: Int32?, summary: String?) {
        self.sessionId = sessionId; self.agent = agent; self.reason = reason
        self.label = label; self.project = project; self.cwd = cwd
        self.pid = pid; self.summary = summary
    }

    /// Stable per-session id so a later state for the same session replaces its banner
    /// rather than stacking a second one — and so a delivered banner can be cleared by id.
    public var notificationId: String { "\(agent.rawValue):\(sessionId)" }
}

/// The outcome of one reconcile: what to post, what verdict map to carry forward, and which
/// already-delivered banners to clear (sessions that left attention since last time).
public struct NotificationPlan: Equatable {
    public let notifications: [SessionNotification]
    public let state: [String: IdleReason]
    public let cleared: [String]      // notificationIds whose sessions no longer want attention
}

/// Pure transition detector: given the previously-seen attention verdict per session and
/// the current rows, decide which sessions just *entered* (or changed) an attention state
/// (→ notify) and which *left* it (→ clear their banner). Filesystem-free and unit-tested.
///
/// A notification fires when a session's attention verdict differs from what we last saw —
/// so a fresh `needsReview`/`needsInput`, or a flip between the two, notifies once; a
/// session that stays in the same verdict across polls does not re-notify. A session that
/// leaves attention (responded → busy, or gone cold/closed) is dropped from the map — it's
/// reported in `cleared` so its stale banner is removed, and a later re-entry notifies again.
public enum NotificationPlanner {
    /// - Parameters:
    ///   - previous: the verdict map returned by the prior call (empty on first run).
    ///   - rows: the current merged session list.
    public static func plan(previous: [String: IdleReason], rows: [ChatSession]) -> NotificationPlan {
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
                    pid: row.pid, summary: row.attentionSummary))
            }
        }
        // Anything we were tracking that no longer wants attention → clear its banner.
        let cleared = previous.keys.filter { state[$0] == nil }.sorted()
        return NotificationPlan(notifications: notifications, state: state, cleared: cleared)
    }
}
