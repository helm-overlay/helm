import SwiftUI
import AppKit
import HelmCore

private enum AgentColors {
    static let claudeOrange = Color(red: 0.851, green: 0.467, blue: 0.341) // #D97757
    static let piCyan = Color(red: 0.133, green: 0.827, blue: 0.933)       // #22D3EE
}

struct SessionPresentation: AttentionSourcePresentation {
    func icon(for item: any AttentionItem) -> some View {
        Group {
            if let session = item as? ChatSession {
                SessionAgentGlyph(session: session)
            } else {
                EmptyView()
            }
        }
    }

    func tint(for item: any AttentionItem, defaultTint: Color) -> Color {
        guard let session = item as? ChatSession else { return defaultTint }
        if session.reason == .live {
            switch session.agent {
            case .claude: return AgentColors.claudeOrange
            case .pi: return AgentColors.piCyan
            }
        }
        return defaultTint
    }
}

struct SessionAgentGlyph: View {
    let session: ChatSession

    var body: some View {
        switch session.agent {
        case .claude:
            ClaudeSessionASCIIIndicator(state: session.state, needsInput: session.needsInput)
        case .pi:
            PiSessionGlyph(state: session.state, needsInput: session.needsInput)
        }
    }
}

/// Claude Code's terminal-style ASCII session glyph. This is source-specific presentation,
/// not part of Helm's orbit glyph vocabulary.
private struct ClaudeSessionASCIIIndicator: View {
    let state: SessionState
    var needsInput: Bool = false
    var suppressAnimations: Bool = false

    private static let busyFrames = ["·", "✻", "✽", "✶", "✳", "✢"]
    private static let needsInputFrames = ["·", "✢", "✦", "✢", "·"]
    private static let needsReviewFrames = ["✢", "✣", "✤", "✥", "✤", "✣"]
    private static let orange = AgentColors.claudeOrange
    private static let amber = Color(red: 0.984, green: 0.749, blue: 0.141)
    private static let violet = Color(red: 0.655, green: 0.545, blue: 0.980)
    private static let gray = Color.white.opacity(0.32)

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        Group {
            if !reduceMotion && !suppressAnimations, let frames = animatedFrames {
                TimelineView(.animation(minimumInterval: frameInterval)) { ctx in
                    glyph(frames[frameIndex(at: ctx.date, interval: frameInterval, count: frames.count)], color: staticColor)
                }
            } else {
                glyph(staticGlyph, color: staticColor)
            }
        }
        .frame(width: 14, height: 14, alignment: .center)
    }

    private func frameIndex(at date: Date, interval: TimeInterval, count: Int) -> Int {
        Int((date.timeIntervalSinceReferenceDate / interval).rounded(.down)) % count
    }

    private var animatedFrames: [String]? {
        switch state {
        case .liveBusy: return Self.busyFrames
        case .liveIdle: return needsInput ? Self.needsInputFrames : Self.needsReviewFrames
        case .cold: return nil
        }
    }

    private var frameInterval: TimeInterval {
        switch state {
        case .liveBusy: return 0.12
        case .liveIdle: return needsInput ? 0.18 : 0.16
        case .cold: return 0.2
        }
    }

    private var staticGlyph: String {
        switch state {
        case .liveBusy: return "✻"
        case .liveIdle: return needsInput ? "✦" : "✥"
        case .cold: return "·"
        }
    }

    private var staticColor: Color {
        switch state {
        case .liveBusy: return Self.orange
        case .liveIdle: return needsInput ? Self.amber : Self.violet
        case .cold: return Self.gray
        }
    }

    private func glyph(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .offset(y: -0.5)
            .foregroundStyle(color)
            .shadow(color: color.opacity(state == .cold ? 0 : 0.45), radius: state == .cold ? 0 : 2)
    }
}

/// Pi's mutable mark: the official badge reduced to rectangular tiles on a 4×4 grid.
/// While Pi is working, the tiles repeatedly assemble the mark, hold, then reconstruct.
private struct PiSessionGlyph: View {
    let state: SessionState
    let needsInput: Bool

    private static let cells: [Cell] = [
        .init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 2, y: 0),
        .init(x: 0, y: 1),                 .init(x: 2, y: 1),
        .init(x: 0, y: 2), .init(x: 1, y: 2),                 .init(x: 3, y: 2),
        .init(x: 0, y: 3),                                 .init(x: 3, y: 3)
    ]

    /// Assembly groups timed as 320ms, 320ms, 400ms, 480ms, then 720ms hold.
    private static let groups: [[Int]] = [
        [0, 3, 5, 8],     // left stem
        [1, 2],           // top cap
        [4, 6],           // inner bend
        [7, 9],           // right foot
        []                // hold complete mark
    ]
    private static let phaseEnds: [TimeInterval] = [0.32, 0.64, 1.04, 1.52, 2.24]

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var color: Color {
        switch state {
        case .liveBusy: return AgentColors.piCyan
        case .liveIdle: return needsInput ? HelmColors.amber : HelmColors.violet
        case .cold: return Color.white.opacity(0.32)
        }
    }

    var body: some View {
        Group {
            if state == .liveBusy && !reduceMotion {
                TimelineView(.animation(minimumInterval: 0.08)) { ctx in
                    mark(visible: visibleCells(at: ctx.date), dimmed: [])
                }
            } else if state == .liveIdle, needsInput, !reduceMotion {
                TimelineView(.animation(minimumInterval: 0.12)) { ctx in
                    mark(visible: Set(Self.cells.indices), dimmed: missingTile(at: ctx.date))
                }
            } else {
                mark(visible: Set(Self.cells.indices), dimmed: [])
            }
        }
        .frame(width: 14, height: 14, alignment: .center)
    }

    private func visibleCells(at date: Date) -> Set<Int> {
        let cycle = Self.phaseEnds.last ?? 0.56
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
        var visible = Set<Int>()
        for (index, end) in Self.phaseEnds.enumerated() where t >= end {
            visible.formUnion(Self.groups[index])
        }
        return visible
    }

    private func missingTile(at date: Date) -> Set<Int> {
        let pulse = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1)
        return pulse < 0.55 ? [7, 9] : []
    }

    private func mark(visible: Set<Int>, dimmed: Set<Int>) -> some View {
        ZStack {
            ForEach(Array(Self.cells.indices), id: \.self) { index in
                tile(Self.cells[index], visible: visible.contains(index), dimmed: dimmed.contains(index))
            }
        }
        .shadow(color: color.opacity(state == .cold ? 0 : 0.45), radius: state == .cold ? 0 : 2)
    }

    private func tile(_ cell: Cell, visible: Bool, dimmed: Bool) -> some View {
        let tile: CGFloat = 3.25
        let pitch = tile
        return Rectangle()
            .fill(color)
            .frame(width: tile, height: tile)
            .opacity(tileOpacity(visible: visible, dimmed: dimmed))
            .scaleEffect(visible ? 1 : 0.55)
            .position(x: CGFloat(cell.x) * pitch + tile / 2,
                      y: CGFloat(cell.y) * pitch + tile / 2)
            .animation(.easeOut(duration: 0.18), value: visible)
            .animation(.easeInOut(duration: 0.24), value: dimmed)
    }

    private func tileOpacity(visible: Bool, dimmed: Bool) -> Double {
        guard visible else { return 0 }
        if dimmed { return 0.18 }
        if state == .cold { return 0.72 }
        return 1
    }

    private struct Cell {
        let x: Int
        let y: Int
    }
}
