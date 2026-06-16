import SwiftUI

// Leaf views shared across the overlay's list views. Kept here (rather than copied
// privately into each view) so the lists stay visually identical by construction.

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

/// What `QueryLine` needs to draw a launcher's filter line. Both launcher view models
/// conform, so the two query lines render identically by construction.
@MainActor
protocol QueryLineModel: ObservableObject {
    var query: String { get }
    var querySelected: Bool { get }
    var queryBeforeCursor: String { get }
    var queryAfterCursor: String { get }
    var lastEdit: Date { get }
}

/// A launcher's editable filter line: placeholder when empty, otherwise the text with a
/// blinking caret drawn at the insertion point, or the whole buffer highlighted under ⌘A.
struct QueryLine<Model: QueryLineModel>: View {
    @ObservedObject var model: Model
    let placeholder: String
    private let font = Font.system(size: 15, weight: .regular)

    var body: some View {
        HStack(spacing: 0) {
            if model.query.isEmpty {
                ZStack(alignment: .leading) {
                    Text(placeholder).foregroundStyle(.secondary).font(font)
                    BlinkingCursor(anchor: model.lastEdit)
                }
            } else if model.querySelected {
                Text(model.query).foregroundStyle(.primary).font(font)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.35))
                            .padding(.horizontal, -4)
                    )
            } else {
                Text(model.queryBeforeCursor).foregroundStyle(.primary).font(font)
                BlinkingCursor(anchor: model.lastEdit)
                Text(model.queryAfterCursor).foregroundStyle(.primary).font(font)
            }
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
