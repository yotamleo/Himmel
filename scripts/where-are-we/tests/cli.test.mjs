// scripts/where-are-we/tests/cli.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { run } from '../index.mjs';
import { UsageError } from '../lib/errors.mjs';

const fix = join(dirname(fileURLToPath(import.meta.url)), 'fixtures', 'sample.jsonl');

test('global md output lists awaiting + in-flight', () => {
  const out = run(['--ledger', fix]);
  assert.ok(out.includes('HIMMEL-2'));
  assert.ok(out.includes('finish fold'));
});

test('--for KEY --json returns that item', () => {
  const out = run(['--ledger', fix, '--for', 'HIMMEL-9', '--json']);
  const obj = JSON.parse(out);
  assert.equal(obj.item.key, 'HIMMEL-9');
});

test('--branch main falls back to global json', () => {
  const obj = JSON.parse(run(['--ledger', fix, '--branch', 'main', '--json']));
  assert.ok(Array.isArray(obj.inFlight));
});

test('--locks renders a Locks section (md)', () => {
  assert.ok(run(['--ledger', fix, '--locks']).includes('## Locks'));
});

test('--for a missing key falls back to the global digest (md)', () => {
  assert.ok(run(['--ledger', fix, '--for', 'NOPE']).includes('## In flight'));
});

test('--for KEY md renders an item-card with status and next', () => {
  const out = run(['--ledger', fix, '--for', 'HIMMEL-9']);
  assert.ok(out.startsWith('# HIMMEL-9'));
  assert.ok(out.includes('status: in-progress'));
  assert.ok(out.includes('next: finish fold'));
});

test('--for KEY md uses the dash fallback when the item has no status', () => {
  const dir = mkdtempSync(join(tmpdir(), 'waw-cli-'));
  const p = join(dir, 'l.jsonl');
  writeFileSync(p, JSON.stringify({ ts: '1', source: 'handover', key: 'HIMMEL-3', kind: 'ticket', next_action: 'do thing' }) + '\n');
  const out = run(['--ledger', p, '--for', 'HIMMEL-3']);
  assert.ok(out.startsWith('# HIMMEL-3'));
  assert.ok(out.includes('status: —'));
  assert.ok(out.includes('next: do thing'));
});

// HIMMEL-530 Task 3: CLI error hygiene — UsageError for expected user-input errors
test('run([]) throws a UsageError with the --ledger-required message', () => {
  let thrown = null;
  try { run([]); } catch (e) { thrown = e; }
  assert.ok(thrown instanceof UsageError, 'missing --ledger must throw UsageError');
  assert.match(thrown.message, /--ledger.*required/i);
});

test('run on a malformed ledger throws a non-UsageError (unexpected runtime error)', () => {
  const dir = mkdtempSync(join(tmpdir(), 'waw-cli-'));
  const p = join(dir, 'bad.jsonl');
  writeFileSync(p, 'not json\n');
  let thrown = null;
  try { run(['--ledger', p]); } catch (e) { thrown = e; }
  assert.ok(thrown !== null, 'malformed ledger must throw');
  assert.ok(!(thrown instanceof UsageError), 'a runtime error must NOT be a UsageError');
});
