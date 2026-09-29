import type { Command } from 'commander';
import { writeFileSync } from 'node:fs';
import { agileRequest, projectKey, request } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { resolveBoard } from './sprint.js';
import { checkDate } from './versions.js';

// HIMMEL-3890: the roadmap lives in Jira custom fields (design doc section 1,
// scoring from the HIMMEL-3882 frame sections 2 and 5). Fields are always
// addressed by the id resolved from their display name, never by a hardcoded
// id, so the CLI survives a re-created field; a missing field fails loud.

type Req = typeof request;

export const ROADMAP_FIELD_NAMES = {
  readiness: 'Readiness',
  theme: 'Theme',
  goals: 'Roadmap Goals',
  impact: 'Roadmap Impact',
  alignment: 'Alignment',
  roi: 'ROI',
  auditDate: 'Audit date',
  auditEvidence: 'Audit evidence',
  closeCandidate: 'Close candidate',
  effort: 'Story point estimate',
} as const;

export type RoadmapKey = keyof typeof ROADMAP_FIELD_NAMES;
export type RoadmapIds = Record<RoadmapKey, string>;

export const THEMES = [
  'Guard safety', 'Wiring gaps', 'Console hierarchy', 'Ship-loop gates', 'Sessions + locks',
  'Bank + CI cost', 'Test signal', 'Observability', 'Skill profile validation', 'Install + adopter',
  'Knowledge substrate', 'North Star a', 'North Star b', 'North Star c', 'Off-goal', 'Windows',
];

export const GOALS = [
  'G1 Structural safety', 'G2 Work survives sessions', 'G3 Trustworthy ship loop', 'G4 Bank + wall-time',
  'G5 Adopter-ready install', 'G6 Honest test signal', 'G7 Knowledge substrate', 'North Star', 'off', 'win',
];

// Frame section 2. North Star has no weight on purpose: it needs an explicit --alignment.
const GOAL_WEIGHTS: Record<string, number> = {
  G1: 1.0, G2: 0.9, G3: 0.9, G4: 0.8, G5: 0.7, G6: 0.7, G7: 0.5, off: 0.25, win: 0.2,
};

// Frame section 5: S-equivalents (bank units / 0.009); x1.3 for non-trivial G1 guard work.
const EFFORT: Record<string, number> = { XS: 0.44, S: 1, M: 2.2, L: 5, XL: 11.1 };
const GUARD_FACTOR = 1.3;
const CONFIDENCE: Record<number, number> = { 1: 0.25, 2: 0.5, 3: 0.75, 4: 1.0 };

const round = (n: number, places: number) => Math.round(n * 10 ** places) / 10 ** places;

async function fieldIndex(req: Req): Promise<Map<string, string[]>> {
  const all = await req<Array<{ id: string; name: string }>>('GET', '/field');
  const byName = new Map<string, string[]>();
  for (const f of all) byName.set(f.name, [...(byName.get(f.name) ?? []), f.id]);
  return byName;
}

function pick(byName: Map<string, string[]>, name: string): string {
  const ids = byName.get(name) ?? [];
  if (ids.length === 0) throw new Error(`roadmap: Jira field "${name}" not found (HIMMEL-3890 apply step 2)`);
  if (ids.length > 1) throw new Error(`roadmap: Jira field name "${name}" is ambiguous (${ids.join(', ')})`);
  return ids[0];
}

// ponytail: one GET /field per command (no id cache), cache it in the breadcrumb dir if roadmap ops get hot.
export async function resolveRoadmapFields(req: Req = request): Promise<RoadmapIds> {
  return idsFrom(await fieldIndex(req));
}

function idsFrom(byName: Map<string, string[]>): RoadmapIds {
  const missing = Object.values(ROADMAP_FIELD_NAMES).filter((n) => !byName.has(n));
  if (missing.length) {
    throw new Error(`roadmap: Jira fields not found: ${missing.join(', ')} (HIMMEL-3890 apply step 2)`);
  }
  const ids = {} as RoadmapIds;
  for (const [k, name] of Object.entries(ROADMAP_FIELD_NAMES)) ids[k as RoadmapKey] = pick(byName, name);
  return ids;
}

