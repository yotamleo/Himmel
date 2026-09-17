import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import { EventEmitter } from 'node:events';
import { renderPromptCacheEconomicsLine } from '../dist/render/lines/prompt-cache-economics.js';
import {
  formatCacheTokens,
  getAllSessionsCacheEconomics,
  runCacheEconomicsRefresh,
  createSpawnRefresh,
  getRefreshLockTokenFromArgv,
} from '../dist/cache-economics.js';
import { shouldRunCacheEconomicsRefresh } from '../dist/index.js';

function stripAnsi(str) {
  // eslint-disable-next-line no-control-regex
  return str.replace(/\x1b\[[0-9;]*m/g, '');
}

function usageLine(u) {
  return JSON.stringify({ type: 'assistant', message: { usage: u } }) + '\n';
}

function cacheDirFor(home) {
  return path.join(home, '.claude', 'plugins', 'claude-hud');
}

function baseContext() {
  return {
    stdin: { model: { display_name: 'Claude Sonnet 4.5' } },
    transcript: { tools: [], agents: [], todos: [] },
    claudeMdCount: 0,
    rulesCount: 0,
    mcpCount: 0,
    hooksCount: 0,
    sessionDuration: '',
    gitStatus: null,
    usageData: null,
    memoryUsage: null,
    config: {
      display: { showPromptCacheEconomics: true },
      colors: {},
    },
    extraLabel: null,
  };
}

function mkTmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'cache-econ-test-'));
}

// (a) gate off (default config) -> line is null.
test('renderPromptCacheEconomicsLine is hidden when the gate is off', () => {
  const ctx = baseContext();
  ctx.config.display.showPromptCacheEconomics = false;
  ctx.transcript.sessionTokens = {
    inputTokens: 10_000,
    outputTokens: 0,
    cacheCreationTokens: 200_000,
    cacheReadTokens: 1_000_000,
  };
  assert.equal(renderPromptCacheEconomicsLine(ctx), null);
});

// (b) gate on + known cache token totals -> session row matches a hand
// calculation for "Claude Sonnet 4.5" pricing (src/cost.ts MODEL_PRICING,
// "sonnet 4" row: input $3/MTok, output $15/MTok; cache read/write are not
// set explicitly on that entry, so cost.ts's own defaults apply:
// cacheRead = input * CACHE_READ_MULTIPLIER (0.1) = $0.30/MTok,
// cacheWrite = input * CACHE_WRITE_MULTIPLIER (1.25) = $3.75/MTok).
//
// read_savings_rate   = (3.00 - 0.30) / 1e6   = 0.0000027
// write_overhead_rate = (3.75 - 3.00) / 1e6   = 0.00000075
// reads = 1,000,000  writes = 200,000  inputs = 10,000
// net = 1,000,000 * 0.0000027 - 200,000 * 0.00000075
//     = 2.7 - 0.15 = 2.55  -> "+$2.5500"
// hit% = floor(1,000,000 * 100 / (10,000 + 1,000,000)) = floor(99.0099..) = 99
// r_fmt = formatCacheTokens(1_000_000) = "1.0M"; w_fmt = formatCacheTokens(200_000) = "200k"
// cost: native stdin.cost.total_cost_usd = 0.04 -> formatUsd(0.04) = "$0.0400"
test('renderPromptCacheEconomicsLine renders the session row from hand-computed values', () => {
  const ctx = baseContext();
  ctx.stdin.cost = { total_cost_usd: 0.04 };
  ctx.transcript.sessionTokens = {
    inputTokens: 10_000,
    outputTokens: 5_000,
    cacheCreationTokens: 200_000,
    cacheReadTokens: 1_000_000,
  };

  const line = stripAnsi(renderPromptCacheEconomicsLine(ctx) ?? '');
  const sessionRow = line.split('\n')[0];
  assert.equal(sessionRow, 'session r:1.0M w:200k hit:99% net +$2.5500  cost $0.0400');
});

