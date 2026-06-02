# Attention feed — design sketch

Status: design, not built. Grounds the "resting view = attention feed, expansion = inventory"
direction (see the launcher pivot) and shows how PRs become a first-class row type next to
Claude/pi sessions **without** a revived multi-panel.

## The one idea

The resting view is not "live sessions." It's **"what needs me right now."** A live session
and a pull request are two *item types* in one feed, ranked on one scale and interleaved by
urgency. Everything else — cold chats, non-urgent PRs — lives in the search expansion.

```
┌─ search ──────────────────────────────────┐   resting  = attention (push)
│ Search 177 sessions…                        │   expanded = inventory  (pull)
├─ attention feed ───────────────────────────┤
│ ◐ helm   needs input   helm-init-claude  3m │  ← session, rank 0
│ ⇅ api    review req.    Fix retry backoff 1h│  ← PR,      rank 0
│ ● core   CI failed      Bump deps         2h│  ← PR,      rank 1
│ ◑ helm   come look      Panel sizing      4h│  ← session, rank 1
└─────────────────────────────────────────────┘
```

## What already exists (don't rebuild)

- `ChatSession` (`Models.swift`) carries `state` / `idleReason` and derives `needsInput` /
  `needsReview`.
- `SessionStore.attentionRank(_:) -> Int` — `0` needs-input, `1` needs-review, `2` busy,
  `3` cold. Lowest wins. Drives in-group sort **and** the `⌥⇧Space` jump.
- `SessionStore.nextAttentionSession(in:after:)` — the jump hotkey, filters `rank <= 1`.
- `SessionBackend` — per-agent (`claude`, `pi`): `readLive` / `readHistory` /
  `classifyTail` / `stateFileReason`. **Filesystem-bound, session-shaped.**

The rank scale and the jump are exactly the backbone PRs need. PRs just map onto it.

## The contract: `AttentionItem`

What the feed and the row view need from *any* item, regardless of type. This is the seam
that lets a PR and a session share one row.

```swift
/// Why an item is in the feed — the load-bearing field. A title says what an item is
/// about; the reason says why it's demanding you. `rank` (lowest = loudest) generalizes
/// today's `attentionRank` across types so sessions and PRs interleave on one scale.
public enum AttentionReason: Equatable {
    // sessions
    case needsInput            // waiting on a decision / permission / question
    case needsReview           // idle, finished — come look
    // pull requests
    case prChangesRequested    // your PR: reviewer asked for changes
    case prCiFailed            // your PR: checks red
    case prReviewRequested     // someone wants *your* review
    case prMergeable           // your PR: approved + green, ready to merge
    // baseline
    case live                  // busy session, nothing to do yet
    case none                  // cold / inventory-only

    public var rank: Int {
        switch self {
        case .needsInput, .prChangesRequested, .prCiFailed: return 0  // action required
        case .needsReview, .prReviewRequested, .prMergeable: return 1  // come look / act soon
        case .live:                                          return 2
        case .none:                                          return 3
        }
    }

    /// Short chip text rendered in the row ("needs input", "review req.", "CI failed").
    public var label: String { … }
}

/// What the feed sorts and the row renders — implemented by ChatSession and PullRequest.
public protocol AttentionItem: Identifiable {
    var id: String { get }
    var badge: AttentionBadge { get }     // type marker: .session(AgentKind) | .pullRequest
    var title: String { get }             // label (session) / PR title
    var subtitle: String? { get }         // project+branch / repo#number
    var reason: AttentionReason { get }
    var lastActive: Date { get }          // recency tiebreak within a rank
    var primaryAction: AttentionAction { get }   // Enter behavior — item owns it
}

public enum AttentionBadge: Equatable { case session(AgentKind), pullRequest }

/// The row owns what Enter does — the view never branches on type.
public enum AttentionAction: Equatable {
    case resumeSession(agent: AgentKind, sessionId: String, cwd: String)  // → terminal
    case openURL(String)                                                  // → browser (PR)
    case newChat(project: String, cwd: String)                            // placeholder rows
}
```

`attentionRank` collapses to `item.reason.rank`, so `nextAttentionSession` generalizes to
`nextAttentionItem(in:after:)` over `rank <= 1` with zero behavior change for sessions.

### `ChatSession` conforms — derivation, no new storage

```swift
extension ChatSession: AttentionItem {
    public var badge: AttentionBadge { .session(agent) }
    public var subtitle: String? { branch.map { "\(project) · \($0)" } ?? project }
    public var reason: AttentionReason {
        switch (state, idleReason) {
        case (.liveIdle, .needsInput): return .needsInput
        case (.liveIdle, _):           return .needsReview
        case (.liveBusy, _):           return .live
        case (.cold, _):               return .none
        }
    }
    public var primaryAction: AttentionAction {
        isPlaceholder ? .newChat(project: project, cwd: cwd)
                      : .resumeSession(agent: agent, sessionId: sessionId, cwd: cwd)
    }
}
```

## The PR side: a *sibling* source, not a `SessionBackend`

This is the key architectural call. `SessionBackend` is session-shaped (live registry +
transcript history + idle classification) and **filesystem-bound**. PRs have none of that —
they come from the network and have their own state machine. Forcing them into
`SessionBackend` would mean stubbing four methods that don't apply.

