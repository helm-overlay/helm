# AGENTS.md

Guidance for agents working in this repository.

## What Helm is

Helm is a macOS Swift app for managing coding-agent sessions (currently Claude Code and Pi).

The main app is a non-activating `NSPanel` overlay summoned by global hotkeys. Its primary view lists agent sessions grouped by project, classifies live idle sessions by whether they need user input vs review, and opens/resumes chats in the configured terminal.

Project/worktree management is NOT Helm's job — that lives in a standalone Python `project` CLI (`~/Home/dev/utils/projects-cli/`, symlinked at `~/.local/bin/project`). Helm is the session overlay only.

## Repository layout

- `project.yml` — XcodeGen source of truth. `Helm.xcodeproj` is generated and gitignored.
- `Sources/HelmCore/` — testable data/model layer.
  - `SessionStore.swift` joins per-agent live registry/state files with transcript history, groups/sorts sessions, classifies idle tails, reaps stale hook state, and exposes live-only refresh logic.
  - `Models.swift` defines `ChatSession`, `LiveRecord`, `HistoryRecord`, session/idle states, and placeholder rows.
  - `AttentionItem.swift` / `AttentionFeed.swift` define the attention-feed seam: the `AttentionItem` row contract, the `AttentionReason` rank scale, and the `AttentionSource` protocol (+ `SessionFeedSource`) that every row producer conforms to. See "Attention launcher" below.
  - `PullRequest.swift` / `PRSource.swift` are the PR row type and its `gh`-backed `AttentionSource`.
  - `HelmConfig.swift` loads `~/.config/helm/config.json`.
- `Sources/Helm/` — macOS app/UI.
  - `AppDelegate.swift` wires hotkeys, panel lifecycle, key handling, session actions, and state reaping.
  - `RootView.swift` hosts the attention launcher and the new-chat picker overlay — Helm is a single view.
  - `AttentionListView.swift` / `AttentionListViewModel.swift` render the attention launcher (the only view) from the registered `AttentionSource`s.
  - `OrbitIndicators.swift` renders the session and PR orbit status glyphs.
  - `TerminalDispatcher.swift` opens/resumes Claude in Terminal.app/iTerm and focuses existing tabs by TTY when possible.
  - `SessionNotifier.swift` posts a macOS notification when a session crosses into an attention state while the panel is closed (transition detection is `HelmCore.NotificationPlanner`).
  - `OverlayPanel.swift`, `GlobalHotKey.swift`, `Components.swift` are UI/platform helpers.
- `Sources/HelmProbe/` — CLI that prints the merged session tree for debugging.
- `Sources/HelmCLI/` — `helm` setup CLI. `helm init pi` installs the Pi package via `pi install`; `helm init claude` clones the external Claude plugin repo into `~/.claude/skills/helm` so Claude auto-loads it.
- `Tests/HelmCoreTests/` — unit tests for pure core logic and temp-filesystem readers.
- `bin/dev` — local dev helper for rebuilding/testing the app; `app`, `ship`, and `check` also build `HelmCLI` and symlink `~/.local/bin/helm`.

## External data and state

Session manager inputs:

- Claude live sessions: `~/.claude/sessions/<pid>.json`
  - Records include `pid`, `sessionId`, `status`, `kind`, `name`, and `entrypoint`.
  - `ClaudeSessionBackend` keeps only alive PIDs (`kill(pid, 0)`) and user threads (`entrypoint == nil || entrypoint == "cli"`).
- Claude history: `~/.claude/projects/*/<sessionId>.jsonl`
  - Filename is the `sessionId`.
  - Helm reads transcript heads for `cwd`, `gitBranch`, `aiTitle`, `entrypoint`, and mtime.
  - `agent-*.jsonl` subagent transcripts and SDK/hook-created sessions are filtered out.
