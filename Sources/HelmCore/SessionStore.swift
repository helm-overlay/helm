import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Reads the two session sources and joins them into the overlay's model.
///
/// Live    : ~/.claude/sessions/<pid>.json  (running only; pid/status/kind/name)
/// History : ~/.claude/projects/*/<sessionId>.jsonl  (every session; filename == sessionId)
/// Join key: sessionId.  Grouping: cwd under ~/projects/<name> → <name>, else "Other".
public struct SessionStore {
    public let claudeDir: URL
    public let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
        self.claudeDir = URL(fileURLWithPath: home).appendingPathComponent(".claude")
    }

    // MARK: Public API

    /// Full merged list, ready to display.
    public func load() -> [ChatSession] {
        merge(live: readLive(), history: readHistory())
    }

    /// Grouped + sorted for display: projects alphabetical, "Other" last; within a
    /// group live rows first, then newest-first by lastActive.
    public func grouped() -> [(project: String, sessions: [ChatSession])] {
        Self.group(load())
    }

    // MARK: Pure logic (unit-tested without the filesystem)

    /// Map a working directory to its display group.
    public static func project(forCwd cwd: String, home: String) -> String {
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
                lastActive: h.lastActive))
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

    static func state(forStatus status: String?, isLive: Bool) -> SessionState {
        guard isLive else { return .cold }
        return status == "busy" ? .liveBusy : .liveIdle
    }

    static func group(_ sessions: [ChatSession]) -> [(project: String, sessions: [ChatSession])] {
        let byProject = Dictionary(grouping: sessions, by: \.project)
        let sortRows: ([ChatSession]) -> [ChatSession] = { rows in
            rows.sorted {
                if $0.isLive != $1.isLive { return $0.isLive }       // live first
                return $0.lastActive > $1.lastActive                  // newest first
            }
        }
        return byProject.keys
            .sorted { a, b in
                if (a == "Other") != (b == "Other") { return b == "Other" } // Other last
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
            .map { ($0, sortRows(byProject[$0]!)) }
    }

    // MARK: Filesystem readers

    private struct LiveJSON: Decodable {
        let pid: Int32; let sessionId: String
        let kind: String?; let status: String?; let name: String?
    }

    /// Read live registry, dropping files whose PID is no longer alive (stale).
    public func readLive() -> [LiveRecord] {
        let dir = claudeDir.appendingPathComponent("sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: nil)) ?? []
        var out: [LiveRecord] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let j = try? JSONDecoder().decode(LiveJSON.self, from: data),
                  Self.isAlive(j.pid) else { continue }
            out.append(LiveRecord(pid: j.pid, sessionId: j.sessionId,
                                  kind: j.kind, status: j.status, name: j.name))
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

    /// Scan every transcript, extracting cwd/gitBranch/aiTitle (first occurrences) + mtime.
    public func readHistory() -> [HistoryRecord] {
        let dir = claudeDir.appendingPathComponent("projects")
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: nil) else { return [] }
        var out: [HistoryRecord] = []
        for pdir in projectDirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: pdir,
                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files where f.pathExtension == "jsonl" {
                out.append(readTranscript(f))
            }
        }
        return out
    }

    /// cwd/gitBranch/aiTitle all appear within the first records, so we only read the
    /// file head instead of loading the whole (possibly multi-MB) transcript.
    private static let headBytes = 64 * 1024

    private func readTranscript(_ url: URL) -> HistoryRecord {
        let sid = url.deletingPathExtension().lastPathComponent
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast

        var cwd: String?, gitBranch: String?, aiTitle: String?
        // A truncated final line (from the head read) simply fails to parse and is skipped.
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
                if cwd != nil && aiTitle != nil { break }   // stop early
            }
        }
        return HistoryRecord(sessionId: sid, cwd: cwd, gitBranch: gitBranch,
                             aiTitle: aiTitle, lastActive: mtime)
    }

    private func readHead(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.headBytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
