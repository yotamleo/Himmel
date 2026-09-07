// scripts/lanes/tests/bench-no-telegram-spawner-grep.test.mjs — HIMMEL-1723 P2.3
// Structural guard (mirrors bench-no-ledger-write.test.mjs's P2.8 guard):
// the Telegram worker spawner for the claudex lane (scripts/telegram/
// spawn-claudex.ts) composes a worker-identity preamble into the prompt,
// refuses a non-himmel cwd, mints a git worktree + branch, and instructs the
// model to commit — every one of those biases or breaks this bench (spec
// §2.1). dispatch-luna.sh's own dry-run test proves the ARGV it actually
// builds; this test proves the invariant holds across every file in the kit,
// not just the path exercised by dry-run.
//
// The forbidden substring is assembled at runtime so this file itself never
// contains the literal string either — nothing here should be mistaken for
// evidence the pattern is safe to write inside scripts/lanes/bench/.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const BENCH_DIR = join(TEST_DIR, '..', 'bench');
const FORBIDDEN = ['spawn', 'claudex'].join('-');

function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(full));
    else out.push(full);
  }
  return out;
}

test('no file under scripts/lanes/bench/ contains the telegram claudex-worker-spawner substring', () => {
  const files = walk(BENCH_DIR);
  assert.ok(files.length > 0, 'expected at least one file under scripts/lanes/bench/');
  const offenders = [];
  for (const f of files) {
    // fixtures/ (P3, task content) may legitimately be unrelated text; scope
    // the guard to the kit's own scripts, matching the P2.3 invariant it enforces.
    if (f.includes(`${join('bench', 'fixtures')}`)) continue;
    let text;
    try { text = readFileSync(f, 'utf8'); } catch { continue; }
    if (text.includes(FORBIDDEN)) offenders.push(f);
  }
  assert.deepEqual(offenders, [], `forbidden substring found in: ${offenders.join(', ')}`);
});