- Claude hook run/attention state: `~/.helm/claude/state/<sessionId>.json`
  - Wire shape `{"reason","sessionId","ts","summary"}`. `reason` values: `needs_input`, `done` (→ `needsReview`), and `running` (working; reads as no attention verdict). Unknown/`running` → falls through to the live registry + tail heuristics.
  - `summary` is the Stop classifier's one-line "what happened", surfaced as the notification body (`ChatSession.attentionSummary`). The bash handlers (`running`/mid-turn `needs_input`) omit it.
  - Authoritative for **any** live row, not just idle ones: a `needs_input`/`done` verdict promotes even a busy row to an attention row (`SessionStore.resolveLiveRow`). That's how a mid-turn AskUserQuestion surfaces while the registry still says busy.
  - Installed by `helm init claude`, which clones `https://github.com/helm-overlay/claude-plugin.git` into `~/.claude/skills/helm` (Claude Code 2.1.157+ auto-loads plugins from `.claude/skills`; `claude plugin install` is only for marketplaces). The plugin owns SessionStart/UserPromptSubmit/PreToolUse(AskUserQuestion)/PostToolUse(AskUserQuestion)/Stop/SessionEnd. The Stop verdict is still a Haiku agent hook.
- Pi history/state:
  - History comes from Pi's session files under `~/.pi/agent/sessions/`.
  - Live/run/attention state is written to `~/.helm/pi/state/<sessionId>.json` by the Pi package installed with `helm init pi` (`pi install git:github.com/helm-overlay/pi-plugin`).
  - Pi state includes liveness metadata such as `pid`, `sessionFile`, `cwd`, `status`, `name`, and `entrypoint` when available.
- The app reaps stale state whose sessions are no longer alive every 2 minutes and clears a file when it kills a session itself.

User config:

```json
{
  "terminal": "terminal",          // or "iterm"/"iterm2"
  "notificationsEnabled": true     // macOS notifications on attention crossings (panel closed)
}
```

Config path: `~/.config/helm/config.json`. Missing/malformed config falls back to defaults.

## Current behavior to preserve

### Attention launcher (default view)

- The **only** view (summon: `⌥Space`; jump-to-next-attention: `⌥⇧Space`, session-only via `SessionStore.nextAttentionSession`). It is **source-driven**: `AttentionListViewModel` holds a list of `AttentionSource`s and renders each one's promoted rows as a titled section, ranked by urgency. The registered sources today are `SessionFeedSource` and `PRSource`.
- **At rest** the feed shows only promoted rows. **On search** (non-empty query) the `promotes` gate drops and the full cached inventory is matched via `AttentionItem.matches(_:)` — cold sessions and non-urgent PRs surface, so a past chat is still resumable by typing. This is why there's no separate sessions/PRs panel.
- An `AttentionSource` declares `id`, section `title`, and `refreshPolicy`; produces `allItems()`; and gates which of those rows reach the feed via `promotes(_:)`. The view-model polls each source on its own cadence (sessions `.interval(1.5)`, PRs `.interval(15)`) into a per-source cache slice, so a slow network source never blocks a fast local one. `refresh(_:)`, `inventory(matching:)`, and the `start(onChange:)` / `stop()` push lifecycle are defaulted — a poll-driven source implements only the first five members.
- Rows of different types interleave on one `AttentionReason` rank scale (lowest = loudest): action-required (needs-input / changes-requested / CI-failed) = 0, come-look (needs-review / review-requested / mergeable) = 1, busy `.live` = 2 (shown dimmed), cold / inventory-only = 3 (never promoted). `AttentionFeed.precedes` is the shared rank-then-recency comparator; `promotes` defaults to "not rank-3".
- The row contract (`AttentionItem`) carries everything the UI needs — `title`, `context`, `reason`, `primaryAction` — so Enter dispatch switches on `primaryAction`, never the concrete type. The lone exception is the orbit glyph in `AttentionListView`, which reads the concrete row because the orbit views live in the UI layer.
- `SessionFeedSource` builds a fresh `SessionStore()` per read so config changes (workspace folders, enabled agents) are reflected live.
- **Adding a source:** conform a type to `AttentionSource` (set `id` / `title` / `refreshPolicy`, implement `allItems()` + `promotes(_:)`), add it to the `AttentionListViewModel(sources:)` default list, and add one `indicator` case in `AttentionListView` for its glyph. Nothing else changes.

