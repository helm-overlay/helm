import Cocoa

/// Non-activating, borderless floating panel placed in the upper-middle of the active
/// screen (Raycast/Spotlight style). Becomes key (so it receives keystrokes) without
/// activating the app — focus returns to the terminal the moment it's ordered out.
final class OverlayPanel: NSPanel {
    private let panelWidth: CGFloat = 780
    private let panelHeight: CGFloat = 520
    /// Fraction of the vertical slack left above the panel. Below 0.5 sits it above
    /// dead center; Raycast's launcher feel lands around the upper third.
    private let topBias: CGFloat = 0.26

    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
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
        let slack = max(0, visible.height - panelHeight)
        let x = visible.midX - panelWidth / 2
        let y = visible.maxY - panelHeight - slack * topBias
        setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }

    private var screenUnderCursor: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
}
