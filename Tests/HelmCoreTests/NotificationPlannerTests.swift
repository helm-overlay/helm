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
        let plan = NotificationPlanner.plan(previous: [:], rows: rows)

        XCTAssertEqual(Set(plan.notifications.map(\.sessionId)), ["A", "B"])  // only attention rows
        XCTAssertEqual(plan.state, ["claude:A": .needsReview, "claude:B": .needsInput])
        XCTAssertTrue(plan.cleared.isEmpty)
    }

    func testNoRefireWhenVerdictUnchanged() {
        let rows = [live("A", .needsReview)]
        let plan = NotificationPlanner.plan(previous: ["claude:A": .needsReview], rows: rows)
        XCTAssertTrue(plan.notifications.isEmpty)
        XCTAssertTrue(plan.cleared.isEmpty)
    }

    func testVerdictFlipRefires() {
        let rows = [live("A", .needsInput)]
        let plan = NotificationPlanner.plan(previous: ["claude:A": .needsReview], rows: rows)
        XCTAssertEqual(plan.notifications.map(\.reason), [.needsInput])
        XCTAssertEqual(plan.state["claude:A"], .needsInput)
        XCTAssertTrue(plan.cleared.isEmpty)   // still in attention → not cleared
    }

    func testLeavingAttentionIsClearedAndReentryRefires() {
        // Was done; now back to work → drops out of the map and is reported for banner clear.
        let back = NotificationPlanner.plan(previous: ["claude:A": .needsReview], rows: [live("A", nil)])
        XCTAssertTrue(back.state.isEmpty)
        XCTAssertEqual(back.cleared, ["claude:A"])

        // Finishes again → fires again, because the map no longer remembers it.
        let again = NotificationPlanner.plan(previous: back.state, rows: [live("A", .needsReview)])
        XCTAssertEqual(again.notifications.map(\.sessionId), ["A"])
    }

    func testGoneSessionIsCleared() {
        // A tracked session that vanished entirely (ended / process gone) is cleared.
        let plan = NotificationPlanner.plan(previous: ["claude:A": .needsInput], rows: [])
        XCTAssertEqual(plan.cleared, ["claude:A"])
        XCTAssertTrue(plan.notifications.isEmpty)
    }

    func testNotificationCarriesFieldsForDisplayAndFocusCheck() {
        let rows = [live("A", .needsReview, summary: "Tests pass", label: "auth", project: "helm")]
        let n = NotificationPlanner.plan(previous: [:], rows: rows).notifications.first
        XCTAssertEqual(n?.summary, "Tests pass")
        XCTAssertEqual(n?.label, "auth")
        XCTAssertEqual(n?.project, "helm")
        XCTAssertEqual(n?.pid, 1)                   // carried for the terminal-focus check
        XCTAssertEqual(n?.notificationId, "claude:A")
    }
}
