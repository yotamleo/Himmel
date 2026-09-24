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

// LINT, not a behavioural proof (HIMMEL-2726 test audit): this can only catch
// a literal (case/separator-insensitive) mention of the spawner name, never a
// composed/aliased reference (e.g. string concatenation, an indirect require
// path, or a differently-named wrapper around spawn-claudex.ts) — those stay
// green under this check by construction, same as under the original
// single-substring version. The behavioural proof that the bench's actual
// dispatch path never invokes the real spawner is bench-dispatch-luna.test.mjs's
// dry-run ARGV assertion; this file's only job is the broader, cheap net across
// every OTHER file in the kit a dry-run never executes.
test('LINT: no file under scripts/lanes/bench/ mentions the telegram claudex-worker-spawner name, in any case/separator spelling', () => {
  const files = walk(BENCH_DIR);
  assert.ok(files.length > 0, 'expected at least one file under scripts/lanes/bench/');
  // Normalize away case and separators (-, _, ., whitespace) so
  // "spawn_claudex", "Spawn.Claudex", "spawn claudex" etc. also trip the
  // guard, not only the exact "spawn-claudex" spelling the original check
  // matched byte for byte.
  const normalize = (s) => s.toLowerCase().replace(/[-_.\s]+/g, '');
  const forbiddenNormalized = normalize(FORBIDDEN);
  const offenders = [];
  for (const f of files) {
    // fixtures/ (P3, task content) may legitimately be unrelated text; scope
    // the guard to the kit's own scripts, matching the P2.3 invariant it enforces.
    if (f.includes(`${join('bench', 'fixtures')}`)) continue;
    let text;
    try { text = readFileSync(f, 'utf8'); } catch { continue; }
    if (normalize(text).includes(forbiddenNormalized)) offenders.push(f);
  }
  assert.deepEqual(offenders, [], `forbidden substring found in: ${offenders.join(', ')}`);
});
