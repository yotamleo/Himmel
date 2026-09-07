#!/usr/bin/env node
// stop-queue.mjs — a durable keyed queue plus ONE bounded worker for the
// end-of-session side-effect work Stop/SessionEnd hooks used to fire off
// themselves (HIMMEL-2004, P2 item 8 of the RAM program).
//
// WHY. Every end-side hook in this repo already returns instantly: each one
// spawns its real body DETACHED (scripts/lib/detach.sh) so it cannot trip the
// harness teardown budget. That fixed latency and created the opposite problem
// — the detached work is UNBOUNDED. A fleet of N children ending at once fans
// out N independent trees (bun, git, curl, node), each doing file-handle churn,
// and HIMMEL-1993 measured this box's kernel pool leaking in proportion to
// exactly that churn. Nothing throttles them, nothing dedups a repeated
// session, and a session that dies mid-flight loses its work silently.
//
// WHAT THIS IS. A directory of entry files plus a single worker process:
//   enqueue  write one entry atomically (tmp + rename), spawn the worker if
//            none is live, exit. Well under a second, no work done inline.
//   work     take the singleton lock (mkdir), drain entries oldest-first ONE
//            AT A TIME, then exit. A second worker refuses to start.
//   status   report-only census: what is pending, what the log says ran,
//            expired or was abandoned. Never mutates.
//
// The bound is the point: concurrency is 1 by construction (one worker, one
// job at a time), so N ending children cost one drain, not N trees.
// ponytail: the bound is the lock, not a pool — if these jobs ever need to
// overlap, give the lock N slots rather than growing a scheduler here.
//
// DURABILITY. An entry is a file. It survives the enqueuer exiting, the worker
// being killed, and the session dying: the next enqueue starts a worker that
// finds it still there. Nothing is dropped silently — a TTL-expired entry, an
// entry that has failed its attempt budget and a malformed entry each write a
// log row before they are removed. That log is the census surface.
//
// SECRETS. An entry file records argv, so a caller must never enqueue a command
// whose ARGUMENTS carry a credential. This is why scripts/lib/detach.sh routes
// only the outer, self-re-exec detach through the queue (argv = a script path
// and a payload file) and leaves the inner relay calls — a curl whose URL holds
// a bot token — running inline inside the worker instead. The environment an
// entry carries is a narrow prefix allowlist with a secret denylist over it
// (see snapshotEnv): the gate and path variables a job needs to behave as its
// OWN session would, never the session's credentials, which every one of these
// hooks loads from a .env inside the job at run time.
//
// The third thing an entry stores is the hook PAYLOAD, and it is worth being
// explicit that this is not a conversational-content channel: an end-side hook
// payload is `{session_id, transcript_path, cwd, hook_event_name}` — the
// transcript arrives as a PATH the job opens for itself, never as text. So what
// lands on disk here is harness metadata, at 0600, under the operator's own
// home. A caller that ever pipes real content into an enqueue would be changing
// that contract and should redact before it does.
//
// KNOWN CEILINGS, both consequences of a queue that can hold work for minutes:
// ponytail: AT-LEAST-ONCE, not exactly-once. runEntry persists the incremented
//   attempt BEFORE running and deletes the entry AFTER, so a worker killed
//   between those two points leaves the job to be re-run. That is the safe
//   direction for this work (ledger refreshes and status notifies are
//   idempotent enough) and the alternative loses work on every crash. Upgrade
//   path if a non-idempotent job ever joins: a per-entry "started" marker the
//   next worker treats as done-unless-proven-otherwise.
// ponytail: a caller that hands a TEMP FILE PATH in argv (the end-side hooks
//   pass their saved payload that way) leaks that file if the entry expires or
//   is abandoned instead of running — the job is what deletes it. Bounded by
//   the TTL and only reachable when the queue never drains at all. Upgrade
//   path: pipe those payloads through the enqueue's stdin, which the entry
//   already stores, and drop the temp file from argv entirely.
//
// STDLIB ONLY, node 24. No deps, by design: this runs on every session end.

