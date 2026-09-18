import type { Command } from 'commander';
import { request } from '../client.js';
import { adfToPlainText } from '../adf-render.js';
import type { ADFDocument } from '../adf-render.js';

export interface JiraCommentEntry {
  id: string;
  author?: { displayName: string };
  created: string;
  body: ADFDocument | null;
}

interface JiraCommentResp {
  comments: JiraCommentEntry[];
  total?: number;
}

const PAGE_MAX = 100;

// HIMMEL-3164. /issue/<key>/comment paginates (startAt/maxResults/total), so a
// single GET silently drops everything past the first page. Walk it by offset
// (same query-string idiom as list.ts's searchAllIssues, but offset- not
// token-based: this endpoint returns no cursor). The offset advances by the
// page ACTUALLY returned, since the server may clamp maxResults below what we
// asked for. An empty page ends the walk, so a `total` that overstates cannot
// loop forever; a response with no numeric `total` is treated as the last page.
export async function fetchAllComments(key: string, req: typeof request): Promise<JiraCommentEntry[]> {
  const all: JiraCommentEntry[] = [];
  let startAt = 0;
  for (;;) {
    const page = await req<JiraCommentResp>(
      'GET',
      `/issue/${key}/comment?startAt=${startAt}&maxResults=${PAGE_MAX}`,
    );
    const got = page.comments ?? [];
    all.push(...got);
    startAt += got.length;
    if (got.length === 0 || typeof page.total !== 'number' || startAt >= page.total) break;
  }
  return all;
}

// Jira's own comment order is not documented/guaranteed, so sort client-side
// rather than trust the API. `--last N` (parsed leniently, like list.ts's
// --limit: a non-numeric or non-positive value falls back to "no limit"
// rather than silently returning zero comments) keeps only the N most
// recent, but the returned slice stays oldest-first.
export function selectComments(comments: JiraCommentEntry[], last?: string): JiraCommentEntry[] {
  const sorted = [...comments].sort((a, b) => a.created.localeCompare(b.created));
  if (last === undefined) return sorted;
  const n = Number.parseInt(last, 10);
  if (!Number.isFinite(n) || n <= 0) return sorted;
  return sorted.slice(-n);
}

export function formatComments(comments: JiraCommentEntry[]): string {
  if (comments.length === 0) return 'No comments on this issue.';
  return comments
    .map((c) => `${c.author?.displayName ?? 'unknown'}\t${c.created}\n${adfToPlainText(c.body)}`)
    .join('\n\n');
}

export function registerComments(program: Command): void {
  program
    .command('comments <key>')
    .description('List comments on a Jira issue, oldest first (author, time, body as plain text)')
    .option('--last <n>', 'Only show the N most recent comments (still oldest-first)')
    .action(async (key: string, options: { last?: string }) => {
      const comments = await fetchAllComments(key, request);
      console.log(formatComments(selectComments(comments, options.last)));
    });
}
