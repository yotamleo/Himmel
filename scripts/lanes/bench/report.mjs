#!/usr/bin/env node
// scripts/lanes/bench/report.mjs — HIMMEL-1723 P2.7
// Emits spec §8's bench tables from a runs/ directory: a results table (one
// row per run-id), a summary split by profile with T1 reported in its own
// row (spec §4.4), a nondeterminism count, a harness-error count, and the
// standing threats-to-validity block (spec §2.4 / §3.3.1 / §4.4).
//
// Also ENFORCES the cross-cell prompt-hash equality invariant (spec §2.3):
// per task, prompt_sha256(haiku) must equal prompt_sha256(luna). This is the
// one runtime check for a fairness guarantee otherwise only asserted in
// prose — a mismatch fails report generation loudly (nonzero exit) rather
// than silently rendering a comparison between two different prompts.
//
// Incomplete DATA, by contrast, is surfaced, never fatal (HIMMEL-1723 CR1):
// missing canonical runs, pending verdicts, probe manifests, self-inconsistent
// manifests (run_id != the manifest's own task/cell/rep), and runs whose
// transcript usage cannot be resolved render as a "Data completeness"
// section plus per-run UNKNOWN cells, so an in-flight corpus (e.g. the
// committed leg-15 runs) still renders. Only structurally WRONG input fails
// the render: a prompt-hash mismatch, or an unexpected manifest that is off
// the canonical matrix, not marked `probe`, and internally consistent
// (usually a wrong --runs-dir — failing there is the point of the gate).
//
// INVARIANT (HIMMEL-1723 CR1–CR3 round guard): this module has exactly ONE
// classification of runs — INCOMPLETE_DATA_CATEGORIES + classifyRuns — and
// every table, stat and gate derives its input from that classification's
// output sets. The Data-completeness section, and the CLI's stderr note,
// render by iterating the SAME registry that produced the exclusions, so a
// category cannot be surfaced as incomplete without the facet it names being
// withheld from the stats that consume that facet: surfacing and exclusion
// are one object read twice, never two lists maintained in parallel. All
// three CR rounds were the parallel-list failure (probes + unresolvable
// transcripts in CR1, self-inconsistent manifests in CR2, pending verdicts
// in CR3): each added an exclusion to a hand-kept predicate only after the
// category was already being surfaced. The registry closes that seam
// structurally; bench-report.test.mjs's round-4 guard test enforces it per
// category.
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { checkPromptHashParity, listRunManifests } from './run-manifest.mjs';
import { aggregate } from './aggregate-tokens.mjs';

// spec §4.2 — 9 `code` + 1 `haiku-native`. T1 is reported in its OWN row
// (spec §4.4 — the one realistic-scale (~200-site) task; averaging it into
// the 9-task `code` pass rate would let a ~10-file-scale near-100% mask the
// exact failure mode the whole task exists to measure).
export const TASK_PROFILE = {
  T1: 'code', T2: 'code', T3: 'code', T4: 'code', T5: 'code',
  T6: 'code', T7: 'code', T8: 'code', T9: 'code', T10: 'haiku-native',
};
export const T1_TASK_ID = 'T1';

const CANONICAL_CELLS = ['haiku', 'luna'];
const CANONICAL_REPS = [1, 2];

// spec §3.4 — harness-decided outcomes excluded from quality stats, but
// counted and reported separately (harness fragility is a real lane property).
const HARNESS_ERROR_VERDICTS = new Set(['error-harness', 'error-harness-final']);

export function buildResultsTable(runs, tokenRowsByRunId = new Map()) {
  return runs
    .slice()
    .sort((a, b) => String(a.run_id).localeCompare(String(b.run_id)))
    .map((r) => {
      const tok = tokenRowsByRunId.get(r.run_id);
      return {
        run_id: r.run_id,
        task: r.task,
        cell: r.cell,
        rep: r.rep,
        verdict: r.verdict ?? 'PENDING',
        // An absent/malformed out_of_scope_paths surfaces as '-', never a
        // silent 0 — the module contract ("never silently zero-filled")
        // applies to every facet, not just tokens.
        out_of_scope_count: Array.isArray(r.out_of_scope_paths) ? r.out_of_scope_paths.length : '-',
        tokens: tok ? tok.usage : null,
        cost_usd: tok ? tok.cost_usd : null,
        duration_ms: r.duration_ms,
        effort: r.effort,
        prompt_sha256: r.prompt_sha256,
      };
    });
}

function taskProfile(task) {
  return TASK_PROFILE[task] || 'code';
}

