#!/usr/bin/env node
// cloud-liveness.mjs — HIMMEL-5163. Is each claude.ai cloud session still alive?
//
// A cloud session cannot message the console, so nothing told it that HIMMEL-5077's
// session stopped after one commit or that HIMMEL-4686's never produced a branch
// (both found only because the operator asked). This reads the bucket's
// cloud-sessions.tsv (launch time, ticket, session; written when the console
// launches a session) against the forge and says, per session:
//
//   no-branch      no branch and no PR for the ticket, N min after launch
//   pr-silent      an open PR, no CLOUD-DONE/CLOUD-BLOCKED comment, no commit for M min
//   unshepherded   CLOUD-DONE/CLOUD-BLOCKED posted, no live leg doc names the PR
//   ok states      working / done-pending / shepherded / branch / merged / closed / pending
//
// One tick field (tick.sh cloud=) and one board panel (board.mjs) read it.
//
//   node cloud-liveness.mjs --bucket <dir> [--repo <dir>] [--json]
//   -> `ok` | `STALL:<ticket>[,<ticket>...]` | `skip` (no tsv, or the forge unreadable)
//
// Forge cost: ONE `gh pr list --state all` (a single GraphQL query inside the tick's
// existing gql budget) plus one `git ls-remote --heads`, and none at all when no
// session is inside the window. Both are bounded by a timeout; a failure reads `skip`,
// never a failed tick.
// ponytail: a branch is attributed to a ticket by name (himmel-<n>), so a cloud branch
// named for neither the ticket nor a PR citing it reads no-branch; a session whose
// branch exists but never opened a PR reads `branch`, not a stall. Tighten with the
// session id once cloud branches carry it.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const MIN = 60e3;
const num = (v, d) => { const n = Number(v); return Number.isFinite(n) && n > 0 ? n : d; };
export const defaults = (env = process.env) => ({
  branchMin: num(env.CLOUD_LIVENESS_BRANCH_MIN, 30),
  prMin: num(env.CLOUD_LIVENESS_PR_MIN, 60),
  doneMin: num(env.CLOUD_LIVENESS_DONE_MIN, 15),
  windowH: num(env.CLOUD_LIVENESS_WINDOW_H, 48),
});

// TSV rows: `<local ISO time>\t<ticket>\t<session id>\t<launch line>`. The latest row per
// ticket wins (a relaunch supersedes), and only rows inside the window are live.
export function parseSessions(text) {
  const byTicket = new Map();
  for (const line of text.split('\n')) {
    const [time, ticket, session] = line.split('\t');
    const at = Date.parse(time ?? '');
    if (!/^[A-Z][A-Z0-9]*-\d+$/.test(ticket ?? '') || Number.isNaN(at)) continue;
    byTicket.set(ticket, { ticket, session: session ?? '', launched: at });
  }
  return [...byTicket.values()];
}

const keyRe = (key) => new RegExp(`(?<![\\w-])${key}(?!\\d)`);
const slugOf = (key) => key.toLowerCase();
const DONE = /^\s*CLOUD-(DONE|BLOCKED)\b/;

// Which PRs are this session's: the brief's `cloud-pilot: <KEY>` body line, a CLOUD-DONE /
// CLOUD-BLOCKED comment carrying the session id, or a claude/ branch named for the ticket.
function attributed(pr, s) {
  const body = pr.body ?? '';
  if (new RegExp(`cloud-pilot:\\s*${s.ticket}(?!\\d)`).test(body)) return true;
  if ((pr.comments ?? []).some((c) => DONE.test(c.body ?? '') && s.session && (c.body ?? '').includes(s.session))) return true;
  return /^claude\//.test(pr.headRefName ?? '') && new RegExp(`${slugOf(s.ticket)}(?!\\d)`, 'i').test(pr.headRefName);
}

