import Foundation

/// Surfaces Jenkins builds *you triggered* from a configured whitelist of jobs. Each job is
/// polled directly (`<job>/api/json`) rather than scanning the instance — a build that's
/// running right now isn't in any per-user RSS feed yet, and there's no cheap per-user
/// "running builds" endpoint, so the whitelist bounds the fan-out to jobs you care about.
///
/// Per job we keep *your latest* build (the highest-numbered build whose trigger cause is you,
/// so a coworker's newer run on the same job doesn't mask yours). Auth, host, and the job list
/// come from `HelmConfig` + the `HELM_JENKINS_TOKEN` env var; the source is inert until all
/// are set. The HTTP runner is injected so decode + filtering is unit-tested without a network.
public struct JenkinsSource: AttentionSource {
    /// Resolved connection + job whitelist. Absent → the source produces nothing.
    public struct Config: Equatable {
        public let user: String        // matched against each build's trigger-cause userId
        public let token: String       // API token, HTTP basic auth
        public let jobURLs: [String]   // full job URLs, e.g. https://host/job/Mobile/job/Deploy/

        public init(user: String, token: String, jobURLs: [String]) {
            self.user = user; self.token = token; self.jobURLs = jobURLs
        }
    }

    /// Runs an HTTP request and returns the body, or empty `Data` on any failure (offline,
    /// non-2xx, missing host). Never throws — a dead Jenkins degrades the feed to its peers.
    public typealias Runner = (_ method: String, _ url: URL, _ user: String, _ token: String) -> Data

    let config: Config?
    /// A finished build older than this drops out of the feed (still reachable via search).
    let freshWindow: TimeInterval
    /// How many recent builds per job to scan for one of yours.
    let buildsToScan: Int
    /// Clock, evaluated per call. Injected for tests.
    let now: () -> Date
    let run: Runner

    public init(config: Config? = JenkinsSource.resolveConfig(),
                freshWindow: TimeInterval = 24 * 3600,
                buildsToScan: Int = 15,
                now: @escaping () -> Date = { Date() },
                run: @escaping Runner = JenkinsSource.httpRun) {
        self.config = config
        self.freshWindow = freshWindow
        self.buildsToScan = buildsToScan
        self.now = now
        self.run = run
    }

    // MARK: AttentionSource

    public var id: String { "jenkins" }
    public var title: String { "JENKINS" }
    /// Network-bound but the running-build view should feel live: poll a touch faster than PRs.
    public var refreshPolicy: RefreshPolicy { .interval(10) }

    public func allItems() async -> [any AttentionItem] { fetchAll() }

    /// Building + failed + unstable rows reach the feed; a clean (or aborted) finish is
    /// inventory-only — `reason` is `.none` there.
    public func promotes(_ item: any AttentionItem) -> Bool { item.reason != .none }

    // MARK: Fetch

    /// One row per whitelisted job that currently has a build of yours worth showing, ordered
    /// loudest-first then newest. Sequential per job — the list is small by design. Off-main.
    public func fetchAll() -> [JenkinsJob] {
        guard let config else { return [] }
        let rows = config.jobURLs.compactMap { jobURL -> JenkinsJob? in
            guard let job = fetchJob(jobURL, user: config.user, token: config.token) else { return nil }
            return row(from: job, user: config.user)
        }
        return rows.sorted(by: AttentionFeed.precedes)
    }

    /// Abort the given build. Fire-and-forget POST to `<build>/stop`; off-main.
    public func stop(_ job: JenkinsJob) {
        guard let config, let url = URL(string: job.stopURL) else { return }
        _ = run("POST", url, config.user, config.token)
    }

    private func fetchJob(_ jobURL: String, user: String, token: String) -> JobDTO? {
        guard let url = Self.apiURL(forJob: jobURL, buildsToScan: buildsToScan) else { return nil }
        return Self.decode(JobDTO.self, from: run("GET", url, user, token))
    }

    /// Your latest build of `job` (highest number whose trigger cause is you), reduced to a
    /// feed row — or nil when none of your builds qualify (none yours, or your latest finished
    /// too long ago).
    func row(from job: JobDTO, user: String) -> JenkinsJob? {
        let mine = job.builds.filter { $0.triggered(by: user) }
        guard let latest = mine.max(by: { $0.number < $1.number }) else { return nil }

        let building = latest.building ?? false
        let finishedAt = latest.timestamp.map { Date(timeIntervalSince1970: $0 / 1000) } ?? now()
        if !building, now().timeIntervalSince(finishedAt) > freshWindow { return nil }

        let folders = Self.folders(fromJobURL: job.url)
        return JenkinsJob(
            name: job.displayName ?? job.name ?? folders.last ?? "build",
            folder: folders.dropLast().last ?? URL(string: job.url)?.host ?? "Jenkins",
            number: latest.number,
            url: latest.url,
            result: JenkinsBuildResult.from(latest.result),
            building: building,
            finishedAt: finishedAt,
            estimatedDuration: building ? max((latest.estimatedDuration ?? 0) / 1000, 0) : 0)
    }

