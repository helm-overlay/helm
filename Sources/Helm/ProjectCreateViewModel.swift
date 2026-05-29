import Foundation
import HelmCore

/// State for the new-project form. Owns its own ProjectManager; the view talks to it
/// only through @Published values and three intents: addRow / removeRow / submit.
@MainActor
final class ProjectCreateViewModel: ObservableObject {
    @Published var name: String = ""
    @Published var rows: [Row] = [Row()]
    @Published var nameStatus: ProjectManager.NameValidation = .empty
    @Published var isSubmitting: Bool = false
    @Published var results: [ProjectManager.RepoResult] = []
    @Published var submitError: String?
    /// Local branches per resolved repo. Loaded lazily as rows resolve to a real repo
    /// (see `ensureBranches`); used for the same `→ <match>` hint as the repo field.
    @Published var branches: [String: [String]] = [:]

    let availableRepos: [String]
    private let manager: ProjectManager

    struct Row: Identifiable, Equatable {
        let id = UUID()
        var repo: String = ""
        var branch: String = ""
    }

    init(manager: ProjectManager = ProjectManager()) {
        self.manager = manager
        self.availableRepos = manager.listAvailableRepos()
        revalidateName()
    }

    // MARK: Intents

    func revalidateName() {
        nameStatus = manager.validateName(name)
        clearResults()
    }

    func addRow() {
        rows.append(Row())
        clearResults()
    }

    func removeRow(_ id: UUID) {
        rows.removeAll { $0.id == id }
        if rows.isEmpty { rows = [Row()] }   // keep at least one blank row visible
        clearResults()
    }

    func touchRow(_ id: UUID, repo: String? = nil, branch: String? = nil) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        if let repo   { rows[i].repo = repo }
        if let branch { rows[i].branch = branch }
        clearResults()
    }

    /// Resolve a typed repo string to its top fuzzy match. Exact match wins; otherwise
    /// the first prefix match, otherwise the first substring match. Used for both the
    /// inline "→ <match>" hint and the actual submit value.
    func topMatch(forRepo s: String) -> String? {
        Self.topMatch(s, in: availableRepos)
    }

    /// Branch typeahead: only suggests if the typed value is a prefix or substring of an
    /// existing local branch. If the user types a brand-new branch name, no hint shown
    /// (that's the create-new path). Requires `ensureBranches(forResolvedRepo:)` to have
    /// populated the cache for the resolved repo.
    func topMatch(forBranch s: String, resolvedRepo: String?) -> String? {
        guard let resolvedRepo, let list = branches[resolvedRepo], !list.isEmpty else { return nil }
        return Self.topMatch(s, in: list)
    }

    private static func topMatch(_ s: String, in candidates: [String]) -> String? {
        if s.isEmpty { return nil }
        if candidates.contains(s) { return s }
        let q = s.lowercased()
        if let p = candidates.first(where: { $0.lowercased().hasPrefix(q) }) { return p }
        return candidates.first { $0.lowercased().contains(q) }
    }

    /// Kick off a branch fetch for the given resolved repo if we haven't already. No-op
    /// if cached. Pure-async; sets `branches[resolvedRepo]` when it lands.
    func ensureBranches(forResolvedRepo resolvedRepo: String) {
        guard branches[resolvedRepo] == nil else { return }
        branches[resolvedRepo] = []   // claim the slot so we don't re-fetch in a tight loop
        let manager = self.manager
        _Concurrency.Task.detached(priority: .userInitiated) {
            let list = manager.listBranches(repo: resolvedRepo)
            await MainActor.run { self.branches[resolvedRepo] = list }
        }
    }

    /// Empty rows are ignored. Other rows need a resolvable repo; branch may be blank
    /// (defaults to the project name on submit).
    var canSubmit: Bool {
        guard nameStatus == .ok, !isSubmitting else { return false }
        return rows.allSatisfy { row in
            if row.repo.isEmpty && row.branch.isEmpty { return true }
            return !row.repo.isEmpty && topMatch(forRepo: row.repo) != nil
        }
    }

    /// Returns the project root URL on full success; nil if validation failed, the
    /// create call threw, or any per-repo worktree failed (results are still populated
    /// so the view can render per-row status).
    func submit() async -> URL? {
        guard canSubmit else { return nil }
        let projectName = self.name
        let specs: [ProjectManager.RepoSpec] = rows.compactMap { row in
            guard !row.repo.isEmpty,
                  let resolved = topMatch(forRepo: row.repo) else { return nil }
            let branch = row.branch.isEmpty ? projectName : row.branch
            return ProjectManager.RepoSpec(repo: resolved, branch: branch)
        }

        isSubmitting = true
        submitError = nil
        results = []
        defer { isSubmitting = false }

        let manager = self.manager
        let name = self.name
        let outcome: ProjectManager.Outcome
        do {
            outcome = try await _Concurrency.Task.detached(priority: .userInitiated) {
                try manager.create(name: name, repos: specs)
            }.value
        } catch {
            submitError = "\(error)"
            return nil
        }

        results = outcome.repos.map { $0.result }
        return outcome.allSucceeded ? outcome.projectRoot : nil
    }

    private func clearResults() {
        if !results.isEmpty || submitError != nil {
            results = []
            submitError = nil
        }
    }
}