import { spawn } from 'node:child_process';
import {
  mkdirSync, writeFileSync, readFileSync, readdirSync, renameSync, rmSync,
  openSync, closeSync, writeSync, statSync, existsSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID, createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { killTree, SPAWN_OWN_GROUP } from '../lib/kill-tree.mjs';

// Returned by main() when the process must NOT be force-exited — some work is
// still draining on the event loop (see the detached fallback in enqueue).
export const EXIT_NATURALLY = Symbol('exit-naturally');

// This file's own path, for the successor-worker handoff in work().
const SELF_PATH = fileURLToPath(import.meta.url);

// An entry older than this is STALE work — the session it belonged to is long
// gone and running it now helps nobody. It must comfortably exceed the worst
// realistic drain, or a legitimate BACKLOG expires its own tail before the
// worker reaches it: at 15 minutes, nine jobs each hitting the 120-second
// timeout would do exactly that, discarding queued work that was never even
// attempted. One hour is far past any real end-of-session drain (these hooks
// take seconds) while still bounding genuinely abandoned entries.
export const DEFAULT_TTL_MS = 60 * 60 * 1000;
export const DEFAULT_JOB_TIMEOUT_MS = 120 * 1000;  // one job may not wedge the drain
export const MAX_ATTEMPTS = 3;                     // CRASH budget only — see runEntry
export const STALE_LOCK_MS = 30 * 60 * 1000;       // belt-and-braces over the pid check
export const MAX_PAYLOAD_BYTES = 4 * 1024 * 1024;  // a hook payload is small JSON; this is a tripwire
const MAX_LOG_BYTES = 2 * 1024 * 1024;
// A job's stderr is accumulated in memory and only its first 500 characters
// are ever logged, so the buffer is bounded rather than unbounded: a chatty job
// must not be able to grow the worker's heap, and — unlike spawnSync's
// maxBuffer — overflowing this is not an error, it just stops collecting. That
// distinction matters: an ENOBUFS turned a merely NOISY job into one this
// worker read as "never finished" and retried, repeating its side effects.
const STDERR_CAP = 64 * 1024;
// How long a reaped job gets to actually close before the deadline is enforced
// anyway. The reap is what should end it; this only bounds the case where the
// reap did not take (see runJob). Short, because by this point the job has
// already had its whole timeout.
const REAP_GRACE_MS = 5 * 1000;
const LOG_KEEP_LINES = 2000;

// Resolution mirrors the ci-queue / flow-run ledgers: one explicit override,
// else a fixed dir under $HOME/.himmel. Deliberately NOT under the repo — the
// queue must outlive a worktree being pruned mid-drain.
export function queueDir(env = process.env) {
  if (env.HIMMEL_STOP_QUEUE_DIR) return env.HIMMEL_STOP_QUEUE_DIR;
  return join(env.HOME || homedir(), '.himmel', 'stop-queue');
}

const paths = (dir) => ({
  entries: join(dir, 'entries'),
  running: join(dir, 'running'),
  tmp: join(dir, 'tmp'),
  attempts: join(dir, 'attempts'),
  lock: join(dir, 'worker.lock'),
  lockPid: join(dir, 'worker.lock', 'pid'),
  log: join(dir, 'queue.jsonl'),
});

// argv reaches spawn directly, and a non-string element makes it THROW —
// which would crash the worker on every pass and leave the entry poisoning the
// queue. Validate the shape so a malformed entry is reported and removed like
// any other corrupt one.
function validArgv(argv) {
  return Array.isArray(argv) && argv.length > 0 && argv.every((a) => typeof a === 'string');
}

// `cwd` is handed to existsSync and then to spawn, and BOTH throw on a
// non-string. An entry that is valid JSON but carries, say, a number there
// would crash the worker on every drain while staying in place — a poison pill
// that never gets logged as one. Validated at read time so it is reported and
// removed like any other corrupt entry.
function validCwd(cwd) {
  return typeof cwd === 'string' && cwd.length > 0;
}

// A key becomes a filename, so it may not contain a separator or traversal.
// Anything else collapses to `_` rather than erroring: the caller is a hook and
// a rejected enqueue would lose the work it was trying to protect.
export function sanitizeKey(key) {
  const raw = String(key || '');
  const clean = raw.replace(/[^A-Za-z0-9._-]/g, '_').replace(/^\.+/, '');
  if (!clean) return 'unkeyed';   // nothing to distinguish; a digest of "" helps nobody
  const safe = clean.slice(0, 100);
  // Sanitising is LOSSY — `a/b` and `a\b` both flatten to `a_b`, and a long id
  // truncates — so two unrelated sessions could land on one filename and be
  // deduped into each other. Any input the flattening changed gets a short
  // digest of the ORIGINAL appended, which restores the distinction. An input
  // that was already filename-safe is left exactly as it was, so the common
  // case (a UUID session id) reads unchanged.
  if (safe === raw) return safe;
  return `${safe}-${createHash('sha256').update(raw).digest('hex').slice(0, 8)}`;
}

// The dedup identity. One entry per (hook, session): a fleet of N children
// yields N entries because each carries its own session id, while the SAME
// hook re-firing for one session replaces its own entry instead of piling up.
// Replacement keeps the newest payload on purpose — by the time the worker
// reaches it, an older payload for the same session is stale, not lost work.
//
// With NO identifiable session the key gets a unique suffix instead, so two
// callers never collapse into one entry. Dedup is an optimisation; dropping
// work is not, and a caller that hands us no payload (detach_queued, whose
// parent has already drained stdin) would otherwise silently overwrite a
// sibling session's queued job.
export function entryKey(name, payload) {
  let session = '';
  try {
    session = String(JSON.parse(payload || '{}').session_id || '');
  } catch { /* a non-JSON payload just means no session dimension */ }
  // A pid + millisecond pair is NOT unique: one process enqueuing the same hook
  // twice inside a millisecond would collide and silently dedup two unrelated
  // jobs into one. Random bits are what make "no session" mean "never merge".
  const suffix = session || `${process.pid}-${randomUUID().slice(0, 8)}`;
  return sanitizeKey(`${name}.${suffix}`);
}

// The env a queued job needs, and NOTHING else.
//
// A job cannot simply inherit the worker's environment: the worker is spawned by
// whichever session enqueued FIRST, so a later session's job would run under an
// earlier session's gates — the hook firing when its session had it switched
// off, or writing to the wrong state dir. Both are wrong answers that look like
// success. So the enqueuer snapshots the gate/path variables into the entry and
// the worker overlays them per job.
//
// The snapshot is a PREFIX ALLOWLIST, not "everything minus secrets": the
// end-side hooks read their gates and test seams from these namespaces, and
// their credentials come from a .env loaded inside the job at run time, never
// from the session environment. The denylist is a second fence for the names
// that do land in these namespaces and must never reach disk anyway.
const ENV_PREFIXES = /^(HIMMEL_|CLAUDE_|VOICE_|WHERE_ARE_WE_|JIRA_NUDGE_|DETACH_)/;
// Not a gate, but the same argument applies with more force: these decide WHICH
// interpreter a job runs and where it looks for its state. Inheriting them from
// whichever session happened to start the worker means a later session's job can
// resolve a different node/bun/bash than its own environment names — or fail to
// find one it definitely has. None of them is a credential.
const ENV_ALWAYS = ['PATH', 'Path', 'HOME', 'USERPROFILE', 'TMPDIR', 'TEMP', 'TMP'];

// The SYSTEM half of the base (HIMMEL-2030). Everything a job inherits from the
// worker must be named here or by snapshotOwns(); nothing else crosses. These
// are machine constants — which interpreter runs, where it finds its own
// config, how the OS resolves a path — never per-session state and never a
// credential.
//
// Enumerated empirically on Windows Git-Bash (the reference box): node, bun,
// git, curl and bash were each run under `env -i` with progressively fewer
// names, and every one of the five queued end-side hooks was exercised through
// its suite the same way. On that box PATH plus HOME is genuinely enough — the
// interpreters all fall back. The rest of this list is the portability margin,
// each name earning its place because SOME supported box resolves differently
// without it; the cost of a spurious entry is one machine constant crossing,
// the cost of a missing one is a job that fails only on one operator's laptop.
//
// Match is case-insensitive: Windows hands these back as `windir`,
// `ProgramFiles(x86)`, `CommonProgramW6432` and friends.
const ENV_SYSTEM = new Set([
  // --- Windows: the OS's own roots ---
  'SYSTEMROOT',   // Win32/winsock/crypto DLL resolution; uv's tmpdir fallback
  'SYSTEMDRIVE',  // resolves drive-relative paths and MSYS `/` translation
  'WINDIR',       // the same root under the older name; some tools read only this
  'COMSPEC',      // cmd.exe — anything spawning with `shell: true` resolves it
  'PATHEXT',      // without it a .cmd/.bat shim on PATH (npm, bun, gh) is invisible
  'PROGRAMDATA',  // machine-wide tool config (git's system config lives here)
  'PROGRAMFILES', 'PROGRAMFILES(X86)', 'PROGRAMW6432', // install roots tools self-locate from
  'HOMEDRIVE', 'HOMEPATH',   // Windows home when HOME is unset (cmd-launched tools)
  'APPDATA', 'LOCALAPPDATA', // per-user config/cache roots: gh, git, bun, npm
  'USERNAME',                // identity; git's fallback author and %USERNAME% expansions
  'NUMBER_OF_PROCESSORS',    // os.cpus()/parallelism on Windows
  'PROCESSOR_ARCHITECTURE',  // arch detection in installer shims
  'OS',                      // MSYS scripts branch on OS=Windows_NT
  'EXEPATH',                 // Git-for-Windows install root, set by its own profile
  // --- POSIX ---
  'SHELL',        // the interpreter a script re-execs
  'TERM',         // a terminal-library tool aborts outright on an unset TERM
  'LOGNAME', 'USER', 'HOSTNAME', // identity: git author fallback, ssh default user
  'LANG',         // locale — under C, the non-ASCII transcript text these jobs read is mangled
  'TZ',           // local timestamps in the ledger rows these jobs write
  'BUN_INSTALL',  // bun's own root — the session-run-end job IS a bun job
  // --- fixed namespaces, spelled out rather than matched by prefix ---
  // A prefix inside an allowlist is a denylist wearing a costume: `^XDG_` also
  // admits XDG_MQTT_PASS, and `PASS` is not one of the shapes the fence below
  // knows — the exact hole this ticket exists to close. Every one of these
  // namespaces is a FIXED set (POSIX locale, the freedesktop base-dir spec,
  // MSYS, the version managers), so enumerating costs nothing but length.
  'LC_ALL', 'LC_CTYPE', 'LC_COLLATE', 'LC_MESSAGES', 'LC_MONETARY', 'LC_NUMERIC', 'LC_TIME',
  'XDG_CACHE_HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_RUNTIME_DIR',
  'MSYS', 'MSYSTEM', 'MSYSTEM_PREFIX', 'MSYSTEM_CHOST', 'MSYS2_ARG_CONV_EXCL', 'MSYS_NO_PATHCONV',
  'NVM_DIR', 'NVM_BIN', 'NVM_INC', 'NVM_HOME', 'NVM_SYMLINK',
  'FNM_DIR', 'FNM_MULTISHELL_PATH', 'VOLTA_HOME', 'ASDF_DIR', 'ASDF_DATA_DIR',
]);
// Deliberately NOT here: SSH_AUTH_SOCK. A job reaching an ssh remote would want
// it, but the denylist below matches AUTH and has stripped it since the queue
// existed — so leaving it out changes nothing, while letting it through would
// need an ENV_NOT_SECRET exception for a live authority handle. The hatch
// cannot restore it either (the fence runs after): granting a job an agent
// socket is its own decision, not this one.
//
// One escape hatch, because no enumeration survives contact with an exotic
// platform: a comma-separated list of extra variable NAMES a job needs. It
// widens what the SNAPSHOT carries, not what the base inherits — see
// snapshotEnv. Naming a variable here therefore writes its VALUE into the entry
// file, so name platform constants, never a credential.
// ponytail: the denylist fences the obvious shapes, so the ceiling is an
// operator who names a credential whose NAME it does not match — the motivating
// GGS_MQTT_PASS shape — and thereby writes it into a queue entry. That is the
// same class of mistake as putting one in argv, which this file already refuses
// to defend against by pattern; no rule here can tell a platform constant from
// a secret by looking at its name. Upgrade path if it ever matters: make the
// hatch carry a VALUE the enqueuer supplies rather than a name it copies.
const ENV_EXTRA_VAR = 'HIMMEL_STOP_QUEUE_ENV_EXTRA';
// Case-insensitive, like ENV_SYSTEM and for the same reason: Windows
// environment names are case-insensitive, so an operator who writes
// `MyApp_Root` in the hatch and has `MYAPP_ROOT` in their environment would
// otherwise get a silent no-op from a setting that looks correct.
function extraNames(env) {
  return new Set(String(env[ENV_EXTRA_VAR] || '')
    .split(',').map((n) => n.trim().toUpperCase()).filter(Boolean));
}
// ONE list of secret-looking name shapes, shared by the environment denylist
// and the stderr redactor below. Two separate lists drift, and the drift is
// silent in the worst direction: a name the env fence strips would still be
// printed verbatim into the durable log.
// ponytail: still shape-based, and still unable to be exhaustive — but since
// HIMMEL-2030 it is the SECOND fence, not the control. Completeness now belongs
// to the allowlist above, whose own ceiling is the opposite one: it can be too
// NARROW on a platform this enumeration never saw. That failure is visible (a
// job fails) rather than silent, and ENV_EXTRA_VAR is its upgrade path.
const SECRET_NAME_SHAPES = 'TOKEN|SECRET|KEY|PASSWORD|PASSWD|CREDENTIAL|COOKIE|AUTH|CHAT_ID|DSN|_URL|CONNECTION|PRIVATE|CERT|BEARER|SIGNATURE|SESSION_ID';
const ENV_SECRET = new RegExp(`(${SECRET_NAME_SHAPES}|(^|_)PAT($|_))`, 'i');
const NAMED_SECRET_ASSIGNMENT = new RegExp(
  `([A-Za-z0-9_]*(?:${SECRET_NAME_SHAPES})[A-Za-z0-9_]*\\s*[=:]\\s*)\\S+`, 'gi',
);

// Names the denylist matches that are NOT credentials. `KEY` has to stay broad
// enough to catch ANTHROPIC_API_KEY, and no name-shaped rule can tell that
// apart from JIRA_PROJECT_KEY — a project identifier the Jira hook reads. An
// explicit exception is honest about that; widening the pattern to guess would
// not be. Keep this list short and only for names verified non-secret.
const ENV_NOT_SECRET = new Set(['JIRA_PROJECT_KEY', 'TICKET_ID_PATTERN']);

// The SECOND fence, not the base (HIMMEL-2030 inverted the base to the
// allowlist above). It runs over the job's finished environment, which catches
// what an allowlist alone cannot: an entry file written by an older version, or
// edited on disk, whose snapshot carries a secret-shaped name. Anything
// genuinely needed by a job is either in the entry's own snapshot or in the
// .env each hook loads itself.
export function scrubSecrets(env = process.env) {
  const out = {};
  for (const [name, value] of Object.entries(env)) {
    if (typeof value !== 'string') continue;
    if (ENV_SECRET.test(name) && !ENV_NOT_SECRET.has(name)) continue;
    out[name] = value;
  }
  return out;
}

// Names the SNAPSHOT owns. Everything matching this comes from the enqueuing
// session or not at all — see jobEnv.
//
// ENV_SYSTEM is here too since HIMMEL-2030 (CR r4). Calling those names
// "machine constants" was only half true: TZ, LANG, the LC_* set, XDG_* (where
// a tool looks for its config — a credential STORE, on Linux) and the
// version-manager roots are all per-SESSION, so inheriting them from the worker
// handed a job another session's configuration. With them owned, a snapshotted
// entry inherits NOTHING from the worker — the base is empty and every value a
// job sees came from the session that queued it, which is the strongest form of
// what this ticket asked for. The cost is one upgrade window: an entry queued
// by the PREVIOUS version has a snapshot without these names, so its job runs
// without them for up to the TTL. Measured on Windows Git-Bash, node/bun/git/
// curl/bash all run on PATH plus HOME alone — both of which those older
// snapshots do carry — so that window degrades to nothing observable.
export function snapshotOwns(name) {
  const upper = name.toUpperCase();
  // Case-insensitive throughout, like ENV_SYSTEM: Windows environment names
  // are, and a missed casing here is not a leak but the other failure — a job
  // handed no PATH at all.
  return ENV_ALWAYS.some((n) => n.toUpperCase() === upper) || ENV_NOT_SECRET.has(name)
    || ENV_SYSTEM.has(upper) || ENV_PREFIXES.test(name);
}

// The environment a job runs under. The snapshot is AUTHORITATIVE over the
// names it owns, which means absence is data: a gate the enqueuing session did
// not set must not be inherited from the worker's session either. Overlaying
// alone is not enough — session A sets HIMMEL_JIRA_NUDGE=1, session B does not,
// and B's job would fire a nudge its own session had switched off. So the base
// is stripped of every owned name first, then the entry's snapshot is applied,
// and scrubSecrets runs over the result as a second fence.
//
// Since the system set became snapshot-owned (CR r4) those two rules collapse
// into one for a snapshotted entry: EVERY name the base could carry is owned,
// so the base ends up empty and nothing at all crosses from the worker. The
// loop still reads as an allowlist rather than a `return scrubSecrets(entryEnv)`
// because the legacy branch below genuinely needs it.
export function jobEnv(entryEnv = {}, workerEnv = process.env) {
  // An entry with NO snapshot at all cannot be treated as authoritative — it
  // predates the snapshot (an entry queued before an upgrade, still inside its
  // TTL). Stripping the owned names for it would hand the job an environment
  // with no PATH and no HOME, which fails far worse than inheriting does.
  const authoritative = Object.keys(entryEnv).length > 0;
  const base = {};
  if (!authoritative) {
    for (const [name, value] of Object.entries(workerEnv)) {
      if (typeof value !== 'string') continue;
      // EXACT names only — deliberately NOT snapshotOwns, whose ENV_PREFIXES
      // half is a wildcard: `^HIMMEL_` also admits HIMMEL_MQTT_PASS, and PASS
      // is not one of the denylist's shapes (CR r5). Nor do the worker's own
      // gates belong here: they are another session's answer, which is the bug
      // the snapshot exists to prevent. All this branch owes a pre-snapshot
      // entry is enough environment to RUN.
      const upper = name.toUpperCase();
      if (!ENV_SYSTEM.has(upper) && !ENV_ALWAYS.some((n) => n.toUpperCase() === upper)) continue;
      base[name] = value;
    }
  }
  return scrubSecrets({ ...base, ...entryEnv, HIMMEL_DETACH_INLINE: '1' });
}

export function snapshotEnv(env = process.env) {
  // The hatch widens the SNAPSHOT, not the base (HIMMEL-2030, CR r3). Widening
  // the base would have taken the NAME from the enqueuing session and the VALUE
  // from whichever session started the worker — so a job would get another
  // session's value for a name its own session chose, the same cross-session
  // mix-up the snapshot exists to prevent.
  const extra = extraNames(env);
  const out = {};
  for (const [name, value] of Object.entries(env)) {
    if (typeof value !== 'string') continue;
    if (extra.has(name.toUpperCase()) && !ENV_SECRET.test(name)) { out[name] = value; continue; }
    // ENV_NOT_SECRET names are session CONFIGURATION (JIRA_PROJECT_KEY and
    // friends), so they belong in the entry like any other gate — otherwise a
    // job inherits the project key of whichever session started the worker
    // rather than its own, which is the exact cross-session bug the snapshot
    // exists to prevent. They are excepted from the denylist here for the same
    // reason scrubSecrets excepts them.
    if (!snapshotOwns(name)) continue;
    if (ENV_SECRET.test(name) && !ENV_NOT_SECRET.has(name)) continue;
    out[name] = value;
  }
  return out;
}

// One entry read, or null. Used where a MISSING or malformed file is an
// ordinary outcome rather than something to report.
function readEntry(file) {
  try { return JSON.parse(readFileSync(file, 'utf8')); } catch { return null; }
}

// Each directory is created independently and a failure on one does NOT abort
// the rest. A single unusable path (a file sitting where a directory belongs)
// would otherwise throw straight out of work() and kill the worker before it
// could do anything at all — including the graceful degradations every writer
// below already implements for exactly this case. The writers report their own
// failures; this only has to get out of their way.
//
// enqueue is the exception and checks for itself: it needs `entries` and `tmp`
// to exist, and it turns their absence into a failed enqueue, which is what
// makes the caller fall back rather than silently lose the work.
export function ensureDirs(dir) {
  const p = paths(dir);
  for (const target of [p.entries, p.running, p.attempts, p.tmp]) {
    try { mkdirSync(target, { recursive: true, mode: 0o700 }); } catch { /* the writer reports it */ }
  }
  return p;
}

// A job's stderr goes into a DURABLE file, so a hook that prints a credential
// it loaded at runtime would persist it. The diagnostic value of stderr is
// worth keeping — it is how a failing job gets debugged — so redact rather than
// drop: NAME=VALUE pairs whose name looks secret, bare long tokens, and the two
// URL shapes that carry a secret in the path.
// ponytail: shape-based, so a credential in an unguessable shape still gets
// through. Same class of fence as ENV_SECRET, and the same reasoning: a
// tripwire for what actually occurs, not a proof.
export function redactSecrets(text) {
  return String(text)
    .replace(NAMED_SECRET_ASSIGNMENT, '$1<redacted>')
    .replace(/(https?:\/\/[^\s/]*\/bot)[^\s/]+/gi, '$1<redacted>')
    .replace(/\b(?:gh[pousr]|xox[baprs])_[A-Za-z0-9_-]{10,}/g, '<redacted>')
    .replace(/\b[A-Za-z0-9_-]{40,}\b/g, '<redacted>');
}

// O_APPEND single-line writes, the same integrity contract the other himmel
// ledgers rest on. Never throws: a hook must not fail because logging did.
export function logRow(dir, row) {
  try {
    const p = paths(dir);
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    const fd = openSync(p.log, 'a', 0o600);
    try {
      writeSync(fd, JSON.stringify({ ts: new Date().toISOString(), ...row }) + '\n');
    } finally {
      closeSync(fd);
    }
  } catch { /* best effort */ }
}

// ponytail: trimming rewrites the log, and an enqueuer appending between the
// read and the swap loses its row. Accepted: this is the CENSUS log, not the
// durable work — entries are files and are unaffected — and it only happens
// above 2MB. The swap is at least atomic (tmp + rename), so no reader ever sees
// a half-written log. Upgrade path if the census ever has to be lossless: trim
// under the worker lock AND make enqueue take it for the append.
function trimLog(dir) {
  try {
    const p = paths(dir);
    if (statSync(p.log).size <= MAX_LOG_BYTES) return;
    const lines = readFileSync(p.log, 'utf8').split('\n').filter(Boolean);
    const tmp = join(p.tmp, `queue.jsonl.${process.pid}.trim`);
    writeFileSync(tmp, lines.slice(-LOG_KEEP_LINES).join('\n') + '\n', { mode: 0o600 });
    renameSync(tmp, p.log);
  } catch { /* best effort */ }
}

// A queued job's argv0 is resolved at RUN time, not enqueue time, and a bare
// `bash` is resolved the same way every wired hook resolves it. On Windows that
// matters: bare `bash` can be the WSL launcher or a 0-byte WindowsApps alias, so
// spawning it by name would run the job under a different shell than the session
// does — or hang. run-hook-with-bash.js already owns this; do not re-derive it.
function resolveArgv0(argv0) {
  if (argv0 !== 'bash') return argv0;
  try {
    return createRequire(import.meta.url)('./run-hook-with-bash.js').resolveBash() || argv0;
  } catch {
    return argv0;
  }
}

function readStdin() {
  if (process.stdin.isTTY) return '';
  try {
    return readFileSync(0, 'utf8');
  } catch {
    return '';
  }
}

// ---------------------------------------------------------------- enqueue

export function enqueue(dir, { name, argv, payload = '', cwd = process.cwd(), ttlMs = DEFAULT_TTL_MS, cleanup = [], id }) {
  const p = ensureDirs(dir);
  const key = entryKey(name, payload);
  // THROW, do not return a flag. A returned `dropped: true` was ignored by the
  // CLI, which then exited 0 — and a 0 tells detach_queued the work is safely
  // queued, so it does not fall back either. The job vanished with a log row
  // nobody reads. An oversize payload is a failed enqueue; say so the only way
  // the caller acts on.
  if (Buffer.byteLength(payload, 'utf8') > MAX_PAYLOAD_BYTES) {
    logRow(dir, { ev: 'oversize', key, bytes: Buffer.byteLength(payload, 'utf8'), ...(id ? { id } : {}) });
    throw new Error(`payload ${Buffer.byteLength(payload, 'utf8')} bytes exceeds the ${MAX_PAYLOAD_BYTES}-byte cap`);
  }
  const target = join(p.entries, `${key}.json`);
  const replaced = existsSync(target);
  // The rename below DISCARDS whatever sat at this path. If that entry named
  // cleanup files, nothing else would ever delete them — the job that would
  // have is the one being superseded — so they would leak once per dedup.
  // CARRY them into the new entry rather than deleting them here: a worker may
  // have CLAIMED the old entry a moment ago and be running it right now, and
  // deleting its payload file out from under it would break a job that is
  // mid-flight. By the time the new entry runs, that job is finished.
  const superseded = replaced ? readEntry(target) : null;
  const carried = (superseded && Array.isArray(superseded.cleanup)) ? superseded.cleanup : [];
  // `gen` is the entry's IDENTITY, not `created`. Two same-key enqueues can
  // land in the same millisecond, and a timestamp would then let the worker
  // mistake a replacement for the entry it just ran and delete it unrun.
  const entry = {
    v: 1, key, name, gen: randomUUID(), created: Date.now(), ttl_ms: ttlMs,
    argv, cwd, payload, cleanup: [...cleanup, ...carried], env: snapshotEnv(),
  };
  // Atomic publish: a reader never sees a half-written entry, and the rename
  // over an existing file IS the dedup.
  const tmp = join(p.tmp, `${key}.${process.pid}.${Date.now()}.tmp`);
  writeFileSync(tmp, JSON.stringify(entry), { mode: 0o600 });
  renameSync(tmp, target);
  logRow(dir, { ev: replaced ? 'dedup' : 'enqueued', key, argv0: argv[0], ...(id ? { id } : {}) });
  return { key, dropped: false, replaced };
}

// ------------------------------------------------------------------- lock

function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    // EPERM means the pid exists and belongs to someone else — still alive.
    return e.code === 'EPERM';
  }
}

