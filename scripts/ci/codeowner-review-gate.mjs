#!/usr/bin/env node
// scripts/ci/codeowner-review-gate.mjs — decision logic for the required
// `codeowner-review-gate` status check (HIMMEL-3372).
//
// Intent: code-owner review is mandatory for OUTSIDE pull requests only. The
// repository owner's own PRs (every console leg PR) keep merging through
// merge-on-green.sh. A ruleset cannot scope a review rule by author, so this is
// a status check instead. It PASSES when
//   (a) the PR author has write/maintain/admin permission on the repo, and is
//       not a bot (Dependabot and every other bot count as outside), or
//   (b) every code owner CODEOWNERS assigns to the changed paths has a LATEST
//       (APPROVED / CHANGES_REQUESTED / DISMISSED) review that is APPROVED and
//       was submitted on the current head sha.
// Otherwise it FAILS naming who must review. Nothing here can be talked into a
// pass: every unreadable input, unverifiable owner or empty owner set FAILS.
//
// Exit: 0 PASS, 1 policy FAIL, 2 ERROR (bad usage / unreadable input / API
// failure). Both non-zero fail the job. Stdout's first line is always
// `codeowner-review-gate: PASS|FAIL|ERROR — <reason>`.
//
// Two input modes:
//   fixtures  --pr-file F --permission-file F --reviews-file F --files-file F
//             --codeowners-file F                     (offline; the test suite)
//   live      --repo owner/name --pr-number N --base-sha SHA
//             (`gh api`; CODEOWNERS is read at the BASE sha, never the PR head,
//              because an outside PR must not be able to rewrite its own owners)
//
// This file runs from the BASE ref (the workflow fetches it from the base sha),
// so a PR cannot edit its own gate. It never executes anything from the PR.

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const WRITE_PERMISSIONS = new Set(['admin', 'write']);
const WRITE_ROLES = new Set(['admin', 'maintain', 'write']);
// Review states that can be a reviewer's "latest word". COMMENTED and PENDING do
// not supersede an approval (GitHub's own semantics: a comment does not retract
// one), so they are skipped when picking the latest review.
const DECIDING_STATES = new Set(['APPROVED', 'CHANGES_REQUESTED', 'DISMISSED']);

class GateError extends Error {}

// ---------------------------------------------------------------- CODEOWNERS

function regexEscape(ch) {
  return /[.+^${}()|[\]\\]/.test(ch) ? `\\${ch}` : ch;
}

// gitignore-style glob -> regex source for the body of a CODEOWNERS pattern.
function globBody(p) {
  let out = '';
  for (let i = 0; i < p.length; i++) {
    const c = p[i];
    if (c === '\\' && i + 1 < p.length) {
      out += regexEscape(p[++i]);
    } else if (c === '*' && p[i + 1] === '*') {
      if (p[i + 2] === '/') { out += '(?:.*/)?'; i += 2; }
      else { out += '.*'; i += 1; }
    } else if (c === '*') {
      out += '[^/]*';
    } else if (c === '?') {
      out += '[^/]';
    } else {
      out += regexEscape(c);
    }
  }
  return out;
}

// One CODEOWNERS pattern -> RegExp over a repo-relative path (no leading slash).
//   /x or a/b   anchored to the root; bare `x` matches at any depth
//   dir/        the directory and everything below it
//   no wildcard in the last segment -> also matches everything below it
//   docs/*      direct children only (GitHub's CODEOWNERS is not gitignore here)
// The `s` flag makes `.` match a newline: a newline is an ordinary filename
// character, and without it a directory rule's `.*` would stop at one and let the
// path fall through to an earlier (global) rule's owner.
export function patternToRegExp(raw) {
  let p = raw;
  const dirOnly = p.endsWith('/');
  if (dirOnly) p = p.slice(0, -1);
  const anchored = p.startsWith('/') || p.includes('/');
  if (p.startsWith('/')) p = p.slice(1);
  const lastSegment = p.slice(p.lastIndexOf('/') + 1);
  const wildLast = /[*?]/.test(lastSegment);
  const prefix = anchored ? '^' : '^(?:.*/)?';
  const suffix = dirOnly ? '/.*' : (wildLast ? '' : '(?:/.*)?');
  return new RegExp(`${prefix}${globBody(p)}${suffix}$`, 's');
}

// CODEOWNERS text -> [{ re, owners }] in file order (last match wins).
export function parseCodeowners(text) {
  const rules = [];
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed === '' || trimmed.startsWith('#')) continue;
    const tokens = trimmed.split(/\s+/);
    const owners = [];
    for (const t of tokens.slice(1)) {
      if (t.startsWith('#')) break; // inline comment
      owners.push(t);
    }
    rules.push({ re: patternToRegExp(tokens[0]), owners });
  }
  return rules;
}