// isSelfConsistentRun — a manifest's identity is established by AGREEMENT
// between its own fields, never by one field taken on faith (HIMMEL-1723
// CR2). The canonical run-id format is exactly `${task}-${cell}-${rep}`, so
// a manifest whose run_id names one run while its task/cell/rep tuple names
// another is self-inconsistent: nothing in it can be attributed, and
// counting its numbers under either name would corrupt the stats. Probe
// manifests are exempt (guarded in the registry's `invalid` detect) — their
// ids are `<task>-<cell>-probe` by convention, and they are already excluded
// from every canonical claim.
export function isSelfConsistentRun(r) {
  return r.run_id === `${r.task}-${r.cell}-${r.rep}`;
}

// describeInvalidRun — names both identities so the completeness line points
// at the file (run_id) AND the slot whose data it tried to claim (the tuple).
function describeInvalidRun(r) {
  return `${r.run_id || '(no run_id)'} != ${r.task}-${r.cell}-${r.rep}`;
}

const isVerdictUndecided = (r) => r.verdict === null || r.verdict === undefined || r.verdict === 'PENDING';

// ---------------------------------------------------------------------------
// THE SINGLE SOURCE OF TRUTH for incomplete data (see the module-header
// invariant). Every category declares, in one place: (a) how a run in it is
// detected, (b) which FACET of the run is unresolved and therefore withheld
// from the stats, and (c) the Data-completeness line + CLI-note label that
// surface it. classifyRuns() builds the measurement/scored sets by iterating
// THIS list, and both surfacing surfaces render by iterating THIS list — so
// adding a category here excludes it and surfaces it in the same motion.
//
// `withholds` facets:
//   'run'     — identity unresolved: the manifest reaches NOTHING (no results
//               row, no parity check, no token aggregation, no summary).
//   'verdict' — identity fine, verdict unresolved: the run renders as a
//               results row (verdict cell = PENDING, which IS the surfacing)
//               but never reaches buildSummary — which additionally throws if
//               one gets through (see the tripwire there).
//   'tokens'  — identity + verdict fine, transcript usage unresolved: the run
//               renders and scores, but its token/cost cells render UNKNOWN.
//               Exclusion is structural at the source: aggregate() PARTITIONS
//               runs into resolved rows | missing, so a run reported
//               unresolvable cannot also carry a token row.
//   'absence' — no manifest exists: nothing present to exclude, only surface.
//
// Detect-bearing entries ('run'/'verdict') are evaluated by classifyRuns,
// first match in array order wins; entries without `detect` ('tokens'/
// 'absence') are injected context — the canonical-matrix diff and
// aggregate()'s missing list — whose exclusion is a partition at that source.
//
// NOT in this registry: an off-matrix, internally-consistent, unmarked
// manifest ("unexpected"). That is structurally WRONG input (usually a wrong
// --runs-dir), not incomplete data — it is excluded by REFUSING to render at
// all (CR1 decision, pinned by test).
export const INCOMPLETE_DATA_CATEGORIES = [
  {
    key: 'missing',
    note: 'missing',
    withholds: 'absence',
    items: ({ unknown }) => unknown.missing || [],
    line: (items) => `- canonical run(s) MISSING (no manifest in runs/): ${items.length} — ${items.join(', ')}`,
  },
  {
    key: 'pending',
    note: 'pending',
    withholds: 'verdict',
    detect: isVerdictUndecided,
    describe: (r) => r.run_id,
    items: ({ classified }) => classified.pending,
    line: (items) => `- run(s) PENDING (no verdict yet; excluded from every summary stat): ${items.length} — ${items.join(', ')}`,
  },
  {
    key: 'invalid',
    note: 'invalid',
    withholds: 'run',
    // The probe guard keeps the detect predicates mutually exclusive: probe
    // ids are `<task>-<cell>-probe` by convention, so without it every probe
    // would read as self-inconsistent.
    detect: (r) => r.probe !== true && !isSelfConsistentRun(r),
    describe: describeInvalidRun,
    items: ({ classified }) => classified.invalid,
    line: (items) => `- invalid manifest(s) excluded from every table and stat (run_id does not match its own task/cell/rep): ${items.length} — ${items.join(', ')}`,
  },
  {
    key: 'unresolvedTokens',
    note: 'unresolved-transcripts',
    withholds: 'tokens',
    items: ({ unknown }) => [...new Set(unknown.unresolvedTokens || [])],
    line: (items) => `- run(s) with unresolvable transcript usage (tokens/cost UNKNOWN above): ${items.length} — ${items.join(', ')}`,
  },
  {
    key: 'probes',
    note: 'probes-excluded',
    withholds: 'run',
    detect: (r) => r.probe === true,
    describe: (r) => r.run_id || `${r.task}-${r.cell}-${r.rep}`,
    items: ({ classified }) => classified.probes,
    line: (items) => `- probe run(s) excluded from every table and stat: ${items.length} — ${items.join(', ')}`,
  },
];

