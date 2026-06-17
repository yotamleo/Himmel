import { describe, it, expect, beforeEach } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir, platform } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { writeThreadCache } from '../lib/thread-cache.mjs';
import { expandPrefix } from '../lib/thread-prefix.mjs';

const IS_WIN = platform() === 'win32';
const REPLY_CLI = join(import.meta.dirname, '..', 'lib', 'thread-reply-cli.mjs');
const RESOLVE_CLI = join(import.meta.dirname, '..', 'lib', 'thread-resolve-action-cli.mjs');

let dir; // env root
let cacheRoot; // <dir>/himmel-cli

// Pre-populate a thread cache the spawned CLI will read, and return the
// generated 6-char prefix for the given thread id.
function seedCache(owner, repo, number, nodes) {
  const data = writeThreadCache(cacheRoot, owner, repo, number, nodes);
  return Object.keys(data.threads);
}

function cacheEnv(extra = {}) {
  const base = IS_WIN ? { LOCALAPPDATA: dir } : { XDG_CACHE_HOME: dir, HOME: dir };
  return { ...process.env, ...base, ...extra };
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'himmel-gh-mutate-'));
  cacheRoot = join(dir, 'himmel-cli');
  mkdirSync(cacheRoot, { recursive: true });
});

describe('expandPrefix (shared helper)', () => {
  it('returns ok + id for a unique prefix', () => {
    const [prefix] = seedCache('o', 'r', 1, [{ id: 'PRRT_a', path: 'a', line: 1, isResolved: false }]);
    // writeThreadCache wrote under cacheRoot; readThreadCache (inside expandPrefix)
    // uses osCacheRoot, so point the env at the same root for this in-process call.
    const saved = IS_WIN ? process.env.LOCALAPPDATA : process.env.XDG_CACHE_HOME;
    if (IS_WIN) process.env.LOCALAPPDATA = dir;
    else process.env.XDG_CACHE_HOME = dir;
    try {
      const res = expandPrefix({ owner: 'o', repo: 'r', number: 1, prefix });
      expect(res).toEqual({ ok: true, id: 'PRRT_a' });
    } finally {
      if (IS_WIN) process.env.LOCALAPPDATA = saved;
      else process.env.XDG_CACHE_HOME = saved;
    }
  });

  it('returns no-match for an unknown prefix', () => {
    seedCache('o', 'r', 1, [{ id: 'PRRT_a', path: 'a', line: 1, isResolved: false }]);
    const saved = IS_WIN ? process.env.LOCALAPPDATA : process.env.XDG_CACHE_HOME;
    if (IS_WIN) process.env.LOCALAPPDATA = dir;
    else process.env.XDG_CACHE_HOME = dir;
    try {
      const res = expandPrefix({ owner: 'o', repo: 'r', number: 1, prefix: 'ffffff' });
      expect(res.ok).toBe(false);
      expect(res.message).toMatch(/no-match/);
    } finally {
      if (IS_WIN) process.env.LOCALAPPDATA = saved;
      else process.env.XDG_CACHE_HOME = saved;
    }
  });

  it('returns ambiguous when a short prefix matches multiple threads', () => {
    // 40 threads > 16 hex digits → by pigeonhole, two 6-char prefixes share a
    // leading hex digit; querying that single digit is ambiguous.
    const nodes = Array.from({ length: 40 }, (_, i) => ({
      id: `T${i}`,
      path: 'a',
      line: 1,
      isResolved: false,
    }));
    const keys = seedCache('o', 'r', 2, nodes);
    const byFirst = {};
    for (const k of keys) (byFirst[k[0]] ??= []).push(k);
    const shared = Object.values(byFirst).find((g) => g.length >= 2);
    expect(shared).toBeDefined();
    const short = shared[0][0];
    const saved = IS_WIN ? process.env.LOCALAPPDATA : process.env.XDG_CACHE_HOME;
    if (IS_WIN) process.env.LOCALAPPDATA = dir;
    else process.env.XDG_CACHE_HOME = dir;
    try {
      const res = expandPrefix({ owner: 'o', repo: 'r', number: 2, prefix: short });
      expect(res.ok).toBe(false);
      expect(res.message).toMatch(/ambiguous/);
    } finally {
      if (IS_WIN) process.env.LOCALAPPDATA = saved;
      else process.env.XDG_CACHE_HOME = saved;
    }
  });
});

