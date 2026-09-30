// scripts/lanes/tests/funded-max-pct.test.mjs
// HIMMEL-1624 — the LANE_FUNDED_MAX_PCT clamp. Number.isFinite alone accepts
// negatives, which made every live bank read "spent". The parser must require a
// sane 0..100 value and fall back to the default otherwise.
// HIMMEL-1700 — the default is 90, the SAME refuse point spawn-claudex uses, so
// bank-status and the dispatcher can no longer disagree in the 90-98 % band.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DEFAULT_FUNDED_MAX_PCT, parseFundedMaxPct, resolveFundedMaxPct } from '../funded-max-pct.mjs';
import { guardState } from '../bank-status-core.mjs';

test('negative values fall back to 90 (the regression: -1 read every bank as spent)', () => {
  assert.equal(parseFundedMaxPct('-1'), 90);
  assert.equal(parseFundedMaxPct('-0.5'), 90);
});

test('values above 100 fall back to 90', () => {
  assert.equal(parseFundedMaxPct('101'), 90);
  assert.equal(parseFundedMaxPct('999'), 90);
});

test('0 and 100 are accepted at the boundaries', () => {
  assert.equal(parseFundedMaxPct('0'), 0);
  assert.equal(parseFundedMaxPct('100'), 100);
});

test('an in-range threshold is honored', () => {
  assert.equal(parseFundedMaxPct('50'), 50);
  assert.equal(parseFundedMaxPct('99.5'), 99.5);
});

test('non-numeric / empty / undefined fall back to 90 (the documented default)', () => {
  assert.equal(parseFundedMaxPct(undefined), 90);
  assert.equal(parseFundedMaxPct(''), 90);
  assert.equal(parseFundedMaxPct('abc'), 90);
});

test('partially numeric values fall back to 90 (CR round 2: parseFloat accepted them)', () => {
  assert.equal(parseFundedMaxPct('50%'), 90);
  assert.equal(parseFundedMaxPct('0invalid'), 90);
  assert.equal(parseFundedMaxPct(' 50 '), 50); // trimmed whole-string numeric is fine
});

test('resolveFundedMaxPct: default 90; LANE_FUNDED_MAX_PCT wins; CLAUDEX_BANK_REFUSE_PCT is an alias', () => {
  assert.equal(DEFAULT_FUNDED_MAX_PCT, 90);
  assert.equal(resolveFundedMaxPct({}), 90);
  assert.equal(resolveFundedMaxPct({ CLAUDEX_BANK_REFUSE_PCT: '70' }), 70);
  assert.equal(resolveFundedMaxPct({ LANE_FUNDED_MAX_PCT: '60' }), 60);
  assert.equal(resolveFundedMaxPct({ LANE_FUNDED_MAX_PCT: '60', CLAUDEX_BANK_REFUSE_PCT: '70' }), 60);
  // an invalid primary falls through to the alias, an invalid alias to the default
  assert.equal(resolveFundedMaxPct({ LANE_FUNDED_MAX_PCT: 'abc', CLAUDEX_BANK_REFUSE_PCT: '70' }), 70);
  assert.equal(resolveFundedMaxPct({ LANE_FUNDED_MAX_PCT: '', CLAUDEX_BANK_REFUSE_PCT: '-3' }), 90);
});

test('HIMMEL-1700 band: codex weekly at 95% is spent under the shared default (was funded at 99)', () => {
  const active = { ok: true, path: { kind: 'subscription', windows: ['weekly'] } };
  const at95 = { kind: 'measured', readings: [{ window: 'weekly', usedPct: 95 }] };
  assert.equal(guardState(at95, active, resolveFundedMaxPct({})), 'spent');
  assert.equal(guardState({ kind: 'measured', readings: [{ window: 'weekly', usedPct: 89 }] }, active, resolveFundedMaxPct({})), 'funded');
});
