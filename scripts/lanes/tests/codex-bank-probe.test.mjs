// scripts/lanes/tests/codex-bank-probe.test.mjs — HIMMEL-1678
// Fixture-driven tests for the codex bank probe + TTL'd cache read. No test
// spawns the real `codex` binary: the probe e2e tests drive it against
// fixtures/codex-appserver-stub.mjs via CODEX_BANK_PROBE_CMD, and everything
// else exercises the pure helpers in codex-bank-probe-core.mjs /
// bank-status-core.mjs directly.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync, spawnSync } from 'node:child_process';
import { encodeJsonRpcLine, normalizeRateLimits, takeJsonRpcMessage } from '../codex-bank-probe-core.mjs';
import { CODEX_BANK_PROBE_REMEDY, formatMeasured, readCodexBankCache } from '../bank-status-core.mjs';

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const PROBE = join(TEST_DIR, '..', 'codex-bank-probe.ts');
const BANK_STATUS = join(TEST_DIR, '..', 'bank-status.ts');
const STUB = join(TEST_DIR, 'fixtures', 'codex-appserver-stub.mjs');

// Same guard as bank-status.test.mjs (HIMMEL-1737): public CI runs plain
// `node --test` with no bun on PATH. The CLI/probe tests below spawn bun, so
// probe once and skip just those, named; the pure-function tests keep running.
const BUN_SKIP = (() => {
  try {
    execFileSync('bun', ['--version'], { stdio: 'ignore' });
    return undefined;
  } catch {
    return 'bun not installed — CLI/probe tests need it; pure-function tests still run';
  }
})();

// The two-limit cache the probe would have written: a weekly primary and a
// 5h secondary with DIFFERENT reset instants (HIMMEL-1725).
function twoLimitPayload(nowMs) {
  return {
    limits: [
      { limitId: 'primary', usedPercent: 20, windowDurationMins: 10080, resetsAt: Math.floor(nowMs / 1000) + 86400 },
      { limitId: 'secondary', usedPercent: 5, windowDurationMins: 300, resetsAt: Math.floor(nowMs / 1000) + 3600 },
    ],
    planType: 'prolite',
    capturedAt: new Date(nowMs - 60_000).toISOString(),
  };
}

function fixtureRegistry(dir) {
  const path = join(dir, 'lanes.json');
  writeFileSync(path, JSON.stringify({ lanes: [
    { id: 'claudex', label: 'claudex', class: 'impl', bestFor: 'implementation chunks', effort: 'high', probe: { kind: 'always' }, quota: { bank: 'codex', accessPaths: [{ kind: 'subscription', windows: ['weekly'] }], activeAccessPath: 0 } },
  ] }));
  return path;
}

