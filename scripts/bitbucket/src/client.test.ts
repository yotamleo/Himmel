import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  getUser,
  getRepo,
  getRepoForIngest,
  getPr,
  getIssue,
  createPr,
  editPr,
  mergePr,
  listPrs,
  createIssue,
  listPrComments,
  replyPrComment,
  resolvePrComment,
  BitbucketHttpError,
  _resetClient,
} from './client.js';
import { resolveSlug } from './output.js';

function jsonRes(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(typeof body === 'string' ? body : JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...headers },
  });
}

// Captures the URL of each fetch call (Request object or string).
function reqUrl(arg: unknown): string {
  return arg instanceof Request ? arg.url : String(arg);
}

describe('bitbucket client', () => {
  const saved = {
    email: process.env.BITBUCKET_EMAIL,
    token: process.env.BITBUCKET_API_TOKEN,
    ws: process.env.BITBUCKET_WORKSPACE,
    slug: process.env.BITBUCKET_REPO_SLUG,
    backoff: process.env.BITBUCKET_RETRY_BASE_MS,
  };

  beforeEach(() => {
    process.env.BITBUCKET_EMAIL = 'u@example.com';
    process.env.BITBUCKET_API_TOKEN = 'secret';
    process.env.BITBUCKET_WORKSPACE = 'myws';
    process.env.BITBUCKET_REPO_SLUG = 'myrepo';
    process.env.BITBUCKET_RETRY_BASE_MS = '0'; // no real delay in tests
    _resetClient();
  });

  afterEach(() => {
    for (const [k, v] of Object.entries({
      BITBUCKET_EMAIL: saved.email,
      BITBUCKET_API_TOKEN: saved.token,
      BITBUCKET_WORKSPACE: saved.ws,
      BITBUCKET_REPO_SLUG: saved.slug,
      BITBUCKET_RETRY_BASE_MS: saved.backoff,
    })) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
    vi.restoreAllMocks();
    _resetClient();
  });

  it('getUser parses identity fields and sends a Basic auth header', async () => {
    let seenAuth = '';
    const fetchMock = vi.fn(async (arg: unknown) => {
      if (arg instanceof Request) seenAuth = arg.headers.get('authorization') ?? '';
      return jsonRes(200, { nickname: 'nick', account_id: 'acc', uuid: '{u}', display_name: 'Nick' });
    });
    vi.stubGlobal('fetch', fetchMock);

    const u = await getUser();
    expect(u.nickname).toBe('nick');
    expect(u.account_id).toBe('acc');
    expect(reqUrl(fetchMock.mock.calls[0][0])).toBe('https://api.bitbucket.org/2.0/user');
    expect(seenAuth).toMatch(/^Basic /);
  });

  it('getRepo maps full_name + mainbranch.name → default_branch', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => jsonRes(200, { full_name: 'myws/myrepo', mainbranch: { name: 'main' } })),
    );
    const r = await getRepo();
    expect(r).toEqual({
      workspace: 'myws',
      repo_slug: 'myrepo',
      full_name: 'myws/myrepo',
      default_branch: 'main',
    });
  });

  it('createPr posts title/description/source/destination and returns id+url', async () => {
    let body: unknown;
    const fetchMock = vi.fn(async (arg: unknown) => {
      if (arg instanceof Request) body = JSON.parse(await arg.text());
      return jsonRes(201, {
        id: 7,
        title: 'T',
        state: 'OPEN',
        source: { branch: { name: 'feat/x' } },
        links: { html: { href: 'https://bitbucket.org/myws/myrepo/pull-requests/7' } },
      });
    });
    vi.stubGlobal('fetch', fetchMock);

    const pr = await createPr({ title: 'T', body: 'B', source: 'feat/x', destination: 'main' });
    expect(pr).toEqual({
      id: 7,
      title: 'T',
      state: 'OPEN',
      source_branch: 'feat/x',
      url: 'https://bitbucket.org/myws/myrepo/pull-requests/7',
    });
    expect(body).toMatchObject({
      title: 'T',
      description: 'B',
      source: { branch: { name: 'feat/x' } },
      destination: { branch: { name: 'main' } },
    });
    expect(reqUrl(fetchMock.mock.calls[0][0])).toBe(
      'https://api.bitbucket.org/2.0/repositories/myws/myrepo/pullrequests',
    );
  });

  it('editPr PUTs title+description and returns the updated PrInfo', async () => {
    let body: unknown;
    let method = '';
    const fetchMock = vi.fn(async (arg: unknown) => {
      if (arg instanceof Request) {
        method = arg.method;
        body = JSON.parse(await arg.text());
      }
      return jsonRes(200, {
        id: 7,
        title: 'New T',
        state: 'OPEN',
        source: { branch: { name: 'feat/x' } },
        links: { html: { href: 'https://bitbucket.org/myws/myrepo/pull-requests/7' } },
      });
    });
    vi.stubGlobal('fetch', fetchMock);

    const pr = await editPr(7, { title: 'New T', body: 'New B' });
    expect(pr).toEqual({
      id: 7,
      title: 'New T',
      state: 'OPEN',
      source_branch: 'feat/x',
      url: 'https://bitbucket.org/myws/myrepo/pull-requests/7',
    });
    expect(method).toBe('PUT');
    expect(body).toMatchObject({ title: 'New T', description: 'New B' });
    expect(reqUrl(fetchMock.mock.calls[0][0])).toBe(
      'https://api.bitbucket.org/2.0/repositories/myws/myrepo/pullrequests/7',
    );
  });

  it('editPr throws BitbucketHttpError on a non-ok response', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => jsonRes(400, { type: 'error', error: { message: 'title required' } })),
    );
    await expect(editPr(7, { title: 'T', body: 'B' })).rejects.toThrowError(BitbucketHttpError);
  });

  it('mergePr returns MERGED on an immediate 200', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => jsonRes(200, { id: 7, state: 'MERGED' })),
    );
    expect(await mergePr(7, { squash: true, closeSourceBranch: true })).toEqual({
      id: 7,
      state: 'MERGED',
    });
  });

  it('mergePr polls state→MERGED when the merge is queued', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonRes(200, { id: 7, state: 'OPEN', queued: true }))
      .mockResolvedValueOnce(jsonRes(200, { id: 7, state: 'OPEN' }))
      .mockResolvedValueOnce(jsonRes(200, { id: 7, state: 'MERGED' }));
    vi.stubGlobal('fetch', fetchMock);

    const res = await mergePr(7, { squash: true, closeSourceBranch: true });
    expect(res.state).toBe('MERGED');
    expect(fetchMock.mock.calls.length).toBeGreaterThanOrEqual(3);
  });

  it('mergePr maps a 400 to a conflict error (atomic — nothing merged, spec §5.1)', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () =>
        jsonRes(400, {
          type: 'error',
          error: { message: "You can't merge until you resolve all merge conflicts." },
        }),
      ),
    );
    await expect(mergePr(7, { squash: true, closeSourceBranch: true })).rejects.toThrowError(
      BitbucketHttpError,
    );
    try {
      await mergePr(7, { squash: true, closeSourceBranch: true });
    } catch (e) {
      expect((e as BitbucketHttpError).status).toBe(400);
      expect((e as Error).message).toMatch(/resolve all merge conflicts/);
    }
  });

  it('listPrs builds the state+source query and follows pagination', async () => {
    const urls: string[] = [];
    const fetchMock = vi.fn(async (arg: unknown) => {
      const url = reqUrl(arg);
      urls.push(url);
      if (urls.length === 1) {
        return jsonRes(200, {
          values: [{ id: 1, title: 'a', state: 'MERGED' }],
          next: 'https://api.bitbucket.org/2.0/repositories/myws/myrepo/pullrequests?page=2',
        });
      }
      return jsonRes(200, { values: [{ id: 2, title: 'b', state: 'MERGED' }] });
    });
    vi.stubGlobal('fetch', fetchMock);

    const prs = await listPrs({ state: 'MERGED', sourceBranch: 'feat/x' });
    expect(prs.map((p) => p.id)).toEqual([1, 2]);
    expect(decodeURIComponent(urls[0])).toContain('state="MERGED"');
    expect(decodeURIComponent(urls[0])).toContain('source.branch.name="feat/x"');
    expect(urls[1]).toContain('page=2');
  });

  it('retries 5xx then succeeds (no retry on 4xx)', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonRes(503, { type: 'error' }))
      .mockResolvedValueOnce(jsonRes(200, { nickname: 'nick' }));
    vi.stubGlobal('fetch', fetchMock);

    const u = await getUser();
    expect(u.nickname).toBe('nick');
    expect(fetchMock.mock.calls.length).toBe(2);
  });

  it('retries a 429 honoring Retry-After, then succeeds', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonRes(429, { type: 'error' }, { 'retry-after': '0' }))
      .mockResolvedValueOnce(jsonRes(200, { nickname: 'nick' }));
    vi.stubGlobal('fetch', fetchMock);
    const u = await getUser();
    expect(u.nickname).toBe('nick');
    expect(fetchMock.mock.calls.length).toBe(2);
  });

  it('does NOT retry a 404 (deterministic) and throws', async () => {
    const fetchMock = vi.fn(async () => jsonRes(404, { type: 'error' }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(getUser()).rejects.toThrowError(BitbucketHttpError);
    expect(fetchMock.mock.calls.length).toBe(1);
  });

  it('caps 5xx retries at 3 attempts', async () => {
    const fetchMock = vi.fn(async () => jsonRes(503, { type: 'error' }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(getUser()).rejects.toThrowError(BitbucketHttpError);
    expect(fetchMock.mock.calls.length).toBe(3);
  });

  it('mergePr throws when polling never reaches MERGED (no silent success)', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => jsonRes(200, { id: 7, state: 'OPEN' })),
    );
    await expect(mergePr(7, { squash: true, closeSourceBranch: true })).rejects.toThrowError(
      BitbucketHttpError,
    );
  });

  it('listPrs throws on a mid-pagination failure (no partial-as-complete)', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        jsonRes(200, {
          values: [{ id: 1, title: 'a', state: 'MERGED' }],
          next: 'https://api.bitbucket.org/2.0/repositories/myws/myrepo/pullrequests?page=2',
        }),
      )
      .mockResolvedValueOnce(jsonRes(500, { type: 'error' }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(listPrs({ state: 'MERGED' })).rejects.toThrowError(BitbucketHttpError);
  });

  it('throws when a PR value has no numeric id (id invariant enforced)', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => jsonRes(200, { values: [{ title: 'no id', state: 'MERGED' }] })),
    );
    await expect(listPrs({ state: 'MERGED' })).rejects.toThrowError(/numeric id/);
  });

  it('createIssue POSTs title/content/kind and returns id+url', async () => {
    let body: unknown;
    const fetchMock = vi.fn(async (arg: unknown) => {
      if (arg instanceof Request) body = JSON.parse(await arg.text());
      return jsonRes(201, {
        id: 42,
        title: 'A nit',
        links: { html: { href: 'https://bitbucket.org/myws/myrepo/issues/42' } },
      });
    });
    vi.stubGlobal('fetch', fetchMock);

    const issue = await createIssue({ title: 'A nit', body: 'Fix it.', kind: 'task' });
    expect(issue).toEqual({
      id: 42,
      title: 'A nit',
      url: 'https://bitbucket.org/myws/myrepo/issues/42',
    });
    expect(body).toMatchObject({ title: 'A nit', content: { raw: 'Fix it.' }, kind: 'task' });
    expect(reqUrl(fetchMock.mock.calls[0][0])).toBe(
      'https://api.bitbucket.org/2.0/repositories/myws/myrepo/issues',
    );
  });

  it('createIssue maps 404 (issues disabled) to a 404 BitbucketHttpError, no retry (spec §5.2)', async () => {
    const fetchMock = vi.fn(async () => jsonRes(404, { type: 'error', error: { message: 'Resource not found' } }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(createIssue({ title: 'T', body: 'B' })).rejects.toThrowError(BitbucketHttpError);
    // deterministic — a single attempt, never retried.
    expect(fetchMock.mock.calls.length).toBe(1);
    try {
      await createIssue({ title: 'T', body: 'B' });
    } catch (e) {
      expect((e as BitbucketHttpError).status).toBe(404);
      expect((e as Error).message).toMatch(/issue tracker is disabled/);
    }
  });

  it('createIssue throws when the response has no numeric id (id invariant enforced)', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => jsonRes(201, { title: 'no id' })),
    );
    await expect(createIssue({ title: 'T', body: 'B' })).rejects.toThrowError(/numeric id/);
  });

  // ── PR review threads (spec §5.3) ──────────────────────────────────────────

  it('listPrComments maps top-level inline comments into threads, follows pagination', async () => {
    const urls: string[] = [];
    const fetchMock = vi.fn(async (arg: unknown) => {
      urls.push(reqUrl(arg));
      if (urls.length === 1) {
        return jsonRes(200, {
          values: [
            {
              id: 10,
              content: { raw: 'fix this' },
              user: { nickname: 'rev' },
              inline: { path: 'src/x.ts', from: null, to: 42 },
            },
            // a reply (has parent) — NOT a thread root
            { id: 11, content: { raw: 'ok' }, user: { nickname: 'me' }, parent: { id: 10 } },
          ],
          next: 'https://api.bitbucket.org/2.0/repositories/myws/myrepo/pullrequests/5/comments?page=2',
        });
      }
      return jsonRes(200, {
        values: [
          {
            id: 20,
            content: { raw: 'resolved one' },
            user: { account_id: 'acc-1' },
            inline: { path: 'src/y.ts', from: 7, to: null },
            resolution: { type: 'resolved' },
          },
          // a general (non-inline) PR comment — NOT a review thread
          { id: 21, content: { raw: 'general note' }, user: { nickname: 'x' } },
          // a deleted comment — skipped
          { id: 22, deleted: true, inline: { path: 'z', to: 1 } },
        ],
      });
    });
    vi.stubGlobal('fetch', fetchMock);

    const result = await listPrComments(5);
    expect(result.threads).toEqual([
      { id: 10, path: 'src/x.ts', line: 42, isResolved: false, author: 'rev', body: 'fix this' },
      { id: 20, path: 'src/y.ts', line: 7, isResolved: true, author: 'acc-1', body: 'resolved one' },
    ]);
    // A complete (non-capped) walk: truncated false, two pages fetched.
    expect(result.truncated).toBe(false);
    expect(result.pages).toBe(2);
    expect(reqUrl(fetchMock.mock.calls[0][0])).toContain(
      '/repositories/myws/myrepo/pullrequests/5/comments',
    );
    expect(urls[1]).toContain('page=2');
  });

  it('listPrComments sets truncated when it hits PAGE_CAP (HIMMEL-344)', async () => {
    // Every page advertises a next link, so the walk hits the 20-page cap and
    // breaks with truncated=true rather than looping forever or silently
    // returning a partial list as if it were complete.
    const fetchMock = vi.fn(async () =>
      jsonRes(200, {
        values: [{ id: 1, inline: { path: 'a', to: 1 }, content: { raw: 'x' } }],
        next: 'https://api.bitbucket.org/2.0/repositories/myws/myrepo/pullrequests/5/comments?page=next',
      }),
    );
    vi.stubGlobal('fetch', fetchMock);
    const errSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    const result = await listPrComments(5);
    expect(result.truncated).toBe(true);
    expect(result.pages).toBe(21); // first page + PAGE_CAP (20) follow-ups
    expect(result.threads.length).toBe(21);
    // The human-facing stderr warning fires alongside the stdout `truncated` flag.
    expect(errSpy).toHaveBeenCalledWith(expect.stringContaining('truncated at 20 pages'));
    errSpy.mockRestore();
  });

  it('listPrComments throws on a mid-pagination failure (no partial-as-complete)', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        jsonRes(200, {
          values: [{ id: 1, inline: { path: 'a', to: 1 }, content: { raw: 'x' } }],
          next: 'https://api.bitbucket.org/2.0/repositories/myws/myrepo/pullrequests/5/comments?page=2',
        }),
      )
      .mockResolvedValueOnce(jsonRes(500, { type: 'error' }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(listPrComments(5)).rejects.toThrowError(BitbucketHttpError);
  });

  it('replyPrComment POSTs content.raw + parent.id and returns the mapped comment', async () => {
    let body: unknown;
    const fetchMock = vi.fn(async (arg: unknown) => {
      if (arg instanceof Request) body = JSON.parse(await arg.text());
      return jsonRes(201, { id: 99, content: { raw: 'my reply' }, user: { nickname: 'me' } });
    });
    vi.stubGlobal('fetch', fetchMock);

    const reply = await replyPrComment(5, 10, 'my reply');
    expect(reply.id).toBe(99);
    expect(reply.body).toBe('my reply');
    expect(body).toMatchObject({ content: { raw: 'my reply' }, parent: { id: 10 } });
    expect(reqUrl(fetchMock.mock.calls[0][0])).toContain(
      '/repositories/myws/myrepo/pullrequests/5/comments',
    );
  });

  it('resolvePrComment POSTs the /resolve endpoint and succeeds on 200', async () => {
    const fetchMock = vi.fn(async () => jsonRes(200, {}));
    vi.stubGlobal('fetch', fetchMock);
    await expect(resolvePrComment(5, 10)).resolves.toBeUndefined();
    expect(reqUrl(fetchMock.mock.calls[0][0])).toContain(
      '/repositories/myws/myrepo/pullrequests/5/comments/10/resolve',
    );
  });

  it('resolvePrComment throws a 404 BitbucketHttpError (comment gone), no retry', async () => {
    const fetchMock = vi.fn(async () => jsonRes(404, { type: 'error' }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(resolvePrComment(5, 10)).rejects.toThrowError(BitbucketHttpError);
    expect(fetchMock.mock.calls.length).toBe(1);
  });

  // ── ingestion read verbs (luna-ingest, HIMMEL-329) ──────────────────────────

  it('getRepoForIngest maps metadata, fetches README on the default branch, honors --repo', async () => {
    const urls: string[] = [];
    const fetchMock = vi.fn(async (arg: unknown) => {
      const url = reqUrl(arg);
      urls.push(url);
      if (url.includes('/src/')) return new Response('# Hello\n\nworld', { status: 200 });
      return jsonRes(200, {
        name: 'otherrepo',
        full_name: 'otherws/otherrepo',
        description: 'a repo',
        language: 'TypeScript',
        mainbranch: { name: 'main' },
        updated_on: '2026-06-01T00:00:00Z',
        is_private: false,
        links: { html: { href: 'https://bitbucket.org/otherws/otherrepo' } },
      });
    });
    vi.stubGlobal('fetch', fetchMock);

    const r = await getRepoForIngest({ workspace: 'otherws', repoSlug: 'otherrepo' });
    expect(r).toEqual({
      workspace: 'otherws',
      repo_slug: 'otherrepo',
      name: 'otherrepo',
      full_name: 'otherws/otherrepo',
      description: 'a repo',
      language: 'TypeScript',
      default_branch: 'main',
      url: 'https://bitbucket.org/otherws/otherrepo',
      updated_on: '2026-06-01T00:00:00Z',
      is_private: false,
      readme: '# Hello\n\nworld',
    });
    // --repo targets otherws/otherrepo, NOT the env myws/myrepo.
    expect(urls[0]).toBe('https://api.bitbucket.org/2.0/repositories/otherws/otherrepo');
    expect(urls[1]).toBe(
      'https://api.bitbucket.org/2.0/repositories/otherws/otherrepo/src/main/README.md',
    );
  });

  it('getRepoForIngest returns readme:null when the README is missing (404)', async () => {
    const fetchMock = vi.fn(async (arg: unknown) => {
      if (reqUrl(arg).includes('/src/')) return new Response('Not found', { status: 404 });
      return jsonRes(200, { full_name: 'myws/myrepo', mainbranch: { name: 'main' } });
    });
    vi.stubGlobal('fetch', fetchMock);
    const r = await getRepoForIngest();
    expect(r.readme).toBeNull();
  });

  it('getRepoForIngest skips the README fetch when there is no default branch', async () => {
    const fetchMock = vi.fn(async () => jsonRes(200, { full_name: 'myws/myrepo' }));
    vi.stubGlobal('fetch', fetchMock);
    const r = await getRepoForIngest();
    expect(r.default_branch).toBeNull();
    expect(r.readme).toBeNull();
    // only the metadata call — no src fetch attempted.
    expect(fetchMock.mock.calls.length).toBe(1);
  });

  it('getPr maps detail fields incl. source/destination branch and author', async () => {
    const fetchMock = vi.fn(async () =>
      jsonRes(200, {
        id: 12,
        title: 'My PR',
        state: 'OPEN',
        description: 'does a thing',
        author: { nickname: 'alice' },
        source: { branch: { name: 'feat/x' } },
        destination: { branch: { name: 'main' } },
        created_on: '2026-06-01T00:00:00Z',
        updated_on: '2026-06-02T00:00:00Z',
        links: { html: { href: 'https://bitbucket.org/myws/myrepo/pull-requests/12' } },
      }),
    );
    vi.stubGlobal('fetch', fetchMock);
    const pr = await getPr(12);
    expect(pr).toEqual({
      id: 12,
      title: 'My PR',
      state: 'OPEN',
      description: 'does a thing',
      author: 'alice',
      source_branch: 'feat/x',
      destination_branch: 'main',
      url: 'https://bitbucket.org/myws/myrepo/pull-requests/12',
      created_on: '2026-06-01T00:00:00Z',
      updated_on: '2026-06-02T00:00:00Z',
    });
    expect(reqUrl(fetchMock.mock.calls[0][0])).toBe(
      'https://api.bitbucket.org/2.0/repositories/myws/myrepo/pullrequests/12',
    );
  });

  it('getPr throws when the PR response has no numeric id', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => jsonRes(200, { title: 'no id' })),
    );
    await expect(getPr(12)).rejects.toThrowError(/numeric id/);
  });

  it('getIssue maps detail fields incl. kind/content/reporter', async () => {
    const fetchMock = vi.fn(async () =>
      jsonRes(200, {
        id: 5,
        title: 'A bug',
        state: 'new',
        kind: 'bug',
        content: { raw: 'it breaks' },
        reporter: { nickname: 'bob' },
        created_on: '2026-06-01T00:00:00Z',
        updated_on: '2026-06-02T00:00:00Z',
        links: { html: { href: 'https://bitbucket.org/myws/myrepo/issues/5' } },
      }),
    );
    vi.stubGlobal('fetch', fetchMock);
    const issue = await getIssue(5);
    expect(issue).toEqual({
      id: 5,
      title: 'A bug',
      state: 'new',
      kind: 'bug',
      content: 'it breaks',
      reporter: 'bob',
      url: 'https://bitbucket.org/myws/myrepo/issues/5',
      created_on: '2026-06-01T00:00:00Z',
      updated_on: '2026-06-02T00:00:00Z',
    });
    expect(reqUrl(fetchMock.mock.calls[0][0])).toBe(
      'https://api.bitbucket.org/2.0/repositories/myws/myrepo/issues/5',
    );
  });

  it('getIssue maps a 404 (tracker disabled / gone) to a 404 BitbucketHttpError, no retry', async () => {
    const fetchMock = vi.fn(async () => jsonRes(404, { type: 'error' }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(getIssue(5)).rejects.toThrowError(BitbucketHttpError);
    expect(fetchMock.mock.calls.length).toBe(1);
    try {
      await getIssue(5);
    } catch (e) {
      expect((e as BitbucketHttpError).status).toBe(404);
      expect((e as Error).message).toMatch(/issue tracker is disabled or the issue does not exist/);
    }
  });

  it('getRepoForIngest treats a non-404 README error (500) as missing, keeps metadata', async () => {
    const fetchMock = vi.fn(async (arg: unknown) => {
      if (reqUrl(arg).includes('/src/')) return new Response('boom', { status: 500 });
      return jsonRes(200, { full_name: 'myws/myrepo', mainbranch: { name: 'main' } });
    });
    vi.stubGlobal('fetch', fetchMock);
    const r = await getRepoForIngest();
    expect(r.readme).toBeNull();
    expect(r.full_name).toBe('myws/myrepo');
  });

  it('getRepoForIngest treats a 200 JSON README body as missing (not a raw file)', async () => {
    const fetchMock = vi.fn(async (arg: unknown) => {
      if (reqUrl(arg).includes('/src/')) return jsonRes(200, { type: 'error' });
      return jsonRes(200, { full_name: 'myws/myrepo', mainbranch: { name: 'main' } });
    });
    vi.stubGlobal('fetch', fetchMock);
    const r = await getRepoForIngest();
    expect(r.readme).toBeNull();
  });

  it('getPr honors the --repo override (targets the override repo, not the env default)', async () => {
    const fetchMock = vi.fn(async () => jsonRes(200, { id: 3, title: 'T', state: 'OPEN' }));
    vi.stubGlobal('fetch', fetchMock);
    await getPr(3, { workspace: 'otherws', repoSlug: 'otherrepo' });
    expect(reqUrl(fetchMock.mock.calls[0][0])).toBe(
      'https://api.bitbucket.org/2.0/repositories/otherws/otherrepo/pullrequests/3',
    );
  });

  it('getIssue honors the --repo override (targets the override repo, not the env default)', async () => {
    const fetchMock = vi.fn(async () => jsonRes(200, { id: 4, title: 'I', state: 'new' }));
    vi.stubGlobal('fetch', fetchMock);
    await getIssue(4, { workspace: 'otherws', repoSlug: 'otherrepo' });
    expect(reqUrl(fetchMock.mock.calls[0][0])).toBe(
      'https://api.bitbucket.org/2.0/repositories/otherws/otherrepo/issues/4',
    );
  });

  it('getPr rejects a non-numeric id before any request', async () => {
    const fetchMock = vi.fn(async () => jsonRes(200, {}));
    vi.stubGlobal('fetch', fetchMock);
    await expect(getPr(Number('foo'))).rejects.toThrowError(/numeric id/);
    expect(fetchMock.mock.calls.length).toBe(0);
  });

  it('getIssue rejects a non-numeric id before any request (does NOT become a 404→exit-3)', async () => {
    const fetchMock = vi.fn(async () => jsonRes(404, { type: 'error' }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(getIssue(Number('foo'))).rejects.toThrowError(/numeric id/);
    expect(fetchMock.mock.calls.length).toBe(0);
    try {
      await getIssue(Number('foo'));
    } catch (e) {
      // status 0 (input error), NOT 404 — so the command layer maps it to exit 1,
      // keeping exit 3 reserved for a genuinely disabled tracker.
      expect((e as BitbucketHttpError).status).toBe(0);
    }
  });
});

describe('resolveSlug (spec §5.4 fallback chain)', () => {
  it('prefers nickname', () => {
    expect(resolveSlug({ nickname: 'n', account_id: 'a', uuid: 'u' })).toBe('n');
  });
  it('falls back to account_id then uuid', () => {
    expect(resolveSlug({ account_id: 'a', uuid: 'u' })).toBe('a');
    expect(resolveSlug({ uuid: 'u' })).toBe('u');
  });
  it('throws when none present (never an empty slug)', () => {
    expect(() => resolveSlug({})).toThrow(/cannot resolve a user-slug/);
  });
});
