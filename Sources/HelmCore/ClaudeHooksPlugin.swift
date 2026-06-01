import Foundation

/// Generates and installs the **`helm` Claude Code plugin** — the set of hooks that keep
/// `~/.helm/state/<sessionId>.json` current so the overlay knows which sessions want you.
///
/// Since Claude Code 2.1.157, a plugin dropped in `~/.claude/skills/<name>/` auto-loads
/// next session with no marketplace — so `helm init claude` just writes the plugin there.
/// The plugin owns the whole lifecycle (replacing the hand-rolled hooks people used to
/// paste into `settings.json`):
///
/// - **SessionStart / UserPromptSubmit** → `running` (alive and working; also clears a
///   stale verdict left by the previous turn). The first step of moving liveness off the
///   per-backend live registry (`~/.claude/sessions`) and onto hook state.
/// - **PreToolUse(AskUserQuestion)** → `needs_input` (paused on a question mid-turn — the
///   case the busy registry status would otherwise mask).
/// - **PostToolUse(AskUserQuestion)** → `running` (answered; back to work).
/// - **Stop** → a Haiku agent classifies the tail and writes `needs_input` / `done`.
/// - **SessionEnd** → clears the file.
///
/// The wire format is unchanged (`{"reason","sessionId","ts"}`); `done` maps to
/// `needsReview` (see `SessionStore.idleReason(fromState:)`).
public enum ClaudeHooksPlugin {
    public static let pluginName = "helm"

    /// One file the installer must write, relative to the plugin root.
    public struct File {
        public let relativePath: String
        public let contents: String
        public let isExecutable: Bool
    }