// (c) format_tokens port, pinned against the legacy bash implementation via
// `bash -c 'source scripts/statusline/bin/statusline.sh; format_tokens N'`:
// 999 -> "999", 1000 -> "1k", 45321 -> "45k", 1234567 -> "1.2M".
test('formatCacheTokens matches the legacy bash format_tokens output', () => {
  assert.equal(formatCacheTokens(999), '999');
  assert.equal(formatCacheTokens(1000), '1k');
  assert.equal(formatCacheTokens(45321), '45k');
  assert.equal(formatCacheTokens(1_234_567), '1.2M');
});

// (d) the "all" row aggregates every historical transcript under
// ~/.claude/projects/**/*.jsonl. A render never awaits that scan itself: it
// kicks a background refresh (here, `spawnRefresh` is stubbed to run
// runCacheEconomicsRefresh in-process, standing in for the detached child)
// and the totals only show up in the render path once that refresh has
// completed and been picked up from the on-disk cache. A mutated fixture
// file must NOT change the result until a fresh refresh completes.
test('getAllSessionsCacheEconomics sums fixtures once a kicked refresh completes, and caches for 30s', async () => {
  const home = mkTmpDir();
  const proj1 = path.join(home, '.claude', 'projects', 'proj1');
  const proj2 = path.join(home, '.claude', 'projects', 'proj2');
  fs.mkdirSync(proj1, { recursive: true });
  fs.mkdirSync(proj2, { recursive: true });

  const file1 = path.join(proj1, 'session1.jsonl');
  const file2 = path.join(proj2, 'session2.jsonl');
  fs.writeFileSync(file1, usageLine({
    input_tokens: 10, output_tokens: 5, cache_creation_input_tokens: 50, cache_read_input_tokens: 100,
  }));
  fs.writeFileSync(file2, usageLine({
    input_tokens: 20, output_tokens: 10, cache_creation_input_tokens: 150, cache_read_input_tokens: 200,
  }));

  let now = 1_000_000;
  const deps = { homeDir: () => home, now: () => now, spawnRefresh: () => {} };

  // Cold start: nothing cached yet, so the render returns zeros and kicks a
  // refresh; simulate that detached child completing before the next render.
  const cold = await getAllSessionsCacheEconomics(deps);
  assert.deepEqual(cold, { reads: 0, writes: 0, inputs: 0 });
  await runCacheEconomicsRefresh(deps);

  const cachePath = path.join(cacheDirFor(home), 'cache-economics-all.json');
  assert.equal(fs.existsSync(cachePath), true);

  const first = await getAllSessionsCacheEconomics(deps);
  assert.deepEqual(first, { reads: 300, writes: 200, inputs: 30 });

  // Mutate file1 to double its reads, then re-call within the 30s window.
  fs.writeFileSync(file1, usageLine({
    input_tokens: 10, output_tokens: 5, cache_creation_input_tokens: 50, cache_read_input_tokens: 999_999,
  }));
  now += 10_000; // +10s, still within the 30s TTL
  const second = await getAllSessionsCacheEconomics(deps);
  assert.deepEqual(second, first, 'a mutated fixture must not be re-read before the cache goes stale');

  // Advance past the TTL: the cache is now stale, so this render still
  // returns the (stale) cached totals immediately, but kicks another
  // refresh. Once that completes, the mutated file is picked up.
  now += 25_000; // total +35s
  const third = await getAllSessionsCacheEconomics(deps);
  assert.deepEqual(third, first, 'a stale cache is still returned as-is by the render path, not recomputed inline');
  await runCacheEconomicsRefresh(deps);
  const fourth = await getAllSessionsCacheEconomics(deps);
  assert.equal(fourth.reads, 999_999 + 200);
});

