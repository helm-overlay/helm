import XCTest
@testable import HelmCore

final class JenkinsSourceTests: XCTestCase {
    private let nowDate = Date(timeIntervalSince1970: 1_000_000_000)
    private let me = "eshaan@browserstack.com"

    private func source(run: @escaping JenkinsSource.Runner = { _, _, _, _ in Data() }) -> JenkinsSource {
        JenkinsSource(config: .init(user: me, token: "t",
                                    jobURLs: ["https://ci.example.com/job/Mobile/job/Deploy/"]),
                      now: { self.nowDate }, run: run)
    }

    /// A build `ageHours` old (or building), authored by `user`, at build `number`.
    private func build(_ number: Int, user: String?, result: String?, ageHours: Double,
                       building: Bool = false, estimatedMs: Double? = nil) -> [String: Any] {
        let ts = (nowDate.timeIntervalSince1970 - ageHours * 3600) * 1000
        var cause: [String: Any] = [:]
        if let user { cause = ["userId": user, "userName": "Someone"] }
        var b: [String: Any] = ["number": number,
                "url": "https://ci.example.com/job/Mobile/job/Deploy/\(number)/",
                "result": result as Any, "timestamp": ts, "building": building,
                "actions": [["causes": [cause]]]]
        if let estimatedMs { b["estimatedDuration"] = estimatedMs }
        return b
    }

