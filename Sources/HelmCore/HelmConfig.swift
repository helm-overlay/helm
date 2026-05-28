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

    public init(terminal: TerminalKind = .default, hideOlderThanDays: Int = 1,
                taskEditor: TaskEditor = .default) {
        self.terminal = terminal
        self.hideOlderThanDays = hideOlderThanDays
        self.taskEditor = taskEditor
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
            taskEditor: TaskEditor(parsing: obj["taskEditor"]))
    }
}
