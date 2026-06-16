import { describe, it, expect, beforeEach } from 'vitest';
import { mkdtempSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { writeThreadCache } from '../lib/thread-cache.mjs';

let dir;        // env-root (mapped to XDG_CACHE_HOME / LOCALAPPDATA)
let cacheRoot;  // what the lib's osCacheRoot() resolves to: <dir>/himmel-cli
const cli = join(import.meta.dirname, '..', 'lib', 'thread-resolve-cli.mjs');

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'himmel-gh-tr-'));
  cacheRoot = join(dir, 'himmel-cli');
  mkdirSync(cacheRoot, { recursive: true });
});

function runCli(args, envOverride = {}) {
  const env = { ...process.env, ...envOverride };
  return spawnSync('node', [cli, ...args], { env, encoding: 'utf8' });
}

describe('thread-resolve-cli', () => {
  it('prints full id and exits 0 for a unique prefix', () => {
    const threads = [{ id: 'PRRT_unique', path: 'a.ts', line: 1, isResolved: false }];
    const data = writeThreadCache(cacheRoot, 'o', 'r', 1, threads);
    const prefix = Object.keys(data.threads)[0].slice(0, 6);
    const res = runCli(
      ['--owner', 'o', '--repo', 'r', '--number', '1', '--prefix', prefix],
      // Force the override path (POSIX uses XDG_CACHE_HOME; on Windows we use LOCALAPPDATA — both override osCacheRoot).
      process.platform === 'win32' ? { LOCALAPPDATA: dir } : { XDG_CACHE_HOME: dir, HOME: dir },
    );
    expect(res.status).toBe(0);
    expect(res.stdout.trim()).toBe('PRRT_unique');
  });

  it('exits 1 with no-match on unknown prefix', () => {
    const threads = [{ id: 'PRRT_x', path: 'a.ts', line: 1, isResolved: false }];
    writeThreadCache(cacheRoot, 'o', 'r', 1, threads);
    const res = runCli(
      ['--owner', 'o', '--repo', 'r', '--number', '1', '--prefix', 'deadbe'],
      process.platform === 'win32' ? { LOCALAPPDATA: dir } : { XDG_CACHE_HOME: dir, HOME: dir },
    );
    expect(res.status).toBe(1);
    expect(res.stderr).toContain('no-match');
  });

  it('exits 1 with no-cache when the per-PR cache file is missing', () => {
    const res = runCli(
      ['--owner', 'o', '--repo', 'r', '--number', '999', '--prefix', '123456'],
      process.platform === 'win32' ? { LOCALAPPDATA: dir } : { XDG_CACHE_HOME: dir, HOME: dir },
    );
    expect(res.status).toBe(1);
    expect(res.stderr).toContain('no-cache');
  });
});
