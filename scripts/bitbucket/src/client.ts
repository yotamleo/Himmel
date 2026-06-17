import { createBitbucketCloudClient } from '@coderabbitai/bitbucket/cloud';
import { authHeader, BASE_URL } from './env.js';
import { repoRef, type RepoRef } from './remote.js';

// openapi-fetch result shape (it never throws on HTTP errors — it returns
// { data } on 2xx and { error } otherwise, with the raw Response either way).
interface OFResult<T> {
  data?: T;
  error?: unknown;
  response: Response;
}

const MAX_ATTEMPTS = 3;
const baseBackoffMs = (): number => {
  const n = Number(process.env.BITBUCKET_RETRY_BASE_MS);
  return Number.isFinite(n) && n >= 0 ? n : 500;
};
const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

// Typed error so callers (e.g. the merge command) can branch on status + body
// without re-parsing strings. Carries the parsed Bitbucket error body. NOTE:
// `status` is usually the real HTTP status, but a couple of paths pack a
// synthetic sentinel into it — 0 = malformed body (no numeric id), 202 = merge
// queued but never converged to MERGED. Callers branching on status (the
// 400-conflict and 404-issues-disabled cases today) should treat unknown values
// as generic failures.
export class BitbucketHttpError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly body: unknown,
  ) {
    super(message);
    this.name = 'BitbucketHttpError';
  }
}

let _client: ReturnType<typeof createBitbucketCloudClient> | null = null;
export function client(): ReturnType<typeof createBitbucketCloudClient> {
  if (_client) return _client;
  _client = createBitbucketCloudClient({
    baseUrl: BASE_URL,
    headers: { Accept: 'application/json', Authorization: authHeader() },
  });
  return _client;
}

// Reset memoized client — test-only seam so env/auth changes between cases
// take effect.
export function _resetClient(): void {
  _client = null;
}

// Retry policy (spec §5.2): never retry 4xx (deterministic); MAY retry
// 5xx/429 with backoff, respecting Retry-After, capped at MAX_ATTEMPTS.
async function withRetry<T>(thunk: () => Promise<OFResult<T>>): Promise<OFResult<T>> {
  let attempt = 0;
  for (;;) {
    const res = await thunk();
    const status = res.response.status;
    if (res.response.ok || (status < 500 && status !== 429)) return res;
    attempt += 1;
    if (attempt >= MAX_ATTEMPTS) return res;
    const ra = res.response.headers.get('retry-after');
    const delay =
      ra && Number.isFinite(Number(ra)) ? Number(ra) * 1000 : baseBackoffMs() * 2 ** (attempt - 1);
    await sleep(delay);
  }
}

function fail(verb: string, res: OFResult<unknown>): never {
  const status = res.response.status;
  const body = res.error ?? '';
  throw new BitbucketHttpError(
    `bitbucket: ${verb} failed: HTTP ${status} ${typeof body === 'string' ? body : JSON.stringify(body)}`,
    status,
    res.error,
  );
}

// ── normalized return shapes (the `gh --json` analogue) ──────────────────────

export interface UserInfo {
  nickname?: string;
  account_id?: string;
  uuid?: string;
  display_name?: string;
}

export interface RepoInfo {
  workspace: string;
  repo_slug: string;
  full_name: string;
  default_branch: string | null;
}

export interface PrInfo {
  id: number;
  title: string;
  state: string;
  source_branch: string | null;
  url: string | null;
}

export interface IssueInfo {
  id: number;
  title: string;
  url: string | null;
}

// ── ingestion read shapes (luna-ingest, HIMMEL-329) ──────────────────────────
// Richer than the action-verb shapes above: these feed the luna-ingest note
// synthesis (the `gh api repos/<o>/<r>` / issue / PR analogue). Bitbucket Cloud
// has no stars or topics, so those github-only inputs are simply absent.

