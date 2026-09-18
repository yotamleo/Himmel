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

describe('registerComments (comments <key>)', () => {
  it('GETs /issue/<key>/comment', async () => {
    mockRequest.mockResolvedValue({ comments: [] });
    const p = freshProgram();
    await p.parseAsync(['node', 'jira', 'comments', 'HIMMEL-1']);
    expect(mockRequest).toHaveBeenCalledWith('GET', '/issue/HIMMEL-1/comment');
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
