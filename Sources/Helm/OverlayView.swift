import SwiftUI
import AppKit
import HelmCore

struct OverlayView: View {
    @ObservedObject var model: SessionListViewModel
    @ObservedObject var shell: AppShellModel
    let onPick: (ChatSession) -> Void
    let onNewChat: () -> Void
    let onDismiss: () -> Void

    /// Renders content only; the panel chrome (material, border, rounded corner) is
    /// owned by `RootView` so view switches crossfade the content without doubling
    /// the material layer.
    private let masterWidth: CGFloat = 220
    private let railCap = 6     // most live rows shown in the rail before a "+N more" note

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if model.isSearching {
                searchResults
            } else {
                railSection
                Divider().opacity(0.5)
                masterDetail
            }
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
                        Text("Type to filter sessions…")
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
                                .padding(.horizontal, -4)   // bleed the highlight without moving the text
                        )
                    if !model.querySelected { BlinkingCursor(anchor: model.lastEdit) }
                }
            }
            Spacer()
            Text("\(model.liveCount) live · \(model.totalCount) total")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: LIVE rail (pinned, cross-project)

    private var railSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("LIVE")
            if model.liveRail.isEmpty {
                Text("Nothing running")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.liveRail.prefix(railCap)) { s in
                        row(s, showsProject: true,
                            selected: model.zone == .live && s.id == model.liveSelection)
                    }
                    if model.liveRail.count > railCap {
                        Text("+\(model.liveRail.count - railCap) more live")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 20).padding(.vertical, 3)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: Master (projects) + detail (selected project's cold history)

    private var masterDetail: some View {
        HStack(spacing: 0) {
            projectsMaster.frame(width: masterWidth)
            Divider().opacity(0.5)
            detailPane.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity)
    }

    private var projectsMaster: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("PROJECTS")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.projectSummaries) { p in
                        ProjectMasterRow(summary: p,
                                         active: p.project == model.selectedProject,
                                         focused: p.project == model.selectedProject && model.zone == .projects)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectProject(p.project) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(detailTitle)
            if model.detailRows.isEmpty {
                Text("No cold sessions — live shown above")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 16).padding(.top, 4)
                Spacer()
            } else {
                sessionScrollList(model.detailRows, showsProject: false,
                                  selectedID: model.zone == .cold ? model.coldSelection : nil)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var detailTitle: String {
        guard let p = model.selectedProject else { return "HISTORY" }
        let cold = model.projectSummaries.first { $0.project == p }?.coldCount ?? 0
        return "\(p.uppercased())  ·  \(cold) cold"
    }

    // MARK: Search (cross-project, full width)

    private var searchResults: some View {
        Group {
            if model.detailRows.isEmpty {
                VStack {
                    Text("No matching sessions").foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 24)
                    Spacer()
                }
            } else {
                sessionScrollList(model.detailRows, showsProject: true, selectedID: model.coldSelection)
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Row plumbing

    private func sessionScrollList(_ rows: [ChatSession], showsProject: Bool, selectedID: String?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { s in
                        row(s, showsProject: showsProject, selected: s.id == selectedID)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.coldSelection) { _, sel in
                guard let sel else { return }
                if model.suppressAnimations {
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { proxy.scrollTo(sel, anchor: .center) }
                } else {
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(sel, anchor: .center) }
                }
            }
        }
    }

    private func row(_ session: ChatSession, showsProject: Bool, selected: Bool) -> some View {
        SessionRow(session: session,
                   selected: selected,
                   now: model.now,
                   showsProject: showsProject,
                   suppressAnimations: model.suppressAnimations)
            .id(session.id)
            .contentShape(Rectangle())
            .onTapGesture { onPick(session) }
            .transition(.rowEnterLeave)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Footer (hints)

    private var footer: some View {
        HStack(spacing: 16) {
            HintBar(hints: hints)
            Spacer()
            ModeSwitcher(shell: shell)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private var hints: [Hint] {
        var h = [Hint(key: "↑↓", label: "navigate")]
        if !model.isSearching { h.append(Hint(key: "←→", label: "project")) }
        h += [Hint(key: "↵", label: "open"),
              Hint(key: "⌘O", label: "add folder"),
              Hint(key: "⌘N", label: "new chat"),
              Hint(key: "⌘X", label: "kill")]
        if model.canRemoveSelectedWorkspaceFolder { h.append(Hint(key: "⌘⌫", label: "remove folder")) }
        h.append(Hint(key: "esc", label: "dismiss"))
        return h
    }
}

private struct ProjectMasterRow: View {
    let summary: ProjectSummary
    let active: Bool       // its history is the one shown in the detail pane
    let focused: Bool      // the keyboard is currently in the PROJECTS zone, on this row

    private static let emerald = Color(red: 0.204, green: 0.827, blue: 0.600)  // #34D399

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(active ? Color.accentColor : .clear)
            Text(summary.project).lineLimit(1)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(.primary)
            Spacer(minLength: 6)
            if summary.liveCount > 0 {
                HStack(spacing: 3) {
                    Circle().fill(Self.emerald).frame(width: 5, height: 5)
                    Text("\(summary.liveCount)").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Self.emerald)
                }
            }
            Text("\(summary.coldCount)")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .frame(minWidth: 16, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(background, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
    }

    private var background: Color {
        if focused { return Color.white.opacity(0.12) }   // keyboard is here
        if active  { return Color.white.opacity(0.05) }   // its history is on the right
        return .clear
    }
}

private struct SessionRow: View {
    let session: ChatSession
    let selected: Bool
    let now: Date
    var showsProject: Bool = false
    let suppressAnimations: Bool

    var body: some View {
        HStack(spacing: 0) {
            if session.isPlaceholder {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
            } else {
                OrbitIndicator(state: session.state, needsInput: session.needsInput, suppressAnimations: suppressAnimations)
                    .frame(width: 14, height: 14)
            }
            HStack(spacing: 10) {
                if showsProject {
                    Text(session.project).lineLimit(1)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: 78, alignment: .leading)
                }
                Text(session.label).lineLimit(1)
                    .font(.system(size: 14))
                    .foregroundStyle(session.isPlaceholder ? .tertiary : .primary)
                    .italic(session.isPlaceholder)
                Spacer(minLength: 12)
                if let kind = session.kind {
                    Text(kind).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.white.opacity(0.06), in: Capsule())
                }
                if !session.isPlaceholder {
                    Text(SessionStore.ageLabel(now.timeIntervalSince(session.lastActive)))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .frame(width: 48, alignment: .trailing)
                }
            }
            .padding(.leading, 12)
        }
        .padding(.leading, 12).padding(.trailing, 12).padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(selected ? Color.white.opacity(0.09) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
        .transaction { transaction in
            if suppressAnimations { transaction.disablesAnimations = true }
        }
    }
}

/// Orbit-metaphor status indicator. The ring is always present; only the satellite's
/// behavior encodes state — it circles for `liveBusy` (motion == alive now), parks at
/// 9 o'clock for `liveIdle`, and is gone (ring goes dashed) for `cold`. An idle session
/// that's waiting on the user (`needsInput`) parks in amber and pings a sonar ring
/// outward; an idle session that finished cleanly (`needsReview`) parks in violet while the
/// ring draws itself to a full circle and holds (a progress ring at 100%, says "ready to review").
/// Transitions glide/fade rather than snap. Reduce-motion parks busy at the top and
/// holds the knock/fill steady.
///
/// Busy rotation is a pure function of one shared wall clock, so every running session's
/// orbit holds the same phase — the synced field reads as one calm hum (common fate),
/// letting the lone amber knock break from it and grab the eye. All motion is driven by
/// per-row `TimelineView(.animation)` (display-link, self-pausing when offscreen) rather
/// than a per-row timer, so an idle field of rows costs nothing to keep on screen.
struct OrbitIndicator: View {
    let state: SessionState
    var needsInput: Bool = false
    var suppressAnimations: Bool = false

    private static let emerald = Color(red: 0.204, green: 0.827, blue: 0.600)  // #34D399
    private static let amber = Color(red: 0.984, green: 0.749, blue: 0.141)    // #FBBF24
    private static let violet = Color(red: 0.655, green: 0.545, blue: 0.980)   // #A78BFA — idle/done, "ready to verify"
    private static let gray = Color.white.opacity(0.28)
    private static let center = CGPoint(x: 7, y: 7)
    private static let radius: CGFloat = 6.5
    private static let park: Double = 180          // 9 o'clock, in degrees
    private static let degPerSec = 360.0 / 2.5     // one revolution / 2.5s

    @State private var spin: Double = park          // satellite angle (deg)
    @State private var satelliteOpacity: Double = 1
    @State private var dashed = false               // ring style; flips after the dead fade

    /// Busy angle as a pure function of absolute time — identical across every orbit, so
    /// they share one phase instead of each drifting from its own appear time.
    private static func spin(at date: Date) -> Double {
        park + (date.timeIntervalSinceReferenceDate * degPerSec).truncatingRemainder(dividingBy: 360)
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    var body: some View {
        ZStack {
            ring
            satellite
        }
        .frame(width: 14, height: 14)
        .onAppear(perform: configureForAppear)
        .onChange(of: state) { old, new in
            if suppressAnimations { configureForAppear() }
            else { transition(from: old, to: new) }
        }
    }

    /// idle + waiting on the user. Drives the amber colorway and the pulse.
    private var knock: Bool { state == .liveIdle && needsInput }

    private var ringColor: Color {
        if state == .liveBusy { return Self.emerald.opacity(0.25) }
        if knock { return Self.amber.opacity(0.3) }
        if state == .liveIdle { return Self.violet.opacity(0.3) }
        return Self.gray
    }

    private var ring: some View {
        ZStack {
            Circle().strokeBorder(ringColor, lineWidth: 1)
                .opacity(dashed ? 0 : 1)
            Circle().strokeBorder(ringColor, style: StrokeStyle(lineWidth: 1, dash: [1.5, 2]))
                .opacity(dashed ? 1 : 0)
        }
        .animation((reduceMotion || suppressAnimations) ? nil : .easeInOut(duration: 0.3), value: dashed)
        .animation((reduceMotion || suppressAnimations) ? nil : .easeInOut(duration: 0.3), value: state)
        .animation((reduceMotion || suppressAnimations) ? nil : .easeInOut(duration: 0.3), value: needsInput)
    }

    private func point(forAngle a0: Double) -> CGPoint {
        let a = a0 * .pi / 180
        return CGPoint(x: Self.center.x + Self.radius * cos(a),
                       y: Self.center.y + Self.radius * sin(a))
    }
    private var satellitePoint: CGPoint { point(forAngle: spin) }

    /// `needsReview` motion: the ring track draws itself from the parked dot around to a
    /// full circle (a progress ring hitting 100%), holds, then fades and refills on a calm
    /// ~2.6s loop. It completes in place rather than circulating, so it reads as "finished,
    /// ready to review" — not the perpetual travel of the busy orbit.
    private func fillArc(_ color: Color) -> some View {
        TimelineView(.animation) { ctx in
            let phase = Self.fillPhase(at: ctx.date)
            Circle()
                .trim(from: 0, to: phase.end)
                .stroke(color.opacity(0.85 * phase.fade), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .rotationEffect(.degrees(Self.park))   // start the fill at the parked dot (9 o'clock)
                .frame(width: 13, height: 13)
        }
    }

    /// Ring-fill progress at `date`: arc end (0→1) and stroke fade, on a ~2.6s loop —
    /// race up to 100%, hold, then fade the full ring out before the next refill.
    private static func fillPhase(at date: Date) -> (end: Double, fade: Double) {
        let p = (date.timeIntervalSinceReferenceDate / 2.6).truncatingRemainder(dividingBy: 1)
        if p < 0.46 {
            let t = p / 0.46
            return (1 - pow(1 - t, 2), 1)
        } else if p < 0.72 {
            return (1, 1)
        } else {
            return (1, 1 - (p - 0.72) / 0.28)
        }
    }

    @ViewBuilder private var satellite: some View {
        let active = state == .liveBusy
        let review = state == .liveIdle && !knock
        let color = active ? Self.emerald : (knock ? Self.amber : (review ? Self.violet : Self.gray))
        let glowing = active || knock || review
        if active && !reduceMotion {
            // Busy orbit: position is a pure function of the shared wall clock, drawn each
            // display frame by this row's TimelineView — no per-row timer to schedule.
            TimelineView(.animation) { ctx in
                dot(color, glowing: glowing).position(point(forAngle: Self.spin(at: ctx.date)))
            }
        } else if knock && !reduceMotion {
            // Sonar ping: a ring expands outward from the parked satellite and fades,
            // every 1.3s. Driven by scaleEffect (Core Animation transform) so the
            // growth is sub-pixel smooth; .frame() rebuilds layout each tick and
            // showed visible quantized steps. Ease-out gives the ripple a natural
            // "spread and settle" rather than a linear march.
            TimelineView(.animation) { ctx in
                let p = (ctx.date.timeIntervalSinceReferenceDate / 1.3)
                    .truncatingRemainder(dividingBy: 1)
                let eased = 1 - pow(1 - p, 2)
                ZStack {
                    Circle()
                        .stroke(color.opacity(1 - p), lineWidth: 1)
                        .frame(width: 4, height: 4)
                        .scaleEffect(1 + 1.5 * eased)
                    dot(color, glowing: glowing)
                }
                .position(satellitePoint)
            }
        } else if review && !reduceMotion {
            // Ring-fill: parked violet dot + the track drawing itself to 100% and holding.
            ZStack {
                fillArc(color)
                dot(color, glowing: glowing).position(satellitePoint)
            }
        } else {
            dot(color, glowing: glowing).position(satellitePoint).opacity(satelliteOpacity)
        }
    }

    private func dot(_ color: Color, glowing: Bool) -> some View {
        Circle()
            .fill(color)
            .frame(width: 4, height: 4)
            .shadow(color: glowing ? color.opacity(0.7) : .clear, radius: glowing ? 3 : 0)
    }

    private func configureForAppear() {
        switch state {
        case .liveBusy:  spin = reduceMotion ? 270 : Self.park; satelliteOpacity = 1; dashed = false
        case .liveIdle:  spin = Self.park; satelliteOpacity = 1; dashed = false
        case .cold:      satelliteOpacity = 0; dashed = true
        }
    }

    private func transition(from old: SessionState, to new: SessionState) {
        switch new {
        case .liveBusy:
            run(.easeOut(duration: 0.25)) { satelliteOpacity = 1; dashed = false }
        case .liveIdle:
            run(.easeOut(duration: 0.25)) { satelliteOpacity = 1; dashed = false }
            if reduceMotion { spin = Self.park }
            else {
                if old == .liveBusy { spin = Self.spin(at: Date()) }   // glide home from the live orbit angle
                run(.easeOut(duration: 0.3)) { spin = nextPark(from: spin) }
            }
        case .cold:
            // Satellite fades and the ring dashes in one beat, so death reads as a single
            // motion that settles with the row's slide to its cold slot — not a dotted ring
            // popping in before the satellite has gone.
            if !reduceMotion && old == .liveBusy { spin = Self.spin(at: Date()) }  // fade from where it orbited
            run(.easeInOut(duration: 0.3)) { satelliteOpacity = 0; dashed = true }
        }
    }

    /// Smallest forward angle ≥ `s` that lands the satellite back at the 9-o'clock park.
    private func nextPark(from s: Double) -> Double {
        let delta = ((Self.park - s).truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        return s + delta
    }

    private func run(_ animation: Animation, _ body: () -> Void) {
        if reduceMotion || suppressAnimations {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t, body)
        } else {
            withAnimation(animation, body)
        }
    }
}
