import XCTest
@testable import HelmCore

final class PullRequestTests: XCTestCase {

    private func pr(mine: Bool = false, review reviewReq: Bool = false, draft: Bool = false,
                    _ rs: PRReviewState = .none, _ ci: PRCIState = .none) -> PullRequest {
        PullRequest(repo: "org/api", number: 7, titleText: "T", url: "https://x/7",
                    isMine: mine, reviewRequestedFromMe: reviewReq, isDraft: draft,
                    reviewState: rs, ciState: ci, updatedAt: Date(timeIntervalSince1970: 1))
    }

    // MARK: reason mapping

    func testReviewRequestedAlwaysWins() {
        XCTAssertEqual(pr(review: true).reason, .prReviewRequested)
        // even if it would otherwise look mergeable
        XCTAssertEqual(pr(mine: true, review: true, .approved, .success).reason, .prReviewRequested)
    }

    func testOwnPRReasonByStatus() {
        XCTAssertEqual(pr(mine: true, .reviewRequired, .failure).reason, .prCiFailed)   // red beats everything
        XCTAssertEqual(pr(mine: true, .changesRequested, .success).reason, .prChangesRequested)
        XCTAssertEqual(pr(mine: true, .approved, .success).reason, .prMergeable)
        XCTAssertEqual(pr(mine: true, .reviewRequired, .pending).reason, .none)         // nothing actionable yet
    }

    func testDraftAndOthersAreInventoryOnly() {
        XCTAssertEqual(pr(mine: true, draft: true, .approved, .success).reason, .none)
        XCTAssertEqual(pr(mine: false).reason, .none)
    }

    func testIdentityAndAction() {
        let p = pr()
        XCTAssertEqual(p.id, "pr:org/api#7")
        XCTAssertEqual(p.subtitle, "org/api#7")
        XCTAssertEqual(p.primaryAction, .openURL("https://x/7"))
        XCTAssertEqual(p.badge, .pullRequest)
    }

    // MARK: review-decision mapping

    func testReviewDecisionMapping() {
        XCTAssertEqual(PRReviewState.from(reviewDecision: "APPROVED"), .approved)
        XCTAssertEqual(PRReviewState.from(reviewDecision: "CHANGES_REQUESTED"), .changesRequested)
        XCTAssertEqual(PRReviewState.from(reviewDecision: "REVIEW_REQUIRED"), .reviewRequired)
        XCTAssertEqual(PRReviewState.from(reviewDecision: ""), .none)
        XCTAssertEqual(PRReviewState.from(reviewDecision: nil), .none)
    }

    // MARK: CI rollup-state mapping

    func testRollupStateMapping() {
        XCTAssertEqual(PRCIState.from(rollupState: "SUCCESS"), .success)
        XCTAssertEqual(PRCIState.from(rollupState: "FAILURE"), .failure)
        XCTAssertEqual(PRCIState.from(rollupState: "ERROR"), .failure)
        XCTAssertEqual(PRCIState.from(rollupState: "PENDING"), .pending)
        XCTAssertEqual(PRCIState.from(rollupState: "EXPECTED"), .pending)
        XCTAssertEqual(PRCIState.from(rollupState: nil), .none)   // PR with no checks
    }

    // MARK: GraphQL decode → fetchAll mapping (injected runner, no network)

    func testFetchAllDecodesGraphQLAndMapsBothBuckets() {
        let json = """
        {"data":{
          "review":{"nodes":[
            {"number":12,"title":"Fix login","url":"https://gh/org/web/pull/12",
             "isDraft":false,"updatedAt":"2026-06-01T10:00:00Z",
             "repository":{"nameWithOwner":"org/web"}}
          ]},
          "mine":{"nodes":[
            {"number":99,"title":"Retry backoff","url":"https://gh/org/api/pull/99",
             "isDraft":false,"updatedAt":"2026-06-02T10:00:00Z",
             "repository":{"nameWithOwner":"org/api"},"reviewDecision":"CHANGES_REQUESTED",
             "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}
          ]}
        }}
        """
        let prs = PRSource(runGh: { _ in Data(json.utf8) }).fetchAll()
        XCTAssertEqual(prs.count, 2)
        // changes-requested (rank 0) sorts before review-requested (rank 1)
        XCTAssertEqual(prs.map(\.id), ["pr:org/api#99", "pr:org/web#12"])
        XCTAssertEqual(prs[0].reason, .prChangesRequested)
        XCTAssertEqual(prs[1].reason, .prReviewRequested)
    }

    func testFetchAllMapsCIFailureFromRollup() {
        let json = """
        {"data":{"review":{"nodes":[]},"mine":{"nodes":[
          {"number":5,"title":"WIP","url":"https://gh/o/r/pull/5","isDraft":false,
           "updatedAt":"2026-06-02T10:00:00Z","repository":{"nameWithOwner":"o/r"},
           "reviewDecision":null,
           "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}}
        ]}}}
        """
        let prs = PRSource(runGh: { _ in Data(json.utf8) }).fetchAll()
        XCTAssertEqual(prs.first?.reason, .prCiFailed)
    }

    func testFetchAllEmptyWhenGhFails() {
        XCTAssertEqual(PRSource(runGh: { _ in Data() }).fetchAll().count, 0)
    }
}
