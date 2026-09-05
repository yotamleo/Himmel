// scripts/lanes/tests/bench-run-batch.test.mjs — HIMMEL-1723 P2.9
// Exercises the batch driver's hard behaviors hermetically, via
// BENCH_CLAUDE_CODEX_BIN pointed at fixtures/bench-fake-launcher.sh (no real
// codex dispatch): a dispatch failing --retry-cap times lands
// error-harness-final and the batch CONTINUES to the next run-id; a bank
// breach before the first paid attempt ABORTS without launching work.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { BASH_BIN } from './lib/resolve-bash.mjs';

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const RUN_BATCH = join(TEST_DIR, '..', 'bench', 'run-batch.sh');
const FAKE_LAUNCHER = join(TEST_DIR, 'fixtures', 'bench-fake-launcher.sh');

function makeTask(tasksDir, id, promptText) {
  const dir = join(tasksDir, id);
  mkdirSync(join(dir, 'input'), { recursive: true });
  writeFileSync(join(dir, 'input', 'a.txt'), `content for ${id}\n`);
  writeFileSync(join(dir, 'prompt.md'), promptText);
}

// A codex-bank cache fixture as the probe would write it (HIMMEL-1678);
// bank-status reads only this file for the codex bank.
function codexBankCacheFile(bankDir, usedPct) {
  const path = join(bankDir, `codex-bank-${usedPct}.json`);
  writeFileSync(path, JSON.stringify({
    limits: [{ limitId: 'primary', usedPercent: usedPct, windowDurationMins: 10080, resetsAt: Math.floor(Date.now() / 1000) + 86400 }],
    planType: 'prolite',
    capturedAt: new Date().toISOString(),
  }));
  return path;
}

function baseEnv(extra) {
  const bankDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-banks-'));
  const codexCache = codexBankCacheFile(bankDir, 5);
  const claudeCache = join(bankDir, 'claude.json');
  const resetsAt = new Date(Date.now() + 3600_000).toISOString();
  writeFileSync(claudeCache, JSON.stringify({
    five_hour: { utilization: 5, resets_at: resetsAt },
    seven_day: { utilization: 5, resets_at: resetsAt },
  }));
  return {
    ...process.env,
    BENCH_CLAUDE_CODEX_BIN: FAKE_LAUNCHER,
    BENCH_LUNA_TIMEOUT_SECS: '30',
    CODEX_BANK_CACHE: codexCache,
    CLAUDE_USAGE_CACHE: claudeCache,
    ...extra,
  };
}

test('run-batch.sh matrix emits every task x cell x rep run-id', () => {
  const tasksDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-tasks-'));
  makeTask(tasksDir, 'T1', 'do T1\n');
  makeTask(tasksDir, 'T2', 'do T2\n');
  const out = execFileSync(BASH_BIN, [RUN_BATCH, 'matrix', '--tasks-dir', tasksDir, '--reps', '2'], { encoding: 'utf8' });
  const runIds = out.trim().split('\n').map((l) => l.split('\t')[0]).sort();
  assert.deepEqual(runIds, ['T1-haiku-1', 'T1-haiku-2', 'T1-luna-1', 'T1-luna-2', 'T2-haiku-1', 'T2-haiku-2', 'T2-luna-1', 'T2-luna-2']);
});

test('dispatch-luna: a run-id that fails --retry-cap times lands error-harness-final and the batch continues', () => {
  const tasksDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-retry-tasks-'));
  makeTask(tasksDir, 'TA', 'always fails\n');
  makeTask(tasksDir, 'TB', 'always succeeds\n');
  const runsDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-retry-runs-'));
  const scratchRoot = mkdtempSync(join(tmpdir(), 'bench-run-batch-retry-scratch-'));
  const stateDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-retry-state-'));
  const configDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-retry-config-'));
  writeFileSync(join(configDir, 'TA-luna-1'), 'always-fail');
  // TB-luna-1 has no config file -> the fake launcher always succeeds for it.

  const env = baseEnv({
    BENCH_SCRATCH_ROOT: scratchRoot,
    FAKE_LAUNCHER_STATE_DIR: stateDir,
    FAKE_LAUNCHER_CONFIG_DIR: configDir,
  });

  execFileSync(BASH_BIN, [
    RUN_BATCH, 'dispatch-luna', '--tasks-dir', tasksDir, '--runs-dir', runsDir,
    '--reps', '1', '--cells', 'luna', '--retry-cap', '2',
  ], { encoding: 'utf8', env });

  const failedManifest = JSON.parse(readFileSync(join(runsDir, 'TA-luna-1.json'), 'utf8'));
  assert.equal(failedManifest.verdict, 'error-harness-final');
  assert.notEqual(failedManifest.exit_code, 0);

  const okManifest = JSON.parse(readFileSync(join(runsDir, 'TB-luna-1.json'), 'utf8'));
  assert.equal(okManifest.exit_code, 0);
  assert.equal(okManifest.verdict, null); // verify.sh scoring is a later phase (P5.5), not dispatch time

  // The retry cap was honored: exactly 2 attempts were made for TA, not more.
  const attempts = readFileSync(join(stateDir, 'TA-luna-1.attempts'), 'utf8').trim();
  assert.equal(attempts, '2');
});

