import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync, spawnSync } from 'node:child_process';
import {
  formatBankAnnotation,
  formatMeasured,
  formatUnmeasurable,
  guardState,
  parseBankStatusOutput,
} from '../bank-status-core.mjs';
import { formatQuotaAnnotation, resolveActiveAccessPath, resolveBankTargets } from '../resolve.mjs';

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const BANK_STATUS = join(TEST_DIR, '..', 'bank-status.ts');
const RESOLVER = join(TEST_DIR, '..', 'resolve.mjs');

// HIMMEL-1737: the public CI job `lanes-and-trust-suites` runs this suite with
// plain `node --test`, no bun on PATH. The CLI tests below spawn bun directly
// (or, for the resolve.mjs test, transitively via runBankStatus), so on a
// bun-less box they'd either ENOENT or fall through to resolve.mjs's own
// unmeasurable-fallback branch and fail their assertions. Probe once and skip
// just those tests, named, so pure-function tests above keep running.
const BUN_SKIP = (() => {
  try {
    execFileSync('bun', ['--version'], { stdio: 'ignore' });
    return undefined;
  } catch {
    return 'bun not installed — CLI tests need it; pure-function tests still run';
  }
})();

function fixtureRegistry(dir) {
  const path = join(dir, 'lanes.json');
  writeFileSync(path, JSON.stringify({ lanes: [
    { id: 'glm', label: 'GLM', class: 'impl', bestFor: 'bulk', effort: 'low', probe: { kind: 'always' }, quota: { bank: 'glm', accessPaths: [{ kind: 'subscription', windows: ['5h'] }], activeAccessPath: 0 } },
    { id: 'claudex', label: 'claudex', class: 'impl', bestFor: 'implementation', effort: 'high', probe: { kind: 'always' }, quota: { bank: 'codex', accessPaths: [{ kind: 'subscription', windows: ['weekly'] }], activeAccessPath: 0 } },
  ] }));
  return path;
}

// A codex-bank cache fixture as the probe would write it (HIMMEL-1678). The
// resetsAt is FIXED (2100-01-01T00:00:00Z) so expected detail strings are
// deterministic; it stays in the future for ~74 years.
const CODEX_RESETS_AT_SEC = 4102444800;
const CODEX_RESETS_ISO = new Date(CODEX_RESETS_AT_SEC * 1000).toISOString();
function codexCacheFile(dir, usedPct = 14) {
  const path = join(dir, 'codex-bank.json');
  writeFileSync(path, JSON.stringify({
    limits: [{ limitId: 'primary', usedPercent: usedPct, windowDurationMins: 10080, resetsAt: CODEX_RESETS_AT_SEC }],
    planType: 'prolite',
    capturedAt: new Date().toISOString(),
  }));
  return path;
}

test('bank detail formatting makes measured and unmeasurable states explicit', () => {
  assert.equal(formatMeasured([{ window: 'weekly', usedPct: 14 }]), 'measured weekly used=14% free=86%');
  assert.equal(formatUnmeasurable('file missing'), 'unmeasurable reason="file missing"');
  const statuses = parseBankStatusOutput([
    'claudex funded measured weekly used=14% free=86%',
    'glm unknown unmeasurable reason="missing weekly window"',
    'codex-wsl unknown unmeasurable reason="I/O timeout"',
  ].join('\n'));
  assert.equal(formatBankAnnotation(statuses.get('claudex')), '[bank: weekly 14% used / 86% free]');
  assert.equal(formatBankAnnotation(statuses.get('glm')), '[bank: unmeasurable — missing weekly window]');
  assert.equal(formatBankAnnotation(statuses.get('codex-wsl')), '[bank: unmeasurable — I/O timeout]');
});

