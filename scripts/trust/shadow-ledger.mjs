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
//   node shadow-ledger.mjs notify   < Notification payload
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

export function cmdPost(payload, now) {
  const tool = payload.tool_name ?? '';
  if (!RECORDED_TOOLS.includes(tool)) return null;
  const cls = classify(tool, payload.tool_input ?? {});
  // The DECISION, recorded alongside the event. A Pre/Post pair alone cannot
  // tell denied from stranded from crashed, so `executed` is asserted only
  // where it is observed; the absence of this row is never read as "denied".
  return append({
    ts: now,
    kind: 'outcome',
    ref: refFor(payload, cls),
    session_id: payload.session_id ?? null,
    actual_verdict: 'executed',
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
export function readLedger(file = ledgerPath()) {
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    return { records: [], malformed: 0, brokenLinks: 0, intact: true };
  }
  const lines = text.split('\n');
  const records = [];
  let malformed = 0;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line.trim()) continue;
    try {
      records.push(JSON.parse(line));
    } catch {
      // An unterminated FINAL line is a torn in-flight append and is expected.
      // Anywhere else it is real damage and must be counted, not swallowed.
      if (i !== lines.length - 1) malformed += 1;
    }
  }
  let brokenLinks = 0;
  let prev = GENESIS;
  for (const r of records) {
    if (r.prev_hash !== prev || r.hash !== chainHash(r.prev_hash, r)) brokenLinks += 1;
    prev = r.hash;
  }
  return { records, malformed, brokenLinks, intact: malformed === 0 && brokenLinks === 0 };
}

export function summarize(records, sinceIso, nowIso = new Date().toISOString(), integrity = null) {
  const rows = sinceIso ? records.filter((r) => (r.ts ?? '') >= sinceIso) : records;
  const requests = rows.filter((r) => r.kind === 'request');
  const notifications = rows.filter((r) => r.kind === 'notification');
  const interrupts = notifications.filter((r) => isApprovalInterrupt(r.notification_type));

  // COUNT outcomes per ref rather than testing set membership. Membership lets
  // ONE outcome mark every request sharing that ref as executed, which silently
  // undercounts unresolved prompts — and refs are shared whenever the harness
  // gives us no `tool_use_id` and we fall back to a derived (`d:`) hash. Two
  // identical calls with one success are one executed and one unresolved, and
  // this is the field whose whole job is to keep that distinction.
  const outcomesByRef = new Map();
  for (const r of rows) {
    if (r.kind === 'outcome') outcomesByRef.set(r.ref, (outcomesByRef.get(r.ref) ?? 0) + 1);
  }
  const budget = new Map(outcomesByRef);
  let executedCount = 0;
  for (const r of requests) {
    const left = budget.get(r.ref) ?? 0;
    if (left > 0) {
      budget.set(r.ref, left - 1);
      executedCount += 1;
    }
  }

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
    // unproven chain publishes no rate at all.
    interrupts_per_week: span >= MIN_EXTRAPOLATION_DAYS && (integrity?.intact ?? true)
      ? +(interrupts.length * 7 / span).toFixed(1)
      : null,
    integrity: integrity
      ? { intact: integrity.intact, malformed: integrity.malformed, broken_links: integrity.brokenLinks }
      : null,
    notifications: notifications.length,
    uncounted_notification_types: uncounted,
    executed: executedCount,
    unresolved: requests.length - executedCount,
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
function observedDays(allRecords, sinceIso, nowIso) {
  const first = allRecords.map((r) => r.ts).filter(Boolean).sort()[0];
  const startIso = sinceIso ?? first;
  if (!startIso) return 0;
  // A `--days N` window that predates the ledger is not N days of observation.
  const start = Math.max(Date.parse(startIso), first ? Date.parse(first) : -Infinity);
  const ms = Date.parse(nowIso) - start;
  return Number.isFinite(ms) ? Math.max(ms / 86400000, 0) : 0;
}

function printReport(summary) {
  const l = [];
  l.push('shadow ledger — HIMMEL-1529 R0');
  l.push(`  window            ${summary.span_days.toFixed(1)} days`);
  l.push(`  requests recorded ${summary.requests}`);
  const damaged = summary.integrity && !summary.integrity.intact;
  l.push(`  APPROVAL INTERRUPTS ${summary.interrupts}` +
    (summary.interrupts_per_week !== null
      ? `  (${summary.interrupts_per_week}/week)`
      : damaged
        ? '  (LEDGER DAMAGED — no rate published)'
        : '  (window under a day — no weekly rate yet)'));
  if (damaged) {
    l.push(`  ⚠ INTEGRITY  ${summary.integrity.malformed} unreadable row(s), ` +
      `${summary.integrity.broken_links} broken chain link(s) — rows are MISSING, so every`);
    l.push('               count below is a floor, not a measurement.');
  }
  const un = Object.entries(summary.uncounted_notification_types ?? {});
  if (un.length) {
    l.push(`  other notifications ${un.map(([k, v]) => `${k}=${v}`).join(' ')}   (NOT counted as interrupts)`);
  }
  l.push(`  executed          ${summary.executed}`);
  l.push(`  unresolved        ${summary.unresolved}   (denied OR stranded OR crashed — not distinguishable)`);
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
    const summary = summarize(led.records, since, new Date().toISOString(), led);
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
  else if (cmd === 'notify') cmdNotify(payload, now);
  return 0;
}

// Never let a throw escape into the hook's exit code: a non-zero PreToolUse exit
// BLOCKS the tool call, which is the one thing this file must never do.
if (import.meta.url === `file://${process.argv[1]}` ||
    process.argv[1]?.endsWith('shadow-ledger.mjs')) {
  let code = 0;
  try {
    code = main(process.argv.slice(2));
  } catch {
    code = 0;
  }
  process.exit(code);
}
