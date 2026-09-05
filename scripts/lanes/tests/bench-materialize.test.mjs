// scripts/lanes/tests/bench-materialize.test.mjs — HIMMEL-1723 P2.2
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { BASH_BIN } from './lib/resolve-bash.mjs';

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const MATERIALIZE = join(TEST_DIR, '..', 'bench', 'materialize.sh');

function makeFixtureTaskDir() {
  const taskDir = mkdtempSync(join(tmpdir(), 'bench-materialize-task-'));
  mkdirSync(join(taskDir, 'input', 'sub'), { recursive: true });
  writeFileSync(join(taskDir, 'input', 'a.txt'), 'hello\n');
  writeFileSync(join(taskDir, 'input', 'sub', 'b.txt'), 'world\n');
  return taskDir;
}

// Recursive checksum of a directory tree (path + content), so a materialize
// bug that mutates the SOURCE fixture is caught even if file counts match.
function treeChecksum(dir) {
  const hash = createHash('sha256');
  function walk(d, rel) {
    const entries = readdirSync(d, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name));
    for (const e of entries) {
      const relPath = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory()) walk(join(d, e.name), relPath);
      else {
        hash.update(relPath);
        hash.update(readFileSync(join(d, e.name)));
      }
    }
  }
  walk(dir, '');
  return hash.digest('hex');
}

function runMaterialize(taskDir, runId, scratchRoot) {
  const out = execFileSync(BASH_BIN, [MATERIALIZE, taskDir, runId], {
    encoding: 'utf8',
    env: { ...process.env, BENCH_SCRATCH_ROOT: scratchRoot },
  });
  return out.trim();
}

test('materialize.sh copies input/ contents to a fresh dir and leaves the source untouched', () => {
  const taskDir = makeFixtureTaskDir();
  const scratchRoot = mkdtempSync(join(tmpdir(), 'bench-materialize-scratch-'));
  const beforeChecksum = treeChecksum(join(taskDir, 'input'));

  const dest = runMaterialize(taskDir, 'T1-luna-1', scratchRoot);
  assert.ok(statSync(dest).isDirectory(), `materialized dest should exist: ${dest}`);
  assert.equal(readFileSync(join(dest, 'a.txt'), 'utf8'), 'hello\n');
  assert.equal(readFileSync(join(dest, 'sub', 'b.txt'), 'utf8'), 'world\n');

  const afterChecksum = treeChecksum(join(taskDir, 'input'));
  assert.equal(afterChecksum, beforeChecksum, 'materialize.sh must never mutate the source fixture');
});

test('two materialize.sh runs produce independent directories', () => {
  const taskDir = makeFixtureTaskDir();
  const scratchRoot = mkdtempSync(join(tmpdir(), 'bench-materialize-scratch2-'));

  const destA = runMaterialize(taskDir, 'T1-luna-1', scratchRoot);
  const destB = runMaterialize(taskDir, 'T1-luna-1', scratchRoot); // same run-id, still independent
  const destC = runMaterialize(taskDir, 'T1-luna-2', scratchRoot);

  assert.notEqual(destA, destB, 'a repeated call for the same run-id must not collide');
  assert.notEqual(destA, destC);

  // Editing one materialized copy must not affect the others.
  writeFileSync(join(destA, 'a.txt'), 'mutated-in-A\n');
  assert.equal(readFileSync(join(destB, 'a.txt'), 'utf8'), 'hello\n');
  assert.equal(readFileSync(join(destC, 'a.txt'), 'utf8'), 'hello\n');
});

test('materialize.sh exits nonzero when the fixture has no input/ dir', () => {
  const taskDir = mkdtempSync(join(tmpdir(), 'bench-materialize-noinput-'));
  const scratchRoot = mkdtempSync(join(tmpdir(), 'bench-materialize-scratch3-'));
  assert.throws(() => runMaterialize(taskDir, 'T1-luna-1', scratchRoot));
});
