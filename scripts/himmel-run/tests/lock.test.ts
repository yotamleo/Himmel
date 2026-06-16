import { describe, it, expect, beforeEach } from 'vitest';
import { mkdtempSync, writeFileSync, mkdirSync, utimesSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { withLock } from '../src/lock.js';

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'himmel-lock-'));
});

describe('withLock', () => {
  it('runs the callback and returns its value', async () => {
    const target = join(dir, 'file.log');
    writeFileSync(target, '');
    const out = await withLock(target, async () => 42);
    expect(out).toBe(42);
  });

  it('serializes parallel callbacks on the same target', async () => {
    const target = join(dir, 'file.log');
    writeFileSync(target, '');
    const order: number[] = [];
    const a = withLock(target, async () => {
      await new Promise((r) => setTimeout(r, 30));
      order.push(1);
    });
    const b = withLock(target, async () => {
      order.push(2);
    });
    await Promise.all([a, b]);
    expect(order).toEqual([1, 2]);
  });

  it('recovers from stale lockfile (mtime > stale threshold)', async () => {
    const target = join(dir, 'file.log');
    writeFileSync(target, '');
    // proper-lockfile v4 uses a directory as the lock artifact
    const lockPath = target + '.lock';
    mkdirSync(lockPath);
    // Set mtime to 60 s ago — well past the 30 s stale threshold
    const sixtySecondsAgoSec = (Date.now() - 60_000) / 1000;
    utimesSync(lockPath, sixtySecondsAgoSec, sixtySecondsAgoSec);
    const out = await withLock(target, async () => 'ok');
    expect(out).toBe('ok');
  }, 10_000);
});
