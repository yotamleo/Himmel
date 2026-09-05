// scripts/lanes/tests/bench-aggregate-tokens.test.mjs — HIMMEL-1723 P2.5
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  RATES,
  aggregate,
  costUsd,
  cwdToProjectSlug,
  sumTranscriptUsage,
  windowsDriveFormPath,
} from '../bench/aggregate-tokens.mjs';
import { buildRunRecord, writeRunManifest } from '../bench/run-manifest.mjs';

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const CLI = join(TEST_DIR, '..', 'bench', 'aggregate-tokens.mjs');
const HAIKU_SAMPLE = join(TEST_DIR, 'fixtures', 'bench-transcripts', 'haiku-sample.jsonl');
const LUNA_SAMPLE = join(TEST_DIR, 'fixtures', 'bench-transcripts', 'luna-sample.jsonl');

test('windowsDriveFormPath converts a Git-Bash POSIX mount path and passes through a native form', () => {
  assert.equal(windowsDriveFormPath('/c/Users/ada/AppData/Local/Temp'), 'C:\\Users\\ada\\AppData\\Local\\Temp');
  assert.equal(windowsDriveFormPath('C:\\Users\\ada'), 'C:\\Users\\ada'); // already native, no-op
});

test('cwdToProjectSlug matches the empirically-verified real ~/.claude/projects encoding', () => {
  // Verified against a real directory on this machine (username neutralized,
  // HIMMEL-1730 — the transform is username-agnostic, only the literal changed):
  // C:\Users\ada\AppData\Local\Temp -> C--Users-ada-AppData-Local-Temp
  assert.equal(cwdToProjectSlug('/c/Users/ada/AppData/Local/Temp', 'win32'), 'C--Users-ada-AppData-Local-Temp');
  assert.equal(cwdToProjectSlug('C:\\Users\\ada\\AppData\\Local\\Temp', 'win32'), 'C--Users-ada-AppData-Local-Temp');
});

test('cwdToProjectSlug is a no-op path-shape conversion off Windows', () => {
  assert.equal(cwdToProjectSlug('/home/ada/project', 'linux'), 'home-ada-project');
});

test('sumTranscriptUsage sums the committed synthetic sample fixtures correctly', () => {
  const haikuUsage = sumTranscriptUsage(readFileSync(HAIKU_SAMPLE, 'utf8'));
  assert.equal(haikuUsage.input_tokens, 135);
  assert.equal(haikuUsage.output_tokens, 430);
  assert.equal(haikuUsage.cache_creation_input_tokens, 0);
  assert.equal(haikuUsage.cache_read_input_tokens, 1200);
  assert.equal(haikuUsage.usage_lines, 2); // the leading _synthetic marker line is skipped

  const lunaUsage = sumTranscriptUsage(readFileSync(LUNA_SAMPLE, 'utf8'));
  assert.equal(lunaUsage.input_tokens, 18300);
  assert.equal(lunaUsage.output_tokens, 1070);
  assert.equal(lunaUsage.cache_creation_input_tokens, 500);
  assert.equal(lunaUsage.cache_read_input_tokens, 24500);
});

test('costUsd applies the spec §0.1 list-price rates', () => {
  const usage = { input_tokens: 1_000_000, output_tokens: 1_000_000, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 };
  assert.equal(costUsd('claude-haiku-4-5', usage), RATES['claude-haiku-4-5'].inputPerM + RATES['claude-haiku-4-5'].outputPerM);
  assert.equal(costUsd('gpt-5.6-luna', usage), RATES['gpt-5.6-luna'].inputPerM + RATES['gpt-5.6-luna'].outputPerM);
  assert.equal(costUsd('unknown-model', usage), null);
});

test('aggregate() resolves every run via an injected readTranscript and reports zero missing', () => {
  const records = [
    { run_id: 'T7-haiku-1', task: 'T7', cell: 'haiku', rep: 1, model: 'claude-haiku-4-5', transcript_path: HAIKU_SAMPLE },
    { run_id: 'T7-luna-1', task: 'T7', cell: 'luna', rep: 1, model: 'gpt-5.6-luna', transcript_path: LUNA_SAMPLE },
  ];
  const result = aggregate(records, { readTranscript: (p) => readFileSync(p, 'utf8') });
  assert.equal(result.missing.length, 0);
  assert.equal(result.rows.length, 2);
  assert.equal(result.dispatchCount, 2);
  assert.equal(result.resolvedCount, 2);
});

test('aggregate() flags an unresolvable transcript as missing (spec §6.1 hard invariant)', () => {
  const records = [
    { run_id: 'T7-haiku-1', task: 'T7', cell: 'haiku', rep: 1, model: 'claude-haiku-4-5', transcript_path: HAIKU_SAMPLE },
    { run_id: 'T7-luna-1', task: 'T7', cell: 'luna', rep: 1, model: 'gpt-5.6-luna', transcript_path: '/does/not/exist.jsonl' },
  ];
  const result = aggregate(records, { readTranscript: (p) => readFileSync(p, 'utf8') });
  assert.deepEqual(result.missing, ['T7-luna-1']);
  assert.equal(result.rows.length, 1);
});

test('CLI: aggregate-tokens.mjs exits 0 and emits cost-annotated rows for a fully-resolved runs/ dir', () => {
  const runsDir = mkdtempSync(join(tmpdir(), 'bench-aggregate-cli-'));
  writeRunManifest(runsDir, buildRunRecord({
    run_id: 'T7-haiku-1', task: 'T7', cell: 'haiku', rep: 1, model: 'claude-haiku-4-5',
    effort: 'low', prompt_sha256: 'h', fixture_path: '/tmp/a', transcript_path: HAIKU_SAMPLE,
  }));
  writeRunManifest(runsDir, buildRunRecord({
    run_id: 'T7-luna-1', task: 'T7', cell: 'luna', rep: 1, model: 'gpt-5.6-luna',
    effort: 'high', prompt_sha256: 'h', fixture_path: '/tmp/b', transcript_path: LUNA_SAMPLE,
  }));
  const out = execFileSync('node', [CLI, '--runs-dir', runsDir], { encoding: 'utf8' });
  const rows = JSON.parse(out);
  assert.equal(rows.length, 2);
  const luna = rows.find((r) => r.run_id === 'T7-luna-1');
  assert.equal(luna.cost_usd, costUsd('gpt-5.6-luna', luna.usage));
});

test('CLI: aggregate-tokens.mjs exits NONZERO when a dispatch has no resolvable transcript', () => {
  const runsDir = mkdtempSync(join(tmpdir(), 'bench-aggregate-cli-missing-'));
  writeRunManifest(runsDir, buildRunRecord({
    run_id: 'T7-luna-1', task: 'T7', cell: 'luna', rep: 1, model: 'gpt-5.6-luna',
    effort: 'high', prompt_sha256: 'h', fixture_path: '/tmp/nonexistent-fixture-path-xyz',
  }));
  assert.throws(() => execFileSync('node', [CLI, '--runs-dir', runsDir], { encoding: 'utf8' }));
});
