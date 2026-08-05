#!/usr/bin/env node
// shadow-ledger.mjs — HIMMEL-1529 R0: blind decision recording, zero behaviour change.
//
// WHAT THIS IS
// An append-only, hash-chained decision record written from Claude Code hooks.
// For every approval-shaped decision point it records the request (class,
// target, requester lane, lane-config hash) and this harness's OWN blind
// verdict, then DEFERS — it emits no permissionDecision, so nothing about the
// prompt flow moves. Removing it changes no behaviour; adding it changes no
// behaviour. It only records.
//
// WHY "BLIND" IS THE WHOLE POINT
// The shadow verdict is computed, hash-chained and flushed to disk BEFORE this
// process exits and the request continues to the permission layer. Ordering is
// mechanical, not conventional. If the operator could see the harness's guess
// while deciding, any agreement rate would measure anchoring rather than
// competence — and the evidence would be worthless in a way that is invisible
// when it is worthless. Do not "optimise" the write to happen after the
// decision, and do not surface shadow_verdict in any operator-facing string.
//
// WHAT THE SHADOW VERDICT IS — AND IS NOT (read before trusting a number)
// It is a small, deterministic rule engine (see shadowVerdict below). It is NOT
// a model judgement — a hook cannot call a model, and must not try. It answers
// a narrow question: "is this request provably safe / provably refused under
// the harness's own current rules, or is it contested?" Contested requests get
// `abstain`, and abstain is the honest answer for exactly the cases a trust
// ladder would have to adjudicate.
//
// Consequence, stated plainly so nobody over-reads the output: the PRIMARY
// product of this ledger is the INTERRUPT COUNT — approval-interrupts per week,
// the number HIMMEL-1529 exists to produce and which nobody currently knows.
// Agreement rate between shadow and actual is a SECONDARY output and is
// dominated by the abstain class; `report` prints it with that caveat attached.
//
// WHO SIGNS
// The hook process, on behalf of the dispatch identity — never the agent. A
// model cannot hold a key: its context is readable and exfiltratable. In R0
// "signing" is the hash chain only; keyed signatures and chain-verification
// tooling are deliberately deferred (the threat model here is model drift and
// confusion, not an adversary with filesystem access).
//
// FAIL-OPEN, ALWAYS
// This hook must never block, deny, delay or ASK. A hook that returns `ask`
// reintroduces the permission dialog that `defaultMode: auto` exists to remove,
// and in an armed session that dialog is unanswerable and unbounded (measured:
// 902.5s, still blocked when killed). Every failure path here exits 0 with
// empty stdout. There is no code path in this file that prints a
// permissionDecision.
//
// PRIVACY
// Commands and file contents are NOT stored. `target` keeps a coarse handle
// (verb + subverb, or a repo-relative path) and `target_hash` a sha256 of the
// full request, so identical requests correlate without the ledger becoming a
// transcript lake. Records point at sessions; they do not embed them.
//
// USAGE (hooks wire these; see scripts/trust/README.md)
//   node shadow-ledger.mjs pre      < PreToolUse payload
//   node shadow-ledger.mjs post     < PostToolUse payload
//   node shadow-ledger.mjs postfail < PostToolUseFailure payload
//   node shadow-ledger.mjs denied   < PermissionDenied payload
//   node shadow-ledger.mjs permreq  < PermissionRequest payload
//   node shadow-ledger.mjs notify   < Notification payload
//   node shadow-ledger.mjs heartbeat < SessionStart payload
//   node shadow-ledger.mjs report [--days N] [--json]

import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const GENESIS = '0'.repeat(64);
const LOCK_TRIES = 40;
const LOCK_WAIT_MS = 5;
// Below this, `report` shows the raw count and refuses to state a weekly rate.
const MIN_EXTRAPOLATION_DAYS = 1;
// The longest stretch of the reporting window that may pass with NO collector
// heartbeat before the weekly rate is withheld (HIMMEL-1547).
//
// This constant is a stated choice, not a derived truth, so it is named after
// the thing it is tied to rather than picked round: the published figure is a
// rate PER WEEK, and a per-week rate must not be computed over a window in
// which the collector went a full week unproven. Anything shorter starts
// refusing on ordinary operator idleness; anything longer lets a stopped
// recorder hide for more than one unit of the very quantity being reported.
// Revisit it with evidence about real session cadence, not by feel.
const HEARTBEAT_MAX_GAP_DAYS = 7;
// The absolute cap above is not sufficient by itself (HIMMEL-1547 CR round):
// it lets ONE heartbeat anywhere within the allowance certify an ENTIRELY
// unobserved window shorter than the allowance — a heartbeat on day 7 of a
// 7-day window satisfies `maxGapDays <= HEARTBEAT_MAX_GAP_DAYS` while the
// whole week behind it went unrecorded, and the 1-to-7-day range is exactly
// where this instrument lives during its first week of operation.
//
// So the allowance is also bounded RELATIVE to the window's own length: no
// more than half of a reporting window may go unaccounted for, because a rule
// that lets the MAJORITY of the window go unproven cannot tell a collecting
// window apart from a stopped one.
//
// Residual, stated honestly rather than claimed away: even sitting exactly at
// this limit, a rate can still be understated by up to 2x — the unproven half
// could hide events the proven half does not. `collection.proven` therefore
// means "not obviously stopped", NOT "fully covered", and the README states
// the same caveat on the operator-facing surface.
const MAX_UNPROVEN_WINDOW_FRACTION = 0.5;
// Every hook event this recorder relies on, paired with the verb it feeds and
// the matcher it must carry — the ONE definition wire-trust-hooks.mjs installs
// from, so the two can never disagree on what "wired" means (HIMMEL-1547: a
// settings file with all seven canonical-looking commands parked under
// SessionStart used to read as a complete inventory, because wiredVerbs below
// never checked WHICH event a verb was attached to).
const TOOL_MATCHER = 'Bash|Edit|Write|MultiEdit|NotebookEdit';
export const EXPECTED_HOOKS = Object.freeze([
  { event: 'PreToolUse', verb: 'pre', matcher: TOOL_MATCHER },
  { event: 'PostToolUse', verb: 'post', matcher: TOOL_MATCHER },
  { event: 'PostToolUseFailure', verb: 'postfail', matcher: TOOL_MATCHER },
  { event: 'PermissionDenied', verb: 'denied', matcher: TOOL_MATCHER },
  { event: 'PermissionRequest', verb: 'permreq', matcher: null },
  { event: 'Notification', verb: 'notify', matcher: null },
  { event: 'SessionStart', verb: 'heartbeat', matcher: null },
]);
// The hook verbs whose rows the report depends on. The heartbeat carries the
// subset actually WIRED at session start, and `report` refuses the rate when
// any of these was missing — because five live hooks are enough to grow a
// healthy-looking observation window while the sixth, the only producer of
// approval-interrupt rows, records nothing. Derived from EXPECTED_HOOKS so the
// two vocabularies cannot drift apart.
export const EXPECTED_VERBS = Object.freeze(EXPECTED_HOOKS.map((h) => h.verb));
// A lock older than this cannot be held by a live writer (the critical section
// is sub-millisecond) — see breakStaleLock.
const STALE_LOCK_MS = 5000;
// Initial tail-read window for lastRecord; grows until a record parses.
const TAIL_WINDOW_BYTES = 16384;

// --- locations ---------------------------------------------------------------

export function ledgerDir() {
  const override = process.env.HIMMEL_TRUST_LEDGER_DIR;
  if (override && override.trim()) return override.trim();
  return path.join(os.homedir(), '.claude', 'himmel', 'trust');
}

export function ledgerPath() {
  return path.join(ledgerDir(), 'ledger.jsonl');
}

// Recorder health, kept in a SEPARATE file from the ledger on purpose. The
// events it records are the ones the ledger could not record, so anything that
// shares the ledger's lock or its hash chain would be silent in exactly the
// case it exists to report.
export function healthPath() {
  return path.join(ledgerDir(), 'drops.jsonl');
}

// --- hashing -----------------------------------------------------------------

const sha256 = (s) => createHash('sha256').update(s, 'utf8').digest('hex');

// Canonical form: keys sorted, `hash` excluded. Two records with the same
// content always hash the same regardless of insertion order.
export function canonical(record) {
  const out = {};
  for (const k of Object.keys(record).sort()) {
    if (k === 'hash') continue;
    out[k] = record[k];
  }
  return JSON.stringify(out);
}

export function chainHash(prevHash, record) {
  return sha256(`${prevHash}\n${canonical(record)}`);
}

// --- ledger IO ---------------------------------------------------------------

// Last complete line without reading the whole file. The ledger is expected to
// stay small (one line per decision), but O(file) per tool call is a latency
// bug waiting to happen, so read a tail window instead.
export function lastRecord(file = ledgerPath()) {
  let fd;
  try {
    fd = fs.openSync(file, 'r');
  } catch {
    return null;
  }
  try {
    const size = fs.fstatSync(fd).size;
    if (size === 0) return null;
    // Grow the tail window until a record parses or the whole file is read.
    // A fixed window silently FORKS the chain: if the last record is larger
    // than the window, its head is clipped, it fails to parse, and we fall
    // back to an EARLIER record — so the next append chains to a stale
    // prev_hash and the break is invisible. Correctness cannot depend on
    // records staying small.
    for (let window = Math.min(size, TAIL_WINDOW_BYTES); ; window = Math.min(size, window * 4)) {
      const buf = Buffer.alloc(window);
      fs.readSync(fd, buf, 0, window, size - window);
      const lines = buf.toString('utf8').split('\n').filter((l) => l.trim());
      // Walk backwards: the FIRST line may be clipped, the last is the newest.
      for (let i = lines.length - 1; i >= 0; i--) {
        try {
          return JSON.parse(lines[i]);
        } catch {
          /* keep walking */
        }
      }
      if (window >= size) return null; // whole file read, nothing parses
    }
  } catch {
    return null;
  } finally {
    try {
      fs.closeSync(fd);
    } catch {
      /* ignore */
    }
  }
}

