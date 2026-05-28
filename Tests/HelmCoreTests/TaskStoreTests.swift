import XCTest
@testable import HelmCore

final class TaskStoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_716_902_400)   // 2024-05-28T12:00:00Z

    // MARK: status parsing + cycle

    func testStatusParsing() {
        XCTAssertEqual(TaskStatus(parsing: "todo"), .todo)
        XCTAssertEqual(TaskStatus(parsing: "wip"), .wip)
        XCTAssertEqual(TaskStatus(parsing: "in-progress"), .wip)     // legacy alias
        XCTAssertEqual(TaskStatus(parsing: "BLOCKED"), .blocked)
        XCTAssertEqual(TaskStatus(parsing: "done"), .done)
        XCTAssertNil(TaskStatus(parsing: ""))
        XCTAssertNil(TaskStatus(parsing: nil))
        XCTAssertNil(TaskStatus(parsing: "garbage"))
    }

    func testStatusCycle() {
        XCTAssertEqual(TaskStatus.todo.next, .wip)
        XCTAssertEqual(TaskStatus.wip.next, .blocked)
        XCTAssertEqual(TaskStatus.blocked.next, .done)
        XCTAssertEqual(TaskStatus.done.next, .todo)
    }

    // MARK: frontmatter parser

    func testFrontmatterFlat() {
        let fm = TaskStore.parseFrontmatter("""
        ---
        status: wip
        jira: MOBPC-1234
        slack:
        tags: [ios, swcd]
        ---
        # body
        """)
        XCTAssertEqual(fm["status"], "wip")
        XCTAssertEqual(fm["jira"], "MOBPC-1234")
        XCTAssertEqual(fm["slack"], "")
        XCTAssertEqual(fm["tags"], "[ios, swcd]")
    }

    func testFrontmatterPreservesTimestampColons() {
        let fm = TaskStore.parseFrontmatter("---\ndue: 2026-05-12T17:00:00\n---\n")
        XCTAssertEqual(fm["due"], "2026-05-12T17:00:00")
    }

    func testFrontmatterMissingReturnsEmpty() {
        XCTAssertEqual(TaskStore.parseFrontmatter("# just a title\nno fences"), [:])
        XCTAssertEqual(TaskStore.parseFrontmatter("---\nno end fence\n"), [:])
    }

    // MARK: title extraction

    func testH1OverridesBasename() {
        let t = TaskStore.parse(text: "---\nstatus: todo\n---\n\n# Real Title\n",
                                basename: "MOBPC-1234-slug", mtime: now, archived: false)
        XCTAssertEqual(t.title, "Real Title")
    }

    func testTitleFallsBackToBasename() {
        let t = TaskStore.parse(text: "---\nstatus: todo\n---\n\nbody\n",
                                basename: "my-task", mtime: now, archived: false)
        XCTAssertEqual(t.title, "my-task")
    }

    // MARK: subtask counting

    func testSubtasksMixedAndCaseInsensitive() {
        let (done, total) = TaskStore.countSubtasks("""
        ## Subtasks
        - [ ] one
        - [x] two
        - [X] three
        - [ ] four
        """)
        XCTAssertEqual(done, 2)
        XCTAssertEqual(total, 4)
    }

    func testSubtasksIgnoreEmptyTemplatePlaceholders() {
        // The new-task template ships a single bare `- [ ]` line; don't count it.
        let (done, total) = TaskStore.countSubtasks("- [ ]\n- [ ] real subtask")
        XCTAssertEqual(done, 0)
        XCTAssertEqual(total, 1)
    }

    func testSubtasksIndentedStillCount() {
        let (done, total) = TaskStore.countSubtasks("    - [x] indented done\n  - [ ] indented todo")
        XCTAssertEqual(done, 1)
        XCTAssertEqual(total, 2)
    }

    // MARK: source resolution (jira > slack)

    func testJiraKeyExpandsToBrowserstackURL() {
        guard case let .jira(key, url)? = TaskStore.resolveSource(jira: "MOBPC-1234", slack: nil) else {
            return XCTFail("expected jira source")
        }
        XCTAssertEqual(key, "MOBPC-1234")
        XCTAssertEqual(url, "https://browserstack.atlassian.net/browse/MOBPC-1234")
    }

    func testJiraFullURLPassesThrough() {
        guard case let .jira(key, url)? = TaskStore.resolveSource(
            jira: "https://browserstack.atlassian.net/browse/MOBPC-5", slack: nil) else {
            return XCTFail("expected jira source")
        }
        XCTAssertEqual(key, "MOBPC-5")
        XCTAssertEqual(url, "https://browserstack.atlassian.net/browse/MOBPC-5")
    }

    func testJiraBeatsSlack() {
        let s = TaskStore.resolveSource(jira: "MOBPC-9", slack: "https://browserstack.slack.com/...")
        guard case .jira = s else { return XCTFail("jira should win") }
    }

    func testSlackOnly() {
        guard case let .slack(url)? = TaskStore.resolveSource(jira: nil, slack: "https://x.slack.com/y") else {
            return XCTFail("expected slack source")
        }
        XCTAssertEqual(url, "https://x.slack.com/y")
    }

    func testNoSource() {
        XCTAssertNil(TaskStore.resolveSource(jira: nil, slack: nil))
        XCTAssertNil(TaskStore.resolveSource(jira: "", slack: ""))
    }

    // MARK: iso8601

    func testParseISOVariants() {
        XCTAssertNotNil(TaskStore.parseISO("2026-05-12T17:00:00Z"))
        XCTAssertNotNil(TaskStore.parseISO("2026-05-12T17:00:00"))
        XCTAssertNotNil(TaskStore.parseISO("2026-05-12T17:00:00+00:00"))
        XCTAssertNil(TaskStore.parseISO(""))
        XCTAssertNil(TaskStore.parseISO(nil))
        XCTAssertNil(TaskStore.parseISO("not a date"))
    }

    // MARK: end-to-end parse

    func testParseFullFile() {
        let text = """
        ---
        type: task
        status: wip
        created: 2026-05-08
        jira: MOBPC-99
        slack:
        tags: []
        due: 2026-05-12T17:00:00Z
        wip_since: 2026-05-08T10:00:00Z
        ---

        # Real Title

        ## Subtasks
        - [ ] a
        - [x] b
        """
        let t = TaskStore.parse(text: text, basename: "MOBPC-99-slug", mtime: now, archived: false)
        XCTAssertEqual(t.title, "Real Title")
        XCTAssertEqual(t.status, .wip)
        XCTAssertEqual(t.subtasksDone, 1)
        XCTAssertEqual(t.subtasksTotal, 2)
        XCTAssertEqual(t.basename, "MOBPC-99-slug")
        XCTAssertFalse(t.archived)
        if case .jira(let key, _) = t.source { XCTAssertEqual(key, "MOBPC-99") } else { XCTFail() }
        XCTAssertNotNil(t.due)
        XCTAssertNotNil(t.wipSince)
        XCTAssertNil(t.checkIn)
    }

    func testParseDegradesGracefullyOnGarbage() {
        let t = TaskStore.parse(text: "no frontmatter at all", basename: "x", mtime: now, archived: false)
        XCTAssertEqual(t.status, .todo)
        XCTAssertEqual(t.title, "x")
        XCTAssertNil(t.source)
        XCTAssertEqual(t.subtasksTotal, 0)
    }

    // MARK: sort

    func testActiveSortByStatusThenMtime() {
        let t = { (basename: String, status: TaskStatus, age: TimeInterval) -> VaultTask in
            VaultTask(basename: basename, title: basename, status: status, source: nil,
                 archived: false, mtime: self.now.addingTimeInterval(-age))
        }
        let unsorted = [
            t("done-recent",   .done,    60),
            t("todo-old",      .todo,    3600),
            t("wip-old",       .wip,     7200),
            t("wip-recent",    .wip,     30),
            t("blocked",       .blocked, 100),
            t("todo-recent",   .todo,    10),
        ]
        let sorted = TaskStore.sortActive(unsorted).map(\.basename)
        XCTAssertEqual(sorted, ["wip-recent", "wip-old", "todo-recent", "todo-old", "blocked", "done-recent"])
    }

    func testArchiveSortNewestFirst() {
        let t = { (n: String, age: TimeInterval) -> VaultTask in
            VaultTask(basename: n, title: n, status: .done, source: nil,
                 archived: true, mtime: self.now.addingTimeInterval(-age))
        }
        let sorted = TaskStore.sortArchive([t("old", 7200), t("recent", 60), t("middle", 1800)])
        XCTAssertEqual(sorted.map(\.basename), ["recent", "middle", "old"])
    }

    // MARK: age flags

    func testOverdueLabelsDays() {
        let due = now.addingTimeInterval(-3 * 86_400 - 60)   // 3d 1m late → "3d late"
        let task = VaultTask(basename: "x", title: "x", status: .todo, source: nil,
                        archived: false, mtime: now, due: due)
        let f = TaskStore.ageFlags(for: task, now: now)
        XCTAssertTrue(f.overdue)
        XCTAssertEqual(f.label, "3d late")
    }

    func testOverdueSameDayShowsDue() {
        let due = now.addingTimeInterval(-3600)   // 1h late, < 1d
        let task = VaultTask(basename: "x", title: "x", status: .todo, source: nil,
                        archived: false, mtime: now, due: due)
        XCTAssertEqual(TaskStore.ageFlags(for: task, now: now).label, "due")
    }

    func testCheckinFiresWhenDueIsClear() {
        let task = VaultTask(basename: "x", title: "x", status: .todo, source: nil,
                        archived: false, mtime: now,
                        checkIn: now.addingTimeInterval(-60))
        let f = TaskStore.ageFlags(for: task, now: now)
        XCTAssertTrue(f.checkin)
        XCTAssertEqual(f.label, "check in")
    }

    func testStaleWipOnlyAtThreshold() {
        let twoDays = now.addingTimeInterval(-2 * 86_400)
        let fourDays = now.addingTimeInterval(-4 * 86_400)
        let young = VaultTask(basename: "y", title: "y", status: .wip, source: nil,
                         archived: false, mtime: now, wipSince: twoDays)
        let old = VaultTask(basename: "o", title: "o", status: .wip, source: nil,
                       archived: false, mtime: now, wipSince: fourDays)
        XCTAssertEqual(TaskStore.ageFlags(for: young, now: now), .none)
        let f = TaskStore.ageFlags(for: old, now: now)
        XCTAssertTrue(f.staleWip)
        XCTAssertEqual(f.label, "4d wip")
    }

    func testDoneAndArchivedNeverFlag() {
        let oldDue = now.addingTimeInterval(-10 * 86_400)
        let done = VaultTask(basename: "d", title: "d", status: .done, source: nil,
                        archived: false, mtime: now, due: oldDue)
        let archived = VaultTask(basename: "a", title: "a", status: .todo, source: nil,
                            archived: true, mtime: now, due: oldDue)
        XCTAssertEqual(TaskStore.ageFlags(for: done, now: now), .none)
        XCTAssertEqual(TaskStore.ageFlags(for: archived, now: now), .none)
    }

    // MARK: end-to-end filesystem (writes a temp vault)

    func testLoadFromTempVault() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-task-vault-\(UUID().uuidString)")
        let tasks = tmp.appendingPathComponent("tasks")
        let archive = tmp.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try """
        ---
        status: wip
        jira: MOBPC-1
        ---
        # Active one
        - [x] done sub
        - [ ] open sub
        """.write(to: tasks.appendingPathComponent("active.md"), atomically: true, encoding: .utf8)

        try """
        ---
        status: done
        ---
        # Archived one
        """.write(to: archive.appendingPathComponent("old.md"), atomically: true, encoding: .utf8)

        let (act, arc) = TaskStore(vaultDir: tmp).load()
        XCTAssertEqual(act.count, 1)
        XCTAssertEqual(act[0].title, "Active one")
        XCTAssertEqual(act[0].status, .wip)
        XCTAssertEqual(act[0].subtasksDone, 1)
        XCTAssertEqual(act[0].subtasksTotal, 2)
        XCTAssertEqual(arc.count, 1)
        XCTAssertEqual(arc[0].title, "Archived one")
        XCTAssertTrue(arc[0].archived)
    }
}
