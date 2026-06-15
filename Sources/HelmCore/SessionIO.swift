import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum SessionIO {
    static let historyCache = HistoryCache()

    private static let headBudgetBytes = 64 * 1024
    // Metadata lines (cwd/gitBranch/aiTitle/entrypoint) are tiny; anything larger is conversation
    // content. Skipping it keeps the scan going toward the metadata instead of spending the budget.
    private static let maxKeptLineBytes = 16 * 1024
    private static let maxLineBytes = 256 * 1024
    private static let headScanBytes = 4 * 1024 * 1024
    private static let chunkBytes = 64 * 1024
    private static let tailBytes: UInt64 = 32 * 1024

    static func readHead(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return collectSmallLines(reading: { try? handle.read(upToCount: $0) })
    }

    static func readTail(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > tailBytes ? end - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func collectSmallLines(reading read: (Int) -> Data?) -> String? {
        var buffer = Data(), collected = Data(), scanned = 0
        let nl: UInt8 = 0x0A
        outer: while scanned < headScanBytes, collected.count < headBudgetBytes {
            guard let chunk = read(chunkBytes), !chunk.isEmpty else { break }
            scanned += chunk.count
            buffer.append(chunk)
            while let nlIdx = buffer.firstIndex(of: nl) {
                let lineLen = nlIdx - buffer.startIndex
                if lineLen <= maxKeptLineBytes {
                    collected.append(buffer[buffer.startIndex..<nlIdx])
                    collected.append(nl)
                }
                buffer.removeSubrange(buffer.startIndex...nlIdx)
                if collected.count >= headBudgetBytes { break outer }
            }
            if buffer.count > maxLineBytes { buffer.removeAll(keepingCapacity: false) }
        }
        if !buffer.isEmpty && buffer.count <= maxKeptLineBytes && collected.count < headBudgetBytes {
            collected.append(buffer)
            collected.append(nl)
        }
        return collected.isEmpty ? nil : String(decoding: collected, as: UTF8.self)
    }

    static func isAlive(_ pid: Int32) -> Bool {
        #if canImport(Darwin)
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
        #else
        return false
        #endif
    }
}

final class HistoryCache {
    private let lock = NSLock()
    private var entries: [String: (mtime: Date, record: HistoryRecord)] = [:]

    func record(forPath path: String, mtime: Date, build: () -> HistoryRecord) -> HistoryRecord {
        lock.lock()
        if let hit = entries[path], hit.mtime == mtime { lock.unlock(); return hit.record }
        lock.unlock()
        let rec = build()
        lock.lock(); entries[path] = (mtime, rec); lock.unlock()
        return rec
    }
}
