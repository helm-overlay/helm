import Foundation

/// Reads pull requests by shelling out to `gh` (decision in `ATTENTION_FEED.md`): no
/// API/auth layer — gh resolves auth, account, and host. A single `gh api graphql` call
/// fetches both buckets — review-requested-of-me and my own PRs, the latter with review
/// decision + CI rollup — in one round-trip, so summon stays fast (the earlier per-PR
/// enrichment meant N+2 sequential calls). Tolerates an empty result when gh is missing or
/// offline; the `gh` invocation is injected (`runGh`) so decode + mapping is unit-tested
/// against fixture JSON without the network.
public struct PRSource: AttentionSource {
    /// Runs `gh <args>` and returns stdout, or empty Data on any failure (missing gh,
    /// nonzero exit, offline). Never throws — a dead `gh` degrades the feed to sessions-only.
    public typealias Runner = ([String]) -> Data

    let runGh: Runner
    /// Cap per bucket so a prolific account can't stall summon.
    let limit: Int
    /// A PR untouched (no `updatedAt` change) for longer than this drops out of the feed —
    /// the feed is for active PRs, so this is the "last modified within" visibility window.
    let staleAfter: TimeInterval
    /// How far before the cutoff a still-promoted PR is flagged "expiring" by the view.
    let expiringWithin: TimeInterval
    /// Clock, evaluated per call so a long-lived source stays current. Injected for tests.
    let now: () -> Date

    public init(limit: Int = 50,
                staleAfter: TimeInterval = 7 * 24 * 3600,
                expiringWithin: TimeInterval = 24 * 3600,
                now: @escaping () -> Date = { Date() },
                runGh: @escaping Runner = PRSource.shellOut) {
        self.limit = limit
        self.staleAfter = staleAfter
        self.expiringWithin = expiringWithin
        self.now = now
        self.runGh = runGh
    }

    // MARK: AttentionSource

    public var id: String { "prs" }
    public var title: String { "PULL REQUESTS" }
    /// Network-bound: poll slowly. A fresh fetch also runs on every summon.
    public var refreshPolicy: RefreshPolicy { .interval(15) }

    public func allItems() async -> [any AttentionItem] { fetchAll() }

    /// Every active PR reaches the feed: any PR last touched within `staleAfter` whose reason
    /// wants attention (all non-draft PRs do — they read out their live state). Older PRs and
    /// drafts are inventory-only.
    public func promotes(_ item: any AttentionItem) -> Bool {
        item.reason.wantsAttention && age(item) <= staleAfter
    }

    /// A promoted PR in its final `expiringWithin` before the staleness cutoff — about to drop
    /// off the feed, so the view flags it.
    public func expiringSoon(_ item: any AttentionItem) -> Bool {
        item.reason.wantsAttention && age(item) > staleAfter - expiringWithin && age(item) <= staleAfter
    }

    /// Time since the PR was last touched (its `updatedAt`).
    private func age(_ item: any AttentionItem) -> TimeInterval {
        now().timeIntervalSince(item.lastActive)
    }

    // MARK: Fetch

    /// Every PR for the PR view, deduped by id, ordered loudest-first then newest. One
    /// `gh api graphql` round-trip; call off the main thread.
    public func fetchAll() -> [PullRequest] {
        let data = runGh(["api", "graphql", "-f", "query=\(Self.graphQLQuery(limit: limit))"])
        guard let resp = Self.decode(GHGraphQL.self, from: data) else { return [] }

        let review = resp.data.review.nodes.map {
            $0.pullRequest(isMine: false, reviewRequestedFromMe: true)
        }
        let mine = resp.data.mine.nodes.map {
            $0.pullRequest(isMine: true, reviewRequestedFromMe: false)
        }
        // A PR can't be both authored-by and review-requested-of me; dedup defensively.
        var byID: [String: PullRequest] = [:]
        for pr in review + mine where byID[pr.id] == nil { byID[pr.id] = pr }
        return byID.values.sorted(by: AttentionFeed.precedes)
    }

    public static func matches(_ pr: PullRequest, query q: String) -> Bool {
        guard !q.isEmpty else { return true }
        return pr.repo.lowercased().contains(q)
            || pr.titleText.lowercased().contains(q)
            || "\(pr.number)".contains(q)
    }

    // MARK: GraphQL

    /// `review` carries only metadata (the reason is "you were asked"); `mine` additionally
    /// pulls `reviewDecision` and the head commit's `statusCheckRollup.state` so own-PR rows
    /// derive CI-failed / changes-requested / ready without a follow-up call.
    static func graphQLQuery(limit: Int) -> String {
        """
        query {
          review: search(query: "is:open is:pr user-review-requested:@me", type: ISSUE, first: \(limit)) {
            nodes { ... on PullRequest {
              number title url isDraft updatedAt repository { nameWithOwner }
            } }
          }
          mine: search(query: "is:open is:pr author:@me", type: ISSUE, first: \(limit)) {
            nodes { ... on PullRequest {
              number title url isDraft updatedAt repository { nameWithOwner }
              reviewDecision
              commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
            } }
          }
        }
        """
    }

    // MARK: Decode

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        guard !data.isEmpty else { return nil }
        return try? decoder.decode(type, from: data)
    }

    /// Default runner: `gh <args>`, stdout drained before wait to avoid a full-pipe deadlock.
    /// PATH is widened to the usual tool locations because a GUI launch (`open`) inherits only
    /// launchd's minimal PATH, which omits Homebrew — without this `gh` isn't found and the
    /// whole PR section silently vanishes.
    public static func shellOut(_ args: [String]) -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["gh"] + args
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? ""]).joined(separator: ":")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()   // discard
        do {
            try p.run()
        } catch {
            return Data()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : Data()
    }
}

// MARK: GraphQL DTOs

struct GHGraphQL: Decodable {
    let data: Payload
    struct Payload: Decodable {
        let review: Bucket
        let mine: Bucket
    }
    struct Bucket: Decodable { let nodes: [Node] }

    struct Node: Decodable {
        let number: Int
        let title: String
        let url: String
        let isDraft: Bool
        let updatedAt: Date
        let repository: Repo
        let reviewDecision: String?       // mine bucket only
        let commits: Commits?             // mine bucket only

        struct Repo: Decodable { let nameWithOwner: String }
        struct Commits: Decodable {
            let nodes: [CommitNode]
            struct CommitNode: Decodable { let commit: Commit }
            struct Commit: Decodable { let statusCheckRollup: Rollup? }
            struct Rollup: Decodable { let state: String? }
        }

        var ciState: PRCIState {
            PRCIState.from(rollupState: commits?.nodes.first?.commit.statusCheckRollup?.state)
        }

        func pullRequest(isMine: Bool, reviewRequestedFromMe: Bool) -> PullRequest {
            PullRequest(repo: repository.nameWithOwner, number: number, titleText: title, url: url,
                        isMine: isMine, reviewRequestedFromMe: reviewRequestedFromMe, isDraft: isDraft,
                        reviewState: PRReviewState.from(reviewDecision: reviewDecision),
                        ciState: ciState, updatedAt: updatedAt)
        }
    }
}
