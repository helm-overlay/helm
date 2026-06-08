# Pi Support Plan for Helm

## Goal

Add support for the pi coding harness alongside Claude Code while preserving Helm’s current session-overlay UX:

- list historical sessions
- detect live/busy/idle sessions
- group by project/cwd
- resume or start sessions in the configured terminal
- classify idle sessions as “needs input” vs “needs review”
- kill/focus terminal panes when possible

## Key differences between Claude Code and pi

Claude Code currently gives Helm two useful data sources:

- live registry: `~/.claude/sessions/<pid>.json`
- history: `~/.claude/projects/*/<sessionId>.jsonl`

Pi gives:

- history: `~/.pi/agent/sessions/--encoded-cwd--/<timestamp>_<uuid>.jsonl`
- no built-in live registry intended for Helm today

So pi support should be split into:

1. passive history parsing
2. terminal launch/resume
3. optional pi extension that writes live status for Helm

## Phase 1: Abstract agent backends

`SessionStore` is currently Claude-specific. Introduce a provider/backend layer so Claude and pi can share the same UI model.

Possible shape:

```swift
public enum AgentKind: String {
    case claude
    case pi
}

public protocol AgentSessionBackend {
    var kind: AgentKind { get }
    func readLive() -> [LiveRecord]
    func readHistory() -> [HistoryRecord]
    func locateTranscript(_ sessionId: String) -> URL?
    func readIdleReason(sessionId: String) -> IdleReason?
}
```

Then:

- move Claude-specific filesystem logic into `ClaudeSessionBackend`
- add `PiSessionBackend`
- make `SessionStore` merge across enabled backends

`ChatSession` should gain:

```swift
public let agent: AgentKind
public let transcriptPath: String?
```

Session IDs may collide across tools, so row identity should become something like:

```swift
agent.rawValue + ":" + sessionId
```

## Phase 2: Add config for enabled/default agents

Extend `~/.config/helm/config.json` with agent settings:

```json
{
  "terminal": "terminal",
  "enabledAgents": ["claude", "pi"],
  "defaultAgent": "pi"
}
```

Behavior:

- `enabledAgents` controls which backends Helm reads from.
- `defaultAgent` controls what `Cmd+N` / new-chat actions launch.
- If missing, preserve existing behavior by enabling Claude and defaulting to Claude.
- If only one agent kind is enabled, the UI should not show a provider marker on rows.
- If multiple agent kinds are enabled, show a small provider marker/badge so rows are distinguishable.

## Phase 3: Parse pi history

Read pi session files from:

```text
~/.pi/agent/sessions/**/*.jsonl
```

Per pi’s session format:

- first line is a session header:
  - `type: "session"`
  - `id`
  - `cwd`
  - `timestamp`
- session name may appear later:
  - `type: "session_info"`
  - `name`
- messages contain timestamps and assistant/user content

For each pi JSONL file:

- `sessionId` = header `id`
- `cwd` = header `cwd`
- `lastActive` = file mtime
- label priority:
  1. latest `session_info.name`
  2. first user text
  3. cwd basename
  4. session id
- branch can initially be nil, or inferred from cwd only if cheap
- entrypoint filtering is probably unnecessary for pi initially

Keep Helm’s current performance model:

- stat all files
- cache parsed heads by path + mtime
- avoid full reads except bounded tail classification

## Phase 4: Launch/resume pi from Helm

Update terminal dispatch to branch by `ChatSession.agent`.

Claude remains:

```sh
claude --resume <sessionId>
claude
```

Pi should use:

```sh
pi --session <transcriptPath>
pi
```

Prefer passing the transcript path over the UUID because pi accepts paths and this avoids partial-ID ambiguity.

Resume command:

```sh
cd <cwd> && pi --session <path>
```

New chat command:

```sh
cd <cwd> && pi
```

## Phase 5: Passive pi MVP

Ship a first useful slice without live pi tracking:

