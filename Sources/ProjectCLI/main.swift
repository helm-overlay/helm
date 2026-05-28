import Foundation
import HelmCore

// MARK: ANSI helpers

func computeUseColor() -> Bool {
    if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
    return isatty(1) != 0  // 1 = stdout
}
let useColor: Bool = computeUseColor()

func ansi(_ code: String, _ s: String) -> String {
    useColor ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
}
func bold(_ s: String) -> String   { ansi("1", s) }
func dim(_ s: String) -> String    { ansi("2", s) }
func red(_ s: String) -> String    { ansi("31", s) }
func green(_ s: String) -> String  { ansi("32", s) }
func cyan(_ s: String) -> String   { ansi("36", s) }

// MARK: Self-introspection

/// The absolute path to the running binary, resolving any symlinks in the path.
/// `_NSGetExecutablePath` is the canonical way to ask the dynamic linker rather
/// than relying on `CommandLine.arguments[0]`, which is whatever string the
/// shell happened to invoke us by (often a bare name when run via $PATH).
func runningBinaryPath() -> URL {
    var size: UInt32 = 1024
    var buf = [CChar](repeating: 0, count: Int(size))
    if _NSGetExecutablePath(&buf, &size) != 0 {
        buf = [CChar](repeating: 0, count: Int(size))
        _ = _NSGetExecutablePath(&buf, &size)
    }
    let raw = String(cString: buf)
    return URL(fileURLWithPath: raw).resolvingSymlinksInPath()
}

// MARK: I/O

func writeErr(_ s: String) {
    if let data = s.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

func die(_ msg: String, code: Int32 = 1) -> Never {
    writeErr("\(red("error:")) \(msg)\n")
    exit(code)
}

func info(_ msg: String) { print("\(cyan("→")) \(msg)") }
func ok(_ msg: String)   { print("  \(green("✓")) \(msg)") }

// MARK: Help

let helpEpilog = """
examples:
  project new helm-redesign           Create a new project from template
  project add helm bug-fix            Add helm@bug-fix as a worktree (bare name)
  project add helm                    Same, branch defaults to the project name
  project add ~/some/checkout fix     Same, by path
  project ls                          List worktrees in current project
                                      (or all projects if outside)
  project ls -a                       Always list all projects
  project show                        Print project summary + worktree tree
  project rm helm/bug-fix             Remove a worktree (refuses if dirty)
  project rm                          Remove the worktree you're in
  project sync                        Resync .claude/ symlinks into cwd

bare-name repo lookup searches:
  1. <current-project>/<name>         (sibling already in this project)
  2. ~/Home/dev/repos/<name>          (BrowserStack repos)
  3. ~/Home/dev/utils/<name>          (personal / utility repos)

layout:
  ~/projects/<project>/<repo>/<branch>/   ← each worktree
  ~/projects/<project>/PROJECT.md         ← the brief, auto-loads in every chat
  ~/projects/.template/                   ← seed for `project new`
"""

let topHelp = """
usage: project <command> [args]

\(bold("commands:"))
  new <name>                 create a new project from template
  add <repo> [<branch>]      add a repo+branch as a worktree (branch defaults to project name)
  ls [-a]                    list worktrees (or all projects if outside)
  show                       print current project's summary
  rm [<repo>/<branch>] [-f]  remove a worktree
  sync [<path>]              resync .claude/ symlinks into a worktree
  install-cli                symlink this binary into ~/.local/bin
  where                      show which build is active on $PATH
  help                       this message
  version                    print version

\(helpEpilog)
"""

// MARK: Shared

let mgr = ProjectManager()

func requireProjectRoot() -> URL {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    if let root = mgr.findProjectRoot(from: cwd) { return root }

    var msg = "not inside a project (no PROJECT.md ancestor of \(cwd.path))"
    let existing = mgr.listProjects().map(\.name)
    if existing.isEmpty {
        msg += "\n\nno projects yet. try `project new <name>`."
    } else {
        msg += "\n\nexisting projects under ~/projects/:\n  "
            + existing.joined(separator: "\n  ")
            + "\n\ntry `cd ~/projects/<name>` or `project new <name>`."
    }
    die(msg)
}

// MARK: new

func cmdNew(_ args: [String]) {
    guard let name = args.first, args.count == 1 else {
        die("usage: project new <name>")
    }
    let syntax = ProjectCreator.validateNameSyntax(name)
    if syntax != .ok {
        die("invalid project name '\(name)': \(describeNameError(syntax))")
    }
    let target = mgr.projectsRoot.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: target.path) {
        die("project '\(name)' already exists at \(target.path)")
    }

    info("creating project \(bold(name)) at \(target.path)")
    switch mgr.newProject(name: name) {
    case .success(let created):
        ok("copied template")
        let pmd = created.appendingPathComponent("PROJECT.md")
        if (try? String(contentsOf: pmd, encoding: .utf8))?.contains("# \(name)") == true {
            ok("set PROJECT.md heading")
        }
        print()
        print("next:  cd \(created.path)")
        print("       edit PROJECT.md (fill in 'What this project is')")
        print("       project add <repo> <branch>")
    case .failure(.alreadyExists(let url)):
        die("project '\(name)' already exists at \(url.path)")
    case .failure(.invalidName(let v)):
        die("invalid name: \(describeNameError(v))")
    case .failure(.templateMissing(let url)):
        die("template not found at \(url.path) — copy or create ~/projects/.template/ first")
    case .failure(.copyFailed(let msg)):
        die("copy failed: \(msg)")
    case .failure(.tokenReplaceFailed(let msg)):
        die("token replace failed: \(msg)")
    }
}