// (d.1) a system-clock rollback must not pin a stale cache as "fresh"
// indefinitely: a cache written with a future computedAt (relative to the
// rolled-back clock) is a negative-age cache, which must be treated as
// stale — kicking a refresh — rather than accepted by a naive
// `now - computedAt < TTL` check. The render itself still returns the
// existing (stale) cached totals immediately, per the never-block design.
test('getAllSessionsCacheEconomics treats a future computedAt as stale and kicks a refresh (clock rollback)', async () => {
  const home = mkTmpDir();
  const proj1 = path.join(home, '.claude', 'projects', 'proj1');
  fs.mkdirSync(proj1, { recursive: true });

  const file1 = path.join(proj1, 'session1.jsonl');
  fs.writeFileSync(file1, usageLine({
    input_tokens: 10, output_tokens: 5, cache_creation_input_tokens: 50, cache_read_input_tokens: 100,
  }));

  const cacheDir = cacheDirFor(home);
  fs.mkdirSync(cacheDir, { recursive: true });
  const cachePath = path.join(cacheDir, 'cache-economics-all.json');
  const now = 1_000_000;
  // A cache "computed" 1 hour ahead of `now` - as if the clock rolled back.
  fs.writeFileSync(cachePath, JSON.stringify({
    reads: 999, writes: 999, inputs: 999, computedAt: now + 3_600_000,
  }));

  let spawnCalls = 0;
  const deps = { homeDir: () => home, now: () => now, spawnRefresh: () => { spawnCalls += 1; } };
  const result = await getAllSessionsCacheEconomics(deps);
  assert.deepEqual(result, { reads: 999, writes: 999, inputs: 999 }, 'a future computedAt is stale, but the existing cache is still returned immediately, not recomputed inline');
  assert.equal(spawnCalls, 1, 'a future computedAt must still be treated as stale enough to kick a refresh');
});

// (c) an absent cache on a cold start returns zeros immediately (matching
// the legacy bash's cold-start behaviour) and kicks exactly one background
// refresh — the render never awaits the scan itself.
test('getAllSessionsCacheEconomics returns zeros on a cold start and kicks exactly one refresh', async () => {
  const home = mkTmpDir();
  let spawnCalls = 0;
  const deps = { homeDir: () => home, now: () => 1_000_000, spawnRefresh: () => { spawnCalls += 1; } };
  const result = await getAllSessionsCacheEconomics(deps);
  assert.deepEqual(result, { reads: 0, writes: 0, inputs: 0 });
  assert.equal(spawnCalls, 1);
});

// (b) a fresh (within-TTL) cache is served without ever touching
// spawnRefresh — no refresh lock, no background job.
test('getAllSessionsCacheEconomics serves a fresh cache without kicking a refresh', async () => {
  const home = mkTmpDir();
  const cacheDir = cacheDirFor(home);
  fs.mkdirSync(cacheDir, { recursive: true });
  const now = 1_000_000;
  fs.writeFileSync(path.join(cacheDir, 'cache-economics-all.json'), JSON.stringify({
    reads: 1, writes: 2, inputs: 3, computedAt: now - 5_000,
  }));
  let spawnCalls = 0;
  const deps = { homeDir: () => home, now: () => now, spawnRefresh: () => { spawnCalls += 1; } };
  const result = await getAllSessionsCacheEconomics(deps);
  assert.deepEqual(result, { reads: 1, writes: 2, inputs: 3 });
  assert.equal(spawnCalls, 0);
});

// (d-lock) a young refresh lock (another render already kicked one) means
// this render must not spawn a second, concurrent refresh.
test('a young refresh lock suppresses a concurrent spawn', async () => {
  const home = mkTmpDir();
  const cacheDir = cacheDirFor(home);
  fs.mkdirSync(path.join(cacheDir, 'refresh.lock'), { recursive: true });
  let spawnCalls = 0;
  const deps = { homeDir: () => home, now: () => 1_000_000, spawnRefresh: () => { spawnCalls += 1; } };
  const result = await getAllSessionsCacheEconomics(deps);
  assert.deepEqual(result, { reads: 0, writes: 0, inputs: 0 });
  assert.equal(spawnCalls, 0, 'an EEXIST lock means someone else is already refreshing');
});

// (e-lock) a refresh lock left behind by a crashed child (older than 120s)
// is stale: it is reclaimed and a fresh refresh is kicked.
test('a refresh lock older than 120s is reclaimed and a refresh is kicked', async () => {
  const home = mkTmpDir();
  const lockPath = path.join(cacheDirFor(home), 'refresh.lock');
  fs.mkdirSync(lockPath, { recursive: true });
  const now = 1_000_000;
  const staleMtime = new Date(now - 130_000);
  fs.utimesSync(lockPath, staleMtime, staleMtime);

  let spawnCalls = 0;
  const deps = { homeDir: () => home, now: () => now, spawnRefresh: () => { spawnCalls += 1; } };
  const result = await getAllSessionsCacheEconomics(deps);
  assert.deepEqual(result, { reads: 0, writes: 0, inputs: 0 });
  assert.equal(spawnCalls, 1);
  assert.equal(fs.existsSync(lockPath), true, 'the render path re-creates the lock after reclaiming it, handing ownership to the spawned refresh');
});

