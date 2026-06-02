import SwiftUI
import HelmCore

/// The tasks-view body. Lives inside the same `NSPanel` as the sessions view; the
/// chrome (material, rounded border) is reproduced here so the two views look like
/// peers from the user's POV.
///
/// Layout mirrors the Übersicht widget so muscle memory transfers: status pill on the
/// left (click to cycle), title in the middle with subtask counter and age tag, source
/// icon on the right.
struct TaskListView: View {
    @ObservedObject var model: TaskListViewModel
    @ObservedObject var shell: AppShellModel
    let onOpen: (VaultTask) -> Void
    let onCycle: () -> Void
    let onOpenSource: (TaskSource) -> Void

    /// Content only; chrome lives in `RootView` (see `OverlayView` for the same note).
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
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            HStack(spacing: 2) {
                if model.query.isEmpty {
                    ZStack(alignment: .leading) {
                        Text("Type to filter tasks…")
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
            Text("\(model.openCount) active · \(model.doneCount) done")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.active) { task in
                        TaskRow(task: task,
                                selected: task.basename == model.selection,
                                archived: false,
                                now: model.now,
                                onCycle: onCycle,
                                onOpen: { onOpen(task) },
                                onOpenSource: onOpenSource)
                            .id(task.basename)
                            .transition(.rowEnterLeave)
                    }
                    if !model.archive.isEmpty {
                        ArchiveHeader(count: model.archive.count)
                        ForEach(model.archive) { task in
                            TaskRow(task: task,
                                    selected: task.basename == model.selection,
                                    archived: true,
                                    now: model.now,
                                    onCycle: {},
                                    onOpen: { onOpen(task) },
                                    onOpenSource: onOpenSource)
                                .id("a:" + task.basename)
                                .transition(.rowEnterLeave)
                        }
                    }
                    if model.active.isEmpty && model.archive.isEmpty {
                        Text(model.query.isEmpty ? "The list is clear" : "No matching tasks")
                            .font(.system(size: 13)).italic()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.vertical, 24)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: model.selection) { _, sel in
                if let sel { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(sel, anchor: .center) } }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 16) {
            HintBar(hints: [Hint(key: "↑↓", label: "navigate"),
                            Hint(key: "↵", label: "open"),
                            Hint(key: "⌘↵", label: "cycle"),
                            Hint(key: "esc", label: "dismiss")])
            Spacer()
            ModeSwitcher(shell: shell)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }
}

// MARK: Row

/// One task row. Status pill at left (clickable), title and counters in the middle,
/// optional source badge at right. Selected row gets a subtle highlight backplate so
/// keyboard nav lands somewhere visible.
private struct TaskRow: View {
    let task: VaultTask
    let selected: Bool
    let archived: Bool
    let now: Date
    let onCycle: () -> Void
    let onOpen: () -> Void
    let onOpenSource: (TaskSource) -> Void

    private var flags: TaskAgeFlags { TaskStore.ageFlags(for: task, now: now) }

