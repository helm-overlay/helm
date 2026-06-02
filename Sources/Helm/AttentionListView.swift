import SwiftUI
import AppKit
import HelmCore

/// The attention launcher — the default view. One urgency-ranked list of everything that
/// wants you, across sessions and PRs, each row keeping its source's orbit glyph. Working
/// sessions trail in a dimmed section. Enter opens whatever's selected (resume a session,
/// open a PR in the browser) via the item's own primary action.
struct AttentionListView: View {
    @ObservedObject var model: AttentionListViewModel
    @ObservedObject var shell: AppShellModel
    let onOpen: (any AttentionItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            list
            Divider().opacity(0.5)
            footer
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            HStack(spacing: 2) {
                if model.query.isEmpty {
                    ZStack(alignment: .leading) {
                        Text("Type to filter…")
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
            Text("\(model.attentionCount) need you · \(model.workingCount) working")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    // One SESSIONS section: attention rows first, working sessions dimmed at
                    // the bottom (urgency-ordered in the model). Each ForEach owns its rows'
                    // identity (id: \.id) — no explicit .id() on the row, which would collide
                    // across sections and make SwiftUI reuse a moved row's stale view/icon.
                    if !model.sessions.isEmpty {
                        SectionHeader(title: "SESSIONS")
                        ForEach(model.sessions, id: \.id) { s in
                            AttentionRow(item: s, dimmed: s.reason == .live,
                                         selected: s.id == model.selection, onOpen: { onOpen(s) })
                                .transition(.rowEnterLeave)
                        }
                    }

                    if !model.attentionPRs.isEmpty {
                        SectionHeader(title: "PULL REQUESTS")
                        ForEach(model.attentionPRs, id: \.id) { pr in
                            AttentionRow(item: pr, dimmed: false,
                                         selected: pr.id == model.selection, onOpen: { onOpen(pr) })
                                .transition(.rowEnterLeave)
                        }
                    }

                    if model.visibleRowCount == 0 { emptyState }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: model.selection) { _, sel in
                if let sel { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(sel, anchor: .center) } }
            }
        }
    }

    private var emptyState: some View {
        Text(model.loading ? "Loading…" : (model.query.isEmpty ? "Nothing wants you right now" : "No matches"))
            .font(.system(size: 13)).italic()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 24)
            .frame(maxWidth: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 16) {
            HintBar(hints: [Hint(key: "↵", label: "open"),
                            Hint(key: "⌘X", label: "kill"),
                            Hint(key: "esc", label: "dismiss")])
            Spacer(minLength: 12)
            ModeSwitcher(shell: shell)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }
}

// MARK: Row

/// One attention row, type-agnostic. The leading glyph is the item's native orbit indicator
/// (session satellite or PR orbit); the rest is a shared layout — context (project / repo),
/// title, and a reason chip tinted to the urgency.
private struct AttentionRow: View {
    let item: any AttentionItem
    let dimmed: Bool
    let selected: Bool
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            indicator
                .opacity(dimmed ? 0.65 : 1)

            Text(context)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                .lineLimit(1)
                .frame(width: 128, alignment: .leading)

            Text(item.title)
                .font(.system(size: 13))
                .foregroundStyle(dimmed ? .secondary : .primary)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 8)

            Text(reasonLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
                .lineLimit(1)
                .frame(width: 96, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(selected ? Color.white.opacity(0.09) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
    }

    @ViewBuilder private var indicator: some View {
        if let s = item as? ChatSession {
            OrbitIndicator(state: s.state, needsInput: s.needsInput)
        } else if let pr = item as? PullRequest {
            PROrbitIndicator(state: pr.orbitState)
        }
    }

    /// Project for a session, repo basename for a PR — the "where" that anchors the row.
    private var context: String {
        if let s = item as? ChatSession { return s.project }
        if let pr = item as? PullRequest { return pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo }
        return ""
    }

    private var reasonLabel: String { AttentionPalette.label(item.reason) }
    private var tint: Color { AttentionPalette.color(item.reason) }
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Maps an `AttentionReason` to its launcher color + short label. Reuses the orbit palette
/// so a row's chip matches its glyph.
enum AttentionPalette {
    static func color(_ reason: AttentionReason) -> Color {
        switch reason {
        case .needsInput:                       return PROrbitIndicator.amber
        case .needsReview:                      return Color(red: 0.655, green: 0.545, blue: 0.980)  // violet
        case .prReviewRequested:                return PROrbitIndicator.amber
        case .prChangesRequested:               return PROrbitIndicator.rose
        case .prCiFailed:                       return PROrbitIndicator.red
        case .prMergeable:                      return PROrbitIndicator.emerald
        case .live:                             return PROrbitIndicator.emerald
        case .none:                             return PROrbitIndicator.slate
        }
    }

    static func label(_ reason: AttentionReason) -> String {
        switch reason {
        case .needsInput:         return "needs input"
        case .needsReview:        return "review"
        case .prReviewRequested:  return "review requested"
        case .prChangesRequested: return "changes"
        case .prCiFailed:         return "CI failed"
        case .prMergeable:        return "ready"
        case .live:               return "working"
        case .none:               return ""
        }
    }
}
