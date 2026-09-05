// scripts/telegram/onboard.ts — bridge onboarding mode (HIMMEL-2176 Stage-1 PR-C, Task 10).
//
// A dedicated, BOUNDED entry point (`bun scripts/telegram/onboard.ts`) that helps
// an adopter discover the chat.id / from.id values they will hand-author into
// access.json (spec A11). Deliberately NOT a poller flag: the poller's
// single-consumer `getUpdates` invariant must stay untangled from onboarding, so
// this refuses to run at all while the bridge is armed (see checkBridgeArmed)
// rather than becoming a second consumer.
//
// It never writes access.json — that file is trust-bearing and human-authored
// (spec A8.1). Onboarding REPORTS; the human edits.

import { randomBytes, createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, delimiter } from "node:path";
import { loadBridgeEnv } from "./poller";
import { pidfilePath, parsePidfile, type PidRec } from "./supervisor";
import { getUpdates } from "./telegram-api";

// --- lock-path derivation (contract owned by the sibling restart-bridge.sh) ---
// Mirrors scripts/telegram/restart-bridge.sh's `--print-lock-path` formula
// exactly: ${BRIDGE_LOCK_DIR:-${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}}/bridge-<sha256(token)[:16]>.lock
// restart-bridge.sh is the counterpart/authoritative implementation (POSIX
// launcher lock); this is the TS side of the SAME derivation so onboarding can
// refuse to start under the identical lock the launcher uses for its
// single-getUpdates-consumer guarantee. Keep in lockstep if the formula changes.
// `${VAR:-default}` (restart-bridge.sh's formula) falls back on unset OR
// empty; JS `??` only catches unset. bus.ts's bridgeRoot() has the same `??`
// gap, so it can't be reused as-is here — this replicates its fallback
// (CR fix, HIMMEL-2176): a set-but-empty BRIDGE_LOCK_DIR/BRIDGE_ROOT must
// resolve to the SAME path the shell derives, or the two single-consumer
// guards can disagree about which lock they're both supposed to hold.
function envOrDefault(v: string | undefined, fallback: string): string {
  return v === undefined || v === "" ? fallback : v;
}

export function lockPathForToken(token: string): string {
  const root = envOrDefault(process.env.BRIDGE_ROOT, join(homedir(), ".claude", "handover", "bridge"));
  const dir = envOrDefault(process.env.BRIDGE_LOCK_DIR, root);
  const hash = createHash("sha256").update(token, "utf8").digest("hex").slice(0, 16);
  return join(dir, `bridge-${hash}.lock`);
}

// --- refuse-to-start check (V4: single-consumer invariant) ---

export const STOP_COMMAND_POSIX = "bash scripts/telegram/restart-bridge.sh stop";
// restart-bridge.ps1 has NO stop verb: its `-Kill` is only a MODIFIER for
// -FromLedger/-Watchdog, and BOTH of those relaunch the bridge after killing —
// the opposite of what onboarding needs, and a bare `-Kill` falls through to the
// ordinary restart path. `supervisor.ts --kill` (HIMMEL-221) is the real stop
// lever and works on both platforms.
export const STOP_COMMAND_WIN = "bun scripts/telegram/supervisor.ts --kill";

export function refusalMessage(reason: string): string {
  return `[onboard] refusing to start — ${reason}. Stop the bridge first, then re-run onboarding:\n`
    + `  POSIX:   ${STOP_COMMAND_POSIX}\n`
    + `  Windows: ${STOP_COMMAND_WIN}`;
}

export type ArmedCheckDeps = {
  pidfileRec: () => PidRec | null;
  isAlive: (pid: number) => boolean;
  bridgeProcessRunning: () => boolean;
  lockPath: string;
  fileExists: (p: string) => boolean;
};

// Refuse when ANY of: the supervisor pidfile names a live pid, a bridge process
// is otherwise detected running, or the launcher lockfile is present. Returns a
// human reason string (message-ready) or null when it's safe to start.
export function checkBridgeArmed(deps: ArmedCheckDeps): string | null {
  const rec = deps.pidfileRec();
  if (rec && (deps.isAlive(rec.supervisor) || (rec.poller != null && deps.isAlive(rec.poller)))) {
    return "the bridge supervisor is running (supervisor.pid names a live pid)";
  }
  if (deps.bridgeProcessRunning()) {
    return "a bridge process (poller.ts / supervisor.ts) is running";
  }
  if (deps.fileExists(deps.lockPath)) {
    return "the bridge launcher lock is held (another process owns getUpdates for this token)";
  }
  return null;
}