function ownersFor(rules, path) {
  let owners = [];
  for (const r of rules) if (r.re.test(path)) owners = r.owners;
  return owners;
}

// ---------------------------------------------------------------- decision

const verdict = (result, reason) => ({ result, reason });

// evaluate({ author, authorType, authorPermission, headSha, reviews, codeowners, files })
//   authorPermission: the collaborator-permission API body ({permission, role_name}) or null
export function evaluate(input) {
  const { author, authorType, authorPermission, headSha, reviews, codeowners, files } = input;

  const isBot = authorType === 'Bot' || /\[bot\]$/i.test(author || '');
  const perm = authorPermission || {};
  const trusted = !isBot &&
    (WRITE_PERMISSIONS.has(perm.permission) || WRITE_ROLES.has(perm.role_name));
  if (trusted) {
    return verdict('PASS', `${author} has ${perm.role_name || perm.permission} permission — not an outside PR`);
  }

  if (!headSha) throw new GateError('no head sha for the PR');
  const rules = parseCodeowners(codeowners);
  const required = new Map(); // lowercased owner -> display form
  if (files.length === 0) {
    return verdict('FAIL', 'the PR lists no changed files — refusing to pass an outside PR unreviewed');
  }
  for (const f of files) {
    for (const o of ownersFor(rules, f)) required.set(o.toLowerCase(), o);
  }
  if (required.size === 0) {
    return verdict('FAIL', 'no code owner covers the changed paths — refusing to pass an outside PR unreviewed');
  }

  // Latest deciding review per reviewer, in submission order.
  const ordered = reviews
    .map((r, i) => ({ r, i }))
    .filter(({ r }) => r && r.user && DECIDING_STATES.has(r.state))
    .sort((a, b) => String(a.r.submitted_at || '').localeCompare(String(b.r.submitted_at || '')) || a.i - b.i);
  const latest = new Map();
  for (const { r } of ordered) latest.set(r.user.login.toLowerCase(), r);

  const missing = [];
  for (const [key, display] of required) {
    if (!display.startsWith('@') || display.includes('/')) {
      missing.push(`${display} (team or email owner — cannot be verified here)`);
      continue;
    }
    const r = latest.get(key.slice(1));
    if (!r) missing.push(`${display} (no review)`);
    else if (r.state !== 'APPROVED') missing.push(`${display} (latest review is ${r.state})`);
    else if (r.commit_id !== headSha) missing.push(`${display} (approved an older commit, not the current head)`);
  }
  if (missing.length > 0) {
    return verdict('FAIL', `${author} is an outside contributor; code-owner approval at the current head is required from: ${missing.join('; ')}`);
  }
  return verdict('PASS', `every required code owner (${[...required.values()].join(', ')}) approved the current head`);
}

// ---------------------------------------------------------------- input

function readText(path) {
  try {
    return readFileSync(path, 'utf8');
  } catch (e) {
    throw new GateError(`cannot read ${path}: ${e.code || e.message}`);
  }
}

// A JSON array, or NDJSON (`gh api --paginate --jq '.[]'`), or blank.
function parseJsonList(text, what) {
  const t = text.trim();
  if (t === '') return [];
  try {
    const v = JSON.parse(t);
    return Array.isArray(v) ? v : [v];
  } catch {
    try {
      return t.split(/\r?\n/).filter((l) => l.trim() !== '').map((l) => JSON.parse(l));
    } catch {
      throw new GateError(`${what} is neither a JSON array nor NDJSON`);
    }
  }
}

function parseJson(text, what) {
  try {
    return JSON.parse(text);
  } catch {
    throw new GateError(`${what} is not valid JSON`);
  }
}

// A JSON array of paths, or one path per line.
function parseFiles(text) {
  const t = text.trim();
  if (t.startsWith('[')) return parseJson(t, 'files').map(String);
  return t.split(/\r?\n/).map((l) => l.trim()).filter((l) => l !== '');
}

const MAX_LISTED_FILES = 3000;

// One JSON string per line (jq `@json`): paths kept byte-exact.
function parseJsonStrings(text, what) {
  return text.split('\n').filter((l) => l !== '').map((l) => {
    const v = parseJson(l, what);
    if (typeof v !== 'string') throw new GateError(`${what} entry is not a string`);
    return v;
  });
}

// `gh api` via execFile: no shell, so no value here can be interpreted as one.
function gh(args) {
  try {
    return execFileSync('gh', ['api', ...args], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 64 * 1024 * 1024,
    });
  } catch (e) {
    const stderr = String(e.stderr || e.message || '');
    const err = new GateError(`gh api ${args.filter((a) => !a.startsWith('-')).join(' ')} failed: ${stderr.trim().split('\n')[0]}`);
    err.notFound = /HTTP 404/.test(stderr);
    throw err;
  }
}

