import SwiftUI
import HelmCore

/// Which list the panel is currently showing. The panel stays summoned across switches
/// so view changes feel like flipping tabs, not summoning a new tool.
///
/// Case order is the source of truth: a view's ⌘-digit, its slot in the `ModeSwitcher`,
/// and the key handler's switch all derive from `allCases`. Adding a view is a single new
/// case here (plus its view + key handler) — no scattered ⌘N wiring to update.
enum AppView: String, CaseIterable, Hashable {
    case sessions, tasks, prs

    var title: String {
        switch self {
        case .sessions: return "Sessions"
        case .tasks:    return "Tasks"
        case .prs:      return "PRs"
        }
    }

    var symbol: String {
        switch self {
        case .sessions: return "bubble.left.and.bubble.right"
        case .tasks:    return "checklist"
        case .prs:      return "arrow.triangle.branch"
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

/// Holds the currently-active view. Lives on AppDelegate; observed by `RootView` and
/// mutated by the key handler. Tiny on purpose — adding more shell state should look
/// out of place here.
@MainActor
final class AppShellModel: ObservableObject {
    @Published var view: AppView = .sessions
}

/// The SwiftUI entry hosted by the NSPanel. Routes between the sessions and tasks
/// views based on `shell.view`. Both child views render their own chrome (material +
/// rounded corner), so a switch fades the whole panel rather than just its contents —
/// the right choice for view-as-mode rather than view-as-pane.
struct RootView: View {
    @ObservedObject var shell: AppShellModel
    @ObservedObject var sessions: SessionListViewModel
    @ObservedObject var tasks: TaskListViewModel
    @ObservedObject var prs: PRListViewModel
    let onPickSession: (ChatSession) -> Void
    let onNewChat: () -> Void
    let onOpenTask: (VaultTask) -> Void
    let onCycleTask: () -> Void
    let onOpenSource: (TaskSource) -> Void
    let onOpenPR: (PullRequest) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            switch shell.view {
            case .sessions:
                OverlayView(model: sessions,
                            shell: shell,
                            onPick: onPickSession,
                            onNewChat: onNewChat,
                            onDismiss: onDismiss)
                    .transition(.opacity)
            case .tasks:
                TaskListView(model: tasks,
                             shell: shell,
                             onOpen: onOpenTask,
                             onCycle: onCycleTask,
                             onOpenSource: onOpenSource)
                    .transition(.opacity)
            case .prs:
                PRListView(model: prs, shell: shell, onOpen: onOpenPR)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.14), value: shell.view)
    }
}