export interface RepoIngestInfo {
  workspace: string;
  repo_slug: string;
  name: string;
  full_name: string;
  description: string | null;
  language: string | null;
  default_branch: string | null;
  url: string | null;
  updated_on: string | null;
  is_private: boolean | null;
  readme: string | null;
}

export interface PrIngestInfo {
  id: number;
  title: string;
  state: string;
  description: string | null;
  author: string | null;
  source_branch: string | null;
  destination_branch: string | null;
  url: string | null;
  created_on: string | null;
  updated_on: string | null;
}

export interface IssueIngestInfo {
  id: number;
  title: string;
  state: string;
  kind: string | null;
  content: string | null;
  reporter: string | null;
  url: string | null;
  created_on: string | null;
  updated_on: string | null;
}

// ── verbs ────────────────────────────────────────────────────────────────

export async function getUser(): Promise<UserInfo> {
  const res = (await withRetry(() => client().GET('/user', {}))) as OFResult<UserInfo>;
  if (!res.response.ok) fail('user', res);
  return (res.data ?? {}) as UserInfo;
}

export async function getRepo(): Promise<RepoInfo> {
  const { workspace, repoSlug } = repoRef();
  const res = (await withRetry(() =>
    client().GET('/repositories/{workspace}/{repo_slug}', {
      params: { path: { workspace, repo_slug: repoSlug } },
    }),
  )) as OFResult<{ full_name?: string; mainbranch?: { name?: string } }>;
  if (!res.response.ok) fail('repo view', res);
  const d = res.data ?? {};
  return {
    workspace,
    repo_slug: repoSlug,
    full_name: d.full_name ?? `${workspace}/${repoSlug}`,
    default_branch: d.mainbranch?.name ?? null,
  };
}

// README is fetched with a RAW fetch (not the typed openapi-fetch client): the
// `src/{commit}/{path}` endpoint returns raw file *text*, but the client defaults
// to `Accept: application/json` + json-parse, which would throw on markdown. A
// 404 (no README on that branch) is the common case — return null and let the
// caller record "README: missing", mirroring the github luna-ingest path. Any
// other non-ok is also non-fatal (README is enrichment, not the note itself) but
// gets a stderr warning so the failure is not silent.
async function fetchReadme(
  workspace: string,
  repoSlug: string,
  branch: string,
): Promise<string | null> {
  const url = `${BASE_URL}/repositories/${workspace}/${repoSlug}/src/${branch}/README.md`;
  const res = await fetch(url, { headers: { Authorization: authHeader() } });
  if (res.status === 404) return null;
  if (!res.ok) {
    process.stderr.write(
      `bitbucket: warning: README fetch for ${workspace}/${repoSlug}@${branch} returned HTTP ${res.status} — treating as missing\n`,
    );
    return null;
  }
  // A raw README is text/* (Content-Type derived from the .md extension). A 200
  // with a JSON body is not a file — it is an error envelope / auth interstitial.
  // Don't ingest that as README content; treat it as missing.
  const contentType = res.headers.get('content-type') ?? '';
  if (contentType.includes('application/json')) {
    process.stderr.write(
      `bitbucket: warning: README fetch for ${workspace}/${repoSlug}@${branch} returned ${contentType} (not a raw file) — treating as missing\n`,
    );
    return null;
  }
  return await res.text();
}

