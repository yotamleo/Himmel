// scripts/lanes/tests/fanout-plan.test.mjs — HIMMEL-1829
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildFanoutPlan } from '../fanout-plan.mjs';

const LIVE = [
  { id: 'haiku', label: 'Haiku', class: 'claude-tier' },
  { id: 'sonnet', label: 'Sonnet 5', class: 'claude-tier' },
  { id: 'opus', label: 'Opus 4.8', class: 'claude-tier' },
  { id: 'fable', label: 'Fable 5', class: 'claude-tier' },
  { id: 'claudex', label: 'claudex lane', class: 'impl', dormant: { reason: 'dormant pending the lane rethink', optInEnv: 'CLAUDEX_LANE_OK' } },
  { id: 'glm', label: 'GLM lane', class: 'impl', dormant: { reason: 'lane dropped by operator ruling 2026-08-19', optInEnv: 'GLM_LANE_OK' } },
  { id: 'hermes-critics', label: 'hermes critics', class: 'critic' },
  // A hypothetical ACTIVE (non-dormant) impl lane — none exist on the real
  // registry today, but the class check must refuse this independently of
  // dormancy (codex CR, HIMMEL-1829 bundle round): an impl-class lane id is
  // not a value the Agent tool's model param accepts, so /fanout must never
  // route implementation work there regardless of availability.
  { id: 'hypothetical-impl', label: 'hypothetical impl lane', class: 'impl' },
];

test('happy path — one item per type resolves to the invariant tier with an explicit model', () => {
  const items = [
    { id: 'A', type: 'judgement' },
    { id: 'B', type: 'reasoning' },
    { id: 'C', type: 'research' },
    { id: 'D', type: 'bulk' },
    { id: 'E', type: 'implementation' },
  ];
  const { plan, errors } = buildFanoutPlan(items, LIVE);
  assert.deepEqual(errors, []);
  // implementation defaults to Sonnet — impl routes to native Claude
  // subagents only (operator ruling 2026-08-19, HIMMEL-1967); the class:"impl"
  // lanes on this machine are all dormant.
  assert.deepEqual(plan.map((p) => p.lane), ['fable', 'opus', 'sonnet', 'haiku', 'sonnet']);
  for (const p of plan) {
    assert.ok(p.model, `${p.id} must name an explicit model`);
    // `model` must be the dispatchable lane id (what the Agent tool's model
    // param accepts), not the human-readable label — a prior draft emitted
    // the label here, which the Agent tool would reject verbatim.
    assert.equal(p.model, p.lane, `${p.id}: model must equal the dispatchable lane id, not the label`);
    assert.ok(p.label, `${p.id} must also carry a human-readable label`);
  }
});

test('destructive item routed below judgement is REFUSED, not downgraded', () => {
  const { plan, errors } = buildFanoutPlan(
    [{ id: 'cleanup', type: 'implementation', destructive: true }],
    LIVE,
  );
  assert.deepEqual(plan, []);
  assert.match(errors[0], /REFUSED/);
  assert.match(errors[0], /judgement/);
});

test('destructive + judgement is allowed (the correct route)', () => {
  const { plan, errors } = buildFanoutPlan([{ id: 'cleanup', type: 'judgement', destructive: true }], LIVE);
  assert.deepEqual(errors, []);
  assert.equal(plan[0].lane, 'fable');
});

test('unknown type is refused, not silently inherited', () => {
  const { plan, errors } = buildFanoutPlan([{ id: 'x' }], LIVE);
  assert.deepEqual(plan, []);
  assert.match(errors[0], /unknown or missing type/);
});

test('lane not in the live roster is refused (never a hardcoded lane list)', () => {
  const { plan, errors } = buildFanoutPlan(
    [{ id: 'x', type: 'implementation', lane: 'codex-exec' }],
    LIVE, // codex-exec deliberately absent — simulates it being unavailable on this machine
  );
  assert.deepEqual(plan, []);
  assert.match(errors[0], /not in the LIVE roster/);
});

test('implementation lane must be class "claude-tier", not e.g. a critic lane', () => {
  const { plan, errors } = buildFanoutPlan(
    [{ id: 'x', type: 'implementation', lane: 'hermes-critics' }],
    LIVE,
  );
  assert.deepEqual(plan, []);
  assert.match(errors[0], /only routes to claude-tier lanes/);
});

test('an impl-class lane is refused for implementation work even when NOT dormant (HIMMEL-1967)', () => {
  const { plan, errors } = buildFanoutPlan(
    [{ id: 'x', type: 'implementation', lane: 'hypothetical-impl' }],
    LIVE,
  );
  assert.deepEqual(plan, []);
  assert.match(errors[0], /only routes to claude-tier lanes/);
});

test('a dormant lane is refused even though it is present in the live roster (HIMMEL-1967)', () => {
  const { plan, errors } = buildFanoutPlan(
    [{ id: 'x', type: 'implementation', lane: 'claudex' }],
    LIVE,
  );
  assert.deepEqual(plan, []);
  assert.match(errors[0], /is dormant/);
});

test('bulk item requesting further spawning is refused — Haiku does not spawn', () => {
  const { plan, errors } = buildFanoutPlan([{ id: 'x', type: 'bulk', spawnsChildren: true }], LIVE);
  assert.deepEqual(plan, []);
  assert.match(errors[0], /does NOT spawn/);
});
