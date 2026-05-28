import Foundation

/// Single source of truth for project + worktree operations. Used by:
///   • the `project` CLI (Sources/ProjectCLI)
///   • the Mac app's New Project view via `ProjectCreator`
///
/// All process invocations go through `ProcessRunner` (in `ProcessRunner.swift`) so tests
/// can stub git calls.
public struct ProjectManager {
    public let home: String
    public let projectsRoot: URL
    public let templateDir: URL
    public let repoRoots: [URL]
    public let runner: ProcessRunner
    public let fm: FileManager

    public init(home: String = NSHomeDirectory(),
                runner: ProcessRunner = .system,
                fm: FileManager = .default) {
        self.home = home
        let h = URL(fileURLWithPath: home)
        self.projectsRoot = h.appendingPathComponent("projects")
        self.templateDir = h.appendingPathComponent("projects/.template")
        self.repoRoots = [
            h.appendingPathComponent("Home/dev/repos"),
            h.appendingPathComponent("Home/dev/utils"),
        ]
        self.runner = runner
        self.fm = fm
    }

    /// Test injection — lets each test substitute a sandbox layout.
    public init(home: String,
                projectsRoot: URL,
                templateDir: URL,
                repoRoots: [URL],
                runner: ProcessRunner,
                fm: FileManager = .default) {
        self.home = home
        self.projectsRoot = projectsRoot
        self.templateDir = templateDir
        self.repoRoots = repoRoots
        self.runner = runner
        self.fm = fm
    }

    // MARK: Project root discovery

