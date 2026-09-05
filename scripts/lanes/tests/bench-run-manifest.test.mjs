// scripts/lanes/tests/bench-run-manifest.test.mjs — HIMMEL-1723 P2.4
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  RUN_MANIFEST_FIELDS,
  buildRunRecord,
  checkPromptHashParity,
  listRunManifests,
  promptSha256,
  readRunManifest,
  writeRunManifest,
} from '../bench/run-manifest.mjs';

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const CLI = join(TEST_DIR, '..', 'bench', 'run-manifest.mjs');

test('promptSha256 matches a plain sha256 of the exact prompt text', () => {
  const text = 'Convert every printf | grep -q site to a here-string helper.\n';
  const expected = createHash('sha256').update(text, 'utf8').digest('hex');
  assert.equal(promptSha256(text), expected);
});

test('buildRunRecord fills the full schema and rejects a missing required field', () => {
  const record = buildRunRecord({
    run_id: 'T7-luna-1', task: 'T7', cell: 'luna', rep: 1, model: 'gpt-5.6-luna',
    effort: 'high', prompt_sha256: 'abc123', fixture_path: '/tmp/x',
  });
  assert.deepEqual(Object.keys(record).sort(), [...RUN_MANIFEST_FIELDS].sort());
  assert.equal(record.transcript_path, null);
  assert.equal(record.verdict, null);
  assert.deepEqual(record.out_of_scope_paths, []);
  assert.equal(record.rep, 1);

  assert.throws(() => buildRunRecord({ task: 'T7', cell: 'luna' }), /missing required field/);
});

test('buildRunRecord defaults probe to false and round-trips probe: true (pipeline smoke-test marker)', () => {
  const base = {
    run_id: 'T7-luna-probe', task: 'T7', cell: 'luna', rep: 1, model: 'gpt-5.6-luna',
    effort: 'high', prompt_sha256: 'abc123', fixture_path: '/tmp/x',
  };
  assert.equal(buildRunRecord(base).probe, false); // a measurement unless explicitly marked
  assert.equal(buildRunRecord({ ...base, probe: true }).probe, true);
});

test('writeRunManifest / readRunManifest round-trip through disk exactly', () => {
  const runsDir = mkdtempSync(join(tmpdir(), 'bench-run-manifest-'));
  const record = buildRunRecord({
    run_id: 'T7-haiku-2', task: 'T7', cell: 'haiku', rep: 2, model: 'claude-haiku-4-5',
    effort: 'low', prompt_sha256: 'deadbeef', fixture_path: '/tmp/y',
    duration_ms: 1234, exit_code: 0, verdict: 'pass',
  });
  const path = writeRunManifest(runsDir, record);
  assert.ok(path.endsWith('T7-haiku-2.json'));
  const readBack = readRunManifest(runsDir, 'T7-haiku-2');
  assert.deepEqual(readBack, record);
  assert.equal(readRunManifest(runsDir, 'does-not-exist'), null);
});

test('listRunManifests returns every written record and nothing for an empty dir', () => {
  const runsDir = mkdtempSync(join(tmpdir(), 'bench-run-manifest-list-'));
  assert.deepEqual(listRunManifests(runsDir), []);
  writeRunManifest(runsDir, buildRunRecord({
    run_id: 'T1-luna-1', task: 'T1', cell: 'luna', rep: 1, model: 'gpt-5.6-luna',
    effort: 'high', prompt_sha256: 'h1', fixture_path: '/tmp/a',
  }));
  writeRunManifest(runsDir, buildRunRecord({
    run_id: 'T1-haiku-1', task: 'T1', cell: 'haiku', rep: 1, model: 'claude-haiku-4-5',
    effort: 'low', prompt_sha256: 'h1', fixture_path: '/tmp/b',
  }));
  const all = listRunManifests(runsDir);
  assert.equal(all.length, 2);
  assert.deepEqual(all.map((r) => r.run_id).sort(), ['T1-haiku-1', 'T1-luna-1']);
});

test('checkPromptHashParity passes when both cells share the same hash per task', () => {
  const records = [
    { task: 'T7', cell: 'haiku', prompt_sha256: 'same-hash' },
    { task: 'T7', cell: 'luna', prompt_sha256: 'same-hash' },
  ];
  const result = checkPromptHashParity(records);
  assert.equal(result.ok, true);
  assert.deepEqual(result.mismatches, []);
});

test('checkPromptHashParity FAILS loudly on a deliberate cross-cell mismatch (spec §2.3)', () => {
  const records = [
    { task: 'T7', cell: 'haiku', prompt_sha256: 'hash-a' },
    { task: 'T7', cell: 'luna', prompt_sha256: 'hash-b' }, // deliberately different
    { task: 'T9', cell: 'haiku', prompt_sha256: 'hash-c' },
    { task: 'T9', cell: 'luna', prompt_sha256: 'hash-c' }, // this task is fine
  ];
  const result = checkPromptHashParity(records);
  assert.equal(result.ok, false);
  assert.equal(result.mismatches.length, 1);
  assert.equal(result.mismatches[0].task, 'T7');
});

