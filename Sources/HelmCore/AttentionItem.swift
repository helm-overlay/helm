import Foundation

/// Why an item is demanding your attention — the load-bearing field of the feed. A title
/// says what an item is about; the reason says why it's in front of you. `rank` (lowest =
/// loudest) is the single scale every item type sorts on, so sessions and pull requests
/// interleave by urgency rather than living in separate regions.
public enum AttentionReason: Equatable {
    // sessions
    case needsInput            // waiting on a decision / permission / question
    case needsReview           // idle, finished — come look
    // pull requests
    case prChangesRequested    // your PR: a reviewer asked for changes
    case prCiFailed            // your PR: checks are red
    case prReviewRequested     // someone wants *your* review
    case prMergeable           // your PR: approved + green, ready to merge
    // baseline
    case live                  // busy session — nothing to do yet
    case none                  // cold / inventory-only

    /// Lowest wins. Action-required reasons share rank 0; come-look/act-soon share 1; a
    /// busy session is 2; everything else (cold, inventory) is 3. This is the generalization
    /// of the original session-only `attentionRank` across item types.
    public var rank: Int {
        switch self {
        case .needsInput, .prChangesRequested, .prCiFailed: return 0
        case .needsReview, .prReviewRequested, .prMergeable: return 1
        case .live:                                          return 2
        case .none:                                          return 3
        }
    }

    /// Short chip text rendered in the row.
    public var label: String {
        switch self {
        case .needsInput:         return "needs input"
        case .needsReview:        return "come look"
        case .prChangesRequested: return "changes requested"
        case .prCiFailed:         return "CI failed"
        case .prReviewRequested:  return "review requested"
        case .prMergeable:        return "ready to merge"
        case .live:               return "working"
        case .none:               return ""
        }
    }

    /// Feed membership: only action-required and come-look items earn a resting-state row.
    public var wantsAttention: Bool { rank <= 1 }
}

/// Type marker for the row's icon/badge. Lets the view distinguish a session from a PR
/// without branching on a concrete type.
public enum AttentionBadge: Equatable {
    case session(AgentKind)
    case pullRequest
}

/// What pressing Enter on a row does — owned by the item, so the dispatch path never
/// switches on the row's concrete type.
public enum AttentionAction: Equatable {
    case resumeSession(agent: AgentKind, sessionId: String, cwd: String)  // → terminal
    case openURL(String)                                                  // → browser
    case newChat(project: String, cwd: String)                            // placeholder rows
}

/// One row in the attention feed / inventory, regardless of source. Implemented today by
/// `ChatSession`; a `PullRequest` is the next conformer (see `ATTENTION_FEED.md`).
public protocol AttentionItem: Identifiable {
    var id: String { get }
    var badge: AttentionBadge { get }
    var title: String { get }
    /// The leading "where" column — a session's project, a PR's repo. Lets the row render
    /// its anchor without the view switching on concrete type.
    var context: String { get }
    var subtitle: String? { get }
    var reason: AttentionReason { get }
    var lastActive: Date { get }
    var primaryAction: AttentionAction { get }
    /// Whether this row matches a search query (assumed already lowercased + trimmed). Drives
    /// the launcher's inventory-on-search: at rest the feed shows only promoted rows, but a
    /// non-empty query searches the full inventory across every row — this one included.
    func matches(_ query: String) -> Bool
}

public extension AttentionItem {
    /// Default match: substring over the row's visible text (title, context, subtitle).
    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return title.lowercased().contains(query)
            || context.lowercased().contains(query)
            || (subtitle?.lowercased().contains(query) ?? false)
    }
}

extension ChatSession: AttentionItem {
    public var badge: AttentionBadge { .session(agent) }

    public var title: String { label }

    public var context: String { project }

    /// Fuzzy subsequence over label / project / branch / cwd — the same search the sessions
    /// list used, so inventory-on-search keeps that recall.
    public func matches(_ query: String) -> Bool { SessionStore.matches(self, query: query) }

    public var subtitle: String? {
        branch.map { "\(project) · \($0)" } ?? project
    }

    public var reason: AttentionReason {
        switch (state, idleReason) {
        case (.liveIdle, .needsInput): return .needsInput
        case (.liveIdle, _):           return .needsReview
        case (.liveBusy, _):           return .live
        case (.cold, _):               return .none
        }
    }

    public var primaryAction: AttentionAction {
        isPlaceholder
            ? .newChat(project: project, cwd: cwd)
            : .resumeSession(agent: agent, sessionId: sessionId, cwd: cwd)
    }
}
