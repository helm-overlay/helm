# HELM_AUDIT

Audit date: 2026-05-30

Scope: full repository audit of Helm macOS app, HelmCore, ProjectCLI, tests, build config, docs, and automation.

Validation performed:

- `xcodebuild -project Helm.xcodeproj -scheme HelmCoreTests -destination 'platform=macOS' test` failed because `HelmCoreTests` is a target but not a scheme.
- After `xcodegen generate`, `xcodebuild -project Helm.xcodeproj -scheme HelmCore -destination 'platform=macOS' test` passed: 105 tests.
- Later validation after agent-state fixes passed: `xcodebuild -project Helm.xcodeproj -scheme HelmCore -destination 'platform=macOS' test` with 111 tests.
- `xcodebuild -project Helm.xcodeproj -scheme Helm -configuration Debug -derivedDataPath build build` passed.

## Highest priority fixes

All highest-priority audit fixes are complete as of 2026-05-30.

## Completed from audit

- Fixed README/AGENTS test scheme docs to use `-scheme HelmCore` instead of nonexistent `-scheme HelmCoreTests`.
- Made `bin/dev` regenerate the Xcode project before builds/tests and added `bin/dev test` / `bin/dev check`.
- Made session UI selection, scroll IDs, and attention cursor use agent-prefixed `ChatSession.id`.
- Made live refresh idle lookup use full `ChatSession` context, avoiding raw-session-ID ambiguity across agents.
- Fixed task optimistic override / reorder-freeze expiry when vault contents are unchanged.
- Narrowed worktree remove unpushed check to `git log HEAD --not --remotes --oneline`.
- Fixed `ProcessRunner.system` to drain stdout/stderr asynchronously before waiting on captured output.
- Restored Pi live registry reads from `~/.pi/sessions` and Pi hook state reads/clears from `~/.helm/pi/state`.
- Clear state files by agent when killing sessions.
  - Added `SessionStore.clearState(agent:sessionId:)` and backend-owned state clearing.
  - Killing Pi sessions now clears `~/.helm/pi/state/<id>.json` instead of only Claude hook state.
  - Added Pi backend test coverage.
- Removed obsolete highest-priority project-creation-view item after that UI was deleted.

## Performance / correctness improvements

- Claude idle classification should use `session.transcriptPath` before scanning all Claude project dirs. Current fallback locates transcripts by walking dirs on each idle check.
- Pi state-file freshness is now covered by hook cleanup: updated `~/.pi/agent/extensions/helm.ts` so `agent_start` deletes the previous `~/.helm/pi/state/<sessionId>.json` before writing live `busy`. Keep this invariant documented; if hook cleanup is removed later, add freshness checks against transcript/state timestamps.
- TODO: Move the entire live-state lifecycle for both Claude and Pi into hooks/extensions and remove the separate live JSON registries (`~/.claude/sessions/<pid>.json`, `~/.pi/sessions/<pid>.json`) if possible. A session can be marked running/busy on user prompt submit / agent start, marked idle with a verdict on stop / agent end, and cleared on session shutdown; Helm can read hook state directly instead of joining against separate live registry files.
- TODO: Add `helm init claude` and `helm init pi` style setup commands that install or update the required Claude hooks and Pi extensions automatically, instead of relying on manual per-machine hook configuration.
- Add an in-flight guard to `SessionListViewModel.refreshLiveState` so the 1s timer cannot stack detached refresh tasks.
- Change full reload behavior from “drop request while reloading” to “run again after current reload” when a reload request arrives mid-scan.
- Add pruning or an LRU cap to `SessionIO.historyCache`; currently it never evicts removed paths.
- Consider caching/indexing Pi transcript discovery if `~/.pi/agent/sessions` grows large.
- Consider replacing repeated `HelmConfig.load()` calls with a cached observable config refreshed on show or file change.

## Architecture recommendations

