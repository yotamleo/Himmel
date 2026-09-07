#!/usr/bin/env bun
// scripts/lanes/bank-status.ts
// HIMMEL-1513/HIMMEL-1678 — report both the routing guard verdict and the
// evidence behind it. Output remains guard-compatible in its first two fields:
//   <lane-id> <funded|spent|unknown> <measured ...|unmeasurable ...|flat-rate>
//
// PER-BANK READER CONTRACT (HIMMEL-1678 CR, codex-1). Three explicit bank
// states exist — measured, unmeasurable (with the reason), and
// flat-rate/not-applicable — and each bank uses the right one:
//
//   claude — readClaudeBank, live-window gated (unchanged). omitReason or zero
//            readings => unmeasurable; never a fabricated number.
//   glm    — readGlmBank, live-window gated. A live row => measured (the 5h
//            utilization is real data z.ai reports). NO live row => flat-rate,
//            NOT unmeasurable: the z.ai plan is FLAT-RATE (operator ruling,
//            HIMMEL-1678; confirmed by the scripts/claude-glm launcher header
//            — "Z.ai GLM flat-rate lane"), so an absent window is "not
//            applicable", not a measurement failure. `unknown` there was
//            bug-shaped: it read like a defect while the lane is in fact
//            always-available.
//   codex  — readCodexDisplay, a TTL-gated CACHE read (HIMMEL-1678). The
//            source of truth is `codex -s read-only -a untrusted app-server`
//            (JSON-RPC account/rateLimits/read), captured by the BOUNDED
//            probe scripts/lanes/codex-bank-probe.ts into
//            ${CODEX_BANK_CACHE:-~/.himmel/cache/codex-bank.json}. bank-status
//            NEVER spawns the probe: a preflight that spawns `codex
//            app-server` per call leaks a process whenever its kill fails.
//            Missing/stale/unusable cache => unmeasurable naming the remedy
//            (run the probe) — never a fabricated number, never a silent
//            fail-open. resetsAt arrives per limit and stays per limit in
//            both the cache and the detail line (HIMMEL-1725).
//
// The deleted sqlite scan, kept as history so nobody resurrects it: every
// prior attempt read `~/.codex/logs_2.sqlite` for a used_percent — that file
// is a LOG database and never contained a quota field, so its eternal
// `unmeasurable` was the right answer to the wrong question. Its HIMMEL-1689
// hole #1 (a reading with no window attribution is incomparable across a
// weekly reset) is now closed structurally: the probe captures resetsAt per
// limit, and readCodexBankCache drops any limit whose window already reset.
// spawn-claudex's dispatch preflight read the same file the same way and was
// therefore refusing EVERY claudex dispatch; it now reads this cache too.
// readCodexBank (sessions rollouts, quota-sources.ts) and scripts/lanes/bench/*
// are DIFFERENT consumers of ~/.codex and are intentionally untouched here.
// Do NOT read "mis-route" as "and then it falls through" (HIMMEL-1700, still
// true of the funded verdict): the guard's documented fall-through —
// guard-implementor-dispatch.sh lane_funded() "skipping it, not refusing
// toward it" — fires only on `spent`. A `funded` verdict does the OPPOSITE:
// it refuses the in-process Agent dispatch and names that lane, and
// funded-max-pct defaults to 99 while spawn-claudex refuses at 90 — that
// 90-98% disagreement band is pre-existing and tracked in HIMMEL-1700, not
// introduced here.
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
import {
  BANK_IDS,
  defaultClaudeCachePath,
  readClaudeBank,
  readGlmBank,
  type BankId,
  type BankReading,
  type LaneQuotaTargets,
} from "../observability/quota-sources";
import { ledgerPath as quotaGaugeLedgerPath } from "../telegram/quota-gauge";
import { parseFundedMaxPct } from "./funded-max-pct.mjs";
import {
  CODEX_BANK_PROBE_REMEDY,
  formatMeasured,
  formatUnmeasurable,
  guardState,
  readCodexBankCache,
} from "./bank-status-core.mjs";
import { resolveActiveAccessPath, resolveBankTargets } from "./resolve.mjs";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const LANES_PATH = process.env.LANES_REGISTRY || join(SCRIPT_DIR, "lanes.json");
// HIMMEL-1690: the machine-local overlay resolve.mjs loadRegistry() layers on
// top of the base registry. The bank probe must read the SAME overlay so an
// overlay-only quota bank gets a real status instead of "no status returned".
const LOCAL_LANES_PATH = join(SCRIPT_DIR, "lanes.local.json");
// HIMMEL-1678: codex bank read comes from the probe's TTL'd cache (default
// TTL 6h). See the header for why bank-status only ever READS this file.
const CODEX_BANK_TTL_DEFAULT_SECONDS = 6 * 60 * 60;
const MAX_PCT = parseFundedMaxPct(process.env.LANE_FUNDED_MAX_PCT);
const nowMs = Date.now();
const env = process.env;
const home = env.HOME ?? homedir();
const claudeCache = defaultClaudeCachePath(env, process.platform);
const codexBankCachePath = env.CODEX_BANK_CACHE || join(home, ".himmel", "cache", "codex-bank.json");
const codexBankTtlSeconds = positiveEnvNumber(env.CODEX_BANK_CACHE_TTL_SECONDS) ?? CODEX_BANK_TTL_DEFAULT_SECONDS;
const glmLedger = quotaGaugeLedgerPath(env);