    /// Where the plugin auto-loads from (`~/.claude/skills/helm`).
    public static func pluginDir(home: String) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent(".claude/skills")
            .appendingPathComponent(pluginName)
    }

    /// The complete plugin payload, with the session-state directory baked into the Stop
    /// agent's prompt (an LLM prompt can't expand `$HOME`, so we resolve it at install time;
    /// the bash handlers use `$HOME` directly and stay portable).
    public static func files(home: String, author: (name: String, email: String)?) -> [File] {
        [
            File(relativePath: ".claude-plugin/plugin.json",
                 contents: pluginManifest(author: author), isExecutable: false),
            File(relativePath: "hooks/hooks.json",
                 contents: hooksJSON(stateDir: SessionStore.stateDir(home: home).path), isExecutable: false),
            File(relativePath: "hooks-handlers/set-state.sh",
                 contents: setStateScript, isExecutable: true),
            File(relativePath: "hooks-handlers/clear-state.sh",
                 contents: clearStateScript, isExecutable: true),
        ]
    }

    // MARK: Payload pieces

    static func pluginManifest(author: (name: String, email: String)?) -> String {
        var obj: [String: Any] = [
            "$schema": "https://anthropic.com/claude-code/plugin.schema.json",
            "name": pluginName,
            "version": "0.1.0",
            "description": "Helm session-state hooks — write attention/run state to ~/.helm/state for the Helm overlay.",
        ]
        if let author {
            obj["author"] = ["name": author.name, "email": author.email]
        }
        return prettyJSON(obj)
    }

    /// Build `hooks/hooks.json`. Command hooks invoke the bash handlers via
    /// `${CLAUDE_PLUGIN_ROOT}` (set by Claude Code to the plugin dir).
    static func hooksJSON(stateDir: String) -> String {
        func cmd(_ reason: String) -> [String: Any] {
            ["type": "command",
             "command": #"bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/set-state.sh" \#(reason)"#]
        }
        let clear: [String: Any] = [
            "type": "command",
            "command": #"bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/clear-state.sh""#,
        ]
        var promptSubmit = cmd("running"); promptSubmit["async"] = true

        let obj: [String: Any] = [
            "hooks": [
                "SessionStart":     [["hooks": [cmd("running")]]],
                "UserPromptSubmit": [["hooks": [promptSubmit]]],
                "PreToolUse":       [["matcher": "AskUserQuestion", "hooks": [cmd("needs_input")]]],
                "PostToolUse":      [["matcher": "AskUserQuestion", "hooks": [cmd("running")]]],
                "Stop":             [["hooks": [stopAgentHook(stateDir: stateDir)]]],
                "SessionEnd":       [["hooks": [clear]]],
            ],
        ]
        return prettyJSON(obj)
    }

    /// The Stop hook: a fast Haiku agent reads the transcript tail, decides whether the
    /// human still needs to come back, and writes the verdict to `<stateDir>/<id>.json`.
    static func stopAgentHook(stateDir: String) -> [String: Any] {
        [
            "type": "agent",
            "model": "claude-haiku-4-5-20251001",
            "timeout": 30,
            "statusMessage": "classifying session state",
            "prompt": stopPrompt(stateDir: stateDir),
        ]
    }

    static func stopPrompt(stateDir: String) -> String {
        """
        You are a fast, silent session-attention classifier. Input JSON: $ARGUMENTS.

        Goal: decide whether the human needs to come back to this session. Mark `done` ONLY when the human's most recent overarching ask has been fully addressed AND the final assistant message does not pose a question to the human. Otherwise mark `needs_input`. Reasons to mark `needs_input` include: a direct question; a request for approval/clarification/choice; OR the assistant stopped before completing the active ask (partial work, blocked, awaiting an external signal, deferred a step, announced an intent without executing it).

        Steps — do them in order, output nothing until the final step:

        (1) Parse the input. Extract `session_id` and `transcript_path`. Use the Read tool to read the LAST 400 lines of `transcript_path`.

        (2) Identify the ACTIVE ASK: scan from the end backwards for the most recent record with `message.role == "user"` whose content is a real instruction — NOT a tool_result, NOT a pure system-reminder payload, NOT a one-word ack ("thanks", "ok", "cool"). If the user has been iterating, treat the cumulative thread as the active ask, anchored on the latest substantive turn.

        (3) Identify the FINAL ASSISTANT MESSAGE: the last record with `message.role == "assistant"` that has user-visible text (skip pure tool_use turns). Note (a) the last 1-2 sentences and (b) whether the final sentence ends with `?`.

        (4) Decide. When in tension, prefer `needs_input`.
          - `needs_input` if: the final sentence is a question to the user; OR the final paragraph asks them to choose/confirm/approve/answer; OR the active ask has visible remaining work the assistant did not do.
          - `done` if: the active ask is fulfilled (or the question is fully answered) AND the final message is a statement / summary / handoff — even if it ends with a soft courtesy like "let me know if you want X next". Courtesies are not asks.

        (5) Run Bash: `mkdir -p \(stateDir)`.

        (6) Use the Write tool to create `\(stateDir)/<session_id>.json` containing exactly: {"reason":"<label>","sessionId":"<session_id>","ts":<unix_epoch_seconds>} where `<label>` is literally `needs_input` or `done`.

        (7) Stop. Do not edit code, do not run other commands, do not output prose.
        """
    }

    static let setStateScript = """
    #!/usr/bin/env bash
    # Helm hook: record this session's run/attention state for the overlay.
    # Usage: set-state.sh <reason>   (running | needs_input | done)
    set -euo pipefail
    reason="${1:-running}"
    event="$(cat)"
    sid="$(printf '%s' "$event" | jq -r '.session_id // empty')"
    [ -n "$sid" ] || exit 0
    dir="$HOME/.helm/state"
    mkdir -p "$dir"
    printf '{"reason":"%s","sessionId":"%s","ts":%s}\\n' "$reason" "$sid" "$(date +%s)" > "$dir/$sid.json"

    """

    static let clearStateScript = """
    #!/usr/bin/env bash
    # Helm hook: drop this session's attention state (the session ended).
    set -euo pipefail
    event="$(cat)"
    sid="$(printf '%s' "$event" | jq -r '.session_id // empty')"
    [ -n "$sid" ] || exit 0
    rm -f "$HOME/.helm/state/$sid.json"

    """

    private static func prettyJSON(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str + "\n"
    }
}
