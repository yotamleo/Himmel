import type { Command } from 'commander';
import { readFileSync } from 'node:fs';
import { agileRequest } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';

// HIMMEL-3890: board order is the roadmap's placement order. Agile REST
// PUT /issue/rank moves up to 50 issues per call (API max) before or after one
// anchor issue; a partial failure answers 207 with per-issue entries.

const RANK_CHUNK = 50;
const KEY = /^[A-Z][A-Z0-9_]*-\d+$/;

type Req = typeof agileRequest;

interface RankAnswer {
  entries?: Array<{ issueKey?: string; status?: number; errors?: string[] }>;
}

async function putRank(req: Req, body: Record<string, unknown>): Promise<void> {
  const r = await req<RankAnswer>('PUT', '/issue/rank', body);
  const bad = (r?.entries ?? []).filter((e) => (e.status ?? 204) >= 300);
  if (bad.length) {
    throw new Error(`rank failed: ${bad.map((e) => `${e.issueKey} ${(e.errors ?? []).join('; ')}`).join(', ')}`);
  }
}

export async function rankIssue(
  key: string,
  opts: { before?: string; after?: string },
  req: Req = agileRequest,
): Promise<string> {
  if ((opts.before === undefined) === (opts.after === undefined)) {
    throw new Error('rank needs exactly one of --before <key> or --after <key>');
  }
  if (opts.before !== undefined) {
    await putRank(req, { issues: [key], rankBeforeIssue: opts.before });
    return `${key} ranked before ${opts.before}`;
  }
  await putRank(req, { issues: [key], rankAfterIssue: opts.after });
  return `${key} ranked after ${opts.after}`;
}

/** Rank keys top-down: keys[0] stays put, every later key lands after its predecessor. */
export async function rankOrder(keys: string[], req: Req = agileRequest): Promise<string> {
  if (keys.length < 2) throw new Error('rank --file needs at least two keys');
  let anchor = keys[0];
  for (let i = 1; i < keys.length; i += RANK_CHUNK) {
    const chunk = keys.slice(i, i + RANK_CHUNK);
    await putRank(req, { issues: chunk, rankAfterIssue: anchor });
    anchor = chunk[chunk.length - 1];
  }
  return `ranked ${keys.length - 1} issues after ${keys[0]}`;
}

export function parseOrderFile(text: string): string[] {
  const keys: string[] = [];
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    if (!KEY.test(line)) throw new Error(`rank --file: not an issue key: "${line}"`);
    if (keys.includes(line)) throw new Error(`rank --file: duplicate key ${line}`);
    keys.push(line);
  }
  return keys;
}

export function registerRank(program: Command): void {
  program
    .command('rank [key]')
    .description('Rank an issue before/after another, or rank a file of keys top-down')
    .option('--before <key>', 'Rank above this issue')
    .option('--after <key>', 'Rank below this issue')
    .option('--file <path>', 'One issue key per line, top first (# comments allowed)')
    .action(async (key: string | undefined, opts: { before?: string; after?: string; file?: string }) => {
      if (opts.file !== undefined) {
        if (key !== undefined || opts.before !== undefined || opts.after !== undefined) {
          throw new Error('rank --file takes no key, --before or --after');
        }
        console.log(await rankOrder(parseOrderFile(readFileSync(opts.file, 'utf8'))));
        return;
      }
      if (key === undefined) throw new Error('rank needs <key> or --file <path>');
      console.log(await rankIssue(key, opts));
      writeJiraBreadcrumb(key);
    });
}
