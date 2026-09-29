import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, readFileSync, readdirSync, rmSync, existsSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runMirror, renderIssue, qmdRefresh, mirrorAgeMinutes, scrubEmails } from './mirror.js';
import type { MirrorIssue, Req } from './mirror.js';

// HIMMEL-3889. Stubbed Jira API: paging, cursor, idempotence, edit, delete.

const issue = (n: number, over: Partial<MirrorIssue['fields']> = {}): MirrorIssue => ({
  key: `HIMMEL-${n}`,
  fields: {
    summary: `summary ${n}`,
    status: { name: 'To Do', statusCategory: { name: 'To Do' } },
    issuetype: { name: 'Task' },
    priority: { name: 'Medium' },
    labels: ['a'],
    fixVersions: [{ name: 'v1.0.0' }],
    created: '2026-09-01T00:00:00.000+0000',
    updated: '2026-09-02T00:00:00.000+0000',
    comment: { comments: [], total: 0 },
    ...over,
  },
});

interface Stub { issues: MirrorIssue[]; pageSize: number; failKeyList?: boolean; count?: number; windowed?: MirrorIssue[]; calls: string[] }

// Fake /search/jql (token paging), /search/approximate-count and comments.
function makeReq(stub: Stub): Req {
  return (async (method: string, path: string) => {
    stub.calls.push(`${method} ${path}`);
    if (path.startsWith('/search/approximate-count')) return { count: stub.count ?? stub.issues.length };
    if (path.startsWith('/search/jql')) {
      const keysOnly = path.includes('fields=key&');
      if (keysOnly && stub.failKeyList) throw new Error('HTTP 500');
      const start = Number(/nextPageToken=(\d+)/.exec(path)?.[1] ?? 0);
      const pool = stub.windowed && decodeURIComponent(path).includes('updated >=') ? stub.windowed : stub.issues;
      const slice = pool.slice(start, start + stub.pageSize);
      const next = start + stub.pageSize < pool.length ? String(start + stub.pageSize) : undefined;
      return { issues: slice, nextPageToken: next };
    }
    throw new Error(`unexpected ${method} ${path}`);
  }) as unknown as Req;
}

let root: string;
beforeEach(() => { root = mkdtempSync(join(tmpdir(), 'jira-mirror-')); });
afterEach(() => { rmSync(root, { recursive: true, force: true }); });
const mdFiles = () => readdirSync(root).filter((n) => n.endsWith('.md')).sort();

