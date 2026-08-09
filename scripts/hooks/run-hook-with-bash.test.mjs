import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, isAbsolute, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const { isKnownBadWindowsBash, isUsable, resolveBash } = require('./run-hook-with-bash.js');
const HERE = dirname(fileURLToPath(import.meta.url));
const LAUNCHER = join(HERE, 'run-hook-with-bash.js');

const norm = (value) => String(value).replace(/\\/g, '/');

test('Windows resolver refuses WSL and WindowsApps bash aliases', () => {
  assert.equal(isKnownBadWindowsBash('C:\\Windows\\System32\\bash.exe'), true);
  assert.equal(isKnownBadWindowsBash('C:\\Windows\\Sysnative\\bash.exe'), true);
  assert.equal(isKnownBadWindowsBash('C:\\Users\\u\\AppData\\Local\\Microsoft\\WindowsApps\\bash.exe'), true);
  assert.equal(isKnownBadWindowsBash('C:\\Program Files\\Git\\bin\\bash.exe'), false);
});

test('Windows resolver refuses zero-byte alias files outside WindowsApps', () => {
  const dir = mkdtempSync(join(tmpdir(), 'hook-bash-zero-byte-'));
  const alias = join(dir, 'bash.exe');
  try {
    writeFileSync(alias, '');
    assert.equal(isUsable(alias, 'win32'), false);
    writeFileSync(alias, 'not empty');
    assert.equal(isUsable(alias, 'win32'), true);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('Windows resolver selects Git Bash even when bad aliases lead PATH', () => {
  const gitBash = 'C:/Tools/Git/bin/bash.exe';
  const usable = new Set([gitBash.toLowerCase()]);
  const resolved = resolveBash({
    platform: 'win32',
    env: { PATH: 'C:\\Windows\\System32;C:\\Users\\u\\AppData\\Local\\Microsoft\\WindowsApps;C:\\Tools\\Git\\cmd' },
    isUsable: (candidate) => usable.has(norm(candidate).toLowerCase()),
  });
  assert.equal(resolved, gitBash);
});

test('Windows resolver fails closed when only bad aliases are available', () => {
  const resolved = resolveBash({
    platform: 'win32',
    env: { PATH: 'C:\\Windows\\System32;C:\\Users\\u\\AppData\\Local\\Microsoft\\WindowsApps' },
    isUsable: (candidate) => !isKnownBadWindowsBash(candidate) && false,
  });
  assert.equal(resolved, null);
});

test('non-Windows resolver preserves PATH order before system fallbacks', () => {
  const resolved = resolveBash({
    platform: 'darwin',
    env: { PATH: '/opt/homebrew/bin:/usr/local/bin' },
    isUsable: (candidate) => candidate === '/opt/homebrew/bin/bash' || candidate === '/bin/bash',
  });
  assert.equal(resolved, '/opt/homebrew/bin/bash');
});

test('current platform resolves a concrete Bash executable', () => {
  const resolved = resolveBash();
  assert.ok(resolved);
  assert.equal(isAbsolute(resolved), true);
  if (process.platform === 'win32') assert.equal(isKnownBadWindowsBash(resolved), false);
});

test('launcher executes a hook through the resolved Bash and forwards extra args', () => {
  const dir = mkdtempSync(join(tmpdir(), 'hook-bash-launcher-'));
  const hook = join(dir, 'hook.sh');
  try {
    writeFileSync(hook, '#!/usr/bin/env bash\nprintf \'HOOK_FIRED:%s\\n\' "$BASH_VERSION"\nprintf \'ARGS:%s|%s\\n\' "$1" "$2"\n');
    chmodSync(hook, 0o755);
    const result = spawnSync(process.execPath, [LAUNCHER, hook, 'alpha', 'two words'], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /^HOOK_FIRED:\d+\./);
    assert.match(result.stdout, /ARGS:alpha\|two words/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('--optional exits zero before Bash resolution when the hook is absent', () => {
  const missing = join(tmpdir(), 'missing-optional-hook.sh');
  const result = spawnSync(process.execPath, [LAUNCHER, '--optional', missing], {
    encoding: 'utf8',
    env: {},
  });
  assert.equal(result.status, 0, result.stderr);
});

// HIMMEL-1649 [codex-adv-1]: a DELETED guard must not silently pass in a
// DISPATCHED WORKER. `--optional` alone exits 0 on a missing script, so a worker
// holding Edit(<worktree>/**) + Bash(node *) could remove the guard in one
// command and disable it for every later tool call. A worker cannot strip the
// marker either — a tool-call child cannot edit the harness process env — so
// under the marker a deleted hook bricks the worker, which is the correct
// outcome for tampering.
test('a missing guard fails closed in a dispatched worker', () => {
  const missing = join(tmpdir(), 'block-glm-external-writes.sh');
  const result = spawnSync(
    process.execPath,
    [LAUNCHER, '--optional', '--fail-closed-when', 'HIMMEL_GLM_WORKER=1', missing],
    { encoding: 'utf8', env: { HIMMEL_GLM_WORKER: '1' } }
  );
  assert.equal(result.status, 2);
  assert.equal(
    result.stderr,
    'block-glm-external-writes: hook script missing while HIMMEL_GLM_WORKER=1 (stale checkout?) - failing closed\n'
  );
});

// The other half, and the round-6 regression this keying exists to prevent: an
// INTERACTIVE GLM session (claude-glm, whose documented primary workload runs
// with cwd in the luna vault) has no himmel scripts/ tree, so the hook is
// legitimately absent. Keying on the provider instead of worker-ness denied
// every Bash/PowerShell/MCP call there. The marker is absent, so it must pass —
// even with the GLM provider env set.
test('a missing guard still passes in an interactive GLM session', () => {
  const missing = join(tmpdir(), 'block-glm-external-writes.sh');
  const result = spawnSync(
    process.execPath,
    [LAUNCHER, '--optional', '--fail-closed-when', 'HIMMEL_GLM_WORKER=1', missing],
    { encoding: 'utf8', env: { ANTHROPIC_BASE_URL: 'https://api.z.ai/api/anthropic' } }
  );
  assert.equal(result.status, 0, result.stderr);
});

test('--fail-closed-when preserves the lesson-loop missing-hook refusal', () => {
  const missing = join(tmpdir(), 'block-lesson-enforcement-writes.sh');
  const result = spawnSync(
    process.execPath,
    [LAUNCHER, '--optional', '--fail-closed-when', 'HIMMEL_LESSON_LOOP=1', missing],
    { encoding: 'utf8', env: { HIMMEL_LESSON_LOOP: '1' } }
  );
  assert.equal(result.status, 2);
  assert.equal(
    result.stderr,
    'block-lesson-enforcement-writes: hook script missing while HIMMEL_LESSON_LOOP=1 (stale checkout?) - failing closed\n'
  );
});
