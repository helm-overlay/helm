import SwiftUI
import HelmCore

/// UI-side companion to an `AttentionSource`. Core sources stay headless; their paired
/// presentation owns source-specific glyphs and tint overrides.
protocol AttentionSourcePresentation {
    associatedtype Icon: View

    @ViewBuilder
    func icon(for item: any AttentionItem) -> Icon

    func tint(for item: any AttentionItem, defaultTint: Color) -> Color
}

extension AttentionSourcePresentation {
    func tint(for item: any AttentionItem, defaultTint: Color) -> Color { defaultTint }
}

/// Type-erased presentation so the launcher can store heterogeneous source integrations.
struct AnyAttentionSourcePresentation {
    private let _icon: (any AttentionItem) -> AnyView
    private let _tint: (any AttentionItem, Color) -> Color

    init<P: AttentionSourcePresentation>(_ presentation: P) {
        self._icon = { AnyView(presentation.icon(for: $0)) }
        self._tint = presentation.tint
    }

    func icon(for item: any AttentionItem) -> AnyView { _icon(item) }

    func tint(for item: any AttentionItem, defaultTint: Color) -> Color {
        _tint(item, defaultTint)
    }
}

/// Single registration point for an attention integration: source + source-owned UI.
struct AttentionSourceRegistration {
    let source: any AttentionSource
    let presentation: AnyAttentionSourcePresentation
}

extension AttentionSourceRegistration {
    static let defaults: [AttentionSourceRegistration] = [
        .init(source: SessionFeedSource(), presentation: AnyAttentionSourcePresentation(SessionPresentation())),
        .init(source: PRSource(), presentation: AnyAttentionSourcePresentation(PRPresentation())),
        .init(source: JenkinsSource(), presentation: AnyAttentionSourcePresentation(JenkinsPresentation()))
    ]
}

struct PRPresentation: AttentionSourcePresentation {
    func icon(for item: any AttentionItem) -> some View {
        Group {
            if let pr = item as? PullRequest {
                PullRequestOcticonIndicator(pullRequest: pr)
            } else {
                EmptyView()
            }
        }
    }
}

struct JenkinsPresentation: AttentionSourcePresentation {
    func icon(for item: any AttentionItem) -> some View {
        Group {
            if let job = item as? JenkinsJob {
                JenkinsOrbitIndicator(job: job)
            } else {
                EmptyView()
            }
        }
    }
}

