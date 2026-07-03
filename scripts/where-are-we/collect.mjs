// scripts/where-are-we/collect.mjs
import { execFileSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
import { jiraRecords, prRecords, gitRecords } from './lib/collect.mjs';
import { branchToKey } from './lib/query.mjs';
import { appendRecords } from './lib/append.mjs';
import { readRecords } from './lib/ledger.mjs';
import { fold, inFlight } from './lib/fold.mjs';
import { UsageError } from './lib/errors.mjs';

// Well-formed Jira ticket key, e.g. HIMMEL-567 / LUNA-44. Used to filter the
// active-key set passed into the by-key status query (no JQL injection) and to
// keep PR keys (#7) out of it.
const TICKET_KEY_RE = /^[A-Z][A-Z0-9]+-\d+$/;

// Explicit page size for the live working set. The jira CLI defaults to
// --limit 25; the project-wide In-Progress set is well under this but the
// default is a trap (HIMMEL-567), so we pin a high ceiling rather than rely on
// it.
const JIRA_LIMIT = '200';

// ---------------------------------------------------------------------------
// Live readers (impure — each degrades gracefully to [] / '' on failure)
// ---------------------------------------------------------------------------

// Depth assumption: this file is scripts/where-are-we/collect.mjs, so the two
// '..' hops on the next line reach the repo root. If this file moves, recount
// those hops (the adjacent _jiraCli must resolve to a real file).
const _repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const _jiraCli = join(_repoRoot, 'scripts', 'jira', 'dist', 'index.js');

// Build the jira CLI arg-lists for one collection pass. Pure + exported so the
// query shapes (per-status, explicit --limit, by-key all-status) are unit-testable
// without shelling out.
//
// The old single `--status 'To Do,In Progress,Done'` query truncated at the CLI
// default of 25 rows — with hundreds of historical Done tickets matching, the
// page filled before any In-Progress row, so live work never reached the ledger
// (HIMMEL-567). Instead:
//   - In-Progress is read project-wide with an explicit high --limit (the HIMMEL
//     live working set, always small);
//   - every ACTIVE key is re-read by key across ALL statuses. This serves three
//     ends: (a) a HIMMEL ticket still self-clears on its Done transition (fold
//     treats 'done' as terminal) without re-reading the unbounded Done history;
//     (b) a cross-project LUNA *harness* ticket (one with a himmel footprint —
//     open PR / locked worktree) shows its real status even though it never
//     appears in the HIMMEL-project status lists (HIMMEL-573); (c) a To-Do ticket
//     surfaces ONLY when it carries a real footprint (an open PR / a locked
//     worktree / a prior-pass ledger breadcrumb seeds it into activeKeys).
//     LUNA vault/content tickets carry no footprint, so they never become active
//     keys and never enter the report.
//
// The blanket `--status 'To Do'` read was DROPPED (HIMMEL-679): reading every
// backlog ticket project-wide folded the entire To-Do backlog (~188 keys) into
// "Other in-flight" and drowned the real live work. HIMMEL-567's actual goal —
// not truncating In-Progress — is preserved: that bug was the combined query
// filling the page with Done rows, not the To-Do read itself.
export function jiraQueries(activeKeys = []) {
  const queries = [
    ['list', '--status', 'In Progress', '--limit', JIRA_LIMIT],
  ];
  const safeKeys = activeKeys.filter((k) => TICKET_KEY_RE.test(k));
  if (safeKeys.length) {
    queries.push(['list', '--jql', `key in (${safeKeys.join(',')})`]);
  }
  return queries;
}

function parseJiraRows(out) {
  const rows = [];
  for (const line of out.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const cols = trimmed.split('\t');
    // columns: KEY\tTYPE\tSTATUS\tTITLE
    if (cols.length < 3) continue;
    const key = cols[0].trim();
    const status = cols[2].trim();
    if (!key || !status || key === 'KEY') continue; // skip header if any
    rows.push({ key, status });
  }
  return rows;
}

function readJira(activeKeys = []) {
  const rows = [];
  for (const args of jiraQueries(activeKeys)) {
    try {
      const out = execFileSync(process.execPath, [_jiraCli, ...args], { encoding: 'utf8' });
      rows.push(...parseJiraRows(out));
    } catch (err) {
      // One failed query degrades to skipping it — partial data beats none.
      console.error('[where-are-we] jira reader unavailable:', err.message);
    }
  }
  return rows;
}

function readPRs() {
  try {
    const out = execFileSync('gh', ['pr', 'list', '--state', 'all', '--json', 'number,state,headRefName,title'], { encoding: 'utf8' });
    return JSON.parse(out);
  } catch (err) {
    console.error('[where-are-we] gh reader unavailable:', err.message);
    return [];
  }
}

function readWorktrees() {
  try {
    return execFileSync('git', ['worktree', 'list', '--porcelain'], { encoding: 'utf8' });
  } catch (err) {
    console.error('[where-are-we] git reader unavailable:', err.message);
    return '';
  }
}

// ---------------------------------------------------------------------------
// collectAll — wiring (exported for testing with injected readers)
// ---------------------------------------------------------------------------

export function collectAll(now, readers = { readJira, readPRs, readWorktrees }, activeKeys = []) {
  const prList = readers.readPRs();
  // Cross-project harness tickets (HIMMEL-573): a LUNA ticket carrying an OPEN
  // himmel PR is harness work and must show its real Jira status, even though it
  // never appears in the HIMMEL-project status lists. Seed those branch keys into
  // the active set so jiraQueries reads them by key. OPEN only — merged/closed
  // history would re-query hundreds of terminal tickets every pass.
  const prKeys = prList
    .filter((p) => String(p.state).toUpperCase() === 'OPEN')
    .map((p) => branchToKey(p.headRefName))
    .filter((k) => k && TICKET_KEY_RE.test(k));
  const allKeys = [...new Set([...activeKeys, ...prKeys])];
  const jira = jiraRecords(readers.readJira(allKeys), now);
  const prs = prRecords(prList, now);
  const git = gitRecords(readers.readWorktrees(), now);
  return [...jira, ...prs, ...git];
}

// Non-terminal ticket keys currently in the ledger — the set whose Done
// transitions we must re-read so they self-clear. Fail-open: an unreadable or
// malformed ledger yields no keys (skip the Done read, never throw the collect).
function activeTicketKeys(ledgerPath) {
  let records;
  try {
    records = readRecords(ledgerPath);
  } catch {
    return [];
  }
  return inFlight(fold(records))
    .filter((it) => it.kind === 'ticket' && TICKET_KEY_RE.test(it.key))
    .map((it) => it.key);
}

// ---------------------------------------------------------------------------
// main — parse args, collect, append, return summary (exported for testing)
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const a = { ledger: null, now: null };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--ledger') a.ledger = argv[++i];
    else if (argv[i] === '--now') a.now = argv[++i];
  }
  return a;
}

export function main(argv, { readers } = {}) {
  const a = parseArgs(argv);
  if (!a.ledger) throw new UsageError('--ledger <path> is required');
  const now = a.now ?? new Date().toISOString();
  const effectiveReaders = readers ?? { readJira, readPRs, readWorktrees };

  const activeKeys = activeTicketKeys(a.ledger);
  const records = collectAll(now, effectiveReaders, activeKeys);
  const r = appendRecords(a.ledger, records);
  const summary = `appended=${r.appended} dropped=${r.dropped}`;
  if (r.dropped > 0) {
    console.error('[where-are-we] dropped records:', r.dropReasons);
  }
  return summary;
}

// ---------------------------------------------------------------------------
// CLI entry
// ---------------------------------------------------------------------------

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  try {
    console.log(main(process.argv.slice(2)));
  } catch (e) {
    // Clean message for UsageError, full stack otherwise (rationale: lib/errors.mjs).
    console.error(e instanceof UsageError ? e.message : (e.stack || String(e)));
    process.exit(1);
  }
}
