import Cocoa

/// Non-activating, borderless floating panel pinned to the top of the active screen.
/// Becomes key (so it receives keystrokes) without activating the app — focus returns
/// to the terminal the moment it's ordered out.
final class OverlayPanel: NSPanel {
    private let panelWidth: CGFloat = 780
    private let panelHeight: CGFloat = 520
    private let topInset: CGFloat = 8

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

    /// Center horizontally on the screen under the cursor, pinned just below the top edge.
    func positionAtTop() {
        let screen = screenUnderCursor ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let x = visible.midX - panelWidth / 2
        let y = visible.maxY - panelHeight - topInset
        setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }

    private var screenUnderCursor: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
}