// repo get — GET .../{ws}/{repo} (+ README via fetchReadme). The luna-ingest
// source-fetch analogue. `ref` overrides the origin-derived repoRef so the verb
// can target an arbitrary URL-named repo.
export async function getRepoForIngest(ref?: RepoRef): Promise<RepoIngestInfo> {
  const { workspace, repoSlug } = ref ?? repoRef();
  const res = (await withRetry(() =>
    client().GET('/repositories/{workspace}/{repo_slug}', {
      params: { path: { workspace, repo_slug: repoSlug } },
    }),
  )) as OFResult<{
    name?: string;
    full_name?: string;
    description?: string;
    language?: string;
    mainbranch?: { name?: string };
    updated_on?: string;
    is_private?: boolean;
    links?: { html?: { href?: string } };
  }>;
  if (!res.response.ok) fail('repo get', res);
  const d = res.data ?? {};
  const defaultBranch = d.mainbranch?.name ?? null;
  const readme = defaultBranch ? await fetchReadme(workspace, repoSlug, defaultBranch) : null;
  return {
    workspace,
    repo_slug: repoSlug,
    name: d.name ?? repoSlug,
    full_name: d.full_name ?? `${workspace}/${repoSlug}`,
    description: d.description ?? null,
    language: d.language ?? null,
    default_branch: defaultBranch,
    url: d.links?.html?.href ?? null,
    updated_on: d.updated_on ?? null,
    // Preserve "unknown" rather than collapsing an absent field to a (wrong-
    // direction) `false`/public — mirror the nullable convention of the rest of
    // this shape.
    is_private: typeof d.is_private === 'boolean' ? d.is_private : null,
    readme,
  };
}

// pr get <id> — GET .../pullrequests/{id}. Detailed read (the action-verb
// PrInfo above is intentionally lean); feeds the luna-ingest PR note.
export async function getPr(id: number, ref?: RepoRef): Promise<PrIngestInfo> {
  // Guard a non-numeric arg BEFORE the request — `id: NaN` would otherwise build
  // `/pullrequests/NaN` and surface as a confusing server-side 404.
  if (!Number.isInteger(id)) {
    throw new BitbucketHttpError(`bitbucket: pr get requires a numeric id, got: ${id}`, 0, null);
  }
  const { workspace, repoSlug } = ref ?? repoRef();
  const res = (await withRetry(() =>
    client().GET('/repositories/{workspace}/{repo_slug}/pullrequests/{pull_request_id}', {
      params: { path: { workspace, repo_slug: repoSlug, pull_request_id: id } },
    }),
  )) as OFResult<Record<string, unknown>>;
  if (!res.response.ok) fail('pr get', res);
  const d = res.data ?? {};
  const pid = Number(d.id);
  if (!Number.isInteger(pid)) {
    throw new BitbucketHttpError('bitbucket: pull request response missing a numeric id', 0, d);
  }
  const links = d.links as { html?: { href?: string } } | undefined;
  const author = d.author as { nickname?: string; account_id?: string } | undefined;
  const source = d.source as { branch?: { name?: string } } | undefined;
  const destination = d.destination as { branch?: { name?: string } } | undefined;
  return {
    id: pid,
    title: String(d.title ?? ''),
    state: String(d.state ?? ''),
    description: (d.description as string | undefined) ?? null,
    author: author?.nickname ?? author?.account_id ?? null,
    source_branch: source?.branch?.name ?? null,
    destination_branch: destination?.branch?.name ?? null,
    url: links?.html?.href ?? null,
    created_on: (d.created_on as string | undefined) ?? null,
    updated_on: (d.updated_on as string | undefined) ?? null,
  };
}

