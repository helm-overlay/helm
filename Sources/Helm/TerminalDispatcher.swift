import AppKit
import HelmCore

/// Opens chats in the user's configured terminal (default: Apple Terminal) via AppleScript.
enum TerminalDispatcher {
    static func resume(sessionId: String, cwd: String?) {
        let dir = cwd?.nonEmpty ?? NSHomeDirectory()
        run("cd \(shellQuote(dir)) && claude --resume \(shellQuote(sessionId))")
    }

    static func newChat(cwd: String) {
        run("cd \(shellQuote(cwd)) && claude")
    }

    // MARK: Internals

    private static func run(_ command: String) {
        let kind = HelmConfig.load().terminal
        let script: String
        switch kind {
        case .iterm:
            script = """
            tell application "iTerm"
                activate
                set w to (create window with default profile)
                tell current session of w to write text \(appleScriptString(command))
            end tell
            """
        case .terminal:
            script = """
            tell application "Terminal"
                activate
                do script \(appleScriptString(command))
            end tell
            """
        }
        runAppleScript(script)
    }

    private static func runAppleScript(_ source: String) {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return }
        script.executeAndReturnError(&error)
        if let error { NSLog("Helm: AppleScript dispatch failed: \(error)") }
    }

    /// Single-quote for POSIX shell: wrap in '...' and escape embedded quotes.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Double-quoted AppleScript string literal.
    private static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                 .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