- pi historical sessions visible in Helm
- pi sessions grouped by project/cwd
- search works
- Enter resumes pi session
- `Cmd+N` starts a pi session if `defaultAgent` is `pi`

At this stage, pi rows can all be `.cold`.

## Phase 6: Add live pi support via a pi extension

Because pi supports extensions and lifecycle events, create a tiny global extension that writes Helm-compatible live state.

Place the live registry as a sibling concept to Claude’s live sessions, under pi’s home area:

```text
~/.pi/sessions/<pid>.json
```

Example payload:

```json
{
  "pid": 12345,
  "sessionId": "019e...",
  "sessionFile": "/Users/.../.pi/agent/sessions/...jsonl",
  "cwd": "/Users/eshaan/Home/dev/helm",
  "status": "idle",
  "name": "Refactor Helm",
  "entrypoint": "cli"
}
```

The pi extension can live at:

```text
~/.pi/agent/extensions/helm-live.ts
```

Use pi events:

- `session_start`: write live record, status `idle`
- `agent_start`: update status to `busy`
- `agent_end`: update status to `idle` and write idle classification
- `session_shutdown`: delete live record
- optional heartbeat: refresh mtime periodically so Helm can detect stale records defensively

Then `PiSessionBackend.readLive()` can read `~/.pi/sessions/<pid>.json` and use PID liveness like the Claude backend.

## Phase 7: Idle classification for pi

Pi transcript format differs from Claude’s.

Claude classifier currently looks for:

- assistant `tool_use` without `tool_result`
- final assistant text ending in `?`

Pi format has:

- assistant content block type: `toolCall`
- tool results as separate messages with role `toolResult`
- assistant `stopReason`: `"toolUse" | "stop" | "length" | "error" | "aborted"`

Implement a pi-specific bounded-tail classifier:

1. last assistant has unresolved `toolCall.id` with no later `toolResult.toolCallId` → `needsInput`
2. final assistant text line ends in `?` → `needsInput`
3. otherwise → `needsReview`

The pi extension can also write an authoritative state file, parallel to Helm’s existing Claude-derived state mechanism:

```text
~/.helm/pi/state/<sessionId>.json
```

Use the same wire format:

```json
{ "reason": "needs_input" }
```

or:

```json
{ "reason": "done" }
```

## Phase 8: UI behavior

Grouping should stay cwd/project-based, not agent-based.

Attention sorting should remain global:

1. needs input
2. needs review
3. busy
4. cold

regardless of agent.

Provider marker rules:

- If multiple agent kinds are enabled, show a small `Claude` / `Pi` marker or icon on rows.
- If only a single agent kind is enabled, omit the provider marker entirely to reduce visual noise.

Search should include the agent name only when multiple agents are enabled, so typing `pi` or `claude` can filter mixed rows.

## Phase 9: Tests

Add or update `HelmCoreTests` for:

- pi session header parsing
- pi session name parsing
- pi cwd-to-project grouping
- pi tail idle classification
- mixed Claude + pi merge
- duplicate session IDs across agents
- config parsing for `enabledAgents` and `defaultAgent`
- provider marker visibility logic when one vs multiple agents are enabled
- terminal command generation if terminal dispatch is factored/testable

## Suggested implementation order

1. [x] Add `AgentKind` to models.
2. [x] Add config parsing for `enabledAgents` and `defaultAgent` while preserving Claude-only defaults.
3. [~] Refactor current Claude logic behind a backend without changing behavior. (Provider identity is now on rows/records; a full backend protocol split is still pending.)
4. [x] Add pi history parser.
5. [x] Add terminal dispatch for pi.
6. [x] Ship passive pi MVP.
7. [ ] Add pi extension for `~/.pi/sessions/<pid>.json` live registry.
8. [ ] Add pi live reader.
9. [ ] Add pi idle classification/state files.
10. [ ] Polish row provider markers and mixed-agent search.

The main architectural move is separating “session source” from “session UI model.” Once that exists, pi becomes another backend instead of a fork of the app.
