import XCTest
@testable import HelmCore

final class ProjectCreatorTests: XCTestCase {
    // MARK: Name validation

    func testNameSyntaxRules() {
        XCTAssertEqual(ProjectCreator.validateNameSyntax(""), .empty)
        XCTAssertEqual(ProjectCreator.validateNameSyntax("claude-projects"), .ok)
        XCTAssertEqual(ProjectCreator.validateNameSyntax("a"), .ok)
        XCTAssertEqual(ProjectCreator.validateNameSyntax("9-lives"), .ok)
        XCTAssertEqual(ProjectCreator.validateNameSyntax("Claude"), .notKebabCase)        // uppercase
        XCTAssertEqual(ProjectCreator.validateNameSyntax("foo_bar"), .notKebabCase)       // underscore
        XCTAssertEqual(ProjectCreator.validateNameSyntax("foo.bar"), .notKebabCase)       // dot
        XCTAssertEqual(ProjectCreator.validateNameSyntax("foo/bar"), .notKebabCase)       // slash
        XCTAssertEqual(ProjectCreator.validateNameSyntax("-foo"), .notKebabCase)          // leading hyphen
        XCTAssertEqual(ProjectCreator.validateNameSyntax("foo-"), .notKebabCase)          // trailing hyphen
        XCTAssertEqual(ProjectCreator.validateNameSyntax("foo--bar"), .notKebabCase)      // double hyphen
        XCTAssertEqual(ProjectCreator.validateNameSyntax("foo bar"), .notKebabCase)       // space
    }

    func testCollisionDetected() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try FileManager.default.createDirectory(at: env.projectsRoot.appendingPathComponent("alpha"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(env.creator.validateName("alpha"), .collides)
        XCTAssertEqual(env.creator.validateName("beta"), .ok)
    }

    // MARK: Available repos

    func testListAvailableReposIgnoresHiddenAndFiles() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let fm = FileManager.default
        try fm.createDirectory(at: env.reposRoot.appendingPathComponent("mobile"), withIntermediateDirectories: true)
        try fm.createDirectory(at: env.reposRoot.appendingPathComponent("realmobile"), withIntermediateDirectories: true)
        try fm.createDirectory(at: env.reposRoot.appendingPathComponent(".cache"), withIntermediateDirectories: true)
        try "x".write(to: env.reposRoot.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        XCTAssertEqual(env.creator.listAvailableRepos(), ["mobile", "realmobile"])
    }

    // MARK: Bare-project create

    func testBareCreateCopiesTemplateAndSubstitutesName() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let outcome = try env.creator.create(name: "demo", repos: [])
        XCTAssertTrue(outcome.allSucceeded)
        XCTAssertEqual(outcome.projectRoot.path, env.projectsRoot.appendingPathComponent("demo").path)

        let projectMd = outcome.projectRoot.appendingPathComponent("PROJECT.md")
        let claudeMd = outcome.projectRoot.appendingPathComponent("CLAUDE.md")
        let projectContent = try String(contentsOf: projectMd, encoding: .utf8)
        XCTAssertTrue(projectContent.contains("# demo"))
        XCTAssertFalse(projectContent.contains("<project-name>"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: claudeMd.path))
    }