// Exclusive-create lock. Several sessions append concurrently; without this two
// records can claim the same prev_hash and silently fork the chain. Bounded
// retry, then give up and DROP the record — a missing row is recoverable, a
// blocked tool call is not.
function pidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === 'EPERM'; // exists but owned by another user
  }
}

// A lock holder that dies between open and unlink (SIGKILL, a killed hook, a
// crashed session) leaves the file behind forever — and without reclamation
// that is TERMINAL: every later call burns its retries and drops its record,
// so recording stops permanently and silently, which is the worst failure this
// file can have.
//
// Age alone is NOT sufficient evidence of death: a writer that is merely slow,
// SIGSTOPped, or resuming from hibernation would lose exclusivity and the two
// writers would fork the chain — trading a loud wedge for silent corruption,
// which is the worse bargain. So the lock records its owner pid and is broken
// only when the pid is genuinely gone AND the file is older than STALE_LOCK_MS.
//
// The read→unlink gap is a real TOCTOU: another process could reclaim and
// re-create the lock in between, and we would delete ITS lock. Re-reading the
// content immediately before unlinking narrows that to the window where a
// reclaimer writes an identical pid+timestamp, which cannot happen (the pid is
// gone and the stamp is fresh). It is a narrowing, not an atomicity proof —
// stated plainly rather than claimed away.
function breakStaleLock(lock) {
  try {
    const before = fs.readFileSync(lock, 'utf8');
    const [pidStr, tsStr] = before.split(/\s+/);
    const pid = Number(pidStr);
    const stamped = Number(tsStr);
    const age = Date.now() - (Number.isFinite(stamped) ? stamped : fs.statSync(lock).mtimeMs);
    if (age <= STALE_LOCK_MS) return;
    if (Number.isFinite(pid) && pid > 0 && pidAlive(pid)) return; // slow, not dead
    if (fs.readFileSync(lock, 'utf8') !== before) return;         // someone reclaimed it
    fs.unlinkSync(lock);
  } catch {
    /* vanished or unreadable — the next openSync decides */
  }
}

// A write this recorder could not perform. Fail-open stays the contract — the
// caller still gets null and the tool call still proceeds — but the loss stops
// being INVISIBLE. Without this the hash chain still validates (it validates the
// rows that landed, never the rows that never did), so a contention spike or an
// ENOSPC produces an understated rate that looks exactly like a quiet week.
//
// Deliberately reason CODES only, never the exception text: an error message can
// carry a path or a command fragment, and this file does not store those.
export function recordDrop(reason) {
  try {
    fs.mkdirSync(ledgerDir(), { recursive: true });
    fs.appendFileSync(
      healthPath(),
      `${JSON.stringify({ ts: new Date().toISOString(), reason })}\n`,
      'utf8',
    );
  } catch {
    /* nothing further to try; the counter is a floor, and fail-open still holds */
  }
}

// Is somebody mid-append RIGHT NOW? Only a live lock holder can be, and only
// that case makes an unterminated final line innocent — see readLedger.
//
// Every uncertain branch answers NO (no lock, unreadable lock, unparseable
// owner, stale stamp). That direction is deliberate: answering NO turns a torn
// tail into declared damage, which SUPPRESSES the rate. The failure it avoids is
// publishing a confident number over a missing row, and between "refuse to
// publish" and "publish short" a measurement tool must pick the first.
// The lock is derived from the LEDGER FILE's own directory, not from
// ledgerDir(). readLedger accepts an arbitrary path, and asking the default
// directory about some other ledger's writer would answer a question nobody
// asked — innocently exempting a torn tail because an unrelated ledger happened
// to be mid-append.
function liveWriterPresent(file = ledgerPath()) {
  const lock = path.join(path.dirname(file), '.ledger.lock');
  let raw;
  try {
    raw = fs.readFileSync(lock, 'utf8');
  } catch {
    return false; // no lock file at all — nobody is writing
  }
  const [pidStr, tsStr] = raw.split(/\s+/);
  const stamped = Number(tsStr);
  // A stale stamp means the holder is long gone even if the pid got recycled.
  if (!Number.isFinite(stamped) || Date.now() - stamped > STALE_LOCK_MS) return false;
  const pid = Number(pidStr);
  return Number.isFinite(pid) && pid > 0 ? pidAlive(pid) : false;
}

function withLock(fn) {
  const lock = path.join(ledgerDir(), '.ledger.lock');
  for (let i = 0; i < LOCK_TRIES; i++) {
    let fd;
    let token;
    try {
      fd = fs.openSync(lock, 'wx');
      // Stamp ownership so a later reclaimer can prove death rather than infer
      // it from age. Written inside the exclusive create, before any work.
      token = `${process.pid} ${Date.now()}`;
      fs.writeSync(fd, token);
    } catch {
      breakStaleLock(lock);
      // Busy-wait without a timer: hooks are synchronous and this is <200ms
      // worst case. Atomics.wait needs a SharedArrayBuffer view.
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, LOCK_WAIT_MS);
      continue;
    }
    try {
      return fn();
    } catch {
      // The write itself failed (ENOSPC, a transient permission fault, a full
      // inode table). Previously this propagated to the top-level fail-open
      // handler, which swallowed it and exited 0 — correct for the tool call,
      // silent for the measurement. Record the loss, then keep failing open.
      recordDrop('append_failed');
      return null;
    } finally {
      try {
        fs.closeSync(fd);
      } catch {
        /* ignore */
      }
      try {
        // Release ONLY a lock this writer still owns. An unconditional unlink
        // deletes whatever is at the pathname — including a replacement lock a
        // reclaimer took after deciding we were dead, which would put two
        // writers in the critical section and fork the chain.
        if (fs.readFileSync(lock, 'utf8') === token) fs.unlinkSync(lock);
      } catch {
        /* ignore */
      }
    }
  }
  // Retries exhausted under sustained contention. The record is gone; say so.
  recordDrop('lock_exhausted');
  return null;
}

export function append(partial) {
  return withLock(() => {
    const prev = lastRecord();
    const prev_hash = prev && typeof prev.hash === 'string' ? prev.hash : GENESIS;
    const record = { ...partial, prev_hash };
    record.hash = chainHash(prev_hash, record);
    // Heal a torn final line before appending. Without this, a record written
    // after an interrupted append is GLUED onto the partial line — so the
    // damage swallows the new record too, and a recoverable one-line loss
    // becomes an ongoing one. `lastRecord` already tolerates the torn line; the
    // write path has to as well.
    let prefix = '';
    try {
      const size = fs.statSync(ledgerPath()).size;
      if (size > 0) {
        const fd = fs.openSync(ledgerPath(), 'r');
        const tail = Buffer.alloc(1);
        fs.readSync(fd, tail, 0, 1, size - 1);
        fs.closeSync(fd);
        if (tail.toString('utf8') !== '\n') prefix = '\n';
      }
    } catch {
      /* no file yet, or unreadable — the append below decides */
    }
    fs.appendFileSync(ledgerPath(), `${prefix}${JSON.stringify(record)}\n`, 'utf8');
    return record;
  });
}

// --- request classification --------------------------------------------------

// Tools that can execute or mutate. Read/Grep/Glob never reach the permission
// layer in this harness, so recording them would bury the signal in noise —
// the "unread lake" failure the ticket warns about.
export const RECORDED_TOOLS = ['Bash', 'Edit', 'Write', 'MultiEdit', 'NotebookEdit'];

// Mirrors auto-approve-safe-bash.sh's read-only set. Several of these have a
// write-capable or exec-capable flag (`sort -o`, `find -exec`, `xxd -r`) and
// are gated by hasWriteFlag below — the same pairing the production hook uses.
// Keeping the sets aligned is the point: a shadow verdict that disagrees with
// the production gate on the same command measures its own drift.
const READ_ONLY_BINS = new Set([
  'cat', 'tac', 'head', 'tail', 'nl', 'wc', 'cut', 'tr', 'sort', 'uniq', 'comm',
  'grep', 'egrep', 'fgrep', 'rg', 'jq', 'file', 'stat', 'ls', 'tree', 'du', 'df',
  'realpath', 'readlink', 'basename', 'dirname', 'pwd', 'echo', 'printf', 'date',
  'seq', 'true', 'false', 'which', 'type', 'printenv', 'diff', 'cmp',
  'sha256sum', 'md5sum', 'cd', 'find', 'xxd', 'od', 'hexdump', 'strings', 'base64',
]);

const GIT_READ_SUBCMDS = new Set([
  'status', 'log', 'diff', 'show', 'rev-parse', 'rev-list', 'describe', 'blame',
  'shortlog', 'ls-files', 'ls-tree', 'cat-file', 'for-each-ref', 'merge-base',
  'show-ref', 'version',
]);

