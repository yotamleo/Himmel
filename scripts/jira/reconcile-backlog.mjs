#!/usr/bin/env node
// scripts/jira/reconcile-backlog.mjs — HIMMEL-374 pure-code backlog reconciler.
//
// Structural fix for Jira backlog drift (HIMMEL-195 philosophy): classify
// every open ticket against the merged-commit corpus with the deterministic
// rules in reconcile-lib.mjs, then comment+transition. No model calls.
//
// I/O only lives here; reconcile-lib.mjs stays a pure function library so
// the evidence rule is unit-testable against fixtures. This file talks to:
//   - the jira CLI's compiled client (dist/, built via `npm run build`) for
//     reads (issue search, comments) — no CLI verb exists for either, so we
//     import the same request() the CLI commands use rather than duplicate
//     auth/env handling.
//   - the jira CLI itself, as a subprocess, for writes (comment/transition)
//     — that preserves its breadcrumb-writing and attestation conventions
//     instead of bypassing them via a direct API call.
//   - git, for the commit corpus (subject + body per commit on `main`).
//
// Usage:
//   node reconcile-backlog.mjs [--apply] [--project HIMMEL] [--limit 2000]
//     [--config reconcile-config.json] [--hygiene-doc <path>]
//     [--commits-file <path>] [--jira-cli <path-to-dist/index.js>]
//     [--only KEY1,KEY2,...]
//
// Default is --dry-run (no writes). Prints one JSON line per candidate
// ticket to stdout, plus a summary line at the end.

