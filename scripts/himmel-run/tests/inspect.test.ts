import { describe, it, expect, beforeEach } from 'vitest';
import { mkdtempSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { inspect } from '../src/inspect.js';
import { writeEntry } from '../src/index-store.js';

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'himmel-insp-'));
});

describe('inspect', () => {
  it('returns log slice between offsets for the runId', async () => {
    const tDir = join(dir, 'jira');
    const idx = join(tDir, 'index');
    mkdirSync(idx, { recursive: true });
    writeFileSync(join(tDir, 'normal.log'), 'AAAhelloBBB');
    writeEntry(idx, {
      runId: 'r1', tag: 'jira', cmd: ['echo'], exitCode: 0,
      summary: 'hello', bytesToClient: 0, startedAt: '', finishedAt: '',
      logOffsetStart: 3, logOffsetEnd: 8, errOffsetStart: 0, errOffsetEnd: 0,
    });
    const out = await inspect('jira', 'r1', dir);
    // Assert the exact stdout slice, not merely that it contains 'hello' —
    // toContain('hello') also passes if inspect ignores the offsets and
    // returns the whole file (which still contains 'hello' inside
    // 'AAAhelloBBB'). Pull out the section between the stdout/stderr
    // markers and require it to be precisely the sliced bytes, excluding
    // both surrounding sentinels.
    const stdoutSection = out.split('--- stdout ---\n')[1]?.split('\n--- stderr ---')[0];
    expect(stdoutSection).toBe('hello');
  });

  // B10: tag path traversal
  it('throws on tag with path separator', async () => {
    await expect(inspect('foo/bar', 'r1', dir)).rejects.toThrow('invalid tag');
  });

  it('throws on tag ".."', async () => {
    await expect(inspect('..', 'r1', dir)).rejects.toThrow('invalid tag');
  });
});
