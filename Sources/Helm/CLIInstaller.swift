import Cocoa
import Foundation

/// Manages the `project` CLI bundled inside Helm.app. Lets the user opt in to
/// a `~/.local/bin/project` symlink so the CLI is on $PATH. Designed to be
/// safe to call repeatedly and to never block app startup on its own.
///
/// Two entry points:
///   • `promptOnFirstLaunchIfNeeded()` — call once after launch; shows an alert
///      if we've never asked and the symlink doesn't yet exist.
///   • `bundledCLIPath`               — Helm.app/Contents/MacOS/project, used as the
///      symlink target.
@MainActor
enum CLIInstaller {
    /// `Helm.app/Contents/MacOS/project`. nil if the binary isn't in the bundle
    /// (e.g. when running from `xcodebuild` Debug output before the post-build
    /// copy step has run — we silently skip installation in that case).
    static var bundledCLIPath: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/project")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var symlinkPath: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/bin/project")
    }

    private static var didAskMarker: URL {
        let support = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Helm")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("cli-install-asked")
    }

    /// True if the symlink at ~/.local/bin/project points at our bundled binary.
    static var isInstalledHere: Bool {
        guard let bundled = bundledCLIPath else { return false }
        guard let dest = try? FileManager.default
                .destinationOfSymbolicLink(atPath: symlinkPath.path) else { return false }
        return URL(fileURLWithPath: dest).resolvingSymlinksInPath()
            == bundled.resolvingSymlinksInPath()
    }

    /// Call once at launch. Skips if (a) the symlink already targets us,
    /// (b) we've already asked, or (c) no bundled binary exists.
    static func promptOnFirstLaunchIfNeeded() {
        guard let bundled = bundledCLIPath else { return }
        if isInstalledHere { return }
        if FileManager.default.fileExists(atPath: didAskMarker.path) { return }

        let alert = NSAlert()
        alert.messageText = "Install the `project` command line tool?"
        alert.informativeText = """
            Helm bundles a `project` CLI that manages your worktrees and projects \
            (see ~/projects/README.md). Symlinking it into ~/.local/bin makes it \
            available on your $PATH.

            Source:  \(bundled.path)
            Target:  \(symlinkPath.path)
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not now")
        alert.addButton(withTitle: "Don't ask again")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            performInstall(bundled: bundled, symlink: symlinkPath)
            FileManager.default.createFile(atPath: didAskMarker.path, contents: Data())
        case .alertSecondButtonReturn:
            return  // ask again next launch
        case .alertThirdButtonReturn:
            FileManager.default.createFile(atPath: didAskMarker.path, contents: Data())
        default: return
        }
    }

    private static func performInstall(bundled: URL, symlink target: URL) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
        } catch {
            showAlert("Could not create \(target.deletingLastPathComponent().path)", info: "\(error)")
            return
        }
        // Remove anything (file or symlink) sitting at the target path.
        if fm.fileExists(atPath: target.path) ||
            (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
            try? fm.removeItem(at: target)
        }
        do {
            try fm.createSymbolicLink(at: target, withDestinationURL: bundled)
        } catch {
            showAlert("Could not create symlink", info: "\(error)")
            return
        }
        showAlert("`project` CLI installed",
                  info: "Symlinked \(target.path) → \(bundled.path).\n" +
                        "Make sure \(target.deletingLastPathComponent().path) is on your PATH.")
    }

    private static func showAlert(_ title: String, info: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