// A lock is stale when its holder is gone, or when it is old enough that a
// reused pid would be the only thing keeping it alive. ponytail: pid reuse is
// the known ceiling here; the age cap is what bounds it.
export function lockIsStale(dir, now = Date.now()) {
  const p = paths(dir);
  let pid = 0;
  let mtime = 0;
  try {
    pid = Number(readFileSync(p.lockPid, 'utf8').trim());
    mtime = statSync(p.lockPid).mtimeMs;
  } catch {
    // Lock dir with no readable pid file: only stale once it has had time to
    // be written, so a worker mid-acquisition is not stolen from.
    try { mtime = statSync(p.lock).mtimeMs; } catch { return true; }
    return now - mtime > 60_000;
  }
  if (now - mtime > STALE_LOCK_MS) return true;
  return !pidAlive(pid);
}

export function workerIsLive(dir) {
  return existsSync(paths(dir).lock) && !lockIsStale(dir);
}

function acquireLock(dir) {
  const p = paths(dir);
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      mkdirSync(p.lock, { mode: 0o700 });
      writeFileSync(p.lockPid, String(process.pid), { mode: 0o600 });
      return true;
    } catch (e) {
      if (e.code !== 'EEXIST') return false;
      if (!lockIsStale(dir)) return false;      // a live worker owns it — this is the bound
      // Clearing a stale lock by rmSync is RACY, and racy here means two
      // workers draining at once — the one thing the lock exists to prevent.
      // Both can see the same stale lock; the slower one then deletes the lock
      // the faster one has just legitimately created, and both proceed. RENAME
      // it away instead: exactly one process can rename a given directory, so
      // the loser fails here and retries against whatever the winner leaves.
      const parked = `${p.lock}.stale-${randomUUID().slice(0, 8)}`;
      try {
        renameSync(p.lock, parked);
      } catch {
        continue;   // someone else cleared or replaced it; look again
      }
      try { rmSync(parked, { recursive: true, force: true }); } catch { /* best effort */ }
    }
  }
  return false;
}