export function effortPoints(size: string, guard = false): number {
  const base = EFFORT[size.trim().toUpperCase()];
  if (base === undefined) throw new Error(`--effort must be one of XS, S, M, L, XL (got "${size}")`);
  return guard ? round(base * GUARD_FACTOR, 2) : base;
}

export function effortLabel(points: number | null | undefined): string {
  if (points === null || points === undefined) return '-';
  for (const size of Object.keys(EFFORT)) {
    if (effortPoints(size) === points) return `${size} (${points})`;
    if (effortPoints(size, true) === points) return `${size}+guard (${points})`;
  }
  return String(points);
}

export function goalOptions(input: string): string[] {
  return input
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)
    .map((t) => {
      const want = t.toLowerCase();
      const hit = GOALS.find((g) => g.toLowerCase() === want || g.split(' ')[0].toLowerCase() === want);
      if (!hit) throw new Error(`--goals: unknown goal "${t}" (use G1..G7, North Star, off, win)`);
      return hit;
    });
}

/** Highest goal weight; undefined when any goal has no weight (North Star). */
export function alignmentFromGoals(goals: string[]): number | undefined {
  const weights = goals.map((g) => GOAL_WEIGHTS[g.split(' ')[0]]);
  if (weights.length === 0 || weights.some((w) => w === undefined)) return undefined;
  return Math.max(...(weights as number[]));
}

export interface RoiInputs {
  readiness: number | null;
  impact: number | null;
  alignment: number | null;
  effort: number | null;
}

/** impact x alignment x confidence / effort; null when not placeable or an input is missing. */
export function computeRoi(v: RoiInputs): number | null {
  const confidence = v.readiness === null ? undefined : CONFIDENCE[v.readiness];
  if (confidence === undefined || v.impact === null || v.alignment === null || !v.effort) return null;
  return round((v.impact * v.alignment * confidence) / v.effort, 3);
}

export interface RoadmapSetOptions {
  readiness?: string;
  theme?: string;
  goals?: string;
  impact?: string;
  alignment?: string;
  effort?: string;
  guard?: boolean;
  auditDate?: string;
  auditEvidence?: string;
  closeCandidate?: string;
  noRoi?: boolean;
}

function num(raw: string, flag: string, min: number, max: number, integer = false): number {
  const n = raw.trim() === '' ? NaN : Number(raw);
  if (!Number.isFinite(n) || n < min || n > max || (integer && !Number.isInteger(n))) {
    throw new Error(`--${flag} must be ${integer ? 'an integer' : 'a number'} ${min}-${max} (got "${raw}")`);
  }
  return n;
}

export function buildRoadmapFields(ids: RoadmapIds, o: RoadmapSetOptions): Record<string, unknown> {
  const f: Record<string, unknown> = {};
  if (o.readiness !== undefined) f[ids.readiness] = num(o.readiness, 'readiness', 0, 4, true);
  if (o.theme !== undefined) {
    const theme = THEMES.find((t) => t.toLowerCase() === o.theme!.trim().toLowerCase());
    if (!theme) throw new Error(`--theme: unknown theme "${o.theme}" (one of: ${THEMES.join(', ')})`);
    f[ids.theme] = { value: theme };
  }
  let goals: string[] | undefined;
  if (o.goals !== undefined) {
    goals = goalOptions(o.goals);
    f[ids.goals] = goals.map((value) => ({ value }));
  }
  if (o.impact !== undefined) f[ids.impact] = num(o.impact, 'impact', 1, 5);
  if (o.alignment !== undefined) {
    f[ids.alignment] = num(o.alignment, 'alignment', 0.2, 1.0);
  } else if (goals !== undefined) {
    const derived = alignmentFromGoals(goals);
    if (derived === undefined) throw new Error('--goals has no alignment weight (North Star): pass --alignment');
    f[ids.alignment] = derived;
  }
  if (o.guard && o.effort === undefined) throw new Error('--guard needs --effort');
  if (o.effort !== undefined) f[ids.effort] = effortPoints(o.effort, o.guard);
  if (o.auditDate !== undefined) f[ids.auditDate] = checkDate(o.auditDate, '--audit-date');
  if (o.auditEvidence !== undefined) {
    let ok = false;
    try {
      ok = ['http:', 'https:'].includes(new URL(o.auditEvidence).protocol);
    } catch {
      ok = false;
    }
    if (!ok) throw new Error(`--audit-evidence must be an http(s) URL (got "${o.auditEvidence}")`);
    f[ids.auditEvidence] = o.auditEvidence;
  }
  if (o.closeCandidate !== undefined) {
    const v = o.closeCandidate.trim().toLowerCase();
    if (v !== 'yes' && v !== 'no') throw new Error(`--close-candidate must be yes|no (got "${o.closeCandidate}")`);
    f[ids.closeCandidate] = v === 'yes' ? [{ value: 'yes' }] : [];
  }
  if (Object.keys(f).length === 0) throw new Error('roadmap set: nothing to set');
  return f;
}

