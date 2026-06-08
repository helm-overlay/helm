import Foundation

/// A producer of attention rows. `SessionStore` is one source; `PRSource` (`gh`) is the next
/// (see `ATTENTION_FEED.md`). Beyond producing rows, a source declares how it wants to be
/// kept fresh (`refreshPolicy`) and which of its rows earn a resting-feed slot vs. stay
/// inventory-only (`promotes`). Adding an integration is: conform, set `id` / `title` /
/// `refreshPolicy`, implement `allItems()` + `promotes(_:)`. Everything else has a default.
public protocol AttentionSource {
    /// Stable key — slots this source's rows into the merged cache and names its refresh timer.
    var id: String { get }
    /// Section header for this source's rows in the launcher ("SESSIONS", "PULL REQUESTS").
    var title: String { get }
    /// How/when the view-model keeps this source fresh.
    var refreshPolicy: RefreshPolicy { get }

    /// Everything this source knows about — the base set for both the feed (after `promotes`)
    /// and the search expansion. `async` so a network source awaits while a local one returns
    /// immediately.
    func allItems() async -> [any AttentionItem]

    /// Which of `allItems()` earn a slot in the resting attention feed (vs. inventory-only).
    /// The gating discipline that keeps the feed sharp: `SessionStore` promotes running + idle
    /// rows but not dead ones; `PRSource` promotes action-required / come-look PRs but not drafts.
    func promotes(_ item: any AttentionItem) -> Bool

    /// Re-fetch a single row — e.g. after you act on it. Default: `allItems()` then pick by id;
    /// a source with a cheaper per-row path (one PR instead of the list) overrides this.
    func refresh(_ item: any AttentionItem) async -> (any AttentionItem)?

    /// The full inventory for the search expansion, matched against `query`. Default: a generic
    /// title/context match over `allItems()`; a source overrides for richer matching.
    func inventory(matching query: String) async -> [any AttentionItem]

    /// Background-worker / push lifecycle for a `.push` source: begin emitting fresh rows via
    /// `onChange`, and tear down. Default: no-op — a poll-driven source needs neither.
    func start(onChange: @escaping ([any AttentionItem]) -> Void)
    func stop()
}

/// How a source wants the view-model to keep it fresh.
public enum RefreshPolicy: Equatable {
    /// Poll `allItems()` every N seconds while the panel is open (sessions: 1.5, PRs: 15).
    case interval(TimeInterval)
    /// Refresh only when the panel opens — for data that can't change while you're away.
    case onSummonOnly
    /// The source drives its own updates via `start(onChange:)` (a watcher / webhook).
    case push
}

public extension AttentionSource {
    func refresh(_ item: any AttentionItem) async -> (any AttentionItem)? {
        await allItems().first { $0.id == item.id }
    }

    func inventory(matching query: String) async -> [any AttentionItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return await allItems().filter { $0.matches(q) }
    }

    func start(onChange: @escaping ([any AttentionItem]) -> Void) {}
    func stop() {}
}

/// Merges attention rows across sources and owns the feed ordering. The ordering itself
/// (`order`, `next`) is pure and unit-tested without any source.
public struct AttentionFeed {
    public let sources: [any AttentionSource]
    public init(_ sources: [any AttentionSource]) { self.sources = sources }

    /// Attention rows across every source, loudest first then newest. Each source's full set
    /// is gated by its own `promotes(_:)` before merging.
    public func items() async -> [any AttentionItem] {
        var all: [any AttentionItem] = []
        for source in sources {                                          // sequential — sources are few
            all += await source.allItems().filter(source.promotes)
        }
        return Self.order(all)
    }

    /// Inventory across every source for the search expansion; each source matches what it
    /// can (session bodies vs PR metadata). Ordering/grouping is the view's call.
    public func search(_ query: String) async -> [any AttentionItem] {
        var all: [any AttentionItem] = []
        for source in sources { all += await source.inventory(matching: query) }
        return all
    }

    // MARK: pure ordering — the generalization of SessionStore.attentionRank/nextAttentionSession

    /// Attention rows only (`reason.rank <= 1`), loudest first then newest. The single feed
    /// + jump order, type-agnostic: a needs-input session and a CI-failed PR interleave here.
    public static func order(_ items: [any AttentionItem]) -> [any AttentionItem] {
        items.filter { $0.reason.wantsAttention }.sorted(by: precedes)
    }

    /// The next attention row after `current` (matched by `id`, wrapping). Falls to the first
    /// when `current` isn't among them; nil when nothing wants you. The generic counterpart
    /// of `SessionStore.nextAttentionSession`, over any item type.
    public static func next(in items: [any AttentionItem], after current: String?) -> (any AttentionItem)? {
        let ordered = order(items)
        guard !ordered.isEmpty else { return nil }
        guard let current, let i = ordered.firstIndex(where: { $0.id == current }) else { return ordered.first }
        return ordered[(i + 1) % ordered.count]
    }

    /// Louder (lower rank) first; ties broken by recency.
    public static func precedes(_ a: any AttentionItem, _ b: any AttentionItem) -> Bool {
        a.reason.rank != b.reason.rank ? a.reason.rank < b.reason.rank : a.lastActive > b.lastActive
    }
}

/// `SessionStore` as a feed source. Builds a fresh store per read so config changes (added
/// workspace folders, enabled agents) are reflected live — matching how the rest of the app
/// reads sessions. The full live+history join is `allItems()`; `promotes` keeps running + idle
/// rows and drops cold ones; inventory reuses the existing fuzzy `matches`. Local reads are
/// cheap, so it polls fast (1.5s).
public struct SessionFeedSource: AttentionSource {
    public init() {}

    public var id: String { "sessions" }
    public var title: String { "SESSIONS" }
    public var refreshPolicy: RefreshPolicy { .interval(1.5) }

    public func allItems() async -> [any AttentionItem] { SessionStore().load() }

    /// Running and idle rows reach the feed; cold (dead) rows are inventory-only.
    public func promotes(_ item: any AttentionItem) -> Bool { item.reason != .none }
}