function positiveEnvNumber(v: string | undefined): number | null {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : null;
}

type CodexCacheReading = BankReading & { resetsAt?: number };
type DisplayResult =
  | { kind: "measured"; readings: CodexCacheReading[] }
  | { kind: "unmeasurable"; reason: string }
  | { kind: "flat-rate" };

function readCodexDisplay(cachePath: string): DisplayResult {
  if (!existsSync(cachePath)) {
    return { kind: "unmeasurable", reason: `codex bank cache missing — ${CODEX_BANK_PROBE_REMEDY}` };
  }
  let text: string;
  try {
    text = readFileSync(cachePath, "utf8");
  } catch (error) {
    const code = typeof error === "object" && error && "code" in error ? String(error.code) : "I/O error";
    return { kind: "unmeasurable", reason: `codex bank cache unreadable (${code}) — ${CODEX_BANK_PROBE_REMEDY}` };
  }
  return readCodexBankCache(text, nowMs, codexBankTtlSeconds);
}

function readGlmDisplay(ledgerPath: string, nowMs: number): DisplayResult {
  const result = readGlmBank(ledgerPath, nowMs);
  if (!result.omitReason && result.readings.length > 0) return { kind: "measured", readings: result.readings };
  // No live ledger window: the lane is flat-rate, not broken. See the header
  // — `unmeasurable`/`unknown` here would be the bug-shaped word for a
  // not-applicable measurement.
  return { kind: "flat-rate" };
}

function readBank(bank: BankId): DisplayResult {
  if (bank === "glm") return readGlmDisplay(glmLedger, nowMs);
  if (bank === "codex") return readCodexDisplay(codexBankCachePath);
  const result = readClaudeBank(claudeCache, nowMs);
  return result.omitReason || result.readings.length === 0
    ? { kind: "unmeasurable", reason: result.omitReason || "no live Claude usage window" }
    : { kind: "measured", readings: result.readings };
}

function detail(result: DisplayResult): string {
  if (result.kind === "unmeasurable") return formatUnmeasurable(result.reason);
  if (result.kind === "flat-rate") return "flat-rate";
  return formatMeasured(result.readings);
}

// HIMMEL-1690: load the base registry and, when no explicit LANES_REGISTRY
// override is set, the lanes.local.json overlay — the same gating resolve.mjs
// loadRegistry() uses (LANES_REGISTRY replaces wholesale; no overlay on top).
// resolveBankTargets merges the two so an overlay-only quota bank is probed.
function readLaneRegistry(): { base: object; local: object | null } {
  let base: object = {};
  try { base = JSON.parse(readFileSync(LANES_PATH, "utf8")); } catch { base = {}; }
  if (process.env.LANES_REGISTRY || !existsSync(LOCAL_LANES_PATH)) return { base, local: null };
  try {
    return { base, local: JSON.parse(readFileSync(LOCAL_LANES_PATH, "utf8")) };
  } catch {
    return { base, local: null };
  }
}

const { base, local } = readLaneRegistry();
const targets = resolveBankTargets(base, local, BANK_IDS) as LaneQuotaTargets;
const bankCache = new Map<BankId, DisplayResult>();
for (const { lane, bank, quota } of targets.withBank) {
  let result = bankCache.get(bank);
  if (!result) {
    try {
      result = readBank(bank);
    } catch (error) {
      const reason = error instanceof Error ? error.message : "unexpected reader failure";
      result = { kind: "unmeasurable", reason };
    }
    bankCache.set(bank, result);
  }
  // HIMMEL-1768 round 3: resolve the ACTIVE access path explicitly. A failed
  // selection (missing paths, out-of-range index) is a registry ERROR, not a
  // paths[0] fallback — the verdict goes unknown and the diagnostic lands on
  // stderr, keeping stdout the machine surface (<lane> <state> <detail>).
  const active = resolveActiveAccessPath(quota);
  if (!active.ok) {
    process.stderr.write(`bank-status: lane '${lane}': ${active.reason} — guard unknown\n`);
  }
  process.stdout.write(`${lane} ${guardState(result, active, MAX_PCT)} ${detail(result)}\n`);
}
