// scripts/where-are-we/tests/dock.cli.test.mjs — tests for dock.mjs main()/parseArgs
// via injected deps (no real fs/clock/network). The CLI entry is not exercised
// here (same convention as index.mjs / collect.mjs).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseArgs, main } from '../dock.mjs';

const HOUR = 3600 * 1000;
const NOW = Date.parse('2026-06-22T12:00:00Z');

const rec = { ts: '2026-01-01T00:00:00Z', source: 'jira', key: 'HIMMEL-9', kind: 'ticket', status: 'in-progress' };
const deps = (over = {}) => ({
  statMtime: () => NOW - 1000,        // fresh by default
  readRecords: () => [rec],
  now: NOW,
  ...over,
});

const argv = (o) => {
  const a = ['--ledger', o.ledger ?? '/x/ledger.jsonl', '--marker', o.marker ?? '/x/.refreshed-at'];
  if (o.branch !== undefined) a.push('--branch', o.branch);
  if (o.staleHours !== undefined) a.push('--stale-hours', String(o.staleHours));
  return a;
};

// --- parseArgs ---------------------------------------------------------------
test('parseArgs: --stale-hours 0 clamps to 1', () => {
  assert.equal(parseArgs(['--stale-hours', '0']).staleHours, 1);
});

test('parseArgs: --stale-hours default is 6', () => {
  assert.equal(parseArgs([]).staleHours, 6);
});

test('parseArgs: --now ISO string parses to ms', () => {
  assert.equal(parseArgs(['--now', '2026-06-22T12:00:00Z']).now, NOW);
});

test('parseArgs: --now integer-ms string parses to ms', () => {
  assert.equal(parseArgs(['--now', String(NOW)]).now, NOW);
});

// --- main --------------------------------------------------------------------
test('main: global scope → digest, fresh marker → not stale', () => {
  const r = main(argv({}), deps());
  assert.match(r.text, /# Where are we/);
  assert.equal(r.stale, false);
});

test('main: active ticket-branch → item card', () => {
  const r = main(argv({ branch: 'feat/HIMMEL-9-x' }), deps());
  assert.match(r.text, /# HIMMEL-9/);
  assert.doesNotMatch(r.text, /# Where are we/);
});

test('main: empty branch → global digest', () => {
  const r = main(argv({ branch: '' }), deps());
  assert.match(r.text, /# Where are we/);
});

test('main: stale marker → stale true', () => {
  const r = main(argv({}), deps({ statMtime: () => NOW - 10 * HOUR }));
  assert.equal(r.stale, true);
});

test('main: missing marker → stale true + never-refreshed header', () => {
  const r = main(argv({}), deps({ statMtime: () => null }));
  assert.equal(r.stale, true);
  assert.match(r.text, /never refreshed/);
});

test('main: malformed/unreadable ledger → fail-open {text:"", stale:true} (heal)', () => {
  const r = main(argv({}), deps({ readRecords: () => { throw new Error('malformed JSON'); } }));
  assert.equal(r.text, '');
  assert.equal(r.stale, true);
});
