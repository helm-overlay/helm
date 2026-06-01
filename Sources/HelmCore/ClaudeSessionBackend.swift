import Foundation

struct ClaudeSessionBackend: SessionBackend {
    let agent: AgentKind = .claude
    let home: String
    let claudeDir: URL

    init(home: String) {
        self.home = home
        self.claudeDir = URL(fileURLWithPath: home).appendingPathComponent(".claude")
    }

    private struct LiveJSON: Decodable {
        let pid: Int32; let sessionId: String
        let kind: String?; let status: String?; let name: String?; let entrypoint: String?
    }

    func readLive() -> [LiveRecord] {
        let dir = claudeDir.appendingPathComponent("sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [LiveRecord] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let j = try? JSONDecoder().decode(LiveJSON.self, from: data),
                  SessionStore.isUserThread(entrypoint: j.entrypoint),
                  SessionIO.isAlive(j.pid) else { continue }
            out.append(LiveRecord(pid: j.pid, sessionId: j.sessionId,
                                  kind: j.kind, status: j.status, name: j.name,
                                  agent: .claude))
        }
        return out
    }

    func readHistory() -> [HistoryRecord] {
        let dir = claudeDir.appendingPathComponent("projects")
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [HistoryRecord] = []
        for pdir in projectDirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: pdir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files where f.pathExtension == "jsonl" {
                if SessionStore.isSubagentTranscript(filename: f.lastPathComponent) { continue }
                let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rec = SessionIO.historyCache.record(forPath: f.path, mtime: mtime) {
                    self.readTranscript(f, mtime: mtime)
                }
                guard SessionStore.isUserThread(entrypoint: rec.entrypoint) else { continue }
                out.append(rec)
            }
        }
        return out
    }

    func stateFileReason(for session: ChatSession) -> IdleReason? {
        readStateFile(sessionId: session.sessionId)
    }

    func classifyTail(for session: ChatSession) -> IdleReason? {
        locateTranscript(session.sessionId).flatMap(SessionIO.readTail).map(SessionStore.classifyIdleTail)
    }

    func aliveSessionIds() -> Set<String>? {
        let dir = claudeDir.appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        var out: Set<String> = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let j = try? JSONDecoder().decode(LiveJSON.self, from: data),
                  SessionIO.isAlive(j.pid) else { continue }
            out.insert(j.sessionId)
        }
        return out
    }

    func clearState(sessionId: String) {
        try? FileManager.default.removeItem(at: SessionStore.stateFileURL(sessionId, home: home))
    }

    private func readTranscript(_ url: URL, mtime: Date) -> HistoryRecord {
        let sid = url.deletingPathExtension().lastPathComponent
        var cwd: String?, gitBranch: String?, aiTitle: String?, entrypoint: String?
        if let content = SessionIO.readHead(url) {
            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty { cwd = c; gitBranch = (obj["gitBranch"] as? String)?.nonEmpty }
                if aiTitle == nil, let t = obj["aiTitle"] as? String, !t.isEmpty { aiTitle = t }
                if entrypoint == nil, let e = obj["entrypoint"] as? String, !e.isEmpty { entrypoint = e }
                if cwd != nil && aiTitle != nil && entrypoint != nil { break }
            }
        }
        return HistoryRecord(sessionId: sid, cwd: cwd, gitBranch: gitBranch,
                             aiTitle: aiTitle, entrypoint: entrypoint, lastActive: mtime,
                             agent: .claude, transcriptPath: url.path)
    }

    private func readStateFile(sessionId: String) -> IdleReason? {
        let url = SessionStore.stateFileURL(sessionId, home: home)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return SessionStore.idleReason(fromState: obj["reason"] as? String)
    }

    private func locateTranscript(_ sessionId: String) -> URL? {
        let dir = claudeDir.appendingPathComponent("projects")
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for pdir in projectDirs {
            let url = pdir.appendingPathComponent("\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