func describeNameError(_ v: ProjectCreator.NameValidation) -> String {
    switch v {
    case .ok: return "ok"
    case .empty: return "name is empty"
    case .notKebabCase: return "name must be lowercase kebab-case (letters, digits, hyphens; start with letter/digit; no leading/trailing/double hyphen)"
    case .collides: return "directory already exists"
    }
}

// MARK: add

func cmdAdd(_ args: [String]) {
    guard args.count == 1 || args.count == 2 else { die("usage: project add <repo> [<branch>]") }
    let repoArg = args[0]

    let projectRoot = requireProjectRoot()
    let branch = args.count == 2 ? args[1] : projectRoot.lastPathComponent
    if branch.contains("/") { die("branch name '\(branch)' may not contain '/'") }

    let resolution: ProjectManager.RepoResolution
    switch mgr.resolveRepo(repoArg, projectRoot: projectRoot) {
    case .success(let r):
        resolution = r
    case .failure(.pathNotFound(let arg)):
        die("source path '\(arg)' not found")
    case .failure(.pathNotGitWorkingTree(let url)):
        die("\(url.path) is not a git working tree")
    case .failure(.nameNotFound(let name, let searched)):
        let lines = searched.map { "  \($0.path)" }.joined(separator: "\n")
        die("repo '\(name)' not found. Searched:\n\(lines)\n\nPass an absolute path if the repo lives elsewhere.")
    }

    let target = projectRoot
        .appendingPathComponent(resolution.repoDirName)
        .appendingPathComponent(branch)

    info("adding \(bold("\(resolution.repoDirName)/\(branch)")) to project \(bold(projectRoot.lastPathComponent))")
    print("  source: \(resolution.sourcePath.path)")
    print("  target: \(target.path)")

    switch mgr.addWorktree(source: resolution.sourcePath, target: target, branch: branch) {
    case .success(let r):
        if r.attachedExisting {
            ok("branch '\(branch)' exists in source — attached")
        } else if let base = r.base {
            ok("branch '\(branch)' is new — created off \(base)")
        }
    case .failure(.targetAlreadyExists(let url)):
        die("target \(url.path) already exists")
    case .failure(.noBaseBranch):
        die("no master or main branch in \(resolution.sourcePath.path) to base '\(branch)' on")
    case .failure(.sourceNotGitWorkingTree(let url)):
        die("\(url.path) is not a git working tree")
    case .failure(.gitFailed(let msg)):
        die(msg)
    }

    for f in mgr.copyEnvFiles(from: resolution.sourcePath, to: target) { ok("copied \(f)") }
    for l in mgr.symlinkClaude(from: resolution.sourcePath, to: target) { ok("symlinked .claude/\(l)") }

    print()
    print("next:  cd \(target.path)")
}

// MARK: rm