test('dispatch-luna: resumes by run-id — an already-complete manifest is never re-dispatched', () => {
  const tasksDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-resume-tasks-'));
  makeTask(tasksDir, 'TR', 'resume test\n');
  const runsDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-resume-runs-'));
  const scratchRoot = mkdtempSync(join(tmpdir(), 'bench-run-batch-resume-scratch-'));
  const stateDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-resume-state-'));
  const configDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-resume-config-'));

  const env = baseEnv({
    BENCH_SCRATCH_ROOT: scratchRoot,
    FAKE_LAUNCHER_STATE_DIR: stateDir,
    FAKE_LAUNCHER_CONFIG_DIR: configDir,
  });

  // First pass: dispatches and completes TR-luna-1.
  execFileSync(BASH_BIN, [
    RUN_BATCH, 'dispatch-luna', '--tasks-dir', tasksDir, '--runs-dir', runsDir,
    '--reps', '1', '--cells', 'luna', '--retry-cap', '2',
  ], { encoding: 'utf8', env });
  assert.equal(readFileSync(join(stateDir, 'TR-luna-1.attempts'), 'utf8').trim(), '1');

  // Second pass over the SAME runs-dir must skip the already-complete run-id
  // entirely — the attempt counter must not move.
  execFileSync(BASH_BIN, [
    RUN_BATCH, 'dispatch-luna', '--tasks-dir', tasksDir, '--runs-dir', runsDir,
    '--reps', '1', '--cells', 'luna', '--retry-cap', '2',
  ], { encoding: 'utf8', env });
  assert.equal(readFileSync(join(stateDir, 'TR-luna-1.attempts'), 'utf8').trim(), '1');
});

test('dispatch-luna: the bank check runs before the first paid attempt', () => {
  const tasksDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-bank-tasks-'));
  makeTask(tasksDir, 'B1', 'do B1\n');
  const runsDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-bank-runs-'));
  const scratchRoot = mkdtempSync(join(tmpdir(), 'bench-run-batch-bank-scratch-'));
  const stateDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-bank-state-'));
  const configDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-bank-config-'));
  // mkdtempSync, not a bare join(): writeFileSync into a directory that was
  // never created is an ENOENT, not a fixture.
  const bankCache = codexBankCacheFile(mkdtempSync(join(tmpdir(), 'bench-bank-breach-')), 95); // codex weekly 95% >= 80% refuse threshold

  const env = baseEnv({
    BENCH_SCRATCH_ROOT: scratchRoot,
    FAKE_LAUNCHER_STATE_DIR: stateDir,
    FAKE_LAUNCHER_CONFIG_DIR: configDir,
    CODEX_BANK_CACHE: bankCache, // bank-status.ts test hook (bank-status.test.mjs uses the same one)
  });

  assert.throws(() => execFileSync(BASH_BIN, [
    RUN_BATCH, 'dispatch-luna', '--tasks-dir', tasksDir, '--runs-dir', runsDir,
    '--reps', '1', '--cells', 'luna', '--retry-cap', '2', '--bank-check-every', '3',
  ], { encoding: 'utf8', env }));

  assert.deepEqual(readdirSync(stateDir), [], 'the paid launcher must not run before the bank check passes');
  assert.deepEqual(readdirSync(runsDir), [], 'a refused pre-attempt check must not write a run manifest');
});

