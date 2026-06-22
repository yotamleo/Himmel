// scripts/where-are-we/tests/provision.cli.test.mjs — tests for provision.mjs
// main()/parseArgs. Uses a real temp-file ledger + the real readRecords/
// appendRecords (hermetic — local fs only, no network). The CLI entry is not
// exercised here (same convention as index.mjs / collect.mjs / dock.mjs).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseArgs, main } from '../provision.mjs';
import { readRecords } from '../lib/ledger.mjs';
import { UsageError } from '../lib/errors.mjs';

const NOW = '2026-06-22T12:00:00Z';

function withLedger(seedLines) {
  const dir = mkdtempSync(join(tmpdir(), 'wa-l3-'));
  const ledger = join(dir, 'ledger.jsonl');
  if (seedLines != null) writeFileSync(ledger, seedLines);
  return { dir, ledger, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

// --- parseArgs ---------------------------------------------------------------
test('parseArgs: verb is argv[0]; --for sets key; lists split on ;', () => {
  const a = parseArgs(['emit', '--key', 'HIMMEL-1', '--blockers', 'a; b ;', '--now', NOW]);
  assert.equal(a.verb, 'emit');
  assert.equal(a.key, 'HIMMEL-1');
  assert.deepEqual(a.blockers, ['a', 'b']); // trimmed, empties dropped
  assert.equal(a.now, NOW);
});

test('parseArgs: slice --for sets key', () => {
  assert.equal(parseArgs(['slice', '--for', 'HIMMEL-9']).key, 'HIMMEL-9');
});

// --- slice -------------------------------------------------------------------
test('slice: seeded substantive ledger → card on stdout', () => {
  const L = withLedger(JSON.stringify({ ts: NOW, source: 'jira', key: 'HIMMEL-9', kind: 'ticket', status: 'in-progress' }) + '\n');
  try {
    const out = main(['slice', '--ledger', L.ledger, '--for', 'HIMMEL-9'], { readRecords });
    assert.match(out, /# HIMMEL-9/);
    assert.match(out, /- status: in-progress/);
  } finally { L.cleanup(); }
});

test('slice: empty/absent ledger → empty string', () => {
  const L = withLedger(null); // no file written
  try {
    assert.equal(main(['slice', '--ledger', L.ledger, '--for', 'HIMMEL-9'], { readRecords }), '');
  } finally { L.cleanup(); }
});

test('slice: missing --for → UsageError', () => {
  const L = withLedger('');
  try {
    assert.throws(() => main(['slice', '--ledger', L.ledger], { readRecords }), UsageError);
  } finally { L.cleanup(); }
});

test('slice: malformed ledger → fail-open empty string (not a throw)', () => {
  const L = withLedger('{"ts":"x","source":"jira"  <-- bad json\n');
  try {
    assert.equal(main(['slice', '--ledger', L.ledger, '--for', 'HIMMEL-9'], { readRecords }), '');
  } finally { L.cleanup(); }
});

// --- emit (real append + read-back) ------------------------------------------
test('emit: --blockers appends 1; slice reads them back', () => {
  const L = withLedger('');
  try {
    const summary = main(['emit', '--ledger', L.ledger, '--key', 'HIMMEL-1', '--blockers', 'waiting on VM; cred'], {});
    assert.equal(summary, 'appended=1 dropped=0');
    const out = main(['slice', '--ledger', L.ledger, '--for', 'HIMMEL-1'], { readRecords });
    assert.match(out, /- blockers: waiting on VM; cred/);
  } finally { L.cleanup(); }
});

test('emit: --clear-blockers after a set → slice no longer shows blockers', () => {
  const L = withLedger('');
  try {
    main(['emit', '--ledger', L.ledger, '--key', 'HIMMEL-1', '--blockers', 'x', '--now', '2026-06-22T10:00:00Z'], {});
    main(['emit', '--ledger', L.ledger, '--key', 'HIMMEL-1', '--clear-blockers', '--now', '2026-06-22T11:00:00Z'], {});
    const out = main(['slice', '--ledger', L.ledger, '--for', 'HIMMEL-1'], { readRecords });
    assert.doesNotMatch(out, /- blockers:/);
  } finally { L.cleanup(); }
});

test('emit: missing --key → UsageError', () => {
  const L = withLedger('');
  try {
    assert.throws(() => main(['emit', '--ledger', L.ledger, '--blockers', 'x'], {}), UsageError);
  } finally { L.cleanup(); }
});

test('emit: no field flags → UsageError', () => {
  const L = withLedger('');
  try {
    assert.throws(() => main(['emit', '--ledger', L.ledger, '--key', 'HIMMEL-1'], {}), UsageError);
  } finally { L.cleanup(); }
});

test('emit: --next-action + --clear-next → UsageError (conflict)', () => {
  const L = withLedger('');
  try {
    assert.throws(() => main(['emit', '--ledger', L.ledger, '--key', 'HIMMEL-1', '--next-action', 'x', '--clear-next'], {}), UsageError);
  } finally { L.cleanup(); }
});

test('emit: --blockers + --clear-blockers → UsageError (array-flag conflict via CLI)', () => {
  // --blockers goes through parseList (array), a distinct CLI path from
  // --next-action (string) — verify the conflict guard end-to-end through main().
  const L = withLedger('');
  try {
    assert.throws(() => main(['emit', '--ledger', L.ledger, '--key', 'HIMMEL-1', '--blockers', 'x', '--clear-blockers'], {}), UsageError);
  } finally { L.cleanup(); }
});

test('emit: --awaiting + --clear-awaiting → UsageError (array-flag conflict via CLI)', () => {
  const L = withLedger('');
  try {
    assert.throws(() => main(['emit', '--ledger', L.ledger, '--key', 'HIMMEL-1', '--awaiting', 'x', '--clear-awaiting'], {}), UsageError);
  } finally { L.cleanup(); }
});

test('emit: --now seam → emitted record ts equals the passed ISO', () => {
  const L = withLedger('');
  try {
    main(['emit', '--ledger', L.ledger, '--key', 'HIMMEL-1', '--next-action', 'ship', '--now', NOW], {});
    const recs = readRecords(L.ledger);
    assert.equal(recs[0].ts, NOW);
    assert.equal(recs[0].next_action, 'ship');
  } finally { L.cleanup(); }
});

test('emit: --awaiting appends awaiting_operator array (anchors the flag name)', () => {
  const L = withLedger('');
  try {
    const summary = main(['emit', '--ledger', L.ledger, '--key', 'HIMMEL-1', '--awaiting', 'decide X; sign off'], {});
    assert.equal(summary, 'appended=1 dropped=0');
    const recs = readRecords(L.ledger);
    assert.deepEqual(recs[0].awaiting_operator, ['decide X', 'sign off']);
  } finally { L.cleanup(); }
});

// --- verb dispatch -----------------------------------------------------------
test('unknown verb → UsageError', () => {
  assert.throws(() => main(['frobnicate', '--ledger', '/x'], {}), UsageError);
});
