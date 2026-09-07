// scripts/lanes/tests/bench-report.test.mjs — HIMMEL-1723 P2.7
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { INCOMPLETE_DATA_CATEGORIES, TASK_PROFILE, buildResultsTable, buildSummary, classifyRuns, renderReport } from '../bench/report.mjs';
import { buildRunRecord, writeRunManifest } from '../bench/run-manifest.mjs';
import { syntheticRuns, syntheticTokenRows } from './fixtures/bench-report/synthetic-runs.mjs';

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const CLI = join(TEST_DIR, '..', 'bench', 'report.mjs');
const GOLDEN = join(TEST_DIR, 'fixtures', 'bench-report', 'golden.md');

const USAGE_LINE = '{"type":"assistant","message":{"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n';

// Writes the complete 40-run canonical matrix into runsDir, with per-run-id
// overrides: skip (a Set of run-ids to omit entirely), transcriptFor and
// verdictFor (per-run-id functions).
function writeCompleteMatrix(runsDir, { skip, transcriptFor, verdictFor } = {}) {
  const validTranscript = join(runsDir, 'transcript.jsonl');
  writeFileSync(validTranscript, USAGE_LINE);
  for (const task of Object.keys(TASK_PROFILE)) {
    for (const cell of ['haiku', 'luna']) {
      for (const rep of [1, 2]) {
        const runId = `${task}-${cell}-${rep}`;
        if (skip && skip.has(runId)) continue;
        writeRunManifest(runsDir, buildRunRecord({
          run_id: runId, task, cell, rep,
          model: cell === 'haiku' ? 'claude-haiku-4-5' : 'gpt-5.6-luna',
          effort: cell === 'haiku' ? 'low' : 'high', prompt_sha256: `hash-${task}`,
          fixture_path: `/tmp/${runId}`,
          transcript_path: transcriptFor ? transcriptFor(runId) : validTranscript,
          verdict: verdictFor ? verdictFor(runId) : 'pass',
        }));
      }
    }
  }
}

test('TASK_PROFILE matches spec §4.2: 9 code tasks, T10 is haiku-native', () => {
  const values = Object.values(TASK_PROFILE);
  assert.equal(values.filter((v) => v === 'code').length, 9);
  assert.equal(TASK_PROFILE.T10, 'haiku-native');
});

test('golden file: renderReport on the synthetic runs set matches the committed golden.md exactly', () => {
  const text = renderReport({ runs: syntheticRuns, tokenRowsByRunId: syntheticTokenRows() });
  const golden = readFileSync(GOLDEN, 'utf8');
  assert.equal(text, golden);
});

test('buildSummary keeps T1 out of the code bucket and counts nondeterminism + harness errors correctly', () => {
  const summary = buildSummary(syntheticRuns);
  assert.deepEqual(summary.luna.t1, { pass: 2, total: 2 });
  assert.deepEqual(summary.luna.byProfile.code, { pass: 1, total: 2 }); // T7 only, T1 excluded
  assert.equal(summary.luna.nondeterminismCount, 1); // T7: pass vs fail across reps
  assert.equal(summary.haiku.harnessErrorCount, 1); // T10-haiku-2
});

test('renderReport throws loudly on a deliberate cross-cell prompt-hash mismatch (spec §2.3)', () => {
  const badRuns = [
    { run_id: 'T7-haiku-1', task: 'T7', cell: 'haiku', rep: 1, model: 'claude-haiku-4-5', effort: 'low', prompt_sha256: 'hash-a', verdict: 'pass', out_of_scope_paths: [] },
    { run_id: 'T7-luna-1', task: 'T7', cell: 'luna', rep: 1, model: 'gpt-5.6-luna', effort: 'high', prompt_sha256: 'hash-b', verdict: 'pass', out_of_scope_paths: [] }, // deliberately different
  ];
  assert.throws(() => renderReport({ runs: badRuns }), /MISMATCH/);
});

