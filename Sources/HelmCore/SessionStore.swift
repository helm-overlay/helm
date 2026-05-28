import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Reads the two session sources and joins them into the overlay's model.
///
/// Live    : ~/.claude/sessions/<pid>.json  (running only; pid/status/kind/name)
/// History : ~/.claude/projects/*/<sessionId>.jsonl  (every session; filename == sessionId)
/// Join key: sessionId.  Grouping: cwd under ~/projects/<name> → <name>; cwd == ~/Home
/// → "Singular Chats" (one-off launchpad, live rows only in default view); else "Other".
public struct SessionStore {
    public let claudeDir: URL
    public let home: String

    /// Group name for one-off sessions launched directly in ~/Home. Not a project —
    /// dead rows are hidden from the default view (search still finds them).
    public static let singularChatsGroup = "Singular Chats"

    public init(home: String = NSHomeDirectory()) {
        self.home = home
        self.claudeDir = URL(fileURLWithPath: home).appendingPathComponent(".claude")
    }

    // MARK: Public API

    /// Full merged list, ready to display. Idle rows get a needs-input/done reason from
    /// the Stop-hook's state file when it's at least as fresh as the transcript;
    /// otherwise we fall back to the in-process structural classify of the tail. Only
    /// idle rows pay any of this IO.
    public func load() -> [ChatSession] {
        merge(live: readLive(), history: readHistory()).map { s in
            guard s.state == .liveIdle else { return s }
            if let reason = readStateFile(sessionId: s.sessionId) {   // hook's verdict wins
                return s.with(idleReason: reason)
            }
            guard let url = locateTranscript(s.sessionId), let tail = readTail(url) else { return s }
            return s.with(idleReason: Self.classifyIdleTail(tail))
        }
    }

    /// Grouped + sorted for display: projects alphabetical, "Other" last; within a
    /// group live rows first, then newest-first by lastActive. Includes every project
    /// dir under `~/projects/` even if it has no sessions yet, so a freshly-created
    /// project shows up in the overlay before its first chat.
    public func grouped() -> [(project: String, sessions: [ChatSession])] {
        Self.group(load(), includeEmpty: listProjects() + [Self.singularChatsGroup])
    }

    /// Cheap live-only refresh for the open panel. Re-reads ONLY the live registry
    /// (+ the per-idle-row verdict) and reconciles each given row's live state — never the
    /// transcript history, since a cold row can't change. `newSessions` is true when the
    /// registry holds a session we have no row for yet (started after the last full scan);
    /// the caller does one full reload to pull its history/label.
    public func refreshLiveState(_ rows: [ChatSession]) -> (rows: [ChatSession], newSessions: Bool) {
        Self.reconcileLive(rows, live: readLive()) { sessionId in
            readStateFile(sessionId: sessionId)
                ?? locateTranscript(sessionId).flatMap(readTail).map(Self.classifyIdleTail)
        }
    }

    // MARK: Pure logic (unit-tested without the filesystem)

    /// Map a working directory to its display group.
    public static func project(forCwd cwd: String, home: String) -> String {
        if cwd == home + "/Home" { return singularChatsGroup }
        let prefix = home + "/projects/"
        guard cwd.hasPrefix(prefix) else { return "Other" }
        let rest = String(cwd.dropFirst(prefix.count))
        return rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? "Other"
    }

