import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Reads the two session sources and joins them into the overlay's model.
///
/// Live    : ~/.claude/sessions/<pid>.json  (running only; pid/status/kind/name)
/// History : ~/.claude/projects/*/<sessionId>.jsonl  (every session; filename == sessionId)
/// Join key: sessionId.  Grouping: cwd under a configured workspace folder → that
/// folder's name; cwd == ~/Home → "Singular Chats" (one-off launchpad, live rows only
/// in default view); else "Other".
public struct SessionStore {
    public let home: String
    public let enabledAgents: [AgentKind]
    public let workspaceFolders: [String]
    private let backends: [any SessionBackend]

    /// Group name for one-off sessions launched directly in ~/Home. Not a project —
    /// dead rows are hidden from the default view (search still finds them).
    public static let singularChatsGroup = "Singular Chats"

    public init(home: String = NSHomeDirectory(), enabledAgents: [AgentKind] = HelmConfig.load().enabledAgents,
                workspaceFolders: [String] = HelmConfig.load().resolvedWorkspaceFolders()) {
        self.home = home
        self.enabledAgents = enabledAgents
        self.workspaceFolders = workspaceFolders
        self.backends = enabledAgents.map { agent in
            switch agent {
            case .claude: return ClaudeSessionBackend(home: home)
            case .pi: return PiSessionBackend(home: home)
            }
        }
    }

    // MARK: Public API

    /// Full merged list, ready to display. Every live row is resolved against its hook
    /// state file (`~/.helm/<agent>/state`): a `needs_input`/`done` verdict wins outright — even on
    /// a row the registry still reports busy, which is how a mid-turn AskUserQuestion
    /// surfaces. Idle rows with no verdict fall back to the in-process tail classify. Cold
    /// rows pay no IO.
    public func load() -> [ChatSession] {
        merge(live: readLive(), history: readHistory()).map { s in
            guard s.isLive, let b = backend(for: s.agent) else { return s }
            let resolved = Self.resolveLiveRow(s, stateReason: b.stateFileReason(for: s),
                                               classifyTail: { b.classifyTail(for: s) })
            // Carry the hook's one-line summary onto attention rows for the notification body.
            return resolved.idleReason == nil ? resolved
                : resolved.withAttentionSummary(b.stateFileSummary(for: s))
        }
    }

    /// Grouped + sorted for display: projects alphabetical, "Other" last; within a
    /// group live rows first, then newest-first by lastActive. Includes configured
    /// workspace folders even if they have no sessions yet.
    public func grouped() -> [(project: String, sessions: [ChatSession])] {
        Self.group(load(), includeEmpty: listProjects() + [Self.singularChatsGroup])
    }

    /// Cheap live-only refresh for the open panel. Re-reads ONLY the live registry
    /// (+ the per-idle-row verdict) and reconciles each given row's live state — never the
    /// transcript history, since a cold row can't change. `newSessions` is true when the
    /// registry holds a session we have no row for yet (started after the last full scan);
    /// the caller does one full reload to pull its history/label.
    public func refreshLiveState(_ rows: [ChatSession]) -> (rows: [ChatSession], newSessions: Bool) {
        let (reconciled, newSessions) = Self.reconcileLive(rows, live: readLive()) { row in
            guard let b = backend(for: row.agent) else { return nil }
            return b.stateFileReason(for: row) ?? b.classifyTail(for: row)
        }
        // reconcileLive only resolves idle rows; a hook verdict on a still-busy row (a
        // mid-turn AskUserQuestion) overrides that here, mirroring `load()`.
        let resolved = reconciled.map { s -> ChatSession in
            guard s.state == .liveBusy, let r = backend(for: s.agent)?.stateFileReason(for: s) else { return s }
            return s.with(state: .liveIdle, idleReason: r)
        }
        return (resolved, newSessions)
    }

    // MARK: Pure logic (unit-tested without the filesystem)

    /// Map a working directory to its display group.
    public static func project(forCwd cwd: String, home: String, workspaceFolders: [String] = []) -> String {
        if cwd == home + "/Home" { return singularChatsGroup }
        if let workspace = matchingWorkspace(forCwd: cwd, workspaceFolders: workspaceFolders) {
            return workspace
        }
        return "Other"
    }

