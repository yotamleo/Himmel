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

  it('truncation that lands MID-CHARACTER still produces valid UTF-8 and preserves the exact whole-character prefix', () => {
    const f = join(dir, 'normal.log');
    // 3999 ASCII bytes then a 4-byte emoji: the MAX_LINE_BYTES=4000 cut lands
    // exactly 1 byte into the emoji's 4-byte sequence — a genuine mid-character
    // boundary (the repeated-emoji case above always cuts on a whole-character
    // boundary, since 4000 is a multiple of 4, so it never exercises this path).
    const prefix = 'a'.repeat(3999);
    appendLog(f, prefix + '😀' + 'trailing filler to exceed the cap');
    const written = readFileSync(f);
    // Must decode as valid UTF-8 — a naive byte-slice would split the emoji's
    // 4-byte sequence and leave a dangling lead byte, which is invalid UTF-8.
    expect(() => new TextDecoder('utf-8', { fatal: true }).decode(written)).not.toThrow();
    const text = written.toString('utf8');
    // The whole-character prefix must be preserved exactly; the incomplete
    // trailing emoji byte must not corrupt or shift it.
    expect(text.startsWith(prefix)).toBe(true);
    expect(text).toMatch(/…\n$/);
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