// (f) the writer never leaves a partial cache file behind: it writes to a
// pid-suffixed tmp path and only the final `fs.renameSync` makes the new
// content visible at the real cache path. The refresh also releases the
// lock it was handed (by owner token) before spawning it.
test('runCacheEconomicsRefresh writes the cache atomically via rename and releases the lock it was handed', async () => {
  const home = mkTmpDir();
  const proj1 = path.join(home, '.claude', 'projects', 'proj1');
  fs.mkdirSync(proj1, { recursive: true });
  fs.writeFileSync(path.join(proj1, 'session1.jsonl'), usageLine({
    input_tokens: 10, output_tokens: 5, cache_creation_input_tokens: 50, cache_read_input_tokens: 100,
  }));
  const cacheDir = cacheDirFor(home);

  let capturedToken = null;
  await getAllSessionsCacheEconomics({
    homeDir: () => home,
    now: () => 1_000_000,
    spawnRefresh: (_homeDir, token) => { capturedToken = token; },
  });
  assert.equal(typeof capturedToken, 'string');
  assert.ok(capturedToken.length > 0);

  const renameCalls = [];
  await runCacheEconomicsRefresh({
    homeDir: () => home,
    now: () => 1_000_000,
    rename: (oldPath, newPath) => {
      renameCalls.push([oldPath, newPath]);
      fs.renameSync(oldPath, newPath);
    },
  }, capturedToken);

  assert.equal(renameCalls.length, 1, 'the cache must be published via exactly one rename');
  const [tmpArg, finalArg] = renameCalls[0];
  const finalPath = path.join(cacheDir, 'cache-economics-all.json');
  assert.match(path.basename(tmpArg), /^cache-economics-all\.json\.tmp\./);
  assert.equal(finalArg, finalPath);
  assert.equal(fs.existsSync(tmpArg), false, 'the tmp file must not remain after the rename');
  assert.equal(fs.existsSync(finalPath), true);

  const written = JSON.parse(fs.readFileSync(finalPath, 'utf8'));
  assert.equal(written.reads, 100);
  assert.equal(written.writes, 50);
  assert.equal(written.inputs, 10);
  assert.equal(fs.existsSync(path.join(cacheDir, 'refresh.lock')), false, 'the refresh releases the lock it was handed, in its finally');
});

// (codex-2 regression, HIMMEL-2948 CR round 1) reclaiming a stale lock mints
// a NEW owner token; a refresh still holding the OLD (superseded) token must
// not delete the reclaiming refresh's lock out from under it.
test('a stale-lock reclaim mints a new owner token; releasing a superseded token leaves the reclaimed lock intact', async () => {
  const home = mkTmpDir();
  const lockPath = path.join(cacheDirFor(home), 'refresh.lock');
  fs.mkdirSync(lockPath, { recursive: true });
  const now = 1_000_000;
  const staleMtime = new Date(now - 130_000);
  fs.utimesSync(lockPath, staleMtime, staleMtime);

  let newToken = null;
  await getAllSessionsCacheEconomics({
    homeDir: () => home,
    now: () => now,
    spawnRefresh: (_homeDir, token) => { newToken = token; },
  });
  assert.equal(typeof newToken, 'string');

  // The original (now-superseded) refresh finally runs and releases with a
  // stale owner token that no longer matches the reclaimed lock -> no-op.
  await runCacheEconomicsRefresh({ homeDir: () => home, now: () => now }, 'stale-owner-token-from-before-reclaim');
  assert.equal(fs.existsSync(lockPath), true, 'releasing a superseded token must not remove the reclaimed lock');

  // The reclaiming refresh finishes and releases with the CURRENT token.
  await runCacheEconomicsRefresh({ homeDir: () => home, now: () => now }, newToken);
  assert.equal(fs.existsSync(lockPath), false, 'releasing the current token does remove the lock');
});

