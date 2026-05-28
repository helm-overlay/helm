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

    // MARK: head read (skip image blobs, recover later cwd/aiTitle/entrypoint)

    func testCollectSmallLinesSkipsMegaLineAndKeepsLaterMetadata() {
        let small1 = #"{"type":"mode","mode":"normal"}"#
        let megaLine = "{\"role\":\"user\",\"image\":\"" + String(repeating: "A", count: 300 * 1024) + "\"}"
        let small2 = #"{"cwd":"/Users/me/projects/p","entrypoint":"cli","aiTitle":"hello"}"#
        let blob = Data((small1 + "\n" + megaLine + "\n" + small2 + "\n").utf8)
        var offset = 0
        let result = SessionStore.collectSmallLines { n in
            guard offset < blob.count else { return Data() }
            let end = min(offset + n, blob.count)
            let slice = blob.subdata(in: offset..<end)
            offset = end
            return slice
        }
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains(#""cwd":"/Users/me/projects/p""#) == true)
        XCTAssertTrue(result?.contains(#""aiTitle":"hello""#) == true)
        XCTAssertFalse(result?.contains("AAAAA") == true)   // mega line dropped
    }

    func testStateDerivation() {
        XCTAssertEqual(SessionStore.state(forStatus: "busy", isLive: true), .liveBusy)
        XCTAssertEqual(SessionStore.state(forStatus: "idle", isLive: true), .liveIdle)
        XCTAssertEqual(SessionStore.state(forStatus: nil, isLive: true), .liveIdle)
        XCTAssertEqual(SessionStore.state(forStatus: "busy", isLive: false), .cold)
    }

    // MARK: idle classification (needs-input vs done)

    private func asst(_ content: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"\#(content)"}]}}"#
    }

    func testClassifyDoneWhenProseEndsDeclaratively() {
        let tail = asst("All set — the build passes and tests are green.")
        XCTAssertEqual(SessionStore.classifyIdleTail(tail), .done)
    }

    func testClassifyNeedsInputWhenLastLineIsAQuestion() {
        let tail = asst("Which option do you want?")
        XCTAssertEqual(SessionStore.classifyIdleTail(tail), .needsInput)
    }

    func testClassifyQuestionOnFinalLineOfMultiline() {
        // In real JSONL, in-message newlines are escaped (\n) and stay on one line;
        // only the LAST line of the decoded text is inspected for the trailing "?".
        let tail = asst(#"Here are the tradeoffs.\nWhich one should I build?"#)
        XCTAssertEqual(SessionStore.classifyIdleTail(tail), .needsInput)
    }

    func testClassifyDoneWhenQuestionIsNotOnTheLastLine() {
        // Deliberate low recall: a question buried above a declarative close reads as done.
        let tail = asst(#"Should I proceed?\nI'll wait for your go-ahead before touching it."#)
        XCTAssertEqual(SessionStore.classifyIdleTail(tail), .done)
    }

    func testClassifyNeedsInputOnUnansweredToolUse() {
        // Assistant asked via a tool and no tool_result followed → blocked on the user.
        let tail = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_1","name":"AskUserQuestion"}]}}"#
        XCTAssertEqual(SessionStore.classifyIdleTail(tail), .needsInput)
    }

    func testClassifyDoneWhenToolUseHasResult() {
        let tail = [
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_1","name":"Bash"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_1"}]}}"#,
            asst("Done — ran it and cleaned up."),
        ].joined(separator: "\n")
        XCTAssertEqual(SessionStore.classifyIdleTail(tail), .done)
    }

    func testClassifyIgnoresTrailingMetadataAndPartialFirstLine() {
        let tail = [
            #"e":"text","text":"truncated mid-record from the tail read"}]}}"#,   // partial → skipped
            asst("Want me to wire it up?"),
            #"{"type":"ai-title","title":"something"}"#,                           // metadata → skipped
            #"{"type":"permission-mode","mode":"default"}"#,
        ].joined(separator: "\n")
        XCTAssertEqual(SessionStore.classifyIdleTail(tail), .needsInput)
    }

    func testClassifyDoneWhenNoAssistantMessage() {
        XCTAssertEqual(SessionStore.classifyIdleTail(#"{"type":"user","message":{"role":"user","content":"hi"}}"#), .done)
    }

    func testIdleReasonFromHookState() {
        XCTAssertEqual(SessionStore.idleReason(fromState: "needs_input"), .needsInput)
        XCTAssertEqual(SessionStore.idleReason(fromState: "done"), .done)
        XCTAssertNil(SessionStore.idleReason(fromState: "needsInput"))   // not the hook's spelling
        XCTAssertNil(SessionStore.idleReason(fromState: nil))
    }

    // MARK: state-file reaping

    func testDeadStateIdsAreThoseWithoutALiveSession() {
        let onDisk: Set<String> = ["A", "B", "C"]
        let alive: Set<String> = ["B"]   // only B is still running
        XCTAssertEqual(SessionStore.deadStateIds(stateFileIds: onDisk, aliveIds: alive), ["A", "C"])
    }

    func testDeadStateIdsEmptyWhenAllLive() {
        XCTAssertTrue(SessionStore.deadStateIds(stateFileIds: ["A"], aliveIds: ["A", "B"]).isEmpty)
    }

    func testDeadStateIdsReapsAllWhenNoneLive() {
        XCTAssertEqual(SessionStore.deadStateIds(stateFileIds: ["A", "B"], aliveIds: []), ["A", "B"])
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

    // MARK: live reconcile (cheap refresh)

    private func row(_ id: String, _ state: SessionState, pid: Int32? = nil) -> ChatSession {
        ChatSession(sessionId: id, cwd: "/Users/me/projects/helm", project: "helm",
                    label: id, state: state, kind: state == .cold ? nil : "interactive",
                    pid: pid, lastActive: .distantPast)
    }

    func testReconcileFlipsBusyToIdleAndDropsToCold() {
        let rows = [row("A", .liveBusy, pid: 1), row("B", .liveBusy, pid: 2)]
        // A is now idle; B has exited (gone from the registry).
        let live = [LiveRecord(pid: 1, sessionId: "A", kind: "interactive", status: "idle", name: nil)]
        let (out, new) = SessionStore.reconcileLive(rows, live: live) { _ in .done }

        XCTAssertFalse(new)
        XCTAssertEqual(out.first { $0.sessionId == "A" }!.state, .liveIdle)
        XCTAssertEqual(out.first { $0.sessionId == "A" }!.idleReason, .done)
        let b = out.first { $0.sessionId == "B" }!
        XCTAssertEqual(b.state, .cold)
        XCTAssertNil(b.pid)
    }

    func testReconcileRevivesColdRowFromRegistry() {
        let rows = [row("A", .cold)]
        let live = [LiveRecord(pid: 9, sessionId: "A", kind: "interactive", status: "busy", name: nil)]
        let (out, new) = SessionStore.reconcileLive(rows, live: live) { _ in nil }

        XCTAssertFalse(new)              // A already had a row — not a "new" session
        XCTAssertEqual(out[0].state, .liveBusy)
        XCTAssertEqual(out[0].pid, 9)
    }

    func testReconcileFlagsNewSessionWithNoRow() {
        let rows = [row("A", .liveBusy, pid: 1)]
        let live = [
            LiveRecord(pid: 1, sessionId: "A", kind: "interactive", status: "busy", name: nil),
            LiveRecord(pid: 2, sessionId: "NEW", kind: "interactive", status: "busy", name: nil),
        ]
        let (_, new) = SessionStore.reconcileLive(rows, live: live) { _ in nil }
        XCTAssertTrue(new)               // caller must full-reload to materialize NEW
    }

    func testReconcileIsIdentityWhenNothingChanged() {
        let rows = [row("A", .liveBusy, pid: 1), row("B", .cold)]
        let live = [LiveRecord(pid: 1, sessionId: "A", kind: "interactive", status: "busy", name: nil)]
        let (out, new) = SessionStore.reconcileLive(rows, live: live) { _ in nil }
        XCTAssertFalse(new)
        XCTAssertEqual(out, rows)        // unchanged → caller skips the redraw
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

    // MARK: search

    func testFuzzyMatchesSubsequenceNotJustSubstring() {
        XCTAssertTrue(SessionStore.fuzzy("mobile-poll cleanup", "mpc"))   // out-of-order chars, in sequence
        XCTAssertTrue(SessionStore.fuzzy("MOBPC-1234", "mob"))            // case-insensitive
        XCTAssertFalse(SessionStore.fuzzy("alpha", "az"))                 // 'z' missing
        XCTAssertTrue(SessionStore.fuzzy("anything", ""))                // empty query matches
    }

    func testMatchesSpansLabelBranchAndCwd() {
        let s = ChatSession(sessionId: "1", cwd: "/Users/me/projects/helm/Sources",
                            project: "helm", label: "fix dispatch",
                            state: .cold, kind: nil, pid: nil, lastActive: Date(),
                            branch: "helm-bootstrap")
        XCTAssertTrue(SessionStore.matches(s, query: "dispatch"))    // label
        XCTAssertTrue(SessionStore.matches(s, query: "helm"))        // project
        XCTAssertTrue(SessionStore.matches(s, query: "bootstrap"))   // branch
        XCTAssertTrue(SessionStore.matches(s, query: "sources"))     // cwd
        XCTAssertFalse(SessionStore.matches(s, query: "android"))
    }
}
