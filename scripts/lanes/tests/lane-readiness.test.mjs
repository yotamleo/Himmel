// Tests for scripts/lanes/lane-readiness.mjs (HIMMEL-1626).
// Hermetic: registry and ledger content are in-memory values — nothing touches
// the real registry, ledger, or repo. Run: node --test "scripts/lanes/tests/**/*.test.mjs"
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { trailingPasses, laneStates } from '../lane-readiness.mjs';

// Build one verify-return end-row as verify-return.mjs writes it; only the
// fields the probe reads are load-bearing.
function row(note, extra = {}) {
  return JSON.stringify({
    v: 1, ev: 'end', flow: 'verify-return',
    run_id: 'verify-return-20260807T0700-1', ended_at: '2026-08-07T07:00:00Z',
    exit_code: note.startsWith('PASS') ? 0 : 1,
    outcome: note.startsWith('PASS') ? 'complete' : 'error',
    items_processed: null, note, ...extra,
  });
}

const pass = (branch) => row(`PASS HIMMEL-1 ${branch}`);
const failed = (branch) => row(`FAILED HIMMEL-1 ${branch} no-pr`);

function gated(id, passesRequired) {
  return { id, readiness: { passesRequired } };
}

test('trailing consecutive passes count from the tail, FAILED resets', () => {
  const ledger = [pass('glm/a'), pass('glm/b'), failed('glm/c'), pass('glm/d'), pass('glm/e')].join('\n');
  assert.equal(trailingPasses(ledger, 'glm'), 2);
});

test('rows of other lanes and other flows never count', () => {
  const ledger = [
    pass('claudex/a'),
    row('PASS HIMMEL-1 glm/x', { flow: 'other-flow' }),
    row('PASS HIMMEL-1 glm/y', { ev: 'start' }),
    pass('glm/z'),
  ].join('\n');
  assert.equal(trailingPasses(ledger, 'glm'), 1);
  assert.equal(trailingPasses(ledger, 'claudex'), 1);
});

test('lane attribution is a branch-PREFIX match: glm-subagent/x is not glm', () => {
  const ledger = [pass('glm-subagent/x'), pass('glm/x')].join('\n');
  assert.equal(trailingPasses(ledger, 'glm'), 1);
});

test('malformed lines (partial appends) and malformed notes are skipped', () => {
  const ledger = [pass('glm/a'), '{"v":1,"ev":"end","flow":"verify-re', row('gibberish note'), pass('glm/b')].join('\n');
  assert.equal(trailingPasses(ledger, 'glm'), 2);
});

test('empty or absent ledger text counts zero', () => {
  assert.equal(trailingPasses('', 'glm'), 0);
  assert.equal(trailingPasses(null, 'glm'), 0);
});

test('an ungated lane is always ready, even with an empty ledger', () => {
  const states = laneStates({ lanes: [{ id: 'sonnet' }] }, '');
  assert.deepEqual(states, [{ lane: 'sonnet', state: 'ready' }]);
});

test('a gated lane with no evidence is down', () => {
  const states = laneStates({ lanes: [gated('glm', 10)] }, '');
  assert.deepEqual(states, [{ lane: 'glm', state: 'down' }]);
});

test('a gated lane graduates at exactly passesRequired trailing passes', () => {
  const nine = Array.from({ length: 9 }, (_, i) => pass(`glm/w${i}`)).join('\n');
  const ten = nine + '\n' + pass('glm/w9');
  assert.equal(laneStates({ lanes: [gated('glm', 10)] }, nine)[0].state, 'down');
  assert.equal(laneStates({ lanes: [gated('glm', 10)] }, ten)[0].state, 'ready');
});

test('a FAILED row mid-streak keeps a gated lane down', () => {
  const ledger = [pass('glm/a'), pass('glm/b'), failed('glm/c'), pass('glm/d')].join('\n');
  assert.equal(laneStates({ lanes: [gated('glm', 2)] }, ledger)[0].state, 'down');
});

test('gates are per-lane: one lane down never affects the other', () => {
  const ledger = [pass('claudex/a'), pass('claudex/b')].join('\n');
  const states = laneStates({ lanes: [gated('claudex', 2), gated('glm', 2)] }, ledger);
  assert.deepEqual(states, [
    { lane: 'claudex', state: 'ready' },
    { lane: 'glm', state: 'down' },
  ]);
});

test('a malformed gate (zero, negative, NaN, non-number) never downs a lane', () => {
  const registry = {
    lanes: [gated('a', 0), gated('b', -3), gated('c', NaN), gated('d', 'ten'), { id: 'e', readiness: {} }],
  };
  for (const s of laneStates(registry, '')) assert.equal(s.state, 'ready');
});

test('a registry without a lanes array yields no states', () => {
  assert.deepEqual(laneStates({}, ''), []);
  assert.deepEqual(laneStates(null, ''), []);
});