// Per-family VALIDATED subcommand sets. The second token is kept only when it
// is a known subcommand of that family — never merely because the family is
// recognised.
//
// A family allowlist alone was not enough, and the gap is instructive: runner
// commands like `node`, `npx`, `bun` and `dotnet` take a PATH or a PACKAGE as
// their second token, not a verb. `npx https://alice:TOKEN@github.com/acme/x`
// would have persisted the whole credential-bearing URL, and
// `node /home/alice/clients/acme/deploy.mjs` a private path. Validating the
// token itself is the boundary: anything not on the list is dropped, so an
// unrecognised token — which is exactly where secrets live — can never land in
// the ledger. Runner families are therefore absent entirely: verb-only.
const SUBVERB_FAMILIES = new Map([
  ['git', new Set(['status', 'log', 'diff', 'show', 'add', 'commit', 'push', 'pull',
    'fetch', 'merge', 'rebase', 'checkout', 'switch', 'branch', 'tag', 'stash',
    'reset', 'clean', 'clone', 'remote', 'worktree', 'restore', 'cherry-pick',
    'revert', 'rev-parse', 'ls-files', 'blame', 'apply', 'bisect', 'config'])],
  ['gh', new Set(['pr', 'issue', 'repo', 'run', 'workflow', 'release', 'api',
    'auth', 'label', 'gist', 'search', 'cache', 'secret'])],
  ['npm', new Set(['run', 'install', 'ci', 'test', 'publish', 'audit', 'exec',
    'link', 'update', 'outdated', 'ls', 'pack', 'version'])],
  ['pnpm', new Set(['run', 'install', 'add', 'test', 'exec', 'update', 'publish'])],
  ['yarn', new Set(['run', 'install', 'add', 'test', 'publish', 'upgrade'])],
  ['docker', new Set(['build', 'run', 'ps', 'exec', 'compose', 'images', 'pull',
    'push', 'logs', 'stop', 'start', 'rm', 'rmi', 'inspect', 'volume', 'network'])],
  ['cargo', new Set(['build', 'test', 'run', 'check', 'clippy', 'fmt', 'add',
    'publish', 'update', 'bench', 'doc'])],
  ['kubectl', new Set(['get', 'apply', 'delete', 'describe', 'logs', 'exec',
    'rollout', 'scale', 'port-forward', 'config'])],
  ['terraform', new Set(['init', 'plan', 'apply', 'destroy', 'validate', 'fmt', 'show'])],
  ['systemctl', new Set(['status', 'start', 'stop', 'restart', 'enable', 'disable',
    'reload', 'list-units'])],
]);

// A bare command name. Deliberately narrow — see the verb check in `classify`.
const PLAIN_COMMAND = /^[A-Za-z0-9._+-]+$/;

// verb x target-pattern. Coarse on purpose: the class is what gets counted, so
// it has to be stable across sessions and free of one-off detail.
export function classify(toolName, toolInput = {}) {
  if (toolName === 'Bash') {
    const cmd = String(toolInput.command ?? '');
    const words = cmd.trim().split(/\s+/).filter(Boolean);
    // Drop leading VAR=val assignments so `FOO=1 git push` classifies as git —
    // and never let the assignment itself (which holds a value) become the verb.
    let i = 0;
    while (i < words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i])) i++;
    const raw = words[i] ?? '';
    // Basename only: `/usr/local/bin/git` and `git` are the same class, and an
    // absolute path can itself carry a revealing directory layout.
    const base = raw ? path.basename(raw) : '';
    // The verb is persisted VERBATIM, so it has to BE a plain command name.
    // Whitespace splitting cannot see a quoted assignment VALUE that contains a
    // space: `TOKEN='x SECRET123' git status` splits to `TOKEN='x` /
    // `SECRET123'` / `git`, the assignment loop stops at the second fragment,
    // and the SECRET became the verb — written to the ledger in cleartext.
    // The subcommand half is allowlist-validated for exactly this reason; the
    // verb half was not. An unrecognisable verb is dropped to `unknown` and only
    // the hash is kept, because ambiguity is precisely where secrets live.
    const verb = PLAIN_COMMAND.test(base) ? base : '';
    if (base && !verb) {
      return { class: 'bash:unknown', target: 'unknown', target_hash: sha256(cmd) };
    }
    const next = words[i + 1];
    const known = SUBVERB_FAMILIES.get(verb);
    const sub = known && next && known.has(next) ? next : '';
    const target = [verb, sub].filter(Boolean).join(' ');
    return { class: `bash:${target || 'empty'}`, target, target_hash: sha256(cmd) };
  }
  // Extension only — NOT the parent directory. A directory basename leaks the
  // same class of thing a command argument does: client, project and customer
  // names (`/work/clients/AcmeCorp/x.ts`). The privacy promise has to hold on
  // the file side too, and `target_hash` still distinguishes individual paths
  // for correlation without naming any of them.
  const file = String(toolInput.file_path ?? toolInput.notebook_path ?? '');
  const ext = path.extname(file) || '(none)';
  return {
    class: `${toolName.toLowerCase()}:${ext}`,
    target: ext,
    target_hash: sha256(file),
  };
}

// --- the blind verdict -------------------------------------------------------

// One definition of "this path is git metadata", shared by the file-tool branch
// and the redirect branch. Two copies drifted once already: the redirect copy
// only matched a cwd-relative `.git/`, so the absolute form was never denied.
// A trailing `.git` with no separator is the worktree POINTER FILE — rewriting
// it repoints the worktree at another repository, the same refusal class.
const GIT_METADATA_PATH = /(^|[\\/])\.git([\\/]|$)/;
// The word after `>` or `>>`, ending at whitespace or a control operator.
// `&\d+` is matched first and deliberately: there the `&` belongs to the target
// (fd duplication, `2>&1`), everywhere else it separates commands.
const REDIRECT_TARGET = />>?\s*(&\d+|[^\s;|&]*)/g;

