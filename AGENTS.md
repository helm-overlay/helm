# AGENTS.md

Guidance for agents working in this repository.

## What Helm is

Helm is a macOS Swift app for managing agent/Claude Code sessions.

The main app is a non-activating `NSPanel` overlay summoned by global hotkeys. Its primary view lists Claude sessions grouped by project, classifies live idle sessions by whether they need user input vs review, and opens/resumes chats in the configured terminal. A secondary view lists tasks from a local markdown task vault.

Project/worktree management is NOT Helm's job — that lives in a standalone Python `project` CLI (`~/Home/dev/utils/projects-cli/`, symlinked at `~/.local/bin/project`). Helm is the session overlay only.

## Repository layout

- `project.yml` — XcodeGen source of truth. `Helm.xcodeproj` is generated and gitignored.
- `Sources/HelmCore/` — testable data/model layer.
  - `SessionStore.swift` joins live Claude registry files with transcript history, groups/sorts sessions, classifies idle tails, reaps stale hook state, and exposes live-only refresh logic.
  - `Models.swift` defines `ChatSession`, `LiveRecord`, `HistoryRecord`, session/idle states, and placeholder rows.
  - `TaskStore.swift`, `TaskModels.swift`, `TaskMutator.swift` read and mutate the markdown task vault.
  - `HelmConfig.swift` loads `~/.config/helm/config.json`.
- `Sources/Helm/` — macOS app/UI.
  - `AppDelegate.swift` wires hotkeys, panel lifecycle, key handling, session/task actions, and state reaping.
  - `RootView.swift` switches between the sessions and tasks views.
  - `OverlayView.swift` renders session rows and orbit status indicator.
  - `SessionListViewModel.swift` maintains grouped/filtered sessions, live refresh, selection, kill flow, and project focus.
  - `TaskListView.swift` and `TaskListViewModel.swift` render/filter/cycle task rows.
  - `TerminalDispatcher.swift` opens/resumes Claude in Terminal.app/iTerm and focuses existing tabs by TTY when possible.
  - `OverlayPanel.swift`, `GlobalHotKey.swift`, `Components.swift` are UI/platform helpers.
- `Sources/HelmProbe/` — CLI that prints the merged session tree for debugging.
- `Tests/HelmCoreTests/` — unit tests for pure core logic and temp-filesystem readers.
- `bin/dev` — local dev helper for rebuilding and testing the app.

## External data and state

Session manager inputs:

- Live sessions: `~/.claude/sessions/<pid>.json`
  - Records include `pid`, `sessionId`, `status`, `kind`, `name`, and `entrypoint`.
  - `SessionStore.readLive()` keeps only alive PIDs (`kill(pid, 0)`) and user threads (`entrypoint == nil || entrypoint == "cli"`).
- History: `~/.claude/projects/*/<sessionId>.jsonl`
  - Filename is the `sessionId`.
  - Helm reads transcript heads for `cwd`, `gitBranch`, `aiTitle`, `entrypoint`, and mtime.
  - `agent-*.jsonl` subagent transcripts and SDK/hook-created sessions are filtered out.
- Idle classification hook state: `~/.helm/state/<sessionId>.json`
  - Expected `reason` values are `needs_input` and `done` (`done` maps to `needsReview`).
  - Hook files are authoritative for idle rows when present; otherwise Helm falls back to transcript-tail heuristics.
  - The app reaps files whose sessions are no longer alive every 2 minutes and clears a file when it kills a session itself.

Task manager inputs:

- Vault: `~/Home/task-vault/tasks/*.md` and `~/Home/task-vault/archive/*.md`.
- Markdown files use flat YAML frontmatter. The parser intentionally matches the existing Python/widget behavior.
- Status mutation shells out to `~/Home/task-vault/_bin/set-status.py`, falling back to the legacy Übersicht widget path.

User config:

```json
{
  "terminal": "terminal",          // or "iterm"/"iterm2"
  "hideOlderThanDays": 1,
  "taskEditor": ["zed"]
}
```

Config path: `~/.config/helm/config.json`. Missing/malformed config falls back to defaults.

## Current behavior to preserve

### Sessions view

- Summon hotkey: `⌥Space`; jump-to-next-attention hotkey: `⌥⇧Space`.
- Rows are grouped by cwd:
  - Exact `~/Home` is `Singular Chats`.
  - `~/projects/<name>/...` is grouped under `<name>`.
  - Everything else is `Other`.
- Default view hides `Other`, hides cold `Singular Chats`, hides old cold rows per `hideOlderThanDays`, and caps each project to 3 rows with a `+N older` focus tail.
- Search spans all sessions/groups with fuzzy subsequence matching over label, project, branch, and cwd.
- Attention ordering is important: `needsInput` first, then `needsReview`, then busy live sessions, then cold sessions. Do not let attention rows sink below busy rows or collapse into the hidden tail.
- Idle classification fallback is deliberately high-precision/low-recall:
  1. unanswered assistant `tool_use` means `needsInput`;
  2. assistant's final text line ending in `?` means `needsInput`;
  3. otherwise `needsReview`.
- Per-second live refresh must stay cheap: read only the live registry and per-idle verdict/tail, not all history, unless a new session appears.
- Killing a session closes/focuses terminal panes where possible, clears hook state, optimistically marks the row cold, then SIGTERM/SIGKILLs off the main thread.

### Tasks view

- Switch with `⌘2` (`⌘1` returns to sessions).
- Polls the vault every second while open, with 30-second age-label ticks.
- Click/`⌘↵` cycles status `todo → wip → blocked → done → todo`.
- Cycling uses a short optimistic override and freezes row order briefly to avoid click jank.
- Active sort is by status rank (`wip`, `todo`, `blocked`, `done`) then mtime desc; archive search results are capped.

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
bin/dev app    # generate project, build Debug Helm.app
bin/dev ship   # generate project, Release build, copy to /Applications
bin/dev test   # generate project and run HelmCore tests
bin/dev check  # generate project, run tests, and build Debug Helm.app
```

## Testing expectations

- Prefer adding or updating `HelmCoreTests` for behavior changes in parsing, grouping, sorting, classification, and config.
- Keep filesystem-dependent tests in temporary directories; do not touch real `~/.claude`, `~/.helm`, or task vault paths from tests.
- For UI-only changes, still run the core test suite when logic in view models or core stores changes.

## Implementation notes and pitfalls

- Keep `HelmCore` headless and testable. UI files should not become the source of truth for parsing/session/task logic.
- `SessionStore.historyCache` is process-wide and keyed by path + mtime; preserve this performance characteristic when touching transcript scanning.
- Transcript reads intentionally avoid loading huge JSONL files wholesale. Head reading skips giant lines; tail reading is bounded.
- `SessionListViewModel` and `TaskListViewModel` are `@MainActor`; do expensive filesystem/process work in detached tasks and publish back on the main actor.
- `NSPanel` is non-activating/LSUIElement. Some normal menu/responder behavior is absent.
- `TerminalDispatcher` uses AppleScript and TTY matching. Be careful with shell quoting and AppleScript string escaping.
- Do not commit generated `Helm.xcodeproj`, `build/`, or `DerivedData/`.
