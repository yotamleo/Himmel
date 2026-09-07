// stop-queue.test.mjs — spec for the bounded detached Stop worker (HIMMEL-2004).
//
// The queue exists to replace an UNBOUNDED fan-out (every ending session
// spawning its own tree of side-effect work) with one worker draining a durable
// directory. Each case below pins one of the properties that makes that safe:
// the enqueue costs nothing, a repeated session does not pile up, expiry is
// LOGGED rather than silent, a second worker cannot start, and work outlives the
// session that queued it.
//
// Run: node --test scripts/hooks/stop-queue.test.mjs
// (pre-commit runs it via scripts/hooks/check-hook-lib-suites.sh)

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync, spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  DEFAULT_TTL_MS, DEFAULT_JOB_TIMEOUT_MS, MAX_ATTEMPTS, MAX_PAYLOAD_BYTES,
  queueDir, sanitizeKey, entryKey, enqueue, drain, work, isExpired,
  lockIsStale, workerIsLive, status, parseEnqueueArgs, snapshotEnv, scrubSecrets, jobEnv, redactSecrets,
  snapshotOwns,
} from './stop-queue.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const SELF = join(HERE, 'stop-queue.mjs');

const scratch = () => mkdtempSync(join(tmpdir(), 'stop-queue-test-'));

// A job that appends one line to a marker file, expressed as argv so it needs
// no shell on any platform.
const appendJob = (marker, text) => [
  process.execPath, '-e',
  `require("fs").appendFileSync(${JSON.stringify(marker)}, ${JSON.stringify(text + '\n')})`,
];