function releaseLock(dir) {
  try { rmSync(paths(dir).lock, { recursive: true, force: true }); } catch { /* best effort */ }
}

function heartbeat(dir) {
  try { writeFileSync(paths(dir).lockPid, String(process.pid), { mode: 0o600 }); } catch { /* best effort */ }
}

// ------------------------------------------------------------------ drain

// `prune` is what separates the worker's read from an inspector's. The worker
// removes a poison entry so it is not re-read forever; `status` must not —
// report-only means report-only, and quietly destroying the malformed entry
// someone is inspecting removes the very evidence they came for.
function readEntries(dir, { prune = true } = {}) {
  const p = paths(dir);
  const out = [];
  let names = [];
  try { names = readdirSync(p.entries); } catch { return out; }
  for (const file of names) {
    if (!file.endsWith('.json')) continue;
    const full = join(p.entries, file);
    try {
      const entry = JSON.parse(readFileSync(full, 'utf8'));
      if (!validArgv(entry.argv)) throw new Error('no argv');
      if (!validCwd(entry.cwd)) throw new Error('no cwd');
      out.push({ ...entry, file: full });
    } catch (e) {
      if (!prune) { out.push({ key: file, file: full, corrupt: String(e.message || e) }); continue; }
      // Never leave a poison entry to be re-read forever, and never remove it
      // without saying so.
      logRow(dir, { ev: 'corrupt', key: file, err: String(e.message || e) });
      try { rmSync(full, { force: true }); } catch { /* best effort */ }
    }
  }
  return out.sort((a, b) => (a.created || 0) - (b.created || 0));
}

