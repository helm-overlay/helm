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
      helm init claude   Install the Claude Code hooks plugin
      helm init pi       Install the Pi extension

    Run `helm init claude`, then restart Claude Code so the plugin loads.
    Run `helm init pi`, then restart Pi so the extension reloads.
    """)
}

/// Pull `--home <dir>` out of the args (defaulting to the real home). External plugin
/// installation only supports the real home; callers using --home get a clear error.
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
        installPi(home: home)
    default:
        fail("helm init: unknown agent '\(agent)'. Supported: claude, pi.")
    }
}

let piPluginSource = "git:github.com/helm-overlay/pi-plugin"
let claudePluginSource = "https://github.com/helm-overlay/claude-plugin.git"

func installClaude(home: String) {
    guard home == NSHomeDirectory() else {
        fail("helm init claude: --home is not supported when installing external plugins")
    }

    let pluginDir = URL(fileURLWithPath: home).appendingPathComponent(".claude/skills/helm")
    try? FileManager.default.createDirectory(at: pluginDir.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: pluginDir)

    let result = runCommand("git", ["clone", "--depth", "1", claudePluginSource, pluginDir.path])
    guard result.ok else {
        fail("""
        helm init claude: could not clone \(claudePluginSource) into \(pluginDir.path).
        \(result.output)

        Install manually with:
        git clone --depth 1 \(claudePluginSource) \(pluginDir.path)
        """)
    }

    let stateDir = URL(fileURLWithPath: home).appendingPathComponent(".helm/claude/state")
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    let settings = URL(fileURLWithPath: home).appendingPathComponent(".claude/settings.json")

    print("✓ Installed the Helm Claude plugin")
    print("  plugin:     \(pluginDir.path)")
    print("  source:     \(claudePluginSource)")
    print("  hooks:      SessionStart · UserPromptSubmit · PreToolUse(AskUserQuestion) · PostToolUse(AskUserQuestion) · Stop · SessionEnd")
    print("  writes:     \(stateDir.path)/<sessionId>.json")
    print("")
    print("→ Restart Claude Code (or start a new session) so it auto-loads from ~/.claude/skills/helm.")

    if settingsReferencesHelmState(settings) {
        print("")
        print("⚠ \(settings.path) still has hand-rolled hooks writing ~/.helm/claude/state.")
        print("  Remove those entries so the classifier doesn't run twice per turn.")
    }
}

func installPi(home: String) {
    guard home == NSHomeDirectory() else {
        fail("helm init pi: --home is not supported when installing external plugins")
    }

    let result = runCommand("pi", ["install", piPluginSource])
    guard result.ok else {
        fail("""
        helm init pi: `pi install \(piPluginSource)` failed.
        \(result.output)

        Install manually with:
        pi install \(piPluginSource)
        """)
    }

    let stateDir = URL(fileURLWithPath: home).appendingPathComponent(".helm/pi/state")
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

    print("✓ Installed the Helm Pi extension")
    print("  source:     \(piPluginSource)")
    print("  hooks:      session_start · before_agent_start · agent_start · agent_end")
    print("  writes:     \(stateDir.path)/<sessionId>.json")
    print("")
    print("→ Restart Pi (or start a new session) so the extension reloads.")
}

func settingsReferencesHelmState(_ url: URL) -> Bool {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
    return text.contains(".helm/claude/state")
}

func runCommand(_ executable: String, _ arguments: [String]) -> (ok: Bool, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = [executable] + arguments
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (false, error.localizedDescription) }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (p.terminationStatus == 0, output)
}

