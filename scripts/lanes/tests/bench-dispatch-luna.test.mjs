// scripts/lanes/tests/bench-dispatch-luna.test.mjs — HIMMEL-1723 P2.3
// --dry-run must print the EXACT argv + env dispatch-luna.sh would use
// without launching anything real. The structural "no telegram spawner in
// this kit's own sources" guard lives in bench-no-telegram-spawner-grep.test.mjs
// (mirrors bench-no-ledger-write.test.mjs's P2.8 guard).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { BASH_BIN } from './lib/resolve-bash.mjs';

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const DISPATCH = join(TEST_DIR, '..', 'bench', 'dispatch-luna.sh');

function makeFixtureTaskDir(promptText) {
  const taskDir = mkdtempSync(join(tmpdir(), 'bench-dispatch-luna-task-'));
  mkdirSync(join(taskDir, 'input'), { recursive: true });
  writeFileSync(join(taskDir, 'input', 'a.txt'), 'hello\n');
  writeFileSync(join(taskDir, 'prompt.md'), promptText);
  return taskDir;
}

test('dispatch-luna.sh --dry-run prints the launcher argv, env, and cwd without launching anything', () => {
  const taskDir = makeFixtureTaskDir('Do the T7 task exactly as described.\n');
  const scratchRoot = mkdtempSync(join(tmpdir(), 'bench-dispatch-luna-scratch-'));
  const out = execFileSync(BASH_BIN, [DISPATCH, taskDir, 'T7-luna-1', '--dry-run'], {
    encoding: 'utf8',
    env: { ...process.env, BENCH_SCRATCH_ROOT: scratchRoot },
  });
  assert.match(out, /DRY-RUN argv: bash .*scripts[\\/]claude-codex --permission-mode dontAsk/);
  assert.match(out, /DRY-RUN env: CODEX_MODEL=gpt-5\.6-luna CLAUDE_CODE_EFFORT_LEVEL=high/);
  assert.match(out, /DRY-RUN cwd: /);
  assert.match(out, /DRY-RUN stdin: closed/);
  // Never the telegram claudex worker-spawner path (structural invariant,
  // spec §2.1-2.2) — the exact substring is defined once, in this test only.
  const spawnerSubstring = ['spawn', 'claudex'].join('-');
  assert.doesNotMatch(out, new RegExp(spawnerSubstring));
});

test('dispatch-luna.sh --dry-run honors an explicit --effort override', () => {
  const taskDir = makeFixtureTaskDir('Task text.\n');
  const scratchRoot = mkdtempSync(join(tmpdir(), 'bench-dispatch-luna-scratch2-'));
  const out = execFileSync(BASH_BIN, [DISPATCH, taskDir, 'T7-luna-1', '--dry-run', '--effort', 'medium'], {
    encoding: 'utf8',
    env: { ...process.env, BENCH_SCRATCH_ROOT: scratchRoot },
  });
  assert.match(out, /CLAUDE_CODE_EFFORT_LEVEL=medium/);
});

test('dispatch-luna.sh refuses when prompt.md is missing', () => {
  const taskDir = mkdtempSync(join(tmpdir(), 'bench-dispatch-luna-noprompt-'));
  mkdirSync(join(taskDir, 'input'), { recursive: true });
  const scratchRoot = mkdtempSync(join(tmpdir(), 'bench-dispatch-luna-scratch3-'));
  assert.throws(() =>
    execFileSync(BASH_BIN, [DISPATCH, taskDir, 'T7-luna-1', '--dry-run'], {
      encoding: 'utf8',
      env: { ...process.env, BENCH_SCRATCH_ROOT: scratchRoot },
    }),
  );
});
