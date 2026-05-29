import SwiftUI
import HelmCore

/// New-project form. Rendered in the overlay panel in place of the sessions/tasks view
/// while `AppShellModel.presentingNewProject` is true (a modal-as-view, not a SwiftUI
/// sheet — sheets misbehave inside the non-activating NSPanel).
struct ProjectCreateView: View {
    @ObservedObject var model: ProjectCreateViewModel
    let onCancel: () -> Void
    let onSuccess: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nameField
                    reposSection
                    if let err = model.submitError {
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            Divider().opacity(0.5)
            footer
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.badge.plus").foregroundStyle(.secondary)
            Text("NEW PROJECT")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.tertiary)
                .tracking(0.8)
            Spacer()
            Text("⌘⇧N · esc")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: Name

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PROJECT NAME")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary).tracking(0.6)
            HStack(spacing: 8) {
                PanelTextField(text: $model.name,
                               placeholder: "kebab-case",
                               fontSize: 15,
                               autofocus: true,
                               onReturn: { submit(); return true })
                    .frame(height: 22)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: model.name) { _, _ in model.revalidateName() }
                statusBadge(for: model.nameStatus)
            }
        }
    }

    @ViewBuilder
    private func statusBadge(for v: ProjectManager.NameValidation) -> some View {
        switch v {
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .empty:
            EmptyView()
        case .notKebabCase:
            Label("not kebab-case", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.orange)
                .help("lowercase letters, digits, hyphens; no leading/trailing/double hyphens")
        case .collides:
            Label("already exists", systemImage: "xmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.red)
                .help("~/projects/\(model.name) already exists")
        }
    }

    // MARK: Repos

    private var reposSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("REPOS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary).tracking(0.6)
                Text("(optional — leave blank for a bare project)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            ForEach($model.rows) { $row in
                let repoMatch = model.topMatch(forRepo: row.repo)
                let branchMatch = model.topMatch(forBranch: row.branch, resolvedRepo: repoMatch)
                RepoRow(row: $row,
                        projectName: model.name,
                        repoSuggestions: model.availableRepos,
                        repoTopMatch: repoMatch,
                        branchSuggestions: model.branches[repoMatch ?? ""] ?? [],
                        branchTopMatch: branchMatch,
                        result: result(for: row.id),
                        onRemove: { model.removeRow(row.id) },
                        onTouched: { model.touchRow(row.id) },
                        onRepoResolved: { model.ensureBranches(forResolvedRepo: $0) },
                        onSubmit: submit)
            }
            Button(action: model.addRow) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                    Text("Add repo").font(.system(size: 13))
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
    }

    private func result(for rowId: UUID) -> ProjectManager.RepoResult? {
        guard !model.results.isEmpty,
              let idx = model.rows.firstIndex(where: { $0.id == rowId }) else { return nil }
        let nonBlankIndices = model.rows.enumerated()
            .filter { !$0.element.repo.isEmpty }
            .map { $0.offset }
        guard let resultIdx = nonBlankIndices.firstIndex(of: idx),
              resultIdx < model.results.count else { return nil }
        return model.results[resultIdx]
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            hint("esc", "cancel")
            Spacer()
            if model.isSubmitting {
                ProgressView().controlSize(.small).padding(.trailing, 4)
            }
            Button(action: submit) {
                Text("Create project")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 6)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canSubmit)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).fontWeight(.semibold)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private func submit() {
        _Concurrency.Task {
            if let projectRoot = await model.submit() {
                onSuccess(projectRoot)
            }
        }
    }
}

/// One {repo, branch} entry. Both fields show a "→ <match>" hint when the typed value
/// is a partial match; Tab accepts the suggestion in place. Repo matches against
/// `~/Home/dev/repos`; branch matches against the resolved repo's local branches
/// (only suggests if the typed value matches an existing branch — typing a brand-new
/// branch name is the create-new path and gets no hint).
private struct RepoRow: View {
    @Binding var row: ProjectCreateViewModel.Row
    let projectName: String
    let repoSuggestions: [String]
    let repoTopMatch: String?
    let branchSuggestions: [String]
    let branchTopMatch: String?
    let result: ProjectManager.RepoResult?
    let onRemove: () -> Void
    let onTouched: () -> Void
    let onRepoResolved: (String) -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                PanelTextField(text: $row.repo,
                               placeholder: "repo",
                               fontSize: 14,
                               onTab: { acceptRepo() },
                               onReturn: { onSubmit(); return true })
                    .frame(height: 22)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: row.repo) { _, _ in
                        onTouched()
                        if let m = repoTopMatch { onRepoResolved(m) }
                    }
                Text("/").foregroundStyle(.tertiary)
                PanelTextField(text: $row.branch,
                               placeholder: projectName.isEmpty ? "branch" : projectName,
                               fontSize: 14,
                               onTab: { acceptBranch() },
                               onReturn: { onSubmit(); return true })
                    .frame(height: 22)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: row.branch) { _, _ in onTouched() }
                resultBadge
                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            hintRow
        }
    }

    @ViewBuilder
    private var hintRow: some View {
        HStack(spacing: 20) {
            if let h = repoHint() {
                Text(h)
                    .font(.system(size: 11))
                    .foregroundStyle(repoTopMatch == nil ? Color.red : Color.secondary)
            }
            if let h = branchHint() {
                Text(h)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.leading, 10)
    }

    /// True iff the typed value is consumed (we autocompleted it); false lets focus
    /// move to the next field via the responder chain's default Tab behavior.
    private func acceptRepo() -> Bool {
        guard let m = repoTopMatch, m != row.repo else { return false }
        row.repo = m
        return true
    }
    private func acceptBranch() -> Bool {
        guard let m = branchTopMatch, m != row.branch else { return false }
        row.branch = m
        return true
    }

    @ViewBuilder
    private var resultBadge: some View {
        switch result {
        case .success(let branch, let createdBranch, let base):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(createdBranch ? "new \(branch) off \(base ?? "?")" : "attached \(branch)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .failed(let m):
            HStack(spacing: 4) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(m).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        case nil:
            EmptyView()
        }
    }

    private func repoHint() -> String? {
        if row.repo.isEmpty { return nil }
        if repoSuggestions.contains(row.repo) { return nil }
        if let m = repoTopMatch { return "↹ \(m)" }
        return "no matching repo under ~/Home/dev/{repos,utils}"
    }

    private func branchHint() -> String? {
        if row.branch.isEmpty { return nil }
        if branchSuggestions.contains(row.branch) { return nil }
        if let m = branchTopMatch { return "↹ \(m)" }
        return nil
    }
}