test('bank annotation keeps "free" attached to its window across MULTI-reading details', () => {
  // HIMMEL-1678 CR (glm-2). The free= capture used to be a bare (\S+), which
  // swallowed the ';' separator and orphaned the word "free" past the comma:
  //   "weekly 14% used / 86%, free daily 5% used / 95% free"
  // Only multi-reading details expose it (a single reading has nothing after
  // the last free=), which is why the single-reading case above stayed green.
  const detail = 'measured weekly used=14% free=86%; daily used=5% free=95%';
  const statuses = parseBankStatusOutput(`claude funded ${detail}`);
  assert.equal(
    formatBankAnnotation(statuses.get('claude')),
    '[bank: weekly 14% used / 86% free, daily 5% used / 95% free]',
  );
  // The formatter's own multi-reading output must round-trip through it.
  const measured = formatMeasured([
    { window: 'weekly', usedPct: 14 },
    { window: 'daily', usedPct: 5 },
  ]);
  assert.equal(measured, 'measured weekly used=14% free=86%; daily used=5% free=95%');
  assert.equal(
    formatBankAnnotation(parseBankStatusOutput(`claude funded ${measured}`).get('claude')),
    '[bank: weekly 14% used / 86% free, daily 5% used / 95% free]',
  );
});

test('bank-status CLI reports GLM 5h and Codex weekly headroom', { skip: BUN_SKIP }, () => {
  const dir = mkdtempSync(join(tmpdir(), 'lane-bank-'));
  const registry = fixtureRegistry(dir);
  const cache = codexCacheFile(dir, 14);
  const ledger = join(dir, 'quota-gauge.jsonl');
  writeFileSync(ledger, glmLedgerLine({ usedPct: 2, resetAt: new Date(Date.now() + 3600_000).toISOString() }) + '\n');
  const out = execFileSync('bun', [BANK_STATUS], {
    encoding: 'utf8',
    env: {
      ...process.env,
      LANES_REGISTRY: registry,
      HIMMEL_QUOTA_GAUGE_LEDGER: ledger,
      CODEX_BANK_CACHE: cache,
    },
  });
  assert.match(out, /^glm funded measured 5h used=2% free=98%$/m);
  assert.match(out, new RegExp(`^claudex funded measured weekly used=14% free=86% resets=${CODEX_RESETS_ISO}$`, 'm'));
});

test('bank-status CLI names an unreadable Codex bank instead of silently reporting unknown', { skip: BUN_SKIP }, () => {
  const dir = mkdtempSync(join(tmpdir(), 'lane-bank-missing-'));
  const registry = fixtureRegistry(dir);
  const out = execFileSync('bun', [BANK_STATUS], {
    encoding: 'utf8',
    env: { ...process.env, LANES_REGISTRY: registry, CODEX_BANK_CACHE: join(dir, 'missing.json') },
  });
  assert.match(out, /^claudex unknown unmeasurable reason="codex bank cache missing — run: bun scripts\/lanes\/codex-bank-probe\.ts"$/m);
});

// A canonical quota-gauge ledger row for the GLM lane. `resetAt` is an ISO
// instant: in the future for a LIVE window, in the past for an expired one.
// readGlmBank gates every reading on that reset_at being parseable AND still
// in the future — these tests pin the guard that the first rewrite deleted.
function glmLedgerLine({ usedPct, resetAt }) {
  return JSON.stringify({
    v: 1,
    ts: new Date().toISOString(),
    lane: 'glm',
    source: 'monitor-endpoint',
    used_pct: usedPct,
    window: '5h',
    reset_at: resetAt,
    tier: null,
    glm_peak: false,
    note: null,
  });
}

test('bank-status CLI reports an exhausted GLM lane as spent, not funded', { skip: BUN_SKIP }, () => {
  // Regression (HIMMEL-1678): when the GLM read was deleted, an exhausted GLM
  // A LIVE required-window reading at/over the threshold must be spent.
  const dir = mkdtempSync(join(tmpdir(), 'lane-bank-glm-spent-'));
  const registry = fixtureRegistry(dir);
  const ledger = join(dir, 'quota-gauge.jsonl');
  writeFileSync(ledger, glmLedgerLine({ usedPct: 80, resetAt: new Date(Date.now() + 3600_000).toISOString() }) + '\n');
  const out = execFileSync('bun', [BANK_STATUS], {
    encoding: 'utf8',
    env: {
      ...process.env,
      LANES_REGISTRY: registry,
      HIMMEL_QUOTA_GAUGE_LEDGER: ledger,
      LANE_FUNDED_MAX_PCT: '50',
      CODEX_BANK_CACHE: join(dir, 'missing.json'),
    },
  });
  assert.match(out, /^glm spent measured 5h used=80% free=20%$/m);
  assert.doesNotMatch(out, /^glm funded /m);
});

