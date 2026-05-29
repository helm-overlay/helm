import AppKit
import HelmCore

/// Opens chats in the user's configured terminal (default: Apple Terminal) via AppleScript.
enum TerminalDispatcher {
    /// Resume a session. For a live row (`pid` set) whose process still owns a terminal
    /// tab, focus that tab instead of spawning a fresh `claude --resume`.
    static func resume(_ session: ChatSession) {
        if let pid = session.pid, let tty = ttyForPID(pid), focusTab(tty: tty) {
            return
        }
        let dir = session.cwd.nonEmpty ?? NSHomeDirectory()
        switch session.agent {
        case .claude:
            run("cd \(shellQuote(dir)) && claude --resume \(shellQuote(session.sessionId))")
        case .pi:
            let target = session.transcriptPath ?? session.sessionId
            run("cd \(shellQuote(dir)) && pi --session \(shellQuote(target))")
        }
    }

    static func resume(sessionId: String, cwd: String?, pid: Int32? = nil) {
        let dir = cwd?.nonEmpty ?? NSHomeDirectory()
        resume(ChatSession(sessionId: sessionId, cwd: dir, project: "Other", label: sessionId,
                           state: pid == nil ? .cold : .liveIdle, kind: nil, pid: pid,
                           lastActive: Date()))
    }

    static func newChat(cwd: String, agent: AgentKind = HelmConfig.load().defaultAgent) {
        switch agent {
        case .claude: run("cd \(shellQuote(cwd)) && claude")
        case .pi: run("cd \(shellQuote(cwd)) && pi")
        }
    }

    /// Close the terminal pane whose session owns `pid`'s controlling tty. No-op for a
    /// process with no tty (e.g. a background session). Resolve the tty before the caller
    /// kills the process, or `ps` will have nothing to report.
    static func closePane(pid: Int32) {
        guard let tty = ttyForPID(pid) else { return }
        let kind = HelmConfig.load().terminal
        let script: String
        switch kind {
        case .iterm:
            script = """
            tell application "iTerm"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is \(appleScriptString(tty)) then
                                tell s to close
                                return "1"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "0"
            """
        case .terminal:
            // Terminal.app can't close a single tab via AppleScript; close its window.
            script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is \(appleScriptString(tty)) then
                            close w
                            return "1"
                        end if
                    end repeat
                end repeat
            end tell
            return "0"
            """
        }
        _ = runAppleScript(script)
    }

    // MARK: Internals

    /// Launch `command` in a new tab of the frontmost window (or a new window if none).
    private static func run(_ command: String) {
        let kind = HelmConfig.load().terminal
        let script: String
        switch kind {
        case .iterm:
            script = """
            tell application "iTerm"
                activate
                if (count of windows) = 0 then
                    set w to (create window with default profile)
                else
                    set w to current window
                    tell w to create tab with default profile
                end if
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
        _ = runAppleScript(script)
    }

    /// Select and front the existing tab whose session owns `tty`. Returns false if none.
    private static func focusTab(tty: String) -> Bool {
        let kind = HelmConfig.load().terminal
        let script: String
        switch kind {
        case .iterm:
            script = """
            tell application "iTerm"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is \(appleScriptString(tty)) then
                                tell w to select
                                tell t to select
                                tell s to select
                                activate
                                return "1"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "0"
            """
        case .terminal:
            script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is \(appleScriptString(tty)) then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return "1"
                        end if
                    end repeat
                end repeat
            end tell
            return "0"
            """
        }
        return runAppleScript(script) == "1"
    }

    /// Controlling terminal of `pid`, as a `/dev/ttysNNN` path; nil if the process has none.
    private static func ttyForPID(_ pid: Int32) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-o", "tty=", "-p", String(pid)]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "??", name != "?" else { return nil }
        return "/dev/" + name
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error { NSLog("Helm: AppleScript dispatch failed: \(error)") }
        return result.stringValue
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
