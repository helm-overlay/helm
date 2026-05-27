import SwiftUI
import HelmCore

struct OverlayView: View {
    @ObservedObject var model: SessionListViewModel
    let onPick: (ChatSession) -> Void
    let onNewChat: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            list
            Divider().opacity(0.5)
            footer
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: Header (query line)

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            Text(model.query.isEmpty ? "Type to filter sessions…" : model.query)
                .foregroundStyle(model.query.isEmpty ? .secondary : .primary)
                .font(.system(size: 15, weight: .regular))
            Spacer()
            Text("\(model.liveCount) live · \(model.totalCount) total")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.groups) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                SessionRow(session: session,
                                           selected: session.sessionId == model.selection,
                                           now: model.now)
                                    .id(session.sessionId)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onPick(session) }
                            }
                            if group.hiddenCount > 0 {
                                CollapseTail(label: "+\(group.hiddenCount) older")
                                    .onTapGesture { model.toggleExpanded(group.project) }
                            } else if group.expanded {
                                CollapseTail(label: "show less")
                                    .onTapGesture { model.toggleExpanded(group.project) }
                            }
                        } header: {
                            GroupHeader(project: group.project)
                        }
                    }
                    if model.groups.isEmpty {
                        Text("No matching sessions")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.vertical, 24)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: model.selection) { _, sel in
                if let sel { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(sel, anchor: .center) } }
            }
        }
    }

    // MARK: Footer (hints)

    private var footer: some View {
        HStack(spacing: 16) {
            hint("↑↓", "navigate")
            hint("↵", "open")
            hint("⌘N", "new chat")
            hint("esc", "dismiss")
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).fontWeight(.semibold)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
        }
    }
}

private struct GroupHeader: View {
    let project: String
    var body: some View {
        Text(project == "Other" ? "OTHER · LEGACY" : project.uppercased())
            .font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
    }
}

private struct CollapseTail: View {
    let label: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis").font(.system(size: 10, weight: .bold))
            Text(label).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
    }
}

private struct SessionRow: View {
    let session: ChatSession
    let selected: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
                .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 0.5))
            Text(session.label).lineLimit(1)
                .font(.system(size: 14))
            Spacer(minLength: 12)
            if let kind = session.kind {
                Text(kind).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.white.opacity(0.07), in: Capsule())
            }
            Text(SessionStore.ageLabel(now.timeIntervalSince(session.lastActive)))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.28) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
    }

    private var dotColor: Color {
        switch session.state {
        case .liveBusy: return .green
        case .liveIdle: return .secondary
        case .cold:     return .clear
        }
    }
}
