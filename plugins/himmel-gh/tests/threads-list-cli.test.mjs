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

// Bitbucket forge route (spec §5.3): FORGE=bitbucket + a node-stub bitbucket CLI
// that emits the `pr comments` payload. Runs on Windows too (HIMMEL-345): the
// JSON-array BITBUCKET_CLI form is parsed as exact argv with no space-split, so
// the space in process.execPath (C:\Program Files\nodejs\node.exe) is safe.
describe('threads-list-cli — bitbucket forge route', () => {
  let stub;
  function writeBbStub(body) {
    stub = join(dir, 'bb-stub.mjs');
    writeFileSync(stub, body);
  }
  function envBb() {
    // envForTest() supplies the platform-correct cache root (LOCALAPPDATA on
    // Windows, XDG_CACHE_HOME/HOME on POSIX) so the cachePath() assertion below
    // matches where the spawned CLI writes — required now that this runs on Windows.
    return {
      ...process.env,
      ...envForTest(),
      FORGE: 'bitbucket',
      BITBUCKET_CLI: JSON.stringify([process.execPath, stub]),
    };
  }

  it('routes through the bitbucket CLI, caches threads, prints the summary', () => {
    writeBbStub(
      `const a = process.argv.slice(2);
       if (a[0]==='pr'&&a[1]==='comments'&&a[2]==='3') {
         process.stdout.write(JSON.stringify({ threads: [
           { id: 10, path: 'src/x.ts', line: 42, isResolved: false, author: 'rev', body: 'fix this' },
           { id: 20, path: 'src/y.ts', line: 7, isResolved: true, author: 'me', body: 'done' }
         ], truncated: false, pages: 1 })); process.exit(0);
       }
       process.stderr.write('bad args'); process.exit(9);`,
    );
    const res = spawnSync(
      process.execPath,
      [cli, '--owner', 'ws', '--repo', 'repo', '--number', '3'],
      { env: envBb(), cwd: dir, encoding: 'utf8' },
    );
    expect(res.status).toBe(0);
    expect(res.stdout).toMatch(/threads=2 unresolved=1/);
    expect(existsSync(cachePath(cacheRoot, 'ws', 'repo', 3))).toBe(true);
  });

  it('propagates a non-zero bitbucket CLI exit as failure (no silent empty list)', () => {
    writeBbStub(`process.stderr.write('bb auth 401\\n'); process.exit(1);`);
    const res = spawnSync(
      process.execPath,
      [cli, '--owner', 'ws', '--repo', 'repo', '--number', '3'],
      { env: envBb(), cwd: dir, encoding: 'utf8' },
    );
    expect(res.status).toBe(1);
    expect(res.stderr).toMatch(/bb auth 401/);
  });
});
