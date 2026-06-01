import Foundation

protocol SessionBackend {
    var agent: AgentKind { get }
    func readLive() -> [LiveRecord]
    func readHistory() -> [HistoryRecord]
    /// The hook-written verdict from this agent's `~/.helm` state file (the Stop
    /// classifier / the AskUserQuestion hook), or nil when there's no file or its reason is
    /// a non-attention marker (e.g. `running`). Authoritative when present — it can flag a
    /// session waiting on you even while the live registry still reports it busy.
    func stateFileReason(for session: ChatSession) -> IdleReason?
    /// In-process fallback when no hook verdict is present: structurally classify the
    /// transcript tail (needs-input vs done).
    func classifyTail(for session: ChatSession) -> IdleReason?
    func aliveSessionIds() -> Set<String>?
    func clearState(sessionId: String)
}