test('checkPromptHashParity catches a rep-to-rep drift the per-cell index used to mask (codex CR)', () => {
  // Regression: the old byTask[task][cell] = hash indexing kept only the LAST
  // record per cell. Here rep 2 agrees across cells, so the old code compared
  // hash-a vs hash-a and reported CLEAN — while rep 1's luna dispatch had in
  // fact run against a different prompt. Every record must be compared.
  const records = [
    { task: 'T7', cell: 'haiku', rep: 1, prompt_sha256: 'hash-a' },
    { task: 'T7', cell: 'luna', rep: 1, prompt_sha256: 'hash-DRIFTED' },
    { task: 'T7', cell: 'haiku', rep: 2, prompt_sha256: 'hash-a' },
    { task: 'T7', cell: 'luna', rep: 2, prompt_sha256: 'hash-a' },
  ];
  const result = checkPromptHashParity(records);
  assert.equal(result.ok, false);
  assert.equal(result.mismatches.length, 1);
  assert.equal(result.mismatches[0].task, 'T7');
  assert.equal(result.mismatches[0].distinct.length, 2);
});

test('checkPromptHashParity catches drift between two reps of the SAME cell', () => {
  const records = [
    { task: 'T9', cell: 'luna', rep: 1, prompt_sha256: 'hash-x' },
    { task: 'T9', cell: 'luna', rep: 2, prompt_sha256: 'hash-y' },
  ];
  const result = checkPromptHashParity(records);
  assert.equal(result.ok, false);
  assert.equal(result.mismatches[0].task, 'T9');
});

test('CLI: write --prompt-file computes prompt_sha256 from the file and the manifest round-trips', () => {
  const runsDir = mkdtempSync(join(tmpdir(), 'bench-run-manifest-cli-'));
  const promptFile = join(runsDir, 'prompt.md');
  const promptText = 'Bump the pinned tool version and add the CHANGELOG line.\n';
  writeFileSync(promptFile, promptText);

  const out = execFileSync('node', [
    CLI, 'write', '--runs-dir', runsDir, '--run-id', 'T7-luna-1', '--task', 'T7', '--cell', 'luna',
    '--rep', '1', '--model', 'gpt-5.6-luna', '--effort', 'high', '--prompt-file', promptFile,
    '--fixture-path', '/tmp/fixture', '--exit-code', '0', '--duration-ms', '5000',
  ], { encoding: 'utf8' });

  const writtenPath = out.trim();
  const record = JSON.parse(readFileSync(writtenPath, 'utf8'));
  assert.equal(record.prompt_sha256, createHash('sha256').update(promptText, 'utf8').digest('hex'));
  assert.equal(record.exit_code, 0);
  assert.equal(record.duration_ms, 5000);
});

test('CLI: check-parity exits nonzero on a mismatch and 0 when clean', () => {
  const runsDir = mkdtempSync(join(tmpdir(), 'bench-run-manifest-cli-parity-'));
  writeRunManifest(runsDir, buildRunRecord({
    run_id: 'T7-haiku-1', task: 'T7', cell: 'haiku', rep: 1, model: 'claude-haiku-4-5',
    effort: 'low', prompt_sha256: 'hash-a', fixture_path: '/tmp/a',
  }));
  writeRunManifest(runsDir, buildRunRecord({
    run_id: 'T7-luna-1', task: 'T7', cell: 'luna', rep: 1, model: 'gpt-5.6-luna',
    effort: 'high', prompt_sha256: 'hash-b', fixture_path: '/tmp/b',
  }));
  assert.throws(() => execFileSync('node', [CLI, 'check-parity', '--runs-dir', runsDir], { encoding: 'utf8' }));

  const cleanDir = mkdtempSync(join(tmpdir(), 'bench-run-manifest-cli-parity-clean-'));
  writeRunManifest(cleanDir, buildRunRecord({
    run_id: 'T7-haiku-1', task: 'T7', cell: 'haiku', rep: 1, model: 'claude-haiku-4-5',
    effort: 'low', prompt_sha256: 'same', fixture_path: '/tmp/a',
  }));
  writeRunManifest(cleanDir, buildRunRecord({
    run_id: 'T7-luna-1', task: 'T7', cell: 'luna', rep: 1, model: 'gpt-5.6-luna',
    effort: 'high', prompt_sha256: 'same', fixture_path: '/tmp/b',
  }));
  const out = execFileSync('node', [CLI, 'check-parity', '--runs-dir', cleanDir], { encoding: 'utf8' });
  assert.match(out, /OK/);
});
