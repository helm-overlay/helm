import SwiftUI
import AppKit
import HelmCore

/// The PRs-view body. A peer of the sessions and tasks views inside the same panel: a
/// filter header, a flat list of pull requests (review-requested-of-me + my own open PRs),
/// and the shared footer. Each row leads with an orbit indicator — the same satellite/ring
/// vocabulary the sessions view uses — and foregrounds the repo, since which repo a PR is in
/// is half of what identifies it.
struct PRListView: View {
    @ObservedObject var model: PRListViewModel
    @ObservedObject var shell: AppShellModel
    let onOpen: (PullRequest) -> Void

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
                        Text("Type to filter pull requests…")
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
            Text("\(model.reviewCount) to review · \(model.mineCount) mine")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.prs) { pr in
                        PRRow(pr: pr, selected: pr.id == model.selection, onOpen: { onOpen(pr) })
                            .id(pr.id)
                            .transition(.rowEnterLeave)
                    }
                    if model.prs.isEmpty { emptyState }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: model.selection) { _, sel in
                if let sel { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(sel, anchor: .center) } }
            }
        }
    }

    private var emptyState: some View {
        Text(emptyText)
            .font(.system(size: 13)).italic()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 24)
            .frame(maxWidth: .infinity)
    }

    private var emptyText: String {
        if model.loading { return "Loading pull requests…" }
        return model.query.isEmpty ? "No open pull requests" : "No matching pull requests"
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 16) {
            HintBar(hints: [Hint(key: "↑↓", label: "navigate"),
                            Hint(key: "↵", label: "open"),
                            Hint(key: "esc", label: "dismiss")])
            Spacer()
            ModeSwitcher(shell: shell)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }
}

// MARK: Row

private struct PRRow: View {
    let pr: PullRequest
    let selected: Bool
    let onOpen: () -> Void

    private var orbit: PROrbitState { pr.orbitState }
    /// Repo basename — the part that varies and identifies the PR at a glance; the owner is
    /// near-constant and only crowds the column.
    private var repoName: String { pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo }

    var body: some View {
        HStack(spacing: 11) {
            PROrbitIndicator(state: orbit)

            Text(repoName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(orbit.tint)
                .lineLimit(1)
                .frame(width: 128, alignment: .leading)

            Text(pr.title)
                .font(.system(size: 13))
                .foregroundStyle(orbit == .draft ? .secondary : .primary)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 8)

            Text(orbit.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(orbit.tint)
                .lineLimit(1)
                .frame(width: 66, alignment: .trailing)
            // verbatim so the PR number isn't run through locale number-grouping (which
            // renders #166927 as "1,66,927").
            Text(verbatim: "#\(pr.number)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(selected ? Color.white.opacity(0.09) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
    }
}

// MARK: Orbital state

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

// MARK: Orbit indicator

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
