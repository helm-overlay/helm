import Foundation
import HelmCore

// `helm` — Helm's command-line companion. Today its job is setup: installing the hooks
// each agent needs so the overlay can track session state. The overlay itself is the app.

let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func printUsage() {
    print("""
    helm — session-overlay setup

    Usage:
      helm init claude [--home <dir>]   Install the Claude Code hooks plugin
      helm init pi                      (not yet) Install the Pi extension

    Run `helm init claude`, then restart Claude Code so the plugin loads.
    """)
}

/// Pull `--home <dir>` out of the args (defaulting to the real home). Lets the install
/// target a sandbox in tests, since NSHomeDirectory() ignores $HOME on macOS.
func takeHome(_ args: inout [String]) -> String {
    guard let i = args.firstIndex(of: "--home") else { return NSHomeDirectory() }
    guard i + 1 < args.count else { fail("--home needs a directory") }
    let dir = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return dir
}

switch args.first {
case "init":
    runInit(Array(args.dropFirst()))
case nil, "-h", "--help", "help":
    printUsage()
default:
    fail("helm: unknown command '\(args[0])'. Try `helm --help`.")
}

func runInit(_ rest: [String]) {
    var rest = rest
    let home = takeHome(&rest)
    guard let agent = rest.first else {
        fail("helm init: which agent? Try `helm init claude`.")
    }
    switch agent {
    case "claude":
        installClaude(home: home)
    case "pi":
        fail("helm init pi: not implemented yet — Pi extension setup is still manual.")
    default:
        fail("helm init: unknown agent '\(agent)'. Supported: claude.")
    }
}

func installClaude(home: String) {
    let author = gitAuthor()
    let report: ClaudePluginInstaller.Report
    do {
        report = try ClaudePluginInstaller.install(home: home, author: author)
    } catch {
        fail("helm init claude: could not write the plugin — \(error.localizedDescription)")
    }

    print("✓ Installed the Helm hooks plugin")
    print("  plugin:     \(report.pluginDir)")
    print("  hooks:      SessionStart · UserPromptSubmit · PreToolUse(AskUserQuestion) · PostToolUse(AskUserQuestion) · Stop · SessionEnd")
    print("  writes:     \(report.stateDir)/<sessionId>.json")
    print("")
    print("→ Restart Claude Code (or start a new session) so the plugin auto-loads as `helm@skills-dir`.")

    if report.legacyHooksInSettings {
        print("")
        print("⚠ \(report.settingsPath) still has hand-rolled hooks writing ~/.helm/state.")
        print("  The plugin now owns these. Remove the Stop / UserPromptSubmit / SessionEnd")
        print("  entries that touch ~/.helm/state from settings.json so the classifier")
        print("  doesn't run twice per turn. (Left untouched — edit it yourself.)")
    }
}

/// Best-effort author stamp for the generated plugin.json. Missing git config → omitted.
func gitAuthor() -> (name: String, email: String)? {
    func config(_ key: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "config", "--get", key]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }
    guard let name = config("user.name"), let email = config("user.email") else { return nil }
    return (name, email)
}
