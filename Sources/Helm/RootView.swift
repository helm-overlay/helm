import SwiftUI
import HelmCore

/// Which list the panel is currently showing. Switched by ⌘1 / ⌘2; the panel itself
/// stays summoned across switches so view changes feel like flipping tabs, not
/// summoning a new tool.
enum AppView: String, Equatable, CaseIterable {
    case sessions, tasks
}

/// Holds the currently-active view. Lives on AppDelegate; observed by `RootView` and
/// mutated by the key handler. Tiny on purpose — adding more shell state should look
/// out of place here.
@MainActor
final class AppShellModel: ObservableObject {
    @Published var view: AppView = .sessions
    @Published var presentingNewProject: Bool = false
}

/// The SwiftUI entry hosted by the NSPanel. Routes between the sessions and tasks
/// views based on `shell.view`. Both child views render their own chrome (material +
/// rounded corner), so a switch fades the whole panel rather than just its contents —
/// the right choice for view-as-mode rather than view-as-pane.
struct RootView: View {
    @ObservedObject var shell: AppShellModel
    @ObservedObject var sessions: SessionListViewModel
    @ObservedObject var tasks: TaskListViewModel
    @ObservedObject var newProject: ProjectCreateViewModel
    let onPickSession: (ChatSession) -> Void
    let onNewChat: () -> Void
    let onOpenTask: (VaultTask) -> Void
    let onCycleTask: () -> Void
    let onOpenSource: (TaskSource) -> Void
    let onCancelNewProject: () -> Void
    let onCreatedProject: (URL) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            if shell.presentingNewProject {
                ProjectCreateView(model: newProject,
                                  onCancel: onCancelNewProject,
                                  onSuccess: onCreatedProject)
                    .transition(.opacity)
            } else {
                switch shell.view {
                case .sessions:
                    OverlayView(model: sessions,
                                onPick: onPickSession,
                                onNewChat: onNewChat,
                                onDismiss: onDismiss)
                        .transition(.opacity)
                case .tasks:
                    TaskListView(model: tasks,
                                 onOpen: onOpenTask,
                                 onCycle: onCycleTask,
                                 onOpenSource: onOpenSource)
                        .transition(.opacity)
                }
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
        .animation(.easeInOut(duration: 0.14), value: shell.presentingNewProject)
    }
}