// Deliberately small and deliberately NOT a re-implementation of
// auto-approve-safe-bash.sh. That hook is the production gate and owns its own
// 486 lines of edge cases; duplicating them here would create two rule sets that
// drift apart and a ledger that measures the drift. This answers the narrower
// question described in the file header, and says `abstain` whenever it is not
// certain. Abstain is a real answer, not a failure.
export function shadowVerdict(toolName, toolInput = {}) {
  if (toolName !== 'Bash') {
    // A write into .git/ is the ONE provable refusal here. Writes elsewhere —
    // including outside the repo — are ordinary (scratchpads, temp dirs), so
    // they are contested, not denied. Claiming more than this in the comment
    // would describe a rule the code does not implement, and a shadow verdict
    // is only worth what its stated basis is.
    const file = String(toolInput.file_path ?? toolInput.notebook_path ?? '');
    if (GIT_METADATA_PATH.test(file)) return 'deny';
    return 'abstain';
  }

  const cmd = String(toolInput.command ?? '');
  if (!cmd.trim()) return 'abstain';

  // Everything below that reads STRUCTURE — where a segment ends, where a
  // redirect points — reads it off a QUOTE-MASKED copy, so a separator or a `>`
  // inside a quoted argument is the literal text it is.
  const masked = maskQuoted(cmd);

  // A bare `&` is a real command separator: in `ls & rm file` the `rm` runs, so
  // treating the line as one `ls` segment produced a false `allow` — the most
  // damaging error this function can make. Excluded via lookaround are the
  // forms where `&` is part of a redirect (`2>&1`, `>&2`, `&>file`) or the
  // logical `&&`, both of which must stay attached to their segment.
  //
  // The separators are LOCATED on `masked` and the text is SLICED from `cmd`:
  // splitting the raw string made `echo "x && git push --force origin main"`
  // two segments, the second of which runs `git push --force` — a false `deny`
  // on a line that runs `echo`. Segment CONTENT stays raw so argument matching
  // below is unchanged; only the boundaries come from the masked copy.
  const spans = [];
  let cut = 0;
  for (const sep of masked.matchAll(/\|\||&&|[|;\n]|(?<![<>&])&(?![&>])/g)) {
    spans.push(cmd.slice(cut, sep.index));
    cut = sep.index + sep[0].length;
  }
  spans.push(cmd.slice(cut));
  const segments = spans.map((s) => s.trim()).filter(Boolean);
  if (!segments.length) return 'abstain';

  // Tokenise each segment down to the binary it actually runs, so both the deny
  // and the allow rules see argv rather than raw text.
  const parsed = segments.map((seg) => {
    const words = seg.split(/\s+/).filter(Boolean);
    let i = 0;
    let unsafeEnv = false;
    while (i < words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i])) {
      // Only locale/timezone assignments are innocuous. LD_PRELOAD,
      // GIT_EXTERNAL_DIFF, BASH_ENV, NODE_OPTIONS, PAGER and friends turn a
      // "read" command into arbitrary execution — `LD_PRELOAD=/tmp/evil.so ls`
      // is not `ls`. auto-approve-safe-bash.sh takes exactly this stance, and a
      // shadow verdict that disagrees with the production gate on the same
      // command is measuring its own drift. Allowlist, because the dangerous
      // set is open-ended.
      if (!/^(LANG|LANGUAGE|LC_[A-Z]+|TZ)=/.test(words[i])) unsafeEnv = true;
      i++;
    }
    const raw = words[i];
    return { bin: raw ? path.basename(raw) : '', args: words.slice(i + 1), unsafeEnv };
  });

  // Provably refused shapes. Kept to cases the harness already hard-blocks, so
  // a `deny` here is a prediction the ledger can actually be scored against.
  //
  // Matched PER SEGMENT against the resolved binary, never against the raw
  // command string. A whole-string regex classified `echo "git push --force"`
  // as a denied force-push — the words appear, but the segment runs `echo`.
  // A verdict engine that reads text instead of argv measures its own parsing.
  for (const { bin, args } of parsed) {
    if (bin !== 'git') continue;
    const sub = gitSubcommand(args);
    if (sub === 'push' && isForcePush(args)) return 'deny';
    if (sub === 'commit' && args.includes('--amend')) return 'deny';
  }
  // A redirect INTO git metadata is a denial wherever the file lives. Matching
  // `>\s*\.git[\\/]` only recognised a target written relative to the cwd, so
  // `> /repo/.git/config` and `> ../.git/config` recorded `abstain` — the
  // documented deny, silently missing on the absolute form. The target is
  // extracted the same way the write check below extracts it, and tested with
  // GIT_METADATA_PATH, the SAME predicate the file-tool branch uses, so the two
  // paths cannot drift apart on what counts as git metadata.
  for (const [, target] of masked.matchAll(REDIRECT_TARGET)) {
    if (GIT_METADATA_PATH.test(target)) return 'deny';
  }

  // Substitution is checked on the RAW text, deliberately: `"$(ls)"` still
  // expands inside double quotes, so masking here would under-detect. Erring
  // toward `abstain` costs nothing; missing a dynamic command costs a wrong
  // `allow`.
  if (/\$\(|`|<\(|>\(/.test(cmd)) return 'abstain';
  // Any redirect to a real file is a write. The target is EXTRACTED and then
  // compared, rather than excluded by a lookahead: in `>>?\s*(?!\/dev\/null|&\d)`
  // the `\s*` backtracks to zero width, so the lookahead ran against the SPACE
  // and the exclusion silently did not apply to the spaced form. That made
  // `ls > /dev/null` a false `abstain`, and — because the unspaced form is the
  // only one the lookahead ever saw — `>/dev/null.bak` a false `allow`, which is
  // the damaging direction.
  // The target ends at whitespace OR a control operator, so `>/dev/null; pwd`
  // does not extract `/dev/null;` and lose the exclusion. `&\d+` is matched
  // first and deliberately: there the `&` belongs to the target (fd duplication,
  // `2>&1`), everywhere else it separates.
  for (const [, target] of masked.matchAll(REDIRECT_TARGET)) {
    if (target === '/dev/null' || /^&\d+$/.test(target)) continue;
    return 'abstain';
  }

  for (const { bin, args, unsafeEnv } of parsed) {
    if (!bin) return 'abstain';
    if (unsafeEnv) return 'abstain';
    if (bin === 'git') {
      const sub = gitSubcommand(args);
      if (!GIT_READ_SUBCMDS.has(sub)) return 'abstain';
      continue;
    }
    if (!READ_ONLY_BINS.has(bin)) return 'abstain';
    if (hasWriteFlag(bin, args)) return 'abstain';
  }
  return 'allow';
}

// Several nominally read-only binaries have a flag that writes a file or runs a
// command — `sort -o out.txt` writes, `find -exec` executes. The production
// guard gates each of these; without the same gate `allow` would be false on
// commands that are not reads at all.
function hasWriteFlag(bin, args) {
  const has = (...names) => args.some((a) => names.some((n) => a === n || a.startsWith(`${n}=`)));
  switch (bin) {
    case 'sort': case 'tree': case 'base64':
      return has('-o', '--output') || args.some((a) => /^-o./.test(a));
    case 'find':
      return has('-exec', '-execdir', '-ok', '-okdir', '-delete', '-fprint',
        '-fprintf', '-fprint0', '-fls');
    case 'file':
      return has('-C', '--compile');
    case 'xxd':
      // `xxd in out` writes: a second positional is an output file.
      return has('-r', '-revert') || args.filter((a) => !a.startsWith('-')).length >= 2;
    default:
      return false;
  }
}

// Blanks the contents of quoted spans (keeping length, so nothing shifts) so
// structural characters inside them are not mistaken for shell syntax.
function maskQuoted(s) {
  let out = '';
  let quote = null;
  let escaped = false;
  for (const ch of s) {
    // A backslash escapes the next character everywhere EXCEPT inside single
    // quotes, where it is literal. Ignoring it treated the escaped quote in
    // `echo \'> out` as an opening delimiter, which swallowed the `>` — a real
    // file write recorded as provably read-only, the most damaging error here.
    // Both the backslash and what it escapes are masked: neither can be
    // structure, so neither may be read as any.
    if (escaped) { out += ' '; escaped = false; continue; }
    if (quote !== "'" && ch === '\\') { out += ' '; escaped = true; continue; }
    if (quote) {
      out += ch === quote ? ch : ' ';
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === "'" || ch === '"') { quote = ch; out += ch; continue; }
    out += ch;
  }
  return out;
}

// `--force-with-lease` is the sanctioned form and is NOT a force-push here.
// The `+` refspec prefix is: `git push origin +main` force-updates the remote
// ref with no flag at all, which a flag-only check misses entirely.
// auto-approve-safe-bash.sh treats `+main` as a force target for the same
// reason; a classifier that disagrees with the production gate on the same
// command is measuring nothing useful.
function isForcePush(args) {
  // Bare --force is checked FIRST. `--force-with-lease --force` is NOT the safe
  // form: the bare flag clobbers without the stale-tip check whatever else is
  // present, and auto-approve-safe-bash.sh refuses that combination outright.
  // Returning early on the lease flag let the dangerous form read as safe.
  if (args.some((a) => a === '--force' || a === '-f')) return true;
  if (args.some((a) => a === '--force-with-lease' || a.startsWith('--force-with-lease='))) return false;
  return args.some((a) => /^\+[^-]/.test(a));
}

// The subcommand, skipping git's GLOBAL flags. Some of them take a SEPARATE
// argument (`git -C repo push`), so a naive "first non-flag word" reads `repo`
// as the subcommand and misses the push entirely — which silently downgraded
// `git -C repo push --force` from deny to abstain.
function gitSubcommand(args) {
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '-C' || a === '--git-dir' || a === '--work-tree' || a === '--namespace' || a === '-c') {
      i += 1;               // consumes the next word
      continue;
    }
    if (a.startsWith('-')) continue;   // =-forms and simple flags
    return a;
  }
  return '';
}

// --- provenance --------------------------------------------------------------

// Best-effort. No dispatcher currently exports a lane marker, so most rows will
// read `primary`; attribution improves the day spawn-* export HIMMEL_LANE, and
// is deliberately not guessed from cwd here (a worktree does not imply a lane).
export function requesterLane() {
  const explicit = process.env.HIMMEL_LANE;
  if (explicit && explicit.trim()) return explicit.trim();
  if (process.env.CLAUDE_CODE_EFFORT_LEVEL) return 'claudex';
  const base = process.env.ANTHROPIC_BASE_URL ?? '';
  if (/z\.ai|bigmodel/i.test(base)) return 'glm';
  return 'primary';
}

// Pins WHICH lane registry was in force when the decision was recorded, so a
// later routing change cannot silently rewrite the meaning of old rows.
export function laneConfigHash(projectDir = process.env.CLAUDE_PROJECT_DIR) {
  if (!projectDir) return null;
  try {
    const f = path.join(projectDir, 'scripts', 'lanes', 'lanes.json');
    return sha256(fs.readFileSync(f, 'utf8')).slice(0, 16);
  } catch {
    return null;
  }
}

// --- hook entry points -------------------------------------------------------

function readStdin() {
  try {
    return fs.readFileSync(0, 'utf8');
  } catch {
    return '';
  }
}

