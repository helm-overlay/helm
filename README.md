# Helm

Master-view overlay for Claude Code sessions — a summon/dismiss HUD pinned to the top
of the screen that lists every project → its chats (live and historical), and opens a
chat in the terminal via `claude --resume`. Working name; see `../PROJECT.md` for the
design decisions.

## Layout

- `Sources/HelmCore` — headless, testable data layer. Reads the two session sources and
  joins them on `sessionId`:
  - **Live**: `~/.claude/sessions/<pid>.json` (running sessions only; pid/status/kind/name).
    Liveness via `kill(pid, 0)`.
  - **History**: `~/.claude/projects/*/<sessionId>.jsonl` (every session; filename ==
    sessionId). Extracts `cwd` / `gitBranch` / `aiTitle` + file mtime.
  - Grouping: cwd under `~/projects/<name>` → `<name>`, everything else → `Other`.
- `Sources/HelmProbe` — CLI that prints the merged tree (uses `HelmCore` directly).
- `Sources/Helm` — the `NSPanel` app: non-activating floating overlay + global hotkey,
  the SwiftUI row list, the orbit status indicator, and terminal dispatch.
- `Tests/HelmCoreTests` — unit tests for the pure join/group/state logic.

## Session status & needs-input classification

Each row's orbit indicator encodes state: **busy** orbits, **idle** parks at 9 o'clock,
**dead** dashes the ring, and **needs-input** (an idle session waiting on *you*) parks
amber and pulses. Idle is split into needs-input vs done two ways:

1. **In-process (always on, fallback):** `SessionStore.classifyIdleTail` reads the
   transcript tail — an unanswered `tool_use` or a final line ending in `?` → needs-input.
   High precision, low recall.
2. **Haiku Stop hook (recall lift):** a classification verdict written to
   `~/.helm/state/<sessionId>.json`, which `load()` prefers when present.

> **The hooks live in `~/.claude/settings.json`, NOT in this repo** (Claude Code config,
> per-machine). To reproduce on another machine, add these to `settings.json` → `hooks`:
>
> - **`Stop`** — `type: "agent"`, `model: "claude-haiku-4-5-..."`: prompt the agent to
>   read `last_assistant_message` from the hook input, classify needs-input/done, and
>   `Write` `~/.helm/state/<session_id>.json` as `{"reason":"...","sessionId":"...","ts":N}`.
>   (Agent hooks inherit the session's tool perms, so `Write` must be allowed.)
> - **`UserPromptSubmit`** — `type: "command"`, `async: true`:
>   `rm -f "$HOME/.helm/state/$(jq -r '.session_id').json"` (wipe at turn start so any
>   present file is from the latest `Stop`).
> - **`SessionEnd`** — same `rm -f` command (cleanup on clean exit).
>
> Helm also deletes the file itself when you `⌘X`-kill a session, since a killed process
> never runs its `SessionEnd` hook. No hooks configured? Classification silently falls
> back to (1).

## Build & run

The Xcode project is generated from `project.yml` (not committed):

```sh
xcodegen generate
xcodebuild -project Helm.xcodeproj -scheme HelmProbe -configuration Debug \
  -derivedDataPath build build
./build/Build/Products/Debug/HelmProbe        # print the session tree

xcodebuild -project Helm.xcodeproj -scheme HelmCoreTests \
  -destination 'platform=macOS' test          # run unit tests
```