test('bank-status CLI reports an expired GLM resets_at window as flat-rate, not a bug-shaped unknown', { skip: BUN_SKIP }, () => {
  // The resets_at live-window validation still drops a row whose window reset
  // (its used_pct no longer describes the current cycle — a high-but-expired
  // reading must NOT report spent). But with no live window the lane is NOT
  // "unmeasurable" either (HIMMEL-1678): the z.ai plan is flat-rate, so the
  // honest state is not-applicable — `unknown` read like a defect while the
  // lane is always-available.
  const dir = mkdtempSync(join(tmpdir(), 'lane-bank-glm-expired-'));
  const registry = fixtureRegistry(dir);
  const ledger = join(dir, 'quota-gauge.jsonl');
  writeFileSync(ledger, glmLedgerLine({ usedPct: 80, resetAt: new Date(Date.now() - 3600_000).toISOString() }) + '\n');
  const out = execFileSync('bun', [BANK_STATUS], {
    encoding: 'utf8',
    env: {
      ...process.env,
      LANES_REGISTRY: registry,
      HIMMEL_QUOTA_GAUGE_LEDGER: ledger,
      LANE_FUNDED_MAX_PCT: '50',
      CODEX_BANK_CACHE: join(dir, 'missing.json'),
    },
  });
  assert.match(out, /^glm funded flat-rate$/m);
  assert.doesNotMatch(out, /^glm (spent|unknown) /m);
  assert.doesNotMatch(out, /^glm funded measured /m);
});

test('/lanes output surfaces limit structure, binding windows, and measured bank data', { skip: BUN_SKIP }, () => {
  const dir = mkdtempSync(join(tmpdir(), 'lane-output-'));
  const registry = fixtureRegistry(dir);
  const cache = codexCacheFile(dir, 14);
  const ledger = join(dir, 'quota-gauge.jsonl');
  writeFileSync(ledger, glmLedgerLine({ usedPct: 2, resetAt: new Date(Date.now() + 3600_000).toISOString() }) + '\n');
  const out = execFileSync(process.execPath, [RESOLVER], {
    encoding: 'utf8',
    env: {
      ...process.env,
      LANES_REGISTRY: registry,
      HIMMEL_QUOTA_GAUGE_LEDGER: ledger,
      CODEX_BANK_CACHE: cache,
    },
  });
  assert.match(out, /GLM .*\[access: subscription; windows: 5h; binds: 5h\].*\[bank: 5h 2% used \/ 98% free\]/);
  assert.match(out, new RegExp(`claudex .*\\[access: subscription; windows: weekly; binds: weekly\\].*\\[bank: weekly 14% used / 86% free resets=${CODEX_RESETS_ISO}\\]`));
});

test('bank probe surfaces an overlay-only quota bank instead of "no status returned" (HIMMEL-1690)', () => {
  // bank-status.ts emits one status line per lane in withBank. A lane ABSENT
  // from withBank is exactly what renders as "[bank: unmeasurable — no status
  // returned]" in /lanes (formatBankAnnotation(undefined) in
  // bank-status-core.mjs), so "real status" vs "no status returned" reduces to
  // withBank membership. withBank is built by resolveBankTargets, which must
  // layer the lanes.local.json overlay so an overlay-only quota bank reaches
  // the probe instead of being silently dropped.
  const base = { lanes: [
    { id: 'glm', quota: { bank: 'glm' } },
    { id: 'plain', quota: {} },
  ] };
  const local = { lanes: [
    { id: 'himmel1690-overlay-only', quota: { bank: 'codex' } },
  ] };
  const bankIds = ['claude', 'codex', 'glm'];

  // WITH the overlay: the overlay-only quota bank reaches the probe.
  const merged = resolveBankTargets(base, local, bankIds);
  assert.ok(
    merged.withBank.some((t) => t.lane === 'himmel1690-overlay-only' && t.bank === 'codex'),
    'overlay-only quota bank is probed (real status, not "no status returned")',
  );
  assert.ok(merged.withBank.some((t) => t.lane === 'glm'), 'base bank lane retained');
  assert.ok(merged.without.includes('plain'), 'non-bank lane listed in without');

  // WITHOUT the overlay (the latent default on a box that has no
  // lanes.local.json): the overlay-only lane never reaches the probe — the
  // defect, latent there only because no overlay is present.
  const noOverlay = resolveBankTargets(base, null, bankIds);
  assert.ok(
    !noOverlay.withBank.some((t) => t.lane === 'himmel1690-overlay-only'),
    'overlay-only bank lane is absent without the overlay',
  );
});

