import XCTest
@testable import HelmCore

final class ProjectManagerTests: XCTestCase {

    // MARK: findProjectRoot

    func testFindProjectRootWalksUp() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let project = env.projectsRoot.appendingPathComponent("alpha")
        let nested = project.appendingPathComponent("helm/branch-x/Sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "# alpha\n".write(to: project.appendingPathComponent("PROJECT.md"),
                              atomically: true, encoding: .utf8)
        XCTAssertEqual(env.manager.findProjectRoot(from: nested)?.path, project.path)
        XCTAssertEqual(env.manager.findProjectRoot(from: project)?.path, project.path)
    }

    func testFindProjectRootReturnsNilOutsideProject() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        // env.home has no PROJECT.md anywhere up the tree.
        XCTAssertNil(env.manager.findProjectRoot(from: env.home))
    }

    // MARK: resolveRepo — bare-name search order

    func testResolveRepoPrefersProjectSibling() throws {
        let env = try makeEnv(repos: ["mobile"])
        defer { env.cleanup() }
        let project = env.projectsRoot.appendingPathComponent("alpha")
        let siblingRepo = project.appendingPathComponent("mobile")
        try FileManager.default.createDirectory(at: siblingRepo, withIntermediateDirectories: true)
        env.installRunner { _, args, cwd in
            // Treat both the sibling and ~/Home/dev/repos/mobile as valid git working trees.
            if args == ["git", "rev-parse", "--git-dir"], cwd != nil {
                return .init(status: 0, stdout: ".git\n")
            }
            return .init(status: 1)
        }
        let result = env.manager.resolveRepo("mobile", projectRoot: project)
        switch result {
        case .success(let r):
            XCTAssertEqual(r.sourcePath.path, siblingRepo.path)
            XCTAssertEqual(r.repoDirName, "mobile")
        case .failure(let e):
            XCTFail("expected success, got \(e)")
        }
    }

    func testResolveRepoFallsBackToReposRoot() throws {
        let env = try makeEnv(repos: ["mobile"])
        defer { env.cleanup() }
        let project = env.projectsRoot.appendingPathComponent("alpha")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        env.installRunner { _, args, _ in
            if args == ["git", "rev-parse", "--git-dir"] { return .init(status: 0) }
            return .init(status: 1)
        }
        let result = env.manager.resolveRepo("mobile", projectRoot: project)
        switch result {
        case .success(let r):
            XCTAssertEqual(r.sourcePath.path, env.reposRoot.appendingPathComponent("mobile").path)
        case .failure(let e):
            XCTFail("expected success, got \(e)")
        }
    }

    func testResolveRepoFallsThroughToUtilsRoot() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let project = env.projectsRoot.appendingPathComponent("alpha")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: env.utilsRoot.appendingPathComponent("helm"),
                                                withIntermediateDirectories: true)
        env.installRunner { _, args, _ in
            if args == ["git", "rev-parse", "--git-dir"] { return .init(status: 0) }
            return .init(status: 1)
        }
        let result = env.manager.resolveRepo("helm", projectRoot: project)
        switch result {
        case .success(let r):
            XCTAssertEqual(r.sourcePath.path, env.utilsRoot.appendingPathComponent("helm").path)
        case .failure(let e):
            XCTFail("expected success, got \(e)")
        }
    }

    func testResolveRepoNotFoundLists3SearchedPaths() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let project = env.projectsRoot.appendingPathComponent("alpha")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let result = env.manager.resolveRepo("ghost", projectRoot: project)
        switch result {
        case .failure(.nameNotFound(_, let searched)):
            XCTAssertEqual(searched.count, 3)
            XCTAssertEqual(searched[0].lastPathComponent, "ghost")
        default:
            XCTFail("expected nameNotFound, got \(result)")
        }
    }

    // MARK: addWorktree

    func testAddWorktreeRefusesWhenTargetExists() throws {
        let env = try makeEnv(repos: ["mobile"])
        defer { env.cleanup() }
        let source = env.reposRoot.appendingPathComponent("mobile")
        let project = env.projectsRoot.appendingPathComponent("alpha")
        let target = project.appendingPathComponent("mobile/feature-x")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        env.installRunner { _, _, _ in .init(status: 0) }
        switch env.manager.addWorktree(source: source, target: target, branch: "feature-x") {
        case .failure(.targetAlreadyExists(let url)):
            XCTAssertEqual(url.path, target.path)
        default:
            XCTFail("expected targetAlreadyExists")
        }
    }

    func testAddWorktreeAttachesExistingBranch() throws {
        let env = try makeEnv(repos: ["mobile"])
        defer { env.cleanup() }
        let source = env.reposRoot.appendingPathComponent("mobile")
        let target = env.projectsRoot.appendingPathComponent("alpha/mobile/feat")
        var invocations: [[String]] = []
        env.installRunner { _, args, _ in
            invocations.append(args)
            // Branch exists, worktree add succeeds.
            return .init(status: 0)
        }
        switch env.manager.addWorktree(source: source, target: target, branch: "feat") {
        case .success(let r):
            XCTAssertTrue(r.attachedExisting)
            XCTAssertNil(r.base)
        default:
            XCTFail("expected success")
        }
        XCTAssertTrue(invocations.contains { $0 == ["git", "worktree", "add", target.path, "feat"] })
    }

    func testAddWorktreeCreatesBranchOffMasterWhenNew() throws {
        let env = try makeEnv(repos: ["mobile"])
        defer { env.cleanup() }
        let source = env.reposRoot.appendingPathComponent("mobile")
        let target = env.projectsRoot.appendingPathComponent("alpha/mobile/new-feat")
        env.installRunner { _, args, _ in
            if args == ["git", "rev-parse", "--git-dir"] { return .init(status: 0) }
            // Branch "new-feat" does NOT exist; "master" does.
            if args == ["git", "rev-parse", "--verify", "--quiet", "new-feat"] { return .init(status: 1) }
            if args == ["git", "rev-parse", "--verify", "--quiet", "master"]    { return .init(status: 0) }
            if args.starts(with: ["git", "worktree", "add"]) { return .init(status: 0) }
            return .init(status: 1)
        }
        switch env.manager.addWorktree(source: source, target: target, branch: "new-feat") {
        case .success(let r):
            XCTAssertFalse(r.attachedExisting)
            XCTAssertEqual(r.base, "master")
        default:
            XCTFail("expected success")
        }
    }

    // MARK: removeWorktree dirty gate

    func testRemoveWorktreeRefusesWhenDirty() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let wt = env.home.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        env.installRunner { _, args, _ in
            if args == ["git", "rev-parse", "--git-dir"] { return .init(status: 0) }
            if args == ["git", "status", "--porcelain"] {
                return .init(status: 0, stdout: "?? scratch.txt\n M Sources/Foo.swift\n")
            }
            return .init(status: 0)
        }
        switch env.manager.removeWorktree(target: wt, force: false) {
        case .failure(.dirty(let files)):
            XCTAssertEqual(files.count, 2)
            XCTAssertEqual(files[0], "?? scratch.txt")
        default:
            XCTFail("expected dirty failure")
        }
    }

    func testRemoveWorktreeRefusesWhenUnpushed() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let wt = env.home.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        env.installRunner { _, args, _ in
            if args == ["git", "rev-parse", "--git-dir"] { return .init(status: 0) }
            if args == ["git", "status", "--porcelain"] { return .init(status: 0) }
            if args == ["git", "log", "--branches", "--not", "--remotes", "--oneline"] {
                return .init(status: 0, stdout: "abc1234 wip: new thing\n")
            }
            return .init(status: 0)
        }
        switch env.manager.removeWorktree(target: wt, force: false) {
        case .failure(.unpushed(let commits)):
            XCTAssertEqual(commits, ["abc1234 wip: new thing"])
        default:
            XCTFail("expected unpushed failure")
        }
    }

    // MARK: symlinkClaude

    func testSymlinkClaudeIsIdempotent() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let fm = FileManager.default
        let source = env.home.appendingPathComponent("src")
        let target = env.home.appendingPathComponent("dst")
        let srcClaude = source.appendingPathComponent(".claude")
        try fm.createDirectory(at: srcClaude, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try "x".write(to: srcClaude.appendingPathComponent("settings.json"),
                      atomically: true, encoding: .utf8)
        try fm.createDirectory(at: srcClaude.appendingPathComponent("agents"),
                               withIntermediateDirectories: true)

        let firstPass = env.manager.symlinkClaude(from: source, to: target)
        XCTAssertEqual(Set(firstPass), ["settings.json", "agents"])

        // Second invocation should be a no-op (existing links left alone).
        let secondPass = env.manager.symlinkClaude(from: source, to: target)
        XCTAssertTrue(secondPass.isEmpty)
    }

    func testSymlinkClaudeLinksArbitraryItemsAndSkipsDenylist() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let fm = FileManager.default
        let source = env.home.appendingPathComponent("src")
        let target = env.home.appendingPathComponent("dst")
        let srcClaude = source.appendingPathComponent(".claude")
        try fm.createDirectory(at: srcClaude, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        // An item not in any historical allowlist — must still be linked (default-open).
        try "y".write(to: srcClaude.appendingPathComponent("some-new-config.json"),
                      atomically: true, encoding: .utf8)
        // Runtime/state entries — must be skipped.
        try fm.createDirectory(at: srcClaude.appendingPathComponent("projects"),
                               withIntermediateDirectories: true)
        try "z".write(to: srcClaude.appendingPathComponent(".DS_Store"),
                      atomically: true, encoding: .utf8)

        let linked = Set(env.manager.symlinkClaude(from: source, to: target))
        XCTAssertTrue(linked.contains("some-new-config.json"))
        XCTAssertFalse(linked.contains("projects"))
        XCTAssertFalse(linked.contains(".DS_Store"))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent(".claude/projects").path))
    }

    func testSymlinkRootContextLinksClaudeFiles() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let fm = FileManager.default
        let source = env.home.appendingPathComponent("src")
        let target = env.home.appendingPathComponent("dst")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try "root".write(to: source.appendingPathComponent("CLAUDE.md"),
                         atomically: true, encoding: .utf8)
        try "local".write(to: source.appendingPathComponent("CLAUDE.local.md"),
                          atomically: true, encoding: .utf8)

        let linked = Set(env.manager.symlinkRootContext(from: source, to: target))
        XCTAssertEqual(linked, ["CLAUDE.md", "CLAUDE.local.md"])
        let dst = target.appendingPathComponent("CLAUDE.md")
        XCTAssertEqual(try? fm.destinationOfSymbolicLink(atPath: dst.path),
                       source.appendingPathComponent("CLAUDE.md").path)
        // Idempotent.
        XCTAssertTrue(env.manager.symlinkRootContext(from: source, to: target).isEmpty)
    }

    // MARK: listProjects tagline

    func testListProjectsExtractsTaglineFromPROJECTmd() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let fm = FileManager.default
        let alpha = env.projectsRoot.appendingPathComponent("alpha")
        let beta = env.projectsRoot.appendingPathComponent("beta")
        try fm.createDirectory(at: alpha, withIntermediateDirectories: true)
        try fm.createDirectory(at: beta, withIntermediateDirectories: true)
        try "# alpha\n\n> a quote\n\nFirst real paragraph here.\n"
            .write(to: alpha.appendingPathComponent("PROJECT.md"),
                   atomically: true, encoding: .utf8)
        try "# beta\n\nOther tagline.\n"
            .write(to: beta.appendingPathComponent("PROJECT.md"),
                   atomically: true, encoding: .utf8)
        let projects = env.manager.listProjects()
        XCTAssertEqual(projects.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(projects[0].tagline, "First real paragraph here.")
        XCTAssertEqual(projects[1].tagline, "Other tagline.")
    }

    // MARK: Helpers

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
        var manager: ProjectManager {
            ProjectManager(home: home.path,
                           projectsRoot: projectsRoot,
                           templateDir: templateDir,
                           repoRoots: [reposRoot, utilsRoot],
                           runner: runner)
        }
        func installRunner(_ fn: @escaping (String, [String], String?) -> ProcessRunner.Result) {
            runner = ProcessRunner(run: fn)
        }
        func cleanup() { try? FileManager.default.removeItem(at: home) }
    }

    private func makeEnv(makeTemplate: Bool = true, repos: [String] = []) throws -> Env {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-pm-\(UUID())")
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
        }
        for r in repos {
            try fm.createDirectory(at: reposRoot.appendingPathComponent(r),
                                   withIntermediateDirectories: true)
        }
        return Env(home: home, projectsRoot: projectsRoot, templateDir: templateDir,
                   reposRoot: reposRoot, utilsRoot: utilsRoot)
    }
}