type Fields = Record<string, unknown>;

const readRoadmap = async (req: Req, key: string, ids: RoadmapIds) =>
  (await req<{ fields: Fields }>('GET', `/issue/${key}?fields=${Object.values(ids).join(',')}`)).fields;

const numOrNull = (v: unknown) => (typeof v === 'number' ? v : null);

export async function roadmapSet(key: string, o: RoadmapSetOptions, req: Req = request): Promise<string> {
  const ids = await resolveRoadmapFields(req);
  const fields = buildRoadmapFields(ids, o);
  await req('PUT', `/issue/${key}`, { fields });
  const names = Object.keys(fields).map((id) => (Object.keys(ids) as RoadmapKey[]).find((k) => ids[k] === id));
  const head = `${key} roadmap set (${names.join(', ')})`;
  if (o.noRoi) return head;
  // ROI is recomputed from what Jira now stores, so a partial set still scores every input.
  const cur = await readRoadmap(req, key, ids);
  const roi = computeRoi({
    readiness: numOrNull(cur[ids.readiness]),
    impact: numOrNull(cur[ids.impact]),
    alignment: numOrNull(cur[ids.alignment]),
    effort: numOrNull(cur[ids.effort]),
  });
  if (roi !== numOrNull(cur[ids.roi])) await req('PUT', `/issue/${key}`, { fields: { [ids.roi]: roi } });
  return `${head}; ROI ${roi ?? 'cleared (not placeable)'}`;
}

function show(v: unknown): string {
  if (v === null || v === undefined) return '-';
  if (Array.isArray(v)) return v.length ? v.map(show).join(', ') : '-';
  if (typeof v === 'object' && 'value' in (v as object)) return String((v as { value: unknown }).value);
  return String(v);
}

export async function roadmapGet(key: string, req: Req = request): Promise<string> {
  const ids = await resolveRoadmapFields(req);
  const cur = await readRoadmap(req, key, ids);
  return (Object.keys(ROADMAP_FIELD_NAMES) as RoadmapKey[])
    .map((k) => {
      if (k === 'effort') return `Effort: ${effortLabel(numOrNull(cur[ids.effort]))}`;
      return `${ROADMAP_FIELD_NAMES[k]}: ${show(cur[ids[k]])}`;
    })
    .join('\n');
}

const PAGE_MAX = 100;

async function searchKeys<T>(req: Req, jql: string, fields: string): Promise<T[]> {
  const out: T[] = [];
  const seen = new Set<string>();
  let token: string | undefined;
  do {
    if (token !== undefined) {
      if (seen.has(token)) throw new Error(`roadmap: pagination loop detected — nextPageToken "${token}" repeated`);
      seen.add(token);
    }
    const cursor = token === undefined ? '' : `&nextPageToken=${encodeURIComponent(token)}`;
    const page = await req<{ issues: T[]; nextPageToken?: string }>(
      'GET',
      `/search/jql?jql=${encodeURIComponent(jql)}&fields=${fields}&maxResults=${PAGE_MAX}${cursor}`,
    );
    out.push(...page.issues);
    token = page.nextPageToken;
    if (page.issues.length === 0) break;
  } while (token !== undefined);
  return out;
}

const EXPORT_FIELDS = ['summary', 'issuetype', 'status', 'priority', 'parent', 'fixVersions', 'issuelinks', 'labels'];

