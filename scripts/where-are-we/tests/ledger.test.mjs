// scripts/where-are-we/tests/ledger.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, appendFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { appendRecord, readRecords } from '../lib/ledger.mjs';

test('append writes one newline-terminated line per record; read round-trips', () => {
  const dir = mkdtempSync(join(tmpdir(), 'waw-'));
  const p = join(dir, 'ledger.jsonl');
  appendRecord(p, { ts: '2026-06-21T00:00:00Z', source: 'jira', key: 'HIMMEL-1', kind: 'ticket' });
  appendRecord(p, { ts: '2026-06-21T00:01:00Z', source: 'pr', key: '#2', kind: 'pr' });
  const raw = readFileSync(p, 'utf8');
  assert.equal(raw.split('\n').filter(Boolean).length, 2);
  assert.ok(raw.endsWith('\n'));
  const recs = readRecords(p);
  assert.equal(recs.length, 2);
  assert.equal(recs[0].key, 'HIMMEL-1');
  assert.equal(recs[1].kind, 'pr');
});

test('read of absent file returns empty array', () => {
  assert.deepEqual(readRecords(join(mkdtempSync(join(tmpdir(), 'waw-')), 'none.jsonl')), []);
});

test('read tolerates blank lines — actual blank line between records is skipped', () => {
  const dir = mkdtempSync(join(tmpdir(), 'waw-'));
  const p = join(dir, 'l.jsonl');
  // Write two real records with a genuine blank line between them via direct fs write
  appendRecord(p, { ts: 't1', source: 'jira', key: 'K1', kind: 'ticket' });
  appendFileSync(p, '\n'); // inject a genuine blank line
  appendRecord(p, { ts: 't2', source: 'pr', key: 'K2', kind: 'pr' });
  const recs = readRecords(p);
  assert.equal(recs.length, 2);
  assert.equal(recs[0].key, 'K1');
  assert.equal(recs[1].key, 'K2');
});

test('malformed JSON line throws with correct 1-based line number', () => {
  const dir = mkdtempSync(join(tmpdir(), 'waw-'));
  const p = join(dir, 'bad.jsonl');
  appendRecord(p, { ts: 't', source: 'jira', key: 'K', kind: 'ticket' }); // line 1 — valid
  appendFileSync(p, 'not json\n'); // line 2 — malformed
  let thrown = null;
  try {
    readRecords(p);
  } catch (e) {
    thrown = e;
  }
  assert.ok(thrown !== null, 'expected an error to be thrown');
  assert.ok(thrown.message.includes('2'), `expected line number 2 in error message, got: ${thrown.message}`);
});

// HIMMEL-530 Task 3b: readRecords re-throws non-ENOENT errors (no existsSync TOCTOU).
// Reading a directory as a file fails with a non-ENOENT code (EISDIR on POSIX,
// EISDIR/EPERM on Windows) — assert it threw and was NOT swallowed as "absent".
test('read of a path that is a directory re-throws (not treated as absent)', () => {
  const dir = mkdtempSync(join(tmpdir(), 'waw-'));
  let thrown = null;
  try { readRecords(dir); } catch (e) { thrown = e; }
  assert.ok(thrown !== null, 'reading a directory must throw, not return []');
  assert.notEqual(thrown.code, 'ENOENT', 'a directory is not ENOENT — must not be swallowed');
});
