// scripts/lanes/tests/bench-bank-snapshot.test.mjs — HIMMEL-1723 P2.6
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  CLAUDE_SEVEN_DAY_REFUSE_PCT,
  CODEX_WEEKLY_REFUSE_PCT,
  evaluateDelta,
  evaluatePreflight,
  extractLaneWindowPct,
} from '../bench/bank-snapshot-core.mjs';

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const CORE = join(TEST_DIR, '..', 'bench', 'bank-snapshot-core.mjs');

function bankStatusLine(lane, guardState, detail) {
  return `${lane} ${guardState} ${detail}`;
}

test('extractLaneWindowPct reads a single-window (codex weekly) reading', () => {
  const output = bankStatusLine('claudex', 'funded', 'measured weekly used=14% free=86%');
  assert.equal(extractLaneWindowPct(output, 'claudex', 'weekly'), 14);
});

test('extractLaneWindowPct reads the right window out of a multi-window (claude) reading', () => {
  const output = bankStatusLine('sonnet', 'funded', 'measured five_hour used=20% free=80%; seven_day used=72% free=28%');
  assert.equal(extractLaneWindowPct(output, 'sonnet', 'seven_day'), 72);
  assert.equal(extractLaneWindowPct(output, 'sonnet', 'five_hour'), 20);
});

test('extractLaneWindowPct returns null for an absent lane, flat-rate, or unmeasurable status', () => {
  const output = [
    bankStatusLine('glm', 'funded', 'flat-rate'),
    bankStatusLine('codex-wsl', 'unknown', 'unmeasurable reason="I/O timeout"'),
  ].join('\n');
  assert.equal(extractLaneWindowPct(output, 'glm', 'weekly'), null);
  assert.equal(extractLaneWindowPct(output, 'codex-wsl', 'weekly'), null);
  assert.equal(extractLaneWindowPct(output, 'absent-lane', 'weekly'), null);
});

test('evaluatePreflight PROCEEDS under both thresholds', () => {
  const result = evaluatePreflight({ codexWeeklyPct: 50, claudeSevenDayPct: 30 });
  assert.equal(result.proceed, true);
  assert.deepEqual(result.reasons, []);
});

test('evaluatePreflight REFUSES when a bank reading is null or unreadable', () => {
  const result = evaluatePreflight({ codexWeeklyPct: null, claudeSevenDayPct: Number.NaN });
  assert.equal(result.proceed, false);
  assert.deepEqual(result.reasons, ['codex weekly UNKNOWN', 'claude seven_day UNKNOWN']);
});

test('evaluatePreflight REFUSES at the codex weekly threshold (spec §7.2: >= 80%)', () => {
  const result = evaluatePreflight({ codexWeeklyPct: CODEX_WEEKLY_REFUSE_PCT, claudeSevenDayPct: 10 });
  assert.equal(result.proceed, false);
  assert.match(result.reasons[0], /codex weekly/);
});

test('evaluatePreflight REFUSES at the claude seven_day threshold (spec §7.2: >= 70%)', () => {
  const result = evaluatePreflight({ codexWeeklyPct: 10, claudeSevenDayPct: CLAUDE_SEVEN_DAY_REFUSE_PCT });
  assert.equal(result.proceed, false);
  assert.match(result.reasons[0], /claude seven_day/);
});

test('evaluatePreflight reports BOTH reasons when both banks breach', () => {
  const result = evaluatePreflight({ codexWeeklyPct: 95, claudeSevenDayPct: 95 });
  assert.equal(result.proceed, false);
  assert.equal(result.reasons.length, 2);
});

test('evaluateDelta reports UNMEASURED (stale source) when post <= pre (spec §6.2 / HIMMEL-1689)', () => {
  assert.deepEqual(evaluateDelta(50, 50), { status: 'UNMEASURED', reason: 'stale source (post <= pre)' });
  assert.deepEqual(evaluateDelta(50, 40), { status: 'UNMEASURED', reason: 'stale source (post <= pre)' });
});

test('evaluateDelta reports MEASURED with the delta when post > pre', () => {
  assert.deepEqual(evaluateDelta(50, 55), { status: 'MEASURED', deltaPct: 5 });
});

test('evaluateDelta reports UNMEASURED when a reading is missing (never fabricates zero)', () => {
  assert.equal(evaluateDelta(null, 50).status, 'UNMEASURED');
  assert.equal(evaluateDelta(50, null).status, 'UNMEASURED');
});

test('CLI: preflight proceeds (exit 0) when both banks are under threshold', () => {
  const output = [
    bankStatusLine('claudex', 'funded', 'measured weekly used=10% free=90%'),
    // readClaudeBank labels the seven_day cache field's reading "weekly"
    // (same string codex's own weekly reading uses, in a different lane's
    // line) — see CLAUDE_SEVEN_DAY_WINDOW_LABEL in bank-snapshot-core.mjs.
    bankStatusLine('sonnet', 'funded', 'measured 5h used=5% free=95%; weekly used=20% free=80%'),
  ].join('\n');
  const out = execFileSync('node', [CORE, 'preflight'], { input: output, encoding: 'utf8' });
  assert.match(out, /proceed/);
});

test('CLI: preflight REFUSES (nonzero exit) when codex weekly breaches', () => {
  const output = [
    bankStatusLine('claudex', 'funded', 'measured weekly used=85% free=15%'),
    // readClaudeBank labels the seven_day cache field's reading "weekly"
    // (same string codex's own weekly reading uses, in a different lane's
    // line) — see CLAUDE_SEVEN_DAY_WINDOW_LABEL in bank-snapshot-core.mjs.
    bankStatusLine('sonnet', 'funded', 'measured 5h used=5% free=95%; weekly used=20% free=80%'),
  ].join('\n');
  assert.throws(() => execFileSync('node', [CORE, 'preflight'], { input: output, encoding: 'utf8' }));
});

test('CLI: snapshot writes a {codex,claude} JSON reading and delta applies the stale rule', () => {
  const dir = mkdtempSync(join(tmpdir(), 'bench-bank-snapshot-cli-'));
  const preOut = bankStatusLine('claudex', 'funded', 'measured weekly used=10% free=90%');
  const preFile = join(dir, 'pre.json');
  execFileSync('node', [CORE, 'snapshot', '--out', preFile], { input: preOut, encoding: 'utf8' });
  const pre = JSON.parse(readFileSync(preFile, 'utf8'));
  assert.equal(pre.codex.usedPct, 10);

  const postOut = bankStatusLine('claudex', 'funded', 'measured weekly used=8% free=92%'); // stale (dropped)
  const postFile = join(dir, 'post.json');
  execFileSync('node', [CORE, 'snapshot', '--out', postFile], { input: postOut, encoding: 'utf8' });

  const deltaOut = execFileSync('node', [CORE, 'delta', '--pre', preFile, '--post', postFile], { encoding: 'utf8' });
  assert.match(deltaOut, /codex: UNMEASURED \(stale source\)/);
});