func cmdRm(_ args: [String]) {
    var force = false
    var target: String? = nil
    for a in args {
        if a == "-f" || a == "--force" { force = true }
        else if target == nil { target = a }
        else { die("usage: project rm [<repo>/<branch>] [-f]") }
    }

    let projectRoot = requireProjectRoot()
    let worktreePath: URL

    if let target = target {
        guard target.contains("/") else { die("rm target '\(target)' must be <repo>/<branch>") }
        let parts = target.split(separator: "/", maxSplits: 1).map(String.init)
        worktreePath = projectRoot.appendingPathComponent(parts[0]).appendingPathComponent(parts[1])
    } else {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
        let rel = String(cwd.path.dropFirst(projectRoot.path.count).drop(while: { $0 == "/" }))
        let parts = rel.split(separator: "/").map(String.init)
        if parts.count < 2 {
            die("rm with no argument requires cwd inside a worktree (expected <repo>/<branch>)")
        }
        worktreePath = projectRoot.appendingPathComponent(parts[0]).appendingPathComponent(parts[1])
    }

    if !FileManager.default.fileExists(atPath: worktreePath.path) {
        die("\(worktreePath.path) does not exist")
    }

    info("removing worktree \(bold(worktreePath.path))")
    switch mgr.removeWorktree(target: worktreePath, force: force) {
    case .success:
        ok("done")
    case .failure(.notAWorktree(let url)):
        die("\(url.path) is not a git working tree (refusing to remove)")
    case .failure(.dirty(let files)):
        let preview = files.prefix(5).joined(separator: "\n  ")
        die("worktree has uncommitted changes:\n  \(preview)\n\nCommit/stash first or rerun with --force.")
    case .failure(.unpushed(let commits)):
        let preview = commits.prefix(5).joined(separator: "\n  ")
        die("worktree has unpushed commits:\n  \(preview)\n\nPush first or rerun with --force.")
    case .failure(.gitFailed(let msg)):
        die(msg)
    }
}

// MARK: ls / show

func renderWorktrees(_ wts: [ProjectManager.WorktreeSummary]) {
    var lastRepo: String? = nil
    for w in wts {
        if w.repo != lastRepo {
            if lastRepo != nil { print() }
            print("  \(bold("\(w.repo)/"))")
            lastRepo = w.repo
        }
        let commit = w.lastCommit ?? "(no commits)"
        let paddedBranch = w.branch.padding(toLength: max(w.branch.count, 25), withPad: " ", startingAt: 0)
        print("    \(paddedBranch)  \(dim(commit))")
    }
}

func cmdLs(_ args: [String]) {
    let listAll = args.contains("-a") || args.contains("--all")
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    if listAll || mgr.findProjectRoot(from: cwd) == nil {
        let projects = mgr.listProjects()
        if projects.isEmpty {
            print("no projects under \(mgr.projectsRoot.path)")
            print("try \(bold("project new <name>"))")
            return
        }
        print("\(bold("projects")) in \(mgr.projectsRoot.path):\n")
        for p in projects {
            let tag = p.tagline.map { $0.prefix(80) } ?? ""
            let padded = p.name.padding(toLength: max(p.name.count, 30), withPad: " ", startingAt: 0)
            print("  \(bold(padded))  \(dim(String(tag)))")
        }
        return
    }

    let root = requireProjectRoot()
    print("\(bold("project"))  \(root.lastPathComponent)  \(dim("(\(root.path))"))\n")
    let wts = mgr.listWorktrees(in: root)
    if wts.isEmpty {
        print("  \(dim("no worktrees yet — `project add <repo> <branch>` to add one"))")
    } else {
        renderWorktrees(wts)
    }
}

func cmdShow(_ args: [String]) {
    let root = requireProjectRoot()
    print("\(bold("project"))  \(root.lastPathComponent)")
    print("\(bold("path"))     \(root.path)\n")
    let pmd = root.appendingPathComponent("PROJECT.md")
    if let text = try? String(contentsOf: pmd, encoding: .utf8) {
        var emitted = 0
        var seenH2 = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("## ") {
                if seenH2 { break }
                seenH2 = true
            }
            print(line)
            emitted += 1
            if emitted > 40 {
                print(dim("    … (more in PROJECT.md)"))
                break
            }
        }
        print()
    }
    print("\(bold("worktrees")):")
    let wts = mgr.listWorktrees(in: root)
    if wts.isEmpty {
        print("  \(dim("(none)"))")
    } else {
        renderWorktrees(wts)
    }
}

