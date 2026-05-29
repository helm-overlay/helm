import XCTest
@testable import HelmCore

final class PiSessionBackendTests: XCTestCase {
    func testPiLiveAndIdleStateParsing() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("helm-pi-live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let liveDir = home.appendingPathComponent(".pi/sessions")
        let stateDir = home.appendingPathComponent(".helm/pi/state")
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        try """
        {"pid":\(pid),"sessionId":"pi-live","status":"idle","name":"Live Pi","entrypoint":"cli"}
        """.write(to: liveDir.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
        try #"{"reason":"needs_input"}"#.write(to: stateDir.appendingPathComponent("pi-live.json"), atomically: true, encoding: .utf8)

        let rows = SessionStore(home: home.path, enabledAgents: [.pi]).load()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].agent, .pi)
        XCTAssertEqual(rows[0].sessionId, "pi-live")
        XCTAssertEqual(rows[0].state, .liveIdle)
        XCTAssertEqual(rows[0].idleReason, .needsInput)
        XCTAssertEqual(rows[0].label, "Live Pi")
    }

    func testPiReapsDeadState() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("helm-pi-reap-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let liveDir = home.appendingPathComponent(".pi/sessions")
        let stateDir = home.appendingPathComponent(".helm/pi/state")
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        try """
        {"pid":\(pid),"sessionId":"alive","status":"idle","entrypoint":"cli"}
        """.write(to: liveDir.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
        try #"{"reason":"done"}"#.write(to: stateDir.appendingPathComponent("alive.json"), atomically: true, encoding: .utf8)
        try #"{"reason":"done"}"#.write(to: stateDir.appendingPathComponent("dead.json"), atomically: true, encoding: .utf8)

        let reaped = SessionStore(home: home.path, enabledAgents: [.pi]).reapDeadState()
        XCTAssertTrue(reaped.contains("pi:dead"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateDir.appendingPathComponent("alive.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDir.appendingPathComponent("dead.json").path))
    }

    func testPiHistoryParsing() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("helm-pi-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent(".pi/agent/sessions/--Users--me--projects--demo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("20260529_abc.jsonl")
        try [
            #"{"type":"session","id":"same-id","cwd":"/Users/me/projects/demo/repo"}"#,
            #"{"type":"message","role":"user","content":"first prompt"}"#,
            #"{"type":"session_info","name":"Named Pi Chat"}"#
        ].joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let rows = SessionStore(home: home.path, enabledAgents: [.pi]).load()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].agent, .pi)
        XCTAssertEqual(rows[0].sessionId, "same-id")
        XCTAssertEqual(rows[0].id, "pi:same-id")
        XCTAssertEqual(rows[0].cwd, "/Users/me/projects/demo/repo")
        XCTAssertEqual(rows[0].project, "demo")
        XCTAssertEqual(rows[0].label, "Named Pi Chat")
        XCTAssertEqual(rows[0].transcriptPath, file.path)
        XCTAssertEqual(rows[0].state, .cold)
    }
}
