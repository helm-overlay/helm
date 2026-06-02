import XCTest
@testable import HelmCore

/// A non-session AttentionItem, standing in for a future PullRequest, so these tests prove
/// the feed orders by the contract — not by anything session-specific.
private struct MockItem: AttentionItem {
    let id: String
    let reason: AttentionReason
    let lastActive: Date
    var badge: AttentionBadge { .pullRequest }
    var title: String { id }
    var subtitle: String? { nil }
    var primaryAction: AttentionAction { .openURL("https://x/\(id)") }
}

private struct MockSource: AttentionSource {
    let attention: [any AttentionItem]
    let inv: [any AttentionItem]
    func attentionItems() async -> [any AttentionItem] { attention }
    func inventory(matching query: String) async -> [any AttentionItem] { inv }
}

final class AttentionFeedTests: XCTestCase {

    private func at(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }
    private func mock(_ id: String, _ r: AttentionReason, _ t: TimeInterval) -> MockItem {
        MockItem(id: id, reason: r, lastActive: at(t))
    }
    private func idleSession(_ id: String, _ reason: IdleReason?, _ t: TimeInterval) -> ChatSession {
        ChatSession(sessionId: id, cwd: "", project: "p", label: id, state: .liveIdle,
                    kind: "interactive", pid: 1, lastActive: at(t), idleReason: reason)
    }

    func testOrderFiltersNonAttentionAndSortsRankThenRecency() {
        let items: [any AttentionItem] = [
            mock("cold", .none, 500),                 // dropped (rank 3)
            mock("busy", .live, 600),                 // dropped (rank 2)
            mock("ci", .prCiFailed, 100),             // rank 0, older
            mock("ask", .needsInput, 200),            // rank 0, newer
            mock("merge", .prMergeable, 400),         // rank 1, newer
            mock("review", .needsReview, 300),        // rank 1, older
        ]
        let ordered = AttentionFeed.order(items)
        XCTAssertEqual(ordered.map(\.id), ["ask", "ci", "merge", "review"])
    }

    func testOrderInterleavesSessionsAndPRsByUrgency() {
        let items: [any AttentionItem] = [
            idleSession("sess-review", .needsReview, 900),   // rank 1
            mock("pr-changes", .prChangesRequested, 100),    // rank 0
            idleSession("sess-input", .needsInput, 50),      // rank 0, older than the PR
        ]
        // rank-0 rows lead (PR newer than the session); rank-1 session trails. MockItem.id is
        // the raw string; ChatSession.id is "agent:sessionId".
        XCTAssertEqual(AttentionFeed.order(items).map(\.id),
                       ["pr-changes", "claude:sess-input", "claude:sess-review"])
    }

    func testNextWrapsAndDefaultsToFirst() {
        let items: [any AttentionItem] = [
            mock("a", .needsInput, 300),
            mock("b", .prCiFailed, 200),
            mock("c", .needsReview, 100),
        ]   // order: a, b (both rank 0, by recency), then c
        XCTAssertEqual(AttentionFeed.next(in: items, after: nil)?.id, "a")
        XCTAssertEqual(AttentionFeed.next(in: items, after: "a")?.id, "b")
        XCTAssertEqual(AttentionFeed.next(in: items, after: "c")?.id, "a")   // wrap
        XCTAssertEqual(AttentionFeed.next(in: items, after: "ghost")?.id, "a") // unknown → first
    }

    func testNextNilWhenNothingWantsAttention() {
        let items: [any AttentionItem] = [mock("x", .live, 1), mock("y", .none, 2)]
        XCTAssertNil(AttentionFeed.next(in: items, after: nil))
    }

    func testFeedMergesSourcesAndOrders() async {
        let sessions = MockSource(attention: [mock("s1", .needsReview, 100)], inv: [])
        let prs = MockSource(attention: [mock("p1", .prChangesRequested, 50)], inv: [])
        let feed = AttentionFeed([sessions, prs])
        let items = await feed.items()
        XCTAssertEqual(items.map(\.id), ["p1", "s1"])   // rank 0 (PR) before rank 1 (session)
    }

    func testSearchConcatenatesInventoryAcrossSources() async {
        let a = MockSource(attention: [], inv: [mock("a", .none, 1)])
        let b = MockSource(attention: [], inv: [mock("b", .none, 2)])
        let found = await AttentionFeed([a, b]).search("anything")
        XCTAssertEqual(Set(found.map(\.id)), ["a", "b"])
    }
}
