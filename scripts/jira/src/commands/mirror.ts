import type { Command } from 'commander';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { request, projectKey } from '../client.js';
import { adfToPlainText } from '../adf-render.js';
import type { ADFDocument } from '../adf-render.js';
import { fetchAllComments } from './comments.js';
import type { JiraCommentEntry } from './comments.js';

// HIMMEL-3889. Jira -> markdown mirror: one <KEY>.md per issue under a root
// outside any repo/vault, plus a qmd collection over it. Read-only against Jira.

const PAGE_MAX = 100;
const OVERLAP_MINUTES = 10;
const COLLECTION = 'jira-himmel';
const DELETE_SAFETY_RATIO = 0.5;
const CURSOR_FILE = '.cursor.json';
const FIELDS =
  'summary,status,issuetype,priority,labels,fixVersions,parent,created,updated,resolution,issuelinks,description,comment';

interface Named { name?: string; displayName?: string }
export interface MirrorIssue {
  key: string;
  fields: {
    summary?: string;
    status?: { name?: string; statusCategory?: { name?: string } };
    issuetype?: Named;
    priority?: Named | null;
    labels?: string[];
    fixVersions?: Named[];
    parent?: { key?: string } | null;
    created?: string;
    updated?: string;
    resolution?: Named | null;
    issuelinks?: Array<{
      type?: { inward?: string; outward?: string };
      inwardIssue?: { key: string };
      outwardIssue?: { key: string };
    }>;
    description?: ADFDocument | null;
    comment?: { comments?: JiraCommentEntry[]; total?: number };
  };
}

interface SearchPage { issues: MirrorIssue[]; nextPageToken?: string }
export type Req = typeof request;

export interface Cursor { lastSync: string; total: number }

export interface MirrorOptions {
  root: string;
  project: string;
  full?: boolean;
  concurrency?: number;
  now?: () => Date;
  warn?: (msg: string) => void;
}

export interface MirrorResult {
  mode: 'full' | 'incremental';
  fetched: number;
  written: number;
  unchanged: number;
  deleted: number;
  deleteSkipped: string | null;
  mirrorCount: number;
  jiraTotal: number | null;
}

// Mirror files must never carry emails; ADF mentions/pasted text can.
const EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/g;
export const scrubEmails = (s: string): string => s.replace(EMAIL_RE, '[email]');

const q = (v: string | null | undefined): string => JSON.stringify(v ?? null);
const list = (v: string[]): string => JSON.stringify(v);

function linkGroups(issue: MirrorIssue): { blocks: string[]; blocked_by: string[]; relates: string[] } {
  const g = { blocks: [] as string[], blocked_by: [] as string[], relates: [] as string[] };
  for (const l of issue.fields.issuelinks ?? []) {
    const other = l.outwardIssue ?? l.inwardIssue;
    if (!other) continue;
    const phrase = (l.outwardIssue ? l.type?.outward : l.type?.inward) ?? '';
    if (l.outwardIssue && /^blocks$/i.test(phrase)) g.blocks.push(other.key);
    else if (l.inwardIssue && /^is blocked by$/i.test(phrase)) g.blocked_by.push(other.key);
    else g.relates.push(phrase ? `${phrase} ${other.key}` : other.key);
  }
  return g;
}

export function renderIssue(issue: MirrorIssue, comments: JiraCommentEntry[]): string {
  const f = issue.fields;
  const links = linkGroups(issue);
  const fm = [
    '---',
    `key: ${q(issue.key)}`,
    `type: ${q(f.issuetype?.name)}`,
    `status: ${q(f.status?.name)}`,
    `statusCategory: ${q(f.status?.statusCategory?.name)}`,
    `priority: ${q(f.priority?.name)}`,
    `labels: ${list(f.labels ?? [])}`,
    `fixVersions: ${list((f.fixVersions ?? []).map((v) => v.name ?? ''))}`,
    `parent: ${q(f.parent?.key)}`,
    `created: ${q(f.created)}`,
    `updated: ${q(f.updated)}`,
    `resolution: ${q(f.resolution?.name)}`,
    'links:',
    `  blocks: ${list(links.blocks)}`,
    `  blocked_by: ${list(links.blocked_by)}`,
    `  relates: ${list(links.relates)}`,
    '---',
    '',
  ];
  const body = [`# ${issue.key}: ${scrubEmails(f.summary ?? '')}`, '', '## Description', ''];
  body.push(scrubEmails(adfToPlainText(f.description)) || '_(none)_', '');
  const sorted = [...comments].sort((a, b) => a.created.localeCompare(b.created));
  body.push('## Comments', '');
  if (sorted.length === 0) body.push('_(none)_', '');
  for (const c of sorted) {
    body.push(`### ${scrubEmails(c.author?.displayName ?? 'unknown')} — ${c.created}`, '');
    body.push(scrubEmails(adfToPlainText(c.body)), '');
  }
  return [...fm, ...body].join('\n');
}