// The crash counter lives OUTSIDE the entry so the entry file can stay
// write-once (see runEntry). Keyed by `gen`, so a replacement never inherits
// the count of the entry it replaced. A missing sidecar simply reads 0 — the
// counter is a safety bound, and losing it costs at most a few extra retries.
const attemptsFile = (dir, entry) => join(paths(dir).attempts, `${sanitizeKey(String(entry.gen || entry.key))}.n`);

function readAttempts(dir, entry) {
  try { return Number(readFileSync(attemptsFile(dir, entry), 'utf8').trim()) || 0; } catch { return 0; }
}

// Returns whether the count actually landed. That matters: the counter is what
// BOUNDS retries, and a retained job whose counter never persists would sit at
// zero forever, spawning a successor worker on every pass — an unbounded loop,
// which is the exact failure this queue exists to remove. The caller refuses to
// retain such a job rather than looping on it.
function writeAttempts(dir, entry, n) {
  try {
    mkdirSync(paths(dir).attempts, { recursive: true, mode: 0o700 });
    writeFileSync(attemptsFile(dir, entry), String(n), { mode: 0o600 });
    return true;
  } catch {
    return false;
  }
}

function clearAttempts(dir, entry) {
  try { rmSync(attemptsFile(dir, entry), { force: true }); } catch { /* best effort */ }
}

// Drop an entry that will NEVER run (expired, or past its crash budget), and
// take its `cleanup` paths with it. Those are files the JOB would have deleted
// had it run — the end-side hooks save their stdin payload to a temp file and
// pass the path in argv — so an entry that dies unrun is the only thing left
// that knows about them. Without this they accumulate one per dropped session.
function discard(dir, entry) {
  try { rmSync(entry.file, { force: true }); } catch { /* best effort */ }
  clearAttempts(dir, entry);
  for (const path of Array.isArray(entry.cleanup) ? entry.cleanup : []) {
    try { rmSync(path, { force: true }); } catch { /* best effort */ }
  }
}

export function isExpired(entry, now = Date.now()) {
  const ttl = Number(entry.ttl_ms) > 0 ? Number(entry.ttl_ms) : DEFAULT_TTL_MS;
  return now - Number(entry.created || 0) > ttl;
}

// ONE job, run to completion or to its deadline, and stopped as a TREE when it
// misses that deadline (HIMMEL-2028).
//
// spawnSync's timeout was the obvious way to write this and the wrong one: it
// signals the DIRECT child only, and every real job here is a tree — node
// run-hook-with-bash.js -> bash <hook>.sh -> curl / bun / python. A job that hit
// the 120-second mark therefore left its descendants running, outside the
// concurrency bound and overlapping its own retry, which is the exact fan-out
// this queue exists to remove. Reaping the tree needs the pid while the job is
// still LIVE, which only the async spawn gives us — hence this function, and
// hence drain()/work() being async.
//
// The reaping itself is scripts/lib/kill-tree.mjs, the harness's one tree
// reaper (taskkill /T on Windows, a process-GROUP signal on POSIX). Its POSIX
// half only works if the child LEADS a group, which is what SPAWN_OWN_GROUP
// arranges on this side of the spawn.
function runJob(entry, jobTimeoutMs) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(resolveArgv0(entry.argv[0]), entry.argv.slice(1), {
        cwd: entry.cwd,
        // Three layers, in order. The ALLOWLIST base: a worker OUTLIVES the
        // session that spawned it and drains other sessions' entries, so
        // passing its raw environment through would hand session A's
        // credentials to session B's job — an exposure the per-session
        // detach_run it replaces never had. Only named system/interpreter
        // variables cross. Then the entry's own snapshot, so the job runs under
        // ITS session's gates. Then the inline flag, because work that reached
        // here must not re-detach out of the bound.
        env: jobEnv(entry.env || {}),
        stdio: ['pipe', 'ignore', 'pipe'],
        // POSIX: the child must lead its own process group, or there is no
        // group for kill-tree.mjs to signal. Empty on Windows, where taskkill
        // /T already walks the tree — see that file for the measured matrix.
        ...SPAWN_OWN_GROUP,
        // The worker runs detached with no console of its own, so a job spawned
        // without this flashes a conhost window on every drain (HIMMEL-2042).
        windowsHide: true,
      });
    } catch (e) {
      // A synchronous throw means nothing started — the same shape as an
      // 'error' event, so the caller's never-started branch handles both alike.
      resolve({ error: e, status: null, signal: null, stderr: '', timedOut: false, reapFailed: '' });
      return;
    }
    let stderr = '';
    let timedOut = false;
    let settled = false;
    // A tree reap that silently failed is indistinguishable from one that
    // worked, and the survivors it leaves are exactly what this is here to
    // prevent — so kill-tree's verdict goes into the log row rather than being
    // dropped. Awaiting 'close' does NOT verify it: that only says the direct
    // child and its pipes are done, not that the descendants are gone.
    let reapFailed = '';
    // Whether the DIRECT CHILD has exited, tracked separately from 'close'.
    // The two are not the same event and the gap between them is where both
    // hazards below live: 'close' waits for the stderr pipe to reach EOF, and a
    // descendant that inherited that pipe holds it open long after the job
    // itself is done.
    let exited = false;
    let exitCode = null;
    let exitSignal = null;
    let graceTimer = null;
    child.stderr.on('data', (chunk) => {
      if (stderr.length < STDERR_CAP) stderr += chunk.toString('utf8');
    });
    // The job may exit before the payload finishes going down the pipe; that is
    // the job's business, not a worker error.
    child.stdin.on('error', () => { /* nothing to do — the job is gone */ });
    child.stdin.end(entry.payload || '');
    const timer = setTimeout(() => {
      if (exited) {
        // The JOB ITSELF FINISHED before the deadline — 'close' has not fired
        // only because a descendant inherited the stderr pipe and is holding it
        // open. That is not a deadline miss, and recording it as one retains a
        // COMPLETED job for retry and repeats every side effect it already
        // performed. Take its real exit code instead. The reap still runs, with
        // kill-tree's `exited` flag set: on POSIX the process GROUP outlives its
        // leader and is still ours to signal, so the survivors are reaped; on
        // Windows the child's pid is gone and may already be recycled, so
        // kill-tree deliberately declines to aim taskkill at it.
        const reap = killTree(child.pid, (s) => child.kill(s), { exited: true });
        if (!reap.ok) reapFailed = String(reap.detail || 'unknown');
        done({ error: null, status: exitCode, signal: exitSignal, stderr, timedOut: false, reapFailed });
        return;
      }
      timedOut = true;
      // The LIVE pid, aimed while we still hold the child handle and exactly
      // once — the recycled-pid hazard kill-tree.mjs documents needs a STALE
      // pid, and this branch only runs while the child is still alive.
      const reap = killTree(child.pid, (s) => child.kill(s));
      if (!reap.ok) reapFailed = String(reap.detail || 'unknown');
      // A reap does NOT guarantee 'close'. A survivor can keep the pipe open,
      // and a reap that FAILED (no taskkill binary, EPERM) may leave the child
      // itself alive — in which case waiting only on 'close' wedges this drain
      // forever while it holds the singleton lock, so ONE stuck job would stop
      // every other session's work. spawnSync's timeout at least always
      // returned; the deadline has to stay enforceable. Settle on a bounded
      // grace instead, and stop holding the pipes on the way out.
      graceTimer = setTimeout(() => {
        done({
          error: null,
          status: null,
          signal: null,
          stderr,
          timedOut: true,
          reapFailed: reapFailed || 'the job did not close within the reap grace',
        });
      }, REAP_GRACE_MS);
    }, jobTimeoutMs);
    const done = (out) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      clearTimeout(graceTimer);
      // Settling AHEAD of 'close' (both deadline paths above) leaves this
      // process holding pipes a survivor still writes to, and holding a child
      // handle that keeps the event loop alive. Release both. After a real
      // 'close' these are no-ops.
      try { child.stdin.destroy(); child.stderr.destroy(); child.unref(); } catch { /* already gone */ }
      resolve(out);
    };
    child.on('error', (e) => done({ error: e, status: null, signal: null, stderr, timedOut, reapFailed }));
    child.on('exit', (code, signal) => { exited = true; exitCode = code; exitSignal = signal; });
    // 'close', not 'exit', for the HAPPY path: it waits for the stderr pipe to
    // reach EOF, so the log row carries what the job actually said. Both
    // deadline branches above settle without it, so a pipe nobody closes can
    // delay this row but can no longer wedge the drain.
    child.on('close', (code, signal) => done({ error: null, status: code, signal, stderr, timedOut, reapFailed }));
  });
}