test('dispatch-luna: a mid-batch bank breach aborts, and a healthy re-run completes the rest without re-dispatching completed runs', () => {
  // Restores the abort-then-resume coverage the pre-"fail closed" bank
  // breach test carried (dropped when that test was replaced): an aborted
  // batch leaves completed runs intact, and re-running with a healthy bank
  // completes the REMAINING runs without re-dispatching the already-
  // completed ones. The old single-invocation shape (bank breached from the
  // start, --bank-check-every 3) is unreachable now the check fires before
  // the FIRST paid attempt, so the breach is staged between invocations.
  const tasksDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-abort-tasks-'));
  makeTask(tasksDir, 'R1', 'do R1\n');
  makeTask(tasksDir, 'R2', 'do R2\n');
  const runsDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-abort-runs-'));
  const scratchRoot = mkdtempSync(join(tmpdir(), 'bench-run-batch-abort-scratch-'));
  const stateDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-abort-state-'));
  const configDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-abort-config-'));
  const bankDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-abort-banks-'));
  const healthyCache = codexBankCacheFile(bankDir, 5);
  const breachedCache = codexBankCacheFile(bankDir, 95);

  const env = baseEnv({
    BENCH_SCRATCH_ROOT: scratchRoot,
    FAKE_LAUNCHER_STATE_DIR: stateDir,
    FAKE_LAUNCHER_CONFIG_DIR: configDir,
    CODEX_BANK_CACHE: healthyCache,
  });
  const dispatch = (bankCache, tasks) => execFileSync(BASH_BIN, [
    RUN_BATCH, 'dispatch-luna', '--tasks-dir', tasksDir, '--runs-dir', runsDir,
    '--reps', '1', '--cells', 'luna', '--retry-cap', '2', '--bank-check-every', '1',
    ...(tasks ? ['--tasks', tasks] : []),
  ], { encoding: 'utf8', env: { ...env, CODEX_BANK_CACHE: bankCache } });

  // Pass 1 (healthy bank): complete R1 only.
  dispatch(healthyCache, 'R1');
  assert.equal(readFileSync(join(stateDir, 'R1-luna-1.attempts'), 'utf8').trim(), '1');

  // Pass 2 (breached bank): R1 must be skipped untouched; the batch aborts
  // before R2's first paid attempt, leaving R1 intact and resumable.
  assert.throws(() => dispatch(breachedCache, null));
  assert.equal(readFileSync(join(stateDir, 'R1-luna-1.attempts'), 'utf8').trim(), '1');
  assert.ok(!existsSync(join(stateDir, 'R2-luna-1.attempts')), 'the abort must fire before R2 is dispatched');
  assert.ok(!existsSync(join(runsDir, 'R2-luna-1.json')), 'no manifest for a run that never dispatched');
  const r1 = JSON.parse(readFileSync(join(runsDir, 'R1-luna-1.json'), 'utf8'));
  assert.equal(r1.exit_code, 0); // the completed run survived the abort

  // Pass 3 (healthy again): completes R2 WITHOUT re-dispatching R1.
  dispatch(healthyCache, null);
  assert.equal(readFileSync(join(stateDir, 'R1-luna-1.attempts'), 'utf8').trim(), '1');
  assert.equal(readFileSync(join(stateDir, 'R2-luna-1.attempts'), 'utf8').trim(), '1');
  assert.deepEqual(readdirSync(runsDir).filter((f) => f.endsWith('.json')).sort(), ['R1-luna-1.json', 'R2-luna-1.json']);
});

test('ingest-haiku writes a manifest for a manually-executed haiku run', () => {
  const tasksDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-ingest-tasks-'));
  makeTask(tasksDir, 'TH', 'haiku task\n');
  const runsDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-ingest-runs-'));

  // Deliberately NOT a POSIX-absolute-looking value (no leading '/'): Git
  // Bash auto-rewrites an argv value shaped like /tmp/x into a Windows path
  // before run-batch.sh ever sees it (the same argv-mangling
  // scripts/lib/proc-tree.sh works around for `tasklist`/`taskkill` via
  // MSYS_NO_PATHCONV — not usable HERE because it would equally suppress the
  // conversion run-batch.sh's OWN script-path argument needs). What's under
  // test is only that the supplied value round-trips verbatim into the
  // manifest, so a non-path-shaped placeholder sidesteps the mangling
  // entirely rather than fighting it.
  execFileSync(BASH_BIN, [
    RUN_BATCH, 'ingest-haiku', '--tasks-dir', tasksDir, '--runs-dir', runsDir,
    '--run-id', 'TH-haiku-1', '--task', 'TH', '--rep', '1',
    '--fixture-path', 'placeholder-fixture', '--transcript-path', 'placeholder-transcript.jsonl',
    '--exit-code', '0', '--duration-ms', '4200',
  ], { encoding: 'utf8' });

  const record = JSON.parse(readFileSync(join(runsDir, 'TH-haiku-1.json'), 'utf8'));
  assert.equal(record.cell, 'haiku');
  assert.equal(record.model, 'claude-haiku-4-5');
  assert.equal(record.transcript_path, 'placeholder-transcript.jsonl');
  assert.equal(record.exit_code, 0);
});

test('emit-manual-queue lists pending haiku run-ids with their literal prompt text', () => {
  const tasksDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-queue-tasks-'));
  makeTask(tasksDir, 'TQ', 'THE LITERAL PROMPT TEXT\n');
  const runsDir = mkdtempSync(join(tmpdir(), 'bench-run-batch-queue-runs-'));
  const out = execFileSync(BASH_BIN, [
    RUN_BATCH, 'emit-manual-queue', '--tasks-dir', tasksDir, '--runs-dir', runsDir, '--reps', '1',
  ], { encoding: 'utf8' });
  assert.match(out, /TQ-haiku-1/);
  assert.match(out, /THE LITERAL PROMPT TEXT/);
  assert.doesNotMatch(out, /TQ-luna-1/); // only the haiku cell — luna is scriptable, not queued
});