export const defaultRoot = (project: string): string => join(homedir(), '.himmel', 'state', 'jira-mirror', project);

export function readCursor(root: string): Cursor | null {
  try {
    const c = JSON.parse(readFileSync(join(root, CURSOR_FILE), 'utf8')) as Cursor;
    return typeof c.lastSync === 'string' && !Number.isNaN(Date.parse(c.lastSync)) ? c : null;
  } catch {
    return null;
  }
}

function writeFileAtomic(path: string, content: string): void {
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, content);
  renameSync(tmp, path);
}

async function searchPages(
  jql: string,
  fields: string,
  req: Req,
  onPage: (issues: MirrorIssue[]) => Promise<void> | void,
): Promise<void> {
  let token: string | undefined;
  const seen = new Set<string>();
  do {
    if (token !== undefined) {
      if (seen.has(token)) throw new Error(`jira mirror: pagination loop detected — nextPageToken "${token}" repeated`);
      seen.add(token);
    }
    const cursor = token === undefined ? '' : `&nextPageToken=${encodeURIComponent(token)}`;
    const page = await req<SearchPage>(
      'GET',
      `/search/jql?jql=${encodeURIComponent(jql)}&fields=${fields}&maxResults=${PAGE_MAX}${cursor}`,
    );
    if (page.issues.length === 0) break;
    await onPage(page.issues);
    token = page.nextPageToken;
  } while (token !== undefined);
}

async function inChunks<T>(items: T[], size: number, fn: (t: T) => Promise<void>): Promise<void> {
  for (let i = 0; i < items.length; i += size) await Promise.all(items.slice(i, i + size).map(fn));
}

const localKeys = (root: string): string[] =>
  existsSync(root) ? readdirSync(root).filter((n) => /^[A-Z][A-Z0-9_]*-\d+\.md$/.test(n)).map((n) => n.slice(0, -3)) : [];

