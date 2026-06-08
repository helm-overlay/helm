import SwiftUI

/// One keyboard hint in the footer (e.g. ⌘N · new chat). Each view owns its own list so
/// the footer reads as the active view's verbs, not a shared lowest common set.
struct Hint: Identifiable {
    let key: String
    let label: String
    var id: String { key + label }
}

/// Footer hint strip. Identical across every view; only the `hints` differ.
struct HintBar: View {
    let hints: [Hint]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(hints) { h in
                HStack(spacing: 4) {
                    Text(h.key).fontWeight(.semibold)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    Text(h.label)
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}