// issue get <id> — GET .../issues/{id}. A 404 (issue tracker disabled OR issue
// gone) surfaces as a 404 BitbucketHttpError so the command layer can map it to
// exit 3, reusing the `issue create` issues-disabled graceful-degrade contract.
export async function getIssue(id: number, ref?: RepoRef): Promise<IssueIngestInfo> {
  // Guard a non-numeric arg BEFORE the request: `id: NaN` → `/issues/NaN` → a
  // server 404, which the 404 branch below would misread as "tracker disabled"
  // and map to exit 3. A status-0 error instead falls through to a plain input
  // error (exit 1), keeping exit 3 reserved for the genuine tracker-off case.
  if (!Number.isInteger(id)) {
    throw new BitbucketHttpError(`bitbucket: issue get requires a numeric id, got: ${id}`, 0, null);
  }
  const { workspace, repoSlug } = ref ?? repoRef();
  const res = (await withRetry(() =>
    client().GET('/repositories/{workspace}/{repo_slug}/issues/{issue_id}', {
      params: { path: { workspace, repo_slug: repoSlug, issue_id: String(id) } },
    }),
  )) as OFResult<Record<string, unknown>>;
  if (res.response.status === 404) {
    throw new BitbucketHttpError(
      'bitbucket: issue get failed: issue tracker is disabled or the issue does not exist (404)',
      404,
      res.error,
    );
  }
  if (!res.response.ok) fail('issue get', res);
  const d = res.data ?? {};
  const iid = Number(d.id);
  if (!Number.isInteger(iid)) {
    throw new BitbucketHttpError('bitbucket: issue response missing a numeric id', 0, d);
  }
  const links = d.links as { html?: { href?: string } } | undefined;
  const reporter = d.reporter as { nickname?: string; account_id?: string } | undefined;
  const content = d.content as { raw?: string } | undefined;
  return {
    id: iid,
    title: String(d.title ?? ''),
    state: String(d.state ?? ''),
    kind: (d.kind as string | undefined) ?? null,
    content: content?.raw ?? null,
    reporter: reporter?.nickname ?? reporter?.account_id ?? null,
    url: links?.html?.href ?? null,
    created_on: (d.created_on as string | undefined) ?? null,
    updated_on: (d.updated_on as string | undefined) ?? null,
  };
}

function prInfo(d: Record<string, unknown>): PrInfo {
  const id = Number(d.id);
  if (!Number.isInteger(id)) {
    throw new BitbucketHttpError('bitbucket: pull request response missing a numeric id', 0, d);
  }
  const links = d.links as { html?: { href?: string } } | undefined;
  const source = d.source as { branch?: { name?: string } } | undefined;
  return {
    id,
    title: String(d.title ?? ''),
    state: String(d.state ?? ''),
    source_branch: source?.branch?.name ?? null,
    url: links?.html?.href ?? null,
  };
}

export async function createPr(opts: {
  title: string;
  body: string;
  source: string;
  destination: string;
}): Promise<PrInfo> {
  const { workspace, repoSlug } = repoRef();
  const res = (await withRetry(() =>
    client().POST('/repositories/{workspace}/{repo_slug}/pullrequests', {
      params: { path: { workspace, repo_slug: repoSlug } },
      body: {
        title: opts.title,
        description: opts.body,
        source: { branch: { name: opts.source } },
        destination: { branch: { name: opts.destination } },
      } as never,
    }),
  )) as OFResult<Record<string, unknown>>;
  if (!res.response.ok) fail('pr create', res);
  return prInfo(res.data ?? {});
}

// Bitbucket Cloud has no PATCH for the PR body — updating a PR is a PUT to the
// pullrequest resource, and the API REQUIRES `title` in the body (a bare
// description update 400s). So this verb takes BOTH a title and a body.
export async function editPr(id: number, opts: { title: string; body: string }): Promise<PrInfo> {
  const { workspace, repoSlug } = repoRef();
  const res = (await withRetry(() =>
    client().PUT('/repositories/{workspace}/{repo_slug}/pullrequests/{pull_request_id}', {
      params: { path: { workspace, repo_slug: repoSlug, pull_request_id: id } },
      body: {
        title: opts.title,
        description: opts.body,
      } as never,
    }),
  )) as OFResult<Record<string, unknown>>;
  if (!res.response.ok) fail('pr edit', res);
  return prInfo(res.data ?? {});
}

// Sentinel for the "PR has merge conflicts" case — the verified BB signal is a
// 400 on the merge endpoint (spec §5.1), atomic (nothing merged).
export const CONFLICT = 'conflict';