    // MARK: Config resolution

    /// Resolve from `HelmConfig` (host/user/job whitelist) plus the API token. Any piece
    /// missing → nil → the source stays silent.
    public static func resolveConfig(config: HelmConfig = .load(),
                                     env: [String: String] = ProcessInfo.processInfo.environment,
                                     tokenFile: URL = JenkinsSource.tokenFile) -> Config? {
        guard let user = config.jenkinsUser, !user.isEmpty,
              let token = resolveToken(env: env, file: tokenFile)
        else { return nil }
        let jobURLs = config.jenkinsJobs.compactMap { absoluteJobURL($0, base: config.jenkinsURL) }
        guard !jobURLs.isEmpty else { return nil }
        return Config(user: user, token: token, jobURLs: jobURLs)
    }

    /// Resolve a `jenkinsJobs` entry to an absolute job URL: an entry that already carries a
    /// scheme is used as-is; otherwise it's treated as a path joined onto `jenkinsURL`. Nil when
    /// an entry is relative but no base host is configured — so a typo can't silently hit nothing.
    static func absoluteJobURL(_ entry: String, base: String?) -> String? {
        let entry = entry.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty else { return nil }
        if entry.hasPrefix("http://") || entry.hasPrefix("https://") { return entry }
        guard let base, !base.isEmpty else { return nil }
        let host = base.hasSuffix("/") ? String(base.dropLast()) : base
        return host + (entry.hasPrefix("/") ? entry : "/" + entry)
    }

    /// The API token, from `HELM_JENKINS_TOKEN` if set (override, for terminal/CI launches),
    /// else a `~/.config/helm/jenkins-token` file (chmod 600). The file works regardless of
    /// launch method — a Dock-launched GUI app inherits no shell environment — and survives
    /// rebuilds, unlike a Keychain item gated on this ad-hoc-signed binary's identity.
    public static func resolveToken(env: [String: String] = ProcessInfo.processInfo.environment,
                                    file: URL = JenkinsSource.tokenFile) -> String? {
        if let token = env["HELM_JENKINS_TOKEN"], !token.isEmpty { return token }
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    public static var tokenFile: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/helm/jenkins-token")
    }

    // MARK: URL helpers

    private static let buildFields =
        "number,url,result,timestamp,building,estimatedDuration,actions[causes[userId,userName]]"

    /// `<job>/api/json?tree=…builds[…]{0,N}` for one job URL.
    static func apiURL(forJob jobURL: String, buildsToScan: Int) -> URL? {
        var base = jobURL
        if !base.hasSuffix("/") { base += "/" }
        guard var comps = URLComponents(string: base + "api/json") else { return nil }
        comps.queryItems = [URLQueryItem(
            name: "tree",
            value: "name,displayName,url,builds[\(buildFields)]{0,\(buildsToScan)}")]
        return comps.url
    }

    /// The ordered job/folder names in a Jenkins URL (`/job/Mobile/job/Deploy/…` → `["Mobile","Deploy"]`).
    static func folders(fromJobURL url: String) -> [String] {
        guard let comps = URLComponents(string: url) else { return [] }
        let parts = comps.path.split(separator: "/").map(String.init)
        var result: [String] = []
        var i = 0
        while i < parts.count {
            if parts[i] == "job", i + 1 < parts.count { result.append(parts[i + 1]); i += 2 }
            else { i += 1 }
        }
        return result
    }

    // MARK: Decode

    static let decoder = JSONDecoder()

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        guard !data.isEmpty else { return nil }
        return try? decoder.decode(type, from: data)
    }

    /// Default runner: a synchronous HTTP request with API-token basic auth. Synchronous because
    /// callers already run it off the main thread; mirrors `PRSource.shellOut`'s blocking style.
    public static func httpRun(_ method: String, _ url: URL, _ user: String, _ token: String) -> Data {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = method
        let credentials = Data("\(user):\(token)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")

        let semaphore = DispatchSemaphore(value: 0)
        var body = Data()
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<400).contains(code), let data else { return }
            body = data
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 15)
        return body
    }
}

// MARK: API DTOs

struct JobDTO: Decodable {
    let name: String?
    let displayName: String?
    let url: String
    let builds: [Build]

    struct Build: Decodable {
        let number: Int
        let url: String
        let result: String?            // null while building
        let timestamp: Double?         // epoch millis
        let building: Bool?
        let estimatedDuration: Double? // predicted run length, millis (-1 when unknown)
        let actions: [Action]?

        struct Action: Decodable { let causes: [Cause]? }
        struct Cause: Decodable { let userId: String?; let userName: String? }

        /// True when one of this build's trigger causes is the given user (a manual
        /// "Started by user …"). SCM/timer/upstream causes carry no `userId` and don't match.
        func triggered(by user: String) -> Bool {
            let causes = (actions ?? []).compactMap(\.causes).flatMap { $0 }
            return causes.contains {
                $0.userId?.caseInsensitiveCompare(user) == .orderedSame
                    || $0.userName?.caseInsensitiveCompare(user) == .orderedSame
            }
        }
    }
}
