import Foundation

/// A pull request surfaced in the feed / PR view. Conforms to `AttentionItem` so it sits in
/// the same attention feed as sessions (see `ATTENTION_FEED.md`). Read via `gh` by `PRSource`.
public struct PullRequest: AttentionItem, Equatable {
    public let repo: String          // "org/api"
    public let number: Int
    public let titleText: String
    public let url: String
    public let isMine: Bool                 // authored by me
    public let reviewRequestedFromMe: Bool  // someone wants *my* review
    public let isDraft: Bool
    public let reviewState: PRReviewState
    public let ciState: PRCIState
    public let updatedAt: Date

    public init(repo: String, number: Int, titleText: String, url: String, isMine: Bool,
                reviewRequestedFromMe: Bool, isDraft: Bool, reviewState: PRReviewState,
                ciState: PRCIState, updatedAt: Date) {
        self.repo = repo; self.number = number; self.titleText = titleText; self.url = url
        self.isMine = isMine; self.reviewRequestedFromMe = reviewRequestedFromMe
        self.isDraft = isDraft; self.reviewState = reviewState; self.ciState = ciState
        self.updatedAt = updatedAt
    }

    public var id: String { "pr:\(repo)#\(number)" }
    public var badge: AttentionBadge { .pullRequest }
    public var title: String { titleText }
    public var subtitle: String? { "\(repo)#\(number)" }
    public var lastActive: Date { updatedAt }
    public var primaryAction: AttentionAction { .openURL(url) }

    /// A PR review request always wants you. Among your own PRs, a red check or a
    /// changes-requested review demands action; an approved+green one is ready to merge;
    /// anything else (incl. drafts) is inventory-only.
    public var reason: AttentionReason {
        if reviewRequestedFromMe { return .prReviewRequested }
        guard isMine, !isDraft else { return .none }
        if ciState == .failure                              { return .prCiFailed }
        if reviewState == .changesRequested                 { return .prChangesRequested }
        if reviewState == .approved && ciState == .success  { return .prMergeable }
        return .none
    }
}

public enum PRReviewState: String, Equatable {
    case approved, changesRequested, reviewRequired, none

    /// Maps gh's `reviewDecision` (APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED / "").
    public static func from(reviewDecision raw: String?) -> PRReviewState {
        switch raw?.uppercased() {
        case "APPROVED":          return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "REVIEW_REQUIRED":   return .reviewRequired
        default:                  return .none
        }
    }
}

public enum PRCIState: String, Equatable {
    case success, failure, pending, none

    /// Maps the GraphQL `statusCheckRollup.state` — GitHub's single rolled-up verdict over a
    /// PR's checks (nil when the PR has no checks at all).
    public static func from(rollupState raw: String?) -> PRCIState {
        switch raw?.uppercased() {
        case "SUCCESS":             return .success
        case "FAILURE", "ERROR":    return .failure
        case "PENDING", "EXPECTED": return .pending
        default:                    return .none
        }
    }
}