async function runEntry(dir, entry, jobTimeoutMs) {
  // Count the attempt BEFORE running, in a SIDECAR — never by rewriting the
  // entry. The entry file is write-once: published by rename, removed by the
  // worker, never modified in place. Rewriting it re-opened the same race the
  // delete already guards, one step earlier: a same-key enqueue that renamed a
  // newer entry into this path just before the write would be overwritten by
  // the stale one and lost outright. Keying the sidecar on `gen` also means a
  // replacement starts its own count instead of inheriting the old entry's.
  //
  // MAX_ATTEMPTS is a CRASH budget, not a failure-retry budget, and the
  // difference is deliberate: a job that RUNS TO COMPLETION is done at whatever
  // exit code it produced (the rc is logged and the entry removed), because
  // re-running a hook that just told us it failed reproduces the failure and
  // multiplies its side effects. Only a job whose worker DIED mid-run leaves a
  // live entry with a bumped count, and it is that path the budget bounds.
  const attempt = readAttempts(dir, entry) + 1;
  const counted = writeAttempts(dir, entry, attempt);

  // The cwd an entry names is load-bearing: these jobs resolve their repo with
  // `git` relative to it. If it has gone (a worktree pruned while its work sat
  // in the queue — the very reason the queue lives outside the repo), falling
  // back to the worker's cwd would point a repo hook at a DIFFERENT checkout
  // and let it inspect or commit against the wrong one. Refuse instead; a job
  // that cannot run where it belongs must not run somewhere else.
  if (!existsSync(entry.cwd || '')) {
    logRow(dir, { ev: 'dropped', key: entry.key, reason: 'cwd-gone', cwd: String(entry.cwd || '') });
    discard(dir, entry);
    return null;
  }

  const started = Date.now();
  const result = await runJob(entry, jobTimeoutMs);
  const ms = Date.now() - started;
  const rc = result.error ? null : result.status;
  logRow(dir, {
    ev: (result.timedOut || result.signal) ? 'timeout' : 'ran',
    key: entry.key,
    rc,
    ms,
    attempt,
    ...(result.error ? { err: String(result.error.message || result.error) } : {}),
    ...(result.stderr ? { stderr: redactSecrets(String(result.stderr)).slice(0, 500) } : {}),
    ...(result.reapFailed ? { reap_failed: result.reapFailed } : {}),
  });
  // The entry lives at its CLAIMED path, which is ours alone (see claim), so
  // this delete cannot race a replacement — a replacement is a fresh file at
  // the key path and will be claimed on its own.
  //
  // A TIMED-OUT job is the exception: it did not finish, so it is not done.
  // Leaving it claimed lets the next pass re-adopt it under the crash budget,
  // which is what bounds it; deleting it here would silently discard
  // unfinished work at the 120-second mark.
  // `result.error` means the command never STARTED (a missing interpreter, a
  // bad path) — nothing ran, so deleting the entry would lose the work outright.
  // It is retained for the crash budget exactly like a timeout. This is the same
  // ran-versus-never-started line the enqueue fallback draws; both must agree,
  // or one of them silently discards work the other would have saved.
  // THREE ways a job can be unfinished, and all three retain it.
  // `timedOut` is our OWN flag rather than an exit signal, because a tree reap
  // on Windows ends the job through taskkill, which reports an ordinary exit
  // code and no signal at all — reading the signal alone would log a deadline
  // miss as a clean run and delete unfinished work.
  // `result.signal` is the CONVERSE case and is still load-bearing: a job
  // terminated by someone ELSE (an OOM reaper, an operator, a sweeper) exits
  // with a null status, no error and no timeout of ours, so classifying on
  // `timedOut` alone would delete it as completed and silently lose work that
  // never ran to the end. spawnSync's `result.signal` covered this before the
  // async rewrite; this keeps that behaviour.
  if (result.timedOut || result.error || result.signal) {
    // Retaining is only safe when the attempt COUNTED. If the counter could not
    // be persisted the job would be retried forever, and each pass hands off to
    // a fresh successor worker — an unbounded spawn loop. Drop it instead,
    // loudly: a bounded loss beats an unbounded one.
    if (!counted) {
      logRow(dir, { ev: 'dropped', key: entry.key, reason: 'attempt-counter-unwritable' });
      discard(dir, entry);
      return rc;
    }
    logRow(dir, {
      ev: 'retained',
      key: entry.key,
      reason: result.timedOut ? 'timeout' : (result.error ? 'spawn-failed' : `signalled-${result.signal}`),
      attempt,
    });
    return rc;
  }
  try { rmSync(entry.file, { force: true }); } catch { /* best effort */ }
  clearAttempts(dir, entry);
  // A completed job deletes its OWN payload file; anything CARRIED here from a
  // superseded entry has no other owner, so clear it now that this entry is
  // done. force, so an already-deleted path is a no-op.
  for (const path of Array.isArray(entry.cleanup) ? entry.cleanup : []) {
    try { rmSync(path, { force: true }); } catch { /* best effort */ }
  }
  return rc;
}

// Take exclusive ownership of whatever currently sits at an entry's key path,
// by RENAME — the one operation the filesystem gives us that is atomic.
//
// This is what removes the read-check-then-delete race entirely rather than
// narrowing it. Previously the worker read an entry, ran it, then re-read the
// path to check nothing had replaced it before deleting; a replacement landing
// inside that window was deleted unrun. Now the key path is vacated the instant
// work begins, so a replacement simply lands on a free path and is claimed in
// its own right. Nothing has to be compared, and nothing can be mistaken.
//
// The claimed file is re-READ rather than trusted from before the rename: if a
// replacement won the race to the key path, the rename moved THAT file, and its
// content is the work we should be doing.
function claim(dir, entry) {
  const p = paths(dir);
  const dest = join(p.running, `${sanitizeKey(String(entry.gen || entry.key))}.json`);
  try {
    mkdirSync(p.running, { recursive: true, mode: 0o700 });
    renameSync(entry.file, dest);
  } catch {
    return null;   // already gone, or another pass took it
  }
  try {
    const claimed = JSON.parse(readFileSync(dest, 'utf8'));
    if (!validArgv(claimed.argv)) throw new Error('no argv');
    if (!validCwd(claimed.cwd)) throw new Error('no cwd');
    return { ...claimed, file: dest };
  } catch (e) {
    logRow(dir, { ev: 'corrupt', key: entry.key, err: String(e.message || e) });
    try { rmSync(dest, { force: true }); } catch { /* best effort */ }
    return null;
  }
}

// Work already claimed by a worker that never finished it — a timed-out job, or
// one whose worker was killed mid-run. The crash budget is what bounds these.
// `prune` carries the same meaning as in readEntries, and for the same reason:
// `status` must not delete the malformed claimed entry an operator opened the
// census to look at.
function readRunning(dir, { prune = true } = {}) {
  const p = paths(dir);
  const out = [];
  let names = [];
  try { names = readdirSync(p.running); } catch { return out; }
  for (const file of names) {
    if (!file.endsWith('.json')) continue;
    const full = join(p.running, file);
    try {
      const entry = JSON.parse(readFileSync(full, 'utf8'));
      if (!validArgv(entry.argv)) throw new Error('no argv');
      if (!validCwd(entry.cwd)) throw new Error('no cwd');
      out.push({ ...entry, file: full });
    } catch (e) {
      if (!prune) { out.push({ key: file, file: full, corrupt: String(e.message || e) }); continue; }
      logRow(dir, { ev: 'corrupt', key: file, err: String(e.message || e) });
      try { rmSync(full, { force: true }); } catch { /* best effort */ }
    }
  }
  return out.sort((a, b) => (a.created || 0) - (b.created || 0));
}

