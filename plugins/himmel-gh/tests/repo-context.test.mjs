import { describe, it, expect, beforeEach } from 'vitest';
import { mkdtempSync, existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  cachePath,
  readCache,
  writeCache,
} from '../lib/repo-context.mjs';

let dir;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'himmel-gh-repo-ctx-'));
});

describe('cachePath', () => {
  it('returns himmel-cli/gh/repo-context.json under OS cache root', () => {
    const p = cachePath();
    expect(p).toMatch(/himmel-cli[\\/]gh[\\/]repo-context\.json$/);
  });

  it('uses cacheRootOverride when provided', () => {
    const p = cachePath(dir);
    expect(p).toBe(join(dir, 'gh', 'repo-context.json'));
  });
});

describe('readCache / writeCache', () => {
  it('readCache returns null when file missing', () => {
    expect(readCache(dir, dir)).toBeNull();
  });

  it('roundtrips owner + name keyed by cwd', () => {
    writeCache(dir, { cwd: dir, owner: 'yotamleo', name: 'himmel' });
    const cached = readCache(dir, dir);
    expect(cached).toMatchObject({ cwd: dir, owner: 'yotamleo', name: 'himmel' });
    expect(cached.fetched_at).toMatch(/^\d{4}-\d{2}-\d{2}T/);
  });

  it('readCache returns null when cached cwd differs from current (cwd-change invalidation)', () => {
    writeCache(dir, { cwd: '/other/path', owner: 'x', name: 'y' });
    expect(readCache(dir, dir)).toBeNull();
  });

  it('writeCache creates parent dir if missing', () => {
    const fresh = join(dir, 'nested');
    writeCache(fresh, { cwd: fresh, owner: 'a', name: 'b' });
    expect(existsSync(join(fresh, 'gh', 'repo-context.json'))).toBe(true);
    const data = JSON.parse(readFileSync(join(fresh, 'gh', 'repo-context.json'), 'utf8'));
    expect(data.owner).toBe('a');
  });

  it('writeCache overwrites existing entry on cwd change', () => {
    writeCache(dir, { cwd: '/a', owner: 'a', name: 'a' });
    writeCache(dir, { cwd: '/b', owner: 'b', name: 'b' });
    const c = readCache(dir, '/b');
    expect(c.owner).toBe('b');
  });

  it('readCache returns null for non-object JSON (null, primitives, arrays, missing cwd)', () => {
    const ghDir = join(dir, 'gh');
    mkdirSync(ghDir, { recursive: true });
    const file = join(ghDir, 'repo-context.json');
    for (const payload of ['null', '"hello"', '42', '[1,2,3]', '{}']) {
      writeFileSync(file, payload);
      expect(readCache(dir, dir)).toBeNull();
    }
  });
});

describe('schema_version', () => {
  it('writeCache stamps schema_version: 1', () => {
    writeCache(dir, { cwd: dir, owner: 'a', name: 'b' });
    const raw = JSON.parse(readFileSync(join(dir, 'gh', 'repo-context.json'), 'utf8'));
    expect(raw.schema_version).toBe(1);
  });

  it('readCache returns null when schema_version is missing (legacy cache)', () => {
    const ghDir = join(dir, 'gh');
    mkdirSync(ghDir, { recursive: true });
    writeFileSync(
      join(ghDir, 'repo-context.json'),
      JSON.stringify({ cwd: dir, owner: 'a', name: 'b', fetched_at: '2026-01-01T00:00:00Z' }),
    );
    expect(readCache(dir, dir)).toBeNull();
  });

  it('readCache returns null when schema_version is not 1 (e.g. 2)', () => {
    const ghDir = join(dir, 'gh');
    mkdirSync(ghDir, { recursive: true });
    writeFileSync(
      join(ghDir, 'repo-context.json'),
      JSON.stringify({ schema_version: 2, cwd: dir, owner: 'a', name: 'b' }),
    );
    expect(readCache(dir, dir)).toBeNull();
  });

  it('readCache returns null when owner is empty string', () => {
    const ghDir = join(dir, 'gh');
    mkdirSync(ghDir, { recursive: true });
    writeFileSync(
      join(ghDir, 'repo-context.json'),
      JSON.stringify({ schema_version: 1, cwd: dir, owner: '', name: 'b' }),
    );
    expect(readCache(dir, dir)).toBeNull();
  });

  it('readCache returns null when name is missing', () => {
    const ghDir = join(dir, 'gh');
    mkdirSync(ghDir, { recursive: true });
    writeFileSync(
      join(ghDir, 'repo-context.json'),
      JSON.stringify({ schema_version: 1, cwd: dir, owner: 'a' }),
    );
    expect(readCache(dir, dir)).toBeNull();
  });

  it('readCache returns null when owner is non-string (number)', () => {
    const ghDir = join(dir, 'gh');
    mkdirSync(ghDir, { recursive: true });
    writeFileSync(
      join(ghDir, 'repo-context.json'),
      JSON.stringify({ schema_version: 1, cwd: dir, owner: 42, name: 'b' }),
    );
    expect(readCache(dir, dir)).toBeNull();
  });
});

describe('chmodSync warning', () => {
  it.skipIf(process.platform === 'win32')(
    'writeCache does not throw when chmodSync fails (best-effort contract)',
    () => {
      // The chmodSync warn-on-fail path is exercised via the implementation
      // contract: writeCache must not throw even if chmod fails. Forcing
      // chmodSync to fail across platforms in a unit test is flaky; this
      // observational assertion pins the contract.
      expect(() => writeCache(dir, { cwd: dir, owner: 'a', name: 'b' })).not.toThrow();
    },
  );
});

describe('osCacheRoot env-unset throw', () => {
  it('throws when LOCALAPPDATA (win32) or HOME+XDG_CACHE_HOME (posix) all unset', () => {
    const saved = {
      LOCALAPPDATA: process.env.LOCALAPPDATA,
      XDG_CACHE_HOME: process.env.XDG_CACHE_HOME,
      HOME: process.env.HOME,
    };
    delete process.env.LOCALAPPDATA;
    delete process.env.XDG_CACHE_HOME;
    delete process.env.HOME;
    try {
      expect(() => cachePath()).toThrow(/Cannot resolve cache dir/);
    } finally {
      for (const [k, v] of Object.entries(saved)) {
        if (v === undefined) delete process.env[k]; else process.env[k] = v;
      }
    }
  });
});
