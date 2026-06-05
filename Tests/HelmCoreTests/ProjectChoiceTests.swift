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

    /// Projects only — the pinned Singular Chats launchpad is asserted separately.
    private func projects(_ choices: [ProjectChoice]) -> [ProjectChoice] {
        choices.filter { !$0.isLaunchpad }
    }

    func testMembershipComesFromFoldersNotSessions() {
        // No sessions at all: every tracked folder still shows up as a launchable choice.
        let choices = SessionStore.projectChoices(workspaceFolders: folders, sessions: [])
        let projects = projects(choices)
        XCTAssertEqual(projects.map(\.name), ["api", "helm", "web"])   // untouched → alphabetical
        XCTAssertEqual(Set(projects.map(\.path)), Set(folders))        // every folder present, paths intact
        XCTAssertTrue(projects.allSatisfy { $0.lastActive == nil && $0.liveCount == 0 })
    }

    func testRanksActiveFoldersByRecencyThenUntouchedAlphabetical() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let sessions = [
            session(project: "helm", cwd: "/Users/me/projects/helm", lastActive: now.addingTimeInterval(-3600)),
            session(project: "api", cwd: "/Users/me/projects/api", lastActive: now),   // most recent
        ]
        let choices = SessionStore.projectChoices(workspaceFolders: folders, sessions: sessions)
        // api (now) > helm (1h ago) > web (untouched, alphabetical last).
        XCTAssertEqual(projects(choices).map(\.name), ["api", "helm", "web"])
    }

    func testSingularChatsLaunchpadIsPinnedFirst() {
        let now = Date(timeIntervalSinceReferenceDate: 3_000_000)
        let sessions = [
            session(project: "api", cwd: "/Users/me/projects/api", lastActive: now),   // most recent project
            session(project: SessionStore.singularChatsGroup, cwd: "\(NSHomeDirectory())/Home",
                    lastActive: now.addingTimeInterval(-9999), live: true),
        ]
        let choices = SessionStore.projectChoices(workspaceFolders: folders, sessions: sessions)
        let launchpad = choices.first
        XCTAssertEqual(launchpad?.name, SessionStore.singularChatsGroup)   // pinned first, ahead of api
        XCTAssertEqual(launchpad?.isLaunchpad, true)
        XCTAssertEqual(launchpad?.path, "\(NSHomeDirectory())/Home")
        XCTAssertEqual(launchpad?.lastActive, now.addingTimeInterval(-9999))   // recency from ~/Home sessions
        XCTAssertEqual(launchpad?.liveCount, 1)
        XCTAssertEqual(choices.filter { $0.isLaunchpad }.count, 1)
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

    func testIgnoresOtherSessionsButKeepsSingularChats() {
        let now = Date()
        let sessions = [
            session(project: "Other", cwd: "/tmp/scratch", lastActive: now),   // untracked → ignored
            session(project: SessionStore.singularChatsGroup, cwd: "\(NSHomeDirectory())/Home", lastActive: now),
        ]
        let choices = SessionStore.projectChoices(workspaceFolders: folders, sessions: sessions)
        XCTAssertFalse(choices.contains { $0.name == "Other" })
        XCTAssertEqual(Set(projects(choices).map(\.name)), ["helm", "api", "web"])
        XCTAssertTrue(projects(choices).allSatisfy { $0.lastActive == nil })   // no project saw a session
        XCTAssertEqual(choices.first { $0.isLaunchpad }?.lastActive, now)      // launchpad picks up the ~/Home one
    }

    func testDedupesFolderListedTwice() {
        let choices = SessionStore.projectChoices(
            workspaceFolders: ["/Users/me/projects/helm", "/Users/me/projects/helm/"], sessions: [])
        XCTAssertEqual(projects(choices).count, 1)
    }

    func testFilterFuzzyMatchesNameOrPath() {
        // Project-name assertions exclude the launchpad: its path is the real ~/Home, which
        // fuzzy-matches environment-dependent queries and would make these non-deterministic.
        let choices = SessionStore.projectChoices(workspaceFolders: folders, sessions: [])
        let filter = { (q: String) in self.projects(SessionStore.filterProjectChoices(choices, query: q)).map(\.name) }
        XCTAssertEqual(filter("hl"), ["helm"])
        XCTAssertEqual(filter("proj/we"), ["web"])
        XCTAssertEqual(SessionStore.filterProjectChoices(choices, query: "  ").map(\.name).sorted(),
                       ["Singular Chats", "api", "helm", "web"])   // blank query = unfiltered (launchpad included)
        XCTAssertTrue(filter("zzz").isEmpty)
    }
}
