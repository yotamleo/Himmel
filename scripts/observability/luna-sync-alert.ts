// scripts/observability/luna-sync-alert.ts
// HIMMEL-1199 — a SEPARATE scheduled checker (NOT part of flow-exporter.ts,
// which must stay a pure Prometheus reader). Root cause: the luna vault's
// auto-sync PUSH was silently blocked by a gitleaks false positive, so
// auto-committed commits piled up unpushed (9 deep) with zero visible signal.
// flow-exporter.ts's `luna_git_unpushed_commits`/`luna_git_uncommitted_files`
// gauges are the passive DETECTION signal; this script is the ACTIVE
// notification on top of it — invoked on a schedule (see install-stack.ps1),
// never a hook, never in the exporter's request path.
//
// Reuses the exact same git-reading function the exporter uses
// (runGitDivergence, imported from ./flow-exporter) so the two never drift on
// what "unpushed"/"uncommitted" mean. NEVER runs `git fetch` — same passivity
// invariant as the exporter.
//
// Debounce: a tiny state file (~/.himmel/luna-sync-alert-state.json) tracks
// the last-alerted timestamp. Alerts on the RISING EDGE (clean -> >0,
// immediate) and re-alerts if the condition persists past a cooldown
// (default 6h) rather than every ~5-10min poll. The state resets the moment
// the tree reads clean again, so the next divergence is a fresh rising edge.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { runGitDivergence, configPath, readConfig, type GitRunner, type GitDivergenceResult } from "./flow-exporter";
import { sendMessage } from "../telegram/telegram-api";
import { loadAccess, defaultAccessPath } from "../telegram/gate";

// Re-alert cadence while the tree stays dirty: long enough that a 5-10min cron
// doesn't spam the operator every cycle, short enough that a stuck push isn't
// forgotten for days.
export const DEFAULT_COOLDOWN_MS = 6 * 60 * 60 * 1000;

export type AlertState = { lastAlertedAt: string | null };

export function statePath(env: Record<string, string | undefined> = process.env): string {
  const override = env.HIMMEL_LUNA_SYNC_ALERT_STATE;
  if (override && override.trim()) return override;
  const home = env.HOME ?? homedir();
  return join(home, ".himmel", "luna-sync-alert-state.json");
}

export function readState(path: string): AlertState {
  if (!existsSync(path)) return { lastAlertedAt: null };
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    return { lastAlertedAt: typeof parsed?.lastAlertedAt === "string" ? parsed.lastAlertedAt : null };
  } catch {
    return { lastAlertedAt: null };
  }
}

export function writeState(path: string, state: AlertState): void {
  const dir = dirname(path);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  writeFileSync(path, JSON.stringify(state), "utf8");
}

export function buildAlertText(unpushed: number, uncommittedFiles: number, vaultPath: string): string {
  const parts: string[] = [];
  if (unpushed > 0) parts.push(`${unpushed} unpushed commit${unpushed === 1 ? "" : "s"}`);
  if (uncommittedFiles > 0) parts.push(`${uncommittedFiles} uncommitted file${uncommittedFiles === 1 ? "" : "s"}`);
  return `⚠️ luna vault sync: ${parts.join(" and ")} in ${vaultPath} — check for a blocked auto-sync (e.g. a gitleaks false positive holding a commit or push back).`;
}

export type CheckOutcome = "sent" | "clean" | "cooldown" | "skip-no-vault" | "skip-error" | "undelivered";