export async function mergePr(
  id: number,
  opts: { squash: boolean; closeSourceBranch: boolean },
): Promise<{ id: number; state: 'MERGED' }> {
  const { workspace, repoSlug } = repoRef();
  const res = (await withRetry(() =>
    client().POST('/repositories/{workspace}/{repo_slug}/pullrequests/{pull_request_id}/merge', {
      params: { path: { workspace, repo_slug: repoSlug, pull_request_id: id } },
      body: {
        merge_strategy: opts.squash ? 'squash' : 'merge_commit',
        close_source_branch: opts.closeSourceBranch,
      } as never,
    }),
  )) as OFResult<Record<string, unknown>>;

  if (res.response.status === 400) {
    // 400 = merge conflict (or other client error). Nothing was merged.
    throw new BitbucketHttpError(
      `bitbucket: pr merge ${id} failed: ${conflictMessage(res.error)}`,
      400,
      res.error,
    );
  }
  if (!res.response.ok) fail('pr merge', res);

  // Async note (spec §5.1): merges may be queued. Poll until MERGED, and treat
  // any non-MERGED terminal state as a failure — never report an incomplete
  // merge as success (the whole point of the §5.1 atomic-signal handling).
  const d = res.data ?? {};
  let state = String(d.state ?? '');
  if (state !== 'MERGED') {
    state = await pollMerged(workspace, repoSlug, id);
  }
  if (state !== 'MERGED') {
    throw new BitbucketHttpError(
      `bitbucket: pr merge ${id} did not reach MERGED (last state: ${state || 'unknown'}) after polling`,
      202,
      res.error ?? null,
    );
  }
  // Past the guard, state is necessarily 'MERGED' — return the literal so the
  // signature's MERGED-only invariant holds at the type level too.
  return { id, state: 'MERGED' };
}

function conflictMessage(err: unknown): string {
  const e = err as { error?: { message?: string } } | undefined;
  return e?.error?.message ?? "You can't merge until you resolve all merge conflicts.";
}

const POLL_ATTEMPTS = 10;
async function pollMerged(workspace: string, repoSlug: string, id: number): Promise<string> {
  for (let i = 0; i < POLL_ATTEMPTS; i += 1) {
    const res = (await withRetry(() =>
      client().GET('/repositories/{workspace}/{repo_slug}/pullrequests/{pull_request_id}', {
        params: { path: { workspace, repo_slug: repoSlug, pull_request_id: id } },
      }),
    )) as OFResult<{ state?: string }>;
    if (res.response.ok && res.data?.state === 'MERGED') return 'MERGED';
    await sleep(baseBackoffMs());
  }
  return 'PENDING';
}

const PAGE_CAP = 20;

export async function listPrs(opts: {
  state: string;
  sourceBranch?: string;
}): Promise<PrInfo[]> {
  const { workspace, repoSlug } = repoRef();
  let q = `state="${opts.state}"`;
  if (opts.sourceBranch) q += ` AND source.branch.name="${opts.sourceBranch}"`;

  const out: PrInfo[] = [];
  const first = (await withRetry(() =>
    client().GET('/repositories/{workspace}/{repo_slug}/pullrequests', {
      params: { path: { workspace, repo_slug: repoSlug }, query: { q, pagelen: 50 } as never },
    }),
  )) as OFResult<{ values?: Record<string, unknown>[]; next?: string }>;
  if (!first.response.ok) fail('pr list', first);

  let page = first.data ?? {};
  let pages = 0;
  for (;;) {
    for (const v of page.values ?? []) out.push(prInfo(v));
    if (!page.next) break;
    if (pages >= PAGE_CAP) {
      // Never let a hit page-cap masquerade as a complete list (silent truncation).
      process.stderr.write(
        `bitbucket: pr list truncated at ${PAGE_CAP} pages — results may be incomplete\n`,
      );
      break;
    }
    pages += 1;
    const next = await fetch(page.next, {
      headers: { Accept: 'application/json', Authorization: authHeader() },
    });
    if (!next.ok) {
      // A mid-pagination failure must not silently return a partial list as if
      // it were the whole set (would undercount merged PRs in clean-garden).
      throw new BitbucketHttpError(
        `bitbucket: pr list pagination failed on page ${pages + 1}: HTTP ${next.status}`,
        next.status,
        await next.text(),
      );
    }
    page = (await next.json()) as { values?: Record<string, unknown>[]; next?: string };
  }
  return out;
}

