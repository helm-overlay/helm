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
            Divider().opacity(0.5)
            list
            Divider().opacity(0.5)
            footer
        }
    }

    // MARK: Header (query line)

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.bubble").foregroundStyle(.secondary)
            HStack(spacing: 2) {
                if model.query.isEmpty {
                    ZStack(alignment: .leading) {
                        Text("New chat in project…")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 15, weight: .regular))
                        BlinkingCursor(anchor: model.lastEdit)
                    }
                } else {
                    Text(model.query)
                        .foregroundStyle(.primary)
                        .font(.system(size: 15, weight: .regular))
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(model.querySelected ? Color.accentColor.opacity(0.35) : .clear)
                                .padding(.horizontal, -4)
                        )
                    if !model.querySelected { BlinkingCursor(anchor: model.lastEdit) }
                }
            }
            Spacer()
            Text("\(model.filtered.count) project\(model.filtered.count == 1 ? "" : "s")")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
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
            }
            .onChange(of: model.selection) { _, sel in
                guard let sel else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(sel, anchor: .center) }
            }
        }
    }

    private var emptyState: some View {
        Text(model.choices.isEmpty ? "No tracked projects — ⌘O to add a folder" : "No matches")
            .font(.system(size: 13)).italic()
            .foregroundStyle(.secondary)
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

    private static let emerald = Color(red: 0.204, green: 0.827, blue: 0.600)  // #34D399

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: choice.isLaunchpad ? "sparkles" : "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(choice.name).lineLimit(1)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Text(choice.isLaunchpad ? "one-off chat in ~/Home" : abbreviatedPath)
                    .lineLimit(1).truncationMode(.head)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            if choice.liveCount > 0 {
                HStack(spacing: 3) {
                    Circle().fill(Self.emerald).frame(width: 5, height: 5)
                    Text("\(choice.liveCount)").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Self.emerald)
                }
            }
            if let last = choice.lastActive, last != .distantPast {
                Text(SessionStore.ageLabel(Date().timeIntervalSince(last)))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(selected ? Color.white.opacity(0.09) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
    }

    /// `~/projects/helm` rather than the full home-rooted absolute path.
    private var abbreviatedPath: String {
        let home = NSHomeDirectory()
        return choice.path.hasPrefix(home) ? "~" + choice.path.dropFirst(home.count) : choice.path
    }
}