describe('runMirror', () => {
  it('full backfill pages through every issue and matches the Jira total', async () => {
    const stub: Stub = { issues: [1, 2, 3, 4, 5].map((n) => issue(n)), pageSize: 2, calls: [] };
    const r = await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    expect(r).toMatchObject({ mode: 'full', fetched: 5, written: 5, mirrorCount: 5, jiraTotal: 5 });
    expect(mdFiles()).toHaveLength(5);
  });

  it('keeps paging past an empty page that still carries a nextPageToken', async () => {
    const stub: Stub = { issues: [issue(1), issue(2), issue(3)], pageSize: 2, calls: [] };
    const inner = makeReq(stub);
    let first = true;
    const req = (async (m: string, p: string, b?: unknown) => {
      if (first && p.startsWith('/search/jql') && !p.includes('nextPageToken')) {
        first = false;
        return { issues: [], nextPageToken: '0' };
      }
      return (inner as unknown as (m: string, p: string, b?: unknown) => Promise<unknown>)(m, p, b);
    }) as unknown as Req;
    const r = await runMirror({ root, project: 'HIMMEL' }, req);
    expect(r.fetched).toBe(3);
  });

  it('is idempotent: a second run with no changes writes nothing', async () => {
    const stub: Stub = { issues: [issue(1), issue(2)], pageSize: 10, calls: [] };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    const r = await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    expect(r).toMatchObject({ mode: 'incremental', written: 0, unchanged: 2, deleted: 0 });
  });

  it('uses a relative-minute updated>= JQL on incremental runs', async () => {
    const stub: Stub = { issues: [issue(1)], pageSize: 10, calls: [] };
    const t0 = new Date('2026-09-30T10:00:00Z');
    await runMirror({ root, project: 'HIMMEL', now: () => t0 }, makeReq(stub));
    stub.calls.length = 0;
    await runMirror({ root, project: 'HIMMEL', now: () => new Date('2026-09-30T10:30:00Z') }, makeReq(stub));
    const jql = decodeURIComponent(stub.calls.find((c) => c.includes('updated'))!);
    expect(jql).toContain('updated >= "-40m"');
  });

  it('an edited issue changes on the next incremental run', async () => {
    const stub: Stub = { issues: [issue(1), issue(2)], pageSize: 10, calls: [] };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    stub.issues[1] = issue(2, { summary: 'edited title', status: { name: 'Done', statusCategory: { name: 'Done' } } });
    const r = await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    expect(r).toMatchObject({ written: 1, unchanged: 1 });
    const md = readFileSync(join(root, 'HIMMEL-2.md'), 'utf8');
    expect(md).toContain('edited title');
    expect(md).toContain('status: "Done"');
  });

  it('removes the file of a deleted/moved issue', async () => {
    const stub: Stub = { issues: [issue(1), issue(2), issue(3)], pageSize: 10, calls: [] };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    stub.issues = [issue(1), issue(3)];
    const r = await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    expect(r.deleted).toBe(1);
    expect(mdFiles()).toEqual(['HIMMEL-1.md', 'HIMMEL-3.md']);
  });

  it('fails safe: a failing key listing deletes nothing and warns', async () => {
    const stub: Stub = { issues: [issue(1), issue(2)], pageSize: 10, calls: [] };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    stub.issues = [issue(1)];
    stub.failKeyList = true;
    const warn = vi.fn();
    const r = await runMirror({ root, project: 'HIMMEL', warn }, makeReq(stub));
    expect(r.deleted).toBe(0);
    expect(r.deleteSkipped).toContain('key listing failed');
    expect(warn).toHaveBeenCalled();
    expect(mdFiles()).toHaveLength(2);
  });

  it('fails safe: a key listing under 50% of local files deletes nothing', async () => {
    const stub: Stub = { issues: [1, 2, 3, 4].map((n) => issue(n)), pageSize: 10, calls: [] };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    stub.issues = [issue(1)];
    const r = await runMirror({ root, project: 'HIMMEL', warn: vi.fn() }, makeReq(stub));
    expect(r.deleted).toBe(0);
    expect(r.deleteSkipped).toContain('%');
    expect(mdFiles()).toHaveLength(4);
  });

  it('fails safe: a listing well short of the Jira count deletes nothing', async () => {
    const stub: Stub = { issues: [1, 2, 3, 4].map((n) => issue(n)), pageSize: 10, calls: [] };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    stub.issues = [issue(1), issue(2), issue(3)];
    stub.count = 4;
    const r = await runMirror({ root, project: 'HIMMEL', warn: vi.fn() }, makeReq(stub));
    expect(r.deleted).toBe(0);
    expect(r.deleteSkipped).toContain('Jira counts 4');
    expect(mdFiles()).toHaveLength(4);
  });

  it('a truncated backfill keeps no cursor, so the next run is a full backfill', async () => {
    const stub: Stub = { issues: [1, 2, 3].map((n) => issue(n)), pageSize: 10, calls: [], count: 10 };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    stub.count = undefined;
    const r = await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    expect(r.mode).toBe('full');
  });

  it('an incremental run that finds a live key missing locally drops the cursor', async () => {
    const stub: Stub = { issues: [1, 2, 3].map((n) => issue(n)), pageSize: 10, calls: [] };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    rmSync(join(root, 'HIMMEL-2.md'));
    stub.windowed = [];
    const r = await runMirror({ root, project: 'HIMMEL', warn: vi.fn() }, makeReq(stub));
    expect(r.mode).toBe('incremental');
    expect(r.deleteSkipped).toBe('live keys missing locally');
    stub.windowed = undefined;
    expect((await runMirror({ root, project: 'HIMMEL' }, makeReq(stub))).mode).toBe('full');
  });

  it('a short run drops an existing cursor', async () => {
    const stub: Stub = { issues: [1, 2, 3].map((n) => issue(n)), pageSize: 10, calls: [] };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    stub.count = 10;
    await runMirror({ root, project: 'HIMMEL', warn: vi.fn() }, makeReq(stub));
    stub.count = undefined;
    const r = await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    expect(r.mode).toBe('full');
  });

  it('a cursor from another project neither drives the window nor lets deletes reach its files', async () => {
    const other: Stub = { issues: [{ ...issue(1), key: 'OTHER-1' }], pageSize: 10, calls: [] };
    await runMirror({ root, project: 'OTHER' }, makeReq(other));
    const stub: Stub = { issues: [issue(1), issue(2)], pageSize: 10, calls: [] };
    const r = await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    expect(r.mode).toBe('full');
    expect(r.deleted).toBe(0);
    expect(existsSync(join(root, 'OTHER-1.md'))).toBe(true);
  });

  it('does not refetch comments the search page already embedded in full', async () => {
    const c = (id: string) => ({ id, author: { displayName: 'Ann' }, created: `2026-09-0${id}T00:00:00Z`, body: null });
    const stub: Stub = {
      issues: [issue(1, { comment: { comments: [c('1')], total: 1 } })],
      pageSize: 10,
      calls: [],
    };
    await runMirror({ root, project: 'HIMMEL' }, makeReq(stub));
    expect(stub.calls.some((x) => x.includes('/comment'))).toBe(false);
  });
});

