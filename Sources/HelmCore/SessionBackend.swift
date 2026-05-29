import Foundation

protocol SessionBackend {
    var agent: AgentKind { get }
    func readLive() -> [LiveRecord]
    func readHistory() -> [HistoryRecord]
    func idleReason(for session: ChatSession) -> IdleReason?
    func aliveSessionIds() -> Set<String>?
}