// ─── HIMMEL-1768 round 3: evidence-derived guard verdicts ────────────────────
// The verdict must come from per-window EVIDENCE about the RESOLVED active
// access path — never from list lengths, array counts, or positional index
// assumptions. These tests cover every numbered failure class from the two
// prior defect rounds plus both sides of the empty-window distinction.

test('resolveActiveAccessPath: an explicit bad index is a registry error, never a paths[0] fallback', () => {
  const two = { accessPaths: [{ kind: 'subscription', windows: ['weekly'] }, { kind: 'metered-api-key', windows: [] }] };
  assert.deepEqual(
    resolveActiveAccessPath({ ...two, activeAccessPath: 1 }),
    { ok: true, index: 1, path: two.accessPaths[1] },
  );
  // An ABSENT field selects the first path — the documented default shape,
  // not an error fallback.
  assert.deepEqual(resolveActiveAccessPath(two), { ok: true, index: 0, path: two.accessPaths[0] });
  for (const bad of [2, -1, 1.5, '1']) {
    const r = resolveActiveAccessPath({ ...two, activeAccessPath: bad });
    assert.equal(r.ok, false, `activeAccessPath ${JSON.stringify(bad)} must not resolve`);
    assert.match(r.reason, /does not select one of 2 declared access path/);
  }
  // Missing or empty accessPaths leave nothing to resolve.
  assert.equal(resolveActiveAccessPath(undefined).ok, false);
  assert.equal(resolveActiveAccessPath({}).ok, false);
  assert.equal(resolveActiveAccessPath({ accessPaths: [] }).ok, false);
});

test('guardState: funded/spent derive from per-window evidence — every declared window needs a reading', () => {
  const sub = resolveActiveAccessPath({ accessPaths: [{ kind: 'subscription', windows: ['5h', 'weekly'] }], activeAccessPath: 0 });
  const both = { kind: 'measured', readings: [{ window: '5h', usedPct: 12 }, { window: 'weekly', usedPct: 34 }] };
  assert.equal(guardState(both, sub, 99), 'funded');
  assert.equal(guardState(both, sub, 30), 'spent'); // weekly 34 >= 30

  // An unmeasurable bank with declared windows is unknown.
  assert.equal(guardState({ kind: 'unmeasurable', reason: 'x' }, sub, 99), 'unknown');

  // Failure 3: duplicate same-window readings once satisfied the old count
  // equality while 'weekly' went genuinely unmeasured.
  const dup = { kind: 'measured', readings: [{ window: '5h', usedPct: 10 }, { window: '5h', usedPct: 10 }] };
  assert.equal(guardState(dup, sub, 99), 'unknown');

  // Failure 4 / round 1: a reader/registry window-label mismatch leaves a
  // declared window unmeasured — unknown, never a permissive default.
  const one = { kind: 'measured', readings: [{ window: '5h', usedPct: 10 }] };
  assert.equal(guardState(one, sub, 99), 'unknown');
  const fiveOnly = resolveActiveAccessPath({ accessPaths: [{ kind: 'subscription', windows: ['5h'] }], activeAccessPath: 0 });
  assert.equal(
    guardState({ kind: 'measured', readings: [{ window: '5hour', usedPct: 10 }] }, fiveOnly, 99),
    'unknown',
  );
  // Corollary: an UNDECLARED reading never governs — only the active path's
  // declared windows gate (the 99% weekly reading below is not declared).
  assert.equal(
    guardState({ kind: 'measured', readings: [{ window: '5h', usedPct: 10 }, { window: 'weekly', usedPct: 99 }] }, fiveOnly, 99),
    'funded',
  );
});

