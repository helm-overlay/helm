# Attention Source Presentation

## Goal

Attention rows should be source-driven all the way down: the data source owns the rows it emits, and a paired UI presentation owns how those rows look. The generic launcher row should not know that sessions use agent glyphs, PRs use octicons, or Jenkins uses an orbit/progress glyph.

This keeps `HelmCore` headless while making each UI integration complete and self-contained.

## Non-goals

- Do not add a central `AttentionIcon` enum with cases like `octicon`, `animatedText`, etc.
- Do not make `AttentionRow` switch on concrete row types (`ChatSession`, `PullRequest`, `JenkinsJob`).
- Do not put SwiftUI types (`Color`, `View`, `AnyView`) into `HelmCore`.

## Architecture

### Core layer

`HelmCore` continues to define only the data contracts:

```swift
public protocol AttentionItem { ... }
public protocol AttentionSource { ... }
```

Sources such as `SessionFeedSource`, `PRSource`, and `JenkinsSource` remain headless and testable.

### UI layer

The Helm app layer adds a presentation contract paired with each source:

```swift
protocol AttentionSourcePresentation {
    associatedtype Icon: View

    @ViewBuilder
    func icon(for item: any AttentionItem) -> Icon

    func tint(for item: any AttentionItem, defaultTint: Color) -> Color
}

extension AttentionSourcePresentation {
    func tint(for item: any AttentionItem, defaultTint: Color) -> Color {
        defaultTint
    }
}
```

Because the launcher stores heterogeneous presentations, use type erasure:

```swift
struct AnyAttentionSourcePresentation {
    private let _icon: (any AttentionItem) -> AnyView
    private let _tint: (any AttentionItem, Color) -> Color

    init<P: AttentionSourcePresentation>(_ presentation: P) {
        self._icon = { AnyView(presentation.icon(for: $0)) }
        self._tint = presentation.tint
    }

    func icon(for item: any AttentionItem) -> AnyView {
        _icon(item)
    }

    func tint(for item: any AttentionItem, defaultTint: Color) -> Color {
        _tint(item, defaultTint)
    }
}
```

## Source registration

Use a single registration object as the integration point:

```swift
struct AttentionSourceRegistration {
    let source: any AttentionSource
    let presentation: AnyAttentionSourcePresentation
}
```

Default registrations live in the UI layer:

```swift
extension AttentionSourceRegistration {
    static let defaults: [AttentionSourceRegistration] = [
        .init(source: SessionFeedSource(),
              presentation: AnyAttentionSourcePresentation(SessionPresentation())),
        .init(source: PRSource(),
              presentation: AnyAttentionSourcePresentation(PRPresentation())),
        .init(source: JenkinsSource(),
              presentation: AnyAttentionSourcePresentation(JenkinsPresentation()))
    ]
}
```

Adding a new attention source means adding one registration: its source plus its presentation.

## View model integration

`AttentionListViewModel` should hold registrations instead of raw sources:

```swift
private let registrations: [AttentionSourceRegistration]

private var sources: [any AttentionSource] {
    registrations.map(\.source)
}
```

`FeedSection` carries the presentation for its rows:

```swift
struct FeedSection: Identifiable {
    let id: String
    let title: String
    let presentation: AnyAttentionSourcePresentation
    let rows: [FeedRow]
}
```

In `recompute()`, build sections from registrations:

```swift
let next: [FeedSection] = registrations.compactMap { registration in
    let source = registration.source
    let pool = cache[source.id] ?? []
    let visible = ...
    let rows = visible.map {
        FeedRow(item: $0, expiringSoon: !searching && source.expiringSoon($0))
    }

    return rows.isEmpty ? nil : FeedSection(
        id: source.id,
        title: source.title,
        presentation: registration.presentation,
        rows: rows
    )
}
```

## Row rendering

`AttentionRow` receives the section presentation:

```swift
AttentionRow(
    item: row.item,
    presentation: section.presentation,
    expiringSoon: row.expiringSoon,
    selected: row.item.id == model.selection,
    onOpen: { onOpen(row.item) }
)
```

The row renders generically:

```swift
private var indicator: some View {
    presentation.icon(for: item)
}

private var tint: Color {
    presentation.tint(
        for: item,
        defaultTint: AttentionPalette.color(item.reason)
    )
}
```

No row-level concrete type checks are needed.

## Example presentations

### Sessions

Sessions can branch internally by agent backend:

```swift
struct SessionPresentation: AttentionSourcePresentation {
    func icon(for item: any AttentionItem) -> some View {
        if let session = item as? ChatSession {
            SessionAgentGlyph(session: session)
        }
    }

    func tint(for item: any AttentionItem, defaultTint: Color) -> Color {
        guard let session = item as? ChatSession else { return defaultTint }
        if session.agent == .claude, session.reason == .live {
            return ClaudeStyle.orange
        }
        return defaultTint
    }
}
```

`SessionAgentGlyph` can then choose Claude vs Pi glyph styles without affecting the generic feed row.

### Pull requests

PRs own their octicon presentation entirely inside the PR presentation:

```swift
struct PRPresentation: AttentionSourcePresentation {
    func icon(for item: any AttentionItem) -> some View {
        if let pr = item as? PullRequest {
            PullRequestOcticonIndicator(pullRequest: pr)
        }
    }
}
```

There is no central octicon type or enum case.

### Jenkins

Jenkins keeps its own visual language:

```swift
struct JenkinsPresentation: AttentionSourcePresentation {
    func icon(for item: any AttentionItem) -> some View {
        if let job = item as? JenkinsJob {
            JenkinsOrbitIndicator(job: job)
        }
    }
}
```

## Migration plan

1. Add `AttentionSourcePresentation`, `AnyAttentionSourcePresentation`, and `AttentionSourceRegistration` in the Helm UI layer.
2. Change `AttentionListViewModel` to store registrations instead of raw sources.
3. Add `presentation` to `FeedSection`.
4. Pass the section presentation into `AttentionRow`.
5. Move session glyph logic into `SessionPresentation` / `SessionAgentGlyph`.
6. Move PR icon selection into `PRPresentation`.
7. Move Jenkins icon selection into `JenkinsPresentation`.
8. Delete the concrete type switch from `AttentionRow.indicator`.

## Result

The launcher remains source-driven:

- `HelmCore` owns data contracts.
- Each source owns its data retrieval.
- Each source presentation owns icons and source-specific row tinting.
- `AttentionRow` owns only generic layout.
- Adding Pi-specific session glyphs or a new attention source does not require editing the generic row renderer.
