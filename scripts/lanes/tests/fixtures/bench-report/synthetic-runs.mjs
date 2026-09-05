// scripts/lanes/tests/fixtures/bench-report/synthetic-runs.mjs — HIMMEL-1723 P2.7
// A hand-built, small runs/ set used by both the golden-file generator and
// bench-report.test.mjs. Deliberately covers: T1 reported in its own row
// (spec §4.4), a `code` task with disagreeing reps on the luna side
// (nondeterminism), a `haiku-native` task with a harness-error rep (excluded
// from quality stats, counted separately), and token/cost rendering for a
// couple of runs (the rest render "-" to prove the no-token-row path too).
import { costUsd } from '../../../bench/aggregate-tokens.mjs';

export const syntheticRuns = [
  { run_id: 'T1-luna-1', task: 'T1', cell: 'luna', rep: 1, model: 'gpt-5.6-luna', effort: 'high', prompt_sha256: 'hT1', verdict: 'pass', duration_ms: 100, out_of_scope_paths: [] },
  { run_id: 'T1-luna-2', task: 'T1', cell: 'luna', rep: 2, model: 'gpt-5.6-luna', effort: 'high', prompt_sha256: 'hT1', verdict: 'pass', duration_ms: 110, out_of_scope_paths: [] },
  { run_id: 'T1-haiku-1', task: 'T1', cell: 'haiku', rep: 1, model: 'claude-haiku-4-5', effort: 'low', prompt_sha256: 'hT1', verdict: 'fail', duration_ms: 50, out_of_scope_paths: [] },
  { run_id: 'T1-haiku-2', task: 'T1', cell: 'haiku', rep: 2, model: 'claude-haiku-4-5', effort: 'low', prompt_sha256: 'hT1', verdict: 'fail', duration_ms: 55, out_of_scope_paths: [] },

  { run_id: 'T7-luna-1', task: 'T7', cell: 'luna', rep: 1, model: 'gpt-5.6-luna', effort: 'high', prompt_sha256: 'hT7', verdict: 'pass', duration_ms: 200, out_of_scope_paths: [] },
  { run_id: 'T7-luna-2', task: 'T7', cell: 'luna', rep: 2, model: 'gpt-5.6-luna', effort: 'high', prompt_sha256: 'hT7', verdict: 'fail', duration_ms: 210, out_of_scope_paths: [] },
  { run_id: 'T7-haiku-1', task: 'T7', cell: 'haiku', rep: 1, model: 'claude-haiku-4-5', effort: 'low', prompt_sha256: 'hT7', verdict: 'pass', duration_ms: 60, out_of_scope_paths: [] },
  { run_id: 'T7-haiku-2', task: 'T7', cell: 'haiku', rep: 2, model: 'claude-haiku-4-5', effort: 'low', prompt_sha256: 'hT7', verdict: 'pass', duration_ms: 65, out_of_scope_paths: [] },

  { run_id: 'T10-luna-1', task: 'T10', cell: 'luna', rep: 1, model: 'gpt-5.6-luna', effort: 'high', prompt_sha256: 'hT10', verdict: 'fail', duration_ms: 300, out_of_scope_paths: [] },
  { run_id: 'T10-luna-2', task: 'T10', cell: 'luna', rep: 2, model: 'gpt-5.6-luna', effort: 'high', prompt_sha256: 'hT10', verdict: 'fail', duration_ms: 310, out_of_scope_paths: [] },
  { run_id: 'T10-haiku-1', task: 'T10', cell: 'haiku', rep: 1, model: 'claude-haiku-4-5', effort: 'low', prompt_sha256: 'hT10', verdict: 'pass', duration_ms: 40, out_of_scope_paths: [] },
  { run_id: 'T10-haiku-2', task: 'T10', cell: 'haiku', rep: 2, model: 'claude-haiku-4-5', effort: 'low', prompt_sha256: 'hT10', verdict: 'error-harness-final', duration_ms: null, out_of_scope_paths: [] },
];

export function syntheticTokenRows() {
  const map = new Map();
  const lunaUsage = { input_tokens: 18000, output_tokens: 950, cache_creation_input_tokens: 500, cache_read_input_tokens: 6000 };
  const haikuUsage = { input_tokens: 120, output_tokens: 340, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 };
  map.set('T7-luna-1', { usage: lunaUsage, cost_usd: costUsd('gpt-5.6-luna', lunaUsage) });
  map.set('T7-haiku-1', { usage: haikuUsage, cost_usd: costUsd('claude-haiku-4-5', haikuUsage) });
  return map;
}