// no-cache exit path runs everywhere (it returns before any forge mutate).
describe('thread-reply-cli / thread-resolve-action-cli — no-cache', () => {
  it('reply CLI exits 1 with no-cache when the prefix cache is absent', () => {
    const res = spawnSync(
      process.execPath,
      [REPLY_CLI, '--owner', 'o', '--repo', 'r', '--number', '9', '--prefix', 'abc123', '--body', 'hi'],
      { env: cacheEnv(), cwd: dir, encoding: 'utf8' },
    );
    expect(res.status).toBe(1);
    expect(res.stderr).toMatch(/no-cache/);
  });

  it('resolve CLI exits 1 with no-cache when the prefix cache is absent', () => {
    const res = spawnSync(
      process.execPath,
      [RESOLVE_CLI, '--owner', 'o', '--repo', 'r', '--number', '9', '--prefix', 'abc123'],
      { env: cacheEnv(), cwd: dir, encoding: 'utf8' },
    );
    expect(res.status).toBe(1);
    expect(res.stderr).toMatch(/no-cache/);
  });
});

// Bitbucket forge route: stub bitbucket CLI via env. Runs on Windows too
// (HIMMEL-345) — the JSON-array BITBUCKET_CLI is parsed as exact argv, so the
// space in process.execPath no longer hits the (space-splitting) legacy path.
describe('thread mutate CLIs — bitbucket forge route', () => {
  let stub;
  function writeBbStub(body) {
    stub = join(dir, 'bb-stub.mjs');
    writeFileSync(stub, body);
  }
  function envBb() {
    return cacheEnv({ FORGE: 'bitbucket', BITBUCKET_CLI: JSON.stringify([process.execPath, stub]) });
  }

  it('reply routes `pr reply <n> <id> --body` and prints reply: ok', () => {
    const [prefix] = seedCache('ws', 'repo', 4, [{ id: '10', path: 'a', line: 1, isResolved: false }]);
    writeBbStub(
      `const a = process.argv.slice(2);
       if (a[0]==='pr'&&a[1]==='reply'&&a[2]==='4'&&a[3]==='10'&&a[4]==='--body'&&a[5]==='fixed it') {
         process.stdout.write('{"id":99}'); process.exit(0);
       }
       process.stderr.write('bad args: '+a.join('|')); process.exit(9);`,
    );
    const res = spawnSync(
      process.execPath,
      [REPLY_CLI, '--owner', 'ws', '--repo', 'repo', '--number', '4', '--prefix', prefix, '--body', 'fixed it'],
      { env: envBb(), cwd: dir, encoding: 'utf8' },
    );
    expect(res.status).toBe(0);
    expect(res.stdout).toMatch(/reply: ok/);
  });

  it('resolve routes `pr resolve <n> <id>` and prints resolved: ok', () => {
    const [prefix] = seedCache('ws', 'repo', 4, [{ id: '20', path: 'a', line: 1, isResolved: false }]);
    writeBbStub(
      `const a = process.argv.slice(2);
       if (a[0]==='pr'&&a[1]==='resolve'&&a[2]==='4'&&a[3]==='20') { process.stdout.write('{"resolved":true}'); process.exit(0); }
       process.stderr.write('bad args: '+a.join('|')); process.exit(9);`,
    );
    const res = spawnSync(
      process.execPath,
      [RESOLVE_CLI, '--owner', 'ws', '--repo', 'repo', '--number', '4', '--prefix', prefix],
      { env: envBb(), cwd: dir, encoding: 'utf8' },
    );
    expect(res.status).toBe(0);
    expect(res.stdout).toMatch(/resolved: ok/);
  });

  it('reply propagates a bitbucket CLI failure as exit 1', () => {
    const [prefix] = seedCache('ws', 'repo', 4, [{ id: '10', path: 'a', line: 1, isResolved: false }]);
    writeBbStub(`process.stderr.write('comment gone\\n'); process.exit(1);`);
    const res = spawnSync(
      process.execPath,
      [REPLY_CLI, '--owner', 'ws', '--repo', 'repo', '--number', '4', '--prefix', prefix, '--body', 'x'],
      { env: envBb(), cwd: dir, encoding: 'utf8' },
    );
    expect(res.status).toBe(1);
    expect(res.stderr).toMatch(/comment gone/);
  });
});
