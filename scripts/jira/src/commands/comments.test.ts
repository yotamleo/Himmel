import { describe, it, expect, vi, beforeEach } from 'vitest';
import { Command } from 'commander';

vi.mock('../client.js', () => ({ request: vi.fn() }));

import { request } from '../client.js';
import { registerComments, formatComments, selectComments } from './comments.js';
import type { JiraCommentEntry } from './comments.js';

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;

function freshProgram(): Command {
  const p = new Command();
  p.exitOverride();
  registerComments(p);
  return p;
}

function comment(id: string, created: string, text = 'x'): JiraCommentEntry {
  return {
    id,
    created,
    author: { displayName: `author-${id}` },
    body: { type: 'doc', version: 1, content: [{ type: 'paragraph', content: [{ type: 'text', text }] }] },
  };
}

beforeEach(() => {
  vi.clearAllMocks();
  // clearAllMocks keeps queued mockResolvedValueOnce values, which would leak
  // one test's unconsumed page into the next
  mockRequest.mockReset();
  vi.spyOn(console, 'log').mockImplementation(() => {});
});

describe('selectComments', () => {
  it('sorts oldest first regardless of API-returned order', () => {
    const out = selectComments([
      comment('2', '2026-01-02T00:00:00.000Z'),
      comment('1', '2026-01-01T00:00:00.000Z'),
    ]);
    expect(out.map((c) => c.id)).toEqual(['1', '2']);
  });

  it('--last N keeps the N most recent, still oldest-first among those', () => {
    const out = selectComments(
      [comment('1', '2026-01-01'), comment('2', '2026-01-02'), comment('3', '2026-01-03')],
      '2',
    );
    expect(out.map((c) => c.id)).toEqual(['2', '3']);
  });

  it('a non-numeric or non-positive --last falls back to no limit', () => {
    const all = [comment('1', '2026-01-01'), comment('2', '2026-01-02')];
    expect(selectComments(all, 'nope').map((c) => c.id)).toEqual(['1', '2']);
    expect(selectComments(all, '0').map((c) => c.id)).toEqual(['1', '2']);
  });
});

describe('formatComments', () => {
  it('renders author, created time, and the ADF body as plain text', () => {
    const out = formatComments([comment('1', '2026-01-01T00:00:00.000Z', 'hello world')]);
    expect(out).toContain('author-1');
    expect(out).toContain('2026-01-01T00:00:00.000Z');
    expect(out).toContain('hello world');
  });

  it('reports no comments when the issue has none', () => {
    expect(formatComments([])).toBe('No comments on this issue.');
  });
});

// HIMMEL-3164. Jira paginates /issue/<key>/comment (startAt/maxResults/total);
// a single GET silently drops everything past the first page, and `--last N`
// then slices the tail of that first page instead of the newest N.
function pageOf(n: number, from: number): JiraCommentEntry[] {
  return Array.from({ length: n }, (_, i) => {
    const seq = from + i;
    // zero-padded day so the ISO strings sort in `seq` order
    return comment(String(seq), `2026-01-${String(seq).padStart(2, '0')}T00:00:00.000Z`, `body-${seq}`);
  });
}

describe('registerComments (comments <key>)', () => {
  it('GETs /issue/<key>/comment starting at offset 0', async () => {
    mockRequest.mockResolvedValue({ comments: [], startAt: 0, maxResults: 50, total: 0 });
    const p = freshProgram();
    await p.parseAsync(['node', 'jira', 'comments', 'HIMMEL-1']);
    expect(mockRequest).toHaveBeenCalledTimes(1);
    const [method, path] = mockRequest.mock.calls[0];
    expect(method).toBe('GET');
    expect(path).toContain('/issue/HIMMEL-1/comment?');
    expect(path).toContain('startAt=0');
  });

  it('pages through the endpoint: all 52 comments across two pages are printed', async () => {
    mockRequest
      .mockResolvedValueOnce({ comments: pageOf(50, 1), startAt: 0, maxResults: 50, total: 52 })
      .mockResolvedValueOnce({ comments: pageOf(2, 51), startAt: 50, maxResults: 50, total: 52 });
    const p = freshProgram();
    const logSpy = vi.spyOn(console, 'log');
    await p.parseAsync(['node', 'jira', 'comments', 'HIMMEL-1']);
    const out = logSpy.mock.calls.map((c) => c[0]).join('\n');
    expect(out.match(/^author-\d+\t/gm)).toHaveLength(52);
    expect(out).toContain('body-52');
    expect(mockRequest).toHaveBeenCalledTimes(2);
    expect(mockRequest.mock.calls[1][1]).toContain('startAt=50');
  });

  it('--last 2 yields the two newest comments (from page 2), not the tail of page 1', async () => {
    mockRequest
      .mockResolvedValueOnce({ comments: pageOf(50, 1), startAt: 0, maxResults: 50, total: 52 })
      .mockResolvedValueOnce({ comments: pageOf(2, 51), startAt: 50, maxResults: 50, total: 52 });
    const p = freshProgram();
    const logSpy = vi.spyOn(console, 'log');
    await p.parseAsync(['node', 'jira', 'comments', 'HIMMEL-1', '--last', '2']);
    const out = logSpy.mock.calls.map((c) => c[0]).join('\n');
    expect(out.match(/^author-\d+\t/gm)).toEqual(['author-51\t', 'author-52\t']);
    expect(out).not.toContain('body-50');
  });

  it('stops on an empty page even when total lies (no infinite loop)', async () => {
    mockRequest
      .mockResolvedValueOnce({ comments: pageOf(3, 1), startAt: 0, maxResults: 50, total: 999 })
      .mockResolvedValue({ comments: [], startAt: 3, maxResults: 50, total: 999 });
    const p = freshProgram();
    const logSpy = vi.spyOn(console, 'log');
    await p.parseAsync(['node', 'jira', 'comments', 'HIMMEL-1']);
    const out = logSpy.mock.calls.map((c) => c[0]).join('\n');
    expect(out.match(/^author-\d+\t/gm)).toHaveLength(3);
    expect(mockRequest).toHaveBeenCalledTimes(2);
  });

  it('a single page that already covers total makes exactly one request', async () => {
    mockRequest.mockResolvedValue({ comments: pageOf(3, 1), startAt: 0, maxResults: 50, total: 3 });
    const p = freshProgram();
    await p.parseAsync(['node', 'jira', 'comments', 'HIMMEL-1']);
    expect(mockRequest).toHaveBeenCalledTimes(1);
  });

  it('prints oldest-first, honoring --last', async () => {
    mockRequest.mockResolvedValue({
      comments: [comment('2', '2026-01-02T00:00:00.000Z', 'second'), comment('1', '2026-01-01T00:00:00.000Z', 'first')],
    });
    const p = freshProgram();
    const logSpy = vi.spyOn(console, 'log');
    await p.parseAsync(['node', 'jira', 'comments', 'HIMMEL-1', '--last', '1']);
    const out = logSpy.mock.calls.map((c) => c[0]).join('\n');
    expect(out).toContain('second');
    expect(out).not.toContain('first');
  });
});