    var body: some View {
        HStack(spacing: 12) {
            StatusPill(status: task.status, archived: archived, flags: flags)
                .frame(width: 64)
                .onTapGesture(perform: archived ? {} : onCycle)
            HStack(spacing: 6) {
                Text(task.title)
                    .font(.system(size: 13))
                    .strikethrough(task.status == .done || archived)
                    .foregroundStyle((task.status == .done || archived) ? .secondary : .primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if task.subtasksTotal > 0 {
                    Text("\(task.subtasksDone)/\(task.subtasksTotal)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(task.subtasksDone == task.subtasksTotal
                                         ? Color.green.opacity(0.7) : .secondary)
                }
                if !flags.label.isEmpty {
                    Text(flags.label)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(ageTagColor(flags))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            Spacer(minLength: 8)
            if let src = task.source {
                SourceBadge(source: src).onTapGesture { onOpenSource(src) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(selected ? Color.white.opacity(0.09) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
    }

    private func ageTagColor(_ f: TaskAgeFlags) -> Color {
        if f.overdue { return Color(red: 0.79, green: 0.45, blue: 0.45) }     // #c97474
        if f.staleWip { return Color(red: 0.79, green: 0.64, blue: 0.45) }    // #c9a474
        if f.checkin { return Color(red: 0.83, green: 0.63, blue: 0.29) }     // #d4a14a
        return .secondary
    }
}

/// The status pill at the left edge of a row. Color/border/opacity tokens are ported
/// from the widget CSS so the two views read as the same UI.
private struct StatusPill: View {
    let status: TaskStatus
    let archived: Bool
    let flags: TaskAgeFlags

    var body: some View {
        HStack(spacing: 5) {
            if !archived && status == .wip { PulseDot() }
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .background(bg, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(border, lineWidth: 1))
        .foregroundStyle(fg)
        .opacity(archived || status == .done ? 0.55 : 1)
    }

    private var label: String { archived ? "archived" : status.rawValue }

    private var fg: Color {
        if archived { return Color(red: 0.54, green: 0.68, blue: 0.59) }       // #8aae96
        switch status {
        case .todo:    return Color(red: 0.70, green: 0.69, blue: 0.67)        // #b3b0aa
        case .wip:     return Color(red: 0.77, green: 0.83, blue: 1.00)        // #c4d4fe
        case .blocked: return Color(red: 0.90, green: 0.72, blue: 0.48)        // #e6b87a
        case .done:    return Color(red: 0.54, green: 0.68, blue: 0.59)        // #8aae96
        }
    }

    private var bg: Color {
        if archived { return Color(red: 0.23, green: 0.48, blue: 0.31).opacity(0.08) }
        switch status {
        case .todo:    return Color.white.opacity(0.04)
        case .wip:     return Color(red: 0.39, green: 0.53, blue: 1.0).opacity(0.10)
        case .blocked: return Color(red: 0.83, green: 0.63, blue: 0.29).opacity(0.10)
        case .done:    return Color(red: 0.23, green: 0.48, blue: 0.31).opacity(0.08)
        }
    }

    private var border: Color {
        // Age flags override the pill border (red for overdue, amber for check-in) so
        // a stale row pops without changing the status color itself.
        if flags.overdue || flags.staleWip { return Color(red: 0.90, green: 0.35, blue: 0.35).opacity(0.5) }
        if flags.checkin { return Color(red: 0.83, green: 0.63, blue: 0.29).opacity(0.6) }
        if archived { return Color(red: 0.23, green: 0.48, blue: 0.31).opacity(0.20) }
        switch status {
        case .todo:    return Color.white.opacity(0.10)
        case .wip:     return Color(red: 0.39, green: 0.53, blue: 1.0).opacity(0.26)
        case .blocked: return Color(red: 0.83, green: 0.63, blue: 0.29).opacity(0.30)
        case .done:    return Color(red: 0.23, green: 0.48, blue: 0.31).opacity(0.20)
        }
    }
}

/// Soft pulse on the `wip` pill — the widget uses the same effect to mark "this is the
/// thing I'm actively working on right now."
private struct PulseDot: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = (ctx.date.timeIntervalSinceReferenceDate / 1.8).truncatingRemainder(dividingBy: 1)
            let alpha = 0.35 + 0.65 * (0.5 + 0.5 * cos(2 * .pi * t))
            Circle()
                .fill(Color(red: 0.46, green: 0.58, blue: 1.0))
                .frame(width: 5, height: 5)
                .opacity(alpha)
                .shadow(color: Color(red: 0.46, green: 0.58, blue: 1.0).opacity(0.6), radius: 2)
        }
        .frame(width: 5, height: 5)
    }
}

/// Source indicator: a small letter chip, colored. We don't bundle the Jira/Slack
/// brand glyphs the widget uses — a clear `J`/`S` chip carries the same signal without
/// the asset baggage.
private struct SourceBadge: View {
    let source: TaskSource

    private var letter: String {
        switch source { case .jira: return "J"; case .slack: return "S" }
    }
    private var color: Color {
        switch source {
        case .jira:  return Color(red: 0.45, green: 0.53, blue: 0.71)    // #7388b6
        case .slack: return Color(red: 0.69, green: 0.55, blue: 0.75)    // #b08bbf
        }
    }

    var body: some View {
        Text(letter)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.30), lineWidth: 1))
    }
}

private struct ArchiveHeader: View {
    let count: Int
    var body: some View {
        Text("ARCHIVE · \(count) \(count == 1 ? "match" : "matches")")
            .font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
    }
}

