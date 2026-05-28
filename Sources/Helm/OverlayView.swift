import SwiftUI
import AppKit
import HelmCore

struct OverlayView: View {
    @ObservedObject var model: SessionListViewModel
    let onPick: (ChatSession) -> Void
    let onNewChat: () -> Void
    let onDismiss: () -> Void

    /// Renders content only; the panel chrome (material, border, rounded corner) is
    /// owned by `RootView` so view switches crossfade the content without doubling
    /// the material layer.
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

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.groups) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                SessionRow(session: session,
                                           selected: session.sessionId == model.selection,
                                           now: model.now)
                                    .id(session.sessionId)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onPick(session) }
                                    .transition(.rowEnterLeave)
                            }
                            if group.hiddenCount > 0 {
                                CollapseTail(label: "+\(group.hiddenCount) older")
                                    .onTapGesture { model.toggleFocus(group.project) }
                                    .transition(.rowEnterLeave)
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
            if model.focusedProject == nil {
                hint("⌘↓", "focus project")
                hint("⌘N", "new chat")
                hint("⌘X", "kill")
                hint("esc", "dismiss")
            } else {
                hint("⌘N", "new chat")
                hint("⌘X", "kill")
                hint("esc", "back")
            }
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
        HStack(spacing: 0) {
            if session.isPlaceholder {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
            } else {
                OrbitIndicator(state: session.state, needsInput: session.needsInput)
                    .frame(width: 14, height: 14)
            }
            HStack(spacing: 10) {
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
private struct OrbitIndicator: View {
    let state: SessionState
    var needsInput: Bool = false

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
        .onChange(of: state) { old, new in transition(from: old, to: new) }
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: dashed)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: state)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: needsInput)
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
        if reduceMotion {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t, body)
        } else {
            withAnimation(animation, body)
        }
    }
}