function issueInfo(d: Record<string, unknown>): IssueInfo {
  const id = Number(d.id);
  if (!Number.isInteger(id)) {
    throw new BitbucketHttpError('bitbucket: issue response missing a numeric id', 0, d);
  }
  const links = d.links as { html?: { href?: string } } | undefined;
  return { id, title: String(d.title ?? ''), url: links?.html?.href ?? null };
}

// Create an issue (POST .../issues). Spec §5.2: the issue tracker is OFF by
// default on Bitbucket repos, and the POST then returns a *404* (verified —
// not 403). 404 is deterministic, so withRetry never retries it; we surface it
// as a 404 BitbucketHttpError so the caller (file-deferred-issues) can degrade
// gracefully ("issues disabled → skip + warn") rather than erroring the CR flow.
// `kind` is the Bitbucket issue kind (bug|enhancement|proposal|task); GitHub
// labels have no Bitbucket equivalent, so the seam's `label` arg is github-only.
export async function createIssue(opts: {
  title: string;
  body: string;
  kind?: string;
}): Promise<IssueInfo> {
  const { workspace, repoSlug } = repoRef();
  const res = (await withRetry(() =>
    client().POST('/repositories/{workspace}/{repo_slug}/issues', {
      params: { path: { workspace, repo_slug: repoSlug } },
      body: {
        title: opts.title,
        content: { raw: opts.body },
        kind: opts.kind ?? 'task',
      } as never,
    }),
  )) as OFResult<Record<string, unknown>>;
  if (res.response.status === 404) {
    throw new BitbucketHttpError(
      'bitbucket: issue create failed: issue tracker is disabled on this repository (404)',
      404,
      res.error,
    );
  }
  if (!res.response.ok) fail('issue create', res);
  return issueInfo(res.data ?? {});
}

// ── PR review threads (spec §5.3) ────────────────────────────────────────────
// Bitbucket Cloud has NO GraphQL, so the GitHub reviewThreads abstraction is
// rebuilt over the flat comment model. A *thread* is a top-level INLINE comment
// (file/line-anchored, `parent` absent); its id is the thread id. Replies carry
// `parent.id`; general (non-inline) PR comments and deleted comments are not
// review threads and are skipped. This shape mirrors what the plugin's
// thread-cache writer consumes from the GitHub GraphQL nodes.

export interface ReviewThread {
  id: number;
  path: string | null;
  line: number | null;
  isResolved: boolean;
  author: string | null;
  body: string;
}

// `pr comments` payload (HIMMEL-344). Wrapping the array lets the stdout consumer
// (the himmel-gh plugin's bitbucket-threads backend) see when the list was capped
// at PAGE_CAP pages — a bare array can't carry that signal, so a truncated list
// would otherwise masquerade as complete. `pages` = total pages fetched.
export interface PrCommentsResult {
  threads: ReviewThread[];
  truncated: boolean;
  pages: number;
}

function threadFromComment(d: Record<string, unknown>): ReviewThread {
  const id = Number(d.id);
  if (!Number.isInteger(id)) {
    throw new BitbucketHttpError('bitbucket: comment response missing a numeric id', 0, d);
  }
  const inline = d.inline as { path?: string; from?: number | null; to?: number | null } | undefined;
  const user = d.user as { nickname?: string; account_id?: string } | undefined;
  const content = d.content as { raw?: string } | undefined;
  return {
    id,
    path: inline?.path ?? null,
    // Bitbucket anchors inline comments on `to` (new side) or `from` (old side).
    line: inline?.to ?? inline?.from ?? null,
    isResolved: Boolean(d.resolution),
    author: user?.nickname ?? user?.account_id ?? null,
    body: content?.raw ?? '',
  };
}