    /// Walks up from `start` looking for a directory that contains `PROJECT.md`.
    /// Returns nil if no ancestor qualifies. Symlinks are resolved.
    public func findProjectRoot(from start: URL) -> URL? {
        var dir = start.resolvingSymlinksInPath()
        while dir.path != "/" {
            if fm.fileExists(atPath: dir.appendingPathComponent("PROJECT.md").path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { return nil }
            dir = parent
        }
        return nil
    }

    // MARK: Repo resolution

    public struct RepoResolution: Equatable {
        public let sourcePath: URL
        public let repoDirName: String
    }

    public enum RepoResolveError: Error, Equatable {
        case pathNotFound(String)
        case pathNotGitWorkingTree(URL)
        case nameNotFound(name: String, searched: [URL])
    }

    /// Resolves `arg` to a (source repo, project-dir-name) pair.
    /// - Paths (contain `/`, start with `~` or `.`): used as-is; basename is the dir name.
    /// - Bare names: searched in order — `<projectRoot>/<arg>`, then each `repoRoots[i]/<arg>`.
    public func resolveRepo(_ arg: String, projectRoot: URL) -> Result<RepoResolution, RepoResolveError> {
        if arg.contains("/") || arg.hasPrefix("~") || arg.hasPrefix(".") {
            let expanded = (arg as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
            guard fm.fileExists(atPath: url.path) else {
                return .failure(.pathNotFound(arg))
            }
            guard isGitWorkingTree(url) else {
                return .failure(.pathNotGitWorkingTree(url))
            }
            return .success(RepoResolution(sourcePath: url, repoDirName: url.lastPathComponent))
        }

        var searched: [URL] = [projectRoot.appendingPathComponent(arg)]
        for root in repoRoots {
            searched.append(root.appendingPathComponent(arg))
        }
        for candidate in searched {
            if isDir(candidate) && isGitWorkingTree(candidate) {
                return .success(RepoResolution(sourcePath: candidate, repoDirName: arg))
            }
        }
        return .failure(.nameNotFound(name: arg, searched: searched))
    }

    // MARK: Worktree add

    public struct AddWorktreeResult: Equatable {
        public let target: URL
        public let attachedExisting: Bool
        public let base: String?
    }

    public enum AddWorktreeError: Error, Equatable {
        case targetAlreadyExists(URL)
        case noBaseBranch(source: URL)
        case gitFailed(String)
        case sourceNotGitWorkingTree(URL)
    }

    /// Attaches existing `branch` if it exists in `source`; otherwise creates it off
    /// master (falling back to main). Creates intermediate parent dirs as needed.
    /// Doesn't pre-check that `source` is a git working tree — callers (the CLI's
    /// `resolveRepo`) handle that earlier with a better error surface; here a non-git
    /// source surfaces as a normal `git worktree add` failure via `.gitFailed`.
    public func addWorktree(source: URL, target: URL, branch: String) -> Result<AddWorktreeResult, AddWorktreeError> {
        if fm.fileExists(atPath: target.path) {
            return .failure(.targetAlreadyExists(target))
        }
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
        } catch {
            return .failure(.gitFailed("couldn't create \(target.deletingLastPathComponent().path): \(error)"))
        }

        if branchExists(in: source, branch: branch) {
            let r = runner.run("/usr/bin/env",
                               ["git", "worktree", "add", target.path, branch],
                               source.path)
            if r.status == 0 {
                return .success(AddWorktreeResult(target: target, attachedExisting: true, base: nil))
            }
            return .failure(.gitFailed(errMsg(r)))
        }

        guard let base = pickBase(in: source) else {
            return .failure(.noBaseBranch(source: source))
        }
        let r = runner.run("/usr/bin/env",
                           ["git", "worktree", "add", "-b", branch, target.path, base],
                           source.path)
        if r.status == 0 {
            return .success(AddWorktreeResult(target: target, attachedExisting: false, base: base))
        }
        return .failure(.gitFailed(errMsg(r)))
    }

    // MARK: Worktree remove

    public enum RemoveWorktreeError: Error, Equatable {
        case notAWorktree(URL)
        case dirty(uncommitted: [String])
        case unpushed(commits: [String])
        case gitFailed(String)
    }

    /// Removes the worktree at `target`. If `force` is false, refuses when the worktree
    /// has uncommitted changes or commits not in any remote. Tidies an empty parent dir.
    public func removeWorktree(target: URL, force: Bool) -> Result<Void, RemoveWorktreeError> {
        guard isGitWorkingTree(target) else {
            return .failure(.notAWorktree(target))
        }

        if !force {
            let status = runner.run("/usr/bin/env",
                                    ["git", "status", "--porcelain"],
                                    target.path)
            let dirty = status.stdout
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { !$0.isEmpty }
            if !dirty.isEmpty {
                return .failure(.dirty(uncommitted: dirty))
            }
            let unpushed = runner.run("/usr/bin/env",
                                      ["git", "log", "--branches", "--not", "--remotes", "--oneline"],
                                      target.path)
            let lines = unpushed.stdout
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { !$0.isEmpty }
            if !lines.isEmpty {
                return .failure(.unpushed(commits: lines))
            }
        }

        // Locate the owning repo via --git-common-dir so we run `worktree remove` from there.
        let common = runner.run("/usr/bin/env",
                                ["git", "rev-parse", "--git-common-dir"],
                                target.path)
        var sourceRepo: URL? = nil
        if common.status == 0 {
            let gcd = common.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let asURL: URL
            if (gcd as NSString).isAbsolutePath {
                asURL = URL(fileURLWithPath: gcd)
            } else {
                asURL = target.appendingPathComponent(gcd).resolvingSymlinksInPath()
            }
            sourceRepo = asURL.deletingLastPathComponent()
        }

        let args = force
            ? ["git", "worktree", "remove", "--force", target.path]
            : ["git", "worktree", "remove", target.path]
        let removeCwd = sourceRepo?.path
        let r = runner.run("/usr/bin/env", args, removeCwd)

        if r.status != 0 {
            if force {
                // Last-resort: just rm -rf.
                try? fm.removeItem(at: target)
            } else {
                return .failure(.gitFailed(errMsg(r)))
            }
        }

        // Tidy empty <project>/<repo>/ parent.
        let parent = target.deletingLastPathComponent()
        if let entries = try? fm.contentsOfDirectory(atPath: parent.path), entries.isEmpty {
            try? fm.removeItem(at: parent)
        }
        return .success(())
    }

    // MARK: Side effects — env + .claude

    public static let envFileNames = [".env", ".env.local"]
    public static let claudeLinkItems = [
        "settings.json", "settings.local.json", "stack-harness.yml", "agents", "knowledge"
    ]

    /// Copies `.env` / `.env.local` from `source` to `target` if present. Returns the
    /// list of filenames actually copied.
    @discardableResult
    public func copyEnvFiles(from source: URL, to target: URL) -> [String] {
        var copied: [String] = []
        for name in Self.envFileNames {
            let src = source.appendingPathComponent(name)
            let dst = target.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.copyItem(at: src, to: dst)
            if fm.fileExists(atPath: dst.path) { copied.append(name) }
        }
        return copied
    }

    /// Symlinks `.claude/<item>` from source into target for every standard item that
    /// exists in source and isn't already present in target. Returns linked item names.
    @discardableResult
    public func symlinkClaude(from source: URL, to target: URL) -> [String] {
        let srcClaude = source.appendingPathComponent(".claude")
        guard isDir(srcClaude) else { return [] }
        let dstClaude = target.appendingPathComponent(".claude")
        try? fm.createDirectory(at: dstClaude, withIntermediateDirectories: true)
        var linked: [String] = []
        for item in Self.claudeLinkItems {
            let s = srcClaude.appendingPathComponent(item)
            let d = dstClaude.appendingPathComponent(item)
            guard fm.fileExists(atPath: s.path) else { continue }
            if fm.fileExists(atPath: d.path) { continue }
            // fileExists follows symlinks. Detect a dangling symlink separately.
            let attrs = try? fm.attributesOfItem(atPath: d.path)
            if attrs != nil { continue }
            do {
                try fm.createSymbolicLink(at: d, withDestinationURL: s)
                linked.append(item)
            } catch {
                continue
            }
        }
        return linked
    }

    // MARK: Listings

    public struct ProjectSummary: Equatable {
        public let name: String
        public let path: URL
        public let tagline: String?
    }

    /// All non-hidden direct child directories of `projectsRoot` that look like projects
    /// (i.e., contain a PROJECT.md). Tagline is the first non-heading, non-blockquote
    /// paragraph from PROJECT.md.
    public func listProjects() -> [ProjectSummary] {
        guard let entries = try? fm.contentsOfDirectory(at: projectsRoot,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])
        else { return [] }
        return entries
            .filter { isDir($0) && !$0.lastPathComponent.hasPrefix(".") }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("PROJECT.md").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { dir in
                ProjectSummary(name: dir.lastPathComponent,
                               path: dir,
                               tagline: firstParagraph(in: dir.appendingPathComponent("PROJECT.md")))
            }
    }

