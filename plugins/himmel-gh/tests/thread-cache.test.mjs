import { describe, it, expect, beforeEach } from 'vitest';
import { mkdtempSync, mkdirSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import {
  cachePath,
  buildPrefixMap,
  writeThreadCache,
  readThreadCache,
  lookupPrefix,
} from '../lib/thread-cache.mjs';

let dir;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'himmel-gh-tc-'));
});

describe('cachePath', () => {
  it('returns himmel-cli/gh/threads/<owner>-<repo>-<N>.json under override root', () => {
    expect(cachePath(dir, 'yotamleo', 'himmel', 97)).toBe(
      join(dir, 'gh', 'threads', 'yotamleo-himmel-97.json'),
    );
  });
});

describe('buildPrefixMap', () => {
  it('assigns 6-char hex prefixes derived from sha256 of thread id', () => {
    const threads = [
      { id: 'PRRT_one', path: 'a.ts', line: 1, isResolved: false },
      { id: 'PRRT_two', path: 'b.ts', line: 2, isResolved: true },
    ];
    const map = buildPrefixMap(threads);
    const prefixes = Object.keys(map);
    expect(prefixes).toHaveLength(2);
    for (const p of prefixes) expect(p).toMatch(/^[0-9a-f]{6}$/);
    expect(Object.values(map).map((t) => t.id).sort()).toEqual(['PRRT_one', 'PRRT_two']);
  });

  it('throws clearly on duplicate thread ids (GitHub API invariant violation)', () => {
    // Two threads with identical SHA-256 hashes can only happen via duplicate
    // input ids — GraphQL guarantees thread ids are unique. Surface this as a
    // loud error rather than fabricating a disambiguation suffix that would
    // break lookupPrefix.startsWith semantics. See W5 in HIMMEL-99 round-1 fix.
    const threads = [
      { id: 'PRRT_dup', path: 'a.ts', line: 1, isResolved: false },
      { id: 'PRRT_dup', path: 'b.ts', line: 2, isResolved: false },
    ];
    expect(() => buildPrefixMap(threads)).toThrow(/duplicate thread id/i);
  });
});

describe('writeThreadCache / readThreadCache', () => {
  it('roundtrips and creates parent dirs', () => {
    const threads = [{ id: 'PRRT_x', path: 'a.ts', line: 1, isResolved: false }];
    writeThreadCache(dir, 'yotamleo', 'himmel', 97, threads);
    const cached = readThreadCache(dir, 'yotamleo', 'himmel', 97);
    expect(cached).not.toBeNull();
    expect(cached.owner).toBe('yotamleo');
    expect(cached.repo).toBe('himmel');
    expect(cached.number).toBe(97);
    expect(Object.values(cached.threads)[0].id).toBe('PRRT_x');
    expect(existsSync(cachePath(dir, 'yotamleo', 'himmel', 97))).toBe(true);
  });

  it('returns null when cache missing', () => {
    expect(readThreadCache(dir, 'yotamleo', 'himmel', 99)).toBeNull();
  });

  it('stamps schema_version: 1 on write', () => {
    const threads = [{ id: 'PRRT_x', path: 'a.ts', line: 1, isResolved: false }];
    writeThreadCache(dir, 'o', 'r', 1, threads);
    const raw = JSON.parse(readFileSync(cachePath(dir, 'o', 'r', 1), 'utf8'));
    expect(raw.schema_version).toBe(1);
  });

  it('rejects cache missing schema_version (legacy file) → returns null + warn', () => {
    // Write a legacy-shaped cache (no schema_version).
    const file = cachePath(dir, 'o', 'r', 1);
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, JSON.stringify({
      owner: 'o', repo: 'r', number: 1, fetched_at: 'x',
      threads: { abc123: { id: 'X', path: '', line: 0, isResolved: false } },
    }));
    expect(readThreadCache(dir, 'o', 'r', 1)).toBeNull();
  });

  it('rejects cache with mismatched owner/repo/number (defense-in-depth)', () => {
    const threads = [{ id: 'PRRT_x', path: 'a.ts', line: 1, isResolved: false }];
    writeThreadCache(dir, 'o', 'r', 1, threads);
    // Corrupt the on-disk owner field; reader should refuse it.
    const file = cachePath(dir, 'o', 'r', 1);
    const data = JSON.parse(readFileSync(file, 'utf8'));
    data.owner = 'someone-else';
    writeFileSync(file, JSON.stringify(data));
    expect(readThreadCache(dir, 'o', 'r', 1)).toBeNull();
  });

  it('rejects cache with future schema_version → returns null', () => {
    const file = cachePath(dir, 'o', 'r', 1);
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, JSON.stringify({
      schema_version: 99,
      owner: 'o', repo: 'r', number: 1, fetched_at: 'x',
      threads: {},
    }));
    expect(readThreadCache(dir, 'o', 'r', 1)).toBeNull();
  });
});

describe('lookupPrefix', () => {
  it('returns the full thread id for a unique prefix', () => {
    const threads = [{ id: 'PRRT_unique', path: 'a.ts', line: 1, isResolved: false }];
    writeThreadCache(dir, 'o', 'r', 1, threads);
    const cached = readThreadCache(dir, 'o', 'r', 1);
    const prefix = Object.keys(cached.threads)[0];
    expect(lookupPrefix(cached, prefix.slice(0, 6))).toEqual({
      status: 'ok',
      id: 'PRRT_unique',
    });
  });

  it('returns no-match for unknown prefix', () => {
    const threads = [{ id: 'PRRT_x', path: 'a.ts', line: 1, isResolved: false }];
    writeThreadCache(dir, 'o', 'r', 1, threads);
    const cached = readThreadCache(dir, 'o', 'r', 1);
    expect(lookupPrefix(cached, 'deadbe').status).toBe('no-match');
  });

  it('returns ambiguous when prefix matches two entries', () => {
    const cached = {
      owner: 'o', repo: 'r', number: 1, fetched_at: '',
      threads: {
        '1234567': { id: 'A', path: '', line: 0, isResolved: false },
        '1234568': { id: 'B', path: '', line: 0, isResolved: false },
      },
    };
    expect(lookupPrefix(cached, '123456').status).toBe('ambiguous');
  });
});