    /// Join history (left) with live on sessionId. Live-only sessions are still included.
    public func merge(live: [LiveRecord], history: [HistoryRecord]) -> [ChatSession] {
        let liveById = Dictionary(live.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [ChatSession] = []

        for h in history {
            let l = liveById[h.sessionId]
            let state = Self.state(forStatus: l?.status, isLive: l != nil)
            let label = l?.name?.nonEmpty
                ?? h.aiTitle?.nonEmpty
                ?? h.gitBranch?.nonEmpty
                ?? h.cwd.map { ($0 as NSString).lastPathComponent }
                ?? h.sessionId
            out.append(ChatSession(
                sessionId: h.sessionId, cwd: h.cwd ?? "",
                project: Self.project(forCwd: h.cwd ?? "", home: home),
                label: label, state: state, kind: l?.kind, pid: l?.pid,
                lastActive: h.lastActive, branch: h.gitBranch))
        }

        // Live sessions with no transcript yet (rare): surface them too.
        let seen = Set(history.map(\.sessionId))
        for l in live where !seen.contains(l.sessionId) {
            out.append(ChatSession(
                sessionId: l.sessionId, cwd: "", project: "Other",
                label: l.name?.nonEmpty ?? l.sessionId,
                state: Self.state(forStatus: l.status, isLive: true),
                kind: l.kind, pid: l.pid, lastActive: Date()))
        }
        return out
    }

    /// Reconcile rows' live state against the registry, without touching history. A row in
    /// the registry takes its status (busy/idle), pid and kind; a row absent from it falls
    /// to cold. `idleReason` supplies the verdict for now-idle rows (the IO half, injected
    /// so this stays pure and testable). `newSessions` flags a registry entry with no
    /// matching row — the caller must full-reload to materialize it (needs cwd/label).
    public static func reconcileLive(_ rows: [ChatSession], live: [LiveRecord],
                                     idleReason: (String) -> IdleReason?)
        -> (rows: [ChatSession], newSessions: Bool) {
        let liveById = Dictionary(live.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        let known = Set(rows.map(\.sessionId))
        let newSessions = live.contains { !known.contains($0.sessionId) }
        let updated = rows.map { row -> ChatSession in
            let l = liveById[row.sessionId]
            let state = Self.state(forStatus: l?.status, isLive: l != nil)
            return ChatSession(
                sessionId: row.sessionId, cwd: row.cwd, project: row.project, label: row.label,
                state: state, kind: l?.kind, pid: l?.pid, lastActive: row.lastActive,
                branch: row.branch, idleReason: state == .liveIdle ? idleReason(row.sessionId) : nil)
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

    /// Whether a session is past the "hide old sessions" cutoff (cutoff <= 0 disables).
    public static func isOlderThan(_ cutoff: TimeInterval, lastActive: Date, now: Date) -> Bool {
        cutoff > 0 && now.timeIntervalSince(lastActive) > cutoff
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
    public static func attentionRank(_ s: ChatSession) -> Int {
        if s.state == .liveIdle { return s.idleReason == .needsInput ? 0 : 1 }
        return s.isLive ? 2 : 3   // busy : cold
    }

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
        guard let current, let i = ordered.firstIndex(where: { $0.sessionId == current })
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

    /// Non-hidden dirs under `~/projects/` that contain a `PROJECT.md` — i.e. real
    /// projects, even if they have no sessions yet. Cheap (one readdir + per-entry
    /// stat); safe to call on every live-refresh tick.
    public func listProjects() -> [String] {
        let dir = URL(fileURLWithPath: home).appendingPathComponent("projects")
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var out: [String] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir),
                  isDir.boolValue,
                  FileManager.default.fileExists(atPath: entry.appendingPathComponent("PROJECT.md").path)
            else { continue }
            out.append(name)
        }
        return out
    }

    // MARK: Filesystem readers

    private struct LiveJSON: Decodable {
        let pid: Int32; let sessionId: String
        let kind: String?; let status: String?; let name: String?; let entrypoint: String?
    }

    /// Read live registry, dropping files whose PID is no longer alive (stale) and any
    /// hook/SDK-induced sessions (keep only user threads).
    public func readLive() -> [LiveRecord] {
        let dir = claudeDir.appendingPathComponent("sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: nil)) ?? []
        var out: [LiveRecord] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let j = try? JSONDecoder().decode(LiveJSON.self, from: data),
                  Self.isUserThread(entrypoint: j.entrypoint),
                  Self.isAlive(j.pid) else { continue }
            out.append(LiveRecord(pid: j.pid, sessionId: j.sessionId,
                                  kind: j.kind, status: j.status, name: j.name))
        }
        return out
    }

    /// Kill and block until the process is actually gone: SIGTERM, wait out `grace` for it
    /// to exit on its own (`claude` shuts down gracefully and isn't our child, so it can
    /// take ~1s), then SIGKILL if it's still up. Blocking — call off the main thread. This
    /// is what lets the caller reload only once the registry will agree the session is
    /// dead, instead of racing a still-exiting process back into an idle row.
    public static func terminateAndWait(_ pid: Int32, grace: Double = 1.5) {
        #if canImport(Darwin)
        _ = kill(pid, SIGTERM)
        if waitForExit(pid, timeout: grace) { return }
        _ = kill(pid, SIGKILL)
        _ = waitForExit(pid, timeout: 0.5)
        #endif
    }

    /// Poll `isAlive` (50ms) until the process exits or `timeout` elapses; true if it went.
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

    /// The directory Helm and the Stop hook share for per-session classifications.
    static func stateDir(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".helm/state")
    }

    /// The path Helm and the Stop hook share for a session's classification.
    static func stateFileURL(_ sessionId: String, home: String) -> URL {
        stateDir(home: home).appendingPathComponent("\(sessionId).json")
    }

    /// Delete a session's state file ourselves. Needed after a self-initiated kill: the
    /// process dies before Claude Code can run its `SessionEnd` cleanup hook, and the
    /// `sessionId` (hence the filename) is reused on `claude --resume`.
    public static func clearState(_ sessionId: String, home: String = NSHomeDirectory()) {
        try? FileManager.default.removeItem(at: stateFileURL(sessionId, home: home))
    }

    // MARK: State-file reaping

    /// Of the state files present, the ones whose session is no longer running. Pure set
    /// difference so it's tested without the filesystem.
    public static func deadStateIds(stateFileIds: Set<String>, aliveIds: Set<String>) -> Set<String> {
        stateFileIds.subtracting(aliveIds)
    }

    /// Delete state files left behind by sessions that have since exited. The `SessionEnd`
    /// hook clears a session's file on clean exit; a crash or `kill -9` skips that, leaking
    /// a stale verdict (which a later `claude --resume` would briefly re-read, since it
    /// reuses the sessionId). A nil alive set means we couldn't read the registry — skip
    /// the sweep rather than risk reaping files for sessions that are actually live.
    @discardableResult
    public func reapDeadState() -> [String] {
        guard let alive = aliveSessionIds() else { return [] }
        let dead = Self.deadStateIds(stateFileIds: stateFileIds(), aliveIds: alive)
        for id in dead {
            try? FileManager.default.removeItem(at: Self.stateFileURL(id, home: home))
        }
        return Array(dead)
    }

    /// sessionIds that currently have a state file (filename minus `.json`).
    private func stateFileIds() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.stateDir(home: home),
            includingPropertiesForKeys: nil)) ?? []
        return Set(files.filter { $0.pathExtension == "json" }
                        .map { $0.deletingPathExtension().lastPathComponent })
    }

    /// Every running session's id, by liveness alone (any entrypoint). Unlike `readLive()`
    /// this does NOT drop automation threads — the reaper asks "is this process alive?",
    /// not "is this my kind of thread?". nil if the registry dir can't be enumerated.
    private func aliveSessionIds() -> Set<String>? {
        let dir = claudeDir.appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: nil) else { return nil }
        var out: Set<String> = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let j = try? JSONDecoder().decode(LiveJSON.self, from: data),
                  Self.isAlive(j.pid) else { continue }
            out.insert(j.sessionId)
        }
        return out
    }

    /// `kill(pid, 0)`: 0 == alive; EPERM == alive but not ours; ESRCH == dead.
    public static func isAlive(_ pid: Int32) -> Bool {
        #if canImport(Darwin)
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
        #else
        return false
        #endif
    }

    /// Parsed transcript heads, cached by path+mtime across `SessionStore` instances (which
    /// are re-created on every scan). See `HistoryCache`.
    static let historyCache = HistoryCache()

    /// Scan every transcript, extracting cwd/gitBranch/aiTitle (first occurrences) + mtime.
    /// Each file's head is re-parsed only when its mtime advanced since the last scan, so a
    /// summon costs "stat every transcript + read the few that changed" rather than "read
    /// every transcript" — which matters as the append-only history grows without bound.
    public func readHistory() -> [HistoryRecord] {
        let dir = claudeDir.appendingPathComponent("projects")
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: nil) else { return [] }
        var out: [HistoryRecord] = []
        for pdir in projectDirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: pdir,
                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files where f.pathExtension == "jsonl" {
                if Self.isSubagentTranscript(filename: f.lastPathComponent) { continue }
                let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let rec = Self.historyCache.record(forPath: f.path, mtime: mtime) {
                    self.readTranscript(f, mtime: mtime)
                }
                guard Self.isUserThread(entrypoint: rec.entrypoint) else { continue }
                out.append(rec)
            }
        }
        return out
    }

    /// cwd/gitBranch/aiTitle all appear within the first records, so we only read the
    /// file head instead of loading the whole (possibly multi-MB) transcript. We collect
    /// up to `headBudgetBytes` of *small* lines, skipping any single line larger than
    /// `maxLineBytes` (a user message with an embedded base64 image), and we never scan
    /// past `headScanBytes` in total — so a transcript that opens with a screenshot still
    /// surfaces the next small record's cwd/aiTitle/entrypoint.
    private static let headBudgetBytes = 64 * 1024
    private static let maxLineBytes = 256 * 1024
    private static let headScanBytes = 4 * 1024 * 1024
    private static let chunkBytes = 64 * 1024

    private func readTranscript(_ url: URL, mtime: Date) -> HistoryRecord {
        let sid = url.deletingPathExtension().lastPathComponent
        var cwd: String?, gitBranch: String?, aiTitle: String?, entrypoint: String?
        if let content = readHead(url) {
            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty {
                    cwd = c
                    gitBranch = (obj["gitBranch"] as? String)?.nonEmpty
                }
                if aiTitle == nil, let t = obj["aiTitle"] as? String, !t.isEmpty {
                    aiTitle = t
                }
                if entrypoint == nil, let e = obj["entrypoint"] as? String, !e.isEmpty {
                    entrypoint = e
                }
                if cwd != nil && aiTitle != nil && entrypoint != nil { break }   // stop early
            }
        }
        return HistoryRecord(sessionId: sid, cwd: cwd, gitBranch: gitBranch,
                             aiTitle: aiTitle, entrypoint: entrypoint, lastActive: mtime)
    }

    private func readHead(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return Self.collectSmallLines(reading: { try? handle.read(upToCount: $0) })
    }

    /// Chunk-streams from `read`, dropping any single line over `maxLineBytes` (image blobs),
    /// until `headBudgetBytes` of small lines are collected or `headScanBytes` are scanned.
    /// Pulled out as a static so unit tests can drive it without a real file.
    static func collectSmallLines(reading read: (Int) -> Data?) -> String? {
        var buffer = Data(), collected = Data(), scanned = 0
        let nl: UInt8 = 0x0A
        outer: while scanned < headScanBytes, collected.count < headBudgetBytes {
            guard let chunk = read(chunkBytes), !chunk.isEmpty else { break }
            scanned += chunk.count
            buffer.append(chunk)
            while let nlIdx = buffer.firstIndex(of: nl) {
                let lineLen = nlIdx - buffer.startIndex
                if lineLen <= maxLineBytes {
                    collected.append(buffer[buffer.startIndex..<nlIdx])
                    collected.append(nl)
                }
                buffer.removeSubrange(buffer.startIndex...nlIdx)
                if collected.count >= headBudgetBytes { break outer }
            }
            // Drop an unterminated mega-line so the buffer doesn't keep growing.
            if buffer.count > maxLineBytes { buffer.removeAll(keepingCapacity: false) }
        }
        return collected.isEmpty ? nil : String(decoding: collected, as: UTF8.self)
    }

    /// The Stop hook's classification at ~/.helm/state/<sessionId>.json. Authoritative for
    /// idle rows: the registry already gates on real-time idle/busy, and the hook rewrites
    /// this on every turn end, so a present file reflects the current idle turn. (No mtime
    /// gate — transcripts get trailing metadata writes that would falsely look "newer".)
    private func readStateFile(sessionId: String) -> IdleReason? {
        let url = Self.stateFileURL(sessionId, home: home)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return Self.idleReason(fromState: obj["reason"] as? String)
    }

    /// Find a session's transcript by filename (== sessionId) across project dirs.
    private func locateTranscript(_ sessionId: String) -> URL? {
        let dir = claudeDir.appendingPathComponent("projects")
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: nil) else { return nil }
        for pdir in projectDirs {
            let url = pdir.appendingPathComponent("\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static let tailBytes: UInt64 = 32 * 1024

    /// Last `tailBytes` of the transcript. The leading line is usually mid-record and
    /// fails to parse (harmless — the classifier just skips it).
    private func readTail(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > Self.tailBytes ? end - Self.tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Process-wide cache of parsed transcript heads, keyed by file path + mtime. `SessionStore`
/// is re-instantiated on every scan, so the cache must outlive instances — hence it's held
/// statically and synchronised (scans can overlap). Append-only transcripts mean a stale
/// entry (for the rare deleted file) only wastes a little memory and is never *wrong*: a
/// changed file always carries a newer mtime, forcing a re-parse.
final class HistoryCache {
    private let lock = NSLock()
    private var entries: [String: (mtime: Date, record: HistoryRecord)] = [:]

    /// Cached record for `path` if its `mtime` is unchanged; otherwise `build()` it, store
    /// it, and return it.
    func record(forPath path: String, mtime: Date, build: () -> HistoryRecord) -> HistoryRecord {
        lock.lock()
        if let hit = entries[path], hit.mtime == mtime { lock.unlock(); return hit.record }
        lock.unlock()
        let rec = build()
        lock.lock(); entries[path] = (mtime, rec); lock.unlock()
        return rec
    }
}
