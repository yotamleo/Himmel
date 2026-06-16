import { describe, it, expect, beforeEach } from 'vitest';
import { mkdtempSync, readFileSync, writeFileSync, statSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { appendLog, rotateIfLarge, ROTATION_BYTES_DEFAULT } from '../src/log.js';

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'himmel-log-'));
});

describe('log.appendLog', () => {
  it('creates file with 0600 mode and appends bytes', () => {
    const f = join(dir, 'normal.log');
    const start = appendLog(f, 'first line\n');
    const end = appendLog(f, 'second line\n');
    expect(readFileSync(f, 'utf8')).toBe('first line\nsecond line\n');
    expect(end).toBeGreaterThan(start);
    if (process.platform !== 'win32') {
      expect(statSync(f).mode & 0o777).toBe(0o600);
    }
  });

  it('truncates oversized payloads at byte boundary (UTF-8 safe)', () => {
    const f = join(dir, 'normal.log');
    // 2000 emoji × 4 bytes each = 8KB raw, must be truncated to < MAX_LINE_BYTES + suffix
    const emoji = '😀'.repeat(2000);
    appendLog(f, emoji);
    const written = readFileSync(f);
    // Ceiling: original-bytes capped at MAX_LINE_BYTES, plus '…\n' suffix (U+2026 = 3 UTF-8 bytes + newline = 4 bytes)
    expect(written.length).toBeLessThanOrEqual(4000 + 4);
    expect(written.toString('utf8')).toMatch(/…\n$/);
  });
});

describe('log.rotateIfLarge', () => {
  it('does nothing under threshold', () => {
    const f = join(dir, 'normal.log');
    writeFileSync(f, 'small');
    const rotated = rotateIfLarge(f, ROTATION_BYTES_DEFAULT);
    expect(rotated).toBe(false);
  });

  it('renames to unique timestamp when over threshold', () => {
    const f = join(dir, 'normal.log');
    writeFileSync(f, Buffer.alloc(100));
    const rotated = rotateIfLarge(f, 10);
    expect(rotated).toBe(true);
    const files = readdirSync(dir);
    const rotatedFile = files.find((n) => n.startsWith('normal.log.'));
    expect(rotatedFile).toBeDefined();
    expect(files.includes('normal.log')).toBe(false);
  });
});
