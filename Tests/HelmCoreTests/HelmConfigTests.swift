import XCTest
@testable import HelmCore

final class HelmConfigTests: XCTestCase {
    func testTerminalParsing() {
        XCTAssertEqual(TerminalKind(parsing: "iterm"), .iterm)
        XCTAssertEqual(TerminalKind(parsing: "iTerm2"), .iterm)
        XCTAssertEqual(TerminalKind(parsing: "terminal"), .terminal)
        XCTAssertEqual(TerminalKind(parsing: "Terminal.app"), .terminal)
    }

    func testDefaultsToAppleTerminal() {
        XCTAssertEqual(TerminalKind.default, .terminal)
        XCTAssertEqual(TerminalKind(parsing: nil), .terminal)
        XCTAssertEqual(TerminalKind(parsing: "ghostty"), .terminal)   // unknown → default
    }

    func testLoadMissingFileReturnsDefault() {
        let missing = URL(fileURLWithPath: "/tmp/helm-does-not-exist-\(UUID()).json")
        XCTAssertEqual(HelmConfig.load(from: missing), HelmConfig())
    }

    func testLoadReadsTerminal() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-cfg-\(UUID()).json")
        try #"{"terminal":"iterm","hideOlderThanDays":14}"#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let cfg = HelmConfig.load(from: url)
        XCTAssertEqual(cfg.terminal, .iterm)
        XCTAssertEqual(cfg.hideOlderThanDays, 14)
        XCTAssertEqual(cfg.hideOlderThan, 14 * 86_400)
    }

    func testHideOlderThanDefaultsToOneDay() {
        XCTAssertEqual(HelmConfig().hideOlderThanDays, 1)
        XCTAssertEqual(HelmConfig().hideOlderThan, 86_400)
    }

    func testHideOlderThanDisabledWhenNonPositive() {
        XCTAssertEqual(HelmConfig(hideOlderThanDays: 0).hideOlderThan, 0)
        XCTAssertEqual(HelmConfig(hideOlderThanDays: -1).hideOlderThan, 0)
    }

    func testAgentDefaultsPreserveClaudeOnly() {
        let cfg = HelmConfig()
        XCTAssertEqual(cfg.enabledAgents, [.claude])
        XCTAssertEqual(cfg.defaultAgent, .claude)
    }

    func testLoadReadsEnabledAndDefaultAgents() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-cfg-\(UUID()).json")
        try #"{"enabledAgents":["claude","pi"],"defaultAgent":"pi"}"#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let cfg = HelmConfig.load(from: url)
        XCTAssertEqual(cfg.enabledAgents, [.claude, .pi])
        XCTAssertEqual(cfg.defaultAgent, .pi)
    }

    func testDefaultAgentFallsBackToEnabledAgent() {
        let cfg = HelmConfig(enabledAgents: [.pi], defaultAgent: .claude)
        XCTAssertEqual(cfg.enabledAgents, [.pi])
        XCTAssertEqual(cfg.defaultAgent, .pi)
    }

    func testInvalidAgentConfigFallsBackToClaudeOnly() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-cfg-\(UUID()).json")
        try #"{"enabledAgents":["ghost"],"defaultAgent":"pi"}"#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let cfg = HelmConfig.load(from: url)
        XCTAssertEqual(cfg.enabledAgents, [.claude])
        XCTAssertEqual(cfg.defaultAgent, .claude)
    }

    func testLoadReadsWorkspaceFolders() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-cfg-\(UUID()).json")
        try #"{"workspaceFolders":["~/Home/dev/helm","/tmp/demo","/tmp/demo"]}"#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let cfg = HelmConfig.load(from: url)
        XCTAssertEqual(cfg.workspaceFolders, [
            "\(NSHomeDirectory())/Home/dev/helm",
            "/tmp/demo",
        ])
    }

    func testAddWorkspaceFoldersPreservesExistingConfig() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-cfg-\(UUID()).json")
        try #"{"terminal":"iterm","workspaceFolders":["/tmp/one"]}"#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let cfg = try HelmConfig.addWorkspaceFolders(["/tmp/two", "/tmp/one"], to: url)

        XCTAssertEqual(cfg.terminal, .iterm)
        XCTAssertEqual(cfg.workspaceFolders, ["/tmp/one", "/tmp/two"])
    }

    func testRemoveWorkspaceFolderPreservesExistingConfig() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-cfg-\(UUID()).json")
        try #"{"terminal":"iterm","workspaceFolders":["/tmp/one","/tmp/two"]}"#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let cfg = try HelmConfig.removeWorkspaceFolder("/tmp/one", from: url)

        XCTAssertEqual(cfg.terminal, .iterm)
        XCTAssertEqual(cfg.workspaceFolders, ["/tmp/two"])
    }

    func testRemoveWorkspaceFolderExcludesRootTrackedChild() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-cfg-\(UUID()).json")
        try #"{"workspaceRoots":["/root"]}"#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let lister: (String) -> [String] = { $0 == "/root" ? ["/root/a", "/root/b"] : [] }
        // "/root/a" is auto-tracked via the root, not an explicit folder — removing it must
        // record an exclusion so the root can't re-add it.
        let cfg = try HelmConfig.removeWorkspaceFolder("/root/a", from: url, lister: lister)

        XCTAssertEqual(cfg.excludedFolders, ["/root/a"])
        XCTAssertEqual(cfg.resolvedWorkspaceFolders(lister: lister), ["/root/b"])
    }

    func testRemoveExplicitFolderLeavesNoExclusionCruft() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-cfg-\(UUID()).json")
        try #"{"workspaceFolders":["/ws/one","/ws/two"]}"#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        // No root would re-add "/ws/one", so removing it should not leave a dangling exclusion.
        let cfg = try HelmConfig.removeWorkspaceFolder("/ws/one", from: url, lister: { _ in [] })

        XCTAssertEqual(cfg.workspaceFolders, ["/ws/two"])
        XCTAssertEqual(cfg.excludedFolders, [])
    }

    func testStaleExclusionPrunedWhenRootStopsDiscovering() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-cfg-\(UUID()).json")
        try #"{"workspaceRoots":["/root"],"excludedFolders":["/root/gone"]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        // "/root/gone" no longer exists under the root — the next write self-prunes it.
        let cfg = try HelmConfig.addWorkspaceRoots(["/root2"], to: url, lister: { _ in [] })

        XCTAssertEqual(cfg.excludedFolders, [])
    }

    func testAddWorkspaceFolderClearsPriorExclusion() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-cfg-\(UUID()).json")
        try #"{"workspaceRoots":["/root"],"excludedFolders":["/root/a"]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let lister: (String) -> [String] = { $0 == "/root" ? ["/root/a"] : [] }
        let cfg = try HelmConfig.addWorkspaceFolders(["/root/a"], to: url, lister: lister)

        XCTAssertEqual(cfg.excludedFolders, [])
        XCTAssertEqual(cfg.resolvedWorkspaceFolders(lister: lister), ["/root/a"])
    }

    func testLoadReadsWorkspaceRoots() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-cfg-\(UUID()).json")
        try #"{"workspaceRoots":["~/projects","/tmp/roots","/tmp/roots"]}"#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let cfg = HelmConfig.load(from: url)
        XCTAssertEqual(cfg.workspaceRoots, [
            "\(NSHomeDirectory())/projects",
            "/tmp/roots",
        ])
    }

    func testResolvedWorkspaceFoldersExpandsRootsAndDedupes() {
        let cfg = HelmConfig(workspaceFolders: ["/ws/explicit", "/root/a"],
                             workspaceRoots: ["/root"])
        let resolved = cfg.resolvedWorkspaceFolders { root in
            root == "/root" ? ["/root/a", "/root/b"] : []
        }
        // explicit folders first, then discovered children; the duplicate "/root/a" collapses.
        XCTAssertEqual(resolved, ["/ws/explicit", "/root/a", "/root/b"])
    }

    func testResolvedWorkspaceFoldersWithNoRootsIsJustFolders() {
        let cfg = HelmConfig(workspaceFolders: ["/ws/one"])
        XCTAssertEqual(cfg.resolvedWorkspaceFolders { _ in ["/should/not/appear"] }, ["/ws/one"])
    }

    func testChildDirectoriesScansImmediateSubdirsSkippingHiddenAndFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-roots-\(UUID())")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("beta"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("afile.txt"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: root) }

        let names = Set(HelmConfig.childDirectories(of: root.path).map { ($0 as NSString).lastPathComponent })
        XCTAssertEqual(names, ["alpha", "beta"])
    }

    func testChildDirectoriesOnMissingRootIsEmpty() {
        XCTAssertEqual(HelmConfig.childDirectories(of: "/tmp/helm-no-such-root-\(UUID())"), [])
    }

    func testAddWorkspaceRootsPreservesExistingConfig() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-cfg-\(UUID()).json")
        try #"{"terminal":"iterm","workspaceFolders":["/tmp/one"],"workspaceRoots":["/roots/a"]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let cfg = try HelmConfig.addWorkspaceRoots(["/roots/b", "/roots/a"], to: url)

        XCTAssertEqual(cfg.terminal, .iterm)
        XCTAssertEqual(cfg.workspaceFolders, ["/tmp/one"])
        XCTAssertEqual(cfg.workspaceRoots, ["/roots/a", "/roots/b"])
    }

    func testRemoveWorkspaceRootPreservesExistingConfig() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-cfg-\(UUID()).json")
        try #"{"workspaceRoots":["/roots/a","/roots/b"]}"#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let cfg = try HelmConfig.removeWorkspaceRoot("/roots/a", from: url)

        XCTAssertEqual(cfg.workspaceRoots, ["/roots/b"])
    }
}
