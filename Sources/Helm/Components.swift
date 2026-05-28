import SwiftUI

// Leaf views shared by the sessions and tasks overlays. Kept here (rather than copied
// privately into each view) so the two lists stay visually identical by construction.

/// A vertical-bar insertion caret that blinks on a fixed cadence, phased so it is
/// solid-on at `anchor` (the last edit) — the caret never blinks off mid-keystroke.
struct BlinkingCursor: View {
    let anchor: Date
    private let period = 0.53
    var body: some View {
        TimelineView(.periodic(from: anchor, by: period)) { ctx in
            let on = Int(ctx.date.timeIntervalSince(anchor) / period) % 2 == 0
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.primary)
                .frame(width: 2, height: 18)
                .opacity(on ? 1 : 0)
        }
    }
}

extension AnyTransition {
    /// New rows drop in from above and fade up; rows leaving the visible set — e.g. one
    /// pushed behind a "+N older" tail — slide down and fade out.
    static var rowEnterLeave: AnyTransition {
        .asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .move(edge: .bottom).combined(with: .opacity))
    }
}
