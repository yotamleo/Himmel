import { describe, it, expect } from 'vitest';
import { rankIssue, rankOrder, parseOrderFile } from './rank.js';

interface Call { method: string; path: string; body?: unknown }

function stub(answer: unknown = '') {
  const calls: Call[] = [];
  const req = (async (method: string, path: string, body?: unknown) => {
    calls.push({ method, path, body });
    return answer;
  }) as never;
  return { req, calls };
}

describe('rankIssue', () => {
  it('ranks one issue before another', async () => {
    const { req, calls } = stub();
    expect(await rankIssue('HIMMEL-2', { before: 'HIMMEL-1' }, req)).toBe('HIMMEL-2 ranked before HIMMEL-1');
    expect(calls).toEqual([{ method: 'PUT', path: '/issue/rank', body: { issues: ['HIMMEL-2'], rankBeforeIssue: 'HIMMEL-1' } }]);
  });

  it('ranks one issue after another', async () => {
    const { req, calls } = stub();
    await rankIssue('HIMMEL-2', { after: 'HIMMEL-1' }, req);
    expect(calls[0].body).toEqual({ issues: ['HIMMEL-2'], rankAfterIssue: 'HIMMEL-1' });
  });

  it('needs exactly one of before/after', async () => {
    const { req } = stub();
    await expect(rankIssue('HIMMEL-2', {}, req)).rejects.toThrow(/exactly one/);
    await expect(rankIssue('HIMMEL-2', { before: 'A-1', after: 'A-2' }, req)).rejects.toThrow(/exactly one/);
  });

  it('fails loud on a partial 207 answer', async () => {
    const { req } = stub({ entries: [{ issueKey: 'HIMMEL-2', status: 400, errors: ['nope'] }] });
    await expect(rankIssue('HIMMEL-2', { after: 'HIMMEL-1' }, req)).rejects.toThrow(/HIMMEL-2.*nope/);
  });
});

describe('rankOrder', () => {
  it('ranks a list top-down in chunks of 50, each after the previous chunk tail', async () => {
    const keys = Array.from({ length: 102 }, (_, i) => `HIMMEL-${i + 1}`);
    const { req, calls } = stub();
    expect(await rankOrder(keys, req)).toBe('ranked 101 issues after HIMMEL-1');
    expect(calls.map((c) => [(c.body as { issues: string[] }).issues.length, (c.body as { rankAfterIssue: string }).rankAfterIssue])).toEqual([
      [50, 'HIMMEL-1'],
      [50, 'HIMMEL-51'],
      [1, 'HIMMEL-101'],
    ]);
  });

  it('needs at least two keys', async () => {
    const { req } = stub();
    await expect(rankOrder(['HIMMEL-1'], req)).rejects.toThrow(/at least two/);
  });
});

describe('parseOrderFile', () => {
  it('reads one key per line, skipping blanks and # comments', () => {
    expect(parseOrderFile('HIMMEL-1\n\n# top\n HIMMEL-2 \n')).toEqual(['HIMMEL-1', 'HIMMEL-2']);
  });

  it('rejects a non-key line and a duplicate', () => {
    expect(() => parseOrderFile('HIMMEL-1\nfoo\n')).toThrow(/foo/);
    expect(() => parseOrderFile('HIMMEL-1\nHIMMEL-1\n')).toThrow(/duplicate/);
  });
});