function parsePayload() {
  const raw = readStdin();
  if (!raw.trim()) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

// Correlates a PreToolUse row with its PostToolUse outcome. Prefer the harness's
// own `tool_use_id`, which is unique per call and present on both events. The
// derived fallback hashes only session + tool + request content, so two
// IDENTICAL calls in one session collapse onto one ref — and since outcomes are
// matched as a set, a single success would then mark every duplicate executed,
// hiding a denial or a strand behind its twin. The fallback stays for payloads
// that lack the field, and is marked in the record so the ambiguity is visible
// rather than assumed away.
export function refFor(payload, cls) {
  if (payload.tool_use_id) return String(payload.tool_use_id);
  return `d:${sha256(`${payload.session_id ?? ''}\n${payload.tool_name ?? ''}\n${cls.target_hash}`).slice(0, 16)}`;
}

export function cmdPre(payload, now) {
  const tool = payload.tool_name ?? '';
  if (!RECORDED_TOOLS.includes(tool)) return null;
  const cls = classify(tool, payload.tool_input ?? {});
  return append({
    ts: now,
    kind: 'request',
    ref: refFor(payload, cls),
    session_id: payload.session_id ?? null,
    tool,
    class: cls.class,
    target: cls.target,
    target_hash: cls.target_hash,
    requester_lane: requesterLane(),
    lane_config_hash: laneConfigHash(),
    permission_mode: payload.permission_mode ?? null,
    shadow_verdict: shadowVerdict(tool, payload.tool_input ?? {}),
    actual_verdict: null,
  });
}

// The DECISION, recorded alongside the event. `actual_verdict` is asserted only
// where it is OBSERVED; the absence of an outcome row is never read as "denied".
//
// One recorder for all three terminal outcomes rather than three near-copies.
// The lesson this file already paid for twice (HIMMEL-1529 CR rounds 3 and 4):
// when several call sites make the same structural read, converting them one at
// a time moves the defect down a layer instead of fixing it, and every move
// looks like a fix because the test just written passes.
function recordOutcome(payload, now, verdict) {
  const tool = payload.tool_name ?? '';
  if (!RECORDED_TOOLS.includes(tool)) return null;
  const cls = classify(tool, payload.tool_input ?? {});
  return append({
    ts: now,
    kind: 'outcome',
    ref: refFor(payload, cls),
    session_id: payload.session_id ?? null,
    actual_verdict: verdict,
  });
}

export function cmdPost(payload, now) {
  return recordOutcome(payload, now, 'executed');
}

// PostToolUseFailure — the call RAN and failed. Distinct from a denial: the
// harness let it through, so it is not an approval interrupt and must not be
// counted as one. Before this was wired it landed in `unresolved` alongside
// genuine denials, which corrupted the agreement data by construction.
export function cmdPostFailure(payload, now) {
  return recordOutcome(payload, now, 'executed_failed');
}

// PermissionDenied — the call was REFUSED by the AUTO-MODE CLASSIFIER, and
// only by it. Verified against the Claude Code hook reference: the event fires
// "when a tool call is denied by the auto mode classifier". A manual operator
// denial, a `deny` permission rule, and a PreToolUse block do NOT raise it, so
// those requests still land in `unresolved`.
//
// The verdict is named for what it actually observes rather than for
// "denied" in general. A short name that overstates its own scope is how a
// partial signal gets read as complete coverage — the same failure class as a
// weekly rate computed over rows that silently went missing.
export function cmdDenied(payload, now) {
  return recordOutcome(payload, now, 'denied_auto_classifier');
}

// PermissionRequest — fires when a tool call NEEDS a permission decision.
//
// Read that literally, because the tempting reading is wrong: "a decision was
// needed" is NOT "a human was interrupted". In an armed or otherwise unattended
// session the event still fires and nobody is there to be interrupted — this
// programme measured that directly (W0 probe P5: a hook returning `ask` hung
// for 902 s on a dialog no one could answer). Counting these as operator
// interrupts would inflate the one number the whole thing is gated on, with the
// inflation concentrated in exactly the unattended runs this harness does most.
//
// So the count is reported as permission-request EVENTS, beside the
// Notification-derived figure rather than as a replacement for it. Two
// independent estimators of one quantity are how you find out which is right;
// silently switching to the new surface would replace a measured number with an
// unvalidated one and destroy the comparison. HIMMEL-1539 raised the choice as
// a design input for HIMMEL-1530 — collecting both is what makes that decision
// evidence-based instead of another round of argument.
//
// `permission_mode` is persisted because it is the only interactivity-adjacent
// signal on the payload. It is stored, NOT interpreted: no count here claims to
// separate a real dialog from an unattended one until that can be shown.
//
// No RECORDED_TOOLS filter, on purpose: a permission decision counts whatever
// tool raised it, and this row carries no request payload to classify.
export function cmdPermissionRequest(payload, now) {
  return append({
    ts: now,
    kind: 'permission_request',
    session_id: payload.session_id ?? null,
    tool: payload.tool_name ?? null,
    permission_mode: payload.permission_mode ?? null,
  });
}

export function cmdNotify(payload, now) {
  // Record EVERY notification, and classify at report time rather than here.
  // Notification does not fire only for permission prompts — the harness also
  // raises it for idle-wait timeouts and elicitation dialogs (see
  // scripts/hooks/telegram-notification.sh, which documents the same surface),
  // so counting them all as approval interrupts inflates the one number this
  // ledger exists to produce.
  //
  // Filtering in the hook would be worse than filtering in the report: if the
  // type vocabulary is not what we expect, a hook-side filter silently records
  // NOTHING and the gate number reads zero with no way to tell that apart from
  // a genuinely quiet week. Recording everything and classifying later means an
  // unrecognised type shows up in the report's breakdown instead of vanishing,
  // and old rows can be reclassified without re-collecting them.
  return append({
    ts: now,
    kind: 'notification',
    session_id: payload.session_id ?? null,
    notification_type: payload.notification_type ?? null,
  });
}

// --- collector heartbeat (HIMMEL-1547) ---------------------------------------

// Every settings file the harness merges for a session, cheapest first. A verb
// wired at USER scope is as live as one wired at project scope, so reading only
// the project file would report a complete inventory as incomplete and withhold
// a rate that was in fact fully observed. Missing files are not an error —
// most projects have only one of these.
function settingsCandidates(projectDir = process.env.CLAUDE_PROJECT_DIR) {
  const out = [];
  if (projectDir) {
    out.push(path.join(projectDir, '.claude', 'settings.json'));
    out.push(path.join(projectDir, '.claude', 'settings.local.json'));
  }
  out.push(path.join(os.homedir(), '.claude', 'settings.json'));
  return out;
}

// Which ledger verbs are WIRED, read off the settings files on disk.
//
// Read what this proves, and nothing more. It proves the CONFIGURATION named
// these verbs at the moment the session started — a necessary condition for
// their rows to exist, and not a sufficient one: a wired hook can still fail to
// spawn. That is exactly why the heartbeat row and the inventory are separate
// signals. The row proves a recorder RAN; the inventory proves the config it
// ran under was complete. Neither alone protects the gate number, and calling
// either of them "the hook works" would be this subsystem's own recurring
// mistake — an observation reported as a claim.
//
// Failure is silent and yields null, distinguished from an empty array: "could
// not read the config" and "the config wires nothing" are different facts, and
// `summarize` refuses the rate on either rather than guessing which.
//
// A verb counts only under its OWN canonical event, with the canonical
// matcher, from a SINGLE `type: 'command'` hook naming it as the last
// whitespace token (HIMMEL-1547 CR round). Before this, the loop walked every
// entry under every event and accepted any ledger-shaped command whose last
// token was a known verb — so a settings file with all seven canonical-looking
// commands parked under `SessionStart` returned the complete inventory while
// `notify` never actually ran for `Notification` events. That is the exact
// failure class this subsystem exists to remove: a check that CLAIMS more than
// it verifies.
export function wiredVerbs(candidates = settingsCandidates()) {
  const byEvent = new Map(EXPECTED_HOOKS.map((spec) => [spec.event, spec]));
  const found = new Set();
  let readAny = false;
  for (const file of candidates) {
    let parsed;
    try {
      parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch {
      continue; // absent or unparseable — not this recorder's business to fix
    }
    readAny = true;
    const hooks = parsed && typeof parsed === 'object' && !Array.isArray(parsed)
      ? parsed.hooks
      : null;
    if (!hooks || typeof hooks !== 'object' || Array.isArray(hooks)) continue;
    for (const [event, list] of Object.entries(hooks)) {
      // An event this recorder does not depend on proves nothing about any
      // verb, no matter what a command under it happens to be named.
      const spec = byEvent.get(event);
      if (!spec || !Array.isArray(list)) continue;
      for (const entry of list) {
        const inner = Array.isArray(entry?.hooks) ? entry.hooks : [];
        // Exactly ONE hook, same requirement wire-trust-hooks.mjs's `isOurs`
        // enforces: a ledger command sharing an entry with somebody else's
        // hook is not safely attributable to this event alone.
        if (inner.length !== 1) continue;
        const [h] = inner;
        if (!h || h.type !== 'command') continue;
        const cmd = typeof h.command === 'string' ? h.command : '';
        if (!cmd.includes('shadow-ledger.mjs')) continue;
        // The verb is the last token. An invocation carrying extra arguments
        // is NOT counted: wire-trust-hooks refuses non-canonical ledger
        // commands outright, so anything shaped differently is a stray this
        // file must not vouch for.
        const tokens = cmd.trim().split(/\s+/);
        const verb = tokens[tokens.length - 1];
        if (verb !== spec.verb) continue;
        // `matcher: null` means the canonical entry carries NO matcher key at
        // all (see EXPECTED_HOOKS); a string matcher must equal it exactly.
        const matcherOk = spec.matcher === null
          ? entry.matcher === undefined
          : entry.matcher === spec.matcher;
        if (!matcherOk) continue;
        found.add(spec.verb);
      }
    }
  }
  if (!readAny) return null;
  return [...found].sort();
}

// SessionStart — the collector proving it was loaded and could write.
//
// This is the ONE row in the ledger that is not evidence of activity, and that
// is its whole purpose. Every other kind here fires because something happened,
// so their absence is ambiguous: a week with no notification rows is either a
// quiet week or a dead hook, and the published rate is the same number either
// way (HIMMEL-1547). A heartbeat separates those two, because it fires whether
// or not anything else did.
//
// SessionStart is the cheapest possible carrier — no timer, no daemon, no new
// process, and one row per session is plenty of resolution for a weekly figure.
export function cmdHeartbeat(payload, now) {
  return append({
    ts: now,
    kind: 'heartbeat',
    session_id: payload.session_id ?? null,
    source: payload.source ?? null,
    hook_inventory: wiredVerbs(),
  });
}

// Which notification types count as an approval interrupt. Deliberately a loose
// substring match, not an exact string: undercounting the gate metric is the
// expensive error, and anything it does NOT match is still surfaced by name in
// the report so a vocabulary change is visible rather than silent.
export function isApprovalInterrupt(notificationType) {
  return /permission|approval/i.test(String(notificationType ?? ''));
}

// --- report ------------------------------------------------------------------

export function readAll(file = ledgerPath()) {
  return readLedger(file).records;
}

// Reads the ledger AND reports whether it can be trusted. Silently skipping a
// torn line and then publishing a confident rate is the failure this guards:
// a killed append or a disk fault turns an interior record into garbage, later
// rows still parse, and the gate number comes out plausible but understated
// with nothing to indicate it. The chain exists precisely to detect that, so
// the read path checks it — this is not the standalone verification tooling the
// ticket defers, it is the report refusing to publish a number it cannot stand
// behind.
// One parse of the ledger text. Split out so the torn-tail path can re-read a
// stable snapshot and run the IDENTICAL classification over it — re-deriving
// the parse for the retry is how the two copies drift apart.
function parseLedgerText(text) {
  const lines = text.split('\n');
  const records = [];
  let malformed = 0;
  let torn = 0;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line.trim()) continue;
    try {
      const parsed = JSON.parse(line);
      // A successfully PARSED value is not necessarily a usable ROW. `null`,
      // `42` and `"x"` are all valid JSON, and every consumer downstream
      // dereferences `.kind` — so an unvalidated row threw a TypeError that the
      // fail-open handler turned into exit 0 with empty stdout. Corruption
      // produced neither a report nor a warning. Shape is damage, not a crash.
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
        malformed += 1;
        continue;
      }
      records.push(parsed);
    } catch {
      // An unterminated FINAL line MAY be a torn in-flight append. Anywhere
      // else it is unambiguous damage.
      if (i === lines.length - 1) torn += 1;
      else malformed += 1;
    }
  }
  return { records, malformed, torn };
}