// ASYNC because runJob is: a job's pid must be held while it runs so a missed
// deadline can take the whole tree. The drain itself is still strictly
// sequential — one job at a time — which is the bound this queue exists for.
export async function drain(dir, { jobTimeoutMs = DEFAULT_JOB_TIMEOUT_MS, maxPasses = 50, maxJobs = Infinity } = {}) {
  let ran = 0;
  let expired = 0;
  // Every removal here is best-effort — on Windows a file another process still
  // holds open refuses to unlink. Without this, such an entry would be re-read
  // and RE-RUN on every pass. Identity is key+created, not key alone, so an
  // entry REPLACED mid-drain (dedup: same key, newer timestamp) is still picked
  // up rather than skipped as already-seen.
  const seen = new Set();
  const idOf = (e) => `${e.key}@${e.gen || e.created}`;
  for (let pass = 0; pass < maxPasses; pass += 1) {
    // Unfinished work FIRST — a timed-out job or one whose worker was killed is
    // already claimed, so it is not in the key directory any more. Then newly
    // queued entries, each claimed by rename as it is taken.
    // Claim LAZILY, one entry at a time inside the loop — not the whole batch
    // up front. A bounded drain (the in-hook recovery) would otherwise rename
    // every queued entry into `running/` and then run only its budget, leaving
    // the rest looking unfinished in the census and costing renames nobody
    // needed. Adopted entries are already claimed by definition.
    const adopted = readRunning(dir).filter((e) => !seen.has(idOf(e)));
    const fresh = readEntries(dir).filter((e) => !seen.has(idOf(e)));
    if (!adopted.length && !fresh.length) return { ran, expired };
    for (const queued of [...adopted.map((e) => ({ e, claimed: true })),
                          ...fresh.map((e) => ({ e, claimed: false }))]) {
      const entry = queued.claimed ? queued.e : claim(dir, queued.e);
      if (!entry) continue;   // vanished, or another pass took it
      seen.add(idOf(entry));
      if (isExpired(entry)) {
        // LOGGED, never silently discarded — the acceptance criterion.
        logRow(dir, { ev: 'expired', key: entry.key, age_ms: Date.now() - Number(entry.created || 0) });
        discard(dir, entry);
        expired += 1;
        continue;
      }
      const priorAttempts = readAttempts(dir, entry);
      if (priorAttempts >= MAX_ATTEMPTS) {
        logRow(dir, { ev: 'abandoned', key: entry.key, attempts: priorAttempts });
        discard(dir, entry);
        continue;
      }
      await runEntry(dir, entry, jobTimeoutMs);
      ran += 1;
      heartbeat(dir);
      // A caller running INSIDE a hook (the spawn-failure recovery) cannot
      // afford the whole backlog: maxPasses bounds the rescans, not the jobs
      // in one pass, so a queued fleet would still blow the hook timeout.
      if (ran >= maxJobs) return { ran, expired };
    }
  }
  return { ran, expired };
}

export async function work(dir, opts = {}) {
  ensureDirs(dir);
  if (!acquireLock(dir)) return { started: false, ran: 0, expired: 0 };
  let ran = 0;
  let expired = 0;
  // Drain, release, then LOOK AGAIN before really exiting. Without the re-check
  // there is a window that strands work: an enqueuer writes its entry, sees a
  // live lock, and skips spawning — while this worker has already finished its
  // last empty read and is on its way out. Nobody then runs that entry until
  // some later enqueue happens to start a worker. Re-acquiring after the
  // release closes it, because the enqueuer writes the entry BEFORE it checks
  // the lock: either this scan sees the entry, or the lock is already gone and
  // the enqueuer spawns. Bounded so a pathological enqueue rate cannot pin one
  // worker here forever — the next enqueue starts a fresh one.
  const ROUNDS = 3;
  for (let round = 0; round < ROUNDS; round += 1) {
    try {
      const result = await drain(dir, opts);
      ran += result.ran;
      expired += result.expired;
      trimLog(dir);
    } finally {
      releaseLock(dir);
    }
    // Check the round budget BEFORE re-acquiring. Taking the lock and then
    // falling out of the loop would leave it held by a process that has
    // already returned — every later enqueue would see a "live" worker until
    // the stale-lock age cap expired, which is the opposite of the stranding
    // this re-check exists to prevent.
    if (round === ROUNDS - 1) break;
    if (!readEntries(dir, { prune: false }).length) break;
    if (!acquireLock(dir)) break;   // someone else took over — their problem now
  }
  // The round budget can end with work still queued — including work whose
  // enqueuer saw this worker's lock during the LAST drain and therefore skipped
  // spawning. Nobody would then start a worker until the next enqueue happened
  // by. Hand off to a fresh one instead of exiting on top of it; the lock is
  // already released, so the successor takes it cleanly.
  // `running/` counts here too: a timed-out job is retained there for its next
  // attempt, and checking only the key directory left exactly that job stranded
  // until some unrelated enqueue happened to start a worker.
  if (readEntries(dir, { prune: false }).length || readRunning(dir).length) {
    try { ensureWorker(dir, SELF_PATH); } catch { /* best effort */ }
  }
  return { started: true, ran, expired };
}

// --------------------------------------------------------- worker spawning

// Spawn the worker only when none is live. The check is a stat, so the common
// path (a worker already draining) costs nothing; a lost race is harmless
// because the second worker refuses the lock and exits.
function ensureWorker(dir, selfPath) {
  if (workerIsLive(dir)) return false;
  const child = spawn(process.execPath, [selfPath, 'work'], {
    detached: true,
    windowsHide: true,   // HIMMEL-2042: detached worker must not allocate a conhost
    stdio: 'ignore',
    cwd: process.cwd(),
    env: process.env,
  });
  // A spawn failure arrives ASYNCHRONOUSLY as an 'error' event, which a
  // try/catch around this call cannot see. Unhandled, it throws out of the
  // event loop and crashes the enqueuer — AFTER the entry was persisted, so the
  // hook reports failure, detach_queued falls back, and the same work runs
  // twice. The entry is durable either way; a worker that could not start is
  // logged and the next enqueue starts one.
  child.on('error', (e) => {
    logRow(dir, { ev: 'worker-spawn-failed', err: String(e.message || e) });
    // Last resort: if we cannot START a worker, BE one. Otherwise a lone queued
    // job sits until some later enqueue happens along — and if spawning is
    // broken, that one will not manage it either. Bounded hard, because this
    // runs inside the hook: one pass, short per-job timeout. The entry stays
    // durable whatever happens here.
    work(dir, { jobTimeoutMs: 10_000, maxPasses: 1, maxJobs: 1 }).catch(() => { /* best effort */ });
  });
  child.unref();
  return true;
}

// ------------------------------------------------------------------ status

export function status(dir) {
  const p = paths(dir);
  const lines = [`stop-queue — dir=${dir}`];
  const live = existsSync(p.lock);
  lines.push(`worker: ${live ? (lockIsStale(dir) ? 'lock present but STALE' : 'running') : 'idle'}`);
  // prune:false — report-only means report-only. The worker's read removes a
  // malformed entry; an inspector must not, or `status` destroys the evidence
  // the operator opened it to look at.
  const entries = readEntries(dir, { prune: false });
  // `running/` is part of the census, not a private worker detail: a timed-out
  // job and one orphaned by a killed worker BOTH live there, and reporting
  // `pending: 0` while they sit unfinished is how an operator concludes the
  // queue is idle when it is actually stuck.
  const running = readRunning(dir, { prune: false });
  lines.push(`pending: ${entries.length}${running.length ? ` (+${running.length} unfinished)` : ''}`);
  for (const e of entries) {
    if (e.corrupt) { lines.push(`  ${e.key}\tCORRUPT (${e.corrupt}) — left in place`); continue; }
    lines.push(`  ${e.key}\tage=${Math.round((Date.now() - Number(e.created || 0)) / 1000)}s\tattempts=${readAttempts(dir, e)}\t${isExpired(e) ? 'EXPIRED' : 'ready'}`);
  }
  for (const e of running) {
    if (e.corrupt) { lines.push(`  ${e.key}	CORRUPT (${e.corrupt}) — left in place`); continue; }
    lines.push(`  ${e.key}\tage=${Math.round((Date.now() - Number(e.created || 0)) / 1000)}s\tattempts=${readAttempts(dir, e)}\tUNFINISHED (claimed, awaiting retry)`);
  }
  const counts = {};
  let tail = [];
  try {
    const rows = readFileSync(p.log, 'utf8').split('\n').filter(Boolean);
    for (const line of rows) {
      try { counts[JSON.parse(line).ev] = (counts[JSON.parse(line).ev] || 0) + 1; } catch { /* skip */ }
    }
    tail = rows.slice(-10);
  } catch { /* no log yet */ }
  lines.push(`log: ${Object.entries(counts).map(([k, v]) => `${k}=${v}`).join(' ') || '(empty)'}`);
  for (const line of tail) lines.push(`  ${line}`);
  return lines.join('\n');
}

