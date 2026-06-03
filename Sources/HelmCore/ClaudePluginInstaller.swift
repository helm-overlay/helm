import Foundation

/// Writes the `helm` Claude plugin to disk and reports what the caller should tell the user.
public enum ClaudePluginInstaller {
    public struct Report {
        public let pluginDir: String
        public let filesWritten: [String]
        public let stateDir: String
        /// True when `~/.claude/settings.json` already wires hooks at `~/.helm/claude/state` —
        /// the hand-rolled set the plugin now supersedes, which the user should remove so
        /// the classifier doesn't run twice per Stop.
        public let legacyHooksInSettings: Bool
        public let settingsPath: String
    }

    /// Materialize the plugin under `~/.claude/skills/helm`, (re)writing every file so a
    /// re-run picks up template changes. Also ensures `~/.helm/claude/state` exists.
    @discardableResult
    public static func install(home: String = NSHomeDirectory(),
                               author: (name: String, email: String)? = nil) throws -> Report {
        let fm = FileManager.default
        let dir = ClaudeHooksPlugin.pluginDir(home: home)
        let files = ClaudeHooksPlugin.files(home: home, author: author)

        var written: [String] = []
        for f in files {
            let url = dir.appendingPathComponent(f.relativePath)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try f.contents.write(to: url, atomically: true, encoding: .utf8)
            if f.isExecutable {
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            written.append(f.relativePath)
        }

        let stateDir = SessionStore.stateDir(home: home)
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)

        let settings = URL(fileURLWithPath: home).appendingPathComponent(".claude/settings.json")
        return Report(
            pluginDir: dir.path,
            filesWritten: written,
            stateDir: stateDir.path,
            legacyHooksInSettings: settingsReferencesHelmState(settings),
            settingsPath: settings.path)
    }

    /// Cheap detection: does `settings.json` mention the Helm Claude state dir at all? A
    /// substring check is enough to decide whether to print the cleanup note — we never edit the file.
    public static func settingsReferencesHelmState(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains(".helm/claude/state")
    }
}
