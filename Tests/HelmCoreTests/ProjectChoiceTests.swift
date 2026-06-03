import XCTest
@testable import HelmCore

final class ProjectChoiceTests: XCTestCase {
    private func session(project: String, cwd: String, lastActive: Date, live: Bool = false) -> ChatSession {
        ChatSession(sessionId: "\(project)-\(lastActive.timeIntervalSinceReferenceDate)",
                    cwd: cwd, project: project, label: project,
                    state: live ? .liveIdle : .cold, kind: nil, pid: live ? 1 : nil,
                    lastActive: lastActive)
    }

    private let folders = ["/Users/me/projects/helm", "/Users/me/projects/api", "/Users/me/projects/web"]

    func testMembershipComesFromFoldersNotSessions() {
        // No sessions at all: every tracked folder still shows up as a launchable choice.
        let choices = SessionStore.projectChoices(workspaceFolders: folders, sessions: [])
        XCTAssertEqual(choices.map(\.name), ["api", "helm", "web"])   // untouched → alphabetical
        XCTAssertEqual(Set(choices.map(\.path)), Set(folders))        // every folder present, paths intact
        XCTAssertTrue(choices.allSatisfy { $0.lastActive == nil && $0.liveCount == 0 })
    }

    func testRanksActiveFoldersByRecencyThenUntouchedAlphabetical() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let sessions = [
            session(project: "helm", cwd: "/Users/me/projects/helm", lastActive: now.addingTimeInterval(-3600)),
            session(project: "api", cwd: "/Users/me/projects/api", lastActive: now),   // most recent
        ]
        let choices = SessionStore.projectChoices(workspaceFolders: folders, sessions: sessions)
        // api (now) > helm (1h ago) > web (untouched, alphabetical last).
        XCTAssertEqual(choices.map(\.name), ["api", "helm", "web"])
    }

    func testUsesMostRecentSessionPerFolderAndCountsLive() {
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000)
        let sessions = [
            session(project: "helm", cwd: "/Users/me/projects/helm", lastActive: now.addingTimeInterval(-100)),
            session(project: "helm", cwd: "/Users/me/projects/helm/sub", lastActive: now, live: true),
            session(project: "helm", cwd: "/Users/me/projects/helm", lastActive: now.addingTimeInterval(-50), live: true),
        ]
        let helm = SessionStore.projectChoices(workspaceFolders: folders, sessions: sessions).first { $0.name == "helm" }
        XCTAssertEqual(helm?.lastActive, now)
        XCTAssertEqual(helm?.liveCount, 2)
    }

    func testIgnoresSessionsOutsideTrackedFolders() {
        let now = Date()
        let sessions = [
            session(project: "Other", cwd: "/tmp/scratch", lastActive: now),
            session(project: SessionStore.singularChatsGroup, cwd: "/Users/me/Home", lastActive: now),
        ]
        let choices = SessionStore.projectChoices(workspaceFolders: folders, sessions: sessions)
        XCTAssertEqual(Set(choices.map(\.name)), ["helm", "api", "web"])   // no Other / Singular Chats row
        XCTAssertTrue(choices.allSatisfy { $0.lastActive == nil })
    }

    func testDedupesFolderListedTwice() {
        let choices = SessionStore.projectChoices(
            workspaceFolders: ["/Users/me/projects/helm", "/Users/me/projects/helm/"], sessions: [])
        XCTAssertEqual(choices.count, 1)
    }

    func testFilterFuzzyMatchesNameOrPath() {
        let choices = SessionStore.projectChoices(workspaceFolders: folders, sessions: [])
        XCTAssertEqual(SessionStore.filterProjectChoices(choices, query: "hl").map(\.name), ["helm"])
        XCTAssertEqual(SessionStore.filterProjectChoices(choices, query: "proj/we").map(\.name), ["web"])
        XCTAssertEqual(SessionStore.filterProjectChoices(choices, query: "  ").map(\.name).sorted(),
                       ["api", "helm", "web"])   // blank query = unfiltered
        XCTAssertTrue(SessionStore.filterProjectChoices(choices, query: "zzz").isEmpty)
    }
}
