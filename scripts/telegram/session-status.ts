// scripts/telegram/session-status.ts — HIMMEL-1250 Increment 1: outbound
// Telegram session status.
//
// Composes a CONCISE status message for two Claude Code hook events —
// SessionEnd ("this session concluded") and Notification (permission prompt /
// idle-wait / AskUserQuestion) — and relays it to the operator's Telegram
// GROUP via the existing sendMessage() HTTP client
// (scripts/telegram/telegram-api.ts). Never reinvents the HTTP client; never
// reads/logs the raw bot token anywhere except handing it to sendMessage.
//
// Why SessionEnd, not Stop: Stop fires per assistant turn (repeatedly, can
// block session flow via exit code 2) — SessionEnd fires exactly once per
// session, is fire-and-forget, and matches this repo's existing "notify
// operator at session end" convention (end-session-wiki.sh /
// jira-nudge-on-end.sh / refresh-where-are-we-on-end.sh, all wired via the
// himmel-ops plugin hooks.json SessionEnd array).
//
// Salus/PHI guard: a repo whose name matches /salus/i (the operator's
// medical vault/repo — see docs/internals memory: "salus = medical vault")
// NEVER has session content (last-assistant text, notification message)
// included in the composed status — only a generic, content-free line. The
// calling bash hooks additionally short-circuit BEFORE extracting any
// transcript content for a salus repo, so this check is defense-in-depth,
// not the only guard.
//
// Silent no-op: when no group chat id is configured (TELEGRAM_GROUP_CHAT_ID
// unset/blank/non-numeric), runSessionEndStatus/runNotificationStatus return
// "skip-no-chat" WITHOUT calling sendAlert — the hook's silent-no-op
// contract (never error, never block, never send).
//
// Pattern mirrors scripts/observability/luna-sync-alert.ts: pure, injectable
// core functions (unit-testable, no network/env/fs access) + a thin main()
// that does the real I/O — never exercised by tests.

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { sendMessage, redactChatId } from "./telegram-api";

export function isSalusRepo(repoName: string | undefined): boolean {
  return /salus/i.test(repoName ?? "");
}

export function truncate(s: string | undefined, max: number): string {
  const t = (s ?? "").trim();
  if (t.length <= max) return t;
  return t.slice(0, max - 1).trimEnd() + "…";
}

const SUMMARY_MAX = 400;

export function composeSessionEndStatus(input: {
  repoName: string;
  branch?: string;
  reason?: string;
  lastAssistant?: string;
  mergepubLine?: string;
}): string {
  const { repoName, branch, reason } = input;
  if (isSalusRepo(repoName)) {
    return `🏁 ${repoName} session ended — content redacted (salus/medical vault)`;
  }
  const lines = [`🏁 ${repoName}${branch ? ` (${branch})` : ""} session ended${reason && reason !== "other" ? ` — ${reason}` : ""}`];
  const summary = truncate(input.lastAssistant, SUMMARY_MAX);
  if (summary) lines.push(summary);
  const mergepub = truncate(input.mergepubLine, 200);
  if (mergepub) lines.push(mergepub);
  return lines.join("\n");
}

export function composeNotificationStatus(input: {
  repoName: string;
  notificationType?: string;
  message?: string;
}): string {
  const { repoName, notificationType } = input;
  if (isSalusRepo(repoName)) {
    return `🔔 ${repoName}: ${notificationType || "notification"} — content redacted (salus/medical vault)`;
  }
  const msg = truncate(input.message, SUMMARY_MAX);
  return `🔔 ${repoName}: ${notificationType || "notification"}${msg ? ` — ${msg}` : ""}`;
}

export type SendFn = (text: string) => Promise<boolean>;
export type StatusOutcome = "sent" | "skip-no-chat" | "undelivered";

export async function runSessionEndStatus(opts: {
  chatId: number | null;
  repoName: string;
  branch?: string;
  reason?: string;
  lastAssistant?: string;
  mergepubLine?: string;
  sendAlert: SendFn;
  log?: (msg: string) => void;
}): Promise<StatusOutcome> {
  const log = opts.log ?? ((m: string) => console.error(m));
  if (opts.chatId === null) {
    log("telegram-session-status: no TELEGRAM_GROUP_CHAT_ID configured — silent no-op");
    return "skip-no-chat";
  }
  const text = composeSessionEndStatus(opts);
  const delivered = await opts.sendAlert(text);
  return delivered ? "sent" : "undelivered";
}

export async function runNotificationStatus(opts: {
  chatId: number | null;
  repoName: string;
  notificationType?: string;
  message?: string;
  sendAlert: SendFn;
  log?: (msg: string) => void;
}): Promise<StatusOutcome> {
  const log = opts.log ?? ((m: string) => console.error(m));
  if (opts.chatId === null) {
    log("telegram-session-status: no TELEGRAM_GROUP_CHAT_ID configured — silent no-op");
    return "skip-no-chat";
  }
  const text = composeNotificationStatus(opts);
  const delivered = await opts.sendAlert(text);
  return delivered ? "sent" : "undelivered";
}

// ── real I/O (main-only; never exercised by tests) ──────────────────────────

// Bot token: SAME resolution the bridge/poller and luna-sync-alert.ts use —
// ~/.claude/channels/telegram/.env's TELEGRAM_BOT_TOKEN, overridable via
// TELEGRAM_ENV. Never logged — only handed to sendMessage's request body.
function loadToken(env: Record<string, string | undefined>): string {
  const envPath = env.TELEGRAM_ENV ?? join(homedir(), ".claude", "channels", "telegram", ".env");
  const txt = readFileSync(envPath, "utf8");
  const m = txt.match(/^TELEGRAM_BOT_TOKEN\s*=\s*(.+)$/m);
  if (!m) throw new Error("TELEGRAM_BOT_TOKEN not found in " + envPath);
  return m[1].trim();
}

function resolveChatId(env: Record<string, string | undefined>): number | null {
  const raw = (env.TELEGRAM_GROUP_CHAT_ID ?? "").trim();
  if (!raw || !/^-?\d+$/.test(raw)) return null;
  return Number(raw);
}

async function main(): Promise<void> {
  const env = process.env;
  const eventType = process.argv[2]; // "sessionend" | "notification"
  const chatId = resolveChatId(env);
  const repoName = env.TG_REPO_NAME || "unknown-repo";

  const sendAlert: SendFn = async (text) => {
    if (chatId === null) return false;
    const token = loadToken(env);
    return sendMessage(token, chatId, text);
  };

  const result =
    eventType === "notification"
      ? await runNotificationStatus({
          chatId,
          repoName,
          notificationType: env.TG_NOTIFICATION_TYPE,
          message: env.TG_MESSAGE,
          sendAlert,
        })
      : await runSessionEndStatus({
          chatId,
          repoName,
          branch: env.TG_BRANCH,
          reason: env.TG_REASON,
          lastAssistant: env.TG_LAST_ASSISTANT,
          mergepubLine: env.TG_MERGEPUB_LINE,
          sendAlert,
        });

  if (result === "undelivered") {
    console.error(`telegram-session-status: ${eventType || "sessionend"} status not delivered (chat=${chatId !== null ? redactChatId(chatId) : "none"})`);
  }
}

if (import.meta.main) {
  main().catch((e) => { console.error(`telegram-session-status: fatal: ${e instanceof Error ? e.message : String(e)}`); });
}