// classifyRuns — THE one classification pass (see INCOMPLETE_DATA_CATEGORIES).
// Returns, alongside the per-category item lists, the two derived run sets
// every consumer must use:
//   measurement — identity-established canonical runs: the ONLY input to the
//                 results table, the prompt-hash parity gate, and token
//                 aggregation.
//   scored      — measurement minus verdict-unresolved runs: the ONLY input
//                 to buildSummary.
// Neither set is (or may ever again be) computed by a hand-maintained filter
// at a call site — that parallel-predicate shape is what CR rounds 1–3 each
// broke on (this function replaces both former `runs.filter(...)` sites and
// the former validateCanonicalRuns).
export function classifyRuns(runs) {
  const expected = new Set();
  for (const task of Object.keys(TASK_PROFILE)) {
    for (const cell of CANONICAL_CELLS) {
      for (const rep of CANONICAL_REPS) expected.add(`${task}-${cell}-${rep}`);
    }
  }

  const runExcluders = INCOMPLETE_DATA_CATEGORIES.filter((c) => c.detect && c.withholds === 'run');
  const verdictExcluders = INCOMPLETE_DATA_CATEGORIES.filter((c) => c.detect && c.withholds === 'verdict');
  const out = { unexpected: [], measurement: [], scored: [] };
  for (const c of INCOMPLETE_DATA_CATEGORIES) if (c.detect) out[c.key] = [];

  const seen = new Set();
  for (const r of runs) {
    const rex = runExcluders.find((c) => c.detect(r));
    if (rex) {
      out[rex.key].push(rex.describe(r));
      continue;
    }
    const key = `${r.task}-${r.cell}-${r.rep}`;
    if (!expected.has(key)) {
      out.unexpected.push(r.run_id);
      continue;
    }
    seen.add(key);
    out.measurement.push(r);
    const vex = verdictExcluders.find((c) => c.detect(r));
    if (vex) {
      out[vex.key].push(vex.describe(r));
      continue;
    }
    out.scored.push(r);
  }

  out.missing = [...expected].filter((key) => !seen.has(key));
  out.ok = out.missing.length === 0 && out.unexpected.length === 0 && out.pending.length === 0 && out.invalid.length === 0;
  return out;
}

// incompleteItems — one materialization of every category's surfaced items,
// consumed by BOTH the report's Data-completeness section and the CLI's
// stderr note, so the two surfaces cannot list different category sets.
// `unknown` carries the injected-context categories: `missing` (the
// canonical-matrix diff — an absent manifest cannot reach a stat by
// construction, so injection cannot violate the invariant) and
// `unresolvedTokens` (aggregate()'s missing list — the same partition that
// withheld the token rows).
function incompleteItems(classified, unknown = {}) {
  const ctx = { classified, unknown };
  const out = {};
  for (const c of INCOMPLETE_DATA_CATEGORIES) out[c.key] = c.items(ctx);
  return out;
}

// buildSummary — per cell: pass rate split by profile (T1 excluded from the
// `code` bucket and reported separately), nondeterminism (tasks where reps
// disagreed on verdict), and a harness-error count.
export function buildSummary(runs) {
  const cells = {};
  for (const r of runs) {
    // Tripwire (round-guard invariant): an undecided verdict must never be
    // scored. Through renderReport this cannot happen — buildSummary only
    // receives classifyRuns().scored — so this throw exists for future
    // direct callers, keeping CR round 3 (a PENDING run scored as a fail,
    // dragging the cell's pass rate) structurally unreachable.
    if (isVerdictUndecided(r)) {
      throw new Error(`buildSummary: undecided verdict for ${r.run_id} reached the summary — score only classifyRuns().scored (HIMMEL-1723)`);
    }
    const cell = r.cell;
    if (!cells[cell]) {
      cells[cell] = {
        byProfile: { code: { pass: 0, total: 0 }, 'haiku-native': { pass: 0, total: 0 } },
        t1: { pass: 0, total: 0 },
        harnessErrorCount: 0,
        byTask: new Map(),
      };
    }
    const c = cells[cell];
    const verdict = r.verdict;
    if (HARNESS_ERROR_VERDICTS.has(verdict)) {
      c.harnessErrorCount++;
      continue;
    }
    const pass = verdict === 'pass';
    if (r.task === T1_TASK_ID) {
      c.t1.total++;
      if (pass) c.t1.pass++;
    } else {
      const bucket = c.byProfile[taskProfile(r.task)];
      bucket.total++;
      if (pass) bucket.pass++;
    }
    if (!c.byTask.has(r.task)) c.byTask.set(r.task, new Set());
    c.byTask.get(r.task).add(verdict);
  }
  const out = {};
  for (const [cell, c] of Object.entries(cells)) {
    let nondeterminism = 0;
    for (const verdicts of c.byTask.values()) if (verdicts.size > 1) nondeterminism++;
    out[cell] = {
      byProfile: c.byProfile,
      t1: c.t1,
      harnessErrorCount: c.harnessErrorCount,
      nondeterminismCount: nondeterminism,
    };
  }
  return out;
}