// (codex-1 regression, HIMMEL-2948 CR round 1) spawn() can fail
// asynchronously (e.g. EAGAIN) after returning; that 'error' event must not
// crash the process, and must release the lock the render path handed to
// the child that never actually started.
test('createSpawnRefresh releases the lock on an asynchronous spawn error', async () => {
  const home = mkTmpDir();
  const lockPath = path.join(cacheDirFor(home), 'refresh.lock');

  let capturedToken = null;
  await getAllSessionsCacheEconomics({
    homeDir: () => home,
    now: () => 1_000_000,
    spawnRefresh: (_homeDir, token) => { capturedToken = token; },
  });
  assert.equal(fs.existsSync(lockPath), true);
  assert.equal(typeof capturedToken, 'string');

  const fakeChild = new EventEmitter();
  fakeChild.unref = () => {};
  const spawnRefresh = createSpawnRefresh(() => fakeChild);
  spawnRefresh(home, capturedToken);
  fakeChild.emit('error', new Error('EAGAIN'));

  assert.equal(fs.existsSync(lockPath), false, 'an asynchronous spawn error must release the lock the render path handed over');
});

// (codex-1, HIMMEL-2948 CR round 3) if the owner-file write fails after the
// lock dir was created, isRefreshLockOwner/releaseRefreshLock can never
// match the returned token -- give up the lock rather than leak it and
// spawn a refresh that could never publish or release.
// Uses a real permission failure (umask forcing the freshly-created lock dir
// to r-x, no write) rather than mocking fs.writeFileSync: node:fs's exports
// are non-configurable under both bun and plain node ("Cannot replace module
// namespace object's binding's value" / "Cannot redefine property"), so
// intercepting a raw fs call here is not portable. The cache dir is
// pre-created (writable) before the umask change so acquireRefreshLock's own
// recursive mkdirSync of it is an unaffected no-op; only the lock dir it
// mkdirSync's fresh (with no explicit mode) is subject to the umask.
test('acquireRefreshLock cleans up and gives up when writing the owner file fails', async () => {
  const home = mkTmpDir();
  const cacheDir = cacheDirFor(home);
  const lockPath = path.join(cacheDir, 'refresh.lock');
  fs.mkdirSync(cacheDir, { recursive: true, mode: 0o700 });

  const originalUmask = process.umask(0o277);
  let spawnCalled = false;
  try {
    await getAllSessionsCacheEconomics({
      homeDir: () => home,
      now: () => 1_000_000,
      spawnRefresh: () => { spawnCalled = true; },
    });
  } finally {
    process.umask(originalUmask);
  }

  assert.equal(spawnCalled, false, 'a refresh must not be spawned when it could never release the lock it was handed');
  assert.equal(fs.existsSync(lockPath), false, 'a lock whose owner file could not be written must be cleaned up, not leaked');
});

// (codex-3, HIMMEL-2948 CR round 1) a failed publish (rename throws) must
// not leave the pid-suffixed tmp file behind.
test('writeCache cleans up the tmp file when the publish step fails', async () => {
  const home = mkTmpDir();
  const cacheDir = cacheDirFor(home);
  await runCacheEconomicsRefresh({
    homeDir: () => home,
    now: () => 1_000_000,
    rename: () => { throw new Error('boom'); },
  });
  const entries = fs.existsSync(cacheDir) ? fs.readdirSync(cacheDir) : [];
  const leftoverTmp = entries.filter((name) => name.includes('.tmp.'));
  assert.deepEqual(leftoverTmp, [], 'a failed rename must not leave a pid-suffixed tmp file behind');
});

