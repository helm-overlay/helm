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
- `Tests/HelmCoreTests` — unit tests for the pure join/group/state logic.
- *(next)* the `NSPanel` app target: non-activating floating overlay + global hotkey.

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
