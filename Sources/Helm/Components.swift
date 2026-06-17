import SwiftUI
import AppKit

/// Forces the enclosing `NSScrollView` to overlay-style scrollers and hides them. SwiftUI's
/// `.scrollIndicators(.hidden)` is ignored when the system "Show scroll bars" setting is
/// "Always" (legacy scrollers draw a permanent track), so we reach the real scroll view and
/// override it directly. Drop this into the scroll content's background so `enclosingScrollView`
/// resolves to the right view.
struct HideScrollIndicators: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollHidingProbe { ScrollHidingProbe() }
    func updateNSView(_ nsView: ScrollHidingProbe, context: Context) {}
}

/// Finds its enclosing `NSScrollView` and keeps the scroller hidden. A one-shot pass isn't
/// enough for a list that re-renders (each content update rebuilds the scroller after the
/// hide ran), so this re-applies on the scroll view's bounds/frame change notifications.
final class ScrollHidingProbe: NSView {
    private weak var scrollView: NSScrollView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.attach() }
    }

    private func attach() {
        guard let scrollView = enclosingScrollView ?? Self.find(in: window?.contentView) else { return }
        if scrollView !== self.scrollView {
            self.scrollView = scrollView
            let nc = NotificationCenter.default
            scrollView.contentView.postsBoundsChangedNotifications = true
            nc.addObserver(self, selector: #selector(reapply),
                           name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            if let doc = scrollView.documentView {
                doc.postsFrameChangedNotifications = true
                nc.addObserver(self, selector: #selector(reapply),
                               name: NSView.frameDidChangeNotification, object: doc)
            }
        }
        reapply()
    }

    @objc private func reapply() {
        guard let scrollView else { return }
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScroller?.alphaValue = 0
    }

    private static func find(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scrollView = view as? NSScrollView { return scrollView }
        for sub in view.subviews { if let found = find(in: sub) { return found } }
        return nil
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

// Leaf views shared across the overlay's list views. Kept here (rather than copied
// privately into each view) so the lists stay visually identical by construction.

/// A 1px hairline rule in the shared border color — the section dividers between header,
/// list, and footer.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(HelmColors.hairline).frame(height: 1)
    }
}

/// A vertical-bar insertion caret that blinks on a fixed cadence, phased so it is
/// solid-on at `anchor` (the last edit) — the caret never blinks off mid-keystroke.
struct BlinkingCursor: View {
    let anchor: Date
    private let period = 0.53
    var body: some View {
        TimelineView(.periodic(from: anchor, by: period)) { ctx in
            let on = Int(ctx.date.timeIntervalSince(anchor) / period) % 2 == 0
            RoundedRectangle(cornerRadius: 1)
                .fill(HelmColors.textPrimary)
                .frame(width: 2, height: 16)
                .opacity(on ? 1 : 0)
        }
    }
}

/// What `QueryLine` needs to draw a launcher's filter line. Both launcher view models
/// conform, so the two query lines render identically by construction.
@MainActor
protocol QueryLineModel: ObservableObject {
    var query: String { get }
    var querySelected: Bool { get }
    var queryBeforeCursor: String { get }
    var queryAfterCursor: String { get }
    var lastEdit: Date { get }
}

/// A launcher's editable filter line: placeholder when empty, otherwise the text with a
/// blinking caret drawn at the insertion point, or the whole buffer highlighted under ⌘A.
struct QueryLine<Model: QueryLineModel>: View {
    @ObservedObject var model: Model
    let placeholder: String
    private let font = Font.system(size: 13, weight: .regular)

    var body: some View {
        HStack(spacing: 0) {
            if model.query.isEmpty {
                ZStack(alignment: .leading) {
                    Text(placeholder).foregroundStyle(HelmColors.textTertiary).font(font)
                    BlinkingCursor(anchor: model.lastEdit)
                }
            } else if model.querySelected {
                Text(model.query).foregroundStyle(HelmColors.textPrimary).font(font)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.14))
                            .padding(.horizontal, -4)
                    )
            } else {
                Text(model.queryBeforeCursor).foregroundStyle(HelmColors.textPrimary).font(font)
                BlinkingCursor(anchor: model.lastEdit)
                Text(model.queryAfterCursor).foregroundStyle(HelmColors.textPrimary).font(font)
            }
        }
    }
}

extension AnyTransition {
    /// New rows drop in from above and fade up; rows leaving the visible set — e.g. one
    /// pushed behind a "+N older" tail — slide down and fade out.
    static var rowEnterLeave: AnyTransition {
        .asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .move(edge: .bottom).combined(with: .opacity))
    }
}
