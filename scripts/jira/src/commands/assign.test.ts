import { describe, it, expect, vi, afterEach } from 'vitest';
import { buildAssignBody } from './assign.js';

afterEach(() => vi.restoreAllMocks());

describe('assign', () => {
  it('clears the assignee for "-"/"unassigned"/"none"', async () => {
    for (const u of ['-', 'unassigned', 'none']) {
      expect(await buildAssignBody(u)).toEqual({ accountId: null });
    }
  });
  it('uses default assignee for "auto"/"-1"', async () => {
    for (const u of ['auto', '-1']) {
      expect(await buildAssignBody(u)).toEqual({ accountId: '-1' });
    }
  });
  it('passes a raw accountId through', async () => {
    expect(await buildAssignBody('5b10ac8d82e05b22cc7d4ef5')).toEqual({
      accountId: '5b10ac8d82e05b22cc7d4ef5',
    });
  });
  it('resolves an email to an accountId', async () => {
    process.env.JIRA_BASE_URL = 'https://x.example';
    vi.stubGlobal('fetch', vi.fn(async () => ({
      ok: true, status: 200, text: async () => '[{"accountId":"abc"}]',
    })));
    expect(await buildAssignBody('a@b.com')).toEqual({ accountId: 'abc' });
  });
});
