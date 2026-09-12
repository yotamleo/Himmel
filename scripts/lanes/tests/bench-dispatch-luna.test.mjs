// scripts/lanes/tests/bench-dispatch-luna.test.mjs — HIMMEL-1723 P2.3
// --dry-run must print the EXACT argv + env dispatch-luna.sh would use
// without launching anything real. The structural "no telegram spawner in
// this kit's own sources" guard lives in bench-no-telegram-spawner-grep.test.mjs
// (mirrors bench-no-ledger-write.test.mjs's P2.8 guard).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync, chmodSync, existsSync } from 'node:fs';
import { makeTmpDir } from '../../lib/test-tmpdir.mjs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { BASH_BIN } from './lib/resolve-bash.mjs';

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const DISPATCH = join(TEST_DIR, '..', 'bench', 'dispatch-luna.sh');

function makeFixtureTaskDir(promptText) {
  const taskDir = makeTmpDir('bench-dispatch-luna-task-');
  mkdirSync(join(taskDir, 'input'), { recursive: true });
  writeFileSync(join(taskDir, 'input', 'a.txt'), 'hello\n');
  writeFileSync(join(taskDir, 'prompt.md'), promptText);
  return taskDir;
}

test('dispatch-luna.sh --dry-run prints the launcher argv, env, and cwd without launching anything', () => {
  const taskDir = makeFixtureTaskDir('Do the T7 task exactly as described.\n');
  const scratchRoot = makeTmpDir('bench-dispatch-luna-scratch-');
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

test('dispatch-luna.sh --dry-run: child permission flags admit Bash without bypassPermissions', () => {
  const taskDir = makeFixtureTaskDir('Do the T7 task exactly as described.\n');
  const scratchRoot = makeTmpDir('bench-dispatch-luna-scratch-');
  const out = execFileSync(BASH_BIN, [DISPATCH, taskDir, 'T7-luna-1', '--dry-run'], {
    encoding: 'utf8',
    env: { ...process.env, BENCH_SCRATCH_ROOT: scratchRoot },
  });
  assert.doesNotMatch(out, /bypassPermissions/);
  assert.match(out, /DRY-RUN argv: [^\n]*--permission-mode dontAsk[^\n]*(--allowedTools[^\n]*\bBash\b|--settings[^\n]*"Bash")/);
});

test('dispatch-luna.sh --dry-run honors an explicit --effort override', () => {
  const taskDir = makeFixtureTaskDir('Task text.\n');
  const scratchRoot = makeTmpDir('bench-dispatch-luna-scratch2-');
  const out = execFileSync(BASH_BIN, [DISPATCH, taskDir, 'T7-luna-1', '--dry-run', '--effort', 'medium'], {
    encoding: 'utf8',
    env: { ...process.env, BENCH_SCRATCH_ROOT: scratchRoot },
  });
  assert.match(out, /CLAUDE_CODE_EFFORT_LEVEL=medium/);
});

test('dispatch-luna.sh resolves transcript_path to the codex project transcript', () => {
  const taskDir = makeFixtureTaskDir('Do the T-transcript task.\n');
  const scratchRoot = makeTmpDir('bench-dispatch-luna-scratch-transcript-');
  const fakeHome = makeTmpDir('bench-dispatch-luna-fakehome-');
  const stubDir = makeTmpDir('bench-dispatch-luna-stub-');
  const stubLauncher = join(stubDir, 'claude-stub.sh');
  writeFileSync(
    stubLauncher,
    '#!/usr/bin/env bash\n' +
      'set -u\n' +
      'win_path="$(pwd)"\n' +
      'if command -v cygpath >/dev/null 2>&1; then\n' +
      '    cp="$(cygpath -w "$win_path" 2>/dev/null)"\n' +
      '    [ -n "$cp" ] && win_path="$cp"\n' +
      'fi\n' +
      'enc="$(printf \'%s\' "$win_path" | sed \'s/[^a-zA-Z0-9]/-/g\')"\n' +
      'mkdir -p "$HOME/.claude-codex/projects/$enc"\n' +
      ': > "$HOME/.claude-codex/projects/$enc/fake.jsonl"\n' +
      'exit 0\n',
  );
  chmodSync(stubLauncher, 0o755);
  const out = execFileSync(BASH_BIN, [DISPATCH, taskDir, 'T-transcript-1'], {
    encoding: 'utf8',
    env: {
      ...process.env,
      HOME: fakeHome,
      BENCH_SCRATCH_ROOT: scratchRoot,
      BENCH_CLAUDE_CODEX_BIN: stubLauncher,
    },
  });
  const match = out.match(/transcript_path=([^\t\n]*)/);
  assert.ok(match, 'RESULT line missing transcript_path field');
  assert.notEqual(match[1], '-');
  assert.ok(existsSync(match[1]), `expected transcript file to exist at ${match[1]}`);
});

test('dispatch-luna.sh refuses when prompt.md is missing', () => {
  const taskDir = makeTmpDir('bench-dispatch-luna-noprompt-');
  mkdirSync(join(taskDir, 'input'), { recursive: true });
  const scratchRoot = makeTmpDir('bench-dispatch-luna-scratch3-');
  assert.throws(() =>
    execFileSync(BASH_BIN, [DISPATCH, taskDir, 'T7-luna-1', '--dry-run'], {
      encoding: 'utf8',
      env: { ...process.env, BENCH_SCRATCH_ROOT: scratchRoot },
    }),
  );
});