// Bounded wait for the writer lock to be released, so the retry above reads a
// snapshot nobody is mid-append into. Bounded because a reader must never hang
// on a wedged writer: if the budget runs out we simply re-read and judge what
// is there, which fails toward declaring damage.
function waitForLockToClear(file) {
  const idle = new Int32Array(new SharedArrayBuffer(4)); // hoisted: one buffer, not one per retry
  for (let i = 0; i < LOCK_TRIES; i++) {
    if (!liveWriterPresent(file)) return;
    Atomics.wait(idle, 0, 0, LOCK_WAIT_MS);
  }
}

export function readLedger(file = ledgerPath()) {
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (e) {
    // Same rule as readDrops: a ledger that does not exist yet is genuinely
    // empty and intact. A ledger that exists but cannot be READ is unknown,
    // and unknown must not present as clean.
    if (e && e.code === 'ENOENT') {
      return { records: [], malformed: 0, torn: 0, brokenLinks: 0, unreadable: false, intact: true };
    }
    // [glm round 4] A file that cannot be OPENED is not a row that failed to
    // parse. Reporting it as `malformed: 1` suppressed the rate correctly but
    // printed "1 unreadable row(s)" over a file with zero rows — a true verdict
    // reached through a false statement, in the one surface this ticket exists
    // to make honest.
    return { records: [], malformed: 0, torn: 0, brokenLinks: 0, unreadable: true, intact: false };
  }
  let { records, malformed, torn } = parseLedgerText(text);
  // A torn tail MAY be an append that is in flight right now and about to
  // complete. Liveness decides whether to WAIT for it — never whether to
  // forgive it. Forgiving on liveness alone was wrong twice over: a live lock
  // does not tie its holder to THIS fragment (a later writer would briefly
  // absolve an abandoned one it never created), and a report racing an
  // incomplete append could publish before that row landed.
  //
  // So: give the writer a bounded chance to finish, re-read a stable snapshot,
  // and then judge what is actually on disk. After the wait there is no
  // exemption at all — a tail that still does not parse is damage, whoever
  // holds the lock. A completing append heals the file by prefixing a newline
  // to its own record, which turns an abandoned fragment into an INTERIOR
  // line, so it is still counted, just as `malformed` instead of `torn`.
  if (torn > 0 && liveWriterPresent(file)) {
    waitForLockToClear(file);
    let retext;
    try {
      retext = fs.readFileSync(file, 'utf8');
    } catch {
      retext = null;
    }
    if (retext !== null) ({ records, malformed, torn } = parseLedgerText(retext));
  }
  let brokenLinks = 0;
  let prev = GENESIS;
  for (const r of records) {
    if (r.prev_hash !== prev || r.hash !== chainHash(r.prev_hash, r)) brokenLinks += 1;
    prev = r.hash;
  }
  return {
    records,
    malformed,
    torn,
    brokenLinks,
    unreadable: false,
    intact: malformed === 0 && brokenLinks === 0 && torn === 0,
  };
}

// Drops recorded by `recordDrop`. A line that does not parse still COUNTS as a
// drop: it is evidence the recorder was in trouble, and discarding it would
// restore the exact blindness this channel exists to remove. Such a line has no
// usable timestamp, so it is treated as in-window by `summarize`.
export function readDrops(file = healthPath()) {
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (e) {
    // ENOENT is the ordinary healthy case: no drops have ever been recorded.
    // ANY OTHER error (EACCES, EIO, a directory in the way) means the health
    // channel cannot be read, and "cannot read" must never present as "no
    // drops" — that is fail-OPEN on the one channel whose whole job is to
    // report losses. Surface it as a drop so the rate is suppressed.
    if (e && e.code === 'ENOENT') return [];
    return [{ ts: null, reason: 'health_channel_unreadable' }];
  }
  const out = [];
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    try {
      out.push(JSON.parse(line));
    } catch {
      out.push({ ts: null, reason: 'unparseable_drop_row' });
    }
  }
  return out;
}

export function summarize(
  records,
  sinceIso,
  nowIso = new Date().toISOString(),
  integrity = null,
  drops = [],
) {
  const rows = sinceIso ? records.filter((r) => (r.ts ?? '') >= sinceIso) : records;
  // Correlation runs over the FULL history; the window is applied to the
  // RESULTS. Filtering requests first was wrong: an outcome belonging to a
  // pre-cutoff request would be left unclaimed, and the first in-window request
  // sharing its derived ref would consume it — reporting an execution that
  // request never had. Its rightful owner has to be present to claim it.
  const allRequests = [];
  records.forEach((r, idx) => {
    if (r.kind === 'request') allRequests.push({ ...r, __idx: idx });
  });
  const notifications = rows.filter((r) => r.kind === 'notification');
  const interrupts = notifications.filter((r) => isApprovalInterrupt(r.notification_type));
  const permissionRequests = rows.filter((r) => r.kind === 'permission_request');

  // A drop with no USABLE timestamp counts as in-window: it cannot be ruled
  // out, and the whole point of this channel is to stop unprovable losses
  // reading as zero. Same direction as everything else here — when unsure,
  // suppress.
  //
  // A recorded drop suppresses the rate for as long as the drop row exists.
  // Drops are deliberately NOT expired by timestamp.
  //
  // There is deliberately NO acknowledgement path that restores the rate.
  // Rotating `drops.jsonl` was briefly documented as one and is not: the lost
  // event is still missing from the window afterwards, so the rate would come
  // back over data known to be incomplete — laundering the loss instead of
  // resolving it. Restoring a rate honestly needs a durable `valid_since`
  // checkpoint that moves the window PAST the loss, which is tracked in
  // HIMMEL-1547 along with the collector-liveness heartbeat it shares
  // machinery with.
  //
  // Two rounds of review taught this the expensive way. Expiring on wall-clock
  // first let a truthy-but-non-string `ts` escape the window, then let a
  // BACKWARD CLOCK STEP across the cutoff re-date an in-window failure as old —
  // both producing dropped_writes=0 and a confident rate over a ledger with
  // known missing events, which is precisely the false-clean this channel
  // exists to prevent. There is no durable proof a drop predates the window
  // (that is what HIMMEL-1547's checkpoint would provide), so the honest
  // options are "suppress until acknowledged" or "trust a clock we have twice
  // shown we cannot trust". Deleting the comparison also deletes the boundary,
  // which is the lesson this subsystem keeps re-teaching.
  const droppedWrites = drops.length;

  // COUNT outcomes per ref rather than testing set membership. Membership lets
  // ONE outcome mark every request sharing that ref as resolved, which silently
  // undercounts unresolved prompts — and refs are shared whenever the harness
  // gives us no `tool_use_id` and we fall back to a derived (`d:`) hash. Two
  // identical calls with one success are one executed and one unresolved, and
  // this is the field whose whole job is to keep that distinction.
  //
  // Outcomes are now VERDICT-BEARING, so the per-ref budget holds the verdicts
  // in arrival order and each request consumes the next one, rather than
  // decrementing an anonymous counter.
  // Built from ALL records, keyed by ref, carrying row position — see the
  // ordering note in the match loop for why position and not `ts`.
  const outcomesByRef = new Map();
  records.forEach((r, idx) => {
    if (r.kind !== 'outcome') return;
    const entry = { idx, verdict: r.actual_verdict };
    const q = outcomesByRef.get(r.ref);
    if (q) q.push(entry);
    else outcomesByRef.set(r.ref, [entry]);
  });
  const cursor = new Map();
  const outcomes = { executed: 0, executed_failed: 0, denied_auto_classifier: 0, other: 0 };
  // Pass 1 — assign outcomes across ALL requests, in ledger order.
  const verdictFor = new Map();
  for (const r of allRequests) {
    const q = outcomesByRef.get(r.ref);
    if (!q) continue;
    let i = cursor.get(r.ref) ?? 0;
    // An outcome must FOLLOW the request it resolves, and "follows" means
    // LEDGER ROW POSITION — never wall-clock. The ledger is append-only and
    // hash-chained, so position IS causal order; `ts` only approximates it and
    // fails at both boundaries. Equal timestamps (millisecond precision, and
    // a hook pair can share a millisecond) made an orphan outcome consumable
    // by a later request, re-creating the very bug this guard was added for;
    // and a backward clock adjustment of 1 ms made a genuine outcome look
    // like it preceded its own request, losing it. Both were measured.
    //
    // Without any ordering guard at all, a `--days` cutoff slicing between a
    // request and its outcome leaves an orphan outcome that a later request
    // sharing the ref consumes — inventing an execution and hiding a real
    // unresolved. Refs are shared exactly when the harness gives no
    // `tool_use_id` and the derived `d:` fallback applies, which is the same
    // population `unresolved` exists to keep honest.
    while (i < q.length && q[i].idx <= r.__idx) i += 1;
    cursor.set(r.ref, i);
    if (i >= q.length) continue;
    cursor.set(r.ref, i + 1);
    verdictFor.set(r.__idx, q[i].verdict);
  }
  // Pass 2 — count only the requests inside the reporting window.
  const requests = sinceIso
    ? allRequests.filter((r) => (r.ts ?? '') >= sinceIso)
    : allRequests;
  for (const r of requests) {
    const v = verdictFor.get(r.__idx);
    if (v === undefined) continue;
    // An unrecognised verdict is surfaced as `other`, never folded into
    // `executed`. Same rule as uncounted_notification_types: a vocabulary this
    // file does not control must show up by name rather than vanish into the
    // most flattering bucket.
    if (v === 'executed' || v === 'executed_failed' || v === 'denied_auto_classifier') outcomes[v] += 1;
    else outcomes.other += 1;
  }
  const resolved = outcomes.executed + outcomes.executed_failed
    + outcomes.denied_auto_classifier + outcomes.other;
  const executedCount = outcomes.executed;

  // Every notification type NOT counted as an interrupt, by name. This is the
  // safety net on the loose match above: if the harness's vocabulary changes,
  // the missed types appear here instead of the gate number quietly reading 0.
  const uncounted = {};
  for (const n of notifications) {
    if (isApprovalInterrupt(n.notification_type)) continue;
    const k = n.notification_type ?? '(none)';
    uncounted[k] = (uncounted[k] ?? 0) + 1;
  }

  const span = observedDays(records, sinceIso, nowIso);
  const collection = collectionHealth(records, sinceIso, nowIso, span);
  const byClass = {};
  const byVerdict = { allow: 0, deny: 0, abstain: 0 };
  for (const r of requests) {
    byClass[r.class] = (byClass[r.class] ?? 0) + 1;
    if (r.shadow_verdict in byVerdict) byVerdict[r.shadow_verdict] += 1;
  }
  return {
    span_days: span,
    requests: requests.length,
    interrupts: interrupts.length,
    // Refuse to extrapolate from a window shorter than a day. A 20-minute
    // sample scaled to a week produces a confident six-figure number that is
    // pure artefact — and this is the one figure the whole programme is gated
    // on, so it has to be null until it is real. The same refusal applies when
    // the ledger is damaged: missing rows understate the rate invisibly, so an
    // unproven chain publishes no rate at all. And the same again for a window
    // with KNOWN dropped writes — the events are gone, the surviving chain still
    // validates, and a rate computed over it would be short by an unknown amount.
    // And the same again when collection itself is unproven for the window
    // (HIMMEL-1547): every condition above stays TRUE while the recorder is
    // simply not running, so without this the instrument publishes its most
    // consequential number — a low one, the one that ends the programme — over
    // a window it never observed.
    interrupts_per_week:
      span >= MIN_EXTRAPOLATION_DAYS && (integrity?.intact ?? true) && droppedWrites === 0
        && collection.proven
        ? +(interrupts.length * 7 / span).toFixed(1)
        : null,
    collection,
    integrity: integrity
      ? {
        intact: integrity.intact,
        malformed: integrity.malformed,
        torn: integrity.torn ?? 0,
        broken_links: integrity.brokenLinks,
        unreadable: integrity.unreadable ?? false,
      }
      : null,
    dropped_writes: droppedWrites,
    health_channel_unreadable: drops.some((d) => d && d.reason === 'health_channel_unreadable'),
    notifications: notifications.length,
    uncounted_notification_types: uncounted,
    // Permission-request EVENTS, from PermissionRequest. NOT a count of human
    // interruptions: the event fires whenever a decision is needed, including
    // in unattended sessions where nobody is present to be interrupted.
    // Reported beside the Notification-derived `interrupts` so the two
    // estimators can be compared on real data; neither is the gate number by
    // fiat.
    permission_request_events: permissionRequests.length,
    executed: executedCount,
    executed_failed: outcomes.executed_failed,
    denied_auto_classifier: outcomes.denied_auto_classifier,
    outcome_other: outcomes.other,
    unresolved: requests.length - resolved,
    shadow_verdicts: byVerdict,
    top_classes: Object.entries(byClass).sort((a, b) => b[1] - a[1]).slice(0, 10),
  };
}

