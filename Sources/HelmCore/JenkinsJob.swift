import Foundation

/// A Jenkins build *you triggered*, surfaced in the attention feed. Conforms to `AttentionItem`
/// so it sits alongside sessions and pull requests. Read via `JenkinsSource`, which polls a
/// whitelist of jobs and keeps your latest build per job. A row is either building right now
/// (a live row you can watch / stop) or a recently-finished build worth a glance.
public struct JenkinsJob: AttentionItem, Equatable {
    /// Leaf job name (Jenkins `displayName`, e.g. "Block Hosts From Deploys").
    public let name: String
    /// Parent folder shown as the row's "where" anchor (e.g. "Mobile"); the instance host
    /// when the job isn't nested.
    public let folder: String
    public let number: Int
    /// The build's URL — opened on Enter and the base for the `/stop` POST.
    public let url: String
    public let result: JenkinsBuildResult
    public let building: Bool
    /// For a finished build, when it finished. For a building one, when it *started* (the
    /// progress baseline). Either way it's the build's `timestamp`, and the row's recency.
    public let finishedAt: Date
    /// Jenkins' predicted run length (seconds), for the live progress ring. 0 when unknown
    /// (e.g. a job's first build) or not building.
    public let estimatedDuration: TimeInterval

    public init(name: String, folder: String, number: Int, url: String,
                result: JenkinsBuildResult, building: Bool, finishedAt: Date,
                estimatedDuration: TimeInterval = 0) {
        self.name = name; self.folder = folder; self.number = number; self.url = url
        self.result = result; self.building = building; self.finishedAt = finishedAt
        self.estimatedDuration = estimatedDuration
    }

    /// Fraction complete (0…1) of a running build at `date`, from elapsed-over-estimate.
    /// Zero when not building or the estimate is unknown — the indicator falls back to an
    /// indeterminate spinner there. Clamped, so an over-running build pins at full.
    public func progress(at date: Date) -> Double {
        guard building, estimatedDuration > 0 else { return 0 }
        let elapsed = date.timeIntervalSince(finishedAt)
        return min(max(elapsed / estimatedDuration, 0), 1)
    }

    public var id: String { "jenkins:\(url)" }
    public var badge: AttentionBadge { .jenkins }
    public var title: String { name }
    public var context: String { folder }
    public var subtitle: String? { "\(folder) » \(name) #\(number)" }
    public var lastActive: Date { finishedAt }
    /// Enter opens the build page; ⌘X stops it (only meaningful while building).
    public var primaryAction: AttentionAction { .openURL(url) }
    /// The endpoint that aborts this build.
    public var stopURL: String { url.hasSuffix("/") ? url + "stop" : url + "/stop" }

    /// A build in progress is a dimmed live row (watch it run). A finished build that failed or
    /// went unstable demands a look; a clean success is inventory-only (surfaces on search).
    public var reason: AttentionReason {
        if building { return .live }
        switch result {
        case .failure:  return .jenkinsFailed
        case .unstable: return .jenkinsUnstable
        default:        return .none
        }
    }

    public func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return name.lowercased().contains(query)
            || folder.lowercased().contains(query)
            || "#\(number)".contains(query)
            || result.rawValue.contains(query)
    }
}

/// A finished build's verdict (Jenkins `result`), or `none` while building / unknown.
public enum JenkinsBuildResult: String, Equatable {
    case success, failure, unstable, aborted, notBuilt, none

    /// Maps the API `result` string (SUCCESS / FAILURE / UNSTABLE / ABORTED / NOT_BUILT, or
    /// null while a build is still running).
    public static func from(_ raw: String?) -> JenkinsBuildResult {
        switch raw?.uppercased() {
        case "SUCCESS":   return .success
        case "FAILURE":   return .failure
        case "UNSTABLE":  return .unstable
        case "ABORTED":   return .aborted
        case "NOT_BUILT": return .notBuilt
        default:          return .none
        }
    }
}
