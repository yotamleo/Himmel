#!/usr/bin/env node
// scripts/lanes/bench/aggregate-tokens.mjs — HIMMEL-1723 P2.5
// Walks each run's Claude Code transcript, sums usage.{input_tokens,
// output_tokens,cache_creation_input_tokens,cache_read_input_tokens}, joins
// to run-ids, and computes $ at spec §0.1 list-price rates.
//
// Hard invariant (spec §6.1): count(resolved transcripts) MUST equal
// count(dispatches). The CLI asserts this and fails loudly (nonzero exit)
// rather than silently under-reporting — a silent drop would bias the only
// cost axis this bench reports.
//
// Transcript locations (spec §6.1):
//   haiku  ~/.claude/projects/<proj-slug>/<session-uuid>/subagents/agent-<id>.jsonl
//          (+ an agent-<id>.meta.json sidecar — the mapping handle). The
//          Haiku cell is dispatched by hand (Agent tool, not scriptable), so
//          this path is resolved at INGEST time by whoever ran the
//          dispatch and recorded into the run manifest's transcript_path —
//          this module trusts that field for the haiku cell rather than
//          guessing a session-uuid it has no way to discover.
//   luna   ~/.claude-codex/projects/<slug-of-cwd>/<uuid>.jsonl — resolvable
//          here because dispatch-luna.sh (the driver) chose the cwd itself,
//          so resolveLunaTranscript below can recompute the same slug.
import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { listRunManifests } from './run-manifest.mjs';

// spec §0.1, retrieved 2026-08-11 — $/M tokens (first-party list price).
export const RATES = {
  'claude-haiku-4-5': { inputPerM: 1.00, outputPerM: 5.00 },
  'gpt-5.6-luna': { inputPerM: 0.20, outputPerM: 1.20 },
};

// windowsDriveFormPath / cwdToProjectSlug mirror Claude Code's own path->slug
// encoding, PROVEN against a real ~/.claude/projects listing on this machine
// (same algorithm as scripts/luna/backfill-sessions.sh:_path_to_slug): every
// character outside [a-zA-Z0-9] becomes '-', a leading '-' is stripped.
//
// Windows-only nuance: Claude Code is a native Node process, so it reports
// its own cwd in DRIVE-LETTER form (C:\Users\...) even when the launching
// shell's cwd is a Git-Bash POSIX mount path (/c/Users/...) — that mount
// form must be converted FIRST (mirrors `cygpath -w`) or the slug silently
// diverges (wrong drive-letter case, missing ':' before the first
// separator). Off Windows this is a no-op.
export function windowsDriveFormPath(p) {
  const m = /^\/([a-zA-Z])\/(.*)$/.exec(String(p));
  if (!m) return p;
  return `${m[1].toUpperCase()}:\\${m[2].replace(/\//g, '\\')}`;
}

export function cwdToProjectSlug(cwdPath, platform = process.platform) {
  const winForm = platform === 'win32' ? windowsDriveFormPath(cwdPath) : cwdPath;
  return String(winForm).replace(/[^a-zA-Z0-9]/g, '-').replace(/^-+/, '');
}

// resolveLunaTranscript — the newest .jsonl under
// ~/.claude-codex/projects/<slug-of-fixturePath>/. Fixture dirs are unique
// per run-id (materialize.sh mints a fresh scratch dir every call), so at
// most one dispatch's transcripts live under that slug.
export function resolveLunaTranscript(fixturePath, home = homedir()) {
  const slug = cwdToProjectSlug(fixturePath);
  const projDir = join(home, '.claude-codex', 'projects', slug);
  if (!existsSync(projDir)) return null;
  const jsonls = readdirSync(projDir).filter((f) => f.endsWith('.jsonl'));
  if (jsonls.length === 0) return null;
  jsonls.sort((a, b) => statSync(join(projDir, b)).mtimeMs - statSync(join(projDir, a)).mtimeMs);
  return join(projDir, jsonls[0]);
}

const EMPTY_USAGE = { input_tokens: 0, output_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 };