// Whether `bin` resolves on PATH — same PATH-scan shape as
// scripts/himmelctl/lib/helpers.js's `which()` (win32 extension walk
// included), duplicated locally rather than imported: onboard.ts stays
// inside scripts/telegram and doesn't reach across into scripts/himmelctl/.
function commandExists(bin: string): boolean {
  const exts = process.platform === "win32" ? ["", ".exe", ".cmd", ".bat"] : [""];
  const dirs = String(process.env.PATH ?? process.env.Path ?? "").split(delimiter);
  for (const dir of dirs) {
    if (!dir) continue;
    for (const ext of exts) {
      if (existsSync(join(dir, bin + ext))) return true;
    }
  }
  return false;
}

// Same preference order as scripts/himmelctl/lib/helpers.js's
// resolvePowershell() (HIMMEL-2126): prefer `pwsh` (PowerShell 7), fall back
// to `powershell` (5.1) only when pwsh isn't found — a host with ONLY pwsh
// installed must not silently fail the armed-check below (its catch turns
// any spawn failure into "no bridge process found", a fail-open on a safety
// check). `exists` is injectable so the preference order is testable
// independent of the actual host platform.
export function resolvePowershellBin(exists: (bin: string) => boolean = commandExists): string {
  return exists("pwsh") ? "pwsh" : "powershell";
}

// ponytail: best-effort OS process scan — the pidfile check above is the
// primary, race-free signal; this only catches a bridge process running
// WITHOUT (or ahead of) a valid pidfile. Any failure (missing tool, perms)
// fails to "not found" so a broken scan can never itself hang onboarding;
// upgrade path if that gap ever bites: read /proc directly on POSIX.
function defaultBridgeProcessRunning(): boolean {
  const CORE = /(?:^|[\\/\s])(?:supervisor|poller)\.ts(?:\s|$)/;
  try {
    if (process.platform === "win32") {
      const r = Bun.spawnSync([resolvePowershellBin(), "-NoProfile", "-Command",
        "Get-CimInstance Win32_Process -Filter \"Name='bun.exe'\" | Select-Object -ExpandProperty CommandLine"],
        { stdout: "pipe", stderr: "pipe" });
      return CORE.test(r.stdout?.toString() ?? "");
    }
    const r = Bun.spawnSync(["ps", "-eo", "args"], { stdout: "pipe", stderr: "pipe" });
    return CORE.test(r.stdout?.toString() ?? "");
  } catch { return false; }
}

// --- nonce + update matching (V3) ---

export function generateNonce(): string {
  return `onboard-${randomBytes(4).toString("hex")}`;
}

export function matchesNonce(update: any, nonce: string): boolean {
  const m = update?.message ?? update?.channel_post;
  const text = typeof m?.text === "string" ? m.text : typeof m?.caption === "string" ? m.caption : null;
  return typeof text === "string" && text.includes(nonce);
}

export type Identity = { chatId: number; chatType: string; fromId: number | null; label: string };

// Enough to author an access.json entry — chat.id, chat.type, from.id, and a
// human label — never the raw message body (spec: never the body verbatim
// beyond what's needed).
export function extractIdentity(update: any): Identity | null {
  const m = update?.message ?? update?.channel_post;
  const chat = m?.chat;
  if (!chat || typeof chat.id !== "number") return null;
  const from = m.from;
  const fromId = typeof from?.id === "number" ? from.id : null;
  let label: string;
  if (chat.type === "private") {
    label = from?.username ? `@${from.username}`
      : [from?.first_name, from?.last_name].filter(Boolean).join(" ") || `user ${fromId ?? chat.id}`;
  } else {
    label = typeof chat.title === "string" && chat.title ? chat.title : `${chat.type} ${chat.id}`;
  }
  return { chatId: chat.id, chatType: chat.type, fromId, label };
}