/** Design section 5 queries 1-2: everything the roadmap page is regenerated from. */
export async function roadmapExport(
  project: string,
  req: Req = request,
  now: () => string = () => new Date().toISOString(),
): Promise<Record<string, unknown>> {
  const byName = await fieldIndex(req);
  const ids = idsFrom(byName);
  const sprint = pick(byName, 'Sprint');
  const versions = await req<unknown[]>('GET', `/project/${encodeURIComponent(project)}/versions`);
  const jql = `project = ${project} AND statusCategory != Done ORDER BY fixVersion ASC, Rank ASC`;
  const issues = await searchKeys<unknown>(req, jql, [...EXPORT_FIELDS, sprint, ...Object.values(ids)].join(','));
  return { project, generatedAt: now(), jql, fieldIds: { ...ids, sprint }, versions, issues };
}

interface Version { id: string; name: string; released?: boolean; startDate?: string; releaseDate?: string }
interface Sprint { id: number; name: string; state: string; startDate?: string; endDate?: string }

const MOVE_CHUNK = 50;

async function boardSprints(agile: Req, board: string): Promise<Sprint[]> {
  const out: Sprint[] = [];
  for (;;) {
    const at = out.length ? `&startAt=${out.length}` : '';
    const page = await agile<{ values: Sprint[]; isLast?: boolean }>(
      'GET',
      `/board/${board}/sprint?state=active,future&maxResults=50${at}`,
    );
    out.push(...(page.values ?? []));
    if (page.isLast !== false || !page.values?.length) return out;
  }
}

const preview = (keys: string[]) => keys.slice(0, 10).join(' ') + (keys.length > 10 ? ' …' : '');

const day = (iso?: string) => (iso ? new Date(iso).toISOString().slice(0, 10) : undefined);

/**
 * Design section 4: fixVersion is the source of truth, the sprint is the view.
 * Each unreleased version with a start and release date gets a same-named
 * sprint on the board carrying the version's dates, and its open issues are
 * moved into it. An issue on several dated versions belongs to the one that
 * releases first, so repeated runs never bounce it between sprints.
 */
export async function syncSprints(
  project: string,
  board: string,
  dryRun: boolean,
  req: Req = request,
  agile: Req = agileRequest,
): Promise<{ lines: string[]; drift: number }> {
  const versions = (await req<Version[]>('GET', `/project/${encodeURIComponent(project)}/versions`))
    .filter((v) => !v.released && v.startDate && v.releaseDate)
    .sort((a, b) => (a.releaseDate! < b.releaseDate! ? -1 : a.releaseDate! > b.releaseDate! ? 1 : 0));
  const sprints = await boardSprints(agile, board);
  const claimed = new Set<string>();
  const lines: string[] = [];
  let drift = 0;
  for (const v of versions) {
    let sprint = sprints.find((s) => s.name === v.name);
    const dates = { startDate: `${v.startDate}T00:00:00.000Z`, endDate: `${v.releaseDate}T23:59:00.000Z` };
    const staleDates = !!sprint && (day(sprint.startDate) !== v.startDate || day(sprint.endDate) !== v.releaseDate);
    const base = `project = ${project} AND fixVersion = "${v.name.replace(/"/g, '\\"')}" AND statusCategory != Done`;
    const all = (await searchKeys<{ key: string }>(req, base, 'summary')).map((i) => i.key);
    const mine = new Set(all.filter((k) => !claimed.has(k)));
    all.forEach((k) => claimed.add(k));
    const outside = sprint
      ? (await searchKeys<{ key: string }>(req, `${base} AND (sprint is EMPTY OR sprint != ${sprint.id})`, 'summary')).map((i) => i.key)
      : all;
    const keys = outside.filter((k) => mine.has(k));
    if (dryRun) {
      drift += keys.length + (sprint ? 0 : 1) + (staleDates ? 1 : 0);
      let where = sprint ? `sprint ${sprint.id}` : `sprint missing (would create ${v.startDate}..${v.releaseDate})`;
      if (staleDates) where += ` (dates ${day(sprint!.startDate)}..${day(sprint!.endDate)}, would set ${v.startDate}..${v.releaseDate})`;
      lines.push(keys.length ? `${v.name}: ${where}, move ${keys.length} (${preview(keys)})` : `${v.name}: ${where}, ${staleDates ? 'issues in sync' : 'in sync'}`);
      continue;
    }
    let where = sprint ? `sprint ${sprint.id}` : '';
    if (!sprint) {
      sprint = await agile<Sprint>('POST', '/sprint', { name: v.name, originBoardId: Number(board), ...dates });
      where = `created sprint ${sprint.id}`;
    } else if (staleDates) {
      await agile('POST', `/sprint/${sprint.id}`, dates);
      where += ' (dates updated)';
    }
    for (let i = 0; i < keys.length; i += MOVE_CHUNK) {
      await agile('POST', `/sprint/${sprint.id}/issue`, { issues: keys.slice(i, i + MOVE_CHUNK) });
    }
    lines.push(`${v.name}: ${where}, moved ${keys.length}`);
  }
  return { lines, drift };
}

