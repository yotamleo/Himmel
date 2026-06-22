// scripts/where-are-we/collect.mjs
import { execFileSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
import { jiraRecords, prRecords, gitRecords } from './lib/collect.mjs';
import { appendRecords } from './lib/append.mjs';
import { UsageError } from './lib/errors.mjs';

// ---------------------------------------------------------------------------
// Live readers (impure — each degrades gracefully to [] / '' on failure)
// ---------------------------------------------------------------------------

// Depth assumption: this file is scripts/where-are-we/collect.mjs, so the two
// '..' hops on the next line reach the repo root. If this file moves, recount
// those hops (the adjacent _jiraCli must resolve to a real file).
const _repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const _jiraCli = join(_repoRoot, 'scripts', 'jira', 'dist', 'index.js');

function readJira() {
  try {
    // 'Done' is intentional: terminal tickets must be read so a Done transition
    // self-clears the ticket from the in-flight view (fold drops terminal items).
    // Do NOT drop Done — that would leave stale in-progress entries forever.
    const out = execFileSync(process.execPath, [_jiraCli, 'list', '--status', 'To Do,In Progress,Done'], { encoding: 'utf8' });
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
  } catch (err) {
    console.error('[where-are-we] jira reader unavailable:', err.message);
    return [];
  }
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

export function collectAll(now, readers = { readJira, readPRs, readWorktrees }) {
  const jira = jiraRecords(readers.readJira(), now);
  const prs = prRecords(readers.readPRs(), now);
  const git = gitRecords(readers.readWorktrees(), now);
  return [...jira, ...prs, ...git];
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

  const records = collectAll(now, effectiveReaders);
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