test('CLI: report.mjs exits nonzero on a cross-cell prompt-hash mismatch', () => {
  const runsDir = mkdtempSync(join(tmpdir(), 'bench-report-cli-mismatch-'));
  writeRunManifest(runsDir, buildRunRecord({
    run_id: 'T7-haiku-1', task: 'T7', cell: 'haiku', rep: 1, model: 'claude-haiku-4-5',
    effort: 'low', prompt_sha256: 'hash-a', fixture_path: '/tmp/a', verdict: 'pass',
  }));
  writeRunManifest(runsDir, buildRunRecord({
    run_id: 'T7-luna-1', task: 'T7', cell: 'luna', rep: 1, model: 'gpt-5.6-luna',
    effort: 'high', prompt_sha256: 'hash-b', fixture_path: '/tmp/b', verdict: 'pass',
  }));
  assert.throws(() => execFileSync('node', [CLI, '--runs-dir', runsDir], { encoding: 'utf8' }));
});

test('CLI: report.mjs exits 0 and renders a report for a complete runs/ dir', () => {
  const runsDir = mkdtempSync(join(tmpdir(), 'bench-report-cli-clean-'));
  const transcriptPath = join(runsDir, 'transcript.jsonl');
  writeFileSync(transcriptPath, USAGE_LINE);
  for (const task of Object.keys(TASK_PROFILE)) {
    for (const cell of ['haiku', 'luna']) {
      for (const rep of [1, 2]) {
        writeRunManifest(runsDir, buildRunRecord({
          run_id: `${task}-${cell}-${rep}`, task, cell, rep,
          model: cell === 'haiku' ? 'claude-haiku-4-5' : 'gpt-5.6-luna',
          effort: cell === 'haiku' ? 'low' : 'high', prompt_sha256: `hash-${task}`,
          fixture_path: `/tmp/${task}-${cell}-${rep}`, transcript_path: transcriptPath, verdict: 'pass',
        }));
      }
    }
  }
  const out = execFileSync('node', [CLI, '--runs-dir', runsDir], { encoding: 'utf8' });
  assert.match(out, /## Results/);
  assert.match(out, /## Summary/);
  assert.match(out, /## Threats to validity/);
  assert.doesNotMatch(out, /## Data completeness/); // complete corpus: no unknowns to surface
  assert.doesNotMatch(out, /UNKNOWN/);
});

test('CLI: an unresolvable transcript is surfaced per-run as UNKNOWN, not a hard exit', () => {
  const runsDir = mkdtempSync(join(tmpdir(), 'bench-report-cli-unresolvable-'));
  const validTranscript = join(runsDir, 'valid.jsonl');
  const malformedTranscript = join(runsDir, 'malformed.jsonl');
  writeFileSync(validTranscript, USAGE_LINE);
  writeFileSync(malformedTranscript, 'not-json\n');
  writeCompleteMatrix(runsDir, {
    transcriptFor: (runId) => (runId === 'T7-luna-1' ? malformedTranscript : validTranscript),
  });
  const out = execFileSync('node', [CLI, '--runs-dir', runsDir], { encoding: 'utf8' });
  assert.match(out, /## Results/); // the render is not killed
  assert.match(out, /\| T7-luna-1 \| T7 \| luna \| 1 \| pass \| 0 \| UNKNOWN \| UNKNOWN \| UNKNOWN \|/);
  assert.doesNotMatch(out, /\| T7-luna-2 [^\n]*\| UNKNOWN \|/); // resolvable runs render real numbers
  assert.match(out, /## Data completeness/);
  assert.match(out, /unresolvable transcript usage[^\n]*T7-luna-1/);
});

test('CLI: a marked probe manifest is excluded from stats and does not fail the report', () => {
  const runsDir = mkdtempSync(join(tmpdir(), 'bench-report-cli-probe-'));
  writeCompleteMatrix(runsDir);
  // A pipeline smoke-test dispatch for T7. verdict 'fail' on purpose: if the
  // probe leaked into the luna summary, T7's verdicts would disagree and the
  // nondeterminism count would rise from 0.
  writeRunManifest(runsDir, buildRunRecord({
    run_id: 'T7-luna-probe', task: 'T7', cell: 'luna', rep: 1, model: 'gpt-5.6-luna',
    effort: 'high', prompt_sha256: 'hash-T7', fixture_path: '/tmp/probe',
    transcript_path: '-', verdict: 'fail', probe: true,
  }));
  const out = execFileSync('node', [CLI, '--runs-dir', runsDir], { encoding: 'utf8' });
  assert.match(out, /## Results/);
  assert.doesNotMatch(out, /\| T7-luna-probe \|/); // never a results-table row
  assert.match(out, /probe run\(s\) excluded from every table and stat: 1 — T7-luna-probe/);
  assert.match(out, /### luna[\s\S]*?nondeterminism \(tasks where reps disagreed\): 0/);
});

test('CLI: missing canonical runs and pending verdicts surface in-report, not as a hard exit', () => {
  const runsDir = mkdtempSync(join(tmpdir(), 'bench-report-cli-incomplete-'));
  writeCompleteMatrix(runsDir, {
    skip: new Set(['T10-luna-2']),
    verdictFor: (runId) => (runId === 'T7-luna-2' ? 'PENDING' : 'pass'),
  });
  const out = execFileSync('node', [CLI, '--runs-dir', runsDir], { encoding: 'utf8' });
  assert.match(out, /## Results/); // the render is not killed
  assert.match(out, /\| T7-luna-2 \| T7 \| luna \| 2 \| PENDING \|/);
  assert.match(out, /canonical run\(s\) MISSING[^\n]*: 1 — T10-luna-2/);
  assert.match(out, /run\(s\) PENDING[^\n]*: 1[^\n]*T7-luna-2/);
});

test('CLI: a genuinely unexpected (unmarked) manifest still fails the whole report', () => {
  const runsDir = mkdtempSync(join(tmpdir(), 'bench-report-cli-unexpected-'));
  writeCompleteMatrix(runsDir);
  // Off the canonical matrix AND not marked probe — this is the gate the
  // surfacing rework must keep (wrong --runs-dir / misnamed run-id).
  writeRunManifest(runsDir, buildRunRecord({
    run_id: 'T99-luna-1', task: 'T99', cell: 'luna', rep: 1, model: 'gpt-5.6-luna',
    effort: 'high', prompt_sha256: 'hash-T99', fixture_path: '/tmp/t99', verdict: 'pass',
  }));
  assert.throws(
    () => execFileSync('node', [CLI, '--runs-dir', runsDir], { encoding: 'utf8' }),
    (error) => {
      const output = `${error.stdout || ''}${error.stderr || ''}`;
      assert.match(output, /UNKNOWN — unexpected non-canonical run manifest\(s\): T99-luna-1/);
      assert.doesNotMatch(output, /## Results/);
      return true;
    },
  );
});

test('classifyRuns: a run_id that disagrees with the task/cell/rep tuple is invalid, never canonical', () => {
  // HIMMEL-1723 CR2: the tuple alone must not vouch for a manifest — its
  // run_id has to AGREE with it. One manifest misnames the slot it claims;
  // the other has no run_id at all, so its identity cannot be established.
  const result = classifyRuns([
    { run_id: 'T7-luna-typo', task: 'T7', cell: 'luna', rep: 1, verdict: 'pass' },
    { task: 'T7', cell: 'luna', rep: 1, verdict: 'pass' },
  ]);
  assert.equal(result.invalid.length, 2);
  assert.match(result.invalid[0], /T7-luna-typo != T7-luna-1/);
  assert.match(result.invalid[1], /no run_id/);
  assert.equal(result.unexpected.length, 0); // its own category, not "unexpected"
  assert.ok(result.missing.includes('T7-luna-1')); // the claimed slot is NOT silently filled
  assert.equal(result.ok, false);
});

test('CLI: a self-inconsistent manifest (run_id != tuple) is excluded and surfaced, not counted and not fatal', () => {
  const runsDir = mkdtempSync(join(tmpdir(), 'bench-report-cli-inconsistent-'));
  writeCompleteMatrix(runsDir);
  // run_id says T7-luna-typo while the tuple claims the T7-luna-1 slot. The
  // verdict ('fail', against two real passes) and the divergent prompt hash
  // are both poison: if this manifest leaked into ANY stat or into the
  // parity check, T7-luna nondeterminism would rise or the render would
  // hard-exit on a hash MISMATCH. It must instead be excluded everywhere.
  writeRunManifest(runsDir, buildRunRecord({
    run_id: 'T7-luna-typo', task: 'T7', cell: 'luna', rep: 1, model: 'gpt-5.6-luna',
    effort: 'high', prompt_sha256: 'hash-OTHER', fixture_path: '/tmp/typo',
    transcript_path: '-', verdict: 'fail',
  }));
  const out = execFileSync('node', [CLI, '--runs-dir', runsDir], { encoding: 'utf8' });
  assert.match(out, /## Results/); // the render is not killed (unlike an off-matrix manifest)
  assert.doesNotMatch(out, /\| T7-luna-typo \|/); // never a results-table row
  assert.match(out, /invalid manifest\(s\) excluded from every table and stat[^\n]*T7-luna-typo != T7-luna-1/);
  assert.match(out, /### luna[\s\S]*?nondeterminism \(tasks where reps disagreed\): 0/); // its verdict never counted
  assert.doesNotMatch(out, /canonical run\(s\) MISSING/); // the REAL T7-luna-1 manifest still fills its slot
});

test('renderReport: raw runs containing a self-inconsistent manifest surface it as excluded, and it cannot trip parity', () => {
  // The pure path (a caller passing unfiltered runs) must defend itself the
  // same way the CLI does: hTYPO disagrees with every real T7 hash, so a
  // missing internal filter would make this call throw on parity instead of
  // rendering.
  const text = renderReport({
    runs: [
      ...syntheticRuns,
      { run_id: 'T7-luna-typo', task: 'T7', cell: 'luna', rep: 1, model: 'gpt-5.6-luna', effort: 'high', prompt_sha256: 'hTYPO', verdict: 'fail', out_of_scope_paths: [] },
    ],
    tokenRowsByRunId: syntheticTokenRows(),
  });
  assert.doesNotMatch(text, /\| T7-luna-typo \|/);
  assert.match(text, /invalid manifest\(s\) excluded from every table and stat[^\n]*T7-luna-typo != T7-luna-1/);
});

test('classifyRuns: measurement carries pending runs (they render as rows) but scored does not (they never reach stats)', () => {
  const c = classifyRuns([
    { run_id: 'T7-luna-1', task: 'T7', cell: 'luna', rep: 1, verdict: 'pass' },
    { run_id: 'T7-luna-2', task: 'T7', cell: 'luna', rep: 2, verdict: 'PENDING' },
    { run_id: 'T7-luna-probe', task: 'T7', cell: 'luna', rep: 1, verdict: 'fail', probe: true },
    { run_id: 'T7-haiku-oops', task: 'T7', cell: 'haiku', rep: 1, verdict: 'fail' },
  ]);
  assert.deepEqual(c.measurement.map((r) => r.run_id), ['T7-luna-1', 'T7-luna-2']);
  assert.deepEqual(c.scored.map((r) => r.run_id), ['T7-luna-1']);
  assert.deepEqual(c.pending, ['T7-luna-2']);
  assert.deepEqual(c.probes, ['T7-luna-probe']);
  assert.match(c.invalid[0], /T7-haiku-oops != T7-haiku-1/);
});

test('buildSummary refuses an undecided verdict — scoring is only reachable through classifyRuns().scored', () => {
  // The CR3 defect: a PENDING run fed to buildSummary scored as a fail and
  // dragged the cell's pass rate. Through renderReport that path no longer
  // exists (buildSummary receives classifyRuns().scored); this tripwire keeps
  // a future DIRECT caller from silently reopening it.
  const pendingRun = { run_id: 'T7-luna-1', task: 'T7', cell: 'luna', rep: 1, verdict: 'PENDING' };
  assert.throws(() => buildSummary([pendingRun]), /undecided verdict/);
  assert.throws(() => buildSummary([{ ...pendingRun, verdict: null }]), /undecided verdict/);
});

test('renderReport: an off-matrix, unmarked, self-consistent manifest fails the pure render too', () => {
  // Latent expression of the same seam (found in the round-4 pass): the
  // module header promised "only structurally WRONG input fails the render"
  // including unexpected manifests, but only the CLI enforced it — the pure
  // path silently rendered an off-matrix manifest as measurement data.
  const offMatrix = { run_id: 'T99-luna-1', task: 'T99', cell: 'luna', rep: 1, model: 'gpt-5.6-luna', effort: 'high', prompt_sha256: 'hT99', verdict: 'pass', out_of_scope_paths: [] };
  assert.throws(() => renderReport({ runs: [...syntheticRuns, offMatrix] }), /unexpected non-canonical/);
});

test('buildResultsTable: an absent out_of_scope_paths surfaces as "-", never a silent 0', () => {
  const rows = buildResultsTable([{ run_id: 'T7-luna-1', task: 'T7', cell: 'luna', rep: 1, verdict: 'pass' }]);
  assert.equal(rows[0].out_of_scope_count, '-');
});

// ---------------------------------------------------------------------------
// THE ROUND-4 GUARD (HIMMEL-1723). The property all three CR rounds violated,
// enforced per category, driven by the registry itself:
//
//   a run surfaced as incomplete contributes NOTHING beyond its resolved
//   facets to the summary stats — with the incomplete datum present, every
//   stat must read exactly as if its unresolved facet did not exist.
//
// Mechanics: for each category in INCOMPLETE_DATA_CATEGORIES, POISONS holds a
// corpus mutation that injects one datum of that category, crafted so that a
// leak into any stat changes the Summary section (poison verdicts 'fail'
// against real passes, divergent prompt hashes that would trip the parity
// gate). The poisoned render's Summary must be byte-identical to a reference
// corpus that simply lacks the unresolved facet. The key-set assertion is the
// ratchet: adding a category to the registry without a poison example here
// FAILS this test, so a new incomplete-data category cannot ship until its
// exclusion is proven — which is exactly the omission of rounds 1, 2 and 3.
//
// Reference semantics per `withholds` facet:
//   'run' / 'verdict' / 'absence' — reference lacks the datum entirely (an
//     unresolved identity or verdict must contribute nothing at all);
//   'tokens' — reference is the COMPLETE corpus (the verdict still scores;
//     only token/cost cells go UNKNOWN, and no summary stat consumes tokens).
const POISONS = {
  missing: {
    // The datum is absence itself: nothing present to exclude, so poison and
    // reference coincide and the Summary equality is trivially true. The
    // load-bearing asserts are `surfaced` and `also`: the empty slot shrinks
    // the denominator (15/15) instead of scoring as a silent fail (15/16).
    poison: (dir) => writeCompleteMatrix(dir, { skip: new Set(['T7-luna-2']) }),
    reference: (dir) => writeCompleteMatrix(dir, { skip: new Set(['T7-luna-2']) }),
    surfaced: /canonical run\(s\) MISSING[^\n]*T7-luna-2/,
    also: (out) => assert.match(summarySection(out), /100% \(15\/15\)/),
  },
  pending: {
    poison: (dir) => writeCompleteMatrix(dir, { verdictFor: (id) => (id === 'T7-luna-2' ? 'PENDING' : 'pass') }),
    reference: (dir) => writeCompleteMatrix(dir, { skip: new Set(['T7-luna-2']) }),
    surfaced: /run\(s\) PENDING[^\n]*T7-luna-2/,
    // The unresolved facet is the verdict only — the run itself still renders.
    also: (out) => assert.match(out, /\| T7-luna-2 \| T7 \| luna \| 2 \| PENDING \|/),
  },
  invalid: {
    poison: (dir) => {
      writeCompleteMatrix(dir);
      writeRunManifest(dir, buildRunRecord({
        run_id: 'T7-luna-typo', task: 'T7', cell: 'luna', rep: 1, model: 'gpt-5.6-luna',
        effort: 'high', prompt_sha256: 'hash-POISON', fixture_path: '/tmp/typo',
        transcript_path: '-', verdict: 'fail',
      }));
    },
    reference: (dir) => writeCompleteMatrix(dir),
    surfaced: /invalid manifest\(s\)[^\n]*T7-luna-typo != T7-luna-1/,
  },
  unresolvedTokens: {
    poison: (dir) => {
      const malformed = join(dir, 'malformed.jsonl');
      writeFileSync(malformed, 'not-json\n');
      writeCompleteMatrix(dir, { transcriptFor: (id) => (id === 'T7-luna-2' ? malformed : join(dir, 'transcript.jsonl')) });
    },
    reference: (dir) => writeCompleteMatrix(dir),
    surfaced: /unresolvable transcript usage[^\n]*T7-luna-2/,
    also: (out) => assert.match(out, /\| T7-luna-2 \| T7 \| luna \| 2 \| pass \| 0 \| UNKNOWN \| UNKNOWN \| UNKNOWN \|/),
  },
  probes: {
    poison: (dir) => {
      writeCompleteMatrix(dir);
      writeRunManifest(dir, buildRunRecord({
        run_id: 'T7-luna-probe', task: 'T7', cell: 'luna', rep: 1, model: 'gpt-5.6-luna',
        effort: 'high', prompt_sha256: 'hash-T7', fixture_path: '/tmp/probe',
        transcript_path: '-', verdict: 'fail', probe: true,
      }));
    },
    reference: (dir) => writeCompleteMatrix(dir),
    surfaced: /probe run\(s\) excluded[^\n]*T7-luna-probe/,
  },
};

function summarySection(text) {
  const start = text.indexOf('## Summary');
  assert.ok(start >= 0, 'report has no Summary section');
  const next = text.indexOf('\n## ', start + 1);
  return text.slice(start, next === -1 ? text.length : next);
}

test('INVARIANT (round-4 guard): every incomplete-data category is surfaced AND excluded from the summary stats', () => {
  assert.deepEqual(
    Object.keys(POISONS).sort(),
    INCOMPLETE_DATA_CATEGORIES.map((c) => c.key).sort(),
    'every category in INCOMPLETE_DATA_CATEGORIES needs a poison example in POISONS (and vice versa) — a new incomplete-data category cannot ship without proving its exclusion here',
  );
  for (const cat of INCOMPLETE_DATA_CATEGORIES) {
    const p = POISONS[cat.key];
    const refDir = mkdtempSync(join(tmpdir(), `bench-inv-ref-${cat.key}-`));
    p.reference(refDir);
    const refOut = execFileSync('node', [CLI, '--runs-dir', refDir], { encoding: 'utf8' });
    const poisonDir = mkdtempSync(join(tmpdir(), `bench-inv-poison-${cat.key}-`));
    p.poison(poisonDir);
    let out;
    try {
      out = execFileSync('node', [CLI, '--runs-dir', poisonDir], { encoding: 'utf8' });
    } catch (e) {
      assert.fail(`category "${cat.key}": incomplete data must render with the gap surfaced, never hard-exit — ${e.stderr || e.message}`);
    }
    assert.match(out, p.surfaced, `category "${cat.key}" is not surfaced in the Data completeness section`);
    assert.equal(
      summarySection(out),
      summarySection(refOut),
      `category "${cat.key}" leaked into the summary stats: with the incomplete datum present, every stat must read exactly as if its unresolved facet did not exist`,
    );
    if (p.also) p.also(out);
  }
});
