# Helm

Master-view overlay for coding-agent sessions — a summon/dismiss HUD pinned to the top
of the screen that lists every project → its chats (live and historical), and opens a
chat in the configured terminal. Working name; see `../PROJECT.md` for the design decisions.

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
2. **Hook/extension state (recall lift + mid-turn):** verdicts written to
   `~/.helm/claude/state/<sessionId>.json` or `~/.helm/pi/state/<sessionId>.json`, which
   `load()` prefers over the in-process classify whenever present — and which override even
   a *busy* row, so a session paused on an AskUserQuestion shows needs-input mid-turn
   (`SessionStore.resolveLiveRow`). `reason` is `needs_input`, `done` (→ `needsReview`; the
   wire word predates the rename), or `running` (working — read as no verdict).

**Attention-first.** Rows sort by `SessionStore.attentionRank` (needs-input → needs-review
→ busy → cold) so the session that wants you never sinks below busier rows or into the
collapsed tail. **⌥⇧Space** jumps straight to the next such session (`nextAttentionSession`,
cycling) without even opening the panel — the summon hotkey is **⌥Space**.

> **Install the hooks with `helm init claude`.** It clones
> `https://github.com/helm-overlay/claude-plugin.git` to `~/.claude/skills/helm/`
> (auto-loaded next session as `helm@skills-dir` since CC 2.1.157 — no marketplace). The
> plugin owns the whole lifecycle, writing `~/.helm/claude/state`:
>
> - **`SessionStart` / `UserPromptSubmit`** → `running` (alive and working; also clears the
>   previous turn's verdict).
> - **`PreToolUse(AskUserQuestion)`** → `needs_input`; **`PostToolUse(AskUserQuestion)`** →
>   `running` (answered, back to work).
> - **`Stop`** — `type: "agent"`, Haiku: reads the transcript tail, classifies, and
>   `Write`s `{"reason":"needs_input"|"done","sessionId":...,"ts":N}`. (Agent hooks inherit
>   the session's tool perms, so `Write` must be allowed.)
> - **`SessionEnd`** → clears the file.
>
> The plugin source lives in `github.com/helm-overlay/claude-plugin`; the CLI target is
> `HelmCLI` (product `helm`). Helm also deletes the file itself when you `⌘X`-kill a
> session, since a killed process never runs `SessionEnd`. As a backstop for crashes that
> skip it, the app reaps stale state every 2 min, dropping any file whose session is no
> longer running (`SessionStore.reapDeadState`). No plugin installed? Classification
> silently falls back to (1).
>
> *Liveness still comes from the live registry (`~/.claude/sessions`) + the reaper; moving
> it fully onto hook state (and dropping the registry) is the remaining step — see
> `HELM_AUDIT.md`.*

## Build & run

The Xcode project is generated from `project.yml` (not committed):

```sh
xcodegen generate
xcodebuild -project Helm.xcodeproj -scheme HelmProbe -configuration Debug \
  -derivedDataPath build build
./build/Build/Products/Debug/HelmProbe        # print the session tree

xcodebuild -project Helm.xcodeproj -scheme HelmCore \
  -destination 'platform=macOS' test          # run unit tests

xcodebuild -project Helm.xcodeproj -scheme helm -configuration Debug \
  -derivedDataPath build build                # build the `helm` CLI
./build/Build/Products/Debug/helm init claude # clone Claude plugin into ~/.claude/skills/helm
./build/Build/Products/Debug/helm init pi     # pi install git:github.com/helm-overlay/pi-plugin
```

## Dev loop

`bin/dev` wraps the common build/test invocations:

```sh
bin/dev app       # rebuild full Helm.app Debug and link ~/.local/bin/helm
bin/dev ship      # rebuild Release, copy to /Applications, and link ~/.local/bin/helm
bin/dev test      # generate project and run HelmCore unit tests
bin/dev check     # generate project, run tests, build Debug Helm.app, and link ~/.local/bin/helm
```

> Helm no longer ships the `project` CLI — it now lives as a standalone Python
> tool (`~/Home/dev/utils/projects-cli/`, symlinked at `~/.local/bin/project`).
> Helm is the session overlay only.
