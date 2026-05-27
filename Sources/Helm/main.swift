import Cocoa

// Agent app: no dock icon, no menu bar presence (LSUIElement + .accessory).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
