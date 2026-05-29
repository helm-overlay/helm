import Foundation

struct PiSessionBackend: SessionBackend {
    let agent: AgentKind = .pi
    let home: String
    let piDir: URL

    init(home: String) {
        self.home = home
        self.piDir = URL(fileURLWithPath: home).appendingPathComponent(".pi")
    }

    private struct LiveJSON: Decodable {
        let pid: Int32
        let sessionId: String
        let status: String?
        let name: String?
        let entrypoint: String?
    }

    func readLive() -> [LiveRecord] {
        let dir = piDir.appendingPathComponent("sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [LiveRecord] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let j = try? JSONDecoder().decode(LiveJSON.self, from: data),
                  SessionStore.isUserThread(entrypoint: j.entrypoint),
                  SessionIO.isAlive(j.pid) else { continue }
            out.append(LiveRecord(pid: j.pid, sessionId: j.sessionId,
                                  kind: nil, status: j.status, name: j.name,
                                  agent: .pi))
        }
        return out
    }

    func idleReason(for session: ChatSession) -> IdleReason? {
        readStateFile(sessionId: session.sessionId)
            ?? session.transcriptPath.map(URL.init(fileURLWithPath:)).flatMap(SessionIO.readTail).map(Self.classifyIdleTail)
    }

    func aliveSessionIds() -> Set<String>? {
        let dir = piDir.appendingPathComponent("sessions")
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

    func readHistory() -> [HistoryRecord] {
        let root = piDir.appendingPathComponent("agent/sessions")
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return [] }
        var out: [HistoryRecord] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }
            let mtime = values?.contentModificationDate ?? .distantPast
            let rec = SessionIO.historyCache.record(forPath: url.path, mtime: mtime) {
                self.readTranscript(url, mtime: mtime)
            }
            out.append(rec)
        }
        return out
    }

    private func readTranscript(_ url: URL, mtime: Date) -> HistoryRecord {
        var sessionId = url.deletingPathExtension().lastPathComponent
        var cwd: String?
        var name: String?
        var firstUser: String?
        if let content = SessionIO.readHead(url) {
            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                switch obj["type"] as? String {
                case "session":
                    if let id = obj["id"] as? String, !id.isEmpty { sessionId = id }
                    if cwd == nil { cwd = (obj["cwd"] as? String)?.nonEmpty }
                case "session_info":
                    if let n = obj["name"] as? String, !n.isEmpty { name = n }
                case "message":
                    if firstUser == nil, (obj["role"] as? String) == "user" || ((obj["message"] as? [String: Any])?["role"] as? String) == "user" {
                        firstUser = Self.piText(from: obj)?.nonEmpty
                    }
                default: break
                }
            }
        }
        let label = name?.nonEmpty ?? firstUser?.nonEmpty ?? cwd.map { ($0 as NSString).lastPathComponent }
        return HistoryRecord(sessionId: sessionId, cwd: cwd, gitBranch: nil, aiTitle: label,
                             entrypoint: nil, lastActive: mtime,
                             agent: .pi, transcriptPath: Self.displayPath(url))
    }

    private func readStateFile(sessionId: String) -> IdleReason? {
        let url = Self.stateFileURL(sessionId, home: home)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return SessionStore.idleReason(fromState: obj["reason"] as? String)
    }

    static func stateDir(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".helm/pi/state")
    }

    static func stateFileURL(_ sessionId: String, home: String) -> URL {
        stateDir(home: home).appendingPathComponent("\(sessionId).json")
    }

    private static func displayPath(_ url: URL) -> String {
        let path = url.path
        return path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }

    static func classifyIdleTail(_ tail: String) -> IdleReason {
        var msgs: [(role: String?, toolCallIds: [String], resultIds: [String], lastText: String?)] = []
        for line in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let message = (obj["message"] as? [String: Any]) ?? obj
            let role = message["role"] as? String
            var toolCallIds: [String] = [], resultIds: [String] = [], lastText: String?
            if role == "toolResult", let id = message["toolCallId"] as? String { resultIds.append(id) }
            if let blocks = message["content"] as? [[String: Any]] {
                for b in blocks {
                    switch b["type"] as? String {
                    case "toolCall": if let id = b["id"] as? String { toolCallIds.append(id) }
                    case "text": if let t = b["text"] as? String { lastText = t }
                    default: break
                    }
                }
            } else if let s = message["content"] as? String {
                lastText = s
            }
            msgs.append((role, toolCallIds, resultIds, lastText))
        }
        guard let li = msgs.lastIndex(where: { $0.role == "assistant" }) else { return .needsReview }
        let last = msgs[li]
        let resultsAfter = Set(msgs[(li + 1)...].flatMap(\.resultIds))
        if last.toolCallIds.contains(where: { !resultsAfter.contains($0) }) { return .needsInput }
        let endsOnQuestion = last.lastText?
            .split(whereSeparator: \.isNewline).last?
            .trimmingCharacters(in: .whitespaces)
            .hasSuffix("?") ?? false
        return endsOnQuestion ? .needsInput : .needsReview
    }

    private static func piText(from obj: [String: Any]) -> String? {
        if let text = obj["text"] as? String { return text }
        if let content = obj["content"] as? String { return content }
        if let blocks = obj["content"] as? [[String: Any]] {
            return blocks.compactMap { ($0["text"] as? String) ?? ($0["content"] as? String) }.first
        }
        if let message = obj["message"] as? [String: Any] {
            if let content = message["content"] as? String { return content }
            if let blocks = message["content"] as? [[String: Any]] {
                return blocks.compactMap { ($0["text"] as? String) ?? ($0["content"] as? String) }.first
            }
        }
        return nil
    }
}
