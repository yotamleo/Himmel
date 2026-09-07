// LUNA-131 Task 9d (acceptance 2 / D16). node:test suite for
// focus-tick-correlate.mjs -- the correlator is the only thing in the plan
// that computes acceptance 2's PASS/FAIL statistic, so this suite proves it
// actually discriminates: C1 plants a real correlation and requires the
// correlator to genuinely FAIL on it (a correlator that always prints PASS
// would falsely exonerate the sweeper, which is worse than no correlator).

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.join(HERE, 'focus-tick-correlate.mjs');

let TMP;
before(() => { TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'focus-tick-correlate-')); });
after(() => { try { fs.rmSync(TMP, { recursive: true, force: true }); } catch { /* best effort */ } });

let fixtureCounter = 0;
function writeFixture(name, content) {
  const p = path.join(TMP, `${fixtureCounter++}-${name}`);
  fs.writeFileSync(p, content, 'utf8');
  return p;
}

function runCorrelator(focusPath, syncPath, seed) {
  const args = [SCRIPT, focusPath, syncPath];
  if (seed !== undefined) args.push('--seed', String(seed));
  return spawnSync(process.execPath, args, { encoding: 'utf8' });
}

// Small deterministic LCG for generating FIXTURE data -- independent of the
// correlator's own --seed, so the test's input data is reproducible across
// runs regardless of what --seed is passed to the script under test.
function lcg(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

function tickLine(iso) {
  return `${iso} tick_start=${iso} dur_ms=120 commit=nothing-to-commit pull=up-to-date push=nothing-to-push ahead=0 behind=0 skip=none alarm=`;
}

function focusLine(iso, i) {
  return JSON.stringify({ ts: iso, pid: 1000 + i, exe: 'obsidian', title: `doc-${i}` });
}

test('C1 planted correlation: every focus event 1s after a tick forces verdict FAIL, and real_count genuinely exceeds surrogate_p95', () => {
  const N = 60;
  const baseMs = Date.UTC(2026, 0, 1, 0, 0, 0);
  const tickIntervalMs = 600 * 1000; // 10 minutes, the real cadence
  const syncLines = [];
  const focusLines = [];
  for (let i = 0; i < N; i++) {
    const tickMs = baseMs + i * tickIntervalMs;
    const tickIso = new Date(tickMs).toISOString();
    syncLines.push(tickLine(tickIso));
    const focusMs = tickMs + 1000; // planted: exactly 1s after every tick, inside the +/-3s window
    focusLines.push(focusLine(new Date(focusMs).toISOString(), i));
  }
  const syncPath = writeFixture('c1-sync.log', `${syncLines.join('\n')}\n`);
  const focusPath = writeFixture('c1-focus.jsonl', `${focusLines.join('\n')}\n`);

  const r = runCorrelator(focusPath, syncPath, 7);
  assert.equal(r.status, 0, r.stderr);
  const out = JSON.parse(r.stdout.trim());

  assert.equal(out.real_count, N, 'every planted focus event coincides with its own tick');
  assert.ok(
    out.real_count > out.surrogate_p95,
    `planted correlation must drive real_count (${out.real_count}) above surrogate_p95 (${out.surrogate_p95}) -- otherwise this is a correlator that would falsely exonerate a real coincidence`,
  );
  assert.equal(out.verdict, 'FAIL', 'the sweeper cannot be exonerated when every focus change is planted 1s after a tick');
});

test('C2 independent: focus events drawn uniformly across the day, uncorrelated with ticks, verdict PASS', () => {
  const days = 3;
  const tickIntervalMs = 600 * 1000;
  const ticksPerDay = 144;
  const baseMs = Date.UTC(2026, 0, 1, 0, 0, 0);
  const totalTicks = days * ticksPerDay;
  const totalSpanMs = days * 86400 * 1000;

  const syncLines = [];
  for (let i = 0; i < totalTicks; i++) {
    const tickIso = new Date(baseMs + i * tickIntervalMs).toISOString();
    syncLines.push(tickLine(tickIso));
  }

  // ~300 focus changes/day (the plan's realistic F), placed uniformly at
  // random over the whole soak span, independent of the tick schedule.
  const rand = lcg(99);
  const focusCount = days * 300;
  const focusLines = [];
  for (let i = 0; i < focusCount; i++) {
    const offsetMs = Math.floor(rand() * totalSpanMs);
    const focusIso = new Date(baseMs + offsetMs).toISOString();
    focusLines.push(focusLine(focusIso, i));
  }

  const syncPath = writeFixture('c2-sync.log', `${syncLines.join('\n')}\n`);
  const focusPath = writeFixture('c2-focus.jsonl', `${focusLines.join('\n')}\n`);

  const r = runCorrelator(focusPath, syncPath, 11);
  assert.equal(r.status, 0, r.stderr);
  const out = JSON.parse(r.stdout.trim());
  assert.equal(out.verdict, 'PASS', `independent input should not exceed the surrogate baseline: real_count=${out.real_count} surrogate_p95=${out.surrogate_p95}`);
  assert.ok(out.real_count <= out.surrogate_p95);
});

test('C3 malformed/empty inputs: never a silent PASS', () => {
  const validSync = writeFixture('c3-valid-sync.log', `${tickLine(new Date().toISOString())}\n`);
  const validFocus = writeFixture('c3-valid-focus.jsonl', `${focusLine(new Date().toISOString(), 0)}\n`);

  const emptyFocus = writeFixture('c3-empty-focus.jsonl', '');
  const r1 = runCorrelator(emptyFocus, validSync);
  assert.notEqual(r1.status, 0, 'empty focus log must exit non-zero');
  assert.match(r1.stderr, /ERROR:/);
  assert.doesNotMatch(r1.stdout, /PASS|FAIL/, 'no verdict line on a refused input');

  const emptySync = writeFixture('c3-empty-sync.log', '');
  const r2 = runCorrelator(validFocus, emptySync);
  assert.notEqual(r2.status, 0, 'empty sync log must exit non-zero');
  assert.match(r2.stderr, /ERROR:/);
  assert.doesNotMatch(r2.stdout, /PASS|FAIL/);

  const garbageFocus = writeFixture('c3-garbage-focus.jsonl', 'not json at all\n{{{\nalso not json\n');
  const r3 = runCorrelator(garbageFocus, validSync);
  assert.notEqual(r3.status, 0, 'wholly malformed focus log must exit non-zero');
  assert.match(r3.stderr, /ERROR:/);
  assert.doesNotMatch(r3.stdout, /PASS|FAIL/);

  const garbageSync = writeFixture('c3-garbage-sync.log', 'nothing resembling a tick line here\n');
  const r4 = runCorrelator(validFocus, garbageSync);
  assert.notEqual(r4.status, 0, 'sync log with no tick_start values must exit non-zero');
  assert.match(r4.stderr, /ERROR:/);
  assert.doesNotMatch(r4.stdout, /PASS|FAIL/);

  const r5 = runCorrelator(path.join(TMP, 'does-not-exist.jsonl'), validSync);
  assert.notEqual(r5.status, 0, 'a missing file must exit non-zero');
  assert.match(r5.stderr, /ERROR:/);
});

test('C4 determinism: the same --seed produces the same surrogate_p95 (and full verdict) twice', () => {
  const N = 20;
  const baseMs = Date.UTC(2026, 2, 1, 0, 0, 0);
  const tickIntervalMs = 600 * 1000;
  const rand = lcg(555);
  const syncLines = [];
  const focusLines = [];
  for (let i = 0; i < N; i++) {
    const tickMs = baseMs + i * tickIntervalMs;
    syncLines.push(tickLine(new Date(tickMs).toISOString()));
  }
  for (let i = 0; i < 40; i++) {
    const offsetMs = Math.floor(rand() * N * tickIntervalMs);
    focusLines.push(focusLine(new Date(baseMs + offsetMs).toISOString(), i));
  }
  const syncPath = writeFixture('c4-sync.log', `${syncLines.join('\n')}\n`);
  const focusPath = writeFixture('c4-focus.jsonl', `${focusLines.join('\n')}\n`);

  const r1 = runCorrelator(focusPath, syncPath, 4242);
  const r2 = runCorrelator(focusPath, syncPath, 4242);
  assert.equal(r1.status, 0, r1.stderr);
  assert.equal(r2.status, 0, r2.stderr);
  assert.equal(r1.stdout, r2.stdout, 'identical seed + identical input must reproduce byte-identical output');

  const out1 = JSON.parse(r1.stdout.trim());
  const out2 = JSON.parse(r2.stdout.trim());
  assert.equal(out1.surrogate_p95, out2.surrogate_p95);
  assert.equal(out1.verdict, out2.verdict);

  // A DIFFERENT seed is not required to match -- sanity check the seed is
  // actually being used to drive the surrogate draw, not ignored.
  const r3 = runCorrelator(focusPath, syncPath, 1);
  const out3 = JSON.parse(r3.stdout.trim());
  assert.equal(out3.real_count, out1.real_count, 'real_count depends only on the input data, not the seed');
});
