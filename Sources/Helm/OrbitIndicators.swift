import SwiftUI
import AppKit
import HelmCore

// Orbit-metaphor status glyphs shared by the attention launcher's rows. A satellite orbits a
// ring; its motion encodes state. Sessions and pull requests reuse the same vocabulary.

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

// MARK: Pull request orbit

/// PR analogue of the sessions view's orbit states. The metaphor carries over: the ring is
/// the PR; the satellite's behavior is its status.
enum PROrbitState {
    case checksRunning     // CI in progress  → satellite orbits (work happening now)
    case wantsReview       // my review asked → amber sonar ping (someone's waiting on you)
    case changesRequested  // changes on mine → rose sonar ping (sent back to you)
    case failed            // CI red          → decayed orbit: satellite fallen, ring fractured
    case ready             // approved+green  → ring fills to 100% and holds (ready to merge)
    case open              // nothing notable → parked slate dot, solid ring
    case draft             // not ready       → dashed ring, faint dot

    var tint: Color {
        switch self {
        case .checksRunning, .ready: return PROrbitIndicator.emerald
        case .wantsReview:           return PROrbitIndicator.amber
        case .changesRequested:      return PROrbitIndicator.rose
        case .failed:                return PROrbitIndicator.red
        case .open:                  return PROrbitIndicator.slate
        case .draft:                 return PROrbitIndicator.gray
        }
    }

    var label: String {
        switch self {
        case .checksRunning:    return "checks…"
        case .wantsReview:      return "review"
        case .changesRequested: return "changes"
        case .failed:           return "CI failed"
        case .ready:            return "ready"
        case .open:             return ""
        case .draft:            return "draft"
        }
    }
}

extension PullRequest {
    var orbitState: PROrbitState {
        if isDraft { return .draft }
        if reviewRequestedFromMe { return .wantsReview }
        guard isMine else { return .open }
        if ciState == .failure { return .failed }
        if reviewState == .changesRequested { return .changesRequested }
        if reviewState == .approved && ciState == .success { return .ready }
        if ciState == .pending { return .checksRunning }
        return .open
    }
}

/// PR status as orbit motion, reusing the sessions indicator's vocabulary: a satellite
/// orbits a ring while checks run, pings outward when a PR wants you, fills the ring when
/// it's ready to merge, and decays (falls + fractures the ring) when CI is red.
struct PROrbitIndicator: View {
    let state: PROrbitState

    static let emerald = Color(red: 0.204, green: 0.827, blue: 0.600)
    static let amber   = Color(red: 0.984, green: 0.749, blue: 0.141)
    static let rose    = Color(red: 0.961, green: 0.451, blue: 0.522)
    static let red     = Color(red: 0.937, green: 0.357, blue: 0.357)
    static let slate   = Color(red: 0.553, green: 0.624, blue: 0.722)
    static let gray    = Color.white.opacity(0.28)

    private static let center = CGPoint(x: 7, y: 7)
    private static let radius: CGFloat = 6.5
    private static let park: Double = 180      // 9 o'clock
    private static let degPerSec = 360.0 / 2.5

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var color: Color { state.tint }

    var body: some View {
        ZStack { ring; satellite }.frame(width: 14, height: 14)
    }

    // MARK: Ring

    @ViewBuilder private var ring: some View {
        switch state {
        case .draft:
            Circle().strokeBorder(color.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [1.5, 2]))
        case .failed:
            Circle().strokeBorder(color.opacity(0.55), lineWidth: 1.2)   // solid red, slightly heavier
        default:
            Circle().strokeBorder(color.opacity(state == .open ? 0.35 : 0.3), lineWidth: 1)
        }
    }

    // MARK: Satellite

    @ViewBuilder private var satellite: some View {
        switch state {
        case .checksRunning where !reduceMotion:
            TimelineView(.animation) { ctx in
                dot(glowing: true).position(point(forAngle: Self.spin(at: ctx.date)))
            }
        case .wantsReview where !reduceMotion, .changesRequested where !reduceMotion:
            sonar
        case .ready where !reduceMotion:
            ZStack { fillArc; dot(glowing: true).position(point(forAngle: Self.park)) }
        case .failed:
            // Orbit collapsed: the satellite has fallen into the core — a red center inside
            // a red ring. Reads as "this came down" without the noisy fracture.
            dot(glowing: !reduceMotion).position(Self.center)
        case .draft:
            dot(glowing: false).opacity(0.6).position(point(forAngle: Self.park))
        default:
            dot(glowing: state != .open && state != .draft).position(point(forAngle: Self.park))
        }
    }

    /// A ring expands outward from the parked satellite and fades — "this wants you."
    private var sonar: some View {
        TimelineView(.animation) { ctx in
            let p = (ctx.date.timeIntervalSinceReferenceDate / 1.3).truncatingRemainder(dividingBy: 1)
            let eased = 1 - pow(1 - p, 2)
            ZStack {
                Circle().stroke(color.opacity(1 - p), lineWidth: 1)
                    .frame(width: 4, height: 4)
                    .scaleEffect(1 + 1.5 * eased)
                dot(glowing: true)
            }
            .position(point(forAngle: Self.park))
        }
    }

    /// Ring draws itself to a full circle and holds, then fades and refills — a progress
    /// ring hitting 100%, "ready to merge".
    private var fillArc: some View {
        TimelineView(.animation) { ctx in
            let phase = Self.fillPhase(at: ctx.date)
            Circle()
                .trim(from: 0, to: phase.end)
                .stroke(color.opacity(0.85 * phase.fade), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .rotationEffect(.degrees(Self.park))
                .frame(width: 13, height: 13)
        }
    }

    // MARK: Geometry / motion

    private func point(forAngle a0: Double) -> CGPoint {
        let a = a0 * .pi / 180
        return CGPoint(x: Self.center.x + Self.radius * cos(a),
                       y: Self.center.y + Self.radius * sin(a))
    }

    private func dot(glowing: Bool) -> some View {
        Circle().fill(color).frame(width: 4, height: 4)
            .shadow(color: glowing ? color.opacity(0.7) : .clear, radius: glowing ? 3 : 0)
    }

    private static func spin(at date: Date) -> Double {
        park + (date.timeIntervalSinceReferenceDate * degPerSec).truncatingRemainder(dividingBy: 360)
    }

    private static func fillPhase(at date: Date) -> (end: Double, fade: Double) {
        let p = (date.timeIntervalSinceReferenceDate / 2.6).truncatingRemainder(dividingBy: 1)
        if p < 0.46 { let t = p / 0.46; return (1 - pow(1 - t, 2), 1) }
        if p < 0.72 { return (1, 1) }
        return (1, 1 - (p - 0.72) / 0.28)
    }
}
