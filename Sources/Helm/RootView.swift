import SwiftUI
import HelmCore

/// Holds the new-chat picker's open state. The picker overlays the launcher rather than being
/// a mode of its own — it's an action surface, not a view. Tiny on purpose; observed by
/// `RootView`, toggled by the key handler.
@MainActor
final class AppShellModel: ObservableObject {
    @Published private(set) var newChatActive = false
    func openNewChat() { newChatActive = true }
    func closeNewChat() { newChatActive = false }
}

/// The SwiftUI entry hosted by the NSPanel. Helm is a single view — the attention launcher —
/// with the new-chat picker as an overlay on top. Renders the panel chrome (material + rounded
/// border); the launcher fades out beneath the picker while it's up.
struct RootView: View {
    @ObservedObject var shell: AppShellModel
    @ObservedObject var attention: AttentionListViewModel
    @ObservedObject var newChat: NewChatViewModel
    let onLaunchNewChat: (ProjectChoice) -> Void
    let onOpenAttention: (any AttentionItem) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                AttentionListView(model: attention, onOpen: onOpenAttention)
                    .frame(width: geo.size.width, height: geo.size.height)
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
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.12), value: shell.newChatActive)
    }
}