export function formatOffer(id: Identity): string {
  return `[onboard] chat.id=${id.chatId} chat.type=${id.chatType} from.id=${id.fromId ?? "n/a"} label=${id.label}`;
}

// Pure per-batch step. `alreadyConsumed` carries the nonce's used/not-used state
// across batches (a used nonce is never re-offered — replay rejection). Only
// updates whose text/caption CONTAINS the nonce are offered; everything else
// (including a nonce-less message from an unrelated chat) is dropped silently.
export function collectOffers(updates: any[], nonce: string, alreadyConsumed: boolean): { offers: Identity[]; consumed: boolean } {
  if (alreadyConsumed) return { offers: [], consumed: true };
  const offers: Identity[] = [];
  for (const u of updates) {
    if (!matchesNonce(u, nonce)) continue;
    const id = extractIdentity(u);
    if (id) offers.push(id);
  }
  return { offers, consumed: offers.length > 0 };
}

// --- token redaction (the URL-embeds-the-token leak from the predecessor PR) ---

export function redactToken(text: string, token: string): string {
  if (!token) return text;
  return text.split(token).join("[REDACTED]");
}

// getUpdates wrapped so a transport error (whose message/URL can embed the raw
// token — telegram-api.ts's API() builds `.../bot<token>/method`) is redacted
// before it ever reaches a log line, never thrown raw.
export async function safeGetUpdates(token: string, offset: number, timeoutSec: number, f: typeof fetch = fetch): Promise<{ updates: any[]; error: string | null }> {
  try {
    return { updates: await getUpdates(token, offset, timeoutSec, f), error: null };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return { updates: [], error: redactToken(msg, token) };
  }
}

// --- CLI ---

const DEFAULT_TIMEOUT_SEC = 300;   // ~5 minutes (brief default)
const POLL_TIMEOUT_SEC = 30;       // long-poll window per getUpdates call
// Transport failures (DNS, revoked token, offline host) reject almost
// instantly, unlike a successful long-poll — without a delay here the loop
// would spin at max rate for the whole timeout window. Fixed and small: this
// is a CLI onboarding aid bounded by DEFAULT_TIMEOUT_SEC, not a long-running
// service that needs exponential backoff.
const ERROR_BACKOFF_MS = 2000;

const HELP_TEXT = `usage: bun scripts/telegram/onboard.ts [--timeout <seconds>]

Bounded onboarding run: prints a one-time nonce, waits for it to come back in a
Telegram message, then reports the chat.id / chat.type / from.id it arrived on.
It NEVER writes access.json — copy the reported ids into it yourself.

Refuses to start while the bridge is armed/running (single-getUpdates-consumer
invariant) — stop it first:
  POSIX:   ${STOP_COMMAND_POSIX}
  Windows: ${STOP_COMMAND_WIN}

Options:
  --timeout <seconds>   how long to wait for the nonce (default ${DEFAULT_TIMEOUT_SEC})
  --help, -h            print this message and exit
`;

// Same shape as supervisor.ts's resolveMaxFails: undefined/blank silently
// takes the default, but a genuinely BAD value (NaN, non-positive) must not
// silently disable the timeout — `now() < NaN` is always false, so a garbage
// value would make the poll loop never execute and the CLI would report
// "timed out after NaNs" instantly. Falls back loudly (warn), not silently.
export function resolveTimeoutSec(raw: string | undefined, warn: (s: string) => void = (s) => console.error(s)): number {
  if (raw === undefined || raw.trim() === "") return DEFAULT_TIMEOUT_SEC;
  const n = Number(raw);
  if (Number.isFinite(n) && n > 0) return n;
  warn(`[onboard] ONBOARD_TIMEOUT_SEC="${raw}" is not a positive number — using the default ${DEFAULT_TIMEOUT_SEC}s`);
  return DEFAULT_TIMEOUT_SEC;
}

function parseArgs(argv: string[], warn: (s: string) => void = (s) => console.error(s)): { help: boolean; timeoutSec: number | null } {
  let timeoutSec: number | null = null;
  let help = false;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--help" || a === "-h") help = true;
    else if (a === "--timeout") {
      const raw = argv[++i];
      const v = Number(raw);
      if (Number.isFinite(v) && v > 0) timeoutSec = v;
      else warn(`[onboard] --timeout ${raw ?? ""} is not a positive number — using the default ${DEFAULT_TIMEOUT_SEC}s`);
    }
  }
  return { help, timeoutSec };
}

