#!/usr/bin/env bun
// scripts/lanes/bank-status.ts
// HIMMEL-1513/HIMMEL-1678 — report both the routing guard verdict and the
// evidence behind it. Output remains guard-compatible in its first two fields:
//   <lane-id> <funded|spent|unknown> <measured ...|unmeasurable ...|flat-rate>
//
// PER-BANK READER CONTRACT (HIMMEL-1678 CR, codex-1). The HIMMEL-1513 header
// this file used to carry asserted one blanket invariant — "every reader gates
// a reading on a LIVE resets_at window" — and that is no longer true of all
// three banks. Stating it per bank, because the deleted blanket claim is worse
// than no claim:
//
//   claude — readClaudeBank, live-window gated (unchanged). omitReason or zero
//            readings => unmeasurable; never a fabricated number.
//   glm    — readGlmBank, live-window gated (valid used_pct AND a resets_at
//            still in the future). See readGlmDisplay below for why the normal
//            state is flat-rate and only a LIVE exhaustion breaks out of it.
//   codex  — readCodexWeeklyBank, NOT window-gated. This is deliberate and is
//            the one place the old blanket invariant no longer holds.
//
// Why codex changed source. readCodexBank reads ~/.codex/sessions rollouts for
// a `rate_limits` row. That source has gone DEAD on current codex builds: the
// newest rollout on this machine is two days old and contains zero rate_limits
// rows, while ~/.codex/logs_2.sqlite is written continuously. Keeping the gated
// reader would therefore not preserve a guarantee — it would report codex
// `unknown` forever, which is precisely the blindness HIMMEL-1513 exists to
// remove. readCodexBank itself is NOT dead code: scripts/observability/
// flow-exporter.ts still uses it against the same sessions dir, and its unit
// tests are unchanged.
//
// Residual, and its ACTUAL bounds (HIMMEL-1689 — judge-corrected). An earlier
// version of this comment claimed the dangerous direction (stale-LOW masking
// real exhaustion) was "not reachable, because codex usage only climbs by
// RUNNING codex". That claim is FALSE and was withdrawn; do not restore it.
// It fails twice over:
//   1. The weekly reset breaks monotonicity. "Usage only climbs" holds only
//      WITHIN a window; across a reset the counter sawtooths to 0 and climbs
//      again. With no resets_at in this source, a reading cannot be attributed
//      to a window at all, so an out-of-window value is not high or low — it is
//      INCOMPARABLE.
//   2. First-match-wins breaks "newest". The monotonicity argument assumes the
//      scan reads the newest record. True for the WAL (append-only, so
//      physically-later == temporally-later); NOT true for the main-DB
//      fallback below, because SQLite does not zero freed pages, so a stale row
//      image can sit physically later than the live row and the scan returns on
//      it first.
// So a stale-LOW `funded` for an EXHAUSTED lane IS reachable: via the main-DB
// fallback, after a checkpoint has truncated the WAL, across a weekly reset.
// What is still true, and why this remains acceptable for now: the impact is
// bounded to a MIS-ROUTE, not a safety failure — a wrong `funded` never grants
// or refuses toward the caller HERE; this module only reports. The WAL path
// (the hot path in practice) is genuinely sound. And a missing or unparseable
// log reports `unmeasurable`, never a fabricated number.
// Do NOT read "mis-route" as "and then it falls through" (HIMMEL-1700). The
// guard's documented fall-through — guard-implementor-dispatch.sh lane_funded()
// "skipping it, not refusing toward it" — fires only on `spent`. A `funded`
// verdict does the OPPOSITE: it refuses the in-process Agent dispatch and names
// that lane. So whenever `funded` here disagrees with the lane's own dispatcher
// the caller is left with no path — and the two DO disagree by default, because
// funded-max-pct defaults to 99 while spawn-claudex refuses at 90. That 90-98%
// band is pre-existing and tracked in HIMMEL-1700, not introduced here.
// The real fix is HIMMEL-1689: query this log via bun:sqlite for the newest
// rate-limit row, which removes the free-page ambiguity AND recovers resets_at
// — recovering resets_at is the bigger prize, since it is the only thing that
// closes hole 1.
import { closeSync, existsSync, fstatSync, openSync, readSync, readFileSync } from "node:fs";
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
  codexScanWindows,
  formatMeasured,
  formatUnmeasurable,
  parseCodexWeeklyUsedPercent,
} from "./bank-status-core.mjs";
import { resolveBankTargets } from "./resolve.mjs";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const LANES_PATH = process.env.LANES_REGISTRY || join(SCRIPT_DIR, "lanes.json");
// HIMMEL-1690: the machine-local overlay resolve.mjs loadRegistry() layers on
// top of the base registry. The bank probe must read the SAME overlay so an
// overlay-only quota bank gets a real status instead of "no status returned".
const LOCAL_LANES_PATH = join(SCRIPT_DIR, "lanes.local.json");
const CODEX_CHUNK_BYTES = 8 * 1024 * 1024;
// Consecutive tail windows overlap by this much so a used_percent record split
// across a chunk boundary is still seen whole (HIMMEL-1678 CR, codex-2/glm-3).
// 64 KiB is orders of magnitude above the longest rate-limit JSON record.
const CODEX_CHUNK_OVERLAP_BYTES = 64 * 1024;
const CODEX_MAX_SCAN_BYTES = 256 * 1024 * 1024;
const MAX_PCT = parseFundedMaxPct(process.env.LANE_FUNDED_MAX_PCT);
const nowMs = Date.now();
const env = process.env;
const home = env.HOME ?? homedir();
const claudeCache = defaultClaudeCachePath(env, process.platform);
const codexLog = env.CODEX_BANK_LOG || join(home, ".codex", "logs_2.sqlite");
const glmLedger = quotaGaugeLedgerPath(env);

