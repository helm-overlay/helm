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

/// Which editor opens when a task row is activated. The first element is the binary
/// (resolved via `env`); successive elements are flags. Defaults to Zed; the user can
/// override via `taskEditor` in `~/.config/helm/config.json` (string or array).
public struct TaskEditor: Equatable {
    public let argv: [String]

    public static let `default` = TaskEditor(argv: ["zed"])

    public init(argv: [String]) { self.argv = argv }

    /// Parse from the config JSON: `"code"` → `["code"]`; `["code", "--wait"]` → same.
    /// Empty or malformed → default.
    public init(parsing raw: Any?) {
        if let s = raw as? String, !s.isEmpty {
            self.argv = s.split(separator: " ").map(String.init)
        } else if let arr = raw as? [String], !arr.isEmpty {
            self.argv = arr
        } else {
            self.argv = Self.default.argv
        }
    }
}

/// User config at ~/.config/helm/config.json. Missing file → all defaults.
public struct HelmConfig: Equatable {
    public var terminal: TerminalKind
    /// Sessions idle longer than this are hidden from the default view (still searchable).
    /// 0 or negative disables the cutoff (show everything).
    public var hideOlderThanDays: Int
    public var taskEditor: TaskEditor
    public var enabledAgents: [AgentKind]
    public var defaultAgent: AgentKind
    /// User-picked folders that should appear as first-class session groups.
    public var workspaceFolders: [String]

    public init(terminal: TerminalKind = .default, hideOlderThanDays: Int = 1,
                taskEditor: TaskEditor = .default,
                enabledAgents: [AgentKind] = [.claude],
                defaultAgent: AgentKind = .claude,
                workspaceFolders: [String] = []) {
        let uniqueEnabled = Self.normalizedAgents(enabledAgents)
        self.terminal = terminal
        self.hideOlderThanDays = hideOlderThanDays
        self.taskEditor = taskEditor
        self.enabledAgents = uniqueEnabled
        self.defaultAgent = uniqueEnabled.contains(defaultAgent) ? defaultAgent : uniqueEnabled[0]
        self.workspaceFolders = Self.normalizedPaths(workspaceFolders)
    }

    /// Cutoff as a duration; 0 if disabled.
    public var hideOlderThan: TimeInterval {
        hideOlderThanDays > 0 ? TimeInterval(hideOlderThanDays) * 86_400 : 0
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
            hideOlderThanDays: (obj["hideOlderThanDays"] as? Int) ?? HelmConfig().hideOlderThanDays,
            taskEditor: TaskEditor(parsing: obj["taskEditor"]),
            enabledAgents: parseAgents(obj["enabledAgents"]),
            defaultAgent: parseAgent(obj["defaultAgent"]) ?? .claude,
            workspaceFolders: parseWorkspaceFolders(obj["workspaceFolders"]))
    }

    public static func addWorkspaceFolders(_ paths: [String], to url: URL = path) throws -> HelmConfig {
        let existingObject: [String: Any]
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            existingObject = obj
        } else {
            existingObject = [:]
        }

        var updated = existingObject
        let current = parseWorkspaceFolders(existingObject["workspaceFolders"])
        updated["workspaceFolders"] = normalizedPaths(current + paths)

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return load(from: url)
    }

    public static func removeWorkspaceFolder(_ folderPath: String, from url: URL = path) throws -> HelmConfig {
        let existingObject: [String: Any]
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            existingObject = obj
        } else {
            existingObject = [:]
        }

        let normalized = normalizedPaths([folderPath]).first
        var updated = existingObject
        let remaining = parseWorkspaceFolders(existingObject["workspaceFolders"]).filter { $0 != normalized }
        updated["workspaceFolders"] = remaining

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
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
