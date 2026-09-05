// scripts/lanes/fanout-plan.mjs
// HIMMEL-1829 — deterministic work-type -> lane routing for /fanout.
//
// Fan-out has been a per-dispatch HABIT, not a primitive: /overnight-shift
// dispatches with no model named at all, and a destructive worktree cleanup
// was once fanned out to Sonnet (judgement/irreversible work belongs at
// Fable). buildFanoutPlan() is the REFUSAL mechanism — it throws no
// exceptions, it just reports every violation as an error and never emits a
// plan entry for a bad route, so a command built on top of this cannot
// silently dispatch one.
//
// The routing table below restates the CLAUDE.md "Subagent policy" invariant
// (judgement/destructive -> Fable; multi-step reasoning -> Opus; scoped
// read-only research -> Sonnet; bulk mechanical -> Haiku, never spawns
// further; well-specified implementation -> Sonnet by default — impl routes
// to native Claude subagents only, operator ruling 2026-08-19, HIMMEL-1967).
// It is fixed on purpose — the whole point is that tier selection stops being
// improvised per dispatch.
//
// A caller MAY still name an explicit `lane` for implementation work, but it
// must be a claude-tier lane — impl-class lanes are never a valid /fanout
// destination (HIMMEL-1967: impl routes to native Claude subagents only), so
// there's no need to special-case dormancy for them; a claude-tier lane the
// live roster (resolve.mjs --json) marks `dormant` is refused outright too —
// dormant is a policy closure, not merely "unavailable".
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));

const TYPE_LANE = { judgement: 'fable', reasoning: 'opus', research: 'sonnet', bulk: 'haiku', implementation: 'sonnet' };
const TYPES = new Set(Object.keys(TYPE_LANE));

// buildFanoutPlan(items, liveLanes) -> { plan, errors }. Pure — no I/O, no
// process.env. `liveLanes` is the array resolve.mjs --json would print (the
// live roster); a lane id not present there can never appear in `plan`.
export function buildFanoutPlan(items, liveLanes) {
  const byId = new Map((liveLanes ?? []).map((l) => [l.id, l]));
  const plan = [];
  const errors = [];

  for (const item of items ?? []) {
    const id = item?.id ?? '(unnamed item)';
    const type = item?.type;
    const destructive = Boolean(item?.destructive);

    if (!TYPES.has(type)) {
      errors.push(`${id}: unknown or missing type ${JSON.stringify(type)} (must be one of ${[...TYPES].join(', ')})`);
      continue;
    }
    // The specific defect HIMMEL-1829 fixes: destructive/irreversible work
    // routed anywhere but the judgement tier is an ERROR, not a downgrade.
    if (destructive && type !== 'judgement') {
      errors.push(`${id}: destructive/irreversible item routed to '${type}' — REFUSED. Destructive or irreversible work must be type 'judgement' (routes to Fable).`);
      continue;
    }
    if (type === 'bulk' && item?.spawnsChildren) {
      errors.push(`${id}: bulk/Haiku item requests further spawning — Haiku does NOT spawn further.`);
      continue;
    }

    const laneId = type === 'implementation' ? (item?.lane || TYPE_LANE.implementation) : TYPE_LANE[type];
    const lane = byId.get(laneId);
    if (!lane) {
      errors.push(`${id}: lane '${laneId}' is not in the LIVE roster on this machine (run /lanes) — refusing to route to an unavailable lane.`);
      continue;
    }
    // Dormant is a POLICY closure (HIMMEL-1967: impl routes to native Claude
    // subagents only), not merely "unavailable" — refuse regardless of type,
    // never route around it just because the lane's own probe still passes.
    if (lane.dormant) {
      errors.push(`${id}: lane '${laneId}' is dormant (${lane.dormant.reason}) — refusing to route fan-out work there.`);
      continue;
    }
    // impl-class lanes are NEVER a valid /fanout destination, dormant or not
    // (HIMMEL-1967: impl routes to native Claude subagents only) — every
    // plan entry, including an explicit override, must land on a
    // claude-tier lane, whose id IS the Agent tool's dispatchable model.
    if (lane.class !== 'claude-tier') {
      errors.push(`${id}: lane '${laneId}' is class '${lane.class}' — /fanout only routes to claude-tier lanes (impl routes to native Claude subagents only, HIMMEL-1967).`);
      continue;
    }

    // Every emitted item names an explicit model — never blank, never
    // "inherit". `model` is DISPATCHABLE (claude-tier lane ids ARE the Agent
    // tool's model enum: sonnet/opus/haiku/fable), not the human-readable
    // `lane.label` — a prior draft emitted the label here, which the Agent
    // tool's model param would reject verbatim (codex CR, HIMMEL-1829 bundle
    // round).
    plan.push({ id, type, destructive, lane: laneId, model: laneId, label: lane.label, effort: item?.effort || 'medium', why: item?.why || '' });
  }
  return { plan, errors };
}

function readItems(path) {
  const raw = path ? readFileSync(path, 'utf8') : readFileSync(0, 'utf8');
  const items = JSON.parse(raw);
  if (!Array.isArray(items)) throw new Error('items must be a JSON array');
  return items;
}

function liveLaneRoster() {
  const out = execFileSync(process.execPath, [join(SCRIPT_DIR, 'resolve.mjs'), '--json'], { encoding: 'utf8' });
  return JSON.parse(out);
}

// --- CLI ---
if (process.argv[1]?.endsWith('fanout-plan.mjs')) {
  let items;
  try { items = readItems(process.argv[2]); }
  catch (e) { process.stderr.write(`fanout-plan: cannot read items — ${e.message}\n`); process.exit(2); }

  const { plan, errors } = buildFanoutPlan(items, liveLaneRoster());
  if (errors.length > 0) {
    process.stderr.write('fanout-plan: REFUSED — fix the items and re-run:\n' + errors.map((e) => `  - ${e}`).join('\n') + '\n');
    process.exit(1);
  }
  process.stdout.write(JSON.stringify(plan, null, 2) + '\n');
  process.exit(0);
}
