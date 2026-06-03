import SwiftUI
import HelmCore

/// Which list the panel is currently showing. The panel stays summoned across switches
/// so view changes feel like flipping tabs, not summoning a new tool.
///
/// Case order is the source of truth: a view's ⌘-digit, its slot in the `ModeSwitcher`,
/// and the key handler's switch all derive from `allCases`. Adding a view is a single new
/// case here (plus its view + key handler) — no scattered ⌘N wiring to update.
enum AppView: String, CaseIterable, Hashable {
    case attention, sessions, tasks, prs

    var title: String {
        switch self {
        case .attention: return "Attention"
        case .sessions:  return "Sessions"
        case .tasks:     return "Tasks"
        case .prs:       return "PRs"
        }
    }

    var symbol: String {
        switch self {
        case .attention: return "dot.radiowaves.left.and.right"
        case .sessions:  return "bubble.left.and.bubble.right"
        case .tasks:     return "checklist"
        case .prs:       return "arrow.triangle.branch"
        }
    }

    /// The ⌘-digit that selects this view: its 1-based position in `allCases`.
    var shortcutDigit: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// The view bound to ⌘<digit>, or nil if no view occupies that slot.
    static func forDigit(_ digit: Int) -> AppView? {
        let idx = digit - 1
        return allCases.indices.contains(idx) ? allCases[idx] : nil
    }
}

/// A request to show a view. `token` changes on every request (even re-selecting the same
/// view) so `RootView` reacts; `animated` distinguishes a user switch (slide) from a summon
/// reset (snap); `forward` picks the slide direction from tab order.
struct ViewTransition: Equatable {
    var view: AppView
    var animated: Bool
    var forward: Bool
    var token: Int
}

/// Holds the currently-active view as a transition request. Lives on AppDelegate; observed
/// by `RootView` and mutated by the key handler / mode switcher. Tiny on purpose.
@MainActor
final class AppShellModel: ObservableObject {
    @Published private(set) var transition = ViewTransition(view: .attention, animated: false,
                                                            forward: true, token: 0)
    /// The new-chat picker overlays the current view rather than being an `AppView` of its
    /// own — it's an action surface, not a mode, so it stays out of the tab order / ⌘-digits.
    @Published private(set) var newChatActive = false
    var view: AppView { transition.view }

    func openNewChat() { newChatActive = true }
    func closeNewChat() { newChatActive = false }

    /// A user switch — slides, direction from tab order.
    func select(_ v: AppView) {
        guard v != transition.view else { return }
        transition = ViewTransition(view: v, animated: true,
                                    forward: v.shortcutDigit >= transition.view.shortcutDigit,
                                    token: transition.token + 1)
    }

    /// A summon reset — snap to the launcher with no slide.
    func snap(to v: AppView) {
        transition = ViewTransition(view: v, animated: false, forward: true,
                                    token: transition.token + 1)
    }
}

/// The SwiftUI entry hosted by the NSPanel. Routes between the sessions and tasks
/// views based on `shell.view`. Both child views render their own chrome (material +
/// rounded corner), so a switch fades the whole panel rather than just its contents —
/// the right choice for view-as-mode rather than view-as-pane.
struct RootView: View {
    @ObservedObject var shell: AppShellModel
    @ObservedObject var attention: AttentionListViewModel
    @ObservedObject var sessions: SessionListViewModel
    @ObservedObject var tasks: TaskListViewModel
    @ObservedObject var prs: PRListViewModel
    @ObservedObject var newChat: NewChatViewModel
    let onPickSession: (ChatSession) -> Void
    let onNewChat: () -> Void
    let onLaunchNewChat: (ProjectChoice) -> Void
    let onOpenTask: (VaultTask) -> Void
    let onCycleTask: () -> Void
    let onOpenSource: (TaskSource) -> Void
    let onOpenPR: (PullRequest) -> Void
    let onOpenAttention: (any AttentionItem) -> Void
    /// Resize the panel for a view (instant). Called in the gap between slide-out and
    /// slide-in, while content is off-screen, so the window never resizes under visible content.
    let onResize: (AppView) -> Void
    let onDismiss: () -> Void

    /// The view currently rendered (lags `shell.view` during a slide). The content slides
    /// via `offset`; `gen` cancels a stale slide if another switch lands mid-animation.
    @State private var shown: AppView = .attention
    @State private var offset: CGFloat = 0
    @State private var gen = 0

    /// Far enough to push any panel width fully off-screen; `.clipped()` hides the overhang.
    private let slideDistance: CGFloat = 1300
    private let slideOut = Animation.easeIn(duration: 0.13)
    private let slideIn = Animation.easeOut(duration: 0.17)
    private let outDuration: TimeInterval = 0.13

    var body: some View {
        GeometryReader { geo in
            ZStack {
                content
                    .frame(width: geo.size.width, height: geo.size.height)
                    .offset(x: offset)
                    .opacity(shell.newChatActive ? 0 : 1)   // hidden beneath the picker, state kept
                if shell.newChatActive {
                    NewChatPickerView(model: newChat, onLaunch: onLaunchNewChat)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.12), value: shell.newChatActive)
        .onAppear { shown = shell.view }
        .onChange(of: shell.transition.token) { _, _ in apply(shell.transition) }
    }

    @ViewBuilder private var content: some View {
        switch shown {
        case .attention:
            AttentionListView(model: attention, shell: shell, onOpen: onOpenAttention)
        case .sessions:
            OverlayView(model: sessions, shell: shell,
                        onPick: onPickSession, onNewChat: onNewChat, onDismiss: onDismiss)
        case .tasks:
            TaskListView(model: tasks, shell: shell,
                         onOpen: onOpenTask, onCycle: onCycleTask, onOpenSource: onOpenSource)
        case .prs:
            PRListView(model: prs, shell: shell, onOpen: onOpenPR)
        }
    }

    /// Slide the current view out, resize the panel in the gap, then slide the new one in
    /// from the opposite edge. A snap (summon reset) skips straight to the resized view.
    private func apply(_ t: ViewTransition) {
        gen += 1
        let g = gen
        guard t.animated, t.view != shown else {
            offset = 0
            shown = t.view
            onResize(t.view)
            return
        }
        withAnimation(slideOut) { offset = t.forward ? -slideDistance : slideDistance }
        DispatchQueue.main.asyncAfter(deadline: .now() + outDuration) {
            guard g == gen else { return }      // a newer switch superseded this one
            shown = t.view
            onResize(t.view)                    // resize while content is off-screen
            offset = t.forward ? slideDistance : -slideDistance
            withAnimation(slideIn) { offset = 0 }
        }
    }
}
