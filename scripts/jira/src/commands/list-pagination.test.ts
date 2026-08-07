import { describe, it, expect, vi } from 'vitest';
import { searchAllIssues } from './list.js';

// HIMMEL-1602. Jira Cloud's /search/jql SILENTLY clamps maxResults to 100 —
// asking for 999 returns exactly 100, with no error and nothing to say more
// exist. Every count taken through this CLI was therefore quietly truncated:
// a consolidation pass read "100 open tickets" when the real figure was 389.

const issue = (key: string) => ({
  key,
  fields: {
    summary: `s-${key}`,
    status: { name: 'To Do' },
    issuetype: { name: 'Task' },
  },
});

const pageOf = (n: number, offset = 0) =>
  Array.from({ length: n }, (_, i) => issue(`HIMMEL-${offset + i + 1}`));

describe('searchAllIssues', () => {
  it('pages past the server cap to reach a limit above 100', async () => {
    const req = vi
      .fn()
      .mockResolvedValueOnce({ issues: pageOf(100, 0), total: 250, nextPageToken: 't1' })
      .mockResolvedValueOnce({ issues: pageOf(100, 100), total: 250, nextPageToken: 't2' })
      .mockResolvedValueOnce({ issues: pageOf(50, 200), total: 250 });

    const out = await searchAllIssues('project = HIMMEL', '1000', req as never);

    expect(out).toHaveLength(250);
    expect(req).toHaveBeenCalledTimes(3);
    // never asks the server for more than it will give
    for (const call of req.mock.calls) {
      const m = /maxResults=(\d+)/.exec(call[1] as string);
      expect(Number(m?.[1])).toBeLessThanOrEqual(100);
    }
  });

  it('forwards the cursor on subsequent pages only', async () => {
    const req = vi
      .fn()
      .mockResolvedValueOnce({ issues: pageOf(100), total: 150, nextPageToken: 'tok en/+1' })
      .mockResolvedValueOnce({ issues: pageOf(50, 100), total: 150 });

    await searchAllIssues('x', '150', req as never);

    expect(req.mock.calls[0][1]).not.toContain('nextPageToken');
    // cursor must be URL-encoded — a raw token with / or + would corrupt the query
    expect(req.mock.calls[1][1]).toContain(`nextPageToken=${encodeURIComponent('tok en/+1')}`);
  });

  it('stops at the limit and does not over-fetch', async () => {
    const req = vi
      .fn()
      .mockResolvedValueOnce({ issues: pageOf(100), total: 500, nextPageToken: 't1' });

    const out = await searchAllIssues('x', '100', req as never);

    expect(out).toHaveLength(100);
    expect(req).toHaveBeenCalledTimes(1);
  });

  it('trims a final page that overshoots the limit', async () => {
    const req = vi.fn().mockResolvedValueOnce({ issues: pageOf(100), total: 100 });
    const out = await searchAllIssues('x', '30', req as never);
    expect(out).toHaveLength(30);
  });

  it('single request when the limit is under the cap', async () => {
    const req = vi.fn().mockResolvedValueOnce({ issues: pageOf(25), total: 25 });
    await searchAllIssues('x', '25', req as never);
    expect(req).toHaveBeenCalledTimes(1);
    expect(req.mock.calls[0][1]).toContain('maxResults=25');
  });

  it('terminates on an empty page even if a token is returned', async () => {
    // Without the empty-page guard this spins forever.
    const req = vi.fn().mockResolvedValue({ issues: [], total: 0, nextPageToken: 'loop' });
    const out = await searchAllIssues('x', '1000', req as never);
    expect(out).toHaveLength(0);
    expect(req).toHaveBeenCalledTimes(1);
  });

  it('falls back to the default for a non-numeric or non-positive limit', async () => {
    const req = vi.fn().mockResolvedValue({ issues: pageOf(25), total: 25 });
    for (const bad of ['abc', '0', '-5', '']) {
      req.mockClear();
      await searchAllIssues('x', bad, req as never);
      expect(req.mock.calls[0][1]).toContain('maxResults=25');
    }
  });
});
