import SwiftUI
import HelmCore

/// The new-chat picker — a small overlay (not a mode tab): type to fuzzy-find a tracked
/// project, ↵ starts a fresh chat there. Deliberately one query line over one flat project
/// list, so it pops in light rather than dragging in the full Sessions layout.
struct NewChatPickerView: View {
    @ObservedObject var model: NewChatViewModel
    let onLaunch: (ProjectChoice) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            list
            Hairline()
            footer
        }
    }

    // MARK: Header (query line)

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.bubble")
                .font(.system(size: 13)).foregroundStyle(HelmColors.textTertiary)
            QueryLine(model: model, placeholder: "New chat in project…")
            Spacer()
            Text("\(model.filtered.count) project\(model.filtered.count == 1 ? "" : "s")")
                .font(.system(size: 11)).foregroundStyle(HelmColors.textTertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.filtered.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.filtered) { choice in
                            ProjectChoiceRow(choice: choice, selected: choice.id == model.selection)
                                .id(choice.id)
                                .contentShape(Rectangle())
                                .onTapGesture { onLaunch(choice) }
                        }
                    }
                }
                .padding(.vertical, 6)
                .background(HideScrollIndicators())
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.selection) { _, sel in
                guard let sel else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(sel, anchor: .center) }
            }
        }
    }

    private var emptyState: some View {
        Text(model.choices.isEmpty ? "No tracked projects — ⌘O to add a folder" : "No matches")
            .font(.system(size: 13))
            .foregroundStyle(HelmColors.textSecondary)
            .padding(.horizontal, 16).padding(.vertical, 24)
            .frame(maxWidth: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 16) {
            HintBar(hints: [Hint(key: "↑↓", label: "navigate"),
                            Hint(key: "↵", label: "new chat"),
                            Hint(key: "esc", label: "back")])
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }
}

/// One project row: folder name, its path dimmed beneath, a live-count dot and the age of
/// its last session on the trailing edge — enough to recognize the project at a glance.
private struct ProjectChoiceRow: View {
    let choice: ProjectChoice
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: choice.isLaunchpad ? "sparkles" : "folder")
                .font(.system(size: 13))
                .foregroundStyle(HelmColors.textTertiary)
                .frame(width: 18, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(choice.name).lineLimit(1)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(HelmColors.textPrimary)
                Text(choice.isLaunchpad ? "one-off chat in ~/Home" : abbreviatedPath)
                    .lineLimit(1).truncationMode(.head)
                    .font(.system(size: 11)).foregroundStyle(HelmColors.textTertiary)
            }

            Spacer(minLength: 8)

            if choice.liveCount > 0 {
                HStack(spacing: 4) {
                    Circle().fill(HelmColors.emerald).frame(width: 5, height: 5)
                    Text("\(choice.liveCount)").font(.system(size: 11))
                        .foregroundStyle(HelmColors.textSecondary)
                }
            }
            if let last = choice.lastActive, last != .distantPast {
                Text(SessionStore.ageLabel(Date().timeIntervalSince(last)))
                    .font(.system(size: 11)).foregroundStyle(HelmColors.textTertiary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(selected ? HelmColors.surfaceHover : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(choice.liveCount > 0 ? HelmColors.emerald : HelmColors.slate)
                    .frame(width: 2)
                    .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 8)
    }

    /// `~/projects/helm` rather than the full home-rooted absolute path.
    private var abbreviatedPath: String {
        let home = NSHomeDirectory()
        return choice.path.hasPrefix(home) ? "~" + choice.path.dropFirst(home.count) : choice.path
    }
}