export function registerRoadmap(program: Command): void {
  const roadmap = program.command('roadmap').description('Roadmap fields, ranking inputs, export and sprint sync (HIMMEL-3890)');

  roadmap
    .command('fields')
    .description('Resolve the roadmap custom fields by name and print their ids')
    .option('--json', 'Print the id map as JSON')
    .action(async (o: { json?: boolean }) => {
      const ids = await resolveRoadmapFields();
      if (o.json) {
        console.log(JSON.stringify(ids, null, 2));
        return;
      }
      for (const k of Object.keys(ids) as RoadmapKey[]) console.log(`${k}\t${ROADMAP_FIELD_NAMES[k]}\t${ids[k]}`);
    });

  roadmap
    .command('set <key>')
    .description('Set roadmap fields on an issue, then recompute ROI')
    .option('--readiness <0-4>', 'Readiness rubric score (integer 0-4)')
    .option('--theme <name>', `Theme (${THEMES.join(', ')})`)
    .option('--goals <list>', 'Comma-separated goals: G1..G7, North Star, off, win')
    .option('--impact <1-5>', 'Impact 1-5')
    .option('--alignment <n>', 'Alignment 0.2-1.0 (default: derived from --goals)')
    .option('--effort <size>', 'Effort XS, S, M, L or XL (stored as S-equivalents)')
    .option('--guard', 'Non-trivial G1 guard work: effort x1.3')
    .option('--audit-date <date>', 'Last readiness audit, YYYY-MM-DD')
    .option('--audit-evidence <url>', 'Link to the audit evidence')
    .option('--close-candidate <yes|no>', 'Flag or unflag as a close candidate')
    .option('--no-roi', 'Do not recompute ROI after the write')
    .action(async (key: string, o: RoadmapSetOptions & { roi?: boolean }) => {
      console.log(await roadmapSet(key, { ...o, noRoi: o.roi === false }));
      writeJiraBreadcrumb(key);
    });

  roadmap
    .command('get <key>')
    .description('Print the roadmap fields of an issue')
    .action(async (key: string) => {
      console.log(await roadmapGet(key));
    });

  roadmap
    .command('export')
    .description('Write the open roadmap (versions + issues + field ids) as one JSON file')
    .requiredOption('--out <file>', 'Output JSON path')
    .option('--project <key>', 'Project key (default: JIRA_PROJECT_KEY env var)')
    .action(async (o: { out: string; project?: string }) => {
      const data = await roadmapExport(o.project ?? projectKey());
      writeFileSync(o.out, `${JSON.stringify(data, null, 2)}\n`);
      console.log(`wrote ${(data.issues as unknown[]).length} issues to ${o.out}`);
    });

  roadmap
    .command('sync-sprints')
    .description('One sprint per dated unreleased fixVersion; move its open issues into it')
    .option('--board <id>', 'Board id (default: JIRA_BOARD_ID)')
    .option('--project <key>', 'Project key (default: JIRA_PROJECT_KEY env var)')
    .option('--dry-run', 'Report the drift and exit 1 if any, without writing')
    .action(async (o: { board?: string; project?: string; dryRun?: boolean }) => {
      const board = resolveBoard(o.board);
      const r = await syncSprints(o.project ?? projectKey(), board, Boolean(o.dryRun));
      if (r.lines.length === 0) console.log('no unreleased version has both a start and a release date');
      for (const line of r.lines) console.log(line);
      if (o.dryRun && r.drift > 0) process.exitCode = 1;
    });
}