    /// Join history (left) with live on sessionId. Live-only sessions are still included.
    public func merge(live: [LiveRecord], history: [HistoryRecord]) -> [ChatSession] {
        let liveById = Dictionary(live.map { ("\($0.agent.rawValue):\($0.sessionId)", $0) }, uniquingKeysWith: { a, _ in a })
        var out: [ChatSession] = []

        for h in history {
            let l = liveById["\(h.agent.rawValue):\(h.sessionId)"]
            let state = Self.state(forStatus: l?.status, isLive: l != nil)
            let label = l?.name?.nonEmpty
                ?? h.aiTitle?.nonEmpty
                ?? h.gitBranch?.nonEmpty
                ?? h.cwd.map { ($0 as NSString).lastPathComponent }
                ?? h.sessionId
            out.append(ChatSession(
                sessionId: h.sessionId, cwd: h.cwd ?? "",
                project: Self.project(forCwd: h.cwd ?? "", home: home, workspaceFolders: workspaceFolders),
                label: label, state: state, kind: l?.kind, pid: l?.pid,
                lastActive: h.lastActive, branch: h.gitBranch,
                agent: h.agent, transcriptPath: h.transcriptPath))
        }

        // Live sessions with no transcript yet (rare): surface them too.
        let seen = Set(history.map { "\($0.agent.rawValue):\($0.sessionId)" })
        for l in live where !seen.contains("\(l.agent.rawValue):\(l.sessionId)") {
            out.append(ChatSession(
                sessionId: l.sessionId, cwd: "", project: "Other",
                label: l.name?.nonEmpty ?? l.sessionId,
                state: Self.state(forStatus: l.status, isLive: true),
                kind: l.kind, pid: l.pid, lastActive: Date(), agent: l.agent))
        }
        return out
    }

    /// Reconcile rows' live state against the registry, without touching history. A row in
    /// the registry takes its status (busy/idle), pid and kind; a row absent from it falls
    /// to cold. `idleReason` supplies the verdict for now-idle rows (the IO half, injected
    /// so this stays pure and testable). `newSessions` flags a registry entry with no
    /// matching row — the caller must full-reload to materialize it (needs cwd/label).
    public static func reconcileLive(_ rows: [ChatSession], live: [LiveRecord],
                                     idleReason: (ChatSession) -> IdleReason?)
        -> (rows: [ChatSession], newSessions: Bool) {
        let liveById = Dictionary(live.map { ("\($0.agent.rawValue):\($0.sessionId)", $0) }, uniquingKeysWith: { a, _ in a })
        let known = Set(rows.map(\.id))
        let newSessions = live.contains { !known.contains("\($0.agent.rawValue):\($0.sessionId)") }
        let updated = rows.map { row -> ChatSession in
            let l = liveById[row.id]
            let state = Self.state(forStatus: l?.status, isLive: l != nil)
            return ChatSession(
                sessionId: row.sessionId, cwd: row.cwd, project: row.project, label: row.label,
                state: state, kind: l?.kind, pid: l?.pid, lastActive: row.lastActive,
                branch: row.branch, idleReason: state == .liveIdle ? idleReason(row) : nil,
                agent: row.agent, transcriptPath: row.transcriptPath)
        }
        return (updated, newSessions)
    }

    /// "My kind of thread": a session the user started interactively, not one a hook or
    /// the agent SDK induced. CLI entrypoint (or unstamped, for older transcripts) = mine.
    public static func isUserThread(entrypoint: String?) -> Bool {
        entrypoint == nil || entrypoint == "cli"
    }

    /// Task/subagent transcripts are written as `agent-<hash>.jsonl` (sidechain-only,
    /// not resumable) — never a user thread.
    public static func isSubagentTranscript(filename: String) -> Bool {
        filename.hasPrefix("agent-")
    }

    /// Coarse "time since last activity" label (no seconds/minutes precision):
    /// `<15m`, `<30m`, `<1h`, then whole hours/days/weeks floored — 2h59m → `2h`,
    /// 6d → `6d`, 13d → `1w`.
    public static func ageLabel(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        switch minutes {
        case ..<15:     return "<15m"
        case ..<30:     return "<30m"
        case ..<60:     return "<1h"
        case ..<1_440:  return "\(minutes / 60)h"        // < 24h
        case ..<10_080: return "\(minutes / 1_440)d"     // < 7d
        default:        return "\(minutes / 10_080)w"
        }
    }

    /// Search-first matching: a session matches a query if the query is a subsequence
    /// (fzf-style fuzzy) of its label, project, branch, or cwd. Query assumed lowercased.
    public static func matches(_ s: ChatSession, query q: String) -> Bool {
        guard !q.isEmpty else { return true }
        for field in [s.label, s.project, s.branch ?? "", s.cwd] where fuzzy(field, q) {
            return true
        }
        return false
    }

    /// `needle`'s characters appear in order within `haystack` (not necessarily adjacent).
    static func fuzzy(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        let n = Array(needle)
        var i = 0
        for ch in haystack.lowercased() where ch == n[i] {
            i += 1
            if i == n.count { return true }
        }
        return false
    }

    static func state(forStatus status: String?, isLive: Bool) -> SessionState {
        guard isLive else { return .cold }
        return status == "busy" ? .liveBusy : .liveIdle
    }