// Core check. Every side effect (git read, alert send, logging) is injected —
// no fs/network/state-file access here — so this is unit-testable with plain
// values. Never throws; the caller decides how to log/exit.
export async function checkLunaSync(opts: {
  vaultPath: string | undefined;
  nowMs: number;
  gitRunner: GitRunner;
  state: AlertState;
  cooldownMs?: number;
  sendAlert: (text: string) => Promise<boolean>;
  log?: (msg: string) => void;
}): Promise<{ outcome: CheckOutcome; state: AlertState }> {
  const log = opts.log ?? ((m: string) => console.error(m));
  if (!opts.vaultPath) return { outcome: "skip-no-vault", state: opts.state };

  let result: GitDivergenceResult;
  try {
    result = await opts.gitRunner(opts.vaultPath);
  } catch (e) {
    log(`luna-sync-alert: git query failed (${e instanceof Error ? e.message : String(e)}) — skipping`);
    return { outcome: "skip-error", state: opts.state };
  }

  const unpushed = result.unpushed;
  const uncommitted = result.uncommittedFiles;

  if (unpushed === null && uncommitted === 0) {
    // No upstream configured (unpushed unknown) AND nothing uncommitted — no
    // divergence to report and nothing to compare, out of scope for this
    // checker. NOT a genuinely-clean tree, so PRESERVE any in-progress alert
    // state: resetting here would wipe the cooldown/rising-edge on a reading
    // that says nothing about whether changes are piling up (HIMMEL-1199 —
    // only a genuinely-clean tree resets).
    return { outcome: "clean", state: opts.state };
  }

  // A null unpushed (no upstream) contributes nothing to the count but must NOT
  // mask uncommitted files — either dimension diverging is the blocked-git-op
  // silent failure this checker exists to surface (HIMMEL-1199 CR: the alert
  // and metric both cover uncommitted files, so the trigger must too).
  const unpushedCount = unpushed ?? 0;
  if (unpushedCount <= 0 && uncommitted <= 0) {
    // Genuinely clean — reset so the NEXT divergence reads as a fresh rising
    // edge instead of staying inside a stale cooldown window.
    return { outcome: "clean", state: { lastAlertedAt: null } };
  }

  const cooldownMs = opts.cooldownMs ?? DEFAULT_COOLDOWN_MS;
  if (opts.state.lastAlertedAt !== null && opts.nowMs - Date.parse(opts.state.lastAlertedAt) < cooldownMs) {
    return { outcome: "cooldown", state: opts.state };
  }

  // Advance the cooldown/rising-edge state ONLY when the alert was actually
  // delivered. sendAlert resolves false when there is no chat_id or Telegram
  // dropped the message; persisting lastAlertedAt then would suppress retries
  // for the whole cooldown window with no operator ever notified — recreating
  // the exact silent failure this checker fights (HIMMEL-1199 CR: codex-adv +
  // coderabbit).
  const delivered = await opts.sendAlert(buildAlertText(unpushedCount, uncommitted, opts.vaultPath));
  if (!delivered) {
    log("luna-sync-alert: alert not delivered (no chat_id or Telegram send failed) — state unchanged, will retry next poll");
    return { outcome: "undelivered", state: opts.state };
  }
  return { outcome: "sent", state: { lastAlertedAt: new Date(opts.nowMs).toISOString() } };
}

// ── real I/O (main-only; never exercised by tests) ──────────────────────────

// Bot token: same source + override the bridge itself reads from
// (poller.ts's loadToken) — ~/.claude/channels/telegram/.env's
// TELEGRAM_BOT_TOKEN, overridable via TELEGRAM_ENV.
function loadToken(env: Record<string, string | undefined>): string {
  const envPath = env.TELEGRAM_ENV ?? join(homedir(), ".claude", "channels", "telegram", ".env");
  const txt = readFileSync(envPath, "utf8");
  const m = txt.match(/^TELEGRAM_BOT_TOKEN\s*=\s*(.+)$/m);
  if (!m) throw new Error("TELEGRAM_BOT_TOKEN not found in " + envPath);
  return m[1].trim();
}

// chat_id: this script has no live session/meta to read a chat_id from (unlike
// the bridge's per-session notify()), so it reuses the SAME allowlist the
// bridge gates inbound messages on (gate.ts access.json): allowFrom holds the
// operator's own Telegram user id(s), and a private-chat chat_id equals the
// user id, so the first allowFrom entry is the operator's DM. Override via
// LUNA_SYNC_ALERT_CHAT_ID for an explicit id.
async function resolveChatId(env: Record<string, string | undefined>): Promise<number | null> {
  const override = env.LUNA_SYNC_ALERT_CHAT_ID;
  if (override && /^-?\d+$/.test(override.trim())) return Number(override.trim());
  const access = await loadAccess(env.TELEGRAM_ACCESS_PATH ?? defaultAccessPath());
  const first = access.allowFrom?.[0];
  return first !== undefined ? Number(first) : null;
}

async function main(): Promise<void> {
  const env = process.env;
  const nowMs = Date.now();
  const cfg = readConfig(configPath(env));
  const sPath = statePath(env);
  const state = readState(sPath);
  const chatId = await resolveChatId(env);

  const result = await checkLunaSync({
    vaultPath: cfg.vault_path,
    nowMs,
    gitRunner: runGitDivergence,
    state,
    sendAlert: async (text) => {
      if (chatId === null) {
        console.error(`luna-sync-alert: no Telegram chat_id configured (access.json allowFrom empty and LUNA_SYNC_ALERT_CHAT_ID unset) — would have sent: ${text}`);
        return false;
      }
      return await sendMessage(loadToken(env), chatId, text);
    },
  });

  if (result.state.lastAlertedAt !== state.lastAlertedAt) writeState(sPath, result.state);
  // rc 0 always — best-effort scheduled checker, never fails the task.
}

if (import.meta.main) {
  main().catch((e) => { console.error(`luna-sync-alert: fatal: ${e instanceof Error ? e.message : String(e)}`); });
}