const THREATS_TO_VALIDITY = `## Threats to validity

Reproduced from spec §2.4 (residual confound table), §3.3.1 (axis
comparability), and §4.4 (fixture-scale claim limit) — HIMMEL-1723.

| | Haiku cell | luna cell |
|---|---|---|
| Dispatch | Agent tool, in-session subagent | scripts/claude-codex child process |
| Harness | parent session's | full Claude Code session (own system prompt, hooks, skills) |
| Startup | ~none | proxy preflight + hook/skill load |
| Bank | Claude 5h/weekly | codex weekly |

Not comparable across cells: input/output/cache token counts (different
tokenizers + different harness overhead), wall-clock (startup asymmetry).
The dollar figure is a caveated sanity axis only, never the verdict.

Fixture-scale claim limit (spec §4.4): results at fixture scale do not
license any claim about 500+-site sweeps. T1 (~200 sites) is reported in its
own row above; the rest of the \`code\` tasks are ~10-file scale.
`;

function fmtPct(pass, total) {
  return total === 0 ? 'n/a' : `${Math.round((pass / total) * 100)}% (${pass}/${total})`;
}

// renderReport — pure: takes raw runs + a token-rows map (the CLI wires the
// filesystem; a test can inject synthetic data for a golden-file comparison)
// and classifies the runs ITSELF, so no caller can feed it a set that
// bypasses the exclusions. Throws on structurally WRONG input: a prompt-hash
// parity violation, or an unexpected (off-matrix, unmarked, self-consistent)
// manifest.
//
// Incomplete data is SURFACED, not fatal: probe/invalid/pending categories
// are classified from the runs themselves; `unknown` injects the two
// caller-context categories (`missing` — the canonical-matrix diff — and
// `unresolvedTokens` — aggregate()'s missing list; see incompleteItems for
// why injection cannot violate the invariant). They render as a "Data
// completeness" section plus UNKNOWN token/cost cells. With nothing
// incomplete the output is byte-identical to the committed golden file.
export function renderReport({ runs, tokenRowsByRunId = new Map(), unknown = {} }) {
  const classified = classifyRuns(runs);
  // Structurally WRONG input fails the render (module-header contract). The
  // CLI gates this earlier with its own exit message; this throw covers
  // callers of the pure path, which previously rendered an off-matrix
  // manifest as measurement data.
  if (classified.unexpected.length > 0) {
    throw new Error(`report.mjs: UNKNOWN — unexpected non-canonical run manifest(s): ${classified.unexpected.join(', ')}`);
  }
  const parity = checkPromptHashParity(classified.measurement);
  if (!parity.ok) {
    const detail = parity.mismatches
      .map((m) => `${m.task}: ${m.entries.map((e) => `${e.run_id || `${e.cell}-rep${e.rep}`}=${e.hash}`).join(' ')}`)
      .join('; ');
    throw new Error(`report.mjs: cross-cell prompt hash MISMATCH (spec §2.3 fairness guarantee violated): ${detail}`);
  }

  const results = buildResultsTable(classified.measurement, tokenRowsByRunId);
  const summary = buildSummary(classified.scored);
  const items = incompleteItems(classified, unknown);
  const unresolvedTokens = new Set(items.unresolvedTokens);

  const lines = [];
  lines.push('## Results', '');
  lines.push('| run_id | task | cell | rep | verdict | out_of_scope | tokens_in | tokens_out | cost_usd | duration_ms | effort |');
  lines.push('|---|---|---|---|---|---|---|---|---|---|---|');
  for (const r of results) {
    const unresolvable = unresolvedTokens.has(r.run_id);
    const tin = r.tokens
      ? r.tokens.input_tokens + r.tokens.cache_creation_input_tokens + r.tokens.cache_read_input_tokens
      : (unresolvable ? 'UNKNOWN' : '-');
    const tout = r.tokens ? r.tokens.output_tokens : (unresolvable ? 'UNKNOWN' : '-');
    const cost = r.cost_usd === null || r.cost_usd === undefined
      ? (unresolvable ? 'UNKNOWN' : '-')
      : r.cost_usd.toFixed(4);
    lines.push(`| ${r.run_id} | ${r.task} | ${r.cell} | ${r.rep} | ${r.verdict} | ${r.out_of_scope_count} | ${tin} | ${tout} | ${cost} | ${r.duration_ms ?? '-'} | ${r.effort} |`);
  }

  lines.push('', '## Summary (split by profile, T1 separate)', '');
  for (const cell of Object.keys(summary).sort()) {
    const s = summary[cell];
    lines.push(`### ${cell}`, '');
    lines.push(`- code (excl. T1): ${fmtPct(s.byProfile.code.pass, s.byProfile.code.total)}`);
    lines.push(`- haiku-native: ${fmtPct(s.byProfile['haiku-native'].pass, s.byProfile['haiku-native'].total)}`);
    lines.push(`- T1 (fixture-scale sweep, own row): ${fmtPct(s.t1.pass, s.t1.total)}`);
    lines.push(`- nondeterminism (tasks where reps disagreed): ${s.nondeterminismCount}`);
    lines.push(`- harness-error count: ${s.harnessErrorCount}`, '');
  }

  // Data completeness — rendered by iterating the SAME registry that produced
  // the exclusions above, so a category surfaced here is excluded from the
  // stats by construction, never by a parallel hand-kept list. A fully
  // resolved corpus emits no section at all (golden path).
  const completeness = [];
  for (const cat of INCOMPLETE_DATA_CATEGORIES) {
    if (items[cat.key].length > 0) completeness.push(cat.line(items[cat.key]));
  }
  if (completeness.length > 0) {
    lines.push('## Data completeness', '');
    lines.push('Incomplete data is surfaced here as UNKNOWN, never silently zero-filled (HIMMEL-1723).');
    lines.push(...completeness, '');
  }

  lines.push(THREATS_TO_VALIDITY);
  return lines.join('\n');
}