import { execFileSync } from 'node:child_process';
import { readFileSync, existsSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { classifyTicket, findMatches, applyDisposition, buildEvidenceComment } from './reconcile-lib.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

export function parseArgs(argv) {
  const opts = {
    apply: false,
    project: process.env.JIRA_PROJECT_KEY,
    limit: '2000',
    config: join(HERE, 'reconcile-config.json'),
    hygieneDoc: null,
    commitsFile: null,
    jiraCli: join(HERE, 'dist', 'index.js'),
    only: null,
    maxClose: null,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--apply') opts.apply = true;
    else if (a === '--dry-run') opts.apply = false;
    else if (a === '--project') opts.project = argv[++i];
    else if (a === '--limit') opts.limit = argv[++i];
    else if (a === '--config') opts.config = argv[++i];
    else if (a === '--hygiene-doc') opts.hygieneDoc = argv[++i];
    else if (a === '--commits-file') opts.commitsFile = argv[++i];
    else if (a === '--jira-cli') opts.jiraCli = argv[++i];
    else if (a === '--only') opts.only = new Set(argv[++i].split(',').map((s) => s.trim()));
    else if (a === '--max-close') opts.maxClose = Number(argv[++i]);
    else {
      process.stderr.write(`reconcile-backlog: unknown argument "${a}"\n`);
      process.exit(1);
    }
  }
  if (!opts.project) {
    process.stderr.write('reconcile-backlog: --project or JIRA_PROJECT_KEY is required\n');
    process.exit(1);
  }
  return opts;
}

export function loadConfig(path) {
  if (!existsSync(path)) return {};
  return JSON.parse(readFileSync(path, 'utf8'));
}

// Every key named under ANY table (CLOSED / RESCOPED / STALE-PREMISE /
// LEFT ALONE / decided-but-not-written) of the hygiene-sweep report is
// "already adjudicated" — including the LEFT ALONE rows that carry no Jira
// comment at all (the gap this reconciler must not blindly re-close).
// All of the report's tables share one markdown shape: `| HIMMEL-1234 | ...`.
export function loadHygieneKeys(path) {
  if (!path) return new Set();
  if (!existsSync(path)) {
    process.stderr.write(`reconcile-backlog: --hygiene-doc path not found: ${path}\n`);
    process.exit(1);
  }
  const text = readFileSync(path, 'utf8');
  const keys = new Set();
  for (const m of text.matchAll(/^\|\s*([A-Za-z]+-\d+)\s*\|/gm)) keys.add(m[1]);
  return keys;
}

// Prefer an explicit --commits-file (date\tsubject, newest first — the shape
// a prior audit already produced by merging public + archived-private git
// history). Falling back to a live `git log` only covers THIS repo's public
// history: any ticket whose only evidence lives in the archived private
// history will read as no-evidence, not as a false CLOSE — a safe direction
// for a fallback to fail in. Neither path populates `body`: the --commits-file
// TSV shape carries subject only (a prior audit's own output format), and the
// live `git log` format below is subject-only for the same reason — a commit
// body can contain literal tabs/newlines that would corrupt a single-line
// TSV/`%x09`-joined record. bodyOnlyCommits matches are therefore unreachable
// from either loader today; a body-carrying format is possible (e.g. a NUL- or
// otherwise-delimited stream) but out of scope here since no live ticket in
// this repo's history has needed it.
export function loadCommits(commitsFile) {
  if (commitsFile) {
    const lines = readFileSync(commitsFile, 'utf8').split('\n').filter(Boolean);
    return lines.map((line) => {
      const [date, ...rest] = line.split('\t');
      return { sha: null, date, subject: rest.join('\t'), body: '' };
    });
  }
  process.stderr.write(
    'reconcile-backlog: no --commits-file given; falling back to `git log` on this repo only ' +
      '(archived private history, if any, will not be searched).\n',
  );
  // A shallow, single-ref checkout (e.g. CI's PR-merge-ref checkout) has no
  // local `main` branch at all; fall back to HEAD, which is `main` in the
  // normal case (invoked from the primary checkout) and the reviewed merge
  // ref in that CI case.
  let ref = 'main';
  try {
    execFileSync('git', ['-C', HERE, 'rev-parse', '-q', '--verify', 'main'], { stdio: 'ignore' });
  } catch {
    ref = 'HEAD';
  }
  const out = execFileSync(
    'git',
    ['-C', HERE, 'log', '--first-parent', ref, '--format=%H%x09%ad%x09%s', '--date=short'],
    { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 },
  );
  return out
    .split('\n')
    .filter(Boolean)
    .map((line) => {
      const [sha, date, ...rest] = line.split('\t');
      return { sha, date, subject: rest.join('\t'), body: '' };
    });
}

async function loadBacklog({ jiraCli, project, limit }) {
  const distDir = dirname(jiraCli);
  const { searchAllIssues } = await import(pathToFileURL(join(distDir, 'commands', 'list.js')).href);
  const { request } = await import(pathToFileURL(join(distDir, 'client.js')).href);
  // statusCategory (not a hardcoded open-status allow-list) so a project-specific
  // status like this backlog's own "Backlog" isn't silently excluded from
  // reconciliation just because it wasn't named here.
  const jql = `project=${project} AND statusCategory != Done ORDER BY created ASC`;
  const issues = await searchAllIssues(jql, limit, request);
  return issues.map((issue) => ({
    key: issue.key,
    issueType: issue.fields.issuetype.name,
    status: issue.fields.status.name,
  }));
}

// Paginated (startAt/maxResults/total — the classic Jira REST shape this
// endpoint uses, distinct from list.ts's cursor-based /search/jql): a ticket
// with more than one page of comments would otherwise have its later pages
// — including a prior adjudication or evidence marker — invisible to
// classifyTicket/hasSkipMarker, risking a re-close of an already-handled
// ticket.
async function loadCommentBodies({ jiraCli, key }) {
  const distDir = dirname(jiraCli);
  const { request } = await import(pathToFileURL(join(distDir, 'client.js')).href);
  const { adfToPlainText } = await import(pathToFileURL(join(distDir, 'adf-render.js')).href);
  const bodies = [];
  let startAt = 0;
  for (;;) {
    const result = await request('GET', `/issue/${key}/comment?startAt=${startAt}&maxResults=100`);
    const comments = result.comments ?? [];
    for (const c of comments) bodies.push(adfToPlainText(c.body) ?? '');
    startAt += comments.length;
    if (comments.length === 0 || startAt >= (result.total ?? startAt)) break;
  }
  return bodies;
}

async function loadDescription({ jiraCli, key }) {
  const distDir = dirname(jiraCli);
  const { request } = await import(pathToFileURL(join(distDir, 'client.js')).href);
  const { adfToPlainText } = await import(pathToFileURL(join(distDir, 'adf-render.js')).href);
  const issue = await request('GET', `/issue/${key}?fields=description`);
  return adfToPlainText(issue.fields?.description) ?? '';
}

function makeJiraClient(jiraCliPath) {
  return {
    async comment(key, body) {
      const tmpDir = mkdtempSync(join(tmpdir(), 'himmel-reconcile-'));
      const tmpFile = join(tmpDir, `${key}-comment.md`);
      writeFileSync(tmpFile, body);
      try {
        execFileSync('node', [jiraCliPath, 'comment', key, '--comment-file', tmpFile], {
          encoding: 'utf8',
        });
      } finally {
        rmSync(tmpDir, { recursive: true, force: true });
      }
    },
    async transition(key, status) {
      execFileSync('node', [jiraCliPath, 'transition', key, status], { encoding: 'utf8' });
    },
  };
}

// HIMMEL-3127: the orchestration loop main() used to run inline against real
// I/O (network Jira calls baked into loadCommentBodies/loadDescription,
// makeJiraClient's subprocess). Extracted here with every I/O boundary
// injected so the /backlog-reconcile surface's operator-approval gate is
// unit-testable against a fixture backlog — `apply` is the ONLY switch that
// lets the loop reach jiraClient.comment/transition.
export async function runReconciliation({
  backlog,
  commits,
  hygieneKeys,
  targetStatus,
  only,
  apply,
  maxClose,
  jiraClient,
  loadCommentBodies,
  loadDescription,
  onRecord = () => {},
}) {
  const counts = { CLOSE: 0, RESCOPE: 0, 'STALE-PREMISE': 0, LEAVE: 0 };
  const records = [];
  const acted = [];
  let failed = 0;
  let closed = 0;

  for (const ticket of backlog) {
    if (only && !only.has(ticket.key)) continue;

    const { subjectCommits, bodyOnlyCommits } = findMatches(commits, ticket.key);

    // Fetch comments only when there is evidence to act on — the tool's own
    // marker can only ever exist on a ticket it previously found evidence
    // for, so a zero-evidence ticket cannot carry it. Keeps the real run
    // bounded to the candidate set instead of a comment-fetch per all ~989
    // open tickets.
    const hasEvidence = subjectCommits.length > 0 || bodyOnlyCommits.length > 0;
    const commentBodies = hasEvidence ? await loadCommentBodies(ticket.key) : [];
    const description = hasEvidence ? await loadDescription(ticket.key) : '';

    const result = classifyTicket({
      key: ticket.key,
      issueType: ticket.issueType,
      status: ticket.status,
      targetStatus,
      commentBodies,
      hygieneKeys,
      subjectCommits,
      bodyOnlyCommits,
      description,
    });

    counts[result.disposition] = (counts[result.disposition] ?? 0) + 1;

    const record = {
      key: ticket.key,
      issueType: ticket.issueType,
      status: ticket.status,
      disposition: result.disposition,
      reason: result.reason,
      evidence: result.evidence ? { sha: result.evidence.sha, date: result.evidence.date, subject: result.evidence.subject } : null,
    };

    if (result.disposition !== 'LEAVE') {
      acted.push(record);
      if (apply) {
        if (result.disposition === 'CLOSE' && closed >= maxClose) {
          record.applied = 'skipped-max-close';
          process.stderr.write(
            `reconcile-backlog: ${ticket.key} CLOSE skipped — --max-close ${maxClose} already reached\n`,
          );
        } else {
          const commentBody = buildEvidenceComment({ key: ticket.key, ...result });
          try {
            const applied = await applyDisposition({
              key: ticket.key,
              disposition: result.disposition,
              targetStatus,
              commentBody,
              jiraClient,
            });
            record.applied = applied.action;
            if (result.disposition === 'CLOSE' && applied.action === 'commented+transitioned') closed += 1;
          } catch (err) {
            // One ticket's comment/transition failure (a missing
            // transition-screen field, a permissions gap, ...) must not abort
            // the whole backlog run — every other candidate still needs its
            // own disposition recorded.
            record.applied = 'failed';
            failed += 1;
            process.stderr.write(`reconcile-backlog: ${ticket.key} apply failed: ${err.message}\n`);
          }
        }
      }
    }

    records.push(record);
    onRecord(record);
  }

  return { records, counts, acted, failed, closed };
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  // A LEFT ALONE hygiene-sweep row carries no Jira comment at all, so
  // hasSkipMarker cannot protect it — --hygiene-doc is the ONLY guard for
  // those tickets. Silently running --apply without it would let a real
  // write run re-disposition tickets a concurrent sweep already adjudicated.
  if (opts.apply && !opts.hygieneDoc) {
    process.stderr.write(
      'reconcile-backlog: --apply requires --hygiene-doc (protects LEFT ALONE tickets the ' +
        'hygiene sweep already adjudicated but never commented on); pass it explicitly, or ' +
        '--hygiene-doc /dev/null if none applies.\n',
    );
    process.exit(1);
  }
  // HIMMEL-3128: --apply requires an explicit --max-close N so a run can
  // never close more than N tickets without that being a deliberate choice
  // (defence in depth on top of the evidence-rule fix — the only writing
  // disposition on the backlog is CLOSE). No default N: an unset cap would
  // just be a large default someone forgets is there.
  if (opts.apply && (!Number.isInteger(opts.maxClose) || opts.maxClose < 0)) {
    process.stderr.write(
      'reconcile-backlog: --apply requires --max-close N (a non-negative integer safety valve on ' +
        'how many tickets this run may CLOSE); pass a large N to intentionally allow many closes.\n',
    );
    process.exit(1);
  }
  // --max-close only caps CLOSE; RESCOPE (a comment, not a transition) is
  // uncapped and would otherwise apply to every non-LEAVE ticket in the
  // backlog on an --only-less run. Require an explicit, non-empty --only so
  // apply mode never touches a ticket the operator did not name.
  if (opts.apply && (!opts.only || opts.only.size === 0)) {
    process.stderr.write(
      'reconcile-backlog: --apply requires a non-empty --only <key-list> (no writes to a ticket ' +
        'the operator did not explicitly select).\n',
    );
    process.exit(1);
  }
  const config = loadConfig(opts.config);
  const projectConfig = config[opts.project];
  const targetStatus = projectConfig?.targetStatus;

  const hygieneKeys = loadHygieneKeys(opts.hygieneDoc);
  const commits = loadCommits(opts.commitsFile);
  const backlog = await loadBacklog({ jiraCli: opts.jiraCli, project: opts.project, limit: opts.limit });

  const jiraClient = makeJiraClient(opts.jiraCli);

  const { counts, acted, failed, closed } = await runReconciliation({
    backlog,
    commits,
    hygieneKeys,
    targetStatus,
    only: opts.only,
    apply: opts.apply,
    maxClose: opts.maxClose,
    jiraClient,
    loadCommentBodies: (key) => loadCommentBodies({ jiraCli: opts.jiraCli, key }),
    loadDescription: (key) => loadDescription({ jiraCli: opts.jiraCli, key }),
    onRecord: (record) => console.log(JSON.stringify(record)),
  });

  console.log(
    JSON.stringify({
      summary: true,
      mode: opts.apply ? 'apply' : 'dry-run',
      total: backlog.length,
      counts,
      acted: acted.length,
      failed,
      closed,
      maxClose: opts.maxClose,
    }),
  );

  // A run where every apply attempt failed must not report success —
  // automation watching only the exit code needs a non-zero signal here.
  if (failed > 0) process.exitCode = 1;
}

// Guarded so vitest can import the pure helpers above (parseArgs, loadConfig,
// loadHygieneKeys, loadCommits) without triggering a live Jira run.
// pathToFileURL (not a manually-built `file://` string) so this comparison
// also holds on Windows and on paths with URL-reserved characters.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    process.stderr.write(`reconcile-backlog: ${err.stack ?? err.message}\n`);
    process.exit(1);
  });
}