// MARK: sync

func cmdSync(_ args: [String]) {
    let target: URL
    if let path = args.first {
        target = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath()
    } else {
        target = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
    }
    if !mgr.isWorkingTree(target) {
        die("\(target.path) is not a git working tree")
    }
    guard let source = mgr.sourceRepo(for: target) else {
        die("could not locate source repo")
    }
    if source == target { die("\(target.path) IS the source repo — nothing to sync") }
    info("syncing .claude/ from \(source.path) → \(target.path)")
    for l in mgr.symlinkClaude(from: source, to: target) { ok("symlinked .claude/\(l)") }
    for f in mgr.copyEnvFiles(from: source, to: target) { ok("copied \(f)") }
    ok("done")
}

// MARK: where

func cmdWhere(_ args: [String]) {
    let home = NSHomeDirectory()
    let symlink = URL(fileURLWithPath: home).appendingPathComponent(".local/bin/project")
    let me = runningBinaryPath()
    print("\(bold("running:"))    \(me.path)")
    if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: symlink.path) {
        let resolved = URL(fileURLWithPath: dest).resolvingSymlinksInPath()
        print("\(bold("$PATH link:"))  \(symlink.path)")
        print("              → \(resolved.path)")
        if resolved == me {
            print("\n\(green("active build matches the one on $PATH."))")
        } else {
            print("\n\(cyan("note:"))  the binary on $PATH is a different build.")
            print("       run `\(me.path) install-cli` to switch.")
        }
    } else if FileManager.default.fileExists(atPath: symlink.path) {
        print("\(bold("$PATH file:"))  \(symlink.path)  \(dim("(not a symlink)"))")
    } else {
        print("\(bold("$PATH link:"))  \(symlink.path)  \(red("(missing)"))")
        print("\nrun `\(me.path) install-cli` to symlink onto $PATH.")
    }
    if let bundled = bundledHelmAppCLI() {
        print("\(bold("Helm.app:"))    \(bundled.path)")
    }
}

/// Returns the bundled `project` binary inside Helm.app under /Applications, if present.
func bundledHelmAppCLI() -> URL? {
    let candidates = [
        "/Applications/Helm.app/Contents/MacOS/project",
        "\(NSHomeDirectory())/Applications/Helm.app/Contents/MacOS/project",
    ]
    for c in candidates {
        if FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
    }
    return nil
}

// MARK: install-cli

func cmdInstallCLI(_ args: [String]) {
    let me = runningBinaryPath()
    let home = NSHomeDirectory()
    let dst = URL(fileURLWithPath: home)
        .appendingPathComponent(".local/bin/project")
    let dstDir = dst.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
    } catch {
        die("could not create \(dstDir.path): \(error)")
    }
    if FileManager.default.fileExists(atPath: dst.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: dst.path)) != nil {
        info("removing existing \(dst.path)")
        try? FileManager.default.removeItem(at: dst)
    }
    do {
        try FileManager.default.createSymbolicLink(at: dst, withDestinationURL: me)
        ok("symlinked \(dst.path) → \(me.path)")
    } catch {
        die("could not symlink: \(error)")
    }
    print()
    print("test it:  \(bold("project --help"))")
    print("(make sure \(dstDir.path) is on your PATH)")
}

// MARK: dispatch

let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty {
    print(topHelp)
    exit(0)
}

switch args[0] {
case "new":         cmdNew(Array(args.dropFirst()))
case "add":         cmdAdd(Array(args.dropFirst()))
case "rm":          cmdRm(Array(args.dropFirst()))
case "ls":          cmdLs(Array(args.dropFirst()))
case "show":        cmdShow(Array(args.dropFirst()))
case "sync":        cmdSync(Array(args.dropFirst()))
case "install-cli": cmdInstallCLI(Array(args.dropFirst()))
case "where":       cmdWhere(Array(args.dropFirst()))
case "help", "--help", "-h":
    print(topHelp)
case "version", "--version":
    print("project (Helm CLI) 0.1")
default:
    writeErr("\(red("error:"))  unknown command '\(args[0])'\n\n")
    writeErr(topHelp + "\n")
    exit(2)
}