export type RunDeps = {
  argv?: string[];
  loadToken?: () => Promise<string>;
  isAlive?: (pid: number) => boolean;
  bridgeProcessRunning?: () => boolean;
  fileExists?: (p: string) => boolean;
  fetchFn?: typeof fetch;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
  log?: (s: string) => void;
  error?: (s: string) => void;
};

// Thin main(), extracted-and-tested pieces above (poller.ts/supervisor.ts
// style). Returns a process exit code rather than calling process.exit itself,
// so tests can drive it in-process.
export async function run(deps: RunDeps = {}): Promise<number> {
  const argv = deps.argv ?? process.argv.slice(2);
  const log = deps.log ?? ((s: string) => console.log(s));
  const error = deps.error ?? ((s: string) => console.error(s));
  const { help, timeoutSec: argTimeout } = parseArgs(argv, error);
  if (help) { log(HELP_TEXT); return 0; }   // never requires a token

  const loadToken = deps.loadToken ?? (async () => {
    const env = await loadBridgeEnv();
    return env.TELEGRAM_BOT_TOKEN!;
  });
  let token: string;
  try { token = await loadToken(); }
  catch (e) { error(`[onboard] could not load TELEGRAM_BOT_TOKEN: ${e instanceof Error ? e.message : String(e)}`); return 1; }

  const isAlive = deps.isAlive ?? ((pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } });
  const bridgeProcessRunning = deps.bridgeProcessRunning ?? defaultBridgeProcessRunning;
  const fileExists = deps.fileExists ?? existsSync;
  const armedReason = checkBridgeArmed({
    pidfileRec: () => { try { return parsePidfile(readFileSync(pidfilePath(), "utf8")); } catch { return null; } },
    isAlive,
    bridgeProcessRunning,
    lockPath: lockPathForToken(token),
    fileExists,
  });
  if (armedReason) { error(refusalMessage(armedReason)); return 1; }

  const nonce = generateNonce();
  log(`[onboard] send this exact text to the bot (DM or an allowed group) to onboard: ${nonce}`);
  log(`[onboard] this only REPORTS chat/user ids — access.json is NOT written automatically; hand-author it yourself.`);

  const timeoutSec = argTimeout ?? resolveTimeoutSec(process.env.ONBOARD_TIMEOUT_SEC, error);
  const now = deps.now ?? Date.now;
  const deadline = now() + timeoutSec * 1000;
  const fetchFn = deps.fetchFn ?? fetch;
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));

  // Own bounded read: an in-memory-only offset, never persisted — the poller's
  // committed cursor/offset files are never touched (requirement #7).
  let offset = 0;
  let consumed = false;
  while (now() < deadline) {
    const remainingSec = Math.max(1, Math.floor((deadline - now()) / 1000));
    const pollSec = Math.min(POLL_TIMEOUT_SEC, remainingSec);
    const { updates, error: fetchErr } = await safeGetUpdates(token, offset, pollSec, fetchFn);
    if (fetchErr) {
      error(`[onboard] getUpdates failed: ${fetchErr}`);
      // Deadline stays authoritative: cap the backoff to whatever's left so
      // it can never overshoot the timeout the CLI promised.
      const remainingMs = deadline - now();
      if (remainingMs > 0) await sleep(Math.min(ERROR_BACKOFF_MS, remainingMs));
    }
    for (const u of updates) if (typeof u?.update_id === "number") offset = Math.max(offset, u.update_id + 1);
    const { offers, consumed: newlyConsumed } = collectOffers(updates, nonce, consumed);
    if (!consumed && newlyConsumed) {
      consumed = true;
      for (const o of offers) log(formatOffer(o));
      log(`[onboard] done — copy the id(s) above into access.json yourself; nothing was written automatically.`);
      return 0;
    }
  }
  log(`[onboard] timed out after ${timeoutSec}s with no matching message — try again: bun scripts/telegram/onboard.ts`);
  return 0;
}

if (import.meta.main) process.exit(await run());