// (codex-3, HIMMEL-2948 CR round 2; test itself corrected per codex-2 round
// 3, which caught that seeding the tmp file before the call let the real
// writeFileSync silently overwrite it and succeed, never exercising the
// intended failure path; corrected again per codex-2 round 3, which caught
// that mocking fs.writeFileSync directly is not portable -- node:fs's
// exports are non-configurable under both bun and plain node) writeFileSync
// can throw partway through (e.g. ENOSPC) after already landing some bytes;
// cleanup must still run even though the write never reached the point that
// used to set `tmpWritten`. Driven through the injected `writeFile` seam
// (the same CacheEconomicsDeps pattern already used for `rename`) so the
// partial-write-then-throw is genuine, not a mock of a raw fs call.
test('writeCache cleans up the tmp file when writeFileSync itself fails partway', async () => {
  const home = mkTmpDir();
  const cacheDir = cacheDirFor(home);
  const cachePath = path.join(cacheDir, 'cache-economics-all.json');
  const tmpPath = `${cachePath}.tmp.${process.pid}`;

  await runCacheEconomicsRefresh({
    homeDir: () => home,
    now: () => 1_000_000,
    writeFile: (filePath, data) => {
      // Simulate a partial write landing on disk before the failure, exactly
      // as a real ENOSPC mid-write would leave behind.
      fs.mkdirSync(path.dirname(filePath), { recursive: true });
      fs.writeFileSync(filePath, data.slice(0, 1));
      throw new Error('ENOSPC: no space left on device');
    },
  });

  assert.equal(fs.existsSync(tmpPath), false, 'a tmp file left behind by a failed writeFileSync must be cleaned up');
});

// (codex-2, HIMMEL-2948 CR round 2) a refresh whose lock was reclaimed while
// it was scanning must not publish its (now-superseded) totals.
test('runCacheEconomicsRefresh skips publishing when its lock token was superseded', async () => {
  const home = mkTmpDir();
  const cacheDir = cacheDirFor(home);
  const lockPath = path.join(cacheDir, 'refresh.lock');
  fs.mkdirSync(lockPath, { recursive: true });
  fs.writeFileSync(path.join(lockPath, 'owner'), 'current-owner-token', 'utf8');

  const renameCalls = [];
  await runCacheEconomicsRefresh({
    homeDir: () => home,
    now: () => 1_000_000,
    rename: (oldPath, newPath) => {
      renameCalls.push([oldPath, newPath]);
      fs.renameSync(oldPath, newPath);
    },
  }, 'stale-superseded-token');

  assert.equal(renameCalls.length, 0, 'a superseded refresh must not publish its totals');
  assert.equal(fs.existsSync(path.join(cacheDir, 'cache-economics-all.json')), false);
  // The lock is left alone: releaseRefreshLock also refuses a superseded
  // token, so the reclaiming refresh's lock survives.
  assert.equal(fs.existsSync(lockPath), true);
});

test('getRefreshLockTokenFromArgv extracts the token that follows the refresh flag', () => {
  assert.equal(
    getRefreshLockTokenFromArgv(['node', 'index.js', '--refresh-cache-economics', 'tok-123']),
    'tok-123',
  );
  assert.equal(getRefreshLockTokenFromArgv(['node', 'index.js']), null);
});

// (g) the detached child is dispatched by re-invoking the same entry with
// REFRESH_CACHE_ECONOMICS_FLAG; shouldRunCacheEconomicsRefresh is the pure
// predicate index.ts's bootstrap guard uses to route to
// runCacheEconomicsRefresh() instead of main() — driven in-process here
// rather than through a real fork.
test('shouldRunCacheEconomicsRefresh recognizes the refresh-child flag', () => {
  assert.equal(shouldRunCacheEconomicsRefresh(['node', 'index.js', '--refresh-cache-economics']), true);
  assert.equal(shouldRunCacheEconomicsRefresh(['node', 'index.js']), false);
});

// (e) a model with no pricing entry -> net and cost both render as an
// em dash placeholder, and rendering must not throw.
test('renderPromptCacheEconomicsLine falls back to a placeholder for unknown model pricing', () => {
  const ctx = baseContext();
  ctx.stdin.model = { display_name: 'some-unlisted-model' };
  ctx.transcript.sessionTokens = {
    inputTokens: 10_000,
    outputTokens: 0,
    cacheCreationTokens: 200_000,
    cacheReadTokens: 1_000_000,
  };

  let line;
  assert.doesNotThrow(() => {
    line = stripAnsi(renderPromptCacheEconomicsLine(ctx) ?? '');
  });
  const sessionRow = line.split('\n')[0];
  assert.match(sessionRow, /net —/);
  assert.match(sessionRow, /cost —/);
});
