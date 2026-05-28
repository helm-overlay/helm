import Foundation

/// Creates a new ~/projects/<name>/ from the .template, then attaches one git worktree
/// per requested repo. Pure-Swift port of the not-yet-existing `newproject` helper —
/// lives in HelmCore so the UI is a thin form and the logic is unit-testable.
///
/// All process invocations go through `ProcessRunner` so tests can substitute a stub
/// for `git` calls without touching the filesystem of real repos.
public struct ProjectCreator {
    public let home: String
    public let projectsRoot: URL
    public let templateDir: URL
    public let reposRoot: URL
    public let runner: ProcessRunner
    public let fm: FileManager

    public init(home: String = NSHomeDirectory(),
                runner: ProcessRunner = .system,
                fm: FileManager = .default) {
        self.home = home
        self.projectsRoot = URL(fileURLWithPath: home).appendingPathComponent("projects")
        self.templateDir = projectsRoot.appendingPathComponent(".template")
        self.reposRoot = URL(fileURLWithPath: home).appendingPathComponent("Home/dev/repos")
        self.runner = runner
        self.fm = fm
    }

    /// Override constructor for tests; lets a temp dir stand in for `~`.
    public init(home: String, projectsRoot: URL, templateDir: URL, reposRoot: URL,
                runner: ProcessRunner, fm: FileManager = .default) {
        self.home = home
        self.projectsRoot = projectsRoot
        self.templateDir = templateDir
        self.reposRoot = reposRoot
        self.runner = runner
        self.fm = fm
    }

    // MARK: Inputs

    public struct RepoSpec: Equatable {
        public let repo: String      // direct-child folder name under reposRoot
        public let branch: String
        public init(repo: String, branch: String) {
            self.repo = repo
            self.branch = branch
        }
    }

    // MARK: Validation

    public enum NameValidation: Equatable {
        case ok
        case empty
        case notKebabCase
        case collides
    }

    /// Pure-syntax check (no filesystem). Lowercase letters/digits/hyphens, must start
    /// with a letter or digit. Used live as the user types.
    public static func validateNameSyntax(_ name: String) -> NameValidation {
        if name.isEmpty { return .empty }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        if name.unicodeScalars.contains(where: { !allowed.contains($0) }) { return .notKebabCase }
        guard let first = name.first, first.isLetter || first.isNumber else { return .notKebabCase }
        if name.hasSuffix("-") || name.contains("--") { return .notKebabCase }
        return .ok
    }

    /// Syntax + collision check against `~/projects/<name>/`. Use at submit time.
    public func validateName(_ name: String) -> NameValidation {
        let syntax = Self.validateNameSyntax(name)
        guard syntax == .ok else { return syntax }
        let target = projectsRoot.appendingPathComponent(name)
        return fm.fileExists(atPath: target.path) ? .collides : .ok
    }

    /// Local branches for a direct-child repo. Returns [] if the repo is missing or git
    /// fails. Sorted; head branch first if detectable. Cheap enough to call per typed key
    /// — the view-model caches the result anyway.
    public func listBranches(repo: String) -> [String] {
        let repoPath = reposRoot.appendingPathComponent(repo)
        guard fm.fileExists(atPath: repoPath.path) else { return [] }
        let r = runner.run("/usr/bin/env",
                           ["git", "for-each-ref", "--format=%(refname:short)", "refs/heads/"],
                           repoPath.path)
        guard r.status == 0 else { return [] }
        return r.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
            .sorted()
    }

