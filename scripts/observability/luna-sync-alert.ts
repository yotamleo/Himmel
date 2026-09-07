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

// LUNA-131 Task 8: sweeperStatusPath mirrors statePath's override pattern.
// The file read stays OUT of checkLunaSync (its stated invariant is no fs/
// network) — main() reads + parses it and injects the value as an opt.
export function sweeperStatusPath(env: Record<string, string | undefined> = process.env): string {
  const override = env.HIMMEL_LUNA_SWEEPER_STATUS;
  if (override && override.trim()) return override;
  const home = env.HOME ?? homedir();
  return join(home, ".himmel", "luna-sync", "status.json");
}

// Missing/unparseable → null, which evaluateSweeperStatus treats as a RED
// "sweeper-dead" reading (the sweeper itself is not running).
export function readSweeperStatus(path: string): unknown {
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
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

export function buildAlertText(
  unpushed: number,
  uncommittedFiles: number,
  vaultPath: string | undefined,
  sweeperReason?: string | null,
  sweeperYellow?: boolean,
): string {
  const path = vaultPath ?? "(vault path unset)";
  const parts: string[] = [];
  if (unpushed > 0) parts.push(`${unpushed} unpushed commit${unpushed === 1 ? "" : "s"}`);
  if (uncommittedFiles > 0) parts.push(`${uncommittedFiles} uncommitted file${uncommittedFiles === 1 ? "" : "s"}`);

  // The git clause (counts + "in <path>") is omitted ENTIRELY when both
  // counts are 0 — joining an empty `parts` used to emit a malformed
  // "⚠️ luna vault sync:  in <path> — …" (double space, no content). A RED
  // sweeper reading on an otherwise-clean tree (LUNA-131 Task 8's swallow
  // regression) is exactly this case, so it must not resurrect the bug.
  const clauses: string[] = [];
  if (parts.length > 0) clauses.push(parts.join(" and "));
  if (sweeperReason) clauses.push(`sweeper: ${sweeperReason}`);

  let text = `⚠️ luna vault sync: ${clauses.join(" and ")} in ${path} — check for a blocked auto-sync (e.g. a gitleaks false positive holding a commit or push back).`;
  // The YELLOW note is only ever appended alongside an alert that is already
  // firing (this function is only called from the send path) — a yellow
  // sweeper reading never wakes the operator on its own (LUNA-131 design D10).
  if (sweeperYellow) text += " (sweeper had a recent alarm within the last 24h)";
  return text;
}

export type CheckOutcome = "sent" | "clean" | "cooldown" | "skip-no-vault" | "skip-error" | "undelivered";

export type SweeperLevel = "red" | "yellow" | "green";
export type SweeperEvaluation = { level: SweeperLevel; reason: string | null };

// LUNA-131 Task 8 — thresholds from status.json's RED/YELLOW rule (design
// Component 3). Pure: no fs, no network, no Date.now() — nowMs is injected.
const SWEEPER_DEAD_MS = 30 * 60 * 1000;
const STALE_MS = 60 * 60 * 1000;
const PULL_BACKLOG_SKIPS = 12;
const PUSH_BLOCKED_FAILURES = 6;
const YELLOW_WINDOW_MS = 24 * 60 * 60 * 1000;
const RED_ALARM_CLASSES = new Set(["auth", "plugin-resurrected", "wrong-remote"]);

function parseTs(value: unknown): number | null {
  if (typeof value !== "string") return null;
  const ms = Date.parse(value);
  return Number.isNaN(ms) ? null : ms;
}

// Pure evaluation of an already-parsed status.json value (or null for
// missing/unparseable). Never reads a file — the caller (main(), or a test)
// owns the fs access, keeping checkLunaSync's no-fs/no-network invariant
// intact for the sweeper dimension too.
export function evaluateSweeperStatus(status: unknown, nowMs: number): SweeperEvaluation {
  if (status === null || typeof status !== "object") {
    return { level: "red", reason: "sweeper-dead" };
  }
  const s = status as Record<string, unknown>;

  // Math.abs, not a raw subtraction: clock skew or corrupt status data can
  // push ts/last_clean_ts into the FUTURE, and a plain `nowMs - tsMs` reads
  // negative there — comfortably under the threshold, so a corrupt/skewed
  // reading would pass as fresh instead of tripping sweeper-dead/stale.
  const tsMs = parseTs(s.ts);
  if (tsMs === null || Math.abs(nowMs - tsMs) > SWEEPER_DEAD_MS) {
    return { level: "red", reason: "sweeper-dead" };
  }

  const lastCleanMs = parseTs(s.last_clean_ts);
  if (lastCleanMs === null || Math.abs(nowMs - lastCleanMs) > STALE_MS) {
    return { level: "red", reason: "stale" };
  }

  const pullSkips = typeof s.consecutive_pull_skips === "number" ? s.consecutive_pull_skips : 0;
  if (pullSkips >= PULL_BACKLOG_SKIPS) {
    return { level: "red", reason: "pull-backlog" };
  }

  const pushFailures = typeof s.consecutive_push_failures === "number" ? s.consecutive_push_failures : 0;
  if (pushFailures >= PUSH_BLOCKED_FAILURES) {
    return { level: "red", reason: "push-blocked" };
  }

  const alarmClass = typeof s.alarm_class === "string" ? s.alarm_class : null;
  if (alarmClass !== null && RED_ALARM_CLASSES.has(alarmClass)) {
    return { level: "red", reason: alarmClass };
  }

  // >= 0 guard, not just <= YELLOW_WINDOW_MS: a future-dated last_alarm_ts
  // (clock skew / corrupt data) makes the subtraction negative, which is
  // always <= the window — that would retain YELLOW indefinitely instead of
  // treating the bogus reading as no-recent-alarm.
  const lastAlarmMs = parseTs(s.last_alarm_ts);
  if (lastAlarmMs !== null) {
    const age = nowMs - lastAlarmMs;
    if (age >= 0 && age <= YELLOW_WINDOW_MS) {
      return { level: "yellow", reason: null };
    }
  }

  return { level: "green", reason: null };
}

// Core check. Every side effect (git read, alert send, logging) is injected —
// no fs/network/state-file access here — so this is unit-testable with plain
// values. Never throws; the caller decides how to log/exit.
//
// LUNA-131 Task 8: a RED sweeper reading must never be swallowed by the four
// pre-existing early returns (skip-no-vault / skip-error / clean-no-upstream /
// clean-genuinely-clean). Required order (design D10, plan Task 8 step 3):
//   1. Evaluate the sweeper FIRST, before any early return.
//   2. Read the git side defensively — a falsy vaultPath or a thrown runner
//      records the would-be outcome but does not return yet; the git
//      dimension defaults to unpushed=0, uncommitted=0.
//   3. If the sweeper is not RED and the git side would have returned early,
//      return that original outcome with its original state semantics.
//   4. Otherwise (sweeper RED, or genuine git divergence) fall through to the
//      existing cooldown/send block.
export async function checkLunaSync(opts: {
  vaultPath: string | undefined;
  nowMs: number;
  gitRunner: GitRunner;
  state: AlertState;
  sweeperStatus: unknown;
  cooldownMs?: number;
  sendAlert: (text: string) => Promise<boolean>;
  log?: (msg: string) => void;
}): Promise<{ outcome: CheckOutcome; state: AlertState }> {
  const log = opts.log ?? ((m: string) => console.error(m));
  const sweeper = evaluateSweeperStatus(opts.sweeperStatus, opts.nowMs);

  let earlyOutcome: CheckOutcome | null = null;
  let earlyState: AlertState = opts.state;
  let unpushedCount = 0;
  let uncommitted = 0;

  if (!opts.vaultPath) {
    earlyOutcome = "skip-no-vault";
  } else {
    let result: GitDivergenceResult | null = null;
    try {
      result = await opts.gitRunner(opts.vaultPath);
    } catch (e) {
      log(`luna-sync-alert: git query failed (${e instanceof Error ? e.message : String(e)}) — skipping`);
      earlyOutcome = "skip-error";
    }

    if (result !== null) {
      const unpushed = result.unpushed;
      uncommitted = result.uncommittedFiles;

      if (unpushed === null && uncommitted === 0) {
        // No upstream configured (unpushed unknown) AND nothing uncommitted —
        // no divergence to report and nothing to compare, out of scope for
        // this checker. NOT a genuinely-clean tree, so PRESERVE any
        // in-progress alert state unconditionally — resetting here would wipe
        // the cooldown/rising-edge on a reading that says nothing about
        // whether changes are piling up (HIMMEL-1199 — only a genuinely-clean
        // tree resets; LUNA-131 Task 8 step 4 — this holds regardless of
        // sweeper level).
        earlyOutcome = "clean";
      } else {
        // A null unpushed (no upstream) contributes nothing to the count but
        // must NOT mask uncommitted files — either dimension diverging is the
        // blocked-git-op silent failure this checker exists to surface
        // (HIMMEL-1199 CR: the alert and metric both cover uncommitted files,
        // so the trigger must too).
        unpushedCount = unpushed ?? 0;
        if (unpushedCount <= 0 && uncommitted <= 0) {
          // Genuinely clean — reset so the NEXT divergence reads as a fresh
          // rising edge, but ONLY when the sweeper isn't RED: a GREEN/YELLOW
          // sweeper on its own says nothing about the git tree, and a RED
          // sweeper on a clean tree must fall through to alert, not reset
          // (LUNA-131 Task 8 step 4 — the swallow regression this exists to fix).
          earlyOutcome = "clean";
          earlyState = sweeper.level !== "red" ? { lastAlertedAt: null } : opts.state;
        }
      }
    }
  }

  if (sweeper.level !== "red" && earlyOutcome !== null) {
    return { outcome: earlyOutcome, state: earlyState };
  }

  const cooldownMs = opts.cooldownMs ?? DEFAULT_COOLDOWN_MS;
  if (opts.state.lastAlertedAt !== null && opts.nowMs - Date.parse(opts.state.lastAlertedAt) < cooldownMs) {
    return { outcome: "cooldown", state: opts.state };
  }

  const sweeperReason = sweeper.level === "red" ? sweeper.reason : null;
  const sweeperYellow = sweeper.level === "yellow";

  // Advance the cooldown/rising-edge state ONLY when the alert was actually
  // delivered. sendAlert resolves false when there is no chat_id or Telegram
  // dropped the message; persisting lastAlertedAt then would suppress retries
  // for the whole cooldown window with no operator ever notified — recreating
  // the exact silent failure this checker fights (HIMMEL-1199 CR: codex-adv +
  // coderabbit).
  const delivered = await opts.sendAlert(buildAlertText(unpushedCount, uncommitted, opts.vaultPath, sweeperReason, sweeperYellow));
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
  const sweeperStatus = readSweeperStatus(sweeperStatusPath(env));
  const chatId = await resolveChatId(env);

  const result = await checkLunaSync({
    vaultPath: cfg.vault_path,
    nowMs,
    gitRunner: runGitDivergence,
    state,
    sweeperStatus,
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
