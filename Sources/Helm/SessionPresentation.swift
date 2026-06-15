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

    func tint(for item: any AttentionItem, defaultTint: Color) -> Color {
        guard let session = item as? ChatSession else { return defaultTint }
        if session.agent == .claude, session.reason == .live { return AttentionPalette.claudeOrange }
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
    private static let orange = AttentionPalette.claudeOrange
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

/// Pi's session glyph lives alongside the Claude glyph in session presentation. Kept simple
/// until Pi gets its own richer visual language.
private struct PiSessionGlyph: View {
    let state: SessionState
    let needsInput: Bool

    private var color: Color {
        switch state {
        case .liveBusy: return PROrbitIndicator.emerald
        case .liveIdle: return needsInput ? PROrbitIndicator.amber : PROrbitIndicator.violet
        case .cold: return Color.white.opacity(0.32)
        }
    }

    var body: some View {
        Text("π")
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .shadow(color: color.opacity(state == .cold ? 0 : 0.45), radius: state == .cold ? 0 : 2)
            .frame(width: 14, height: 14, alignment: .center)
    }
}