### Sessions: grouping, classification, refresh, kill, notifications

- A session's cwd maps to a group used for its `context` label and the new-chat picker (not a panel): exact `~/Home` → `Singular Chats`; `~/projects/<name>/...` → `<name>`; everything else → `Other`.
- Idle classification fallback is deliberately high-precision/low-recall:
  1. unanswered assistant `tool_use` means `needsInput`;
  2. assistant's final text line ending in `?` means `needsInput`;
  3. otherwise `needsReview`.
- `SessionFeedSource` polls `SessionStore().load()` every 1.5s while the launcher is open. `load()` stays cheap via the process-wide `historyCache` (keyed by path + mtime), so transcript heads aren't re-scanned unless a file changed.
- Killing a session closes/focuses terminal panes where possible, clears hook state, optimistically drops the row (suppressed until teardown confirms it gone), then SIGTERM/SIGKILLs off the main thread.
- Notifications fire only on a fresh attention crossing (`NotificationPlanner` diffs against the prior verdict) and only while the panel is closed; the first poll after launch primes the baseline silently so a backlog of finished sessions doesn't burst. A separate 5s timer drives this since the panel's own ticker stops when hidden. Tapping a banner (or Resume) jumps into that session.
  - If you're focused on that session's terminal tab when it crosses (`TerminalDispatcher.isSessionFocused` — terminal frontmost + its active tab owns the session pid's tty), Helm plays a chime instead of a banner. Otherwise it posts the full banner + sound.
  - When a session leaves attention (you responded → `running`, or it ended), `NotificationPlanner` reports it in `plan.cleared` and the delivered banner is removed (`removeDeliveredNotifications`), so a handled banner doesn't linger.
  - Notifications post at `.active` level, not `.timeSensitive`: the latter needs an entitlement a local build can't carry and is silently dropped without it.

## Development commands

Generate the Xcode project first if needed:

```sh
xcodegen generate
```

Build/probe/test:

```sh
xcodebuild -project Helm.xcodeproj -scheme HelmProbe -configuration Debug \
  -derivedDataPath build build
./build/Build/Products/Debug/HelmProbe

xcodebuild -project Helm.xcodeproj -scheme HelmCore \
  -destination 'platform=macOS' test
```

Dev helper:

```sh
bin/dev app    # generate project, build Debug Helm.app, build/link ~/.local/bin/helm
bin/dev ship   # generate project, Release build, copy to /Applications, build/link ~/.local/bin/helm
bin/dev test   # generate project and run HelmCore tests
bin/dev check  # generate project, run tests, build Debug Helm.app, build/link ~/.local/bin/helm
```

## Testing expectations

- Prefer adding or updating `HelmCoreTests` for behavior changes in parsing, grouping, sorting, classification, and config.
- Keep filesystem-dependent tests in temporary directories; do not touch real `~/.claude` or `~/.helm` paths from tests.
- For UI-only changes, still run the core test suite when logic in view models or core stores changes.

## Implementation notes and pitfalls

- Keep `HelmCore` headless and testable. UI files should not become the source of truth for parsing/session logic.
- `SessionStore.historyCache` is process-wide and keyed by path + mtime; preserve this performance characteristic when touching transcript scanning.
- Transcript reads intentionally avoid loading huge JSONL files wholesale. Head reading skips giant lines; tail reading is bounded.
- The view models (`SessionListViewModel`, `AttentionListViewModel`, `PRListViewModel`) are `@MainActor`; do expensive filesystem/process work in detached tasks and publish back on the main actor.
- `NSPanel` is non-activating/LSUIElement. Some normal menu/responder behavior is absent.
- `TerminalDispatcher` uses AppleScript and TTY matching. Be careful with shell quoting and AppleScript string escaping.
- Do not commit generated `Helm.xcodeproj`, `build/`, or `DerivedData/`.
- The main repo is `github.com/helm-overlay/helm` (`helm-bootstrap` is the default branch). External plugin repos are `github.com/helm-overlay/pi-plugin` and `github.com/helm-overlay/claude-plugin`; update those repos when changing plugin source, not Swift string literals.
