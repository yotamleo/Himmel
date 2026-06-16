import { describe, it, expect, beforeEach } from 'vitest';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { writeEntry, readEntry, listEntries, generateRunId } from '../src/index-store.js';
import type { IndexEntry } from '../src/types.js';

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'himmel-idx-'));
});

describe('index-store', () => {
  it('generateRunId returns 16-char id', () => {
    const id = generateRunId();
    expect(id).toMatch(/^[a-z0-9-]{8,}$/);
  });

  it('writeEntry + readEntry roundtrip', () => {
    const entry: IndexEntry = {
      runId: 'abc-123',
      tag: 'jira',
      cmd: ['node', 'x.js'],
      exitCode: 0,
      summary: 'OK',
      bytesToClient: 32,
      startedAt: '2026-05-23T00:00:00Z',
      finishedAt: '2026-05-23T00:00:01Z',
      logOffsetStart: 0,
      logOffsetEnd: 100,
      errOffsetStart: 0,
      errOffsetEnd: 0,
    };
    writeEntry(dir, entry);
    const back = readEntry(dir, 'abc-123');
    expect(back).toEqual(entry);
  });

  it('readEntry returns null for corrupt JSON', () => {
    // Write corrupt JSON to simulate disk corruption
    writeFileSync(join(dir, 'bad-run.json'), '{not valid json');
    const result = readEntry(dir, 'bad-run');
    expect(result).toBeNull();
  });

  it('readEntry returns null for entry with missing required fields', () => {
    writeFileSync(join(dir, 'partial-run.json'), JSON.stringify({ runId: 'partial-run' }));
    const result = readEntry(dir, 'partial-run');
    expect(result).toBeNull();
  });

  it('listEntries returns ids sorted by mtime (oldest first)', async () => {
    const e = (id: string): IndexEntry => ({
      runId: id,
      tag: 'jira',
      cmd: ['echo'] as [string, ...string[]],
      exitCode: 0,
      summary: '',
      bytesToClient: 0,
      startedAt: '',
      finishedAt: '',
      logOffsetStart: 0,
      logOffsetEnd: 0,
      errOffsetStart: 0,
      errOffsetEnd: 0,
    });
    writeEntry(dir, e('a'));
    // Small delay to ensure distinct mtime values on filesystems with 1ms resolution
    await new Promise((r) => setTimeout(r, 5));
    writeEntry(dir, e('b'));
    await new Promise((r) => setTimeout(r, 5));
    writeEntry(dir, e('c'));
    const ids = listEntries(dir);
    expect(ids).toEqual(['a', 'b', 'c']);
  });
});

describe('readEntry tightened shape validation', () => {
  const baseValid = {
    runId: 'v1',
    tag: 'jira',
    cmd: ['node', 'x.js'],
    exitCode: 0,
    summary: 'OK',
    bytesToClient: 32,
    startedAt: '2026-05-23T00:00:00Z',
    finishedAt: '2026-05-23T00:00:01Z',
    logOffsetStart: 0,
    logOffsetEnd: 10,
    errOffsetStart: 0,
    errOffsetEnd: 0,
  };

  for (const missing of ['exitCode', 'summary', 'bytesToClient', 'startedAt', 'finishedAt'] as const) {
    it(`returns null when '${missing}' is missing`, () => {
      const partial: Record<string, unknown> = { ...baseValid };
      delete partial[missing];
      writeFileSync(join(dir, 'p.json'), JSON.stringify(partial));
      expect(readEntry(dir, 'p')).toBeNull();
    });
  }

  it('returns null when exitCode is a string (wrong type)', () => {
    writeFileSync(join(dir, 'p.json'), JSON.stringify({ ...baseValid, exitCode: '0' }));
    expect(readEntry(dir, 'p')).toBeNull();
  });

  it('returns null when summary is a number (wrong type)', () => {
    writeFileSync(join(dir, 'p.json'), JSON.stringify({ ...baseValid, summary: 42 }));
    expect(readEntry(dir, 'p')).toBeNull();
  });

  it('returns null when bytesToClient is not a number', () => {
    writeFileSync(join(dir, 'p.json'), JSON.stringify({ ...baseValid, bytesToClient: '32' }));
    expect(readEntry(dir, 'p')).toBeNull();
  });

  it('returns the entry when ALL required fields are present and of correct type', () => {
    writeFileSync(join(dir, 'v1.json'), JSON.stringify(baseValid));
    expect(readEntry(dir, 'v1')).toEqual(baseValid);
  });
});
