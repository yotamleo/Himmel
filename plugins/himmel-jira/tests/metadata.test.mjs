import { describe, it, expect, beforeEach } from 'vitest';
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir, platform } from 'node:os';
import { join } from 'node:path';
import { metadataPath, readMetadata, writeMetadata, isStale } from '../lib/metadata.mjs';

let dir;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'himmel-meta-'));
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Set the env var used as the cache root, return a restore callback. */
function stubCacheRoot(tmpDir) {
  const isWin = platform() === 'win32';
  const envKey = isWin ? 'LOCALAPPDATA' : 'HOME';
  const origXdg = process.env.XDG_CACHE_HOME;
  const orig = process.env[envKey];
  if (!isWin) delete process.env.XDG_CACHE_HOME;
  process.env[envKey] = tmpDir;
  return () => {
    process.env[envKey] = orig;
    if (!isWin && origXdg !== undefined) process.env.XDG_CACHE_HOME = origXdg;
  };
}

/** Returns the directory where metadata.json lives, relative to the stub root. */
function metaSubdir(root) {
  return platform() === 'win32'
    ? join(root, 'himmel-cli', 'jira')
    : join(root, '.cache', 'himmel-cli', 'jira');
}

// ---------------------------------------------------------------------------
// metadataPath
// ---------------------------------------------------------------------------

describe('metadataPath', () => {
  it('returns path under XDG_CACHE_HOME when set (POSIX)', () => {
    if (platform() === 'win32') return;
    const origXdg = process.env.XDG_CACHE_HOME;
    const origHome = process.env.HOME;
    process.env.XDG_CACHE_HOME = dir;
    try {
      const { file } = metadataPath();
      expect(file).toBe(join(dir, 'himmel-cli', 'jira', 'metadata.json'));
    } finally {
      if (origXdg === undefined) delete process.env.XDG_CACHE_HOME;
      else process.env.XDG_CACHE_HOME = origXdg;
      process.env.HOME = origHome;
    }
  });

  it('falls back to HOME/.cache when XDG_CACHE_HOME absent (POSIX)', () => {
    if (platform() === 'win32') return;
    const origXdg = process.env.XDG_CACHE_HOME;
    const origHome = process.env.HOME;
    delete process.env.XDG_CACHE_HOME;
    process.env.HOME = dir;
    try {
      const { file } = metadataPath();
      expect(file).toBe(join(dir, '.cache', 'himmel-cli', 'jira', 'metadata.json'));
    } finally {
      process.env.HOME = origHome;
      if (origXdg !== undefined) process.env.XDG_CACHE_HOME = origXdg;
    }
  });

  it('returns path under LOCALAPPDATA on Windows', () => {
    if (platform() !== 'win32') return;
    const orig = process.env.LOCALAPPDATA;
    process.env.LOCALAPPDATA = dir;
    try {
      const { file } = metadataPath();
      expect(file).toBe(join(dir, 'himmel-cli', 'jira', 'metadata.json'));
    } finally {
      if (orig === undefined) delete process.env.LOCALAPPDATA;
      else process.env.LOCALAPPDATA = orig;
    }
  });

  it('throws when HOME and XDG_CACHE_HOME are both unset (POSIX)', () => {
    if (platform() === 'win32') return;
    const origHome = process.env.HOME;
    const origXdg = process.env.XDG_CACHE_HOME;
    delete process.env.HOME;
    delete process.env.XDG_CACHE_HOME;
    try {
      expect(() => metadataPath()).toThrow();
    } finally {
      process.env.HOME = origHome;
      if (origXdg !== undefined) process.env.XDG_CACHE_HOME = origXdg;
    }
  });
});

// ---------------------------------------------------------------------------
// readMetadata
// ---------------------------------------------------------------------------

describe('readMetadata', () => {
  it('returns null when metadata file is absent', () => {
    const restore = stubCacheRoot(dir);
    try {
      expect(readMetadata()).toBeNull();
    } finally {
      restore();
    }
  });

  it('returns null for corrupt JSON', () => {
    const cacheRoot = mkdtempSync(join(tmpdir(), 'himmel-corrupt-'));
    const restore = stubCacheRoot(cacheRoot);
    try {
      const sub = metaSubdir(cacheRoot);
      mkdirSync(sub, { recursive: true });
      writeFileSync(join(sub, 'metadata.json'), '{bad json}');
      expect(readMetadata()).toBeNull();
    } finally {
      restore();
      rmSync(cacheRoot, { recursive: true, force: true });
    }
  });
});

// ---------------------------------------------------------------------------
// writeMetadata + readMetadata roundtrip
// ---------------------------------------------------------------------------

describe('writeMetadata + readMetadata roundtrip', () => {
  it('persists and retrieves the written payload', () => {
    const restore = stubCacheRoot(dir);
    try {
      const payload = { fetched_at: new Date().toISOString(), projects: { FOO: {} } };
      writeMetadata(payload);
      expect(readMetadata()).toMatchObject(payload);
    } finally {
      restore();
    }
  });
});

// ---------------------------------------------------------------------------
// isStale
// ---------------------------------------------------------------------------

describe('isStale', () => {
  it('returns true for null metadata', () => {
    expect(isStale(null)).toBe(true);
  });

  it('returns true for metadata missing fetched_at', () => {
    expect(isStale({})).toBe(true);
  });

  it('returns false for recently-fetched metadata', () => {
    expect(isStale({ fetched_at: new Date().toISOString() })).toBe(false);
  });

  it('returns true for metadata fetched 40 days ago (default 30d threshold)', () => {
    const fortyDaysAgo = new Date(Date.now() - 40 * 86400_000).toISOString();
    expect(isStale({ fetched_at: fortyDaysAgo })).toBe(true);
  });

  it('returns false for 40-day-old metadata with custom 60d threshold', () => {
    const fortyDaysAgo = new Date(Date.now() - 40 * 86400_000).toISOString();
    expect(isStale({ fetched_at: fortyDaysAgo }, 60)).toBe(false);
  });
});
