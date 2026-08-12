import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import {
  codexScanWindows,
  formatBankAnnotation,
  formatMeasured,
  formatUnmeasurable,
  parseBankStatusOutput,
  parseCodexWeeklyUsedPercent,
} from '../bank-status-core.mjs';
import { resolveBankTargets } from '../resolve.mjs';

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
    { id: 'glm', label: 'GLM', class: 'impl', bestFor: 'bulk', effort: 'low', probe: { kind: 'always' }, quota: { bank: 'glm' } },
    { id: 'claudex', label: 'claudex', class: 'impl', bestFor: 'implementation', effort: 'high', probe: { kind: 'always' }, quota: { bank: 'codex' } },
  ] }));
  return path;
}

test('Codex weekly parser uses the last secondary.used_percent and treats it as used', () => {
  const raw = 'x "secondary":{"used_percent":91} y "secondary": {"used_percent":14.5,"window_minutes":10080}';
  assert.equal(parseCodexWeeklyUsedPercent(raw), 14.5);
  assert.equal(parseCodexWeeklyUsedPercent('"primary":{"used_percent":2}'), null);
  assert.equal(parseCodexWeeklyUsedPercent('"secondary":{"used_percent":101}'), null);
});

test('codex tail windows are newest-first and OVERLAP so no record is split away', () => {
  // HIMMEL-1678 CR (codex-2/glm-3). Contiguous chunks truncated a
  // "secondary":{"used_percent":N} fragment on a boundary in both halves, so it
  // matched in neither and an older reading won. Small numbers stand in for the
  // 8 MiB/64 KiB production values so this needs no multi-megabyte fixture.
  const w = codexScanWindows(1000, 1000, 100, 10);
  // Newest first: the first window ends at EOF.
  assert.deepEqual(w[0], { start: 900, length: 100 });
  // Every consecutive pair overlaps by exactly the overlap, and no window
  // starts before the file does.
  for (let i = 1; i < w.length; i++) {
    const prevStart = w[i - 1].start;
    const thisEnd = w[i].start + w[i].length;
    assert.ok(thisEnd - prevStart === 10, `window ${i} overlap was ${thisEnd - prevStart}`);
    assert.ok(w[i].start >= 0, `window ${i} started before the file`);
  }
  // The scan is bounded by scanLimit, not by file size.
  const capped = codexScanWindows(1000, 250, 100, 10);
  assert.ok(capped.every((x) => x.start >= 750 - 100));
  // Degenerate inputs yield no windows rather than looping.
  assert.deepEqual(codexScanWindows(0, 100, 100, 10), []);
  assert.deepEqual(codexScanWindows(100, 0, 100, 10), []);
});

test('bank detail formatting makes measured, unmeasurable, and flat-rate explicit', () => {
  assert.equal(formatMeasured([{ window: 'weekly', usedPct: 14 }]), 'measured weekly used=14% free=86%');
  assert.equal(formatUnmeasurable('file missing'), 'unmeasurable reason="file missing"');
  const statuses = parseBankStatusOutput([
    'claudex funded measured weekly used=14% free=86%',
    'glm funded flat-rate',
    'codex-wsl unknown unmeasurable reason="I/O timeout"',
  ].join('\n'));
  assert.equal(formatBankAnnotation(statuses.get('claudex')), '[bank: weekly 14% used / 86% free]');
  assert.equal(formatBankAnnotation(statuses.get('glm')), '[bank: flat-rate / n/a]');
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

test('bank-status CLI reports real Codex headroom and GLM as flat-rate', { skip: BUN_SKIP }, () => {
  const dir = mkdtempSync(join(tmpdir(), 'lane-bank-'));
  const registry = fixtureRegistry(dir);
  const log = join(dir, 'logs_2.sqlite');
  writeFileSync(log, 'noise "secondary":{"used_percent":28} later "secondary":{"used_percent":14}');
  const out = execFileSync('bun', [BANK_STATUS], {
    encoding: 'utf8',
    env: { ...process.env, LANES_REGISTRY: registry, CODEX_BANK_LOG: log },
  });
  assert.match(out, /^glm funded flat-rate$/m);
  assert.match(out, /^claudex funded measured weekly used=14% free=86%$/m);
});

test('bank-status CLI names an unreadable Codex bank instead of silently reporting unknown', { skip: BUN_SKIP }, () => {
  const dir = mkdtempSync(join(tmpdir(), 'lane-bank-missing-'));
  const registry = fixtureRegistry(dir);
  const out = execFileSync('bun', [BANK_STATUS], {
    encoding: 'utf8',
    env: { ...process.env, LANES_REGISTRY: registry, CODEX_BANK_LOG: join(dir, 'missing.sqlite') },
  });
  assert.match(out, /^claudex unknown unmeasurable reason="codex log file missing"$/m);
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
  // lane could never surface as spent — guardState mapped flat-rate to funded
  // unconditionally. A LIVE ledger reading at/over the threshold must be spent.
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
      CODEX_BANK_LOG: join(dir, 'missing.sqlite'),
    },
  });
  assert.match(out, /^glm spent measured 5h used=80% free=20%$/m);
  assert.doesNotMatch(out, /^glm funded /m);
});

test('bank-status CLI drops an expired GLM resets_at window (never fabricates spent)', { skip: BUN_SKIP }, () => {
  // The resets_at live-window validation: a row whose window already reset is
  // stale — its used_pct no longer describes the current cycle, so emitting it
  // would fabricate. A high-but-expired reading must NOT report spent.
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
      CODEX_BANK_LOG: join(dir, 'missing.sqlite'),
    },
  });
  assert.match(out, /^glm funded flat-rate$/m);
  assert.doesNotMatch(out, /^glm spent /m);
});

test('/lanes output surfaces measured headroom and flat-rate state', { skip: BUN_SKIP }, () => {
  const dir = mkdtempSync(join(tmpdir(), 'lane-output-'));
  const registry = fixtureRegistry(dir);
  const log = join(dir, 'logs_2.sqlite');
  writeFileSync(log, '"secondary":{"used_percent":14}');
  const out = execFileSync(process.execPath, [RESOLVER], {
    encoding: 'utf8',
    env: { ...process.env, LANES_REGISTRY: registry, CODEX_BANK_LOG: log },
  });
  assert.match(out, /GLM .*\[bank: flat-rate \/ n\/a\]/);
  assert.match(out, /claudex .*\[bank: weekly 14% used \/ 86% free\]/);
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
