import { describe, it, expect, beforeEach } from 'vitest';
import { mkdtempSync, mkdirSync, existsSync, readFileSync, writeFileSync, chmodSync } from 'node:fs';
import { tmpdir, platform } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { cachePath } from '../lib/thread-cache.mjs';

let dir;        // env-root
let cacheRoot;  // <dir>/himmel-cli
const cli = join(import.meta.dirname, '..', 'lib', 'threads-list-cli.mjs');
const IS_WIN = platform() === 'win32';

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'himmel-gh-tl-'));
  cacheRoot = join(dir, 'himmel-cli');
  mkdirSync(cacheRoot, { recursive: true });
});

function fakeGhResponse(threads) {
  return JSON.stringify({
    data: {
      repository: {
        pullRequest: {
          reviewThreads: {
            totalCount: threads.length,
            nodes: threads,
          },
        },
      },
    },
  });
}

function envForTest() {
  return process.platform === 'win32'
    ? { LOCALAPPDATA: dir }
    : { XDG_CACHE_HOME: dir, HOME: dir };
}

describe('threads-list-cli (with --stdin-json for test injection)', () => {
  it('writes per-PR cache and prints one-line summary', () => {
    const env = envForTest();
    const payload = fakeGhResponse([
      { id: 'PRRT_a', path: 'a.ts', line: 1, isResolved: false,
        comments: { nodes: [{ author: { login: 'reviewer1' }, bodyText: 'fix this' }] } },
      { id: 'PRRT_b', path: 'b.ts', line: 2, isResolved: true,
        comments: { nodes: [{ author: { login: 'reviewer2' }, bodyText: 'ok' }] } },
    ]);
    const res = spawnSync(
      'node',
      [cli, '--owner', 'o', '--repo', 'r', '--number', '1', '--stdin-json'],
      { input: payload, env: { ...process.env, ...env }, encoding: 'utf8' },
    );
    expect(res.status).toBe(0);
    expect(res.stdout).toMatch(/threads=2 unresolved=1/);
    expect(existsSync(cachePath(cacheRoot, 'o', 'r', 1))).toBe(true);
    const cached = JSON.parse(readFileSync(cachePath(cacheRoot, 'o', 'r', 1), 'utf8'));
    expect(Object.keys(cached.threads)).toHaveLength(2);
  });

  it('handles empty thread list (threads=0 unresolved=0)', () => {
    const env = envForTest();
    const payload = fakeGhResponse([]);
    const res = spawnSync(
      'node',
      [cli, '--owner', 'o', '--repo', 'r', '--number', '5', '--stdin-json'],
      { input: payload, env: { ...process.env, ...env }, encoding: 'utf8' },
    );
    expect(res.status).toBe(0);
    expect(res.stdout).toMatch(/threads=0 unresolved=0/);
  });

  it('exits 1 with parse error on malformed JSON', () => {
    const env = envForTest();
    const res = spawnSync(
      'node',
      [cli, '--owner', 'o', '--repo', 'r', '--number', '5', '--stdin-json'],
      { input: 'not json', env: { ...process.env, ...env }, encoding: 'utf8' },
    );
    expect(res.status).toBe(1);
    expect(res.stderr).toContain('parse');
  });
});

// Signal-killed gh subprocess (no --stdin-json path, uses real spawn → fake gh).
// Windows can't reliably resolve .cmd shims without shell:true, so POSIX only.
describe.skipIf(IS_WIN)('threads-list-cli signal-killed gh subprocess', () => {
  let fakeBin;
  beforeEach(() => {
    fakeBin = join(dir, 'bin');
    mkdirSync(fakeBin, { recursive: true });
  });

  function envWithFakeGh() {
    return {
      ...process.env,
      PATH: `${fakeBin}:${process.env.PATH}`,
      XDG_CACHE_HOME: dir,
      HOME: dir,
    };
  }

  function writeFakeGh(script) {
    const sh = join(fakeBin, 'gh');
    writeFileSync(sh, `#!/usr/bin/env node\n${script}\n`);
    chmodSync(sh, 0o755);
  }

  it('signal-killed gh → propagates exitCode 129 + stderr signal note (no confusing parse error)', () => {
    writeFakeGh(`process.kill(process.pid, 'SIGTERM');`);
    const res = spawnSync(
      process.execPath,
      [cli, '--owner', 'o', '--repo', 'r', '--number', '1'],
      { env: envWithFakeGh(), cwd: dir, encoding: 'utf8' },
    );
    expect(res.status).toBe(129);
    expect(res.stderr).toMatch(/killed by signal SIGTERM/);
    // Critical: must NOT be misleading "parse error" or "unexpected response shape".
    expect(res.stderr).not.toMatch(/parse error/);
    expect(res.stderr).not.toMatch(/unexpected response shape/);
  });
});
