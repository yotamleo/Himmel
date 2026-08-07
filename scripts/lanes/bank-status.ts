#!/usr/bin/env bun
// scripts/lanes/bank-status.ts
// HIMMEL-1513 — funded-bank probe, the companion to the guard's runnable check
// (scripts/hooks/guard-implementor-dispatch.sh). lane_runnable() proves a lane
// is INVOCABLE (bun + dispatcher on disk); it never proves the lane's BANK is
// FUNDED. This probe closes that gap.
//
// For each lane that declares a quota bank in scripts/lanes/lanes.json it prints
// one line:
//   <lane-id> <state>     state in { funded | spent | unknown }
//
//   spent    ONLY when a provably-LIVE window reports usedPct >= LANE_FUNDED_MAX_PCT
//            (default 99). Every reader in quota-sources.ts gates a reading on a
//            LIVE resets_at window (parseable AND in the future); an expired
//            window means the bank has reset since the value was written, so
//            emitting it would fabricate.
//   unknown  when there is no live reading, a reader sets omitReason, or anything
//            throws. Never a fabricated number.
//   funded   otherwise — a live reading exists and none is at/over the threshold.
//
// REUSES the existing readers verbatim (this file reimplements NONE of them):
//   readLaneQuotaTargets(lanesPath) — lane->bank map from lanes.json
//   readClaudeBank / readCodexBank / readGlmBank — {readings, omitReason} per
//     bank, each already gated on a provably-LIVE window.
//
// Bank source paths resolve the SAME files the flow exporter reads
// (scripts/observability/flow-exporter.ts): the claude statusline cache
// (defaultClaudeCachePath), ~/.codex/sessions, and the quota-gauge ledger.
//
// Exits 0 with whatever it could establish. A consumer (the guard) treats
// `unknown` as FUNDED (fail-open): this probe never invents a hard-block —
// `spent` skips a preferred lane toward a cheaper fall-through, it does not
// refuse toward the caller.
//
// The guard stubs this whole probe via IMPL_GUARD_BANK_STATUS_CMD (see the
// guard's file header) so its test suite never depends on the operator's live
// bank state.
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
import {
  defaultClaudeCachePath,
  readClaudeBank,
  readCodexBank,
  readGlmBank,
  readLaneQuotaTargets,
  type BankId,
  type BankResult,
} from "../observability/quota-sources";
import { ledgerPath as quotaGaugeLedgerPath } from "../telegram/quota-gauge";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const LANES_PATH = process.env.LANES_REGISTRY || join(SCRIPT_DIR, "lanes.json");

// spent threshold on a live usedPct. Default 99: a lane is only "spent" when a
// live window is at or beyond near-exhaustion. Lowering it makes the guard skip
// a preferred lane earlier (fail toward the cheaper fall-through).
const MAX_PCT = (() => {
  const raw = Number.parseFloat(process.env.LANE_FUNDED_MAX_PCT ?? "");
  return Number.isFinite(raw) ? raw : 99;
})();

const nowMs = Date.now();
const env = process.env;
const home = env.HOME ?? homedir();

// Resolve each bank's source file exactly as the flow exporter does. Honoring
// CLAUDE_USAGE_CACHE / HIMMEL_QUOTA_GAUGE_LEDGER keeps this probe on the SAME
// files the rest of the harness reads.
const claudeCache = defaultClaudeCachePath(env, process.platform);
const codexSessions = join(home, ".codex", "sessions");
const glmLedger = quotaGaugeLedgerPath(env);

function readBank(bank: BankId): BankResult {
  switch (bank) {
    case "claude": return readClaudeBank(claudeCache, nowMs);
    case "codex": return readCodexBank(codexSessions, nowMs);
    case "glm": return readGlmBank(glmLedger, nowMs);
  }
}

const targets = readLaneQuotaTargets(LANES_PATH);
// Lanes share a bank (claudex/codex-exec/codex-wsl -> codex; glm/glm-subagent
// -> glm). Read each bank ONCE.
const bankCache = new Map<BankId, BankResult>();

for (const { lane, bank } of targets.withBank) {
  let state: "funded" | "spent" | "unknown" = "unknown";
  try {
    let result = bankCache.get(bank);
    if (!result) {
      result = readBank(bank);
      bankCache.set(bank, result);
    }
    // omitReason set OR no live reading -> unknown (never fabricate). Otherwise
    // spent iff ANY live window reports usedPct >= MAX_PCT ("a live window
    // reports" — existential, matching the spec wording; the 99 default makes a
    // false-spent require a window genuinely near exhaustion).
    if (!result.omitReason && result.readings.length > 0) {
      state = result.readings.some((r) => r.usedPct >= MAX_PCT) ? "spent" : "funded";
    }
  } catch {
    state = "unknown";
  }
  process.stdout.write(`${lane} ${state}\n`);
}
