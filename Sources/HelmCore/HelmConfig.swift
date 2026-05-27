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

    public init(terminal: TerminalKind = .default) {
        self.terminal = terminal
    }

    public static var path: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/helm/config.json")
    }

    public static func load(from url: URL = path) -> HelmConfig {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return HelmConfig() }
        return HelmConfig(terminal: TerminalKind(parsing: obj["terminal"] as? String))
    }
}