// list: GET .../pullrequests/{id}/comments — paginated, same next-link + PAGE_CAP
// pattern as listPrs. Returns one ReviewThread per top-level inline comment,
// wrapped with a `truncated` flag (HIMMEL-344) so a page-capped list is not
// mistaken for a complete one by the stdout consumer.
export async function listPrComments(prId: number): Promise<PrCommentsResult> {
  const { workspace, repoSlug } = repoRef();
  const out: ReviewThread[] = [];
  const first = (await withRetry(() =>
    client().GET('/repositories/{workspace}/{repo_slug}/pullrequests/{pull_request_id}/comments', {
      params: {
        path: { workspace, repo_slug: repoSlug, pull_request_id: prId },
        query: { pagelen: 50 } as never,
      },
    }),
  )) as OFResult<{ values?: Record<string, unknown>[]; next?: string }>;
  if (!first.response.ok) fail('pr comments', first);

  let page = first.data ?? {};
  let pages = 0;
  let truncated = false;
  for (;;) {
    for (const c of page.values ?? []) {
      if (c.deleted || c.parent || !c.inline) continue;
      out.push(threadFromComment(c));
    }
    if (!page.next) break;
    if (pages >= PAGE_CAP) {
      // Never let a hit page-cap masquerade as a complete list (silent truncation).
      // The stderr warning stays for humans; `truncated` carries it on stdout too.
      truncated = true;
      process.stderr.write(
        `bitbucket: pr comments truncated at ${PAGE_CAP} pages — results may be incomplete\n`,
      );
      break;
    }
    pages += 1;
    const next = await fetch(page.next, {
      headers: { Accept: 'application/json', Authorization: authHeader() },
    });
    if (!next.ok) {
      // A mid-pagination failure must not silently return a partial list (would
      // hide unresolved threads from the CR loop).
      throw new BitbucketHttpError(
        `bitbucket: pr comments pagination failed on page ${pages + 1}: HTTP ${next.status}`,
        next.status,
        await next.text(),
      );
    }
    page = (await next.json()) as { values?: Record<string, unknown>[]; next?: string };
  }
  return { threads: out, truncated, pages: pages + 1 };
}

// reply: POST .../comments with `{ content.raw, parent.id }` (the §5.3 mutate).
export async function replyPrComment(
  prId: number,
  parentId: number,
  body: string,
): Promise<ReviewThread> {
  const { workspace, repoSlug } = repoRef();
  const res = (await withRetry(() =>
    client().POST('/repositories/{workspace}/{repo_slug}/pullrequests/{pull_request_id}/comments', {
      params: { path: { workspace, repo_slug: repoSlug, pull_request_id: prId } },
      body: { content: { raw: body }, parent: { id: parentId } } as never,
    }),
  )) as OFResult<Record<string, unknown>>;
  if (!res.response.ok) fail('pr reply', res);
  return threadFromComment(res.data ?? {});
}

// resolve: POST .../comments/{cid}/resolve. A 404 (comment/PR gone) flows through
// the generic fail() as a BitbucketHttpError; withRetry never retries any 4xx.
export async function resolvePrComment(prId: number, commentId: number): Promise<void> {
  const { workspace, repoSlug } = repoRef();
  const res = (await withRetry(() =>
    client().POST(
      '/repositories/{workspace}/{repo_slug}/pullrequests/{pull_request_id}/comments/{comment_id}/resolve',
      {
        params: {
          path: { workspace, repo_slug: repoSlug, pull_request_id: prId, comment_id: commentId },
        },
      },
    ),
  )) as OFResult<Record<string, unknown>>;
  if (!res.response.ok) fail('pr resolve', res);
}