function parseFlags(args) {
  const out = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) { out[args[i].slice(2)] = args[i + 1]; i++; }
  }
  return out;
}

function main() {
  const flags = parseFlags(process.argv.slice(2));
  if (!flags['runs-dir']) {
    process.stderr.write('usage: report.mjs --runs-dir <dir> [--out <file>]\n');
    process.exitCode = 2;
    return;
  }
  const runs = listRunManifests(flags['runs-dir']);
  const classified = classifyRuns(runs);
  // The unexpected-manifest gate stays a HARD failure on purpose: an
  // off-matrix, internally-consistent manifest that is not a marked probe
  // usually means a wrong --runs-dir, and rendering past it would silently
  // compare the wrong corpus. Everything else (missing/pending/invalid/probe/
  // unresolvable transcripts) is incomplete DATA — surfaced in the report.
  if (classified.unexpected.length > 0) {
    process.stderr.write(`report.mjs: UNKNOWN — unexpected non-canonical run manifest(s): ${classified.unexpected.join(', ')}\n`);
    process.exitCode = 1;
    return;
  }
  // Token aggregation runs over the SAME measurement set the render uses;
  // aggregate() partitions it into resolved rows | missing, so a run whose
  // transcript is unresolvable cannot also contribute a token row.
  const agg = aggregate(classified.measurement, { readTranscript: (p) => readFileSync(p, 'utf8') });
  const tokenRowsByRunId = new Map(agg.rows.map((r) => [r.run_id, r]));
  const unknown = { missing: classified.missing, unresolvedTokens: agg.missing };
  let text;
  try {
    text = renderReport({ runs, tokenRowsByRunId, unknown });
  } catch (e) {
    process.stderr.write(`${e.message}\n`);
    process.exitCode = 1;
    return;
  }
  // The stderr note iterates the registry too — a new incomplete-data
  // category appears here without this code changing.
  const items = incompleteItems(classified, unknown);
  if (INCOMPLETE_DATA_CATEGORIES.some((c) => items[c.key].length > 0)) {
    const counts = INCOMPLETE_DATA_CATEGORIES.map((c) => `${c.note}=${items[c.key].length}`).join(' ');
    process.stderr.write(`report.mjs: note — incomplete corpus rendered with unknowns surfaced (${counts})\n`);
  }
  if (flags.out) writeFileSync(flags.out, text);
  else process.stdout.write(text);
}

// Resolved-path comparison, not a filename suffix (codex CR) — `report.mjs` is
// an especially collision-prone suffix (any `*-report.mjs` would match).
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