// --------------------------------------------------------------------- cli

export function parseEnqueueArgs(argv) {
  let name = null;
  let ttlMs = null;
  const cleanup = [];
  let i = 0;
  for (; i < argv.length; i += 1) {
    if (argv[i] === '--key') { name = argv[i + 1]; i += 1; continue; }
    if (argv[i] === '--ttl') { ttlMs = Number(argv[i + 1]) * 1000; i += 1; continue; }
    if (argv[i] === '--cleanup') { cleanup.push(argv[i + 1]); i += 1; continue; }
    if (argv[i] === '--') { i += 1; break; }
    throw new Error(`unknown argument: ${argv[i]}`);
  }
  const command = argv.slice(i);
  if (!name) throw new Error('enqueue needs --key <name>');
  if (!command.length) throw new Error('enqueue needs -- <command...>');
  if (ttlMs !== null && !(ttlMs > 0)) throw new Error('--ttl needs a positive number of seconds');
  return { name, ttlMs: ttlMs === null ? DEFAULT_TTL_MS : ttlMs, command, cleanup };
}

export function main(argv, selfPath) {
  const dir = queueDir();
  const sub = argv[0];
  if (sub === 'enqueue') {
    // EXIT CODE IS THE FALLBACK SIGNAL. detach_queued decides whether to fall
    // back to the old unbounded detach_run purely on this process's status, so
    // an enqueue that failed MUST NOT report success — returning 0 there would
    // strand the job in neither the queue nor a detached child, which is the
    // one outcome this design refuses ("losing the bound is acceptable; losing
    // the work is not"). 1, never 2: Claude Code treats 2 as a BLOCKING hook
    // decision, and a queue problem must not take the session with it — it
    // surfaces as a non-blocking error with the reason on stderr.
    let parsed;
    try {
      parsed = parseEnqueueArgs(argv.slice(1));
    } catch (e) {
      // 1, NOT 2. This binary is wired as a HOOK, and Claude Code reads 2 as a
      // BLOCKING decision — so a mistyped hook command would block session
      // teardown instead of reporting itself. Same rule the enqueue-failure
      // path already follows: a malformed configuration is still a queue
      // problem, and queue problems never take the session with them.
      process.stderr.write(`stop-queue: ${e.message}\n`);
      return 1;
    }
    // HIMMEL-713: an `attempt` breadcrumb FIRST, before any of the slower work
    // below (stdin read, the atomic entry write) — so a hook the harness
    // cancels mid-enqueue (the "Hook cancelled" class on a short session) still
    // leaves a trace. Without this, a cancelled enqueue is indistinguishable
    // from a session that never fired the hook at all: the same masking class
    // HIMMEL-2022 found had cost the session-runs ledger five silent days. A
    // later `status`/audit sees an `attempt` row with no matching
    // `enqueued`/`enqueue-failed` as the trace of a cancelled hook.
    // `attemptId` is a per-invocation correlation id, NOT the entry key —
    // `key` is sanitizeKey'd and can collapse or truncate, so an attempt row
    // logged before that transform can't otherwise be matched to its terminal
    // row (or disambiguated from a concurrent same-name invocation).
    const attemptId = randomUUID();
    logRow(dir, { ev: 'attempt', key: parsed.name, id: attemptId });
    // Read stdin ONCE, here, and keep it: this process has now consumed the
    // hook payload, so no caller downstream can ever read it again. That is
    // precisely why the enqueue-failure fallback has to live INSIDE this
    // process rather than as a `|| <original command>` in the wiring — a shell
    // fallback re-runs the command against an already-drained stdin, handing a
    // payload-dependent hook EOF and quietly doing nothing. Whoever holds the
    // payload owns the fallback.
    const payload = readStdin();
    try {
      enqueue(dir, {
        name: parsed.name,
        argv: parsed.command,
        payload,
        cleanup: parsed.cleanup,
        // The directory the HOOK ran in, not CLAUDE_PROJECT_DIR: these jobs
        // resolve their repo with `git` relative to cwd, so running them
        // somewhere else silently detects the wrong repository.
        cwd: process.cwd(),
        ttlMs: parsed.ttlMs,
        id: attemptId,
      });
    } catch (e) {
      logRow(dir, { ev: 'enqueue-failed', key: parsed.name, id: attemptId, err: String(e.message || e) });
      process.stderr.write(`stop-queue: enqueue failed: ${e.message} — running it inline instead\n`);
      // Losing the bound is acceptable; losing the work is not — so fall back
      // to exactly what this queue replaced: a DETACHED spawn, which survives
      // the hook returning. Running it inline here cannot work: the wired hooks
      // carry a 10-second harness timeout while a job is allowed 120, so
      // teardown would kill the fallback mid-flight and lose the very work the
      // fallback exists to save. The payload goes down the pipe before unref.
      let started = false;
      try {
        const fb = spawn(resolveArgv0(parsed.command[0]), parsed.command.slice(1), {
          detached: true,
          windowsHide: true,   // HIMMEL-2042
          stdio: ['pipe', 'ignore', 'ignore'],
          env: { ...process.env, HIMMEL_DETACH_INLINE: '1' },
        });
        fb.on('error', () => { /* reported via `started` below */ });
        fb.stdin.on('error', () => { /* the child may exit before we finish writing */ });
        fb.stdin.end(payload);
        fb.unref();
        started = typeof fb.pid === 'number';
      } catch { started = false; }
      logRow(dir, { ev: 'detached-fallback', key: parsed.name, started });
      // Report failure ONLY when nothing was started, so detach_queued still
      // gets its turn. A fallback that DID start owns the work from here; a
      // caller falling back again would run it twice.
      //
      // EXIT_NATURALLY, not process.exit: the payload write to the child's
      // stdin is asynchronous, and calling process.exit here can kill this
      // process with those bytes still buffered — the child would then read
      // truncated or empty stdin and a payload-dependent hook would quietly do
      // nothing. Setting exitCode and letting the event loop drain flushes the
      // pipe first; the child is unref'd, so nothing else holds us open.
      process.exitCode = started ? 0 : 1;
      return EXIT_NATURALLY;
    }
    // A worker that fails to START is NOT a failed enqueue: the entry is on
    // disk and the next one to arrive starts a worker that finds it. Reporting
    // failure here would make detach_queued ALSO run the job detached — the
    // same work twice — so this half is deliberately non-signalling.
    try {
      ensureWorker(dir, selfPath);
    } catch (e) {
      logRow(dir, { ev: 'worker-spawn-failed', key: parsed.name, err: String(e.message || e) });
      process.stderr.write(`stop-queue: worker spawn failed (entry is queued): ${e.message}\n`);
    }
    // EXIT_NATURALLY, not 0: a spawn failure is delivered as an ASYNCHRONOUS
    // 'error' event, and force-exiting here would return before it could fire —
    // so the recovery drain in that handler would never run and a lone job
    // would strand. The spawned worker is unref'd, so when the spawn succeeds
    // the loop is empty immediately and this costs nothing measurable.
    process.exitCode = 0;
    return EXIT_NATURALLY;
  }
  if (sub === 'work') {
    // EXIT_NATURALLY, not 0: work() is async now, and returning a code here
    // force-exits the process — which would abandon the drain mid-job, leaving
    // exactly the orphaned tree this file's deadline reap exists to prevent.
    // The pending promise is what holds the loop open until the drain is done.
    work(dir).catch((e) => logRow(dir, { ev: 'worker-failed', err: String(e.message || e) }));
    process.exitCode = 0;
    return EXIT_NATURALLY;
  }
  if (sub === 'status') {
    process.stdout.write(status(dir) + '\n');
    return 0;
  }
  process.stderr.write('usage: stop-queue.mjs enqueue --key NAME [--ttl SECONDS] -- COMMAND... | work | status\n');
  return 1;   // never 2 — see the enqueue arg-parse branch above
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const code = main(process.argv.slice(2), fileURLToPath(import.meta.url));
  if (code !== EXIT_NATURALLY) process.exit(code);
}
