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

Each row's orbit indicator encodes state: **busy** orbits, **dead** dashes the ring, and
the two idle states each get their own motion — **needs-input** (idle, waiting on *you*)
parks amber and pings a sonar ring; **needs-review** (idle, finished, come look) parks
violet under a calm "lighthouse" comet arc sweeping the ring. Idle is split into
needs-input vs needs-review two ways:

1. **In-process (always on, fallback):** `SessionStore.classifyIdleTail` reads the
   transcript tail — an unanswered `tool_use` or a final line ending in `?` → needs-input.
   High precision, low recall.
2. **Haiku Stop hook (recall lift):** a classification verdict written to
   `~/.helm/state/<sessionId>.json`, which `load()` prefers when present. (The wire format
   predates the rename, so the hook still writes `"done"`; it maps to `needsReview`.)

**Attention-first.** Rows sort by `SessionStore.attentionRank` (needs-input → needs-review
→ busy → cold) so the session that wants you never sinks below busier rows or into the
collapsed tail. **⌥⇧Space** jumps straight to the next such session (`nextAttentionSession`,
cycling) without even opening the panel — the summon hotkey is **⌥Space**.

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
> never runs its `SessionEnd` hook. As a backstop for crashes/kills that skip `SessionEnd`
> entirely, the app reaps `~/.helm/state` every 2 min, dropping any file whose session is
> no longer running (`SessionStore.reapDeadState`). No hooks configured? Classification
> silently falls back to (1).

## Build & run

The Xcode project is generated from `project.yml` (not committed):

```sh
xcodegen generate
xcodebuild -project Helm.xcodeproj -scheme HelmProbe -configuration Debug \
  -derivedDataPath build build
./build/Build/Products/Debug/HelmProbe        # print the session tree

xcodebuild -project Helm.xcodeproj -scheme HelmCore \
  -destination 'platform=macOS' test          # run unit tests
```

## Dev loop

`bin/dev` wraps the common build/test invocations:

```sh
bin/dev app       # rebuild full Helm.app Debug
bin/dev ship      # rebuild Release, copy to /Applications
bin/dev test      # generate project and run HelmCore unit tests
bin/dev check     # generate project, run tests, and build Debug Helm.app
```

> Helm no longer ships the `project` CLI — it now lives as a standalone Python
> tool (`~/Home/dev/utils/projects-cli/`, symlinked at `~/.local/bin/project`).
> Helm is the session overlay only.
