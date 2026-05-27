import Foundation
import HelmCore

// Prints the merged live + history session tree the overlay will render.
// This is real app code (uses HelmCore directly), not a throwaway script.

func dot(_ s: SessionState) -> String {
    switch s {
    case .liveBusy: return "🟢"
    case .liveIdle: return "⚪️"
    case .cold:     return " ·"
    }
}

let store = SessionStore()
let now = Date()
let groups = store.grouped()

let liveCount = groups.flatMap(\.sessions).filter(\.isLive).count
let total = groups.flatMap(\.sessions).count
print("Helm — \(total) sessions across \(groups.count) groups (\(liveCount) live)\n")

for (project, sessions) in groups {
    let title = project == "Other" ? "Other (legacy — migrating)" : project
    print("▌ \(title)")
    for s in sessions {
        let when = SessionStore.ageLabel(now.timeIntervalSince(s.lastActive))
        let meta = s.isLive ? "\(s.kind ?? "?")/\(s.state.rawValue)" : "cold"
        let label = s.label.count > 34 ? String(s.label.prefix(33)) + "…" : s.label
        print("  \(dot(s.state))  \(label.padding(toLength: 34, withPad: " ", startingAt: 0))  \(when.padding(toLength: 6, withPad: " ", startingAt: 0))  \(meta)")
    }
    print("")
}