- Introduce an `AppEnvironment` / dependency container for config, stores, terminal dispatcher, task vault path, process runner, and clock.
- Make terminal dispatch testable behind a `TerminalClient` protocol. Test AppleScript generation and shell quoting without launching Terminal/iTerm.
- Extend `SessionBackend` with provider capabilities: resume command, new-chat command, state dir, transcript locator, display metadata. This reduces Claude/Pi branching in UI and dispatch code.
- Extract shared query/typeahead behavior from `SessionListViewModel` and `TaskListViewModel` into a small `QueryState` helper.
- Move session display shaping/filtering policy into HelmCore so default visibility, placeholders, caps, and focus mode can be unit-tested.
- Consider typed Codable transcript parsers for key formats instead of widespread `[String: Any]` parsing, while preserving robustness for partial/unknown lines.
- Add a small logging/diagnostics layer instead of silent `try?` in important side-effect paths.

## Project CLI / ProjectManager (removed from Helm)

The Swift `project` CLI, `HelmCore.ProjectManager`, and `ProcessRunner` were removed
(2026-06-01). Project/worktree management now lives in a standalone Python `project`
tool (`~/Home/dev/utils/projects-cli/`, symlinked at `~/.local/bin/project`); Helm is
the session overlay only. The improvement ideas that were listed here no longer apply
to this repo — carry them to the Python tool if still wanted.

## UI / UX feature ideas

- Add settings UI for terminal, enabled agents, default agent, task editor, hide-old cutoff, and hotkeys.
- Show an agent badge when more than one agent is enabled.
- Make `⌘N` use the selected row’s agent when a row is selected; otherwise use `defaultAgent`.
- Add per-row actions: copy session ID, copy cwd, reveal transcript, reveal project, kill, open fresh chat here.
- Add notifications or a subtle menu-bar badge for new `needsInput` while the panel is closed.
- Add a diagnostics pane: config path, enabled agents, live registry counts, transcript scan counts, hook state health, last refresh time.
- Add task creation, status filters, due/check-in editing, and Slack desktop deep-link rewrite.
- Add a menu bar item for status / settings / quit; LSUIElement apps otherwise lack discoverability.
- Consider an onboarding/first-run health check for Terminal automation permissions, hooks, and config.

## Features / code to remove or simplify

- Remove unused `TerminalDispatcher.resume(sessionId:cwd:pid:)` if it remains unused.
- Remove unused `TerminalKind.appName` if it remains unused.
- Remove unused `onDismiss` plumbing in `OverlayView` / `RootView`, or wire it to an actual close affordance.
- Eventually remove the legacy task-widget fallback path in `TaskMutator` once migration is complete.
- Consider retiring or renaming the “Other · legacy” framing once sessions are consistently project-rooted.
- Review `NSAppleEventsUsageDescription`: it mentions Claude/iTerm only, but Helm now supports Terminal and Pi too.

## Automation / quality gates

- Add `bin/dev test` and `bin/dev check`:
  - `xcodegen generate`
  - `xcodebuild -project Helm.xcodeproj -scheme HelmCore -destination 'platform=macOS' test`
  - `xcodebuild -project Helm.xcodeproj -scheme Helm -configuration Debug build`
- Add CI on a macOS runner if the repo is hosted remotely.
- Add SwiftFormat and/or SwiftLint with modest rules.
- Add code coverage for HelmCore.
- Add fixture-based performance tests for transcript scanning and live refresh.
- Add release automation: version bump, Release build, copy to `/Applications`, optional signing/notarization if desired.
- Add a pre-commit or CI check that `xcodegen generate` leaves `Helm.xcodeproj` consistent, even though it is gitignored locally.

## Overall assessment

The core shape is strong: HelmCore is mostly headless and testable, process execution has a seam, provider backends are emerging cleanly, and the existing core test suite is solid. The biggest next steps are:

1. Extract provider capabilities and terminal dispatch seams to reduce UI coupling.
2. Add setup/onboarding commands for Claude hooks and Pi extensions.
3. Add CI/formatting/release automation if desired.