describe('renderIssue', () => {
  it('writes frontmatter, description and comments by display name only, no emails', () => {
    const md = renderIssue(
      issue(7, {
        description: { type: 'doc', version: 1, content: [{ type: 'paragraph', content: [{ type: 'text', text: 'mail bob@example.com about zebra widgets' }] }] } as never,
        parent: { key: 'HIMMEL-1' },
        issuelinks: [{ type: { outward: 'blocks', inward: 'is blocked by' }, outwardIssue: { key: 'HIMMEL-8' } }],
      }),
      [{ id: '1', author: { displayName: 'Ann Lee' }, created: '2026-09-03T00:00:00Z', body: null }],
    );
    expect(md).toContain('key: "HIMMEL-7"');
    expect(md).toContain('parent: "HIMMEL-1"');
    expect(md).toContain('  blocks: ["HIMMEL-8"]');
    expect(md).toContain('zebra widgets');
    expect(md).toContain('Ann Lee');
    expect(md).not.toContain('bob@example.com');
  });

  it('scrubs address-shaped text out of frontmatter values too', () => {
    const md = renderIssue(issue(9, { labels: ['owner@corp.io'], fixVersions: [{ name: 'v1 x@y.org' }] }), []);
    expect(md).not.toMatch(/@corp\.io|@y\.org/);
    expect(md).toContain('[email]');
  });

  it('scrubEmails replaces address-shaped text', () => {
    expect(scrubEmails('a.b+c@x.co and d@y.org')).toBe('[email] and [email]');
  });
});

describe('cursor + qmd', () => {
  it('mirrorAgeMinutes is null before any sync and counts minutes after', async () => {
    expect(mirrorAgeMinutes(root)).toBeNull();
    const stub: Stub = { issues: [issue(1)], pageSize: 10, calls: [] };
    await runMirror({ root, project: 'HIMMEL', now: () => new Date('2026-09-30T10:00:00Z') }, makeReq(stub));
    expect(mirrorAgeMinutes(root, new Date('2026-09-30T10:45:00Z'))).toBe(45);
  });

  it('a corrupt cursor falls back to a full run', async () => {
    writeFileSync(join(root, '.cursor.json'), '{nope');
    const stub: Stub = { issues: [issue(1)], pageSize: 10, calls: [] };
    expect((await runMirror({ root, project: 'HIMMEL' }, makeReq(stub))).mode).toBe('full');
    expect(existsSync(join(root, '.cursor.json'))).toBe(true);
  });

  it('qmdRefresh registers a missing collection, then updates and embeds', () => {
    const run = vi.fn().mockReturnValueOnce('himmel (qmd://himmel/)').mockReturnValue('');
    expect(qmdRefresh(root, run)).toContain('updated and embedded');
    expect(run.mock.calls.map((c) => (c[0] as string[]).join(' '))).toEqual([
      'collection list',
      `collection add ${root} --name jira-himmel`,
      'update',
      'embed -c jira-himmel',
    ]);
  });

  it('qmdRefresh does not re-register an existing collection and never throws', () => {
    const run = vi.fn()
      .mockReturnValueOnce('jira-himmel (qmd://jira-himmel/)')
      .mockReturnValueOnce(`Collection: jira-himmel\n  Path:     ${root}\n`)
      .mockReturnValueOnce('')
      .mockImplementation(() => { throw new Error('embed boom'); });
    const msg = qmdRefresh(root, run);
    expect(msg).toContain('FAILED');
    expect(msg).toContain('sync itself succeeded');
    expect(run.mock.calls.some((c) => (c[0] as string[])[1] === 'add')).toBe(false);
  });

  it('qmdRefresh refuses to embed a collection that points at a different root', () => {
    const run = vi.fn()
      .mockReturnValueOnce('jira-himmel (qmd://jira-himmel/)')
      .mockReturnValueOnce('Collection: jira-himmel\n  Path:     /elsewhere/OTHER\n')
      .mockReturnValue('');
    const msg = qmdRefresh(root, run);
    expect(msg).toContain('FAILED');
    expect(msg).toContain('/elsewhere/OTHER');
    expect(run.mock.calls.some((c) => (c[0] as string[])[0] === 'embed')).toBe(false);
  });
});
