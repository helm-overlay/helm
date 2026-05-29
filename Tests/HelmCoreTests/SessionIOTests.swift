import XCTest
@testable import HelmCore

final class SessionIOTests: XCTestCase {
    func testCollectSmallLinesSkipsMegaLineAndKeepsLaterMetadata() {
        let small1 = #"{"type":"mode","mode":"normal"}"#
        let megaLine = "{\"role\":\"user\",\"image\":\"" + String(repeating: "A", count: 300 * 1024) + "\"}"
        let small2 = #"{"cwd":"/Users/me/projects/p","entrypoint":"cli","aiTitle":"hello"}"#
        let blob = Data((small1 + "\n" + megaLine + "\n" + small2 + "\n").utf8)
        var offset = 0
        let result = SessionStore.collectSmallLines { n in
            guard offset < blob.count else { return Data() }
            let end = min(offset + n, blob.count)
            let slice = blob.subdata(in: offset..<end)
            offset = end
            return slice
        }
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains(#""cwd":"/Users/me/projects/p""#) == true)
        XCTAssertTrue(result?.contains(#""aiTitle":"hello""#) == true)
        XCTAssertFalse(result?.contains("AAAAA") == true)
    }

    func testHistoryCacheReusesUntilMtimeChanges() {
        let cache = HistoryCache()
        var builds = 0
        let make: () -> HistoryRecord = {
            builds += 1
            return HistoryRecord(sessionId: "s", cwd: "/x", gitBranch: nil, aiTitle: nil, lastActive: .distantPast)
        }
        let t0 = Date(timeIntervalSince1970: 100), t1 = Date(timeIntervalSince1970: 200)
        _ = cache.record(forPath: "/a.jsonl", mtime: t0, build: make)
        _ = cache.record(forPath: "/a.jsonl", mtime: t0, build: make)
        XCTAssertEqual(builds, 1)
        _ = cache.record(forPath: "/a.jsonl", mtime: t1, build: make)
        XCTAssertEqual(builds, 2)
        _ = cache.record(forPath: "/b.jsonl", mtime: t0, build: make)
        XCTAssertEqual(builds, 3)
    }
}
