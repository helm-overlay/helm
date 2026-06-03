import Foundation

public enum PiExtensionInstaller {
    public struct Report {
        public let extensionPath: String
        public let stateDir: String
    }

    @discardableResult
    public static func install(home: String = NSHomeDirectory()) throws -> Report {
        let fm = FileManager.default
        let ext = URL(fileURLWithPath: home).appendingPathComponent(".pi/agent/extensions/helm.ts")
        try fm.createDirectory(at: ext.deletingLastPathComponent(), withIntermediateDirectories: true)
        try extensionSource.write(to: ext, atomically: true, encoding: .utf8)
        let stateDir = PiSessionBackend.stateDir(home: home)
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        return Report(extensionPath: ext.path, stateDir: stateDir.path)
    }

    static let extensionSource = #"""
import { complete, type UserMessage } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const home = homedir();
const stateDir = join(home, ".helm", "pi", "state");

const TITLE_SYSTEM_PROMPT = `You write concise chat titles for coding-agent sessions.

Goal: create a short, specific title for this Pi chat, similar to Claude's ai-title.

You are given JSON with:
- user_ask: the user's prompt that started the work
- cwd: current working directory

Write a title in Title Case, 3-7 words, no quotes, no trailing period.
Prefer a specific title that captures the user's intent instead of merely copying the prompt.
Do not mention Pi unless the ask is about Pi itself.
Output only the title.`;

const CLASSIFIER_SYSTEM_PROMPT = `You are a fast, silent session-attention classifier.

Goal: decide whether the human needs to come back to this session. Output exactly one token: needs_input or done.

You are given JSON with:
- session_id
- transcript_path
- final_assistant_message

Use transcript_path as a reference to the full conversation location, but classify primarily from the final assistant message.

Mark done ONLY when the human's most recent overarching ask appears fully addressed AND the final assistant message does not pose a real question to the human.

Mark needs_input if the final assistant message asks a direct question, requests approval/clarification/choice, says work is blocked/partial/deferred, or announces an intent without doing it.

Soft courtesies like "let me know if you want X next" are done when the ask appears answered.

When in doubt, prefer needs_input.`;

let lastNameOverride: string | undefined;

function ensureDir(path: string) {
  mkdirSync(path, { recursive: true });
}

function sessionIdFromFile(file: string | undefined): string | undefined {
  if (!file) return undefined;
  const base = file.split("/").pop()?.replace(/\.jsonl$/, "");
  const match = base?.match(/^[^_]+_(.+)$/);
  return match?.[1] || base;
}

function getSessionInfo(ctx: any) {
  const sessionFile = ctx.sessionManager?.getSessionFile?.();
  const header = ctx.sessionManager?.getHeader?.();
  return {
    sessionId: header?.id || ctx.sessionManager?.getSessionId?.() || sessionIdFromFile(sessionFile),
    sessionFile,
    cwd: ctx.cwd || ctx.sessionManager?.getCwd?.() || header?.cwd,
    name: ctx.sessionManager?.getSessionName?.() || undefined,
  };
}

type StateReason = "running" | "needs_input" | "done";

function writeState(ctx: any, reason: StateReason, nameOverride?: string) {
  const info = getSessionInfo(ctx);
  if (!info.sessionId) return;
  ensureDir(stateDir);
  writeFileSync(join(stateDir, `${info.sessionId}.json`), JSON.stringify({
    reason,
    sessionId: info.sessionId,
    sessionFile: info.sessionFile,
    cwd: info.cwd,
    status: reason === "running" ? "busy" : "idle",
    pid: process.pid,
    name: nameOverride || info.name,
    entrypoint: "cli",
    ts: Math.floor(Date.now() / 1000),
  }, null, 2));
}

type IdleReason = "needs_input" | "done";

function textFromContent(content: any): string | undefined {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return undefined;
  return content
    .filter((b) => b?.type === "text" && typeof b.text === "string")
    .map((b) => b.text)
    .join("\n") || undefined;
}

function lastAssistantTextFromMessages(messages: any[] | undefined): string | undefined {
  if (!Array.isArray(messages)) return undefined;
  for (let i = messages.length - 1; i >= 0; i--) {
    const msg = messages[i];
    if (msg?.role !== "assistant") continue;
    const text = textFromContent(msg.content)?.trim();
    if (text) return text;
  }
  return undefined;
}

function sanitizeTitle(title: string, fallback: string): string {
  const cleaned = title
    .split(/\r?\n/)[0]
    .replace(/^title\s*:\s*/i, "")
    .replace(/["'`]/g, "")
    .replace(/[.!?]+$/g, "")
    .replace(/\s+/g, " ")
    .trim();
  if (!cleaned) return fallback;
  return cleaned.length > 80 ? `${cleaned.slice(0, 77).trim()}...` : cleaned;
}

function fallbackTitle(prompt: string): string {
  const firstLine = prompt.split(/\r?\n/).map((s) => s.trim()).find(Boolean) || "New Chat";
  return sanitizeTitle(firstLine, "New Chat");
}

async function generateTitle(ctx: any, prompt: string): Promise<string> {
  const model = ctx.modelRegistry?.find?.("openai-codex", "gpt-5.4-mini") || ctx.model;
  if (!model) return fallbackTitle(prompt);

  const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model);
  if (!auth.ok || !auth.apiKey) return fallbackTitle(prompt);

  const info = getSessionInfo(ctx);
  const userMessage: UserMessage = {
    role: "user",
    content: [{
      type: "text",
      text: JSON.stringify({
        user_ask: prompt,
        cwd: info.cwd,
      }),
    }],
    timestamp: Date.now(),
  };

  const response = await complete(
    model,
    { systemPrompt: TITLE_SYSTEM_PROMPT, messages: [userMessage] },
    { apiKey: auth.apiKey, headers: auth.headers, signal: AbortSignal.timeout(30_000) },
  );
  const output = response.content
    .filter((c): c is { type: "text"; text: string } => c.type === "text")
    .map((c) => c.text)
    .join("\n");
  return sanitizeTitle(output, fallbackTitle(prompt));
}

function heuristicClassify(finalAssistantMessage: string | undefined): IdleReason {
  if (!finalAssistantMessage) return "done";
  const text = finalAssistantMessage.trim();
  const lastLine = text.split(/\r?\n/).map((s) => s.trim()).filter(Boolean).pop() || "";
  if (lastLine.endsWith("?")) return "needs_input";
  if (/\b(should i|do you want|would you like|which|confirm|approve|approval|clarify|blocked|stuck|waiting|i'll .* next|i will .* next)\b/i.test(text)) {
    return "needs_input";
  }
  return "done";
}

async function modelClassify(ctx: any, finalAssistantMessage: string | undefined): Promise<IdleReason> {
  const info = getSessionInfo(ctx);
  const model = ctx.modelRegistry?.find?.("openai-codex", "gpt-5.4-mini") || ctx.model;
  if (!model) return heuristicClassify(finalAssistantMessage);

  const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model);
  if (!auth.ok || !auth.apiKey) return heuristicClassify(finalAssistantMessage);

  const input = {
    session_id: info.sessionId,
    transcript_path: info.sessionFile,
    final_assistant_message: finalAssistantMessage || "",
  };
  const userMessage: UserMessage = {
    role: "user",
    content: [{ type: "text", text: JSON.stringify(input) }],
    timestamp: Date.now(),
  };

  const response = await complete(
    model,
    { systemPrompt: CLASSIFIER_SYSTEM_PROMPT, messages: [userMessage] },
    { apiKey: auth.apiKey, headers: auth.headers, signal: AbortSignal.timeout(30_000) },
  );
  const output = response.content
    .filter((c): c is { type: "text"; text: string } => c.type === "text")
    .map((c) => c.text)
    .join("\n")
    .trim()
    .toLowerCase();
  return output.includes("needs_input") ? "needs_input" : output.includes("done") ? "done" : heuristicClassify(finalAssistantMessage);
}

function writeIdleState(ctx: any, reason: IdleReason) {
  writeState(ctx, reason);
}

export default function helm(pi: ExtensionAPI) {
  pi.on("session_start", async (_event, ctx) => {
    writeState(ctx, ctx.isIdle?.() ? "done" : "running");
  });

  pi.on("before_agent_start", async (event, ctx) => {
    if (pi.getSessionName?.() || ctx.sessionManager?.getSessionName?.()) return;

    pi.setSessionName("New Chat");
    lastNameOverride = "New Chat";
    writeState(ctx, ctx.isIdle?.() ? "done" : "running", "New Chat");

    const prompt = (event as any).prompt || "";
    void generateTitle(ctx, prompt)
      .then((title) => {
        if (!title || title === "New Chat") return;
        pi.setSessionName(title);
        lastNameOverride = title;
        writeState(ctx, ctx.isIdle?.() ? "done" : "running", title);
      })
      .catch(() => {});
  });

  pi.on("agent_start", async (_event, ctx) => {
    writeState(ctx, "running", lastNameOverride);
  });

  pi.on("agent_end", async (event, ctx) => {
    const finalAssistantMessage = lastAssistantTextFromMessages((event as any).messages);
    let reason: IdleReason;
    try {
      reason = await modelClassify(ctx, finalAssistantMessage);
    } catch {
      reason = heuristicClassify(finalAssistantMessage);
    }
    writeIdleState(ctx, reason);
  });

  pi.on("session_shutdown", async () => {});
}

"""#
}
