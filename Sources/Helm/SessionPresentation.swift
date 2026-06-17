import SwiftUI
import AppKit
import HelmCore

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
///
/// Quiet by default: a working session is a static grey mark with no motion or glow, so a
/// screen full of them recedes behind the text. Color and a gentle pulse are reserved for the
/// states that actually want you — needs-input (amber) and needs-review (violet).
private struct ClaudeSessionASCIIIndicator: View {
    let state: SessionState
    var needsInput: Bool = false
    var suppressAnimations: Bool = false

    private static let needsInputFrames = ["·", "✢", "✦", "✢", "·"]
    private static let needsReviewFrames = ["✢", "✣", "✤", "✥", "✤", "✣"]

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Only an attention state carries color and the soft glow that draws the eye.
    private var attentive: Bool {
        if case .liveIdle = state { return true }
        return false
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
        case .liveIdle: return needsInput ? Self.needsInputFrames : Self.needsReviewFrames
        case .liveBusy, .cold: return nil
        }
    }

    private var frameInterval: TimeInterval {
        needsInput ? 0.18 : 0.16
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
        case .liveBusy: return HelmColors.textSecondary
        case .liveIdle: return needsInput ? HelmColors.amber : HelmColors.violet
        case .cold: return HelmColors.textTertiary
        }
    }

    private func glyph(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 14))
            .offset(y: -0.5)
            .foregroundStyle(color)
            .shadow(color: attentive ? color.opacity(0.35) : .clear, radius: attentive ? 1.5 : 0)
    }
}

/// Pi's mutable mark: the official badge reduced to rectangular tiles on a 4×4 grid.
/// Working/cold render the assembled mark statically in grey; needs-input pulses a tile
/// in amber so it's the only Pi glyph that moves.
private struct PiSessionGlyph: View {
    let state: SessionState
    let needsInput: Bool

    private static let cells: [Cell] = [
        .init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 2, y: 0),
        .init(x: 0, y: 1),                 .init(x: 2, y: 1),
        .init(x: 0, y: 2), .init(x: 1, y: 2),                 .init(x: 3, y: 2),
        .init(x: 0, y: 3),                                 .init(x: 3, y: 3)
    ]

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var attentive: Bool {
        if case .liveIdle = state { return true }
        return false
    }

    private var color: Color {
        switch state {
        case .liveBusy: return HelmColors.textSecondary
        case .liveIdle: return needsInput ? HelmColors.amber : HelmColors.violet
        case .cold: return HelmColors.textTertiary
        }
    }

    var body: some View {
        Group {
            if state == .liveIdle, needsInput, !reduceMotion {
                TimelineView(.animation(minimumInterval: 0.12)) { ctx in
                    mark(visible: Set(Self.cells.indices), dimmed: missingTile(at: ctx.date))
                }
            } else {
                mark(visible: Set(Self.cells.indices), dimmed: [])
            }
        }
        .frame(width: 14, height: 14, alignment: .center)
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
        .shadow(color: attentive ? color.opacity(0.35) : .clear, radius: attentive ? 1.5 : 0)
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
