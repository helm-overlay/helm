import XCTest
@testable import HelmCore

final class ClaudeHooksPluginTests: XCTestCase {

    // MARK: resolveLiveRow — hook verdict folds into display state

    private func row(_ state: SessionState) -> ChatSession {
        ChatSession(sessionId: "S", cwd: "", project: "p", label: "S",
                    state: state, kind: "interactive", pid: 1, lastActive: .distantPast)
    }

    func testBusyRowWithNeedsInputVerdictIsPromotedToAttention() {
        // The whole point of the AskUserQuestion hook: a verdict surfaces even though the
        // live registry still reports the session busy.
        let out = SessionStore.resolveLiveRow(row(.liveBusy), stateReason: .needsInput,
                                              classifyTail: { XCTFail("tail must not be read when a verdict exists"); return nil })
        XCTAssertEqual(out.state, .liveIdle)
        XCTAssertEqual(out.idleReason, .needsInput)
    }

    func testBusyRowWithNoVerdictStaysBusy() {
        let out = SessionStore.resolveLiveRow(row(.liveBusy), stateReason: nil, classifyTail: { .needsReview })
        XCTAssertEqual(out.state, .liveBusy)        // a `running` marker reads as no verdict → busy
        XCTAssertNil(out.idleReason)
    }

    func testIdleRowPrefersVerdictOverTail() {
        let out = SessionStore.resolveLiveRow(row(.liveIdle), stateReason: .needsReview,
                                              classifyTail: { XCTFail("verdict present"); return nil })
        XCTAssertEqual(out.state, .liveIdle)
        XCTAssertEqual(out.idleReason, .needsReview)
    }

    func testIdleRowFallsBackToTailClassify() {
        let out = SessionStore.resolveLiveRow(row(.liveIdle), stateReason: nil, classifyTail: { .needsInput })
        XCTAssertEqual(out.idleReason, .needsInput)
    }

    func testColdRowUntouched() {
        let out = SessionStore.resolveLiveRow(row(.cold), stateReason: .needsInput,
                                              classifyTail: { XCTFail("cold pays no IO"); return nil })
        XCTAssertEqual(out.state, .cold)
        XCTAssertNil(out.idleReason)
    }

    // MARK: plugin payload

    func testHooksJSONHasFullLifecycleAndAskMatcher() throws {
        let json = ClaudeHooksPlugin.hooksJSON(stateDir: "/Users/me/.helm/claude/state")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(obj["hooks"] as? [String: Any])

        XCTAssertEqual(Set(hooks.keys),
                       ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"])

        // AskUserQuestion is matched on both pre (→ needs_input) and post (→ running).
        for event in ["PreToolUse", "PostToolUse"] {
            let group = try XCTUnwrap((hooks[event] as? [[String: Any]])?.first)
            XCTAssertEqual(group["matcher"] as? String, "AskUserQuestion")
        }
        let pre = try XCTUnwrap(((hooks["PreToolUse"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertTrue((pre["command"] as? String ?? "").hasSuffix("set-state.sh\" needs_input"))

        // Stop is the Haiku agent classifier, with the resolved state dir baked into its prompt.
        let stop = try XCTUnwrap(((hooks["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(stop["type"] as? String, "agent")
        XCTAssertEqual(stop["model"] as? String, "claude-haiku-4-5-20251001")
        XCTAssertTrue((stop["prompt"] as? String ?? "").contains("/Users/me/.helm/claude/state/<session_id>.json"))
    }

    func testManifestIsValidJSONWithName() throws {
        let json = ClaudeHooksPlugin.pluginManifest(author: ("Me", "me@example.com"))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["name"] as? String, "helm")
        XCTAssertEqual((obj["author"] as? [String: Any])?["email"] as? String, "me@example.com")
    }

    func testInstallWritesExecutableHandlersAndStateDir() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("helm-install-\(UUID())")
        defer { try? fm.removeItem(at: home) }

        let report = try ClaudePluginInstaller.install(home: home.path, author: ("Me", "me@example.com"))

        let plugin = home.appendingPathComponent(".claude/skills/helm")
        XCTAssertTrue(fm.fileExists(atPath: plugin.appendingPathComponent("hooks/hooks.json").path))
        XCTAssertTrue(fm.fileExists(atPath: plugin.appendingPathComponent(".claude-plugin/plugin.json").path))
        XCTAssertTrue(fm.fileExists(atPath: report.stateDir))   // ~/.helm/claude/state created

        let setState = plugin.appendingPathComponent("hooks-handlers/set-state.sh").path
        let perms = try XCTUnwrap((try fm.attributesOfItem(atPath: setState)[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(perms & 0o111, 0o111, "handler must be executable")

        XCTAssertFalse(report.legacyHooksInSettings)   // no settings.json in this sandbox
    }
}