    /// Direct-child folder names under reposRoot, sorted. Skips dotfiles and non-dirs.
    public func listAvailableRepos() -> [String] {
        guard let entries = try? fm.contentsOfDirectory(at: reposRoot,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])
        else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.lastPathComponent }
            .sorted()
    }

    // MARK: Create

    public enum RepoResult: Equatable {
        /// Worktree added. `createdBranch` true → new branch off `base`; false → attached existing.
        case success(branch: String, createdBranch: Bool, base: String?)
        case failed(message: String)
    }

    public struct Outcome {
        public let projectRoot: URL
        public let repos: [(spec: RepoSpec, result: RepoResult)]
        public var allSucceeded: Bool {
            repos.allSatisfy { if case .success = $0.result { return true } else { return false } }
        }
    }

    public enum CreateError: Error, Equatable {
        case invalidName(NameValidation)
        case templateMissing(URL)
        case copyFailed(String)
        case tokenReplaceFailed(String)
    }

    /// Creates the project root + template + per-repo worktrees. Best-effort across repos:
    /// each worktree is attempted independently; the project root is NOT rolled back on
    /// per-repo failures.
    public func create(name: String, repos: [RepoSpec]) throws -> Outcome {
        let nameStatus = validateName(name)
        guard nameStatus == .ok else { throw CreateError.invalidName(nameStatus) }
        guard fm.fileExists(atPath: templateDir.path) else {
            throw CreateError.templateMissing(templateDir)
        }

        let projectRoot = projectsRoot.appendingPathComponent(name)
        do {
            try fm.copyItem(at: templateDir, to: projectRoot)
        } catch {
            throw CreateError.copyFailed("\(error)")
        }

        let projectMd = projectRoot.appendingPathComponent("PROJECT.md")
        if fm.fileExists(atPath: projectMd.path) {
            do {
                let original = try String(contentsOf: projectMd, encoding: .utf8)
                let replaced = original.replacingOccurrences(of: "<project-name>", with: name)
                try replaced.write(to: projectMd, atomically: true, encoding: .utf8)
            } catch {
                throw CreateError.tokenReplaceFailed("\(error)")
            }
        }

        let results: [(spec: RepoSpec, result: RepoResult)] = repos.map { spec in
            (spec, attachWorktree(spec: spec, projectRoot: projectRoot))
        }
        return Outcome(projectRoot: projectRoot, repos: results)
    }

    // MARK: Worktree

    private func attachWorktree(spec: RepoSpec, projectRoot: URL) -> RepoResult {
        let repoPath = reposRoot.appendingPathComponent(spec.repo)
        guard fm.fileExists(atPath: repoPath.path) else {
            return .failed(message: "repo not found at \(repoPath.path)")
        }

        let targetDir = projectRoot
            .appendingPathComponent(spec.repo)
            .appendingPathComponent(spec.branch)
        do {
            try fm.createDirectory(at: targetDir.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
        } catch {
            return .failed(message: "couldn't prepare \(targetDir.deletingLastPathComponent().path): \(error)")
        }

        let branchExists = runner.run("/usr/bin/env",
                                      ["git", "rev-parse", "--verify", "--quiet", spec.branch],
                                      repoPath.path).status == 0

        if branchExists {
            let r = runner.run("/usr/bin/env",
                               ["git", "worktree", "add", targetDir.path, spec.branch],
                               repoPath.path)
            if r.status == 0 {
                return .success(branch: spec.branch, createdBranch: false, base: nil)
            }
            return .failed(message: errMsg(r))
        }

        guard let base = pickBase(repoPath: repoPath) else {
            return .failed(message: "no master or main branch found to base \(spec.branch) on")
        }
        let r = runner.run("/usr/bin/env",
                           ["git", "worktree", "add", "-b", spec.branch, targetDir.path, base],
                           repoPath.path)
        if r.status == 0 {
            return .success(branch: spec.branch, createdBranch: true, base: base)
        }
        return .failed(message: errMsg(r))
    }

    /// Prefer `master` (most BrowserStack-internal repos), fall back to `main`.
    private func pickBase(repoPath: URL) -> String? {
        for cand in ["master", "main"] {
            let r = runner.run("/usr/bin/env",
                               ["git", "rev-parse", "--verify", "--quiet", cand],
                               repoPath.path)
            if r.status == 0 { return cand }
        }
        return nil
    }

    private func errMsg(_ r: ProcessRunner.Result) -> String {
        let s = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "git exited \(r.status)" : s
    }
}

// MARK: Process runner

/// Thin seam over `Process` so tests can stub git invocations.
public struct ProcessRunner {
    public struct Result: Equatable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public init(status: Int32, stdout: String = "", stderr: String = "") {
            self.status = status; self.stdout = stdout; self.stderr = stderr
        }
    }

    public let run: (_ executable: String, _ args: [String], _ cwd: String?) -> Result

    public init(run: @escaping (String, [String], String?) -> Result) {
        self.run = run
    }

    public static let system = ProcessRunner { executable, args, cwd in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch {
            return Result(status: -1, stderr: "\(error)")
        }
        p.waitUntilExit()
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Result(status: p.terminationStatus, stdout: out, stderr: err)
    }
}
