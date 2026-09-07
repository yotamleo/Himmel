// scripts/lanes/tests/bench-no-ledger-write.test.mjs — HIMMEL-1723 P2.8
// Hard constraint (spec §6.4): the kit must NEVER write
// ~/.himmel/flow-runs.jsonl. That is the live lane-readiness ledger;
// synthetic bench rows would corrupt lane-readiness.mjs's trailing-PASS
// streak and could wrongly graduate the real claudex lane past its
// passesRequired: 5 probation gate. This test greps every file under
// scripts/lanes/bench/ for the literal ledger filename and fails if present.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const BENCH_DIR = join(TEST_DIR, '..', 'bench');
const FORBIDDEN = 'flow-runs.jsonl';

function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(full));
    else out.push(full);
  }
  return out;
}

test('no file under scripts/lanes/bench/ references the flow-runs.jsonl ledger path', () => {
  const files = walk(BENCH_DIR);
  assert.ok(files.length > 0, 'expected at least one file under scripts/lanes/bench/');
  const offenders = [];
  for (const f of files) {
    let text;
    try { text = readFileSync(f, 'utf8'); } catch { continue; }
    if (text.includes(FORBIDDEN)) offenders.push(f);
  }
  assert.deepEqual(offenders, [], `ledger path referenced in: ${offenders.join(', ')}`);
});