Instead, introduce one level up: an `AttentionSource` that *produces items*. `SessionStore`
becomes one source (wrapping its session backends); a `PRSource` is a second.

```swift
/// Anything that contributes rows to the attention feed / inventory. Async because some
/// sources (PRs) are network-bound, unlike the synchronous filesystem session reads.
public protocol AttentionSource {
    /// Feed candidates — the source decides what's attention-worthy (see gating below).
    func attentionItems() async -> [any AttentionItem]
    /// Full inventory for the search expansion (all PRs / all sessions).
    func inventory(matching query: String) async -> [any AttentionItem]
}
```

```swift
public struct PullRequest: AttentionItem {
    public let repo: String          // "org/api"
    public let number: Int
    public let titleText: String
    public let url: String
    public let headBranch: String
    public let isMine: Bool
    public let reviewState: ReviewState   // approved | changesRequested | pending
    public let ciState: CIState           // success | failure | pending | none
    public let reviewRequestedFromMe: Bool
    public let updatedAt: Date

    public var id: String { "pr:\(repo)#\(number)" }
    public var badge: AttentionBadge { .pullRequest }
    public var title: String { titleText }
    public var subtitle: String? { "\(repo)#\(number)" }
    public var lastActive: Date { updatedAt }
    public var primaryAction: AttentionAction { .openURL(url) }

    public var reason: AttentionReason {
        if reviewRequestedFromMe { return .prReviewRequested }
        guard isMine else { return .none }
        if ciState == .failure                       { return .prCiFailed }
        if reviewState == .changesRequested          { return .prChangesRequested }
        if reviewState == .approved && ciState == .success { return .prMergeable }
        return .none
    }
}
```

```swift
/// Reads PRs by shelling out to `gh` and decoding its --json output. No API/auth layer:
/// gh resolves auth, active account, and remote. Network-bound → refresh-on-summon +
/// cache last result; degrade to sessions-only if gh errors. Never block the overlay.
struct PRSource: AttentionSource {
    // attentionItems(): two calls, mapped to [PullRequest], filtered to reason.rank <= 1.
    //
    //   gh search prs --review-requested=@me --state=open \
    //     --json repository,number,title,url,updatedAt              → .prReviewRequested
    //
    //   gh pr list --author=@me --state=open --json \
    //     number,title,url,headRefName,reviewDecision,statusCheckRollup,mergeable,updatedAt
    //                                                               → CI/changes/mergeable
    //
    // reviewDecision (APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED) + statusCheckRollup
    // map straight onto PullRequest.reason. inventory(matching:): all PRs, matched on
    // repo/branch/title (do this after content search lands).
}
```

> Decision (locked): shell out to the `gh` binary, decode `--json`. Not `gh api graphql` —
> revisit only if summon latency from the two calls becomes a problem.
>
> Open: PR **scope** — all-repos (`@me` everywhere, simplest) vs scoped to the repos behind
> configured workspace folders (fewer calls, matches project grouping). Start all-repos,
> tighten if noisy.

## Gating — the discipline that keeps the feed sharp

A feed that lets every open PR in just rebuilds the cold-chat scanning problem with PRs.
Resting-state PRs are a **short allowlist** — exactly the `reason != .none` cases above.
Everything else is inventory, reachable only by expanding/searching. Same rule sessions
already follow: only `rank <= 1` rows are "attention"; busy/cold wait below.

## Two surfaces, both types on both sides

| Surface | Sessions | PRs |
| --- | --- | --- |
| **Resting (attention feed)** | needs-input, needs-review | review-requested, changes-requested, CI-failed, mergeable |
| **Expansion (inventory + search)** | all sessions incl. cold, **content search** over `.jsonl` | all PRs, matched on repo/branch/title |

Feed = `sources.flatMap(attentionItems)` → sort by `reason.rank` then `lastActive`.
Search = `sources.flatMap { inventory(matching:) }` → each source matches what it can
(session bodies vs PR metadata) → merged results, same row contract, preview pane on the side.

## Seams to touch vs defer

Touch:
- `AttentionItem.swift` — protocol, `AttentionReason`, `AttentionBadge`, `AttentionAction`.
- `Models.swift` — `ChatSession: AttentionItem` (pure derivation, no stored fields).
- `SessionStore` — `attentionRank` → delegates to `reason.rank`; `nextAttentionSession` →
  generalized `nextAttentionItem`. Wrap as an `AttentionSource`.
- Feed view — render heterogeneous rows off the contract (badge + reason chip + Enter action).

Defer (sketch the seam, don't build the network layer yet):
- `gh` integration details, auth, PR polling cadence + cache invalidation.
- PR participation in search (title/repo/branch is easy; do it after content search lands).
- Multi-account / multi-remote PR scoping.

## Open questions

1. Exact cross-type rank order — should `prChangesRequested` really tie `needsInput` at 0,
   or sit just under it? Proposed default ties them; trivially tunable in `reason.rank`.
2. Busy sessions (`.live`, rank 2) in the resting feed — show dimmed, or hide until they
   flip to needs-input/review? Leaning: show a compact count, not full rows.
3. PR refresh cadence — fixed interval vs refresh-on-summon. Summon-triggered is simplest
   and matches how the overlay is used.
