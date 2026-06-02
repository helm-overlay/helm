import XCTest
@testable import HelmCore

final class NotificationPlannerTests: XCTestCase {

    private func live(_ id: String, _ reason: IdleReason?, summary: String? = nil,
                      label: String = "L", project: String = "p") -> ChatSession {
        ChatSession(sessionId: id, cwd: "/w", project: project, label: label,
                    state: reason == nil ? .liveBusy : .liveIdle, kind: "interactive",
                    pid: 1, lastActive: .distantPast, idleReason: reason,
                    attentionSummary: summary)
    }

    private func cold(_ id: String) -> ChatSession {
        ChatSession(sessionId: id, cwd: "/w", project: "p", label: "L",
                    state: .cold, kind: nil, pid: nil, lastActive: .distantPast)
    }

    func testFreshAttentionRowsFire() {
        let rows = [live("A", .needsReview), live("B", .needsInput), live("C", nil), cold("D")]
        let (notifs, state) = NotificationPlanner.plan(previous: [:], rows: rows)

        XCTAssertEqual(Set(notifs.map(\.sessionId)), ["A", "B"])           // only the attention rows
        XCTAssertEqual(state, ["claude:A": .needsReview, "claude:B": .needsInput])
    }

    func testNoRefireWhenVerdictUnchanged() {
        let rows = [live("A", .needsReview)]
        let (notifs, _) = NotificationPlanner.plan(previous: ["claude:A": .needsReview], rows: rows)
        XCTAssertTrue(notifs.isEmpty)
    }

    func testVerdictFlipRefires() {
        let rows = [live("A", .needsInput)]
        let (notifs, state) = NotificationPlanner.plan(previous: ["claude:A": .needsReview], rows: rows)
        XCTAssertEqual(notifs.map(\.reason), [.needsInput])
        XCTAssertEqual(state["claude:A"], .needsInput)
    }

    func testLeavingAttentionClearsStateSoReentryRefires() {
        // Was done; now back to work → drops out of the map.
        let (_, afterBusy) = NotificationPlanner.plan(previous: ["claude:A": .needsReview],
                                                      rows: [live("A", nil)])
        XCTAssertTrue(afterBusy.isEmpty)

        // Finishes again → fires again, because the map no longer remembers it.
        let (notifs, _) = NotificationPlanner.plan(previous: afterBusy, rows: [live("A", .needsReview)])
        XCTAssertEqual(notifs.map(\.sessionId), ["A"])
    }

    func testNotificationCarriesSummaryAndDisplayFields() {
        let rows = [live("A", .needsReview, summary: "Tests pass", label: "auth", project: "helm")]
        let n = NotificationPlanner.plan(previous: [:], rows: rows).notifications.first
        XCTAssertEqual(n?.summary, "Tests pass")
        XCTAssertEqual(n?.label, "auth")
        XCTAssertEqual(n?.project, "helm")
        XCTAssertEqual(n?.notificationId, "claude:A")
    }
}