    func testCreateRejectsInvalidName() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        XCTAssertThrowsError(try env.creator.create(name: "Bad_Name", repos: [])) { err in
            guard case ProjectCreator.CreateError.invalidName(let v) = err else { return XCTFail("wrong error: \(err)") }
            XCTAssertEqual(v, .notKebabCase)
        }
    }

    func testCreateRejectsMissingTemplate() throws {
        let env = try makeEnv(makeTemplate: false)
        defer { env.cleanup() }
        XCTAssertThrowsError(try env.creator.create(name: "demo", repos: [])) { err in
            guard case ProjectCreator.CreateError.templateMissing = err else { return XCTFail("wrong error: \(err)") }
        }
    }

    // MARK: Worktree dispatch (stubbed git)

    func testNewBranchUsesMasterAsBaseByDefault() throws {
        let env = try makeEnv(repos: ["mobile"])
        defer { env.cleanup() }
        var calls: [[String]] = []
        env.installRunner { _, args, _ in
            calls.append(args)
            // rev-parse for the requested branch fails → new branch path
            if args[0] == "git" && args[1] == "rev-parse" && args.last == "feature-x" {
                return .init(status: 1, stderr: "")
            }
            // rev-parse for `master` succeeds, `main` is irrelevant once master is found
            if args[0] == "git" && args[1] == "rev-parse" && args.last == "master" {
                return .init(status: 0)
            }
            // worktree add
            if args[0] == "git" && args[1] == "worktree" {
                return .init(status: 0)
            }
            return .init(status: 1, stderr: "unexpected: \(args)")
        }
        let outcome = try env.creator.create(name: "demo",
                                             repos: [.init(repo: "mobile", branch: "feature-x")])
        XCTAssertTrue(outcome.allSucceeded)
        XCTAssertEqual(outcome.repos[0].result,
                       .success(branch: "feature-x", createdBranch: true, base: "master"))
        let worktreeCall = calls.first(where: { $0.contains("worktree") })!
        XCTAssertEqual(worktreeCall[0...3], ["git", "worktree", "add", "-b"])
        XCTAssertEqual(worktreeCall.last, "master")
        XCTAssertTrue(worktreeCall.contains("feature-x"))
        XCTAssertTrue(calls.contains(where: { $0.contains("master") && $0.contains("rev-parse") }))
        XCTAssertFalse(calls.contains(where: { $0.contains("main") }))
    }

    func testNewBranchFallsBackToMainIfNoMaster() throws {
        let env = try makeEnv(repos: ["mobile"])
        defer { env.cleanup() }
        env.installRunner { _, args, _ in
            if args[1] == "rev-parse" && args.last == "feature-x" { return .init(status: 1) }
            if args[1] == "rev-parse" && args.last == "master"    { return .init(status: 1) }
            if args[1] == "rev-parse" && args.last == "main"      { return .init(status: 0) }
            if args[1] == "worktree" { return .init(status: 0) }
            return .init(status: 1, stderr: "unexpected: \(args)")
        }
        let outcome = try env.creator.create(name: "demo",
                                             repos: [.init(repo: "mobile", branch: "feature-x")])
        XCTAssertEqual(outcome.repos[0].result,
                       .success(branch: "feature-x", createdBranch: true, base: "main"))
    }

    func testExistingBranchAttaches() throws {
        let env = try makeEnv(repos: ["mobile"])
        defer { env.cleanup() }
        var worktreeArgs: [String] = []
        env.installRunner { _, args, _ in
            if args[1] == "rev-parse" && args.last == "existing" { return .init(status: 0) }
            if args[1] == "worktree" { worktreeArgs = args; return .init(status: 0) }
            return .init(status: 1)
        }
        let outcome = try env.creator.create(name: "demo",
                                             repos: [.init(repo: "mobile", branch: "existing")])
        XCTAssertEqual(outcome.repos[0].result,
                       .success(branch: "existing", createdBranch: false, base: nil))
        XCTAssertEqual(worktreeArgs[0...2], ["git", "worktree", "add"])
        XCTAssertFalse(worktreeArgs.contains("-b"))
        XCTAssertEqual(worktreeArgs.last, "existing")
    }

    func testPerRepoFailureDoesNotBlockOtherRepos() throws {
        let env = try makeEnv(repos: ["mobile", "realmobile"])
        defer { env.cleanup() }
        env.installRunner { _, args, cwd in
            if args[1] == "rev-parse" && args.last == "feature-x" { return .init(status: 1) }
            if args[1] == "rev-parse" && args.last == "master"    { return .init(status: 0) }
            if args[1] == "worktree" {
                if (cwd ?? "").hasSuffix("/mobile") {
                    return .init(status: 128,
                                 stderr: "fatal: 'feature-x' is already checked out at /some/other/path")
                }
                return .init(status: 0)
            }
            return .init(status: 1)
        }
        let outcome = try env.creator.create(name: "demo", repos: [
            .init(repo: "mobile", branch: "feature-x"),
            .init(repo: "realmobile", branch: "feature-x"),
        ])
        XCTAssertFalse(outcome.allSucceeded)
        guard case .failed(let msg) = outcome.repos[0].result else { return XCTFail("expected failure") }
        XCTAssertTrue(msg.contains("already checked out"))
        guard case .success = outcome.repos[1].result else { return XCTFail("expected success") }
    }

    func testCreateResolvesRepoFromUtilsRoot() throws {
        // The bug this fixes: a repo that lives only in ~/Home/dev/utils (e.g. helm itself)
        // must be reachable from the GUI form, not just the CLI.
        let env = try makeEnv()
        defer { env.cleanup() }
        try FileManager.default.createDirectory(at: env.utilsRoot.appendingPathComponent("helm"),
                                                withIntermediateDirectories: true)
        var worktreeCwd: String?
        env.installRunner { _, args, cwd in
            if args[1] == "rev-parse" && args.last == "feat"   { return .init(status: 1) }  // new branch
            if args[1] == "rev-parse" && args.last == "master" { return .init(status: 0) }
            if args[1] == "worktree" { worktreeCwd = cwd; return .init(status: 0) }
            return .init(status: 1)
        }
        let outcome = try env.creator.create(name: "demo", repos: [.init(repo: "helm", branch: "feat")])
        XCTAssertTrue(outcome.allSucceeded)
        XCTAssertEqual(worktreeCwd, env.utilsRoot.appendingPathComponent("helm").path)
    }

    func testListAvailableReposUnionsRootsFirstWins() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let fm = FileManager.default
        try fm.createDirectory(at: env.reposRoot.appendingPathComponent("mobile"), withIntermediateDirectories: true)
        try fm.createDirectory(at: env.utilsRoot.appendingPathComponent("helm"), withIntermediateDirectories: true)
        try fm.createDirectory(at: env.utilsRoot.appendingPathComponent("mobile"), withIntermediateDirectories: true) // dup
        XCTAssertEqual(env.creator.listAvailableRepos(), ["helm", "mobile"])   // deduped, sorted
    }

    func testMissingRepoReportedPerRow() throws {
        let env = try makeEnv(repos: ["mobile"])
        defer { env.cleanup() }
        env.installRunner { _, _, _ in .init(status: 0) }
        let outcome = try env.creator.create(name: "demo", repos: [
            .init(repo: "ghost", branch: "feature-x"),
        ])
        guard case .failed(let msg) = outcome.repos[0].result else { return XCTFail("expected failure") }
        XCTAssertTrue(msg.contains("repo not found"))
    }

    // MARK: Test env

    private final class Env {
        let home: URL
        let projectsRoot: URL
        let templateDir: URL
        let reposRoot: URL
        let utilsRoot: URL
        var runner: ProcessRunner
        init(home: URL, projectsRoot: URL, templateDir: URL, reposRoot: URL, utilsRoot: URL) {
            self.home = home
            self.projectsRoot = projectsRoot
            self.templateDir = templateDir
            self.reposRoot = reposRoot
            self.utilsRoot = utilsRoot
            self.runner = ProcessRunner { _, _, _ in .init(status: 0) }
        }
        var creator: ProjectCreator {
            ProjectCreator(home: home.path, projectsRoot: projectsRoot,
                           templateDir: templateDir, repoRoots: [reposRoot, utilsRoot],
                           runner: runner)
        }
        func installRunner(_ fn: @escaping (String, [String], String?) -> ProcessRunner.Result) {
            runner = ProcessRunner(run: fn)
        }
        func cleanup() { try? FileManager.default.removeItem(at: home) }
    }

    /// Builds a fresh temp ~ with projects/.template + repos/<name>/ entries. Hands back
    /// an Env whose `creator` can be mutated with a stub runner between calls.
    private func makeEnv(makeTemplate: Bool = true, repos: [String] = []) throws -> Env {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-pc-\(UUID())")
        let projectsRoot = home.appendingPathComponent("projects")
        let templateDir = projectsRoot.appendingPathComponent(".template")
        let reposRoot = home.appendingPathComponent("Home/dev/repos")
        let utilsRoot = home.appendingPathComponent("Home/dev/utils")
        try fm.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: reposRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: utilsRoot, withIntermediateDirectories: true)
        if makeTemplate {
            try fm.createDirectory(at: templateDir, withIntermediateDirectories: true)
            try "# <project-name>\n\nA brief here.\n"
                .write(to: templateDir.appendingPathComponent("PROJECT.md"),
                       atomically: true, encoding: .utf8)
            try "Stub CLAUDE.md\n"
                .write(to: templateDir.appendingPathComponent("CLAUDE.md"),
                       atomically: true, encoding: .utf8)
        }
        for r in repos {
            try fm.createDirectory(at: reposRoot.appendingPathComponent(r), withIntermediateDirectories: true)
        }
        return Env(home: home, projectsRoot: projectsRoot, templateDir: templateDir,
                   reposRoot: reposRoot, utilsRoot: utilsRoot)
    }
}