// The OBSERVATION window, not the spread between the first and last event.
// Event spread is biased short at both ends — the first event lands some time
// after the recorder was installed and the last some time before now — and it
// collapses to zero for a quiet week, which would report an infinite-looking
// rate from two adjacent events. Both errors push the rate UP, on the single
// figure the trust programme is gated on. The window runs from `since` (when
// the caller asked for one) or the first record ever seen (the best available
// proxy for install time) through to now.
function windowStartMs(allRecords, sinceIso) {
  const first = allRecords.map((r) => r.ts).filter(Boolean).sort()[0];
  const startIso = sinceIso ?? first;
  if (!startIso) return null;
  // A `--days N` window that predates the ledger is not N days of observation.
  const start = Math.max(Date.parse(startIso), first ? Date.parse(first) : -Infinity);
  return Number.isFinite(start) ? start : null;
}

function observedDays(allRecords, sinceIso, nowIso) {
  const start = windowStartMs(allRecords, sinceIso);
  if (start === null) return 0;
  const ms = Date.parse(nowIso) - start;
  return Number.isFinite(ms) ? Math.max(ms / 86400000, 0) : 0;
}

// Was the collector demonstrably RUNNING, with a COMPLETE hook inventory, for
// the whole reporting window? (HIMMEL-1547)
//
// Two separate questions, because they fail separately and only both together
// protect the number:
//
//   liveness  — heartbeat rows exist, spaced closely enough that no stretch of
//               the window is unaccounted for. A recorder that stops writing
//               stops producing these, while `observedDays` keeps running to
//               NOW and the rate decays smoothly toward zero with nothing to
//               indicate it.
//   inventory — every heartbeat carried ALL the verbs. Five live hooks are
//               enough to grow an intact, healthy-looking window; only `notify`
//               produces approval-interrupt rows. Unwire that one and the
//               instrument publishes a confident 0/week with every integrity
//               signal it owns reading clean.
//
// Note what is deliberately NOT done here: the window is not shortened to the
// last heartbeat. HIMMEL-1529 CR round 1 removed spread-based windows because
// they are biased short at both ends and push the rate UP, and re-introducing
// that bias through a different door would be worse than the defect this
// closes. A window with unproven stretches is refused whole, not trimmed.
//
// `span` defaults to a fresh `observedDays` call so every existing direct
// caller (this file's own tests included) keeps working unchanged, but
// `summarize` — the one caller that also needs the SAME number for
// `span_days` — passes its already-computed value in rather than deriving a
// second copy. Two independent derivations of one window have already drifted
// apart once in this file (see the comment on `windowStartMs`); sharing the
// value is how that stops being possible here too.
export function collectionHealth(allRecords, sinceIso, nowIso, span = observedDays(allRecords, sinceIso, nowIso)) {
  const start = windowStartMs(allRecords, sinceIso);
  const nowMs = Date.parse(nowIso);
  const beats = allRecords
    .filter((r) => r.kind === 'heartbeat' && typeof r.ts === 'string')
    .map((r) => ({ ms: Date.parse(r.ts), inventory: r.hook_inventory }))
    .filter((b) => Number.isFinite(b.ms) && (start === null || b.ms >= start))
    .sort((a, b) => a.ms - b.ms);

  // Union of everything any in-window heartbeat failed to report as wired. A
  // heartbeat whose inventory could not be READ (null) is not evidence of a
  // complete inventory, so it counts as missing everything — same
  // when-unsure-suppress direction as the drops channel.
  const missing = new Set();
  for (const b of beats) {
    const have = Array.isArray(b.inventory) ? b.inventory : [];
    for (const v of EXPECTED_VERBS) if (!have.includes(v)) missing.add(v);
  }

  // Largest unproven stretch, measured across the window's own edges as well as
  // between beats: a fresh heartbeat says nothing about a hole in the middle,
  // and a run of beats early in the window says nothing about right now.
  let maxGapDays = null;
  if (start !== null && Number.isFinite(nowMs) && beats.length > 0) {
    const points = [start, ...beats.map((b) => b.ms), nowMs];
    let widest = 0;
    for (let i = 1; i < points.length; i += 1) {
      widest = Math.max(widest, points[i] - points[i - 1]);
    }
    maxGapDays = Math.max(widest / 86400000, 0);
  }

  // The EFFECTIVE allowance: the absolute cap, or half the window, whichever
  // is smaller. For a window shorter than 14 days this is tighter than
  // HEARTBEAT_MAX_GAP_DAYS — a 7-day window allows only 3.5 unproven days, not
  // 7 — which is exactly what stops one end-of-window heartbeat from
  // certifying the week behind it. See MAX_UNPROVEN_WINDOW_FRACTION above.
  const allowedGapDays = Math.min(HEARTBEAT_MAX_GAP_DAYS, span * MAX_UNPROVEN_WINDOW_FRACTION);

  return {
    heartbeats: beats.length,
    last_heartbeat: beats.length ? new Date(beats[beats.length - 1].ms).toISOString() : null,
    max_gap_days: maxGapDays === null ? null : +maxGapDays.toFixed(2),
    max_gap_allowed_days: HEARTBEAT_MAX_GAP_DAYS,
    // The allowance actually applied to THIS window, distinct from the
    // absolute cap above whenever the window is under 14 days. An operator
    // told "allowed 7d" while the real bound was 3.5d cannot act on the
    // message, so both numbers are reported.
    allowed_gap_days: +allowedGapDays.toFixed(2),
    missing_verbs: [...missing].sort(),
    // NO heartbeat at all is the loudest version of this failure, not the
    // quietest: it is what an unwired collector, a removed settings entry and a
    // recorder that cannot spawn all look like. It must never pass by default
    // just because a short window happens to fit inside the gap allowance.
    proven: beats.length > 0 && missing.size === 0
      && maxGapDays !== null && maxGapDays <= allowedGapDays,
  };
}