type DisplayResult =
  | { kind: "measured"; readings: BankReading[] }
  | { kind: "unmeasurable"; reason: string }
  | { kind: "flat-rate" };

function readCodexWeeklyBank(path: string): DisplayResult {
  if (!existsSync(path)) return { kind: "unmeasurable", reason: "codex log file missing" };
  try {
    for (const candidate of [`${path}-wal`, path]) {
      if (!existsSync(candidate)) continue;
      const fd = openSync(candidate, "r");
      try {
        const size = fstatSync(fd).size;
        const scanLimit = Math.min(size, CODEX_MAX_SCAN_BYTES);
        const windows = codexScanWindows(size, scanLimit, CODEX_CHUNK_BYTES, CODEX_CHUNK_OVERLAP_BYTES);
        for (const { start, length } of windows) {
          const buf = Buffer.alloc(length);
          readSync(fd, buf, 0, length, start);
          const usedPct = parseCodexWeeklyUsedPercent(buf.toString("latin1"));
          if (usedPct !== null) return { kind: "measured", readings: [{ window: "weekly", usedPct }] };
        }
      } finally {
        closeSync(fd);
      }
    }
    return { kind: "unmeasurable", reason: "codex log contains no parseable weekly used_percent" };
  } catch (error) {
    const code = typeof error === "object" && error && "code" in error ? String(error.code) : "I/O error";
    return { kind: "unmeasurable", reason: `codex log unreadable (${code})` };
  }
}

function readGlmDisplay(ledgerPath: string, nowMs: number): DisplayResult {
  // GLM is a flat-rate Coding Plan: no monetary funded-bank, so a 5h-cycle
  // percentage is NOT reported as a fabricated funded-bank percentage — the
  // normal state is `flat-rate`. But "no bank percentage" is not "no state
  // worth reading": readGlmBank reads the quota-gauge ledger and surfaces a
  // reading ONLY when a LIVE window exists (valid used_pct AND a resets_at
  // still in the future — the live-window validation). If that live reading
  // proves exhaustion (usedPct >= MAX_PCT), the GLM lane is SPENT — a runtime
  // condition the guard must route around, distinct from the flat-rate billing
  // shape. A stale/expired window yields no reading, so it fabricates neither
  // funded nor spent.
  const { readings } = readGlmBank(ledgerPath, nowMs);
  if (readings.some((reading) => reading.usedPct >= MAX_PCT)) {
    return { kind: "measured", readings };
  }
  return { kind: "flat-rate" };
}

function readBank(bank: BankId): DisplayResult {
  if (bank === "glm") return readGlmDisplay(glmLedger, nowMs);
  if (bank === "codex") return readCodexWeeklyBank(codexLog);
  const result = readClaudeBank(claudeCache, nowMs);
  return result.omitReason || result.readings.length === 0
    ? { kind: "unmeasurable", reason: result.omitReason || "no live Claude usage window" }
    : { kind: "measured", readings: result.readings };
}

function guardState(result: DisplayResult): "funded" | "spent" | "unknown" {
  if (result.kind === "flat-rate") return "funded";
  if (result.kind === "unmeasurable") return "unknown";
  return result.readings.some((reading) => reading.usedPct >= MAX_PCT) ? "spent" : "funded";
}

function detail(result: DisplayResult): string {
  if (result.kind === "flat-rate") return "flat-rate";
  if (result.kind === "unmeasurable") return formatUnmeasurable(result.reason);
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
for (const { lane, bank } of targets.withBank) {
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
  process.stdout.write(`${lane} ${guardState(result)} ${detail(result)}\n`);
}