const logRows = (dir) => {
  const p = join(dir, 'queue.jsonl');
  if (!existsSync(p)) return [];
  return readFileSync(p, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
};

const pending = (dir) => {
  const p = join(dir, 'entries');
  return existsSync(p) ? readdirSync(p).filter((f) => f.endsWith('.json')) : [];
};

// Whether a pid is still around. EPERM means it exists and belongs to someone
// else — still alive. Mirrors pidAlive() in the module under test.
const alive = (pid) => {
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
};

// A tree teardown is not instantaneous — taskkill returns before the tree is
// actually gone — so poll to a budget rather than asserting on the first read.
const reaped = async (pid, budgetMs = 5000) => {
  const deadline = Date.now() + budgetMs;
  while (alive(pid) && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  return !alive(pid);
};

// ------------------------------------------------------------------ paths

test('queueDir prefers the explicit override, else $HOME/.himmel/stop-queue', () => {
  assert.equal(queueDir({ HIMMEL_STOP_QUEUE_DIR: '/q' }), '/q');
  assert.equal(queueDir({ HOME: '/h' }).replace(/\\/g, '/'), '/h/.himmel/stop-queue');
});

// A key becomes a filename. Traversal must not escape the queue dir, and an
// empty key must still produce something openable rather than throwing inside a
// hook.
test('sanitizeKey refuses separators, traversal and emptiness', () => {
  // No separator survives, and a lossy flattening keeps a digest of the
  // original so two different raw ids cannot collide (round 4).
  assert.match(sanitizeKey('../../etc/passwd'), /^_\.\._etc_passwd-[0-9a-f]{8}$/);
  assert.match(sanitizeKey('a/b\\c'), /^a_b_c-[0-9a-f]{8}$/);
  assert.equal(sanitizeKey(''), 'unkeyed');
  assert.equal(sanitizeKey('speak-reply.abc_123'), 'speak-reply.abc_123');
});

// The dedup identity carries the session, which is what makes a FLEET of N
// children produce N entries while one session re-firing produces one.
test('entryKey namespaces by session_id, and degrades without one', () => {
  assert.equal(entryKey('speak-reply', JSON.stringify({ session_id: 's1' })), 'speak-reply.s1');
  // No session to key on: a unique suffix, never a collision with a sibling.
  assert.match(entryKey('speak-reply', 'not json'), /^speak-reply\.\d+-[a-z0-9]+$/);
  assert.match(entryKey('speak-reply', ''), /^speak-reply\.\d+-[a-z0-9]+$/);
});

// ---------------------------------------------------------------- enqueue

test('enqueue publishes one entry and records the command and payload', () => {
  const dir = scratch();
  try {
    enqueue(dir, { name: 'k', argv: ['echo', 'hi'], payload: '{"session_id":"s1"}' });
    const files = pending(dir);
    assert.deepEqual(files, ['k.s1.json']);
    const entry = JSON.parse(readFileSync(join(dir, 'entries', files[0]), 'utf8'));
    assert.deepEqual(entry.argv, ['echo', 'hi']);
    assert.equal(entry.payload, '{"session_id":"s1"}');
    assert.ok(entry.gen, 'entry carries no generation id');
    assert.equal(logRows(dir).at(-1).ev, 'enqueued');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// The bug this prevents: a session that ends repeatedly (or a hook that fires
// per turn) accumulating one queue entry per firing until the drain is longer
// than the session that produced it.
test('a second enqueue on the same key REPLACES rather than piles up, and says so', () => {
  const dir = scratch();
  try {
    enqueue(dir, { name: 'k', argv: ['a'], payload: '{"session_id":"s1"}' });
    enqueue(dir, { name: 'k', argv: ['b'], payload: '{"session_id":"s1"}' });
    assert.equal(pending(dir).length, 1);
    const entry = JSON.parse(readFileSync(join(dir, 'entries', 'k.s1.json'), 'utf8'));
    // Newest payload wins: by drain time an older one for the same session is
    // stale, not lost work.
    assert.deepEqual(entry.argv, ['b']);
    assert.equal(logRows(dir).at(-1).ev, 'dedup');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a fleet of N sessions enqueues N distinct entries', () => {
  const dir = scratch();
  try {
    for (let i = 0; i < 8; i += 1) {
      enqueue(dir, { name: 'k', argv: ['x'], payload: JSON.stringify({ session_id: `s${i}` }) });
    }
    assert.equal(pending(dir).length, 8);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// The acceptance criterion for the Stop hook itself. Measured through the real
// CLI, because that is what the harness runs.
test('the enqueue CLI returns in well under a second and does no work inline', () => {
  const dir = scratch();
  try {
    const marker = join(dir, 'ran.txt');
    const started = Date.now();
    const result = spawnSync(process.execPath, [
      SELF, 'enqueue', '--key', 'cli', '--', ...appendJob(marker, 'x'),
    ], {
      input: '{"session_id":"cli1"}',
      env: { ...process.env, HIMMEL_STOP_QUEUE_DIR: dir },
      encoding: 'utf8',
    });
    const elapsed = Date.now() - started;
    assert.equal(result.status, 0, result.stderr);
    assert.ok(elapsed < 1000, `enqueue took ${elapsed}ms (budget 1000ms)`);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// HIMMEL-713: the masking case a harness cancellation would otherwise produce.
// The `attempt` row is written BEFORE the atomic entry write, so it is the one
// breadcrumb that survives even if the process is killed the instant after —
// proven here by its presence and its ordering ahead of `enqueued`, since a
// real mid-flight kill cannot be simulated through the CLI deterministically.
test('the enqueue CLI logs an attempt breadcrumb before the entry is published', () => {
  const dir = scratch();
  try {
    const marker = join(dir, 'ran.txt');
    const result = spawnSync(process.execPath, [
      SELF, 'enqueue', '--key', 'cli-attempt', '--', ...appendJob(marker, 'x'),
    ], {
      input: '{"session_id":"cli2"}',
      env: { ...process.env, HIMMEL_STOP_QUEUE_DIR: dir },
      encoding: 'utf8',
    });
    assert.equal(result.status, 0, result.stderr);
    const rows = logRows(dir).filter((r) => r.key === 'cli-attempt' || r.key.startsWith('cli-attempt.'));
    const attemptIdx = rows.findIndex((r) => r.ev === 'attempt');
    const enqueuedIdx = rows.findIndex((r) => r.ev === 'enqueued');
    assert.notEqual(attemptIdx, -1, 'no attempt row logged');
    assert.notEqual(enqueuedIdx, -1, 'no enqueued row logged');
    assert.ok(attemptIdx < enqueuedIdx, 'attempt must be logged before enqueued');
    // The attempt row's `key` is the raw --key value; sanitizeKey can alter it
    // before the enqueued row's `key` is derived — so `id` is the field an
    // audit actually joins the two rows on.
    assert.ok(rows[attemptIdx].id, 'attempt row carries no id');
    assert.equal(rows[enqueuedIdx].id, rows[attemptIdx].id, 'enqueued row id must match its attempt row');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// The exit code IS the fallback signal: detach_queued runs the job the old,
// unbounded way only when this process reports failure. So it must report
// failure ONLY when the work truly did not happen — a command that ran and
// failed owns its exit code, and re-running it would double its side effects.
// 1, never 2: 2 is a BLOCKING hook decision to Claude Code.
test('an enqueue whose inline fallback cannot even start reports failure', () => {
  const dir = scratch();
  try {
    // A FILE where the queue dir must be: every mkdir under it fails. The
    // command is unspawnable too, so nothing ran by any path.
    const blocked = join(dir, 'not-a-dir');
    writeFileSync(blocked, 'x');
    const result = spawnSync(process.execPath, [
      SELF, 'enqueue', '--key', 'k', '--', join(dir, 'no-such-binary-at-all'),
    ], {
      input: '',
      env: { ...process.env, HIMMEL_STOP_QUEUE_DIR: blocked },
      encoding: 'utf8',
    });
    assert.equal(result.status, 1, `expected 1, got ${result.status}: ${result.stderr}`);
    assert.match(result.stderr, /enqueue failed/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('an enqueue whose inline fallback RAN reports success, so nobody re-runs it', () => {
  const dir = scratch();
  try {
    const blocked = join(dir, 'not-a-dir');
    writeFileSync(blocked, 'x');
    const result = spawnSync(process.execPath, [
      SELF, 'enqueue', '--key', 'k', '--', process.execPath, '-e', 'process.exit(7)',
    ], {
      input: '',
      env: { ...process.env, HIMMEL_STOP_QUEUE_DIR: blocked },
      encoding: 'utf8',
    });
    assert.equal(result.status, 0, `a job that ran must not invite a second run: ${result.stderr}`);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('the enqueue CLI refuses a call with no key or no command', () => {
  const run = (args) => spawnSync(process.execPath, [SELF, ...args], { encoding: 'utf8', input: '' });
  // 1, never 2: this binary is wired as a HOOK and Claude Code reads 2 as a
  // BLOCKING decision, so a mistyped hook command would block session teardown.
  assert.equal(run(['enqueue', '--', 'echo']).status, 1);
  assert.equal(run(['enqueue', '--key', 'k']).status, 1);
  assert.equal(run(['bogus']).status, 1);
});

test('parseEnqueueArgs reads the key, the ttl and the command after --', () => {
  const parsed = parseEnqueueArgs(['--key', 'k', '--ttl', '30', '--', 'node', '-e', '1']);
  assert.equal(parsed.name, 'k');
  assert.equal(parsed.ttlMs, 30_000);
  assert.deepEqual(parsed.command, ['node', '-e', '1']);
  assert.equal(parseEnqueueArgs(['--key', 'k', '--', 'x']).ttlMs, DEFAULT_TTL_MS);
  assert.throws(() => parseEnqueueArgs(['--key', 'k', '--ttl', '0', '--', 'x']), /positive/);
  assert.throws(() => parseEnqueueArgs(['--nope', '--', 'x']), /unknown argument/);
});

// ------------------------------------------------------------------ drain

test('the worker drains every queued entry, one at a time, then leaves the queue empty', async () => {
  const dir = scratch();
  try {
    const marker = join(dir, 'ran.txt');
    for (let i = 0; i < 5; i += 1) {
      enqueue(dir, { name: 'j', argv: appendJob(marker, `job${i}`), payload: JSON.stringify({ session_id: `s${i}` }) });
    }
    const result = await work(dir);
    assert.equal(result.started, true);
    assert.equal(result.ran, 5);
    assert.equal(readFileSync(marker, 'utf8').split('\n').filter(Boolean).length, 5);
    assert.equal(pending(dir).length, 0);
    assert.equal(logRows(dir).filter((r) => r.ev === 'ran').length, 5);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// The whole reason the bound holds: a job that re-detaches itself would escape
// the worker and restore the fan-out this ticket removes. detach.sh reads this
// exact variable.
test('the worker runs every job with HIMMEL_DETACH_INLINE=1 so nothing escapes the bound', async () => {
  const dir = scratch();
  try {
    const marker = join(dir, 'env.txt');
    enqueue(dir, {
      name: 'j',
      argv: [process.execPath, '-e', `require("fs").writeFileSync(${JSON.stringify(marker)}, String(process.env.HIMMEL_DETACH_INLINE))`],
      payload: '{}',
    });
    await work(dir);
    assert.equal(readFileSync(marker, 'utf8'), '1');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// "Nothing lost on a dropped session": the entry is a file, so a session that
// died between enqueue and drain still gets its work run by the NEXT worker.
test('an entry left behind by a dropped session is run by the next worker', async () => {
  const dir = scratch();
  try {
    const marker = join(dir, 'ran.txt');
    mkdirSync(join(dir, 'entries'), { recursive: true });
    writeFileSync(join(dir, 'entries', 'orphan.json'), JSON.stringify({
      v: 1, key: 'orphan', created: Date.now(), ttl_ms: DEFAULT_TTL_MS,
      attempts: 0, argv: appendJob(marker, 'orphan'), cwd: dir, payload: '',
    }));
    assert.equal((await work(dir)).ran, 1);
    assert.match(readFileSync(marker, 'utf8'), /orphan/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('the job receives the saved stdin payload the hook was given', async () => {
  const dir = scratch();
  try {
    const marker = join(dir, 'payload.txt');
    enqueue(dir, {
      name: 'j',
      argv: [process.execPath, '-e', `require("fs").writeFileSync(${JSON.stringify(marker)}, require("fs").readFileSync(0, "utf8"))`],
      payload: '{"session_id":"s1","hook_event_name":"Stop"}',
    });
    await work(dir);
    assert.equal(JSON.parse(readFileSync(marker, 'utf8')).hook_event_name, 'Stop');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// --------------------------------------------------------------------- ttl

test('isExpired measures against the entry ttl, falling back to the default', () => {
  assert.equal(isExpired({ created: Date.now(), ttl_ms: 1000 }), false);
  assert.equal(isExpired({ created: Date.now() - 5000, ttl_ms: 1000 }), true);
  assert.equal(isExpired({ created: Date.now() - 1000, ttl_ms: 0 }), false);
  assert.equal(isExpired({ created: Date.now() - DEFAULT_TTL_MS - 1000 }), true);
});

// Expiry must be visible. A queue that quietly drops work is worse than one
// that never queued it, because the operator has no way to notice.
test('an expired entry is LOGGED, not silently discarded', async () => {
  const dir = scratch();
  try {
    const marker = join(dir, 'ran.txt');
    mkdirSync(join(dir, 'entries'), { recursive: true });
    writeFileSync(join(dir, 'entries', 'old.json'), JSON.stringify({
      v: 1, key: 'old', created: Date.now() - 60_000, ttl_ms: 1000,
      attempts: 0, argv: appendJob(marker, 'should-not-run'), cwd: dir, payload: '',
    }));
    const result = await work(dir);
    assert.equal(result.ran, 0);
    assert.equal(result.expired, 1);
    assert.equal(existsSync(marker), false, 'an expired job must not run');
    const row = logRows(dir).find((r) => r.ev === 'expired');
    assert.ok(row, 'expiry wrote no log row');
    assert.equal(row.key, 'old');
    assert.ok(row.age_ms >= 60_000);
    assert.equal(pending(dir).length, 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a job that keeps failing is abandoned after its attempt budget, loudly', async () => {
  const dir = scratch();
  try {
    mkdirSync(join(dir, 'entries'), { recursive: true });
    mkdirSync(join(dir, 'attempts'), { recursive: true });
    writeFileSync(join(dir, 'entries', 'bad.json'), JSON.stringify({
      v: 1, key: 'bad', gen: 'bad-gen', created: Date.now(), ttl_ms: DEFAULT_TTL_MS,
      argv: [process.execPath, '-e', 'process.exit(1)'], cwd: dir, payload: '',
    }));
    // The count lives in the sidecar now — the entry file is write-once.
    writeFileSync(join(dir, 'attempts', 'bad-gen.n'), String(MAX_ATTEMPTS));
    await work(dir);
    assert.equal(logRows(dir).filter((r) => r.ev === 'abandoned').length, 1);
    assert.equal(pending(dir).length, 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a malformed entry is removed and reported instead of poisoning every drain', async () => {
  const dir = scratch();
  try {
    mkdirSync(join(dir, 'entries'), { recursive: true });
    writeFileSync(join(dir, 'entries', 'junk.json'), '{ not json');
    await work(dir);
    assert.equal(logRows(dir).filter((r) => r.ev === 'corrupt').length, 1);
    assert.equal(pending(dir).length, 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// ------------------------------------------------------------ concurrency 1

test('a second worker refuses to start while a live one holds the lock', async () => {
  const dir = scratch();
  try {
    const marker = join(dir, 'ran.txt');
    enqueue(dir, { name: 'j', argv: appendJob(marker, 'x'), payload: '' });
    // A lock held by THIS process is by definition live.
    mkdirSync(join(dir, 'worker.lock'), { recursive: true });
    writeFileSync(join(dir, 'worker.lock', 'pid'), String(process.pid));
    assert.equal(workerIsLive(dir), true);
    const result = await work(dir);
    assert.equal(result.started, false, 'two workers ran at once — the bound is gone');
    assert.equal(result.ran, 0);
    assert.equal(existsSync(marker), false);
    // And the work is still there for the live worker to take.
    assert.equal(pending(dir).length, 1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// The opposite failure: a worker killed mid-drain leaves a lock nobody holds,
// and the queue would wedge forever if that were treated as live.
test('a lock whose holder is gone is stale, and the next worker takes it', async () => {
  const dir = scratch();
  try {
    const marker = join(dir, 'ran.txt');
    enqueue(dir, { name: 'j', argv: appendJob(marker, 'x'), payload: '' });
    mkdirSync(join(dir, 'worker.lock'), { recursive: true });
    // A pid that cannot be running: pid 0 is never a user process, and the
    // liveness probe treats it as dead on every platform.
    writeFileSync(join(dir, 'worker.lock', 'pid'), '0');
    assert.equal(lockIsStale(dir), true);
    const result = await work(dir);
    assert.equal(result.started, true);
    assert.equal(result.ran, 1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a worker releases its lock when the drain finishes', async () => {
  const dir = scratch();
  try {
    enqueue(dir, { name: 'j', argv: [process.execPath, '-e', '0'], payload: '' });
    await work(dir);
    assert.equal(existsSync(join(dir, 'worker.lock')), false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// ---------------------------------------------------------------- census

test('status reports what is pending and what the log recorded, and mutates nothing', () => {
  const dir = scratch();
  try {
    enqueue(dir, { name: 'j', argv: ['echo'], payload: '{"session_id":"s1"}' });
    const before = pending(dir);
    const out = status(dir);
    assert.match(out, /pending: 1/);
    assert.match(out, /j\.s1/);
    assert.match(out, /worker: idle/);
    assert.match(out, /enqueued=1/);
    assert.deepEqual(pending(dir), before);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// ------------------------------------------------------------ what is wired

test('the end-side hooks route their detached work through the queue', () => {
  const settings = JSON.parse(readFileSync(join(HERE, '..', '..', '.claude', 'settings.json'), 'utf8'));
  const commandsFor = (event) => (settings.hooks[event] || [])
    .flatMap((b) => (b.hooks || []).map((h) => String(h.command)));
  for (const event of ['Stop', 'SessionEnd']) {
    const cmds = commandsFor(event);
    assert.ok(cmds.length, `${event} has no hooks`);
    for (const c of cmds) {
      assert.match(c, /stop-queue\.mjs" enqueue --key /, `${event} hook is not enqueue-and-exit: ${c}`);
    }
  }
  // The three plugin SessionEnd hooks self-detach, so their seam is the call
  // site inside the script, not the wiring.
  for (const name of ['refresh-where-are-we-on-end', 'jira-nudge-on-end', 'telegram-session-end']) {
    const body = readFileSync(join(HERE, `${name}.sh`), 'utf8');
    assert.match(body, /^\s*detach_queued /m, `${name}.sh still fans out with a bare detach_run`);
  }
});

// A queue entry is a file, so anything the snapshot lets through is written to
// disk. The allowlist is what keeps a job behaving like its own session; the
// denylist is what keeps the operator's tokens out of the queue directory.
test('the env snapshot takes the gate variables and refuses the secret-shaped ones', () => {
  const env = {
    HIMMEL_WHERE_ARE_WE: '1',
    CLAUDE_PROJECT_DIR: '/repo',
    VOICE_SPEAK: '1',
    JIRA_NUDGE_RELAY_CMD: 'true',
    HIMMEL_TELEGRAM_BOT_TOKEN: 'shibboleth',
    CLAUDE_CODE_OAUTH_TOKEN: 'shibboleth',
    HIMMEL_GROUP_CHAT_ID: 'shibboleth',
    PATH: '/usr/bin',
    ANTHROPIC_API_KEY: 'shibboleth',
  };
  assert.deepEqual(snapshotEnv(env), {
    HIMMEL_WHERE_ARE_WE: '1',
    CLAUDE_PROJECT_DIR: '/repo',
    VOICE_SPEAK: '1',
    JIRA_NUDGE_RELAY_CMD: 'true',
    // Carried on purpose — it decides which interpreter the job resolves.
    PATH: '/usr/bin',
  });
});

test('an entry carries the snapshot and never a secret', () => {
  const dir = scratch();
  try {
    process.env.HIMMEL_STOP_QUEUE_FAKE_TOKEN = 'shibboleth';
    process.env.HIMMEL_STOP_QUEUE_FAKE_GATE = 'on';
    enqueue(dir, { name: 'j', argv: ['echo'], payload: '' });
    const body = readFileSync(join(dir, 'entries', pending(dir)[0]), 'utf8');
    assert.equal(JSON.parse(body).env.HIMMEL_STOP_QUEUE_FAKE_GATE, 'on');
    assert.equal(body.includes('shibboleth'), false);
  } finally {
    delete process.env.HIMMEL_STOP_QUEUE_FAKE_TOKEN;
    delete process.env.HIMMEL_STOP_QUEUE_FAKE_GATE;
    rmSync(dir, { recursive: true, force: true });
  }
});

// The bug this closes: the worker belongs to whichever session enqueued first,
// so without a per-entry snapshot a later session's job runs under an earlier
// session's gates.
test('a job runs under the enqueuing session gates, not the worker own', async () => {
  const dir = scratch();
  try {
    const marker = join(dir, 'gate.txt');
    process.env.HIMMEL_STOP_QUEUE_FAKE_GATE = 'from-enqueuer';
    enqueue(dir, {
      name: 'j',
      argv: [process.execPath, '-e', `require("fs").writeFileSync(${JSON.stringify(marker)}, String(process.env.HIMMEL_STOP_QUEUE_FAKE_GATE))`],
      payload: '',
    });
    // The worker now has a DIFFERENT value, as a later session's would.
    process.env.HIMMEL_STOP_QUEUE_FAKE_GATE = 'from-worker';
    await work(dir);
    assert.equal(readFileSync(marker, 'utf8'), 'from-enqueuer');
  } finally {
    delete process.env.HIMMEL_STOP_QUEUE_FAKE_GATE;
    rmSync(dir, { recursive: true, force: true });
  }
});

// ---------------------------------------------- panel findings (HIMMEL-2004)

// NOTE: rounds 1-3 pinned this property through a `superseded` log row and a
// generation comparison at delete time. Round 4 replaced that whole mechanism
// with claim-by-rename, which removes the race rather than narrowing it — see
// "a running job vacates its key path" below, which is the same guarantee
// asserted against the design that actually holds it.

// [codex-2] A dropped payload that reports success is the same stranding bug as
// the exit-code one: the caller neither queues the work nor falls back.
test('an oversize payload fails the enqueue instead of vanishing', () => {
  const dir = scratch();
  try {
    assert.throws(
      () => enqueue(dir, { name: 'j', argv: ['echo'], payload: 'x'.repeat(MAX_PAYLOAD_BYTES + 1) }),
      /exceeds/,
    );
    assert.equal(pending(dir).length, 0);
    assert.equal(logRows(dir).filter((r) => r.ev === 'oversize').length, 1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-3] The worker outlives the session that spawned it, so its raw
// environment must not reach another session's job.
test('scrubSecrets keeps the working environment but drops credentials', () => {
  const scrubbed = scrubSecrets({
    PATH: '/usr/bin', HOME: '/h', TMPDIR: '/t',
    TELEGRAM_BOT_TOKEN: 'shibboleth', ANTHROPIC_API_KEY: 'shibboleth',
    GH_TOKEN: 'shibboleth', SOME_PASSWORD: 'shibboleth',
  });
  assert.deepEqual(scrubbed, { PATH: '/usr/bin', HOME: '/h', TMPDIR: '/t' });
});

test("a job cannot read a credential from the worker's own environment", async () => {
  const dir = scratch();
  try {
    const marker = join(dir, 'leak.txt');
    enqueue(dir, {
      name: 'j',
      argv: [process.execPath, '-e', `require("fs").writeFileSync(${JSON.stringify(marker)}, String(process.env.STOP_QUEUE_FAKE_TOKEN))`],
      payload: '',
    });
    // The worker's env carries another session's credential.
    process.env.STOP_QUEUE_FAKE_TOKEN = 'shibboleth';
    await work(dir);
    assert.equal(readFileSync(marker, 'utf8'), 'undefined');
  } finally {
    delete process.env.STOP_QUEUE_FAKE_TOKEN;
    rmSync(dir, { recursive: true, force: true });
  }
});

// [codex-4] The enqueuer sees a live lock just as the worker finishes its last
// empty read, so it skips spawning — and the entry is stranded. The worker's
// post-release re-check is what closes that window.
test('an entry arriving as the drain ends is still picked up before the worker exits', async () => {
  const dir = scratch();
  try {
    const marker = join(dir, 'ran.txt');
    const late = join(dir, 'entries', 'late.json');
    // The first job enqueues a SECOND entry while the worker is mid-drain —
    // i.e. it appears after the worker began, in the window that used to strand.
    mkdirSync(join(dir, 'entries'), { recursive: true });
    writeFileSync(join(dir, 'entries', 'first.json'), JSON.stringify({
      v: 1, key: 'first', created: Date.now(), ttl_ms: DEFAULT_TTL_MS, attempts: 0,
      argv: [process.execPath, '-e', `require("fs").writeFileSync(${JSON.stringify(late)}, JSON.stringify(${JSON.stringify({
        v: 1, key: 'late', created: Date.now(), ttl_ms: DEFAULT_TTL_MS, attempts: 0,
        argv: appendJob(marker, 'late'), cwd: dir, payload: '',
      })}))`],
      cwd: dir, payload: '',
    }));
    const result = await work(dir);
    assert.equal(result.ran, 2, 'the late entry was stranded instead of drained');
    assert.match(readFileSync(marker, 'utf8'), /late/);
    assert.equal(pending(dir).length, 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-5] Pin the DELIBERATE semantics the panel read as a bug: a job that
// runs to completion is done at whatever rc it produced. Re-running a hook that
// just reported failure reproduces the failure and doubles its side effects.
test('a job that runs and fails is not retried — the attempt budget covers crashes only', async () => {
  const dir = scratch();
  try {
    enqueue(dir, { name: 'j', argv: [process.execPath, '-e', 'process.exit(3)'], payload: '' });
    const result = await work(dir);
    assert.equal(result.ran, 1);
    assert.equal(pending(dir).length, 0, 'a failed job was requeued');
    const row = logRows(dir).find((r) => r.ev === 'ran');
    assert.equal(row.rc, 3);
    assert.equal(row.attempt, 1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// ------------------------------------------- panel findings round 2 (2004)

// [codex-1 r2] The attempt counter used to be written INTO the live entry
// before running, which re-opened the delete race one step earlier: a newer
// same-key entry renamed in just beforehand was overwritten by the stale one.
// The entry file is now write-once — published by rename, removed by the
// worker, never modified — and the counter lives in a sidecar.
test('running an entry never rewrites it — the attempt count lives outside', async () => {
  const dir = scratch();
  try {
    const seen = join(dir, 'seen.txt');
    enqueue(dir, {
      name: 'j',
      payload: '{"session_id":"s1"}',
      // The job copies its own CLAIMED entry aside while running; mid-run is
      // exactly where the old in-place attempt rewrite used to land.
      argv: [process.execPath, '-e',
        'const fs=require("fs");const d=' + JSON.stringify(join(dir, 'running')) + ';'
        + `const f=d+"/"+fs.readdirSync(d)[0];fs.writeFileSync(${JSON.stringify(seen)}, fs.readFileSync(f,"utf8"))`],
    });
    const before = readFileSync(join(dir, 'entries', 'j.s1.json'), 'utf8');
    await work(dir);
    assert.equal(readFileSync(seen, 'utf8'), before, 'the entry file was modified in place');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-7 r2] Two same-key enqueues can share a millisecond, so `created` is
// not a safe identity — a replacement would pass for the entry just run and be
// deleted unrun. `gen` is per-entry and collision-resistant.
test('each entry carries a unique generation id, independent of the clock', () => {
  const dir = scratch();
  try {
    enqueue(dir, { name: 'j', argv: ['a'], payload: '{"session_id":"s1"}' });
    const first = JSON.parse(readFileSync(join(dir, 'entries', 'j.s1.json'), 'utf8'));
    enqueue(dir, { name: 'j', argv: ['b'], payload: '{"session_id":"s1"}' });
    const second = JSON.parse(readFileSync(join(dir, 'entries', 'j.s1.json'), 'utf8'));
    assert.ok(first.gen && second.gen);
    assert.notEqual(first.gen, second.gen, 'a replacement reused the identity of the entry it replaced');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-2 r2] The post-drain re-check could take the lock on the LAST round
// and then fall out of the loop, leaving it held by a process that had already
// returned — every later enqueue would read a live worker until the stale-lock
// age cap expired.
test('the worker never returns while still holding the lock', async () => {
  const dir = scratch();
  try {
    // A job that enqueues another job, every time: the re-check always finds
    // work, so the loop runs its full round budget and exits on it.
    const spawnMore = (n) => [process.execPath, '-e',
      `const fs=require("fs");const p=${JSON.stringify(join(dir, 'entries'))};` +
      `fs.writeFileSync(p+"/gen${n}.json", JSON.stringify({v:1,key:"gen${n}",gen:"g${n}",created:Date.now(),ttl_ms:900000,argv:["${process.execPath.replace(/\\/g, '\\\\')}","-e","0"],cwd:${JSON.stringify(dir)},payload:""}))`];
    mkdirSync(join(dir, 'entries'), { recursive: true });
    for (let i = 0; i < 6; i += 1) {
      writeFileSync(join(dir, 'entries', `seed${i}.json`), JSON.stringify({
        v: 1, key: `seed${i}`, gen: `s${i}`, created: Date.now() + i, ttl_ms: DEFAULT_TTL_MS,
        argv: spawnMore(i), cwd: dir, payload: '',
      }));
    }
    await work(dir);
    assert.equal(existsSync(join(dir, 'worker.lock')), false, 'the worker exited holding the lock');
    assert.equal(workerIsLive(dir), false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-6 r2] status() read through the worker's pruning path, so inspecting
// the queue DELETED malformed entries and wrote log rows — destroying the
// evidence the operator opened it to look at.
test('status reports a malformed entry without deleting it', () => {
  const dir = scratch();
  try {
    mkdirSync(join(dir, 'entries'), { recursive: true });
    writeFileSync(join(dir, 'entries', 'junk.json'), '{ not json');
    const before = logRows(dir).length;
    const out = status(dir);
    assert.match(out, /CORRUPT/);
    assert.equal(existsSync(join(dir, 'entries', 'junk.json')), true, 'status deleted the evidence');
    assert.equal(logRows(dir).length, before, 'status wrote to the log');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-5 r2] A name-pattern denylist is inherently partial; these are the
// shapes it must not miss.
test('the secret denylist covers the common non-TOKEN credential names', () => {
  const scrubbed = scrubSecrets({
    PATH: '/usr/bin',
    DATABASE_URL: 'shibboleth',
    SENTRY_DSN: 'shibboleth',
    MY_PRIVATE_THING: 'shibboleth',
    SOME_CERT: 'shibboleth',
    A_BEARER: 'shibboleth',
  });
  assert.deepEqual(scrubbed, { PATH: '/usr/bin' });
});

// [codex-3 r2 / CRITIC-1 r3] Round 2 put the enqueue-failure fallback in the
// WIRING as `|| <original command>`. It could not work: stop-queue.mjs reads
// the hook payload from stdin before it can report failure, so the retried
// command got EOF and a payload-dependent hook quietly did nothing. Whoever
// consumes the payload owns the fallback — it belongs inside the process.
test('the wiring carries no shell fallback — stdin is already spent by then', () => {
  const settings = JSON.parse(readFileSync(join(HERE, '..', '..', '.claude', 'settings.json'), 'utf8'));
  for (const event of ['Stop', 'SessionEnd']) {
    for (const b of settings.hooks[event] || []) {
      for (const h of b.hooks || []) {
        assert.ok(!String(h.command).includes('||'),
          `${event} hook re-runs its command from the shell, against a drained stdin: ${h.command}`);
      }
    }
  }
});

test('a failed enqueue still delivers the payload it consumed', async () => {
  const dir = scratch();
  try {
    const blocked = join(dir, 'not-a-dir');
    writeFileSync(blocked, 'x');
    const marker = join(dir, 'inline.txt');
    const result = spawnSync(process.execPath, [
      SELF, 'enqueue', '--key', 'k', '--',
      process.execPath, '-e', `require("fs").writeFileSync(${JSON.stringify(marker)}, require("fs").readFileSync(0, "utf8"))`,
    ], {
      input: '{"session_id":"s1","hook_event_name":"Stop"}',
      env: { ...process.env, HIMMEL_STOP_QUEUE_DIR: blocked },
      encoding: 'utf8',
    });
    // 0, not 1: the fallback started, so it owns the work — a caller that also
    // fell back would be running it a second time.
    assert.equal(result.status, 0, result.stderr);
    // Detached, so give it a moment to land; the property under test is that
    // the payload reached it at all, not when.
    for (let i = 0; i < 50 && !existsSync(marker); i += 1) {
      await new Promise((r) => setTimeout(r, 100));
    }
    assert.equal(JSON.parse(readFileSync(marker, 'utf8')).hook_event_name, 'Stop',
      'the detached fallback ran without the payload');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-1 r3] An entry that never runs is the only thing that still knows
// about the payload temp file its argv names — the JOB is what would have
// deleted it.
test('an entry that expires takes its cleanup files with it', async () => {
  const dir = scratch();
  try {
    const orphan = join(dir, 'payload.tmp');
    writeFileSync(orphan, '{}');
    mkdirSync(join(dir, 'entries'), { recursive: true });
    writeFileSync(join(dir, 'entries', 'old.json'), JSON.stringify({
      v: 1, key: 'old', gen: 'g1', created: Date.now() - 60_000, ttl_ms: 1000,
      argv: [process.execPath, '-e', '0'], cwd: dir, payload: '', cleanup: [orphan],
    }));
    await work(dir);
    assert.equal(existsSync(orphan), false, 'the payload temp file leaked');
    assert.equal(logRows(dir).filter((r) => r.ev === 'expired').length, 1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('detach_queued passes its payload file to the queue as a cleanup path', () => {
  for (const name of ['jira-nudge-on-end', 'telegram-session-end']) {
    const body = readFileSync(join(HERE, `${name}.sh`), 'utf8');
    assert.match(body, new RegExp(`detach_queued ${name} --cleanup "\\$_tmp"`),
      `${name}.sh does not hand its temp payload to the queue`);
  }
});

// [codex-4 r3] A prefixed credential under a name the denylist did not spell
// out, and the case-sensitivity that let a lowercase one through. PATH must
// survive — an anchored PAT, never a substring one.
test('the denylist is case-insensitive and never eats PATH', () => {
  assert.deepEqual(scrubSecrets({
    PATH: '/usr/bin',
    HIMMEL_GITHUB_PAT: 'shibboleth',
    my_api_token: 'shibboleth',
    Database_Url: 'shibboleth',
  }), { PATH: '/usr/bin' });
});

// ------------------------------------------- panel findings round 4 (2004)

// [codex-1/2 r4] Three rounds of point-fixes kept NARROWING the read-check-then-
// delete window instead of closing it. Claiming by rename removes the class: the
// key path is vacated the instant work begins, so a replacement lands on a free
// path and is claimed in its own right. Nothing is compared, nothing mistaken.
test('a running job vacates its key path, so a replacement is never mistaken for it', async () => {
  const dir = scratch();
  try {
    const file = join(dir, 'entries', 'j.s1.json');
    const marker = join(dir, 'ran.txt');
    // Prepare the replacement as a file, so the job only has to copy it into
    // the key path — the same rename-in a real same-key enqueue performs.
    const replacementSrc = join(dir, 'replacement.json');
    mkdirSync(join(dir, 'entries'), { recursive: true });
    writeFileSync(replacementSrc, JSON.stringify({
      v: 1, key: 'j.s1', gen: 'replacement', created: Date.now(), ttl_ms: DEFAULT_TTL_MS,
      argv: appendJob(marker, 'second'), cwd: dir, payload: '',
    }));
    // The job announces itself, then drops the replacement at the key path
    // WHILE it is running.
    enqueue(dir, {
      name: 'j',
      payload: '{"session_id":"s1"}',
      argv: [process.execPath, '-e',
        `const fs=require("fs");fs.appendFileSync(${JSON.stringify(marker)},"first\\n");`
        + `fs.copyFileSync(${JSON.stringify(replacementSrc)}, ${JSON.stringify(file)});`],
    });
    await work(dir);
    const lines = readFileSync(marker, 'utf8').split('\n').filter(Boolean);
    assert.deepEqual(lines, ['first', 'second'], 'the replacement was lost instead of run');
    assert.equal(pending(dir).length, 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('claiming empties the key directory before the job runs', async () => {
  const dir = scratch();
  try {
    const seen = join(dir, 'seen.txt');
    enqueue(dir, {
      name: 'j',
      payload: '',
      argv: [process.execPath, '-e',
        `require("fs").writeFileSync(${JSON.stringify(seen)}, String(require("fs").readdirSync(${JSON.stringify(join(dir, 'entries'))}).length))`],
    });
    await work(dir);
    assert.equal(readFileSync(seen, 'utf8'), '0', 'the entry was still at its key path while running');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-3 r4] A timed-out job did NOT finish, so treating it as complete and
// deleting it discards unfinished work at the timeout mark. It stays claimed and
// is re-adopted under the crash budget, which is what bounds it.
test('a timed-out job is retained for the crash budget, not discarded', async () => {
  const dir = scratch();
  try {
    enqueue(dir, { name: 'slow', argv: [process.execPath, '-e', 'setTimeout(()=>{},60000)'], payload: '' });
    const result = await work(dir, { jobTimeoutMs: 400 });
    assert.equal(result.ran, 1);
    const rows = logRows(dir);
    assert.ok(rows.some((r) => r.ev === 'timeout'), 'no timeout row');
    assert.ok(rows.some((r) => r.ev === 'retained'), 'the timed-out job was discarded');
    // Still on disk, claimed, awaiting its next attempt.
    assert.equal(readdirSync(join(dir, 'running')).filter((f) => f.endsWith('.json')).length, 1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [HIMMEL-2028] spawnSync's timeout signalled the DIRECT child only, and every
// real job here is a tree — node run-hook-with-bash.js -> bash <hook>.sh ->
// curl / bun / python. A job that missed its deadline therefore left its
// descendants running OUTSIDE the concurrency bound and overlapping its own
// retry, which is the exact fan-out this queue exists to remove.
test('a timed-out job takes its whole process TREE with it', async () => {
  const dir = scratch();
  const started = [];
  try {
    const pidFile = join(dir, 'grandchild.pid');
    // How the grandchild must be spawned for this case to have TEETH, which is
    // platform-dependent and was measured, not assumed (2026-08-23, this box):
    //   POSIX   a plain grandchild inherits the job's process group — the group
    //           the deadline signals — and survives the direct child otherwise.
    //   Windows a plain grandchild is ALREADY torn down when its parent is
    //           stopped, so it would prove nothing. It has to DETACH to
    //           survive — which is exactly what a real end-side job body does
    //           (scripts/lib/detach.sh) — and taskkill /T still walks to it.
    const grandchildOpts = JSON.stringify(process.platform === 'win32'
      ? { stdio: 'ignore', detached: true, windowsHide: true }
      : { stdio: 'ignore' });
    // A job that spawns a grandchild outliving the deadline, records its pid,
    // then outlives the deadline itself. APPEND, so a later attempt cannot
    // overwrite the pid this case asserts on.
    enqueue(dir, {
      name: 'tree',
      payload: '',
      argv: [process.execPath, '-e',
        `const c = require("child_process").spawn(process.execPath, ["-e", "setTimeout(()=>{}, 60000)"], ${grandchildOpts}); c.unref();`
        + `require("fs").appendFileSync(${JSON.stringify(pidFile)}, c.pid + "\\n");`
        + 'setTimeout(() => {}, 60000);'],
    });
    // drain(), not work(): work() hands a retained job to a SUCCESSOR worker,
    // which would race this assertion by starting a second tree of its own.
    const result = await drain(dir, { jobTimeoutMs: 2000 });
    assert.equal(result.ran, 1);
    assert.ok(existsSync(pidFile), 'the job never reported its grandchild');
    const pid = Number(readFileSync(pidFile, 'utf8').split('\n')[0]);
    assert.ok(pid > 0, `unusable grandchild pid: ${pid}`);
    started.push(pid);
    assert.ok(await reaped(pid), `the grandchild (pid ${pid}) outlived the job deadline`);
  } finally {
    for (const pid of started) {
      try { process.kill(pid, 'SIGKILL'); } catch { /* already gone, which is the point */ }
    }
    rmSync(dir, { recursive: true, force: true });
  }
});

// [codex-1 HIMMEL-2028] The deadline fires on the DIRECT CHILD's liveness, not
// on 'close'. A job that finished but left a descendant holding its stderr pipe
// open never reaches 'close' — reading that as a deadline miss would retain a
// COMPLETED job for retry and repeat every side effect it already performed.
test('a job that FINISHED but left a pipe-holding survivor is recorded as ran, not timed out', async () => {
  const dir = scratch();
  const started = [];
  try {
    const pidFile = join(dir, 'holder.pid');
    // fd 2 is INHERITED by the grandchild — that is the worker's stderr pipe,
    // so 'close' cannot fire while the grandchild lives. On Windows it must
    // also detach to outlive its parent (see the tree case above).
    const holderOpts = JSON.stringify(process.platform === 'win32'
      ? { stdio: ['ignore', 'ignore', 'inherit'], detached: true, windowsHide: true }
      : { stdio: ['ignore', 'ignore', 'inherit'] });
    enqueue(dir, {
      name: 'holder',
      payload: '',
      argv: [process.execPath, '-e',
        `const c = require("child_process").spawn(process.execPath, ["-e", "setTimeout(()=>{}, 60000)"], ${holderOpts}); c.unref();`
        + `require("fs").appendFileSync(${JSON.stringify(pidFile)}, c.pid + "\\n");`],
      // …and the job itself exits immediately, well inside the deadline.
    });
    const result = await drain(dir, { jobTimeoutMs: 1500 });
    assert.equal(result.ran, 1);
    started.push(Number(readFileSync(pidFile, 'utf8').split('\n')[0]));
    const rows = logRows(dir);
    assert.ok(rows.some((r) => r.ev === 'ran' && r.rc === 0), 'a completed job was not recorded as ran');
    assert.ok(!rows.some((r) => r.ev === 'timeout'), 'a completed job was recorded as a deadline miss');
    assert.ok(!rows.some((r) => r.ev === 'retained'), 'a completed job was retained for retry');
    assert.equal(pending(dir).length, 0);
    assert.equal(readdirSync(join(dir, 'running')).filter((f) => f.endsWith('.json')).length, 0);
  } finally {
    for (const pid of started) {
      try { process.kill(pid, 'SIGKILL'); } catch { /* already gone */ }
    }
    rmSync(dir, { recursive: true, force: true });
  }
});

// [codex-1 HIMMEL-2028 r2] A job terminated by someone ELSE exits with a null
// status, no error and no deadline miss of ours — so classifying unfinished work
// on `timedOut` alone deleted it as completed and lost it. spawnSync's
// `result.signal` covered this before the async rewrite.
test('a job terminated by an external signal is retained, not deleted as done', {
  // Windows has no signals: a terminated child reports an exit CODE and a null
  // signal, so this case cannot be produced there. The Windows equivalents
  // (our own deadline reap, a spawn failure) are covered by their own cases.
  skip: process.platform === 'win32' ? 'no signals on Windows — a terminated child reports a code, never a signal' : false,
}, async () => {
  const dir = scratch();
  try {
    enqueue(dir, { name: 'doomed', payload: '', argv: [process.execPath, '-e', 'process.kill(process.pid, "SIGKILL")'] });
    const result = await drain(dir, { jobTimeoutMs: 30_000 });
    assert.equal(result.ran, 1);
    const rows = logRows(dir);
    assert.ok(rows.some((r) => r.ev === 'retained' && String(r.reason).startsWith('signalled-')),
      'an externally terminated job was not retained for the crash budget');
    assert.equal(readdirSync(join(dir, 'running')).filter((f) => f.endsWith('.json')).length, 1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('work adopts a job left claimed by a worker that never finished it', async () => {
  const dir = scratch();
  try {
    const marker = join(dir, 'ran.txt');
    mkdirSync(join(dir, 'running'), { recursive: true });
    writeFileSync(join(dir, 'running', 'orphan.json'), JSON.stringify({
      v: 1, key: 'orphan', gen: 'g-orphan', created: Date.now(), ttl_ms: DEFAULT_TTL_MS,
      argv: appendJob(marker, 'adopted'), cwd: dir, payload: '',
    }));
    assert.equal((await work(dir)).ran, 1);
    assert.match(readFileSync(marker, 'utf8'), /adopted/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-4 r4] The snapshot decided a job's gates but not its INTERPRETER, so
// every queued command resolved against the PATH of whichever session happened
// to start the worker.
test('the snapshot carries the interpreter and state variables', () => {
  const snap = snapshotEnv({ PATH: '/session/bin', HOME: '/session/home', TMPDIR: '/session/tmp', UNRELATED: 'x' });
  assert.equal(snap.PATH, '/session/bin');
  assert.equal(snap.HOME, '/session/home');
  assert.equal(snap.TMPDIR, '/session/tmp');
  assert.equal(snap.UNRELATED, undefined);
});

test('a job resolves its command against the enqueuing session PATH', async () => {
  const dir = scratch();
  try {
    const marker = join(dir, 'path.txt');
    const original = process.env.PATH;
    process.env.PATH = `${original}${process.platform === 'win32' ? ';' : ':'}/enqueuer-marker`;
    enqueue(dir, {
      name: 'j',
      argv: [process.execPath, '-e', `require("fs").writeFileSync(${JSON.stringify(marker)}, process.env.PATH)`],
      payload: '',
    });
    process.env.PATH = original;   // the worker's PATH differs, as a later session's would
    await work(dir);
    assert.match(readFileSync(marker, 'utf8'), /enqueuer-marker/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-5 r4] Flattening is lossy, so two unrelated session ids could collapse
// onto one filename and dedup into each other.
test('sanitizeKey keeps distinct raw inputs distinct', () => {
  assert.notEqual(sanitizeKey('a/b'), sanitizeKey('a\\b'));
  assert.notEqual(sanitizeKey('x'.repeat(150) + 'A'), sanitizeKey('x'.repeat(150) + 'B'));
  // Already filename-safe input is untouched — the common case stays readable.
  assert.equal(sanitizeKey('speak-reply.abc_123'), 'speak-reply.abc_123');
});

// ------------------------------------------- panel findings round 5 (2004)

// [codex-1 r5] Round 4 started retaining timed-out jobs under running/, but the
// successor handoff still only looked at entries/ — so the one job that needed
// a successor most was the one that could not get one.
test('a retained job still gets a successor worker', async () => {
  const dir = scratch();
  try {
    mkdirSync(join(dir, 'running'), { recursive: true });
    writeFileSync(join(dir, 'running', 'stuck.json'), JSON.stringify({
      v: 1, key: 'stuck', gen: 'g-stuck', created: Date.now(), ttl_ms: DEFAULT_TTL_MS,
      argv: [process.execPath, '-e', '0'], cwd: dir, payload: '',
    }));
    // A worker that cannot take the lock still must not swallow the handoff
    // decision; here it runs normally and the queue ends empty.
    assert.equal((await work(dir)).ran, 1);
    assert.equal(readdirSync(join(dir, 'running')).filter((f) => f.endsWith('.json')).length, 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-3 r5] The wired hooks carry a 10s harness timeout while a job may take
// 120s, so an INLINE fallback would be killed by teardown — losing exactly the
// work the fallback exists to save. It detaches instead, as the pre-queue path
// did, and returns at once.
test('the enqueue-failure fallback detaches instead of blocking the hook', () => {
  const dir = scratch();
  try {
    const blocked = join(dir, 'not-a-dir');
    writeFileSync(blocked, 'x');
    const marker = join(dir, 'detached.txt');
    const started = Date.now();
    const result = spawnSync(process.execPath, [
      SELF, 'enqueue', '--key', 'k', '--',
      process.execPath, '-e',
      `setTimeout(() => require("fs").writeFileSync(${JSON.stringify(marker)}, "late"), 1200)`,
    ], {
      input: '',
      env: { ...process.env, HIMMEL_STOP_QUEUE_DIR: blocked },
      encoding: 'utf8',
    });
    const elapsed = Date.now() - started;
    assert.equal(result.status, 0, result.stderr);
    // It must NOT have waited for the 1.2s child — that is the whole point.
    assert.ok(elapsed < 1000, `the fallback blocked the hook for ${elapsed}ms`);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-4 r5] Reporting `pending: 0` while jobs sit unfinished in running/ is
// how an operator concludes the queue is idle when it is actually stuck.
test('status counts unfinished work, not just queued work', () => {
  const dir = scratch();
  try {
    mkdirSync(join(dir, 'running'), { recursive: true });
    writeFileSync(join(dir, 'running', 'stuck.json'), JSON.stringify({
      v: 1, key: 'stuck-job', gen: 'g1', created: Date.now(), ttl_ms: DEFAULT_TTL_MS,
      argv: ['echo'], cwd: dir, payload: '',
    }));
    const out = status(dir);
    assert.match(out, /\+1 unfinished/);
    assert.match(out, /stuck-job.*UNFINISHED/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// ------------------------------------------- panel findings round 6 (2004)

// [codex-1 r6] A command that cannot be SPAWNED sets result.error with no
// signal. The worker treated that as a completed run and deleted the entry —
// losing work that never executed. Same ran-versus-never-started line the
// enqueue fallback draws; the two must agree.
test('a job that never started is retained, not deleted as done', async () => {
  const dir = scratch();
  try {
    enqueue(dir, { name: 'j', argv: [join(dir, 'no-such-binary-at-all')], payload: '' });
    const result = await work(dir);
    assert.equal(pending(dir).length, 0);
    // Retained under running/, awaiting its next attempt — NOT discarded.
    assert.equal(readdirSync(join(dir, 'running')).filter((f) => f.endsWith('.json')).length, 1);
    const row = logRows(dir).find((r) => r.ev === 'retained');
    assert.ok(row, 'no retained row for a job that never started');
    assert.equal(row.reason, 'spawn-failed');
    assert.equal(result.ran, 1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-2 r6] readEntries got `prune` in round 2; readRunning arrived in round
// 4 without it, so status() started deleting malformed CLAIMED entries again.
test('status does not delete a malformed claimed entry either', () => {
  const dir = scratch();
  try {
    mkdirSync(join(dir, 'running'), { recursive: true });
    writeFileSync(join(dir, 'running', 'junk.json'), '{ not json');
    const before = logRows(dir).length;
    const out = status(dir);
    assert.match(out, /CORRUPT/);
    assert.equal(existsSync(join(dir, 'running', 'junk.json')), true, 'status deleted the evidence');
    assert.equal(logRows(dir).length, before, 'status wrote to the log');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-4 r6] The TTL must outlast a legitimate backlog, or the queue expires
// its own tail before ever attempting it.
test('the default TTL comfortably exceeds a full backlog of timing-out jobs', () => {
  // A worst-case drain is a full fleet whose jobs each burn the whole job
  // timeout, serially. Ten such jobs is already far past any real end-of-session
  // fleet, and the TTL must still outlast it with room to spare — otherwise the
  // queue expires its own tail before the worker ever reaches it.
  const worstCaseDrainMs = 10 * DEFAULT_JOB_TIMEOUT_MS;
  assert.ok(
    DEFAULT_TTL_MS > worstCaseDrainMs,
    `TTL ${DEFAULT_TTL_MS}ms does not outlast a ${worstCaseDrainMs}ms drain — queued work would expire unattempted`,
  );
});

// [codex-2 r7] `KEY` must stay broad enough to catch ANTHROPIC_API_KEY, and no
// name-shaped rule can tell that from JIRA_PROJECT_KEY — which the Jira hook
// reads. The exception is explicit rather than guessed at by the pattern.
test('a non-secret name the denylist happens to match is excepted by name', () => {
  const scrubbed = scrubSecrets({
    PATH: '/usr/bin',
    JIRA_PROJECT_KEY: 'HIMMEL',
    ANTHROPIC_API_KEY: 'shibboleth',
    GH_TOKEN: 'shibboleth',
  });
  assert.equal(scrubbed.JIRA_PROJECT_KEY, 'HIMMEL');
  assert.equal(scrubbed.PATH, '/usr/bin');
  assert.equal(scrubbed.ANTHROPIC_API_KEY, undefined);
  assert.equal(scrubbed.GH_TOKEN, undefined);
});

// [codex-3 r7] The docs claimed a 15-minute TTL after round 6 raised it to an
// hour. A stale number in a reference doc is the drift the docs-audit charter
// exists for, so pin it here rather than trusting a re-read.
test('the documented TTL matches the code', () => {
  const doc = readFileSync(join(HERE, '..', '..', 'docs', 'internals', 'enforcement.md'), 'utf8');
  const hours = DEFAULT_TTL_MS / (60 * 60 * 1000);
  assert.match(doc, new RegExp(`default ${hours} h`),
    `enforcement.md does not document the real TTL (${DEFAULT_TTL_MS}ms)`);
});

// [codex-2 r8] The exception belongs in BOTH env paths. Applying it only to the
// inherited base meant JIRA_PROJECT_KEY reached a job from whichever session
// started the worker, never from the session that queued it — the exact
// cross-session bug the per-entry snapshot exists to prevent.
test('session configuration is snapshotted, not inherited from the worker', () => {
  const snap = snapshotEnv({ JIRA_PROJECT_KEY: 'HIMMEL', ANTHROPIC_API_KEY: 'shibboleth', PATH: '/bin' });
  assert.equal(snap.JIRA_PROJECT_KEY, 'HIMMEL');
  assert.equal(snap.ANTHROPIC_API_KEY, undefined);
});

test('the entry carries the enqueuing session project key', () => {
  const dir = scratch();
  try {
    process.env.JIRA_PROJECT_KEY = 'FROMSESSION';
    enqueue(dir, { name: 'j', argv: ['echo'], payload: '' });
    const entry = JSON.parse(readFileSync(join(dir, 'entries', pending(dir)[0]), 'utf8'));
    assert.equal(entry.env.JIRA_PROJECT_KEY, 'FROMSESSION');
  } finally {
    delete process.env.JIRA_PROJECT_KEY;
    rmSync(dir, { recursive: true, force: true });
  }
});

// [codex-3 r10 / codex-2 r11] Dedup DISCARDS the entry it replaces, and the job
// that would have deleted that entry's cleanup files is exactly the one being
// superseded — so they leak unless someone adopts them. The new entry does.
// Deleting them AT replace time would be wrong: a worker may have claimed the
// old entry moments earlier and be running it, and pulling its payload file
// would break a job in flight.
test('a superseded cleanup file is carried forward, not pulled from under a running job', async () => {
  const dir = scratch();
  try {
    const old = join(dir, 'old-payload.tmp');
    writeFileSync(old, '{}');
    enqueue(dir, { name: 'j', argv: ['a'], payload: '{"session_id":"s1"}', cleanup: [old] });
    enqueue(dir, {
      name: 'j',
      payload: '{"session_id":"s1"}',
      argv: [process.execPath, '-e', '0'],
    });
    // Still there while the replacement is merely QUEUED.
    assert.equal(existsSync(old), true, 'a possibly-running job lost its payload file');
    const entry = JSON.parse(readFileSync(join(dir, 'entries', 'j.s1.json'), 'utf8'));
    assert.deepEqual(entry.cleanup, [old], 'the superseded file was not adopted');
    // ...and cleared once the entry that adopted it has run.
    await work(dir);
    assert.equal(existsSync(old), false, 'the superseded payload file leaked');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-4 r10] "No session" must mean "never merge". A pid + millisecond pair
// is not unique within one process.
test('two no-session enqueues from one process never collapse', () => {
  const dir = scratch();
  try {
    enqueue(dir, { name: 'j', argv: ['a'], payload: '' });
    enqueue(dir, { name: 'j', argv: ['b'], payload: '' });
    assert.equal(pending(dir).length, 2, 'two unrelated jobs deduped into one');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-1 r11] Clearing a stale lock by delete-then-create is racy, and racy
// here means TWO workers draining — the one thing the lock exists to prevent.
// The slower worker would delete the lock the faster one had just legitimately
// created. Renaming it away instead lets exactly one process win.
// Sequential work() calls cannot see this race at all — by the time the second
// runs, the first has finished. The workers have to be REAL, CONCURRENT
// processes contending for the same stale lock, which is why this case shells
// out instead of calling work() twice.
test('two workers racing the same stale lock cannot both drain', async () => {
  const dir = scratch();
  try {
    const marker = join(dir, 'ran.txt');
    // A job slow enough that a second worker would still be inside the drain
    // window if it wrongly took the lock.
    enqueue(dir, {
      name: 'j',
      payload: '',
      argv: [process.execPath, '-e',
        `const fs=require("fs");fs.appendFileSync(${JSON.stringify(marker)},"once\\n");`
        + 'const t=Date.now();while(Date.now()-t<700);'],
    });
    // A stale lock, as a killed worker leaves behind.
    mkdirSync(join(dir, 'worker.lock'), { recursive: true });
    writeFileSync(join(dir, 'worker.lock', 'pid'), '0');
    assert.equal(lockIsStale(dir), true);

    const runWorker = () => new Promise((resolve) => {
      const child = spawn(process.execPath, [SELF, 'work'], {
        env: { ...process.env, HIMMEL_STOP_QUEUE_DIR: dir },
        stdio: 'ignore',
      });
      child.on('exit', resolve);
      child.on('error', () => resolve(null));
    });
    await Promise.all([runWorker(), runWorker(), runWorker()]);

    const ran = readFileSync(marker, 'utf8').split('\n').filter(Boolean).length;
    assert.equal(ran, 1, `the job ran ${ran} times — two workers held the lock at once`);
    // Nobody leaves a lock or a parked stale directory behind.
    assert.equal(existsSync(join(dir, 'worker.lock')), false);
    assert.deepEqual(readdirSync(dir).filter((f) => f.startsWith('worker.lock')), []);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-1 r13] Overlaying the snapshot is not enough: ABSENCE is data. Session
// A sets a gate, session B does not, and B's job would inherit A's value from
// the worker and fire something B had switched off. The snapshot is
// authoritative over the names it owns, so an unset gate must arrive unset.
test('a gate the enqueuing session did not set is not inherited from the worker', () => {
  const env = jobEnv({ CLAUDE_PROJECT_DIR: '/b', PATH: '/b/bin' }, {
    PATH: '/a/bin',
    SYSTEMROOT: 'C:\\Windows',    // owned since HIMMEL-2030 r4 — see below
    HIMMEL_JIRA_NUDGE: '1',       // the WORKER session's gate
    JIRA_PROJECT_KEY: 'OTHER',    // the WORKER session's config
    CLAUDE_PROJECT_DIR: '/a',
  });
  assert.equal(env.HIMMEL_JIRA_NUDGE, undefined, 'a foreign gate leaked into the job');
  assert.equal(env.JIRA_PROJECT_KEY, undefined, 'foreign session config leaked into the job');
  assert.equal(env.CLAUDE_PROJECT_DIR, '/b', "the entry's own value must win");
  assert.equal(env.PATH, '/b/bin', 'an owned name must come from the entry, not the worker');
  // [codex-1 r4, HIMMEL-2030] SYSTEMROOT used to pass through as "the
  // interpreter's, not a session's". The system set is snapshot-owned now — TZ,
  // LANG, LC_*, XDG_* and the version-manager roots are all per-session, and
  // XDG_* names where a tool keeps its credentials — so a snapshotted entry
  // inherits NOTHING from the worker.
  assert.equal(env.SYSTEMROOT, undefined, "a system name crossed from the worker's session");
  assert.equal(env.HIMMEL_DETACH_INLINE, '1');
});

// An entry with no snapshot at all predates the feature (queued before an
// upgrade, still inside its TTL). Treating it as authoritative would hand the
// job an environment with no PATH and no HOME — far worse than inheriting.
test('a snapshot-less entry falls back to inheriting rather than starving', () => {
  const env = jobEnv({}, {
    PATH: '/a/bin', HOME: '/a', SYSTEMROOT: 'C:\\Windows',
    HIMMEL_JIRA_NUDGE: '1', HIMMEL_MQTT_PASS: 'shibboleth',
  });
  assert.equal(env.PATH, '/a/bin');
  assert.equal(env.HOME, '/a');
  assert.equal(env.SYSTEMROOT, 'C:\\Windows');
  // [codex-1 r5, HIMMEL-2030] Enough environment to RUN, and no more. This
  // branch used to take snapshotOwns, whose ENV_PREFIXES half is a wildcard —
  // `^HIMMEL_` also admits HIMMEL_MQTT_PASS, and PASS is not a denylist shape.
  // The worker's own gates go with it: they are another session's answer.
  assert.equal(env.HIMMEL_MQTT_PASS, undefined, 'a prefix wildcard let a credential cross');
  assert.equal(env.HIMMEL_JIRA_NUDGE, undefined, "another session's gate crossed into a legacy job");
});

test('a job sees only its own session gates end to end', async () => {
  const dir = scratch();
  try {
    const marker = join(dir, 'gate.txt');
    // Enqueued by a session with the gate OFF (unset).
    delete process.env.HIMMEL_STOP_QUEUE_FAKE_GATE;
    enqueue(dir, {
      name: 'j',
      argv: [process.execPath, '-e', `require("fs").writeFileSync(${JSON.stringify(marker)}, String(process.env.HIMMEL_STOP_QUEUE_FAKE_GATE))`],
      payload: '',
    });
    // The worker belongs to a session that had it ON.
    process.env.HIMMEL_STOP_QUEUE_FAKE_GATE = 'on';
    await work(dir);
    assert.equal(readFileSync(marker, 'utf8'), 'undefined');
  } finally {
    delete process.env.HIMMEL_STOP_QUEUE_FAKE_GATE;
    rmSync(dir, { recursive: true, force: true });
  }
});

// [codex-2 r14] A worktree pruned while its work sat in the queue is exactly
// the case the queue's out-of-repo location anticipates. Falling back to the
// worker's cwd would point a repo-relative hook at a DIFFERENT checkout.
test('a job whose working directory has gone is dropped, not run somewhere else', async () => {
  const dir = scratch();
  try {
    const marker = join(dir, 'ran.txt');
    mkdirSync(join(dir, 'entries'), { recursive: true });
    writeFileSync(join(dir, 'entries', 'gone.json'), JSON.stringify({
      v: 1, key: 'gone', gen: 'g1', created: Date.now(), ttl_ms: DEFAULT_TTL_MS,
      argv: appendJob(marker, 'wrong-repo'),
      cwd: join(dir, 'a-worktree-that-was-pruned'),
      payload: '', env: { PATH: process.env.PATH },
    }));
    await work(dir);
    assert.equal(existsSync(marker), false, 'the job ran against the wrong checkout');
    const row = logRows(dir).find((r) => r.ev === 'dropped');
    assert.ok(row, 'the drop was not logged');
    assert.equal(row.reason, 'cwd-gone');
    assert.equal(pending(dir).length, 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-2 r15] A job's stderr lands in a DURABLE file, so a hook that prints a
// credential would persist it. Redact rather than drop — stderr is how a
// failing job gets debugged.
test('captured stderr is redacted before it reaches the durable log', () => {
  assert.match(redactSecrets('TELEGRAM_BOT_TOKEN=123:abcDEF'), /TELEGRAM_BOT_TOKEN=<redacted>/);
  assert.match(redactSecrets('api_key: sk-abcdefghij'), /api_key: <redacted>/);
  assert.match(redactSecrets('curl https://api.telegram.org/bot99:XYZ/sendMessage'),
    /api\.telegram\.org\/bot<redacted>/);
  assert.match(redactSecrets('ghp_abcdefghijklmnopqrst'), /<redacted>/);
  assert.match(redactSecrets(`opaque ${'a'.repeat(48)} blob`), /opaque <redacted> blob/);
  // Ordinary diagnostics must survive, or the redaction destroys the value.
  assert.equal(redactSecrets('git: not a repository (or any parent)'),
    'git: not a repository (or any parent)');
});

test('a job stderr row in the log carries no credential', async () => {
  const dir = scratch();
  try {
    enqueue(dir, {
      name: 'noisy',
      argv: [process.execPath, '-e', 'console.error("GH_TOKEN=ghp_abcdefghijklmnopqrst"); process.exit(1)'],
      payload: '',
    });
    await work(dir);
    const row = logRows(dir).find((r) => r.ev === 'ran' && r.stderr);
    assert.ok(row, 'no stderr captured');
    assert.equal(row.stderr.includes('ghp_abcdefghijklmnopqrst'), false, 'a token was written to the log');
    assert.match(row.stderr, /<redacted>/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-1 r16] The env denylist and the log redactor must recognise the same
// names, or a credential the env fence strips is still printed to the log.
test('the log redactor covers the same names the env denylist does', () => {
  for (const name of ['DATABASE_URL', 'SENTRY_DSN', 'GH_TOKEN', 'MY_PRIVATE_THING']) {
    assert.equal(scrubSecrets({ [name]: 'x' })[name], undefined, `${name} not stripped from env`);
    assert.match(redactSecrets(`${name}=shibboleth`), /<redacted>/, `${name} not redacted in the log`);
  }
});

// [codex-2 r16] A retained job whose attempt counter cannot be written would sit
// at zero forever, and every pass hands off to a fresh successor worker — an
// unbounded spawn loop, the exact fan-out this queue removes.
test('a job whose attempt counter cannot be written is dropped, not looped on', async () => {
  const dir = scratch();
  try {
    enqueue(dir, { name: 'slow', argv: [process.execPath, '-e', 'setTimeout(()=>{},60000)'], payload: '' });
    // Make the attempts directory unwritable by putting a FILE where it goes.
    rmSync(join(dir, 'attempts'), { recursive: true, force: true });
    writeFileSync(join(dir, 'attempts'), 'x');
    await work(dir, { jobTimeoutMs: 400 });
    const row = logRows(dir).find((r) => r.ev === 'dropped' && r.reason === 'attempt-counter-unwritable');
    assert.ok(row, 'an uncountable retained job was looped on instead of dropped');
    assert.equal(readdirSync(join(dir, 'running')).filter((f) => f.endsWith('.json')).length, 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-3 r16] A non-string argv element makes spawnSync THROW, which would
// crash the worker on every pass with the entry still in place.
test('an entry with a malformed argv is reported and removed, not left to poison', async () => {
  const dir = scratch();
  try {
    mkdirSync(join(dir, 'entries'), { recursive: true });
    writeFileSync(join(dir, 'entries', 'bad.json'), JSON.stringify({
      v: 1, key: 'bad', gen: 'g1', created: Date.now(), ttl_ms: DEFAULT_TTL_MS,
      argv: ['echo', { not: 'a string' }], cwd: dir, payload: '',
    }));
    await work(dir);
    assert.equal(logRows(dir).filter((r) => r.ev === 'corrupt').length, 1);
    assert.equal(pending(dir).length, 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-1 r17] A non-string cwd is valid JSON but makes existsSync and
// spawnSync THROW, so the entry would crash the worker on every drain while
// staying in place — a poison pill that never gets logged as one.
test('an entry with a malformed cwd is reported and removed, not left to poison', async () => {
  const dir = scratch();
  try {
    mkdirSync(join(dir, 'entries'), { recursive: true });
    writeFileSync(join(dir, 'entries', 'bad.json'), JSON.stringify({
      v: 1, key: 'bad', gen: 'g1', created: Date.now(), ttl_ms: DEFAULT_TTL_MS,
      argv: ['echo'], cwd: 42, payload: '',
    }));
    await work(dir);   // must not throw
    assert.equal(logRows(dir).filter((r) => r.ev === 'corrupt').length, 1);
    assert.equal(pending(dir).length, 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// [codex-2 r17] maxPasses bounds the RESCANS, not the jobs in one pass, so the
// in-hook recovery drain would still work through a whole queued fleet and blow
// the hook's 10-second budget.
test('a bounded drain stops after its job budget, not after the batch', async () => {
  const dir = scratch();
  try {
    const marker = join(dir, 'ran.txt');
    for (let i = 0; i < 5; i += 1) {
      enqueue(dir, { name: 'j', argv: appendJob(marker, `job${i}`), payload: JSON.stringify({ session_id: `s${i}` }) });
    }
    const result = await drain(dir, { maxJobs: 1 });
    assert.equal(result.ran, 1, 'the bounded drain ran the whole batch');
    assert.equal(readFileSync(marker, 'utf8').split('\n').filter(Boolean).length, 1);
    assert.equal(pending(dir).length, 4, 'the rest must stay queued for a real worker');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('drain is a no-op on an empty queue', async () => {
  const dir = scratch();
  try {
    assert.deepEqual(await drain(dir), { ran: 0, expired: 0 });
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// ------------------------------------- HIMMEL-2030: the base is an ALLOWLIST

// The finding three CR rounds kept deferring. `scrubSecrets` is a NAME-pattern
// denylist, so it can only strip what someone wrote down — and this box really
// does carry credentials it does not match (GGS_MQTT_PASS is neither PASSWORD
// nor PASSWD). The denylist still not matching is the POINT of this case: it is
// the allowlist base, not the fence, that keeps the value out of the job.
test('a credential under a name the denylist cannot match still never reaches a job', async () => {
  const dir = scratch();
  const NAME = 'GGS_MQTT_PASS';
  try {
    assert.equal(scrubSecrets({ [NAME]: 'shibboleth' })[NAME], 'shibboleth',
      'the denylist matches this name after all — pick one it genuinely cannot');
    const marker = join(dir, 'unguessable.txt');
    enqueue(dir, {
      name: 'j',
      argv: [process.execPath, '-e', `require("fs").writeFileSync(${JSON.stringify(marker)}, String(process.env.${NAME}))`],
      payload: '',
    });
    process.env[NAME] = 'shibboleth';
    await work(dir);
    assert.equal(readFileSync(marker, 'utf8'), 'undefined');
  } finally {
    delete process.env[NAME];
    rmSync(dir, { recursive: true, force: true });
  }
});

// The allowlist's failure direction is a job that breaks only on one machine,
// so pin what it must carry: the names the enumeration justified, and nothing
// resembling per-session state. This is the LEGACY branch (an entry with no
// snapshot); a snapshotted entry inherits nothing at all — see the case below.
test('the allowlist base carries the system names and drops everything unnamed', () => {
  const env = jobEnv({}, {
    PATH: '/bin', HOME: '/h',
    SYSTEMROOT: 'C:\\Windows', ComSpec: 'C:\\Windows\\system32\\cmd.exe',
    PATHEXT: '.COM;.EXE', 'ProgramFiles(x86)': 'C:\\PF86', windir: 'C:\\Windows',
    MSYSTEM: 'MINGW64', LANG: 'en_US.UTF-8', LC_ALL: 'en_US.UTF-8', TZ: 'UTC',
    NVM_DIR: '/n', XDG_CONFIG_HOME: '/x',
    // Not system, not a gate, not in the snapshot: no reason to cross.
    GGS_MQTT_PASS: 'shibboleth', LUNA_VAULT_PATH: '/v', JAVA_HOME: '/j',
    // [codex-1] A PREFIX inside an allowlist is a denylist wearing a costume:
    // `^XDG_` also admits this, and PASS is not one of the denylist's shapes.
    // The namespaces are spelled out name by name for exactly this reason.
    XDG_MQTT_PASS: 'shibboleth', NVM_MQTT_PASS: 'shibboleth',
    // On the allowlist by shape, but the denylist fence runs after it.
    SSH_AUTH_SOCK: '/tmp/agent',
  });
  for (const name of ['SYSTEMROOT', 'ComSpec', 'PATHEXT', 'ProgramFiles(x86)', 'windir',
    'MSYSTEM', 'LANG', 'LC_ALL', 'TZ', 'NVM_DIR', 'XDG_CONFIG_HOME']) {
    assert.ok(name in env, `${name} must reach the job — the interpreter half of the base`);
  }
  for (const name of ['GGS_MQTT_PASS', 'LUNA_VAULT_PATH', 'JAVA_HOME', 'SSH_AUTH_SOCK',
    'XDG_MQTT_PASS', 'NVM_MQTT_PASS']) {
    assert.equal(env[name], undefined, `${name} crossed from the worker's session`);
  }
});

// [codex-1 r4] The end state the allowlist buys: for an entry that HAS a
// snapshot, nothing whatsoever crosses from the worker. Not a credential, not a
// per-session config path, not even a name on the system list — every value the
// job sees came from the session that queued it.
test('a snapshotted entry inherits nothing at all from the worker', () => {
  const env = jobEnv({ PATH: '/b/bin', HOME: '/b' }, {
    PATH: '/a/bin', HOME: '/a', SYSTEMROOT: 'C:\\Windows', PATHEXT: '.EXE',
    TZ: 'UTC', LANG: 'en_US.UTF-8', XDG_CONFIG_HOME: '/a/.config', NVM_DIR: '/a/nvm',
    GGS_MQTT_PASS: 'shibboleth',
  });
  assert.deepEqual(env, { PATH: '/b/bin', HOME: '/b', HIMMEL_DETACH_INLINE: '1' });
});

// [codex-1] The allowlist must contain no wildcards at all — a prefix rule is
// the same unbounded-name problem the denylist had, and a future edit adding
// one back must fail here rather than at a leak.
test('the allowlist admits no name it does not spell out', () => {
  for (const name of ['XDG_MQTT_PASS', 'LC_MQTT_PASS', 'MSYS_MQTT_PASS', 'NVM_MQTT_PASS',
    'FNM_MQTT_PASS', 'VOLTA_MQTT_PASS', 'ASDF_MQTT_PASS']) {
    assert.equal(snapshotOwns(name), false, `${name} is admitted by a wildcard, not by name`);
  }
  for (const name of ['XDG_CONFIG_HOME', 'LC_ALL', 'MSYSTEM', 'NVM_DIR', 'VOLTA_HOME']) {
    assert.equal(snapshotOwns(name), true, `${name} must still be inheritable by name`);
  }
  // [codex-1 r6] ENV_ALWAYS was matched case-sensitively while everything else
  // was not. A miss there is not a leak but the other failure — a job handed no
  // PATH at all.
  for (const name of ['path', 'Home', 'tmpdir']) {
    assert.equal(snapshotOwns(name), true, `${name} is not recognised as an essential name`);
  }
});

// An adopter on a platform this enumeration never saw must not be bricked, and
// the hatch must not become a way to hand a job someone else's value.
//
// [codex-1 r2/r3] It widens the SNAPSHOT, not the base. Widening the base took
// the NAME from the enqueuing session and the VALUE from whichever session
// started the worker — so a job got another session's value for a name its own
// session chose. Both halves have to come from the same session.
test("the extra-names hatch carries the enqueuing session's own value", () => {
  const session = {
    PATH: '/b', HIMMEL_STOP_QUEUE_ENV_EXTRA: 'ODD_PLATFORM_ROOT, ODD_PLATFORM_TOKEN',
    ODD_PLATFORM_ROOT: '/mine', ODD_PLATFORM_TOKEN: 'shibboleth',
  };
  const snap = snapshotEnv(session);
  assert.equal(snap.ODD_PLATFORM_ROOT, '/mine', 'the hatch did not widen the snapshot');
  assert.equal(snap.ODD_PLATFORM_TOKEN, undefined, 'the hatch wrote a credential into an entry on disk');
  const worker = { PATH: '/a', ODD_PLATFORM_ROOT: '/theirs', HIMMEL_STOP_QUEUE_ENV_EXTRA: 'ODD_PLATFORM_ROOT' };
  assert.equal(jobEnv(snap, worker).ODD_PLATFORM_ROOT, '/mine',
    "the worker session's value reached another session's job");
  // A session that named nothing gets nothing — even though the worker's own
  // session named one. Absence is data here too.
  assert.equal(jobEnv({ PATH: '/b' }, worker).ODD_PLATFORM_ROOT, undefined,
    "the worker session's hatch widened another session's job");
  // [codex-2 r2] Windows environment names are case-insensitive, so a
  // case-sensitive hatch would silently no-op on a correct-looking setting.
  assert.equal(
    snapshotEnv({ HIMMEL_STOP_QUEUE_ENV_EXTRA: 'odd_platform_root', ODD_PLATFORM_ROOT: '/mine' }).ODD_PLATFORM_ROOT,
    '/mine',
  );
});

// Smoke, not theory: the interpreters every queued end-side hook actually names
// as argv[0] must still START under the allowlist base. `bun` is optional on a
// fresh clone; a missing one is not this suite's failure.
test('every interpreter the queued end-side hooks name still runs under the allowlist base', () => {
  const env = jobEnv(snapshotEnv(process.env));
  for (const bin of ['node', 'bash', 'bun']) {
    const r = spawnSync(bin, ['--version'], { env, encoding: 'utf8', shell: false });
    if (r.error && bin === 'bun') continue;
    assert.equal(r.status, 0, `${bin} does not run under the allowlist base: ${r.error || r.stderr}`);
  }
});

// End to end through the real queue with a REAL end-side hook — the one with a
// hermetic seam (its suite's shape: stub refresh, temp state dir, no network).
// If the allowlist starved a job's environment, this is where it shows.
test('a real end-side hook still runs to completion under the allowlist base', async () => {
  const dir = scratch();
  const REPO = join(HERE, '..', '..');
  const saved = { ...process.env };
  try {
    const sentinel = join(dir, 'collected');
    const state = join(dir, 'state');
    mkdirSync(state, { recursive: true });
    process.env.HIMMEL_REPO = REPO;
    process.env.WHERE_ARE_WE_STATE_DIR = state;
    process.env.HIMMEL_WHERE_ARE_WE = '1';
    process.env.HIMMEL_WHERE_ARE_WE_COLLECT_CMD = `touch '${sentinel.split(sep).join('/')}'`;
    enqueue(dir, {
      name: 'where-are-we-on-end',
      argv: ['bash', join(HERE, 'refresh-where-are-we-on-end.sh'), '__himmel_detached'],
      payload: '',
    });
    await work(dir);
    const row = logRows(dir).find((r) => r.ev === 'ran');
    assert.ok(row, 'the job never ran');
    assert.equal(row.rc, 0, `the hook failed under the allowlist base: ${row.stderr || ''}`);
    assert.ok(existsSync(sentinel), 'the hook did no work under the allowlist base');
    assert.ok(existsSync(join(state, '.refreshed-at')), 'the hook stamped no freshness marker');
  } finally {
    for (const k of ['HIMMEL_REPO', 'WHERE_ARE_WE_STATE_DIR', 'HIMMEL_WHERE_ARE_WE', 'HIMMEL_WHERE_ARE_WE_COLLECT_CMD']) {
      if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k];
    }
    rmSync(dir, { recursive: true, force: true });
  }
});

// An allowlist an adopter cannot widen is a brick, and one they cannot find out
// about is the same thing. Same reasoning as the TTL pin above.
test('the escape hatch is documented where the secrets model is', () => {
  const doc = readFileSync(join(HERE, '..', '..', 'docs', 'internals', 'enforcement.md'), 'utf8');
  assert.match(doc, /HIMMEL_STOP_QUEUE_ENV_EXTRA/,
    'enforcement.md does not name the allowlist escape hatch');
});
