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
    /// Sessions idle longer than this are hidden from the default view (still searchable).
    /// 0 or negative disables the cutoff (show everything).
    public var hideOlderThanDays: Int

    public init(terminal: TerminalKind = .default, hideOlderThanDays: Int = 7) {
        self.terminal = terminal
        self.hideOlderThanDays = hideOlderThanDays
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
            hideOlderThanDays: (obj["hideOlderThanDays"] as? Int) ?? HelmConfig().hideOlderThanDays)
    }
}