    public struct WorktreeSummary: Equatable {
        public let repo: String
        public let branch: String
        public let path: URL
        public let lastCommit: String?
    }

    /// Every `<projectRoot>/<repo>/<branch>/` directory whose `<branch>` is a git working
    /// tree. Sorted by repo then branch. `lastCommit` is `git log -1 --format=%h %s`.
    public func listWorktrees(in projectRoot: URL) -> [WorktreeSummary] {
        guard let repoEntries = try? fm.contentsOfDirectory(at: projectRoot,
                                                            includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles])
        else { return [] }
        var out: [WorktreeSummary] = []
        for repoDir in repoEntries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard isDir(repoDir), !repoDir.lastPathComponent.hasPrefix(".") else { continue }
            guard let branchEntries = try? fm.contentsOfDirectory(at: repoDir,
                                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles])
            else { continue }
            for branchDir in branchEntries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard isDir(branchDir) else { continue }
                guard isGitWorkingTree(branchDir) else { continue }
                let log = runner.run("/usr/bin/env",
                                     ["git", "log", "-1", "--format=%h %s"],
                                     branchDir.path)
                let commit = log.status == 0
                    ? log.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil
                out.append(WorktreeSummary(
                    repo: repoDir.lastPathComponent,
                    branch: branchDir.lastPathComponent,
                    path: branchDir,
                    lastCommit: (commit?.isEmpty ?? true) ? nil : commit))
            }
        }
        return out
    }

    // MARK: Project creation

    public enum NewProjectError: Error, Equatable {
        case invalidName(ProjectCreator.NameValidation)
        case templateMissing(URL)
        case alreadyExists(URL)
        case copyFailed(String)
        case tokenReplaceFailed(String)
    }

    /// Creates a new project root from `templateDir`, replaces `<project-name>` tokens
    /// in PROJECT.md. Returns the project root path on success.
    public func newProject(name: String) -> Result<URL, NewProjectError> {
        let syntax = ProjectCreator.validateNameSyntax(name)
        guard syntax == .ok else { return .failure(.invalidName(syntax)) }
        let target = projectsRoot.appendingPathComponent(name)
        if fm.fileExists(atPath: target.path) {
            return .failure(.alreadyExists(target))
        }
        guard fm.fileExists(atPath: templateDir.path) else {
            return .failure(.templateMissing(templateDir))
        }
        do {
            try fm.copyItem(at: templateDir, to: target)
        } catch {
            return .failure(.copyFailed("\(error)"))
        }
        let pmd = target.appendingPathComponent("PROJECT.md")
        if fm.fileExists(atPath: pmd.path) {
            do {
                let original = try String(contentsOf: pmd, encoding: .utf8)
                let replaced = original.replacingOccurrences(of: "<project-name>", with: name)
                if replaced != original {
                    try replaced.write(to: pmd, atomically: true, encoding: .utf8)
                }
            } catch {
                return .failure(.tokenReplaceFailed("\(error)"))
            }
        }
        return .success(target)
    }

    // MARK: Public lookups

    /// Whether the given path is a git working tree (`git rev-parse --git-dir` succeeds).
    public func isWorkingTree(_ url: URL) -> Bool { isGitWorkingTree(url) }

    /// Given a worktree path, returns the main repo (source) path. The "source repo" is
    /// the directory containing the shared `.git` (resolved via `git rev-parse
    /// --git-common-dir`). Returns nil for non-worktrees or when git fails.
    public func sourceRepo(for worktree: URL) -> URL? {
        let common = runner.run("/usr/bin/env",
                                ["git", "rev-parse", "--git-common-dir"],
                                worktree.path)
        guard common.status == 0 else { return nil }
        let gcd = common.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let asURL: URL
        if (gcd as NSString).isAbsolutePath {
            asURL = URL(fileURLWithPath: gcd)
        } else {
            asURL = worktree.appendingPathComponent(gcd).resolvingSymlinksInPath()
        }
        return asURL.deletingLastPathComponent()
    }

    // MARK: Helpers

    func isDir(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    func isGitWorkingTree(_ url: URL) -> Bool {
        return runner.run("/usr/bin/env",
                          ["git", "rev-parse", "--git-dir"],
                          url.path).status == 0
    }

    func branchExists(in source: URL, branch: String) -> Bool {
        return runner.run("/usr/bin/env",
                          ["git", "rev-parse", "--verify", "--quiet", branch],
                          source.path).status == 0
    }

    func pickBase(in source: URL) -> String? {
        for cand in ["master", "main"] {
            if branchExists(in: source, branch: cand) { return cand }
        }
        return nil
    }

    func errMsg(_ r: ProcessRunner.Result) -> String {
        let s = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "git exited \(r.status)" : s
    }

    func firstParagraph(in file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") || line.hasPrefix(">") { continue }
            return line
        }
        return nil
    }
}