    /// Fold a live row's hook-state verdict into its final display state. `stateReason` is
    /// the `~/.helm/<agent>/state` verdict (nil = no file, or a non-attention `running` marker);
    /// `classifyTail` is the lazy in-process fallback, run only for an idle row with no
    /// verdict. A verdict promotes even a busy row to `.liveIdle` so a session that paused
    /// to ask (AskUserQuestion) doesn't hide behind its busy status. Cold rows pass through.
    static func resolveLiveRow(_ s: ChatSession, stateReason: IdleReason?,
                               classifyTail: () -> IdleReason?) -> ChatSession {
        switch s.state {
        case .cold:     return s
        case .liveBusy: return stateReason.map { s.with(state: .liveIdle, idleReason: $0) } ?? s
        case .liveIdle: return s.with(idleReason: stateReason ?? classifyTail())
        }
    }

    /// Classify an idle session's transcript tail into needs-input vs done. Pure, so it
    /// runs against synthetic JSONL in tests. Rules, in order:
    ///   1. The last assistant turn left a `tool_use` with no matching `tool_result`
    ///      after it (e.g. an unanswered AskUserQuestion / ExitPlanMode) → needsInput.
    ///   2. It ended on prose whose last line is a question (trailing "?") → needsInput.
    ///   3. Otherwise → done.
    /// High precision, deliberately low recall: a turn that asks in prose without a
    /// trailing "?" reads as `done` rather than risk a false "needs you". (An LLM pass
    /// over the same tail would lift recall — that's the planned next layer.)
    public static func classifyIdleTail(_ tail: String) -> IdleReason {
        var msgs: [ClassMsg] = []
        for line in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = obj["message"] as? [String: Any] else { continue }
            let role = message["role"] as? String
            var toolUseIds: [String] = [], resultIds: [String] = [], lastText: String?
            if let blocks = message["content"] as? [[String: Any]] {
                for b in blocks {
                    switch b["type"] as? String {
                    case "tool_use":    if let id = b["id"] as? String { toolUseIds.append(id) }
                    case "tool_result": if let id = b["tool_use_id"] as? String { resultIds.append(id) }
                    case "text":        if let t = b["text"] as? String { lastText = t }
                    default: break
                    }
                }
            } else if let s = message["content"] as? String {
                lastText = s
            }
            msgs.append(ClassMsg(role: role, toolUseIds: toolUseIds, resultIds: resultIds, lastText: lastText))
        }