    private func jobJSON(_ builds: [[String: Any]]) -> Data {
        let obj: [String: Any] = ["name": "Deploy", "displayName": "Deploy",
                                  "url": "https://ci.example.com/job/Mobile/job/Deploy/",
                                  "builds": builds]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    private func decodeJob(_ builds: [[String: Any]]) -> JobDTO {
        JenkinsSource.decode(JobDTO.self, from: jobJSON(builds))!
    }

    func testKeepsMyLatestBuildSupersedingEarlierMine() {
        let job = decodeJob([build(2, user: me, result: "FAILURE", ageHours: 5),
                             build(4, user: me, result: "SUCCESS", ageHours: 1)])
        let row = source().row(from: job, user: me)
        XCTAssertEqual(row?.number, 4)            // latest of mine wins
        XCTAssertEqual(row?.result, .success)
    }

    func testIgnoresBuildsTriggeredByOthers() {
        let job = decodeJob([build(9, user: "someone-else", result: "FAILURE", ageHours: 1),
                             build(7, user: me, result: "FAILURE", ageHours: 2)])
        let row = source().row(from: job, user: me)
        XCTAssertEqual(row?.number, 7)            // a coworker's newer run doesn't mask mine
    }

    func testBuildingBuildIsAlwaysKeptAsLive() {
        let job = decodeJob([build(5, user: me, result: nil, ageHours: 0.1, building: true)])
        let row = source().row(from: job, user: me)
        XCTAssertEqual(row?.building, true)
        XCTAssertEqual(row?.reason, .live)
    }

    func testBuildingProgressFromEstimatedDuration() {
        // Started 30s ago, estimated 60s → ~50% complete.
        let job = decodeJob([build(5, user: me, result: nil, ageHours: 30.0 / 3600,
                                   building: true, estimatedMs: 60_000)])
        let row = source().row(from: job, user: me)!
        XCTAssertEqual(row.estimatedDuration, 60, accuracy: 0.01)
        XCTAssertEqual(row.progress(at: nowDate), 0.5, accuracy: 0.02)
    }

    func testProgressClampsAndZeroWithoutEstimate() {
        // Overrunning build pins at 1; a build with no estimate reports 0 (indeterminate).
        let over = source().row(from: decodeJob([build(6, user: me, result: nil, ageHours: 1,
                                                        building: true, estimatedMs: 60_000)]), user: me)!
        XCTAssertEqual(over.progress(at: nowDate), 1.0)
        let noEstimate = source().row(from: decodeJob([build(7, user: me, result: nil,
                                                             ageHours: 0.01, building: true)]), user: me)!
        XCTAssertEqual(noEstimate.estimatedDuration, 0)
        XCTAssertEqual(noEstimate.progress(at: nowDate), 0)
    }

    func testFinishedBuildOlderThanWindowDrops() {
        let job = decodeJob([build(3, user: me, result: "FAILURE", ageHours: 30)])
        XCTAssertNil(source().row(from: job, user: me))   // > 24h, no longer shown
    }

    func testNoBuildsOfMineYieldsNoRow() {
        let job = decodeJob([build(1, user: nil, result: "SUCCESS", ageHours: 1)])  // SCM-triggered
        XCTAssertNil(source().row(from: job, user: me))
    }

    func testReasonAndPromotion() {
        let s = source()
        let failed = s.row(from: decodeJob([build(1, user: me, result: "FAILURE", ageHours: 1)]), user: me)!
        let unstable = s.row(from: decodeJob([build(1, user: me, result: "UNSTABLE", ageHours: 1)]), user: me)!
        let success = s.row(from: decodeJob([build(1, user: me, result: "SUCCESS", ageHours: 1)]), user: me)!
        XCTAssertEqual(failed.reason, .jenkinsFailed)
        XCTAssertEqual(unstable.reason, .jenkinsUnstable)
        XCTAssertEqual(success.reason, .none)
        XCTAssertTrue(s.promotes(failed))
        XCTAssertTrue(s.promotes(unstable))
        XCTAssertFalse(s.promotes(success))   // clean build is inventory-only
    }

    func testFolderAndNameDerivedFromURL() {
        let job = decodeJob([build(1, user: me, result: "FAILURE", ageHours: 1)])
        let row = source().row(from: job, user: me)
        XCTAssertEqual(row?.name, "Deploy")
        XCTAssertEqual(row?.folder, "Mobile")
        XCTAssertEqual(row?.stopURL, "https://ci.example.com/job/Mobile/job/Deploy/1/stop")
    }

    func testInactiveWithoutConfig() async {
        let s = JenkinsSource(config: nil)
        let items = await s.allItems()
        XCTAssertTrue(items.isEmpty)
    }

    func testResolveConfigJoinsRelativeJobsToBaseAndKeepsAbsolute() {
        let cfg = HelmConfig(jenkinsURL: "https://ci.example.com/",
                             jenkinsUser: me,
                             jenkinsJobs: ["/job/Mobile/job/Deploy/",
                                           "https://other.example.com/job/X/"])
        let resolved = JenkinsSource.resolveConfig(config: cfg, env: ["HELM_JENKINS_TOKEN": "t"])
        XCTAssertEqual(resolved?.jobURLs,
                       ["https://ci.example.com/job/Mobile/job/Deploy/",
                        "https://other.example.com/job/X/"])
    }

    func testResolveConfigNilWhenRelativeJobsButNoBase() {
        let cfg = HelmConfig(jenkinsUser: me, jenkinsJobs: ["job/Mobile/job/Deploy/"])
        XCTAssertNil(JenkinsSource.resolveConfig(config: cfg, env: ["HELM_JENKINS_TOKEN": "t"]))
    }

    func testResolveTokenPrefersEnvThenFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("jenkins-token")
        try "  filetok\n".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(JenkinsSource.resolveToken(env: [:], file: file), "filetok")  // trimmed
        XCTAssertEqual(JenkinsSource.resolveToken(env: ["HELM_JENKINS_TOKEN": "envtok"], file: file),
                       "envtok")                                                     // env overrides
        XCTAssertNil(JenkinsSource.resolveToken(env: [:], file: dir.appendingPathComponent("absent")))
    }

    func testFetchAllReadsAndSortsLoudestFirst() {
        // Single whitelisted job → its failed build promotes to a row.
        let s = source(run: { _, _, _, _ in
            self.jobJSON([self.build(8, user: self.me, result: "FAILURE", ageHours: 1)])
        })
        let rows = s.fetchAll()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.reason, .jenkinsFailed)
    }
}
