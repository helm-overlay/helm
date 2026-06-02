import Foundation

/// A producer of attention rows. A `SessionStore` is one source; a PR reader (`gh`) is the
/// next (see `ATTENTION_FEED.md`). `async` because some sources are network-bound, unlike
/// the filesystem-backed session reads — the protocol accommodates the slow one.
public protocol AttentionSource {
    /// Rows that earn a resting-state slot — the source decides what's attention-worthy.
    func attentionItems() async -> [any AttentionItem]
    /// The full inventory for the search expansion, matched against `query`.
    func inventory(matching query: String) async -> [any AttentionItem]
}

/// Merges attention rows across sources and owns the feed ordering. The ordering itself
/// (`order`, `next`) is pure and unit-tested without any source.
public struct AttentionFeed {
    public let sources: [any AttentionSource]
    public init(_ sources: [any AttentionSource]) { self.sources = sources }

    /// Attention rows across every source, loudest first then newest.
    public func items() async -> [any AttentionItem] {
        var all: [any AttentionItem] = []
        for source in sources { all += await source.attentionItems() }   // sequential — sources are few
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
    static func precedes(_ a: any AttentionItem, _ b: any AttentionItem) -> Bool {
        a.reason.rank != b.reason.rank ? a.reason.rank < b.reason.rank : a.lastActive > b.lastActive
    }
}

/// `SessionStore` as a feed source: live+history join, filtered to attention rows; the full
/// join for inventory, matched with the existing fuzzy `matches`. IO stays in `load()`'s
/// readers, consistent with the rest of the store.
extension SessionStore: AttentionSource {
    public func attentionItems() async -> [any AttentionItem] {
        load().filter { $0.reason.wantsAttention }
    }

    public func inventory(matching query: String) async -> [any AttentionItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return load().filter { SessionStore.matches($0, query: q) }
    }
}
