import SwiftUI
import AppKit
import HelmCore

/// The attention launcher — the default view. One urgency-ranked list of everything that
/// wants you, across sessions and PRs, each row keeping its source's orbit glyph. Working
/// sessions trail in a dimmed section. Enter opens whatever's selected (resume a session,
/// open a PR in the browser) via the item's own primary action.
struct AttentionListView: View {
    @ObservedObject var model: AttentionListViewModel
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
                    // One titled section per source, urgency-ordered in the model so working
                    // rows trail at the bottom. The inner ForEach owns each row's
                    // identity (id: \.id, globally unique) — no explicit .id() on the row,
                    // which would collide across sections and reuse a moved row's stale view.
                    ForEach(model.sections) { section in
                        SectionHeader(title: section.title)
                        ForEach(section.rows) { row in
                            AttentionRow(item: row.item,
                                         presentation: section.presentation,
                                         expiringSoon: row.expiringSoon,
                                         selected: row.item.id == model.selection, onOpen: { onOpen(row.item) })
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
                            Hint(key: "⌘N", label: "new"),
                            Hint(key: "⌘X", label: "kill/stop"),
                            Hint(key: "esc", label: "dismiss")])
            Spacer(minLength: 12)
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
    let presentation: AnyAttentionSourcePresentation
    let expiringSoon: Bool
    let selected: Bool
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            indicator

            Text(context)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .lineLimit(1)
                .frame(width: 128, alignment: .leading)

            Text(item.title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 8)

            Text(reasonLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
                .lineLimit(1)
                .frame(width: 96, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(selected ? Color.white.opacity(0.09) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        // About to drop off the feed: a thin amber bar on the leading edge.
        .overlay(alignment: .leading) {
            if expiringSoon {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(HelmColors.amber)
                    .frame(width: 3)
                    .padding(.vertical, 6)
                    .padding(.leading, 1)
            }
        }
        .padding(.horizontal, 8)
    }

    private var indicator: some View {
        presentation.icon(for: item)
    }

    /// Project for a session, repo basename for a PR, folder for a Jenkins job — the "where"
    /// that anchors the row.
    private var context: String { item.context }

    private var reasonLabel: String { AttentionPalette.label(item.reason) }
    private var tint: Color {
        presentation.tint(for: item, defaultTint: AttentionPalette.color(item.reason))
    }
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
        case .needsInput:                       return HelmColors.amber
        case .needsReview:                      return HelmColors.violet
        case .prReviewRequested:                return HelmColors.amber
        case .prChangesRequested:               return HelmColors.rose
        case .prCiFailed:                       return HelmColors.red
        case .prMergeable:                      return HelmColors.emerald
        case .prCiRunning:                      return HelmColors.emerald
        case .prChecksGreen:                    return HelmColors.violet
        case .prInReview:                       return HelmColors.slate
        case .jenkinsFailed:                    return HelmColors.red
        case .jenkinsUnstable:                  return HelmColors.rose
        case .live:                             return HelmColors.emerald
        case .none:                             return HelmColors.slate
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
        case .prCiRunning:        return "CI running"
        case .prChecksGreen:      return "checks passed"
        case .prInReview:         return "in review"
        case .jenkinsFailed:      return "build failed"
        case .jenkinsUnstable:    return "unstable"
        case .live:               return "working"
        case .none:               return ""
        }
    }
}
