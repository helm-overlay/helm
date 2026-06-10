import Foundation

/// Which terminal Helm dispatches chats into. Add cases as more are supported.
public enum TerminalKind: String, Equatable, CaseIterable {
    case terminal   // Apple Terminal.app — the macOS default
    case iterm      // iTerm2

    /// Default when no config file is present: the stock macOS terminal.
    public static let `default`: TerminalKind = .terminal

    public init(parsing raw: String?) {
        switch raw?.lowercased() {
        case "iterm", "iterm2":              self = .iterm
        case "terminal", "terminal.app", "apple": self = .terminal
        default:                             self = .default
        }
    }

    /// The .app name used to launch / AppleScript-target this terminal.
    public var appName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm:    return "iTerm"
        }
    }
}

/// User config at ~/.config/helm/config.json. Missing file → all defaults.
public struct HelmConfig: Equatable {
    public var terminal: TerminalKind
    /// Post a macOS notification when a watched session finishes (needs review) or blocks
    /// awaiting input, while the overlay is dismissed. Default on.
    public var notificationsEnabled: Bool
    public var enabledAgents: [AgentKind]
    public var defaultAgent: AgentKind
    /// User-picked folders that should appear as first-class session groups.
    public var workspaceFolders: [String]
    /// Parent folders whose immediate child directories are each auto-tracked as a
    /// workspace (e.g. `~/projects` → every project under it). Saves adding each one by
    /// hand. Merged with `workspaceFolders` by `resolvedWorkspaceFolders()`.
    public var workspaceRoots: [String]
    /// Folders the user explicitly removed. Subtracted by `resolvedWorkspaceFolders()` so a
    /// `workspaceRoots` parent can't silently re-add a child the user dismissed.
    public var excludedFolders: [String]
    /// Jenkins host root (e.g. `https://minion.browserstack.com`). Nil disables the source.
    public var jenkinsURL: String?
    /// Jenkins login, matched against a build's trigger-cause `userId` to find builds you ran.
    public var jenkinsUser: String?
    /// Whitelist of full job URLs to poll for your builds. Empty disables the source. The API
    /// token is read from the `HELM_JENKINS_TOKEN` env var, never stored here.
    public var jenkinsJobs: [String]

    public init(terminal: TerminalKind = .default,
                notificationsEnabled: Bool = true,
                enabledAgents: [AgentKind] = [.claude],
                defaultAgent: AgentKind = .claude,
                workspaceFolders: [String] = [],
                workspaceRoots: [String] = [],
                excludedFolders: [String] = [],
                jenkinsURL: String? = nil,
                jenkinsUser: String? = nil,
                jenkinsJobs: [String] = []) {
        let uniqueEnabled = Self.normalizedAgents(enabledAgents)
        self.terminal = terminal
        self.notificationsEnabled = notificationsEnabled
        self.enabledAgents = uniqueEnabled
        self.defaultAgent = uniqueEnabled.contains(defaultAgent) ? defaultAgent : uniqueEnabled[0]
        self.workspaceFolders = Self.normalizedPaths(workspaceFolders)
        self.workspaceRoots = Self.normalizedPaths(workspaceRoots)
        self.excludedFolders = Self.normalizedPaths(excludedFolders)
        self.jenkinsURL = jenkinsURL
        self.jenkinsUser = jenkinsUser
        self.jenkinsJobs = jenkinsJobs
    }

    /// Every tracked folder: the explicit `workspaceFolders` plus the immediate child
    /// directories of each `workspaceRoots` entry, deduped. This is the set the session
    /// store groups against. `lister` is injected so the directory scan can be faked in
    /// tests; the default reads the real filesystem (hidden entries skipped, so a root's
    /// `.template`-style dirs don't become workspaces).
    public func resolvedWorkspaceFolders(
        lister: (String) -> [String] = HelmConfig.childDirectories
    ) -> [String] {
        let excluded = Set(excludedFolders)
        return Self.normalizedPaths(workspaceFolders + workspaceRoots.flatMap(lister))
            .filter { !excluded.contains($0) }
    }

