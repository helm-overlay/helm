import Cocoa

/// Non-activating, borderless floating panel placed in the upper-middle of the active
/// screen (Raycast/Spotlight style). Becomes key (so it receives keystrokes) without
/// activating the app — focus returns to the terminal the moment it's ordered out.
final class OverlayPanel: NSPanel {
    /// The frame is a fraction of the active screen, clamped between a floor and a cap so
    /// it's neither tiny on a 5K nor cramped on a 13″. One generous size holds every view —
    /// the panel never resizes on a mode switch, so switches stay crossfades, not lurches.
    private let widthFraction: CGFloat = 0.46
    private let heightFraction: CGFloat = 0.62
    private let minWidth: CGFloat = 820, maxWidth: CGFloat = 1100
    private let minHeight: CGFloat = 560, maxHeight: CGFloat = 820
    /// Fraction of the vertical slack left above the panel. Below 0.5 sits it above
    /// dead center; Raycast's launcher feel lands around the upper third.
    private let topBias: CGFloat = 0.26

    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: minWidth, height: minHeight),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        content.frame = contentView!.bounds
        content.autoresizingMask = [.width, .height]
        contentView?.addSubview(content)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Place the panel in the upper-middle of the screen under the cursor.
    func positionUpperMiddle() {
        let screen = screenUnderCursor ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let w = min(maxWidth, max(minWidth, visible.width * widthFraction))
        let h = min(maxHeight, max(minHeight, visible.height * heightFraction))
        let slack = max(0, visible.height - h)
        let x = visible.midX - w / 2
        let y = visible.maxY - h - slack * topBias
        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }

    private var screenUnderCursor: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
}
