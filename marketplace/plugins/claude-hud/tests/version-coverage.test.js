import { afterEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { utimesSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import {
  _getClaudeVersionInvocation,
  _parseClaudeCodeVersion,
  _resetVersionCache,
  _setExecFileImplForTests,
  _setResolveClaudeBinaryForTests,
  _setVersionInvocationEnvForTests,
  getClaudeCodeVersion,
} from '../dist/version.js';

function restoreEnvVar(name, value) {
  if (value === undefined) {
    delete process.env[name];
    return;
  }
  process.env[name] = value;
}

afterEach(() => {
  _resetVersionCache();
  _setExecFileImplForTests(null);
  _setResolveClaudeBinaryForTests(null);
  _setVersionInvocationEnvForTests(null, null);
});

test('getClaudeCodeVersion returns undefined when no binary is resolved', async () => {
  _setResolveClaudeBinaryForTests(() => null);
  const version = await getClaudeCodeVersion();
  assert.equal(version, undefined);
});

test('getClaudeCodeVersion returns undefined when execFile throws', async () => {
  const tempHome = await mkdtemp(path.join(tmpdir(), 'claude-hud-ver-err-'));
  const customConfigDir = path.join(tempHome, '.claude-alt');
  const binaryPath = path.join(tempHome, 'claude');
  const originalHome = process.env.HOME;
  const originalConfigDir = process.env.CLAUDE_CONFIG_DIR;

  process.env.HOME = tempHome;
  process.env.CLAUDE_CONFIG_DIR = customConfigDir;
  await writeFile(binaryPath, '#!/bin/sh\n', 'utf8');
  const binaryMtimeMs = 1710000000000;
  utimesSync(binaryPath, binaryMtimeMs / 1000, binaryMtimeMs / 1000);

  try {
    _setResolveClaudeBinaryForTests(() => ({ path: binaryPath, mtimeMs: binaryMtimeMs }));
    _setExecFileImplForTests(async () => {
      throw new Error('command not found');
    });

    const version = await getClaudeCodeVersion();
    assert.equal(version, undefined);
  } finally {
    restoreEnvVar('HOME', originalHome);
    restoreEnvVar('CLAUDE_CONFIG_DIR', originalConfigDir);
    await rm(tempHome, { recursive: true, force: true });
  }
});

test('getClaudeCodeVersion uses in-memory cache on repeated calls without reset', async () => {
  const tempHome = await mkdtemp(path.join(tmpdir(), 'claude-hud-ver-memcache-'));
  const customConfigDir = path.join(tempHome, '.claude-alt');
  const binaryPath = path.join(tempHome, 'claude');
  const originalHome = process.env.HOME;
  const originalConfigDir = process.env.CLAUDE_CONFIG_DIR;
  let execCalls = 0;

  process.env.HOME = tempHome;
  process.env.CLAUDE_CONFIG_DIR = customConfigDir;
  await writeFile(binaryPath, '#!/bin/sh\n', 'utf8');
  const binaryMtimeMs = 1710000000000;
  utimesSync(binaryPath, binaryMtimeMs / 1000, binaryMtimeMs / 1000);

  try {
    _setResolveClaudeBinaryForTests(() => ({ path: binaryPath, mtimeMs: binaryMtimeMs }));
    _setExecFileImplForTests(async () => {
      execCalls += 1;
      return { stdout: '2.1.90 (Claude Code)\n' };
    });

    const first = await getClaudeCodeVersion();
    assert.equal(first, '2.1.90');
    assert.equal(execCalls, 1);

    // Second call without reset should use in-memory cache
    const second = await getClaudeCodeVersion();
    assert.equal(second, '2.1.90');
    assert.equal(execCalls, 1); // no additional exec call
  } finally {
    restoreEnvVar('HOME', originalHome);
    restoreEnvVar('CLAUDE_CONFIG_DIR', originalConfigDir);
    await rm(tempHome, { recursive: true, force: true });
  }
});

test('_parseClaudeCodeVersion handles various version output formats', () => {
  assert.equal(_parseClaudeCodeVersion('1.0.0'), '1.0.0');
  assert.equal(_parseClaudeCodeVersion('  \n  '), undefined);
  assert.equal(_parseClaudeCodeVersion('no version here'), undefined);
  assert.equal(_parseClaudeCodeVersion('v2.3.4-rc.1+build.123'), '2.3.4-rc.1+build.123');
});

test('_getClaudeVersionInvocation handles .bat files on Windows via cmd', () => {
  const invocation = _getClaudeVersionInvocation(
    'C:\\Tools\\claude.bat',
    'win32',
    'C:\\Windows\\System32\\cmd.exe'
  );
  assert.equal(invocation.file, 'C:\\Windows\\System32\\cmd.exe');
  // No special chars in the path, so it's not quoted
  assert.deepEqual(invocation.args, ['/d', '/s', '/c', '"C:\\Tools\\claude.bat --version"']);
});

test('_getClaudeVersionInvocation handles paths with no special characters on Windows cmd', () => {
  const invocation = _getClaudeVersionInvocation(
    'C:\\claude.cmd',
    'win32',
    'C:\\Windows\\System32\\cmd.exe'
  );
  assert.equal(invocation.file, 'C:\\Windows\\System32\\cmd.exe');
  assert.deepEqual(invocation.args, ['/d', '/s', '/c', '"C:\\claude.cmd --version"']);
});

test('_getClaudeVersionInvocation runs .exe directly on Windows', () => {
  const invocation = _getClaudeVersionInvocation('C:\\path\\claude.exe', 'win32');
  assert.deepEqual(invocation, { file: 'C:\\path\\claude.exe', args: ['--version'] });
});

test('_getClaudeVersionInvocation runs binary directly on darwin', () => {
  const invocation = _getClaudeVersionInvocation('/opt/local/bin/claude', 'darwin');
  assert.deepEqual(invocation, { file: '/opt/local/bin/claude', args: ['--version'] });
});

test('getClaudeCodeVersion handles disk cache with null version', async () => {
  const tempHome = await mkdtemp(path.join(tmpdir(), 'claude-hud-ver-null-'));
  const customConfigDir = path.join(tempHome, '.claude-alt');
  const binaryPath = path.join(tempHome, 'claude');
  const originalHome = process.env.HOME;
  const originalConfigDir = process.env.CLAUDE_CONFIG_DIR;

  process.env.HOME = tempHome;
  process.env.CLAUDE_CONFIG_DIR = customConfigDir;
  await writeFile(binaryPath, '#!/bin/sh\n', 'utf8');
  const binaryMtimeMs = 1710000000000;
  utimesSync(binaryPath, binaryMtimeMs / 1000, binaryMtimeMs / 1000);

  try {
    // First call: exec returns unparseable output → null cached
    _setResolveClaudeBinaryForTests(() => ({ path: binaryPath, mtimeMs: binaryMtimeMs }));
    _setExecFileImplForTests(async () => ({ stdout: 'not a version\n' }));

    const first = await getClaudeCodeVersion();
    assert.equal(first, undefined);

    // Reset and read from disk cache (null version should be preserved)
    _resetVersionCache();
    _setResolveClaudeBinaryForTests(() => ({ path: binaryPath, mtimeMs: binaryMtimeMs }));
    _setExecFileImplForTests(async () => {
      throw new Error('should not be called');
    });

    const second = await getClaudeCodeVersion();
    assert.equal(second, undefined);
  } finally {
    restoreEnvVar('HOME', originalHome);
    restoreEnvVar('CLAUDE_CONFIG_DIR', originalConfigDir);
    await rm(tempHome, { recursive: true, force: true });
  }
});
