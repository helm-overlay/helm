import XCTest
@testable import HelmCore

final class ClaudeSessionBackendTests: XCTestCase {
    func testUserThreadVsAutomation() {
        XCTAssertTrue(SessionStore.isUserThread(entrypoint: "cli"))
        XCTAssertTrue(SessionStore.isUserThread(entrypoint: nil))
        XCTAssertFalse(SessionStore.isUserThread(entrypoint: "sdk-py"))
        XCTAssertFalse(SessionStore.isUserThread(entrypoint: "sdk-ts"))
    }

    func testSubagentTranscriptDetection() {
        XCTAssertTrue(SessionStore.isSubagentTranscript(filename: "agent-afcb69a539763eff5.jsonl"))
        XCTAssertFalse(SessionStore.isSubagentTranscript(filename: "3f27ba72-739d-41a8-8f47.jsonl"))
    }

    func testReadLiveAndHistoryFromTempClaudeDir() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("helm-ss-\(UUID())")
        defer { try? fm.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".claude/sessions")
        let projects = home.appendingPathComponent(".claude/projects/proj")
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        try fm.createDirectory(at: projects, withIntermediateDirectories: true)

        let myPid = ProcessInfo.processInfo.processIdentifier
        try #"{"pid":\#(myPid),"sessionId":"S1","kind":"interactive","status":"busy","entrypoint":"cli","name":"live one"}"#
            .write(to: sessions.appendingPathComponent("\(myPid).json"), atomically: true, encoding: .utf8)

        let demo = "\(home.path)/projects/demo"
        try (#"{"cwd":"\#(demo)","gitBranch":"main","aiTitle":"hello","entrypoint":"cli"}"# + "\n")
            .write(to: projects.appendingPathComponent("S1.jsonl"), atomically: true, encoding: .utf8)
        try (#"{"cwd":"\#(demo)","gitBranch":"feat","entrypoint":"cli"}"# + "\n")
            .write(to: projects.appendingPathComponent("S2.jsonl"), atomically: true, encoding: .utf8)
        try (#"{"cwd":"\#(demo)","entrypoint":"sdk-py"}"# + "\n")
            .write(to: projects.appendingPathComponent("S3.jsonl"), atomically: true, encoding: .utf8)

        let store = SessionStore(home: home.path)
        XCTAssertEqual(store.readLive().map(\.sessionId), ["S1"])
        XCTAssertEqual(store.readLive().first?.status, "busy")

        let history = store.readHistory()
        XCTAssertEqual(Set(history.map(\.sessionId)), ["S1", "S2"])

        let merged = store.merge(live: store.readLive(), history: history)
        let s1 = merged.first { $0.sessionId == "S1" }!
        XCTAssertEqual(s1.state, .liveBusy)
        XCTAssertEqual(s1.label, "live one")
        XCTAssertEqual(s1.project, "demo")
        XCTAssertEqual(merged.first { $0.sessionId == "S2" }?.state, .cold)
    }
}
