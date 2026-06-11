import Cocoa

/// Non-activating, borderless floating panel placed in the upper-middle of the active
/// screen (Raycast/Spotlight style). Becomes key (so it receives keystrokes) without
/// activating the app — focus returns to the terminal the moment it's ordered out.
///
/// Sizes to its content: a compact **launcher** (the attention view) — a small list of what
/// wants you, like Raycast at rest — and a slightly narrower **new-chat picker** overlay.
/// Anchored at a fixed top edge so it grows/shrinks downward.
final class OverlayPanel: NSPanel {
    /// Initial seed size before the first content-driven resize.
    private let minWidth: CGFloat = 820
    private let minHeight: CGFloat = 560

    /// Compact launcher: a fixed, narrower width; height fits content up to a cap.
    private let launcherWidth: CGFloat = 700
    private let launcherMaxHeightFraction: CGFloat = 0.7

    /// New-chat picker: a command-palette-shaped box — narrower than the launcher, height
    /// fit to its project rows up to a cap.
    private let pickerWidth: CGFloat = 560
    private let pickerMaxHeightFraction: CGFloat = 0.6

    /// Top edge as a fraction of the screen height below the visible top — fixed across
    /// resizes so the panel doesn't jump when it grows or shrinks.
    private let topInsetFraction: CGFloat = 0.14

    /// Present on every Space (follow the active desktop) and survive other apps' full-screen
    /// Spaces. Re-asserted on every summon — see `summon()`.
    private let spaceBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: minWidth, height: minHeight),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = spaceBehavior
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // The UI is styled as dark glass (light text, white-opacity overlays). Pin the
        // appearance so the material renders dark regardless of system mode or whatever
        // window sits behind it — otherwise a bright page bleeds through and washes it out.
        appearance = NSAppearance(named: .darkAqua)
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        // Pin the hosting view to fill the content view exactly. Auto Layout (not an
        // autoresizing mask) so the SwiftUI content tracks the window across launcher⇄generous
        // resizes — a shrink-then-grow could otherwise leave the content wider than the window.
        content.translatesAutoresizingMaskIntoConstraints = false
        contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentView!.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor),
        ])
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Order the panel front on the *active* Space. Re-applying `collectionBehavior` here is
    /// load-bearing: while the app sits idle (App Nap / display sleep) the WindowServer drops a
    /// background accessory window's all-Spaces association, so a stale summon lands on the Space
    /// the window was last anchored to (the launch desktop). Re-setting it forces the WindowServer
    /// to re-register the window against whatever Space is now active.
    func summon() {
        collectionBehavior = spaceBehavior
        makeKeyAndOrderFront(nil)
    }

    /// The compact launcher size — narrow, height fit to `contentHeight` up to a cap.
    func setLauncherFrame(contentHeight: CGFloat) {
        guard let visible = currentVisibleFrame() else { return }
        let w = min(launcherWidth, visible.width * 0.5)
        let h = min(contentHeight, visible.height * launcherMaxHeightFraction)
        apply(width: w, height: h, in: visible)
    }

    /// The new-chat picker size — a compact palette, height fit to `contentHeight` up to a cap.
    func setPickerFrame(contentHeight: CGFloat) {
        guard let visible = currentVisibleFrame() else { return }
        let w = min(pickerWidth, visible.width * 0.5)
        let h = min(contentHeight, visible.height * pickerMaxHeightFraction)
        apply(width: w, height: h, in: visible)
    }

    /// Resize instantly (no AppKit frame animation — that blocks the run loop and fights the
    /// SwiftUI content crossfade). Anchored at a fixed top so size changes grow downward.
    private func apply(width w: CGFloat, height h: CGFloat, in visible: NSRect) {
        let topY = visible.maxY - visible.height * topInsetFraction
        let frame = NSRect(x: visible.midX - w / 2, y: topY - h, width: w, height: h)
        setFrame(frame, display: true)
    }

    private func currentVisibleFrame() -> NSRect? {
        let screen = screenUnderCursor ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame
    }

    private var screenUnderCursor: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
}
