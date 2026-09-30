import { describe, it, expect, vi } from 'vitest';
import {
  createIssueLink,
  findLinkType,
  formatIssueLinks,
  unlinkIssueLink,
} from './link.js';

describe('findLinkType', () => {
  const types = [{ name: 'Relates' }, { name: 'Blocks' }, { name: 'Duplicate' }];

  it('matches an exact name', () => {
    expect(findLinkType(types, 'Blocks')).toEqual({ name: 'Blocks' });
  });

  it('matches case-insensitively', () => {
    expect(findLinkType(types, 'relates')).toEqual({ name: 'Relates' });
    expect(findLinkType(types, 'DUPLICATE')).toEqual({ name: 'Duplicate' });
  });

  it('returns undefined for an unknown type', () => {
    expect(findLinkType(types, 'Clones')).toBeUndefined();
  });
});

const blocks = {
  name: 'Blocks',
  inward: 'is blocked by',
  outward: 'blocks',
};

const relates = {
  name: 'Relates',
  inward: 'relates to',
  outward: 'relates to',
};

describe('formatIssueLinks', () => {
  it('renders inward and outward direction unambiguously', () => {
    expect(formatIssueLinks('HIMTEST-1', [
      { id: '10', type: blocks, outwardIssue: { key: 'HIMTEST-2' } },
      { id: '11', type: blocks, inwardIssue: { key: 'HIMTEST-3' } },
    ])).toBe(
      '10\tBlocks\tinward=HIMTEST-1\toutward=HIMTEST-2\tHIMTEST-1 is blocked by HIMTEST-2\n' +
      '11\tBlocks\tinward=HIMTEST-3\toutward=HIMTEST-1\tHIMTEST-1 blocks HIMTEST-3',
    );
  });

  it('reports an issue with no links cleanly', () => {
    expect(formatIssueLinks('HIMTEST-1', [])).toBe('HIMTEST-1: no issue links');
  });
});

describe('unlinkIssueLink', () => {
  it('resolves the link id from the inward issue and deletes it', async () => {
    const request = vi.fn()
      .mockResolvedValueOnce({
        fields: {
          issuelinks: [
            { id: '42', type: blocks, outwardIssue: { key: 'HIMTEST-2' } },
          ],
        },
      })
      .mockResolvedValueOnce({});

    await expect(
      unlinkIssueLink('HIMTEST-1', 'HIMTEST-2', undefined, request),
    ).resolves.toMatchObject({ id: '42' });
    expect(request).toHaveBeenNthCalledWith(
      1,
      'GET',
      '/issue/HIMTEST-1?fields=issuelinks',
    );
    expect(request).toHaveBeenNthCalledWith(2, 'DELETE', '/issueLink/42');
  });

  it('refuses an ambiguous pair and lists every candidate', async () => {
    const request = vi.fn().mockResolvedValueOnce({
      fields: {
        issuelinks: [
          { id: '42', type: blocks, outwardIssue: { key: 'HIMTEST-2' } },
          { id: '43', type: relates, outwardIssue: { key: 'HIMTEST-2' } },
        ],
      },
    });

    await expect(
      unlinkIssueLink('HIMTEST-1', 'HIMTEST-2', undefined, request),
    ).rejects.toThrow(
      /multiple issue links.*42\tBlocks.*43\tRelates/is,
    );
    expect(request).toHaveBeenCalledTimes(1);
  });

  it('uses --type to disambiguate case-insensitively', async () => {
    const request = vi.fn()
      .mockResolvedValueOnce({
        fields: {
          issuelinks: [
            { id: '42', type: blocks, outwardIssue: { key: 'HIMTEST-2' } },
            { id: '43', type: relates, outwardIssue: { key: 'HIMTEST-2' } },
          ],
        },
      })
      .mockResolvedValueOnce({});

    await unlinkIssueLink('HIMTEST-1', 'HIMTEST-2', 'relates', request);
    expect(request).toHaveBeenLastCalledWith('DELETE', '/issueLink/43');
  });

  it('errors clearly when the directed pair does not exist', async () => {
    const request = vi.fn().mockResolvedValueOnce({
      fields: {
        issuelinks: [
          { id: '42', type: blocks, inwardIssue: { key: 'HIMTEST-2' } },
        ],
      },
    });

    await expect(
      unlinkIssueLink('HIMTEST-1', 'HIMTEST-2', undefined, request),
    ).rejects.toThrow(
      'No issue link found with inward=HIMTEST-1, outward=HIMTEST-2.',
    );
    expect(request).toHaveBeenCalledTimes(1);
  });
});

describe('createIssueLink', () => {
  it('prints the relationship as Jira stores it (inward text), not positional order', async () => {
    const request = vi.fn().mockResolvedValue(undefined);
    const line = await createIssueLink('HIMTEST-1', 'HIMTEST-2', blocks, request);
    expect(request).toHaveBeenCalledWith('POST', '/issueLink', {
      type: { name: 'Blocks' },
      inwardIssue: { key: 'HIMTEST-1' },
      outwardIssue: { key: 'HIMTEST-2' },
    });
    expect(line).toBe('Linked: HIMTEST-1 is blocked by HIMTEST-2');
  });

  it('prints a symmetric type with its shared text', async () => {
    const request = vi.fn().mockResolvedValue(undefined);
    expect(await createIssueLink('HIMTEST-1', 'HIMTEST-2', relates, request)).toBe(
      'Linked: HIMTEST-1 relates to HIMTEST-2',
    );
  });

  it('falls back to the type name when Jira omits the inward text', async () => {
    const request = vi.fn().mockResolvedValue(undefined);
    expect(await createIssueLink('HIMTEST-1', 'HIMTEST-2', { name: 'Odd' }, request)).toBe(
      'Linked: HIMTEST-1 Odd HIMTEST-2',
    );
  });
});