// evaluate({sessions, prs, heads, legDocs, now, cfg}) -> [{ticket, session, launched, state, stall, pr?, detail}]
// prs = gh pr list rows; heads = branch names (null when unreadable); legDocs = [{wrapped, text}].
export function evaluate({ sessions, prs, heads, legDocs = [], now, cfg = defaults() }) {
  const out = [];
  for (const s of sessions) {
    const age = (now - s.launched) / MIN;
    const row = (state, stall, extra = {}) => out.push({ ticket: s.ticket, session: s.session, launched: s.launched, state, stall, ...extra });
    if (age > cfg.windowH * 60) continue;
    const mine = prs.filter((p) => attributed(p, s));
    const merged = mine.find((p) => p.state === 'MERGED' || p.mergedAt);
    if (merged) { row('merged', false, { pr: merged.number }); continue; }
    const open = mine.filter((p) => p.state === 'OPEN').sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt))[0];
    if (!open) {
      const closed = mine.find((p) => p.state === 'CLOSED');
      if (closed) { row('closed', false, { pr: closed.number }); continue; }
      const hasBranch = (heads ?? []).some((h) => new RegExp(`${slugOf(s.ticket)}(?!\\d)`, 'i').test(h));
      if (hasBranch) row('branch', false, { detail: 'a branch exists, no PR yet' });
      else if (heads === null) row('pending', false, { detail: 'branches unreadable' });
      else if (age >= cfg.branchMin) row('no-branch', true, { detail: `no branch or PR ${Math.round(age)} min after launch` });
      else row('pending', false, { detail: `launched ${Math.round(age)} min ago` });
      continue;
    }
    const done = (open.comments ?? []).filter((c) => DONE.test(c.body ?? '')).map((c) => Date.parse(c.createdAt)).filter((t) => !Number.isNaN(t)).sort((a, b) => b - a)[0];
    if (done !== undefined) {
      const named = legDocs.some((d) => !d.wrapped && new RegExp(`(?:#|PR\\s*#?|pull/)${open.number}(?!\\d)`, 'i').test(d.text));
      if (named) row('shepherded', false, { pr: open.number });
      else if ((now - done) / MIN >= cfg.doneMin) row('unshepherded', true, { pr: open.number, detail: `CLOUD-DONE ${Math.round((now - done) / MIN)} min ago, no live leg doc names PR ${open.number}` });
      else row('done-pending', false, { pr: open.number });
      continue;
    }
    const commits = (open.commits ?? []).map((c) => Date.parse(c.committedDate)).filter((t) => !Number.isNaN(t));
    const last = Math.max(Date.parse(open.createdAt) || 0, ...commits);
    const quiet = (now - last) / MIN;
    if (quiet >= cfg.prMin) row('pr-silent', true, { pr: open.number, detail: `PR ${open.number} open, no CLOUD-DONE, no commit for ${Math.round(quiet)} min` });
    else row('working', false, { pr: open.number });
  }
  return out;
}

export const summarize = (states) => {
  const stalled = [...new Set(states.filter((r) => r.stall).map((r) => r.ticket))];
  return stalled.length ? `STALL:${stalled.join(',')}` : 'ok';
};

// ---- I/O ----
// Live leg docs: the bucket's `<TICKET>-...md` files touched inside the window whose last
// `- ` bullet is not WRAPPED (the same "last bullet decides" rule the tick's tails= uses).
function readLegDocs(bucket, sinceMs) {
  const out = [];
  for (const name of readdirSync(bucket)) {
    if (!/^[A-Z][A-Z0-9]*-\d+-.+\.md$/.test(name)) continue;
    const file = join(bucket, name);
    try {
      if (statSync(file).mtimeMs < sinceMs) continue;
      const text = readFileSync(file, 'utf8');
      const last = text.split('\n').filter((l) => l.startsWith('- ')).pop() ?? '';
      out.push({ wrapped: /^-\s+(?:\d{2}:\d{2}\s+)?WRAPPED\b/.test(last), text });
    } catch { /* unreadable doc: not evidence of a live leg */ }
  }
  return out;
}

export function collect({ bucket, repo, env = process.env, now = Date.now() }) {
  const tsv = join(bucket, 'cloud-sessions.tsv');
  if (!existsSync(tsv)) return { skip: true };
  const cfg = defaults(env);
  const sessions = parseSessions(readFileSync(tsv, 'utf8')).filter((s) => now - s.launched <= cfg.windowH * 3600e3);
  if (!sessions.length) return { states: [], cfg };
  let prs;
  try {
    prs = JSON.parse(execFileSync(env.CLOUD_LIVENESS_GH_CMD || 'gh', ['pr', 'list', '--state', 'all', '--limit', '100', '--json', 'number,title,body,state,headRefName,createdAt,mergedAt,closedAt,comments,commits'], { cwd: repo, encoding: 'utf8', timeout: 40000, stdio: ['ignore', 'pipe', 'ignore'] }));
    if (!Array.isArray(prs)) return { skip: true };
  } catch { return { skip: true }; }
  let heads = null;
  try {
    heads = execFileSync(env.CLOUD_LIVENESS_GIT_CMD || 'git', ['-C', repo, 'ls-remote', '--heads', 'origin'], { encoding: 'utf8', timeout: 20000, stdio: ['ignore', 'pipe', 'ignore'] })
      .split('\n').map((l) => l.split('\trefs/heads/')[1]).filter(Boolean);
  } catch { /* unreadable: a missing branch is then unknown, not a stall */ }
  return { states: evaluate({ sessions, prs, heads, legDocs: readLegDocs(bucket, now - cfg.windowH * 3600e3), now, cfg }), cfg };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const a = process.argv.slice(2);
  const val = (f) => { const i = a.indexOf(f); return i >= 0 ? a[i + 1] : undefined; };
  const bucket = val('--bucket');
  if (!bucket) { process.stderr.write('usage: cloud-liveness.mjs --bucket <dir> [--repo <dir>] [--json]\n'); process.exit(2); }
  const now = process.env.CLOUD_LIVENESS_NOW ? Date.parse(process.env.CLOUD_LIVENESS_NOW) : Date.now();
  const r = collect({ bucket: resolve(bucket), repo: resolve(val('--repo') || '.'), now });
  if (a.includes('--json')) process.stdout.write(`${JSON.stringify(r.skip ? { skip: true } : { states: r.states })}\n`);
  else process.stdout.write(`${r.skip ? 'skip' : summarize(r.states)}\n`);
}