export async function runMirror(opts: MirrorOptions, req: Req): Promise<MirrorResult> {
  const { root, project } = opts;
  const now = opts.now ?? (() => new Date());
  const warn = opts.warn ?? ((m: string) => process.stderr.write(`jira mirror: ${m}\n`));
  const startedAt = now();
  mkdirSync(root, { recursive: true });

  const cursor = opts.full ? null : readCursor(root);
  const mode = cursor ? 'incremental' : 'full';
  let jql = `project = ${project} ORDER BY key ASC`;
  if (cursor) {
    // Relative JQL ("-Nm") is timezone-independent, unlike an absolute datetime.
    const mins = Math.max(1, Math.ceil((startedAt.getTime() - Date.parse(cursor.lastSync)) / 60000)) + OVERLAP_MINUTES;
    jql = `project = ${project} AND updated >= "-${mins}m" ORDER BY updated ASC`;
  }

  const res: MirrorResult = {
    mode, fetched: 0, written: 0, unchanged: 0, deleted: 0, deleteSkipped: null, mirrorCount: 0, jiraTotal: null,
  };
  const fullKeys = new Set<string>();

  await searchPages(jql, FIELDS, req, async (issues) => {
    await inChunks(issues, opts.concurrency ?? 5, async (issue) => {
      res.fetched++;
      fullKeys.add(issue.key);
      const c = issue.fields.comment;
      const embedded = c?.comments ?? [];
      const comments =
        (c?.total ?? 0) === 0 ? [] : embedded.length >= (c?.total ?? 0) ? embedded : await fetchAllComments(issue.key, req);
      const md = renderIssue(issue, comments);
      const path = join(root, `${issue.key}.md`);
      if (existsSync(path) && readFileSync(path, 'utf8') === md) res.unchanged++;
      else {
        writeFileAtomic(path, md);
        res.written++;
      }
    });
  });

  // Delete/move detection: authoritative key list. Fails SAFE — an error or a
  // suspiciously short list deletes nothing.
  const local = localKeys(root);
  let live: Set<string> | null = null;
  if (mode === 'full') live = fullKeys;
  else {
    try {
      const keys = new Set<string>();
      await searchPages(`project = ${project} ORDER BY key ASC`, 'key', req, (is) => {
        for (const i of is) keys.add(i.key);
      });
      live = keys;
    } catch (err) {
      res.deleteSkipped = `key listing failed: ${err instanceof Error ? err.message : String(err)}`;
    }
  }
  if (live && local.length > 0 && live.size < local.length * DELETE_SAFETY_RATIO) {
    res.deleteSkipped = `key listing returned ${live.size} of ${local.length} local files (< ${DELETE_SAFETY_RATIO * 100}%)`;
    live = null;
  }
  if (res.deleteSkipped) warn(`delete pass skipped — ${res.deleteSkipped}`);
  if (live) {
    for (const k of local) {
      if (!live.has(k)) {
        unlinkSync(join(root, `${k}.md`));
        res.deleted++;
      }
    }
  }

  res.mirrorCount = localKeys(root).length;
  try {
    const { count } = await req<{ count: number }>('POST', '/search/approximate-count', { jql: `project = ${project}` });
    res.jiraTotal = typeof count === 'number' ? count : null;
  } catch {
    res.jiraTotal = null;
  }
  writeFileAtomic(join(root, CURSOR_FILE), JSON.stringify({ lastSync: startedAt.toISOString(), total: res.mirrorCount }) + '\n');
  return res;
}

export function mirrorAgeMinutes(root: string, now: Date = new Date()): number | null {
  const c = readCursor(root);
  return c ? Math.floor((now.getTime() - Date.parse(c.lastSync)) / 60000) : null;
}

// qmd registration + re-embed. Never throws: the sync has already succeeded.
export function qmdRefresh(root: string, run: (args: string[]) => string = (a) => execFileSync('qmd', a, { encoding: 'utf8' })): string {
  try {
    if (!run(['collection', 'list']).includes(`${COLLECTION} (`)) {
      run(['collection', 'add', root, '--name', COLLECTION]);
    }
    run(['update']);
    run(['embed', '-c', COLLECTION]);
    return `qmd: collection ${COLLECTION} updated and embedded`;
  } catch (err) {
    return `qmd: refresh FAILED (${err instanceof Error ? err.message.split('\n')[0] : String(err)}); the mirror sync itself succeeded`;
  }
}

export function registerMirror(program: Command): void {
  program
    .command('mirror')
    .description('Mirror Jira issues to markdown files (full backfill, then incremental) for qmd retrieval; read-only against Jira')
    .option('--root <dir>', 'Mirror root (default: ~/.himmel/state/jira-mirror/<PROJECT>)')
    .option('--full', 'Ignore the cursor and re-fetch everything')
    .option('--status', 'Print mirror age and file count, then exit (no network)')
    .option('--qmd', `Register the ${COLLECTION} qmd collection if missing, then qmd update + embed (failure is reported, not fatal)`)
    .action(async (options: { root?: string; full?: boolean; status?: boolean; qmd?: boolean }) => {
      const project = projectKey();
      const root = options.root ?? defaultRoot(project);
      if (options.status) {
        const age = mirrorAgeMinutes(root);
        console.log(`mirror root=${root} files=${localKeys(root).length} age_minutes=${age ?? 'never-synced'}`);
        return;
      }
      const r = await runMirror({ root, project, full: options.full }, request);
      console.log(
        `mirror ${r.mode}: fetched=${r.fetched} written=${r.written} unchanged=${r.unchanged} deleted=${r.deleted}\n` +
          `mirror count=${r.mirrorCount} jira total=${r.jiraTotal ?? 'unknown'}`,
      );
      if (options.qmd) console.log(qmdRefresh(root));
    });
}