test('guardState: empty window lists split by path kind — metered funded, everything else unknown', () => {
  // Side A (do NOT collapse away): a RESOLVED metered-api-key path declares
  // no subscription windows to exhaust — funded by construction, even when
  // the now-irrelevant subscription bank read is missing or exhausted.
  const metered = resolveActiveAccessPath({
    accessPaths: [{ kind: 'subscription', windows: ['5h'] }, { kind: 'metered-api-key', provider: 'z.ai', windows: [] }],
    activeAccessPath: 1,
  });
  assert.equal(metered.ok, true);
  assert.equal(guardState({ kind: 'unmeasurable', reason: 'no live glm row' }, metered, 99), 'funded');
  assert.equal(guardState({ kind: 'measured', readings: [{ window: '5h', usedPct: 100 }] }, metered, 99), 'funded');

  // Side B: a SUBSCRIPTION path declaring no windows is a registry defect —
  // the governing limits cannot be established. The round-2 fail-open (a
  // measured, exhausted bank reported funded because [].some() is false)
  // must not come back.
  const emptySub = resolveActiveAccessPath({ accessPaths: [{ kind: 'subscription', windows: [] }], activeAccessPath: 0 });
  assert.equal(guardState({ kind: 'measured', readings: [{ window: '5h', usedPct: 80 }] }, emptySub, 50), 'unknown');
  assert.equal(guardState({ kind: 'unmeasurable', reason: 'x' }, emptySub, 50), 'unknown');

  // Failure 5: a failed selection never falls through to paths[0] — the
  // perfectly healthy 5h reading below belongs to a path the registry did
  // not select.
  const broken = resolveActiveAccessPath({
    accessPaths: [{ kind: 'subscription', windows: ['5h'] }, { kind: 'metered-api-key', windows: [] }],
    activeAccessPath: 7,
  });
  assert.equal(guardState({ kind: 'measured', readings: [{ window: '5h', usedPct: 1 }] }, broken, 99), 'unknown');
});

test('guardState: a flat-rate bank read is funded by construction, not a bug-shaped unknown (HIMMEL-1678)', () => {
  // The z.ai GLM plan is flat-rate (operator ruling — see readGlmDisplay), so
  // a bank read with NO metered window is a positive not-applicable, never
  // missing evidence. `unknown` here read like a defect while the lane is in
  // fact always-available. This is NOT the round-2 fail-open: that one flipped
  // a measured, EXHAUSTED bank to funded; a flat-rate read carries no metered
  // reading to ignore.
  const sub = resolveActiveAccessPath({ accessPaths: [{ kind: 'subscription', windows: ['5h'] }], activeAccessPath: 0 });
  assert.equal(guardState({ kind: 'flat-rate' }, sub, 50), 'funded');
  // An unresolved path is still a registry error, flat-rate bank or not.
  const broken = resolveActiveAccessPath({ accessPaths: [{ kind: 'subscription', windows: ['5h'] }], activeAccessPath: 9 });
  assert.equal(guardState({ kind: 'flat-rate' }, broken, 99), 'unknown');
  // The explicit n/a state renders end to end (formatBankAnnotation's
  // flat-rate branch finally has a producer).
  const statuses = parseBankStatusOutput('glm funded flat-rate');
  assert.equal(formatBankAnnotation(statuses.get('glm')), '[bank: flat-rate / n/a]');
});