function loadLive({ repo, pr, base }) {
  if (!/^[\w.-]+\/[\w.-]+$/.test(repo)) throw new GateError(`bad --repo: ${repo}`);
  if (!/^\d+$/.test(pr)) throw new GateError(`bad --pr-number: ${pr}`);
  if (!/^[0-9a-f]{7,64}$/i.test(base)) throw new GateError(`bad --base-sha: ${base}`);

  const prData = parseJson(gh([`repos/${repo}/pulls/${pr}`]), 'pull request');
  const author = prData.user.login;
  const authorType = prData.user.type;
  const out = { author, authorType, headSha: prData.head.sha, authorPermission: null,
    reviews: [], files: [], codeowners: '' };

  // A bot is outside regardless of any permission it holds: skip the lookup.
  if (authorType !== 'Bot' && !/\[bot\]$/i.test(author)) {
    try {
      out.authorPermission = parseJson(gh([`repos/${repo}/collaborators/${encodeURIComponent(author)}/permission`]), 'permission');
    } catch (e) {
      if (!e.notFound) throw e; // 404 = not a collaborator = outside; anything else fails closed
    }
    if (out.authorPermission &&
        (WRITE_PERMISSIONS.has(out.authorPermission.permission) || WRITE_ROLES.has(out.authorPermission.role_name))) {
      return out; // permitted author: nothing further is read
    }
  }

  out.reviews = parseJsonList(gh(['--paginate', `repos/${repo}/pulls/${pr}/reviews?per_page=100`, '--jq', '.[]']), 'reviews');
  // The pulls/files API stops at 3000 files, so at or beyond that the list is
  // incomplete and an owner of an omitted path could be skipped: fail closed.
  if (Number(prData.changed_files) >= MAX_LISTED_FILES) {
    throw new GateError(`PR changes ${prData.changed_files} files, at or over the ${MAX_LISTED_FILES}-file API listing cap; the changed-file list would be incomplete`);
  }
  // Each path travels as a JSON string (@json), so newlines and edge whitespace
  // in a filename reach CODEOWNERS matching exactly as git recorded them.
  out.files = parseJsonStrings(gh(['--paginate', `repos/${repo}/pulls/${pr}/files?per_page=100`,
    '--jq', '.[] | (.filename, (.previous_filename // empty)) | @json']), 'files');
  out.codeowners = gh(['-H', 'Accept: application/vnd.github.raw',
    `repos/${repo}/contents/.github/CODEOWNERS?ref=${base}`]);
  return out;
}

function loadFixtures(a) {
  const pr = parseJson(readText(a['pr-file']), 'pr-file');
  const permText = readText(a['permission-file']).trim();
  return {
    author: pr.user.login,
    authorType: pr.user.type,
    headSha: pr.head.sha,
    authorPermission: permText === '' ? null : parseJson(permText, 'permission-file'),
    reviews: parseJsonList(readText(a['reviews-file']), 'reviews-file'),
    files: parseFiles(readText(a['files-file'])),
    codeowners: readText(a['codeowners-file']),
  };
}

function parseArgs(argv) {
  const a = {};
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (!k.startsWith('--') || i + 1 >= argv.length) throw new GateError(`bad argument: ${k}`);
    a[k.slice(2)] = argv[++i];
  }
  return a;
}

// Workflow-command injection guard: a value echoed on a `::error` line must not
// be able to start a new command or smuggle newlines.
const annotationSafe = (s) => String(s).replace(/[\r\n%]/g, ' ');

function main(argv) {
  const a = parseArgs(argv);
  let input;
  if (a.repo || a['pr-number'] || a['base-sha']) {
    if (!(a.repo && a['pr-number'] && a['base-sha'])) throw new GateError('live mode needs --repo, --pr-number and --base-sha');
    input = loadLive({ repo: a.repo, pr: a['pr-number'], base: a['base-sha'] });
  } else if (['pr-file', 'permission-file', 'reviews-file', 'files-file', 'codeowners-file'].every((k) => a[k])) {
    input = loadFixtures(a);
  } else {
    throw new GateError('usage: --repo R --pr-number N --base-sha S | --pr-file F --permission-file F --reviews-file F --files-file F --codeowners-file F');
  }
  return evaluate(input);
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) {
  let v;
  try {
    v = main(process.argv.slice(2));
  } catch (e) {
    if (!(e instanceof GateError)) throw e;
    console.log(`codeowner-review-gate: ERROR — ${e.message}`);
    console.log(`::error title=codeowner-review-gate::${annotationSafe(e.message)}`);
    process.exit(2);
  }
  console.log(`codeowner-review-gate: ${v.result} — ${v.reason}`);
  if (v.result === 'FAIL') console.log(`::error title=codeowner-review-gate::${annotationSafe(v.reason)}`);
  process.exit(v.result === 'PASS' ? 0 : 1);
}