// Poll until the pid is gone (taskkill/kill are asynchronous-ish); the stub
// NEVER exits on its own, so "gone" can only mean the probe's kill worked.
async function waitForExit(pidFile, budgetMs = 10_000) {
  const pid = Number(readFileSync(pidFile, 'utf8'));
  const deadline = Date.now() + budgetMs;
  for (;;) {
    try {
      process.kill(pid, 0);
    } catch {
      return true; // ESRCH (or EPERM-only on some platforms for dead pids) — gone
    }
    if (Date.now() > deadline) return false;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
}

test('takeJsonRpcMessage reads NDJSON messages and skips banner lines', () => {
  const buf = Buffer.from('codex app-server v1.2\n{"jsonrpc":"2.0","id":1,"result":{"ok":true}}\r\nnot-json\n');
  const first = takeJsonRpcMessage(buf);
  assert.equal(first?.text, '{"jsonrpc":"2.0","id":1,"result":{"ok":true}}');
  // The trailing banner line is skipped and nothing remains.
  assert.equal(takeJsonRpcMessage(first.rest), null);
  // An unterminated line is not a message yet.
  assert.equal(takeJsonRpcMessage(Buffer.from('{"jsonrpc"')), null);
});

test('takeJsonRpcMessage reads Content-Length frames by BYTE length', () => {
  const body = JSON.stringify({ jsonrpc: '2.0', id: 2, result: { note: 'ü' } });
  const frame = `Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`;
  const taken = takeJsonRpcMessage(Buffer.from(`\r\n${frame}`));
  assert.equal(taken?.text, body); // byte-exact: 'ü' is 2 bytes in utf-8
  // A frame whose body has not fully arrived stays pending.
  assert.equal(takeJsonRpcMessage(Buffer.from('Content-Length: 100\r\n\r\n{}')), null);
  // A header block without a terminator stays pending (bounded by the probe timeout).
  assert.equal(takeJsonRpcMessage(Buffer.from('Content-Length: 5\r\n')), null);
});

test('encodeJsonRpcLine emits one NDJSON object', () => {
  assert.equal(
    encodeJsonRpcLine({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }),
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n',
  );
});

// The LIVE `account/rateLimits/read` result, captured 2026-08-17 (balance and
// the null-valued fields kept verbatim — the normalizer must skip them).
const LIVE_RESULT = {
  rateLimits: {
    limitId: 'codex',
    limitName: null,
    primary: { usedPercent: 23, windowDurationMins: 10080, resetsAt: 1787198028 },
    secondary: null,
    credits: { hasCredits: false, unlimited: false, balance: '0' },
    individualLimit: null,
    spendControlReached: false,
    planType: 'prolite',
    rateLimitReachedType: null,
  },
  rateLimitsByLimitId: {
    codex: {
      limitId: 'codex',
      primary: { usedPercent: 23, windowDurationMins: 10080, resetsAt: 1787198028 },
      secondary: null,
      planType: 'prolite',
    },
    codex_bengalfox: {
      limitId: 'codex_bengalfox',
      limitName: 'GPT-5.3-Codex-Spark',
      primary: { usedPercent: 0, windowDurationMins: 10080, resetsAt: 1787525932 },
      secondary: null,
      planType: 'prolite',
    },
  },
  rateLimitResetCredits: { availableCount: 0, credits: [] },
};

test('normalizeRateLimits reads planType out of the BUCKET (the plan=unknown defect)', () => {
  // planType sits inside each rateLimits bucket, never at the top level;
  // reading result.planType is what produced `plan=unknown` against live codex.
  assert.equal(normalizeRateLimits(LIVE_RESULT).planType, 'prolite');
  assert.equal(normalizeRateLimits({ ...LIVE_RESULT, planType: 'ignored-top-level' }).planType, 'prolite');
});

test('normalizeRateLimits keeps EVERY limitId with its own reset (HIMMEL-1725)', () => {
  const { limits } = normalizeRateLimits(LIVE_RESULT);
  assert.deepEqual(limits, [
    { limitId: 'codex/primary', usedPercent: 23, windowDurationMins: 10080, resetsAt: 1787198028 },
    { limitId: 'codex_bengalfox/primary', usedPercent: 0, windowDurationMins: 10080, resetsAt: 1787525932 },
  ]);
  // The two weekly resets are ~3.8 days apart — never collapsible into one.
  assert.notEqual(limits[0].resetsAt, limits[1].resetsAt);
});

test('normalizeRateLimits falls back to the single bucket, clamps, and drops junk', () => {
  const single = normalizeRateLimits({
    rateLimits: { limitId: 'codex', secondary: { usedPercent: 101, windowDurationMins: 300, resetsAt: 123 }, planType: 'prolite' },
  });
  assert.deepEqual(single.limits, [{ limitId: 'codex/secondary', usedPercent: 100, windowDurationMins: 300, resetsAt: 123 }]);
  // A bare bucket (no container) keeps the slot name as the id.
  assert.deepEqual(normalizeRateLimits({ primary: { usedPercent: 5, windowDurationMins: 10080 } }).limits,
    [{ limitId: 'primary', usedPercent: 5, windowDurationMins: 10080, resetsAt: null }]);
  // A zero-length window, a non-numeric used%, and a non-object are all dropped.
  assert.deepEqual(normalizeRateLimits({ primary: { usedPercent: 1, windowDurationMins: 0 } }).limits, []);
  assert.deepEqual(normalizeRateLimits({ primary: { usedPercent: 'x', windowDurationMins: 300 } }).limits, []);
  assert.deepEqual(normalizeRateLimits(null).limits, []);
});

test('readCodexBankCache: a fresh cache resolves to measured with per-limit windows', () => {
  const now = Date.now();
  const result = readCodexBankCache(JSON.stringify(twoLimitPayload(now)), now, 21600);
  assert.equal(result.kind, 'measured');
  assert.deepEqual(result.readings, [
    { window: 'weekly', usedPct: 20, resetsAt: (Math.floor(now / 1000) + 86400) * 1000 },
    { window: '5h', usedPct: 5, resetsAt: (Math.floor(now / 1000) + 3600) * 1000 },
  ]);
});

test('readCodexBankCache: a cache older than the TTL is unmeasurable and names the remedy', () => {
  const now = Date.now();
  const stale = { ...twoLimitPayload(now), capturedAt: new Date(now - 7 * 3600_000).toISOString() };
  const result = readCodexBankCache(JSON.stringify(stale), now, 21600);
  assert.equal(result.kind, 'unmeasurable');
  assert.match(result.reason, /stale \(age 420min > TTL 360min\)/);
  assert.ok(result.reason.includes(CODEX_BANK_PROBE_REMEDY), 'the reason must name how to fix it');
});

test('readCodexBankCache: unparseable/malformed caches are unmeasurable, never fabricated', () => {
  const now = Date.now();
  for (const text of ['not json', '{}', '[]', JSON.stringify({ limits: 'x', capturedAt: new Date().toISOString() })]) {
    const result = readCodexBankCache(text, now, 21600);
    assert.equal(result.kind, 'unmeasurable', `expected unmeasurable for ${text}`);
    assert.ok(result.reason.includes(CODEX_BANK_PROBE_REMEDY));
  }
  const noStamp = JSON.stringify({ limits: twoLimitPayload(now).limits });
  assert.equal(readCodexBankCache(noStamp, now, 21600).kind, 'unmeasurable');
});

test('readCodexBankCache drops a limit whose window already reset (HIMMEL-1689 hole 1)', () => {
  const now = Date.now();
  const payload = {
    limits: [
      { limitId: 'primary', usedPercent: 20, windowDurationMins: 10080, resetsAt: Math.floor(now / 1000) - 10 },
      { limitId: 'secondary', usedPercent: 5, windowDurationMins: 300, resetsAt: Math.floor(now / 1000) + 3600 },
    ],
    capturedAt: new Date(now - 60_000).toISOString(),
  };
  const mixed = readCodexBankCache(JSON.stringify(payload), now, 21600);
  assert.equal(mixed.kind, 'measured');
  assert.deepEqual(mixed.readings.map((r) => r.window), ['5h']); // expired weekly dropped
  const allExpired = readCodexBankCache(JSON.stringify({ ...payload, limits: [payload.limits[0]] }), now, 21600);
  assert.equal(allExpired.kind, 'unmeasurable'); // nothing live -> fail closed
});

test('readCodexBankCache: the WORST limit on a shared window governs (no fail-open)', () => {
  const now = Date.now();
  const sec = Math.floor(now / 1000);
  // Both limitIds are weekly; the fresh 0% sibling arrives FIRST. First-wins
  // would report 0% used and read as funded while the real limit is exhausted.
  const payload = {
    limits: [
      { limitId: 'codex_bengalfox/primary', usedPercent: 0, windowDurationMins: 10080, resetsAt: sec + 5 * 86400 },
      { limitId: 'codex/primary', usedPercent: 95, windowDurationMins: 10080, resetsAt: sec + 86400 },
    ],
    capturedAt: new Date(now - 60_000).toISOString(),
  };
  const result = readCodexBankCache(JSON.stringify(payload), now, 21600);
  assert.equal(result.kind, 'measured');
  assert.deepEqual(result.readings, [
    // The governing limit's OWN reset instant rides along, not the sibling's.
    { window: 'weekly', usedPct: 95, resetsAt: (sec + 86400) * 1000 },
  ]);
});

test('per-limit resetsAt stay DISTINCT through the detail line (HIMMEL-1725)', () => {
  const now = Date.now();
  const result = readCodexBankCache(JSON.stringify(twoLimitPayload(now)), now, 21600);
  const detail = formatMeasured(result.readings);
  // The capture must exclude ';' — formatMeasured joins readings with '; ', so
  // a bare (\S+) swallows the separator onto the first reset (same class of
  // bug already fixed in formatBankAnnotation).
  const resets = [...detail.matchAll(/resets=([^\s;]+)/g)].map((m) => m[1]);
  assert.equal(resets.length, 2, detail);
  assert.notEqual(resets[0], resets[1], 'reset times must never collapse into one global value');
  assert.equal(resets[0], new Date((Math.floor(now / 1000) + 86400) * 1000).toISOString());
  assert.equal(resets[1], new Date((Math.floor(now / 1000) + 3600) * 1000).toISOString());
});

test('bank-status CLI: fresh cache measured, missing/stale cache unmeasurable — never funded', { skip: BUN_SKIP }, () => {
  const dir = mkdtempSync(join(tmpdir(), 'codex-bank-cache-cli-'));
  const registry = fixtureRegistry(dir);
  const cache = join(dir, 'codex-bank.json');
  writeFileSync(cache, JSON.stringify({
    limits: [{ limitId: 'primary', usedPercent: 20, windowDurationMins: 10080, resetsAt: Math.floor(Date.now() / 1000) + 86400 }],
    planType: 'prolite',
    capturedAt: new Date().toISOString(),
  }));
  const fresh = execFileSync('bun', [BANK_STATUS], {
    encoding: 'utf8',
    env: { ...process.env, LANES_REGISTRY: registry, CODEX_BANK_CACHE: cache },
  });
  assert.match(fresh, /^claudex funded measured weekly used=20% free=80% resets=\S+Z$/m);

  const missing = execFileSync('bun', [BANK_STATUS], {
    encoding: 'utf8',
    env: { ...process.env, LANES_REGISTRY: registry, CODEX_BANK_CACHE: join(dir, 'absent.json') },
  });
  assert.match(missing, /^claudex unknown unmeasurable reason="codex bank cache missing — run: bun scripts\/lanes\/codex-bank-probe\.ts"$/m);
  assert.doesNotMatch(missing, /^claudex funded /m);

  // The TTL env var is honored end-to-end (its parsing lives in bank-status.ts).
  writeFileSync(cache, JSON.stringify({
    limits: [{ limitId: 'primary', usedPercent: 20, windowDurationMins: 10080, resetsAt: Math.floor(Date.now() / 1000) + 86400 }],
    capturedAt: new Date(Date.now() - 3600_000).toISOString(),
  }));
  const stale = execFileSync('bun', [BANK_STATUS], {
    encoding: 'utf8',
    env: { ...process.env, LANES_REGISTRY: registry, CODEX_BANK_CACHE: cache, CODEX_BANK_CACHE_TTL_SECONDS: '1' },
  });
  assert.match(stale, /^claudex unknown unmeasurable reason="codex bank cache stale \(age 60min > TTL 0min\) — run: bun scripts\/lanes\/codex-bank-probe\.ts"$/m);
});

test('probe: bounded handshake against a STUB app-server writes the cache AND kills the stub', { skip: BUN_SKIP }, async () => {
  const dir = mkdtempSync(join(tmpdir(), 'codex-bank-probe-ok-'));
  const pidFile = join(dir, 'stub.pid');
  const cache = join(dir, 'codex-bank.json');
  const run = spawnSync('bun', [PROBE], {
    encoding: 'utf8',
    timeout: 60_000,
    env: {
      ...process.env,
      CODEX_BANK_CACHE: cache,
      CODEX_BANK_PROBE_CMD: `node ${STUB}`,
      STUB_PID_FILE: pidFile,
    },
  });
  assert.equal(run.status, 0, `probe failed: ${run.stderr}`);
  assert.match(run.stdout, /plan=prolite/);
  // HIMMEL-1956 / PR #1751: reaping fires from the finally, the signal
  // handlers AND the process-'exit' backstop, so it used to run twice on
  // every clean run -- the second pass landing on an already-empty group.
  // A successful probe must say nothing about failing to reap anything.
  assert.doesNotMatch(run.stderr, /could not reap the app-server tree/,
    'a clean probe run must not warn about a reap that did not fail');
  const payload = JSON.parse(readFileSync(cache, 'utf8'));
  assert.equal(payload.planType, 'prolite');
  assert.deepEqual(payload.limits.map(({ limitId, usedPercent, windowDurationMins }) => ({ limitId, usedPercent, windowDurationMins })), [
    { limitId: 'codex/primary', usedPercent: 20, windowDurationMins: 10080 },
    { limitId: 'codex_bengalfox/primary', usedPercent: 0, windowDurationMins: 10080 },
  ]);
  // Both limits are persisted with their OWN reset instant (HIMMEL-1725).
  assert.notEqual(payload.limits[0].resetsAt, payload.limits[1].resetsAt);
  assert.ok(Number.isFinite(Date.parse(payload.capturedAt)), 'capturedAt must be a parseable instant');
  // GUARANTEED KILL, success path: the stub never exits on its own, so it can
  // only be gone because the probe reaped it.
  assert.ok(await waitForExit(pidFile), 'stub survived a SUCCESSFUL probe — kill guarantee violated');
});

test('probe: a silent app-server times out, writes no cache, and is still killed', { skip: BUN_SKIP }, async () => {
  const dir = mkdtempSync(join(tmpdir(), 'codex-bank-probe-to-'));
  const pidFile = join(dir, 'stub.pid');
  const cache = join(dir, 'codex-bank.json');
  const run = spawnSync('bun', [PROBE], {
    encoding: 'utf8',
    timeout: 60_000,
    env: {
      ...process.env,
      CODEX_BANK_CACHE: cache,
      CODEX_BANK_PROBE_CMD: `node ${STUB}`,
      STUB_PID_FILE: pidFile,
      STUB_SILENT: '1',
      CODEX_BANK_PROBE_TIMEOUT_MS: '800',
    },
  });
  assert.equal(run.status, 1);
  assert.match(run.stderr, /timed out after 800ms/);
  assert.ok(!existsSync(cache), 'a timed-out probe must not write a cache');
  // GUARANTEED KILL, timeout path.
  assert.ok(await waitForExit(pidFile), 'stub survived a TIMED-OUT probe — kill guarantee violated');
});
