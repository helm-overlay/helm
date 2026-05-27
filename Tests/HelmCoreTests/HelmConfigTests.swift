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

    func testHideOlderThanDefaultsToOneWeek() {
        XCTAssertEqual(HelmConfig().hideOlderThanDays, 7)
        XCTAssertEqual(HelmConfig().hideOlderThan, 7 * 86_400)
    }

    func testHideOlderThanDisabledWhenNonPositive() {
        XCTAssertEqual(HelmConfig(hideOlderThanDays: 0).hideOlderThan, 0)
        XCTAssertEqual(HelmConfig(hideOlderThanDays: -1).hideOlderThan, 0)
    }
}
