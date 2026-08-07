// scripts/lanes/tests/funded-max-pct.test.mjs
// HIMMEL-1624 — the LANE_FUNDED_MAX_PCT clamp. Number.isFinite alone accepts
// negatives, which made every live bank read "spent". The parser must require a
// sane 0..100 value and fall back to 99 otherwise.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseFundedMaxPct } from '../funded-max-pct.mjs';

test('negative values fall back to 99 (the regression: -1 read every bank as spent)', () => {
  assert.equal(parseFundedMaxPct('-1'), 99);
  assert.equal(parseFundedMaxPct('-0.5'), 99);
});

test('values above 100 fall back to 99', () => {
  assert.equal(parseFundedMaxPct('101'), 99);
  assert.equal(parseFundedMaxPct('999'), 99);
});

test('0 and 100 are accepted at the boundaries', () => {
  assert.equal(parseFundedMaxPct('0'), 0);
  assert.equal(parseFundedMaxPct('100'), 100);
});

test('an in-range threshold is honored', () => {
  assert.equal(parseFundedMaxPct('50'), 50);
  assert.equal(parseFundedMaxPct('99.5'), 99.5);
});

test('non-numeric / empty / undefined fall back to 99 (the documented default)', () => {
  assert.equal(parseFundedMaxPct(undefined), 99);
  assert.equal(parseFundedMaxPct(''), 99);
  assert.equal(parseFundedMaxPct('abc'), 99);
});

test('partially numeric values fall back to 99 (CR round 2: parseFloat accepted them)', () => {
  assert.equal(parseFundedMaxPct('50%'), 99);
  assert.equal(parseFundedMaxPct('0invalid'), 99);
  assert.equal(parseFundedMaxPct(' 50 '), 50); // trimmed whole-string numeric is fine
});
