// scripts/lanes/tests/effort-route.test.mjs — HIMMEL-3997
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { recommend, loadConfig } from '../effort-route.mjs';
import { buildFanoutPlan } from '../fanout-plan.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const FIX = JSON.parse(readFileSync(join(HERE, 'fixtures/effort-routing/records.json'), 'utf8'));
const CFG = loadConfig();
const LIVE = [{ id: 'sonnet', label: 'Sonnet', class: 'claude-tier' }, { id: 'opus', label: 'Opus', class: 'claude-tier' }];

for (const [name, { record, expect }] of Object.entries(FIX)) {
  test(`fixture ${name} matches the threshold table`, () => {
    const r = recommend(record, CFG);
    assert.equal(r.action, expect.action);
    assert.equal(r.effort, expect.effort);
    assert.equal(r.review, expect.review);
  });
}

test('the recommendation never carries a tier', () => {
  for (const { record } of Object.values(FIX)) {
    const r = recommend(record, CFG);
    for (const k of ['tier', 'model', 'lane']) assert.ok(!(k in r), `unexpected key ${k}`);
  }
});

test('plan-first may suggest design; an implement result never does', () => {
  assert.equal(recommend(FIX.too_uncertain.record, CFG).suggest_tier_design, true);
  assert.equal(recommend(FIX.small_sure.record, CFG).suggest_tier_design, false);
});

test('sigma in the unspecified 0.85-1.2 band takes the conservative high+review side', () => {
  const r = recommend({ ...FIX.small_sure.record, sigma: 1.0 }, CFG);
  assert.deepEqual([r.action, r.effort, r.review], ['implement', 'high', true]);
});

test('a refused DoD record is plan-first', () => {
  const r = recommend({ ...FIX.small_sure.record, dod: { passed: false, failed: ['red'] } }, CFG);
  assert.equal(r.action, 'plan-first');
});

test('thresholds come from config: editing them changes the result with no code edit', () => {
  const dir = mkdtempSync(join(tmpdir(), 'effort-route-'));
  const path = join(dir, 'cfg.json');
  writeFileSync(path, JSON.stringify({ ...CFG, medium: { mean_max: 0.5, sigma_max: 0.5 } }));
  const r = recommend(FIX.small_sure.record, loadConfig(path));
  assert.equal(r.effort, 'high');
});

test('fanout: plan-first estimate refuses an implementation item', () => {
  const { plan, errors } = buildFanoutPlan([{ id: 'X', type: 'implementation', estimate: FIX.too_uncertain.record }], LIVE);
  assert.deepEqual(plan, []);
  assert.match(errors[0], /plan-first/);
});

test('fanout: an implement estimate adds advisory fields and leaves item.effort alone', () => {
  const { plan, errors } = buildFanoutPlan([{ id: 'X', type: 'implementation', effort: 'low', estimate: FIX.g1_guard.record }], LIVE);
  assert.deepEqual(errors, []);
  assert.equal(plan[0].effort, 'low');
  assert.equal(plan[0].recommended_effort, 'high');
  assert.equal(plan[0].review, true);
  assert.ok(plan[0].advisory);
});

test('fanout: items without an estimate behave exactly as before', () => {
  const { plan, errors } = buildFanoutPlan([{ id: 'X', type: 'implementation' }], LIVE);
  assert.deepEqual(errors, []);
  assert.deepEqual(Object.keys(plan[0]).sort(), ['destructive', 'effort', 'id', 'label', 'lane', 'model', 'type', 'why']);
});

test('fanout: a plan-first estimate does not refuse non-implementation items', () => {
  const { errors } = buildFanoutPlan([{ id: 'R', type: 'reasoning', estimate: FIX.too_uncertain.record }], LIVE);
  assert.deepEqual(errors, []);
});
