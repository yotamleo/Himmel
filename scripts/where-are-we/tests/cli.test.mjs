// scripts/where-are-we/tests/cli.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { run } from '../index.mjs';

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
