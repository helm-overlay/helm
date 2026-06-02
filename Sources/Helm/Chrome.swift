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
    }
}

/// Persistent mode tabs (Sessions · Tasks · …), built from `AppView.allCases`. The active
/// mode is filled; clicking one (or pressing its ⌘-digit) switches. A new `AppView` case
/// adds a pill here automatically — nothing to wire.
struct ModeSwitcher: View {
    @ObservedObject var shell: AppShellModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppView.allCases, id: \.self) { view in
                let active = shell.view == view
                Button { shell.view = view } label: {
                    HStack(spacing: 4) {
                        Image(systemName: view.symbol).font(.system(size: 10, weight: .semibold))
                        Text(view.title).font(.system(size: 11, weight: active ? .semibold : .regular))
                        Text("⌘\(view.shortcutDigit)").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(active ? .primary : .secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(active ? Color.white.opacity(0.12) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .focusEffectDisabled()   // clicking a pill shouldn't leave the keyboard focus ring on it
    }
}