// sumTranscriptUsage — pure: takes JSONL TEXT (not a path), sums every
// assistant message's usage object (record.message.usage, the real Claude
// Code transcript shape — verified against a live transcript on this
// machine). Non-JSON / non-assistant / usage-less lines are skipped, not
// fatal, so a leading synthetic-marker line (see the committed sample
// fixtures' header comment) does not break parsing.
export function sumTranscriptUsage(jsonlText) {
  const totals = { ...EMPTY_USAGE };
  let usageLines = 0;
  for (const line of String(jsonlText).split(/\r?\n/)) {
    if (!line.trim()) continue;
    let record;
    try { record = JSON.parse(line); } catch { continue; }
    // Only assistant records carry billable usage (codex CR): the contract in
    // this function's header said so, but nothing enforced it, so any other
    // record type that happens to carry message.usage would have been summed
    // into the cost axis.
    if (!record || record.type !== 'assistant') continue;
    const usage = record.message && record.message.usage;
    if (!usage || typeof usage !== 'object') continue;
    for (const key of Object.keys(EMPTY_USAGE)) {
      const v = usage[key];
      if (typeof v === 'number' && Number.isFinite(v)) totals[key] += v;
    }
    usageLines++;
  }
  return { ...totals, usage_lines: usageLines };
}

export function costUsd(model, usage) {
  const rate = RATES[model];
  if (!rate) return null;
  const inputTokens = usage.input_tokens + usage.cache_creation_input_tokens + usage.cache_read_input_tokens;
  return (inputTokens / 1_000_000) * rate.inputPerM + (usage.output_tokens / 1_000_000) * rate.outputPerM;
}

// aggregate — the testable core: given run records (each optionally already
// carrying a transcript_path) and an injected readTranscript(path) -> text
// function, resolves every run's transcript (trusting transcript_path when
// present; falling back to resolveLunaTranscript for the luna cell only) and
// returns per-run usage/cost rows plus the run-ids whose transcript or usage
// could not be resolved. The CLI treats a non-empty `missing` as a hard failure.
export function aggregate(records, { readTranscript, home = homedir() } = {}) {
  const rows = [];
  const missing = [];
  for (const r of records) {
    let transcriptPath = r.transcript_path && r.transcript_path !== '-' ? r.transcript_path : null;
    if (!transcriptPath && r.cell === 'luna' && r.fixture_path) {
      transcriptPath = resolveLunaTranscript(r.fixture_path, home);
    }
    if (!transcriptPath) { missing.push(r.run_id); continue; }
    let text;
    try { text = readTranscript(transcriptPath); } catch { text = undefined; }
    if (text === null || text === undefined) { missing.push(r.run_id); continue; }
    const usage = sumTranscriptUsage(text);
    if (usage.usage_lines === 0) { missing.push(r.run_id); continue; }
    rows.push({
      run_id: r.run_id,
      task: r.task,
      cell: r.cell,
      rep: r.rep,
      model: r.model,
      transcript_path: transcriptPath,
      usage,
      cost_usd: costUsd(r.model, usage),
    });
  }
  return { rows, missing, dispatchCount: records.length, resolvedCount: rows.length };
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
    process.stderr.write('usage: aggregate-tokens.mjs --runs-dir <dir> [--out <file>]\n');
    process.exitCode = 2;
    return;
  }
  const records = listRunManifests(flags['runs-dir']);
  const result = aggregate(records, { readTranscript: (p) => readFileSync(p, 'utf8') });
  if (result.missing.length > 0) {
    process.stderr.write(
      `aggregate-tokens: ${result.missing.length}/${result.dispatchCount} dispatch(es) have NO resolvable ` +
      `transcript (count(transcripts) must equal count(dispatches), spec §6.1): ${result.missing.join(', ')}\n`,
    );
    process.exitCode = 1;
    return;
  }
  const out = JSON.stringify(result.rows, null, 2) + '\n';
  if (flags.out) writeFileSync(flags.out, out);
  else process.stdout.write(out);
}

// Entrypoint guard: compare RESOLVED paths, not a filename suffix (codex CR).
// `endsWith('aggregate-tokens.mjs')` would also fire when this module is
// imported by any script whose own filename happens to end with that string,
// silently running main() as an import side effect.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
