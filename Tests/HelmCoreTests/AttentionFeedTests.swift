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
    var context: String { "" }
    var subtitle: String? { nil }
    var primaryAction: AttentionAction { .openURL("https://x/\(id)") }
}

private struct MockSource: AttentionSource {
    let id: String
    let all: [any AttentionItem]
    var gate: (any AttentionItem) -> Bool = { $0.reason != .none }
    var title: String { id }
    var refreshPolicy: RefreshPolicy { .interval(1) }
    func allItems() async -> [any AttentionItem] { all }
    func promotes(_ item: any AttentionItem) -> Bool { gate(item) }
    // inventory(matching:) uses the default: allItems() filtered by each row's matches(_:).
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
        let sessions = MockSource(id: "sessions", all: [mock("s1", .needsReview, 100)])
        let prs = MockSource(id: "prs", all: [mock("p1", .prChangesRequested, 50)])
        let feed = AttentionFeed([sessions, prs])
        let items = await feed.items()
        XCTAssertEqual(items.map(\.id), ["p1", "s1"])   // rank 0 (PR) before rank 1 (session)
    }

    func testItemsHonorsPerSourcePromotesGate() async {
        // A source that refuses to promote even a loud (rank-0) row keeps it out of the feed,
        // proving the gate is applied independent of urgency ordering.
        let source = MockSource(
            id: "s",
            all: [mock("kept", .prCiFailed, 50), mock("gated", .needsInput, 100)],
            gate: { $0.id == "kept" })
        let feed = await AttentionFeed([source]).items()
        XCTAssertEqual(feed.map(\.id), ["kept"])
    }

    func testInventoryRowsHiddenAtRestButSurfacedOnSearch() async {
        // The resting=push / expansion=pull split: a `.none` (inventory-only) row never reaches
        // the feed, but search finds it across the source's full set.
        let source = MockSource(id: "s", all: [mock("cold", .none, 100), mock("loud", .needsInput, 50)])
        let feed = AttentionFeed([source])
        let resting = await feed.items()
        let searched = await feed.search("cold")
        XCTAssertEqual(resting.map(\.id), ["loud"])     // .none hidden at rest
        XCTAssertEqual(searched.map(\.id), ["cold"])    // surfaced on search
    }

    func testSearchMatchesAndConcatenatesAcrossSources() async {
        let a = MockSource(id: "a", all: [mock("apple", .none, 1), mock("kiwi", .none, 3)])
        let b = MockSource(id: "b", all: [mock("avocado", .none, 2)])
        let found = await AttentionFeed([a, b]).search("a")   // matches apple + avocado, not kiwi
        XCTAssertEqual(Set(found.map(\.id)), ["apple", "avocado"])
    }

    func testDefaultMatchesIsSubstringOverVisibleText() {
        let item = mock("Fix retry backoff", .needsInput, 0)   // MockItem.title == id
        XCTAssertTrue(item.matches("retry"))
        XCTAssertFalse(item.matches("zzz"))
        XCTAssertTrue(item.matches(""))   // empty query matches everything
    }
}