test('formatQuotaAnnotation lists every path except the ACTIVE one, not paths.slice(1)', () => {
  const quota = { accessPaths: [{ kind: 'subscription', windows: ['5h'] }, { kind: 'metered-api-key', provider: 'z.ai', windows: [] }] };
  assert.equal(
    formatQuotaAnnotation({ ...quota, activeAccessPath: 1 }),
    '[access: metered API key (z.ai); windows: none; binds: metered spend; alternative: subscription 5h]',
  );
  // Default (index 0) rendering is unchanged.
  assert.equal(
    formatQuotaAnnotation({ ...quota, activeAccessPath: 0 }),
    '[access: subscription; windows: 5h; binds: unknown; alternative: metered API key (z.ai)]',
  );
  // An unresolvable selection renders a diagnostic, not paths[0]'s windows.
  assert.equal(
    formatQuotaAnnotation({ ...quota, activeAccessPath: 5 }),
    '[access: unresolved — activeAccessPath 5 does not select one of 2 declared access path(s)]',
  );
});

function writeRegistry(dir, lanes) {
  const path = join(dir, 'lanes.json');
  writeFileSync(path, JSON.stringify({ lanes }));
  return path;
}

test('bank-status CLI: a subscription path declaring no windows is unknown, not fail-open funded', { skip: BUN_SKIP }, () => {
  const dir = mkdtempSync(join(tmpdir(), 'lane-bank-emptywin-'));
  const registry = writeRegistry(dir, [
    { id: 'nosub', quota: { bank: 'glm', accessPaths: [{ kind: 'subscription', windows: [] }], activeAccessPath: 0 } },
  ]);
  const ledger = join(dir, 'quota-gauge.jsonl');
  writeFileSync(ledger, glmLedgerLine({ usedPct: 80, resetAt: new Date(Date.now() + 3600_000).toISOString() }) + '\n');
  const out = execFileSync('bun', [BANK_STATUS], {
    encoding: 'utf8',
    env: {
      ...process.env,
      LANES_REGISTRY: registry,
      HIMMEL_QUOTA_GAUGE_LEDGER: ledger,
      LANE_FUNDED_MAX_PCT: '50',
      CODEX_BANK_CACHE: join(dir, 'missing.json'),
    },
  });
  assert.match(out, /^nosub unknown measured 5h used=80% free=20%$/m);
  assert.doesNotMatch(out, /^nosub funded /m);
});

test('bank-status CLI: an active metered-api-key path stays funded even when the subscription ledger is dead', { skip: BUN_SKIP }, () => {
  const dir = mkdtempSync(join(tmpdir(), 'lane-bank-metered-'));
  const registry = writeRegistry(dir, [
    { id: 'payg', quota: { bank: 'glm', accessPaths: [{ kind: 'subscription', windows: ['5h'] }, { kind: 'metered-api-key', provider: 'z.ai', windows: [] }], activeAccessPath: 1 } },
  ]);
  const out = execFileSync('bun', [BANK_STATUS], {
    encoding: 'utf8',
    env: {
      ...process.env,
      LANES_REGISTRY: registry,
      HIMMEL_QUOTA_GAUGE_LEDGER: join(dir, 'absent.jsonl'),
      CODEX_BANK_CACHE: join(dir, 'missing.json'),
    },
  });
  // The glm bank read with a dead ledger is flat-rate (HIMMEL-1678); the
  // metered path stays funded by construction either way.
  assert.match(out, /^payg funded flat-rate$/m);
});

test('bank-status CLI: out-of-range activeAccessPath reports unknown with a stderr diagnostic', { skip: BUN_SKIP }, () => {
  const dir = mkdtempSync(join(tmpdir(), 'lane-bank-oor-'));
  const registry = writeRegistry(dir, [
    { id: 'oor', quota: { bank: 'codex', accessPaths: [{ kind: 'subscription', windows: ['weekly'] }, { kind: 'metered-api-key', windows: [] }], activeAccessPath: 3 } },
  ]);
  const run = spawnSync('bun', [BANK_STATUS], {
    encoding: 'utf8',
    env: { ...process.env, LANES_REGISTRY: registry, CODEX_BANK_CACHE: codexCacheFile(dir, 14) },
  });
  assert.equal(run.status, 0);
  assert.match(run.stdout, new RegExp(`^oor unknown measured weekly used=14% free=86% resets=${CODEX_RESETS_ISO}$`, 'm'));
  assert.match(run.stderr, /lane 'oor': activeAccessPath 3 does not select one of 2 declared access path/);
});