function printReport(summary) {
  const l = [];
  l.push('shadow ledger — HIMMEL-1529 R0');
  l.push(`  window            ${summary.span_days.toFixed(1)} days`);
  l.push(`  requests recorded ${summary.requests}`);
  const damaged = summary.integrity && !summary.integrity.intact;
  const dropped = (summary.dropped_writes ?? 0) > 0;
  const coll = summary.collection ?? null;
  // Every reason the rate is withheld, not just the first one found. One label
  // reads as one problem, and an operator who fixes it and sees the rate stay
  // null learns only that the report is opaque.
  const withheld = [];
  if (dropped) withheld.push('WRITES DROPPED');
  if (damaged) withheld.push('LEDGER DAMAGED');
  if (coll && !coll.proven) withheld.push('COLLECTION UNPROVEN');
  if (summary.span_days < MIN_EXTRAPOLATION_DAYS) withheld.push('window under a day — no weekly rate yet');
  l.push(`  APPROVAL INTERRUPTS ${summary.interrupts}` +
    (summary.interrupts_per_week !== null
      ? `  (${summary.interrupts_per_week}/week)`
      : `  (no rate published: ${withheld.join('; ') || 'reason unknown'})`));
  if (damaged && summary.integrity.unreadable) {
    l.push('  ⚠ INTEGRITY  the ledger file EXISTS but could not be read (permissions, I/O, or a');
    l.push('               directory in its place). Nothing below was measured — no rate is published.');
  } else if (damaged) {
    l.push(`  ⚠ INTEGRITY  ${summary.integrity.malformed} unparseable row(s), ` +
      `${summary.integrity.torn} abandoned torn tail(s), ` +
      `${summary.integrity.broken_links} broken chain link(s) —`);
    l.push('               rows are MISSING, so every count below is a floor, not a measurement.');
  }
  if (dropped) {
    l.push(`  ⚠ DROPPED WRITES  ${summary.dropped_writes} event(s) the recorder could not write`);
    l.push('               (see drops.jsonl). The surviving chain still validates — it can only');
    l.push('               attest rows that landed — so these counts are a floor. Drops do NOT');
    l.push('               expire, and deleting drops.jsonl does not make the lost event exist —');
    l.push('               restoring a rate honestly needs the checkpoint in HIMMEL-1547.');
    if (summary.health_channel_unreadable) {
      l.push('               The health channel itself could not be READ, so the drop count is');
      l.push('               a floor on the floor.');
    }
  }
  if (coll) {
    l.push(`  collection        ${coll.heartbeats} heartbeat(s)` +
      (coll.last_heartbeat ? `, last ${coll.last_heartbeat}` : '') +
      (coll.max_gap_days === null ? '' : `, widest unproven gap ${coll.max_gap_days}d`) +
      `  (${coll.proven ? 'PROVEN' : 'UNPROVEN'})`);
    if (!coll.proven) {
      if (coll.heartbeats === 0) {
        l.push('  ⚠ COLLECTION  NO collector heartbeat in this window. The recorder cannot be shown to');
        l.push('               have been running, and the five other hooks would grow an intact,');
        l.push('               healthy-looking window regardless — so no rate is published. Wire the');
        l.push('               SessionStart entry (`himmelctl trust on`) and start a session.');
      } else if (coll.missing_verbs.length) {
        l.push(`  ⚠ COLLECTION  hook(s) NOT wired at heartbeat time: ${coll.missing_verbs.join(', ')} —`);
        l.push('               part of this window was recorded by an incomplete collector. `notify` is');
        l.push('               the ONLY producer of approval-interrupt rows: without it the count is 0');
        l.push('               by construction, not by observation.');
      } else {
        l.push(`  ⚠ COLLECTION  ${coll.max_gap_days}d of this window has no heartbeat behind it ` +
          `(allowed ${coll.allowed_gap_days}d) —`);
        l.push('               the collector either stopped or was never loaded for that stretch. The');
        l.push('               window is NOT trimmed to fit (that bias inflates the rate); the rate is');
        l.push('               refused whole instead.');
      }
    }
  }
  const un = Object.entries(summary.uncounted_notification_types ?? {});
  if (un.length) {
    l.push(`  other notifications ${un.map(([k, v]) => `${k}=${v}`).join(' ')}   (NOT counted as interrupts)`);
  }
  if (summary.permission_request_events !== undefined) {
    l.push(`  permission-request events ${summary.permission_request_events}   (a decision was NEEDED —`);
    l.push('                        NOT proof anyone was interrupted; unattended sessions fire this too)');
  }
  l.push(`  executed          ${summary.executed}`);
  l.push(`  executed (failed) ${summary.executed_failed ?? 0}   (ran and failed — NOT an approval interrupt)`);
  l.push(`  denied (auto)     ${summary.denied_auto_classifier ?? 0}   (AUTO-MODE CLASSIFIER denials ONLY —`);
  l.push('                        manual denials, deny rules and PreToolUse blocks do NOT appear here)');
  if ((summary.outcome_other ?? 0) > 0) {
    l.push(`  outcome (other)   ${summary.outcome_other}   (UNRECOGNISED verdict — vocabulary changed?)`);
  }
  // Denials and failures are only observed if their hooks are wired, and even
  // wired, PermissionDenied covers ONE denial source. This file cannot tell a
  // wired-and-quiet harness from an unwired one, so the caveat stays rather
  // than claiming a completeness the events do not provide.
  l.push(`  unresolved        ${summary.unresolved}   (no terminal outcome seen — stranded, crashed,`);
  l.push('                        a non-auto-classifier denial, or an unwired failure/denial hook)');
  l.push(`  shadow verdicts   allow=${summary.shadow_verdicts.allow} deny=${summary.shadow_verdicts.deny} abstain=${summary.shadow_verdicts.abstain}`);
  l.push('  NOTE: agreement rate is dominated by the abstain class and is NOT the');
  l.push('        gate number. The gate number is APPROVAL INTERRUPTS per week.');
  if (summary.top_classes.length) {
    l.push('  top classes:');
    for (const [k, v] of summary.top_classes) l.push(`    ${String(v).padStart(5)}  ${k}`);
  }
  return l.join('\n');
}

// --- main --------------------------------------------------------------------

function main(argv) {
  const cmd = argv[0];
  const now = new Date().toISOString();

  if (cmd === 'report') {
    const days = Number(argv[argv.indexOf('--days') + 1]);
    const since = argv.includes('--days') && Number.isFinite(days)
      ? new Date(Date.now() - days * 86400000).toISOString()
      : null;
    const led = readLedger();
    const summary = summarize(led.records, since, new Date().toISOString(), led, readDrops());
    process.stdout.write(argv.includes('--json')
      ? `${JSON.stringify(summary, null, 2)}\n`
      : `${printReport(summary)}\n`);
    return 0;
  }

  // Hook paths from here down. Every one of them is fail-open and silent.
  const payload = parsePayload();
  if (!payload) return 0;
  try {
    fs.mkdirSync(ledgerDir(), { recursive: true });
  } catch {
    return 0;
  }
  if (cmd === 'pre') cmdPre(payload, now);
  else if (cmd === 'post') cmdPost(payload, now);
  else if (cmd === 'postfail') cmdPostFailure(payload, now);
  else if (cmd === 'denied') cmdDenied(payload, now);
  else if (cmd === 'permreq') cmdPermissionRequest(payload, now);
  else if (cmd === 'notify') cmdNotify(payload, now);
  else if (cmd === 'heartbeat') cmdHeartbeat(payload, now);
  return 0;
}

// Never let a throw escape into the hook's exit code: a non-zero PreToolUse exit
// BLOCKS the tool call, which is the one thing this file must never do.
if (import.meta.url === `file://${process.argv[1]}` ||
    process.argv[1]?.endsWith('shadow-ledger.mjs')) {
  const argv = process.argv.slice(2);
  let code = 0;
  try {
    code = main(argv);
  } catch (e) {
    // Fail-open is a HOOK contract: a non-zero PreToolUse exit blocks the tool
    // call. `report` is not a hook — it is the operator reading the instrument,
    // and swallowing its exceptions turned ledger corruption into exit 0 with
    // empty stdout, which reads as "nothing to report" rather than "could not
    // report". Silence is the one answer this file must never give about
    // itself.
    if (argv[0] === 'report') {
      process.stderr.write(`shadow-ledger report FAILED: ${e && e.message ? e.message : e}\n`);
      code = 1;
    } else {
      code = 0;
    }
  }
  // `process.exitCode`, NOT `process.exit()`. `report` writes its output to
  // stdout, and process.exit() can truncate a pending write when stdout is a
  // pipe — which is how this is always read in practice. Truncating the report
  // would reintroduce exactly the silence rounds 6 and 7 closed, by a different
  // mechanism. Setting the code and letting Node exit naturally flushes first.
  process.exitCode = code;
}
