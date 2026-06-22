// scripts/where-are-we/tests/dock.test.mjs — unit tests for lib/dock.mjs (pure)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isStale, freshnessLine, renderDock } from '../lib/dock.mjs';

const HOUR = 3600 * 1000;
const NOW = Date.parse('2026-06-22T12:00:00Z');

// --- isStale -----------------------------------------------------------------
test('isStale: missing marker (null mtime) is stale', () => {
  assert.equal(isStale(null, NOW, 6), true);
});

test('isStale: just under the threshold is fresh', () => {
  assert.equal(isStale(NOW - (6 * HOUR - 1000), NOW, 6), false);
});

test('isStale: exactly at the threshold is fresh (strict >)', () => {
  assert.equal(isStale(NOW - 6 * HOUR, NOW, 6), false);
});

test('isStale: over the threshold is stale', () => {
  assert.equal(isStale(NOW - (6 * HOUR + 1000), NOW, 6), true);
});

// --- freshnessLine -----------------------------------------------------------
test('freshnessLine: null mtime → never refreshed', () => {
  assert.equal(freshnessLine(null, NOW), '_where-are-we · never refreshed_');
});

test('freshnessLine: 0h ago', () => {
  assert.equal(freshnessLine(NOW - 1000, NOW), '_where-are-we · refreshed 0h ago_');
});

test('freshnessLine: 3h ago (floored)', () => {
  assert.equal(freshnessLine(NOW - (3 * HOUR + 59 * 60 * 1000), NOW), '_where-are-we · refreshed 3h ago_');
});

// --- renderDock --------------------------------------------------------------
const recs = (status) => [
  { ts: '2026-01-01T00:00:00Z', source: 'jira', key: 'HIMMEL-9', kind: 'ticket', status },
];

test('renderDock: global scope renders the digest', () => {
  const out = renderDock(recs('in-progress'), { mode: 'global' }, NOW, NOW);
  assert.match(out, /# Where are we/);
  assert.match(out, /## In flight/);
});

test('renderDock: active ticket-branch renders the item card, not the digest', () => {
  // fixture branch MUST match branchToKey ^[a-z]+/(KEY-N)\b
  const out = renderDock(recs('in-progress'), { mode: 'branch', name: 'feat/HIMMEL-9-x' }, NOW, NOW);
  assert.match(out, /# HIMMEL-9/);
  assert.doesNotMatch(out, /# Where are we/);
});

test('renderDock: terminal (done) ticket-branch falls back to the global digest', () => {
  const out = renderDock(recs('done'), { mode: 'branch', name: 'feat/HIMMEL-9-x' }, NOW, NOW);
  assert.match(out, /# Where are we/);
  assert.doesNotMatch(out, /# HIMMEL-9\n/);
});

test('renderDock: terminal (merged) ticket-branch also falls back to the global digest', () => {
  const out = renderDock(recs('merged'), { mode: 'branch', name: 'feat/HIMMEL-9-x' }, NOW, NOW);
  assert.match(out, /# Where are we/);
  assert.doesNotMatch(out, /# HIMMEL-9\n/);
});

test('renderDock: branch with no ticket key (main) → global digest', () => {
  const out = renderDock(recs('in-progress'), { mode: 'branch', name: 'main' }, NOW, NOW);
  assert.match(out, /# Where are we/);
});

test('renderDock: freshness header is the first line', () => {
  const out = renderDock(recs('in-progress'), { mode: 'global' }, NOW, null);
  assert.equal(out.split('\n')[0], '_where-are-we · never refreshed_');
});
