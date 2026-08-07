// scripts/lanes/lane-readiness.mjs
// HIMMEL-1626 — lane READINESS probe, the third leg of the guard's lane
// qualification (scripts/hooks/guard-implementor-dispatch.sh):
//   lane_runnable() proves a lane is INVOCABLE (bun + dispatcher on disk);
//   lane_funded()  (bank-status.ts) proves its BANK has quota;
//   this probe proves the lane actually RETURNS WORK.
//
// Funding and readiness answer different questions: a lane can be fully funded
// while an operator ruling holds it DOWN (the GLM worker lane after the
// HIMMEL-1575 startup-hang class). Before this probe the guard fail-opened
// funding's `unknown` to "funded" and forced dispatches onto a ruled-down lane,
// stranding the sanctioned in-process Claude-tier path (the FIRST_WAVE block).
//
// Readiness is MEASURED, never asserted: a lane under a readiness gate
// (`readiness.passesRequired` in scripts/lanes/lanes.json) is ready only when
// the flow-runs ledger that verify-return.mjs (HIMMEL-1621) feeds shows that
// many TRAILING consecutive PASS rows for the lane's branches. A FAILED row
// resets the streak. Lanes without a gate are always ready.
//
// For each lane in the registry it prints one line (bank-status.ts parity):
//   <lane-id> <state>     state in { ready | down }
//
//   down   ONLY for a gated lane whose trailing consecutive PASS count in the
//          ledger is below its gate. A missing/unreadable ledger is "no
//          evidence of graduation" — gated lanes stay down. This direction is
//          safe by construction: the guard treats `down` as SKIP (toward the
//          other lane or the HIMMEL-920 fall-through), never as a refusal
//          toward the caller.
//   ready  otherwise.
//
// Lane attribution: a ledger row belongs to lane L when its note's branch
// field starts with "L/" (glm workers commit on glm/<slug>, claudex on
// claudex/<slug> — the spawn chokepoints own that convention).
//
// The guard stubs this whole probe via IMPL_GUARD_READINESS_CMD (see the
// guard's file header) so its test suite never depends on the operator's live
// ledger. An unparseable output or non-zero exit fail-opens to READY there —
// only a clean `down` verdict skips a lane.
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ledgerPath } from './verify-return.mjs';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));

// Trailing consecutive verify-return PASS rows for branches under `<laneId>/`.
// Note grammar (verify-return.mjs one-line contract):
//   PASS <ticket> <branch>
//   FAILED <ticket> <branch> <first-failed-check>
// Rows from other flows, non-end rows, and malformed lines (including a
// partial last line of an append-only file) are skipped, never fatal.
export function trailingPasses(ledgerText, laneId) {
  let count = 0;
  for (const line of String(ledgerText ?? '').split('\n')) {
    const t = line.trim();
    if (!t) continue;
    let row;
    try { row = JSON.parse(t); } catch { continue; }
    if (!row || row.flow !== 'verify-return' || row.ev !== 'end' || typeof row.note !== 'string') continue;
    const m = /^(PASS|FAILED) \S+ (\S+)/.exec(row.note);
    if (!m) continue;
    if (!m[2].startsWith(`${laneId}/`)) continue;
    count = m[1] === 'PASS' ? count + 1 : 0;
  }
  return count;
}

// One { lane, state } per registry lane. A gate is a positive finite
// `readiness.passesRequired`; anything else (absent, zero, negative, NaN,
// non-number) means ungated -> ready, so a malformed field can never down a
// lane the registry did not clearly gate.
export function laneStates(lanesJson, ledgerText) {
  const lanes = Array.isArray(lanesJson?.lanes) ? lanesJson.lanes : [];
  return lanes
    .filter((l) => l && typeof l.id === 'string')
    .map((l) => {
      const need = l.readiness?.passesRequired;
      if (typeof need !== 'number' || !Number.isFinite(need) || need <= 0) {
        return { lane: l.id, state: 'ready' };
      }
      return { lane: l.id, state: trailingPasses(ledgerText, l.id) >= need ? 'ready' : 'down' };
    });
}

function main() {
  const lanesPath = process.env.LANES_REGISTRY || join(SCRIPT_DIR, 'lanes.json');
  let lanesJson;
  try {
    lanesJson = JSON.parse(readFileSync(lanesPath, 'utf8'));
  } catch (e) {
    // No registry -> no verdict. The consumer (the guard) fail-opens a
    // non-zero exit to READY, preserving pre-1626 behaviour.
    process.stderr.write(`lane-readiness: cannot read registry ${lanesPath}: ${e.message}\n`);
    process.exitCode = 1;
    return;
  }
  let ledgerText = '';
  try {
    ledgerText = readFileSync(ledgerPath(), 'utf8');
  } catch {
    // Missing/unreadable ledger = no evidence of graduation; gated lanes
    // resolve to down (safe: down only ever SKIPS a lane, it never refuses).
  }
  for (const { lane, state } of laneStates(lanesJson, ledgerText)) {
    process.stdout.write(`${lane} ${state}\n`);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