    /// Immediate child directories of `root` (absolute paths), hidden entries skipped.
    /// Missing/unreadable root → empty.
    public static func childDirectories(of root: String) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.path)
    }

    public static var path: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/helm/config.json")
    }

    public static func load(from url: URL = path) -> HelmConfig {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return HelmConfig() }
        return HelmConfig(
            terminal: TerminalKind(parsing: obj["terminal"] as? String),
            notificationsEnabled: (obj["notificationsEnabled"] as? Bool) ?? HelmConfig().notificationsEnabled,
            enabledAgents: parseAgents(obj["enabledAgents"]),
            defaultAgent: parseAgent(obj["defaultAgent"]) ?? .claude,
            workspaceFolders: parseWorkspaceFolders(obj["workspaceFolders"]),
            workspaceRoots: parseWorkspaceFolders(obj["workspaceRoots"]),
            excludedFolders: parseWorkspaceFolders(obj["excludedFolders"]),
            jenkinsURL: (obj["jenkinsURL"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            jenkinsUser: (obj["jenkinsUser"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            jenkinsJobs: (obj["jenkinsJobs"] as? [String])?.filter { !$0.isEmpty } ?? [])
    }

    public static func addWorkspaceFolders(_ paths: [String], to url: URL = path,
                                           lister: (String) -> [String] = childDirectories) throws -> HelmConfig {
        let added = Set(normalizedPaths(paths))
        return try mutateObject(in: url, lister: lister) { obj in
            obj["workspaceFolders"] = normalizedPaths(parseWorkspaceFolders(obj["workspaceFolders"]) + paths)
            obj["excludedFolders"] = parseWorkspaceFolders(obj["excludedFolders"]).filter { !added.contains($0) }
        }
    }

    /// Stop tracking a folder: drop it from the explicit `workspaceFolders` list and, if a
    /// `workspaceRoots` parent would otherwise re-add it, record it in `excludedFolders`.
    public static func removeWorkspaceFolder(_ folderPath: String, from url: URL = path,
                                             lister: (String) -> [String] = childDirectories) throws -> HelmConfig {
        guard let normalized = normalizedPaths([folderPath]).first else { return load(from: url) }
        return try mutateObject(in: url, lister: lister) { obj in
            obj["workspaceFolders"] = parseWorkspaceFolders(obj["workspaceFolders"]).filter { $0 != normalized }
            obj["excludedFolders"] = normalizedPaths(parseWorkspaceFolders(obj["excludedFolders"]) + [normalized])
        }
    }

    public static func addWorkspaceRoots(_ paths: [String], to url: URL = path,
                                         lister: (String) -> [String] = childDirectories) throws -> HelmConfig {
        try mutateObject(in: url, lister: lister) { obj in
            obj["workspaceRoots"] = normalizedPaths(parseWorkspaceFolders(obj["workspaceRoots"]) + paths)
        }
    }

    public static func removeWorkspaceRoot(_ rootPath: String, from url: URL = path,
                                           lister: (String) -> [String] = childDirectories) throws -> HelmConfig {
        let normalized = normalizedPaths([rootPath]).first
        return try mutateObject(in: url, lister: lister) { obj in
            obj["workspaceRoots"] = parseWorkspaceFolders(obj["workspaceRoots"]).filter { $0 != normalized }
        }
    }

    /// Read the config object, apply `transform`, write it back (preserving every other
    /// field), and return the reloaded config. `excludedFolders` is self-pruned on every
    /// write to only the folders a `workspaceRoots` parent is currently re-adding — so the
    /// list never accumulates entries for explicit folders, deleted folders, or removed roots.
    private static func mutateObject(in url: URL,
                                     lister: (String) -> [String] = childDirectories,
                                     _ transform: (inout [String: Any]) -> Void) throws -> HelmConfig {
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = obj
        }
        transform(&object)

        let rootDiscovered = Set(normalizedPaths(parseWorkspaceFolders(object["workspaceRoots"]).flatMap(lister)))
        let excluded = parseWorkspaceFolders(object["excludedFolders"]).filter(rootDiscovered.contains)
        if excluded.isEmpty { object["excludedFolders"] = nil } else { object["excludedFolders"] = excluded }

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return load(from: url)
    }

    private static func parseAgent(_ raw: Any?) -> AgentKind? {
        guard let s = raw as? String else { return nil }
        return AgentKind(rawValue: s.lowercased())
    }

    private static func parseAgents(_ raw: Any?) -> [AgentKind] {
        guard let values = raw as? [String] else { return [.claude] }
        return normalizedAgents(values.compactMap { AgentKind(rawValue: $0.lowercased()) })
    }

    private static func parseWorkspaceFolders(_ raw: Any?) -> [String] {
        guard let values = raw as? [String] else { return [] }
        return normalizedPaths(values)
    }

    private static func normalizedAgents(_ agents: [AgentKind]) -> [AgentKind] {
        var seen = Set<AgentKind>()
        let unique = agents.filter { seen.insert($0).inserted }
        return unique.isEmpty ? [.claude] : unique
    }

    private static func normalizedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { raw in
            let expanded = (raw as NSString).expandingTildeInPath
            let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            guard !standardized.isEmpty, seen.insert(standardized).inserted else { return nil }
            return standardized
        }
    }
}