        return classifyAssistantMessages(msgs)
    }

    /// The Stop hook writes `{"reason":"needs_input"|"done", ...}` (the wire format predates
    /// the `needsReview` rename, so `"done"` still maps to `.needsReview`).
    public static func idleReason(fromState raw: String?) -> IdleReason? {
        switch raw {
        case "needs_input": return .needsInput
        case "done":        return .needsReview
        default:            return nil
        }
    }

    private struct ClassMsg { let role: String?; let toolUseIds: [String]; let resultIds: [String]; let lastText: String? }

    private static func classifyAssistantMessages(_ msgs: [ClassMsg]) -> IdleReason {
        guard let li = msgs.lastIndex(where: { $0.role == "assistant" }) else { return .needsReview }
        let last = msgs[li]

        let resultsAfter = Set(msgs[(li + 1)...].flatMap(\.resultIds))
        if last.toolUseIds.contains(where: { !resultsAfter.contains($0) }) { return .needsInput }

        let endsOnQuestion = last.lastText?
            .split(whereSeparator: \.isNewline).last?
            .trimmingCharacters(in: .whitespaces)
            .hasSuffix("?") ?? false
        return endsOnQuestion ? .needsInput : .needsReview
    }

    /// How loudly a row wants your attention — lowest wins. Drives both the in-group sort
    /// and the jump hotkey: a session waiting on a decision (`needsInput`) outranks one
    /// that's done and ready for review (`needsReview`), which outranks anything still live
    /// (busy, or idle pending classification), which outranks cold. This is what keeps the
    /// row the app exists to surface from sinking below busier rows or into the collapsed
    /// tail — it lands in the top slots, where `perProjectCap` always shows it.
    public static func attentionRank(_ s: ChatSession) -> Int { s.reason.rank }

    /// The next session that wants you, for the jump hotkey. Considers only attention rows
    /// (needs-input, then needs-review — never busy/cold), ordered by rank then recency, and
    /// returns the one after `current` (wrapping). Falls to the first when `current` isn't
    /// among them. nil when nothing wants you.
    public static func nextAttentionSession(in rows: [ChatSession], after current: String?) -> ChatSession? {
        let ordered = rows.filter { attentionRank($0) <= 1 }.sorted {
            let ra = attentionRank($0), rb = attentionRank($1)
            return ra != rb ? ra < rb : $0.lastActive > $1.lastActive
        }
        guard !ordered.isEmpty else { return nil }
        guard let current, let i = ordered.firstIndex(where: { $0.id == current || $0.sessionId == current })
        else { return ordered.first }
        return ordered[(i + 1) % ordered.count]
    }

    public static func group(_ sessions: [ChatSession], includeEmpty: [String] = [])
        -> [(project: String, sessions: [ChatSession])] {
        var byProject = Dictionary(grouping: sessions, by: \.project)
        for name in includeEmpty where byProject[name] == nil {
            byProject[name] = []
        }
        let sortRows: ([ChatSession]) -> [ChatSession] = { rows in
            rows.sorted {
                let ra = attentionRank($0), rb = attentionRank($1)
                if ra != rb { return ra < rb }       // attention first (needs-input, review, …)
                return $0.lastActive > $1.lastActive  // then newest
            }
        }
        return byProject.keys
            .sorted { a, b in
                func rank(_ s: String) -> Int {
                    if s == "Other" { return 2 }             // legacy bucket — last
                    if s == singularChatsGroup { return -1 }      // launchpad — first; it's the most-reached-for section
                    return 0                                  // real projects — alphabetical
                }
                let ra = rank(a), rb = rank(b)
                if ra != rb { return ra < rb }
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
            .map { ($0, sortRows(byProject[$0]!)) }
    }

    /// Configured workspace folders, even if they have no sessions yet.
    public func listProjects() -> [String] {
        workspaceFolders.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    private static func matchingWorkspace(forCwd cwd: String, workspaceFolders: [String]) -> String? {
        let normalizedCwd = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let matches = workspaceFolders
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
            .filter { root in normalizedCwd == root || normalizedCwd.hasPrefix(root + "/") }
        return matches.max(by: { $0.count < $1.count }).map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
    }

    // MARK: Backend dispatch + shared filesystem helpers

    private func backend(for agent: AgentKind) -> (any SessionBackend)? {
        backends.first { $0.agent == agent }
    }

    public func readLive() -> [LiveRecord] {
        backends.flatMap { $0.readLive() }
    }

    public func readHistory() -> [HistoryRecord] {
        backends.flatMap { $0.readHistory() }
    }

    /// Kill and block until the process is actually gone: SIGTERM, wait out `grace` for it
    /// to exit on its own, then SIGKILL if it's still up. Blocking — call off the main thread.
    public static func terminateAndWait(_ pid: Int32, grace: Double = 1.5) {
        #if canImport(Darwin)
        _ = kill(pid, SIGTERM)
        if waitForExit(pid, timeout: grace) { return }
        _ = kill(pid, SIGKILL)
        _ = waitForExit(pid, timeout: 0.5)
        #endif
    }

    @discardableResult
    private static func waitForExit(_ pid: Int32, timeout: Double) -> Bool {
        #if canImport(Darwin)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isAlive(pid) { return true }
            usleep(50_000)
        }
        #endif
        return !isAlive(pid)
    }

    static func stateDir(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".helm/claude/state")
    }

    static func stateFileURL(_ sessionId: String, home: String) -> URL {
        stateDir(home: home).appendingPathComponent("\(sessionId).json")
    }

    public static func clearState(agent: AgentKind, sessionId: String, home: String = NSHomeDirectory()) {
        switch agent {
        case .claude: ClaudeSessionBackend(home: home).clearState(sessionId: sessionId)
        case .pi: PiSessionBackend(home: home).clearState(sessionId: sessionId)
        }
    }

    public static func deadStateIds(stateFileIds: Set<String>, aliveIds: Set<String>) -> Set<String> {
        stateFileIds.subtracting(aliveIds)
    }

    @discardableResult
    public func reapDeadState() -> [String] {
        var reaped: [String] = []
        if let claude = backend(for: .claude), let alive = claude.aliveSessionIds() {
            let dead = Self.deadStateIds(stateFileIds: stateFileIds(in: Self.stateDir(home: home)), aliveIds: alive)
            for id in dead { claude.clearState(sessionId: id) }
            reaped.append(contentsOf: dead.map { "claude:\($0)" })
        }
        if let pi = backend(for: .pi), let alive = pi.aliveSessionIds() {
            let dead = Self.deadStateIds(stateFileIds: stateFileIds(in: PiSessionBackend.stateDir(home: home)), aliveIds: alive)
            for id in dead { pi.clearState(sessionId: id) }
            reaped.append(contentsOf: dead.map { "pi:\($0)" })
        }
        return reaped
    }

    private func stateFileIds(in dir: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return Set(files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent })
    }

    public static func isAlive(_ pid: Int32) -> Bool { SessionIO.isAlive(pid) }

    static func collectSmallLines(reading read: (Int) -> Data?) -> String? {
        SessionIO.collectSmallLines(reading: read)
    }
}