test('bank-status CLI: a lane with no accessPaths at all is unknown, whatever the bank read', { skip: BUN_SKIP }, () => {
  const dir = mkdtempSync(join(tmpdir(), 'lane-bank-nopath-'));
  const registry = writeRegistry(dir, [{ id: 'nopath', quota: { bank: 'glm' } }]);
  const ledger = join(dir, 'quota-gauge.jsonl');
  writeFileSync(ledger, glmLedgerLine({ usedPct: 2, resetAt: new Date(Date.now() + 3600_000).toISOString() }) + '\n');
  const run = spawnSync('bun', [BANK_STATUS], {
    encoding: 'utf8',
    env: {
      ...process.env,
      LANES_REGISTRY: registry,
      HIMMEL_QUOTA_GAUGE_LEDGER: ledger,
      CODEX_BANK_CACHE: join(dir, 'missing.json'),
    },
  });
  assert.equal(run.status, 0);
  assert.match(run.stdout, /^nopath unknown measured 5h used=2% free=98%$/m);
  assert.match(run.stderr, /lane 'nopath': no access path declared/);
});

test('the SHIPPED lanes.json stays guardable end-to-end against the reader contract (round-1 lesson)', { skip: BUN_SKIP }, () => {
  // Round 1 shipped glm windows ["5h","weekly"] while readGlmBank emits
  // exactly one reading — glm went permanently unknown and this suite stayed
  // green because every test read a hand-written fixture that ALSO declared
  // ["5h"]. This test reads the SHIPPED registry and feeds each bank a
  // fixture its reader really emits; any declared window no reader emits, or
  // an out-of-range activeAccessPath, flips a lane to unknown and fails here.
  const dir = mkdtempSync(join(tmpdir(), 'lane-bank-shipped-'));
  const ledger = join(dir, 'quota-gauge.jsonl');
  const cache = join(dir, 'statusline-cache.json');
  const codexCache = codexCacheFile(dir, 14);
  writeFileSync(ledger, glmLedgerLine({ usedPct: 2, resetAt: new Date(Date.now() + 3600_000).toISOString() }) + '\n');
  writeFileSync(cache, JSON.stringify({
    five_hour: { utilization: 12, resets_at: Math.floor((Date.now() + 3600_000) / 1000) },
    seven_day: { utilization: 34, resets_at: Math.floor((Date.now() + 7 * 86400_000) / 1000) },
  }));
  const out = execFileSync('bun', [BANK_STATUS], {
    encoding: 'utf8',
    env: {
      ...process.env,
      LANES_REGISTRY: join(TEST_DIR, '..', 'lanes.json'),
      HIMMEL_QUOTA_GAUGE_LEDGER: ledger,
      CODEX_BANK_CACHE: codexCache,
      CLAUDE_USAGE_CACHE: cache,
    },
  });
  // claude tiers declare 5h+weekly and the cache reader emits exactly both.
  for (const lane of ['haiku', 'sonnet', 'opus', 'fable']) {
    assert.match(out, new RegExp(`^${lane} funded measured 5h used=12% free=88%; weekly used=34% free=66%$`, 'm'));
  }
  // The GLM lane declares 5h and the ledger reader emits exactly that.
  assert.match(out, /^glm funded measured 5h used=2% free=98%$/m);
  // codex-bank lanes declare weekly and the probe-cache reader emits exactly that.
  for (const lane of ['claudex', 'codex-exec', 'codex-wsl']) {
    assert.match(out, new RegExp(`^${lane} funded measured weekly used=14% free=86% resets=${CODEX_RESETS_ISO}$`, 'm'));
  }
  // No quota lane in the shipped registry may be left ungoverned or spent by
  // these healthy fixtures.
  assert.doesNotMatch(out, /^(haiku|sonnet|opus|fable|glm|claudex|codex-exec|codex-wsl) (unknown|spent) /m);
});
