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
    /// per-repo failures. Delegates to ProjectManager so the UI and the CLI share logic.
    public func create(name: String, repos: [RepoSpec]) throws -> Outcome {
        // Collision check before delegating, to preserve the `.collides` semantic surfaced to the UI.
        let nameStatus = validateName(name)
        guard nameStatus == .ok else { throw CreateError.invalidName(nameStatus) }

        let mgr = ProjectManager(home: home,
                                 projectsRoot: projectsRoot,
                                 templateDir: templateDir,
                                 repoRoots: [reposRoot],
                                 runner: runner,
                                 fm: fm)

        let projectRoot: URL
        switch mgr.newProject(name: name) {
        case .success(let url):
            projectRoot = url
        case .failure(.invalidName(let v)):
            throw CreateError.invalidName(v)
        case .failure(.templateMissing(let url)):
            throw CreateError.templateMissing(url)
        case .failure(.alreadyExists):
            throw CreateError.invalidName(.collides)
        case .failure(.copyFailed(let msg)):
            throw CreateError.copyFailed(msg)
        case .failure(.tokenReplaceFailed(let msg)):
            throw CreateError.tokenReplaceFailed(msg)
        }

        let results: [(spec: RepoSpec, result: RepoResult)] = repos.map { spec in
            let target = projectRoot
                .appendingPathComponent(spec.repo)
                .appendingPathComponent(spec.branch)
            let source = reposRoot.appendingPathComponent(spec.repo)
            guard fm.fileExists(atPath: source.path) else {
                return (spec, .failed(message: "repo not found at \(source.path)"))
            }
            switch mgr.addWorktree(source: source, target: target, branch: spec.branch) {
            case .success(let r):
                return (spec, .success(branch: spec.branch,
                                       createdBranch: !r.attachedExisting,
                                       base: r.base))
            case .failure(.noBaseBranch):
                return (spec, .failed(message: "no master or main branch found to base \(spec.branch) on"))
            case .failure(.gitFailed(let msg)):
                return (spec, .failed(message: msg))
            case .failure(.targetAlreadyExists(let url)):
                return (spec, .failed(message: "target already exists at \(url.path)"))
            case .failure(.sourceNotGitWorkingTree(let url)):
                return (spec, .failed(message: "source is not a git working tree: \(url.path)"))
            }
        }
        return Outcome(projectRoot: projectRoot, repos: results)
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
