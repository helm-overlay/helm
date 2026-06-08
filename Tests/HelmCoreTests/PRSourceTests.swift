import XCTest
@testable import HelmCore

final class PRSourceTests: XCTestCase {
    private let nowDate = Date(timeIntervalSince1970: 1_000_000_000)

    /// Default 7d staleness / 1d expiring window, with a fixed clock.
    private func source() -> PRSource { PRSource(now: { self.nowDate }) }

    /// A review-requested PR (promotes by reason) last touched `ageDays` ago.
    private func pr(ageDays: Double) -> PullRequest {
        PullRequest(repo: "org/api", number: 1, titleText: "t", url: "https://x/1",
                    isMine: false, reviewRequestedFromMe: true, isDraft: false,
                    reviewState: .none, ciState: .none,
                    updatedAt: nowDate.addingTimeInterval(-ageDays * 86_400))
    }

    func testFreshPRPromotesAndIsNotExpiring() {
        let s = source(), p = pr(ageDays: 3)
        XCTAssertTrue(s.promotes(p))
        XCTAssertFalse(s.expiringSoon(p))
    }

    func testPRInFinalDayPromotesAndIsFlaggedExpiring() {
        let s = source(), p = pr(ageDays: 6.5)
        XCTAssertTrue(s.promotes(p))
        XCTAssertTrue(s.expiringSoon(p))
    }

    func testStalePRDropsFromFeedAndIsNotExpiring() {
        let s = source(), p = pr(ageDays: 8)
        XCTAssertFalse(s.promotes(p))          // past the 7d cutoff → hidden (search-only)
        XCTAssertFalse(s.expiringSoon(p))      // already gone, no longer "about to expire"
    }
}
