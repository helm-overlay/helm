import XCTest
@testable import HelmCore

final class SessionStoreTests: XCTestCase {
    let home = "/Users/me"

    // MARK: grouping

    func testProjectFromCwd() {
        XCTAssertEqual(SessionStore.project(forCwd: "/Users/me/projects/helm/app", home: home), "helm")
        XCTAssertEqual(SessionStore.project(forCwd: "/Users/me/projects/helm", home: home), "helm")
        XCTAssertEqual(SessionStore.project(forCwd: "/Users/me/worktrees/mobile/x", home: home), "Other")
        XCTAssertEqual(SessionStore.project(forCwd: "/Users/me/Desktop/local_dev", home: home), "Other")
        XCTAssertEqual(SessionStore.project(forCwd: "", home: home), "Other")
    }

    // MARK: hook-induced filtering ("my kind of threads only")

    func testUserThreadVsAutomation() {
        XCTAssertTrue(SessionStore.isUserThread(entrypoint: "cli"))
        XCTAssertTrue(SessionStore.isUserThread(entrypoint: nil))     // old transcripts: keep
        XCTAssertFalse(SessionStore.isUserThread(entrypoint: "sdk-py"))   // security-guidance hook
        XCTAssertFalse(SessionStore.isUserThread(entrypoint: "sdk-ts"))
    }

    func testSubagentTranscriptDetection() {
        XCTAssertTrue(SessionStore.isSubagentTranscript(filename: "agent-afcb69a539763eff5.jsonl"))
        XCTAssertFalse(SessionStore.isSubagentTranscript(filename: "3f27ba72-739d-41a8-8f47.jsonl"))
    }

    // MARK: age labels (<15m / <30m / <1h / Nh, floored)

    func testAgeLabelBuckets() {
        XCTAssertEqual(SessionStore.ageLabel(-100),        "<15m")   // future mtime → clamp
        XCTAssertEqual(SessionStore.ageLabel(0),           "<15m")
        XCTAssertEqual(SessionStore.ageLabel(14 * 60),     "<15m")
        XCTAssertEqual(SessionStore.ageLabel(15 * 60),     "<30m")
        XCTAssertEqual(SessionStore.ageLabel(29 * 60),     "<30m")
        XCTAssertEqual(SessionStore.ageLabel(30 * 60),     "<1h")
        XCTAssertEqual(SessionStore.ageLabel(59 * 60),     "<1h")
        XCTAssertEqual(SessionStore.ageLabel(60 * 60),     "1h")
        XCTAssertEqual(SessionStore.ageLabel((2 * 60 + 59) * 60), "2h")   // 2h59m → 2h
        XCTAssertEqual(SessionStore.ageLabel(23 * 3600),   "23h")
        XCTAssertEqual(SessionStore.ageLabel(24 * 3600),   "1d")
        XCTAssertEqual(SessionStore.ageLabel(47 * 3600),   "1d")          // 1d23h → 1d
        XCTAssertEqual(SessionStore.ageLabel(6 * 86400),   "6d")
        XCTAssertEqual(SessionStore.ageLabel(7 * 86400),   "1w")
        XCTAssertEqual(SessionStore.ageLabel(13 * 86400),  "1w")          // 1w6d → 1w
        XCTAssertEqual(SessionStore.ageLabel(14 * 86400),  "2w")
    }

    func testIsOlderThan() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let week: TimeInterval = 7 * 86400
        XCTAssertFalse(SessionStore.isOlderThan(week, lastActive: now.addingTimeInterval(-3 * 86400), now: now))
        XCTAssertTrue(SessionStore.isOlderThan(week, lastActive: now.addingTimeInterval(-8 * 86400), now: now))
        XCTAssertFalse(SessionStore.isOlderThan(0, lastActive: .distantPast, now: now))   // disabled
    }

    // MARK: state derivation

    func testStateDerivation() {
        XCTAssertEqual(SessionStore.state(forStatus: "busy", isLive: true), .liveBusy)
        XCTAssertEqual(SessionStore.state(forStatus: "idle", isLive: true), .liveIdle)
        XCTAssertEqual(SessionStore.state(forStatus: nil, isLive: true), .liveIdle)
        XCTAssertEqual(SessionStore.state(forStatus: "busy", isLive: false), .cold)
    }

    // MARK: join

    func testMergeJoinsOnSessionId() {
        let store = SessionStore(home: home)
        let live = [LiveRecord(pid: 100, sessionId: "A", kind: "interactive", status: "busy", name: "live one")]
        let history = [
            HistoryRecord(sessionId: "A", cwd: "/Users/me/projects/helm", gitBranch: "main", aiTitle: "old title", lastActive: Date(timeIntervalSince1970: 10)),
            HistoryRecord(sessionId: "B", cwd: "/Users/me/projects/other", gitBranch: "feat", aiTitle: nil, lastActive: Date(timeIntervalSince1970: 20)),
        ]
        let merged = store.merge(live: live, history: history)
        let a = merged.first { $0.sessionId == "A" }!
        let b = merged.first { $0.sessionId == "B" }!

        XCTAssertEqual(a.state, .liveBusy)
        XCTAssertEqual(a.label, "live one")          // live name wins over aiTitle
        XCTAssertEqual(a.project, "helm")
        XCTAssertEqual(a.pid, 100)

        XCTAssertEqual(b.state, .cold)
        XCTAssertEqual(b.label, "feat")              // falls back to gitBranch (no aiTitle)
        XCTAssertNil(b.pid)
    }

    func testLabelFallbackChain() {
        let store = SessionStore(home: home)
        let h = HistoryRecord(sessionId: "X", cwd: "/Users/me/projects/p/repo", gitBranch: nil, aiTitle: nil, lastActive: .distantPast)
        let merged = store.merge(live: [], history: [h])
        XCTAssertEqual(merged[0].label, "repo")      // last resort: cwd basename
    }

    func testLiveOnlySessionIncluded() {
        let store = SessionStore(home: home)
        let live = [LiveRecord(pid: 1, sessionId: "Z", kind: "bg", status: "idle", name: "fresh")]
        let merged = store.merge(live: live, history: [])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].label, "fresh")
        XCTAssertEqual(merged[0].state, .liveIdle)
    }

    // MARK: ordering

    func testGroupOrderingOtherLastLiveFirst() {
        let s1 = ChatSession(sessionId: "1", cwd: "", project: "alpha", label: "cold-new", state: .cold, kind: nil, pid: nil, lastActive: Date(timeIntervalSince1970: 200))
        let s2 = ChatSession(sessionId: "2", cwd: "", project: "alpha", label: "live-old", state: .liveIdle, kind: "bg", pid: 5, lastActive: Date(timeIntervalSince1970: 100))
        let s3 = ChatSession(sessionId: "3", cwd: "", project: "Other", label: "x", state: .cold, kind: nil, pid: nil, lastActive: Date())
        let groups = SessionStore.group([s1, s2, s3])

        XCTAssertEqual(groups.map(\.project), ["alpha", "Other"])     // Other last
        XCTAssertEqual(groups[0].sessions.map(\.label), ["live-old", "cold-new"]) // live first
    }
}
