import Foundation

/// Writes to the task vault. Shells out to `set-status.py` rather than rewriting
/// frontmatter in Swift — that script also owns the `wip_since` / `done_at`
/// bookkeeping and is shared with the MCP server, so keeping one implementation
/// avoids two drifting copies of the rules.
public struct TaskMutator {
    public let scriptPath: URL

    /// Default location after the script move (phase 2 of the migration). Falls
    /// back to the legacy widget path so we work today.
    public init(scriptPath: URL? = nil, home: String = NSHomeDirectory()) {
        if let p = scriptPath { self.scriptPath = p; return }
        let fm = FileManager.default
        let newPath = URL(fileURLWithPath: home).appendingPathComponent("Home/task-vault/_bin/set-status.py")
        let widgetPath = URL(fileURLWithPath: home).appendingPathComponent(
            "Library/Application Support/Übersicht/widgets/task-vault.widget/set-status.py")
        self.scriptPath = fm.fileExists(atPath: newPath.path) ? newPath : widgetPath
    }

    public enum SetStatusError: Error, Equatable {
        case scriptMissing(path: String)
        case nonzeroExit(code: Int32, stderr: String)
    }

    /// Apply `next` to the task at `<vault>/tasks/<basename>.md`. Synchronous —
    /// call from a background queue. Returns after the markdown file is on disk.
    public func setStatus(basename: String, to next: TaskStatus) throws {
        guard FileManager.default.fileExists(atPath: scriptPath.path) else {
            throw SetStatusError.scriptMissing(path: scriptPath.path)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", scriptPath.path, basename, next.rawValue]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()    // discard
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw SetStatusError.nonzeroExit(code: p.terminationStatus, stderr: msg)
        }
    }
}
