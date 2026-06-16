import { describe, it, expect, beforeEach } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, readdirSync, utimesSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { gc } from '../src/gc.js';

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'himmel-gc-'));
});

describe('gc', () => {
  it('removes entries older than maxAgeDays', async () => {
    const idx = join(dir, 'jira', 'index');
    mkdirSync(idx, { recursive: true });
    const old = join(idx, 'old.json');
    const young = join(idx, 'young.json');
    writeFileSync(old, '{}');
    writeFileSync(young, '{}');
    const oldTs = Date.now() / 1000 - 40 * 86400;
    utimesSync(old, oldTs, oldTs);
    const removed = await gc('jira', 30, dir);
    expect(removed).toBe(1);
    const remaining = readdirSync(idx);
    expect(remaining).toEqual(['young.json']);
  });

  // B10: tag path traversal
  it('throws on tag with path separator', async () => {
    await expect(gc('foo/bar', 30, dir)).rejects.toThrow('invalid tag');
  });

  it('throws on tag ".."', async () => {
    await expect(gc('..', 30, dir)).rejects.toThrow('invalid tag');
  });
});
