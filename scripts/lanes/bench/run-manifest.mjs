#!/usr/bin/env node
// scripts/lanes/bench/run-manifest.mjs — HIMMEL-1723 P2.4
// The run manifest schema (spec §2.7) plus a writer/reader every other bench
// component uses, so the shape lives in exactly one place. One
// runs/<run-id>.json per dispatch: {run_id, task, cell, rep, model, effort,
// prompt_sha256, fixture_path, transcript_path, started_at, ended_at,
// duration_ms, exit_code, verdict, out_of_scope_paths[], tokens, notes,
// probe}. `"probe": true` marks a pipeline smoke-test dispatch (proving the
// harness works, not a bench measurement) — report.mjs recognizes it and
// excludes the run from the canonical-set check and every stats table,
// surfacing it as an excluded probe instead.
//
// Also owns the prompt-hash equality check (spec §2.3's fairness guarantee):
// per task, EVERY record — both cells, all reps — must carry the same
// prompt_sha256.
// report.mjs (P2.7) is what ENFORCES this at report-generation time (fails
// loudly on a mismatch); checkPromptHashParity here is the pure, testable
// core the enforcement calls.
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const RUN_MANIFEST_FIELDS = [
  'run_id', 'task', 'cell', 'rep', 'model', 'effort', 'prompt_sha256',
  'fixture_path', 'transcript_path', 'started_at', 'ended_at', 'duration_ms',
  'exit_code', 'verdict', 'out_of_scope_paths', 'tokens', 'notes', 'probe',
];

export function promptSha256(promptText) {
  return createHash('sha256').update(promptText, 'utf8').digest('hex');
}

// buildRunRecord — fills every schema field, defaulting the ones a caller may
// not yet know (verdict / out_of_scope_paths / tokens / notes are typically
// filled in later, by verify.sh and aggregate-tokens.mjs respectively) rather
// than leaving them absent, so every runs/<id>.json round-trips through the
// same shape regardless of write order.
export function buildRunRecord(fields) {
  const required = ['run_id', 'task', 'cell', 'rep', 'model', 'effort', 'prompt_sha256', 'fixture_path'];
  for (const key of required) {
    if (fields[key] === undefined || fields[key] === null || fields[key] === '') {
      throw new Error(`buildRunRecord: missing required field "${key}"`);
    }
  }
  return {
    run_id: fields.run_id,
    task: fields.task,
    cell: fields.cell,
    rep: Number(fields.rep),
    model: fields.model,
    effort: fields.effort,
    prompt_sha256: fields.prompt_sha256,
    fixture_path: fields.fixture_path,
    transcript_path: fields.transcript_path ?? null,
    started_at: fields.started_at ?? null,
    ended_at: fields.ended_at ?? null,
    duration_ms: fields.duration_ms !== undefined && fields.duration_ms !== null ? Number(fields.duration_ms) : null,
    exit_code: fields.exit_code !== undefined && fields.exit_code !== null ? Number(fields.exit_code) : null,
    verdict: fields.verdict ?? null,
    out_of_scope_paths: fields.out_of_scope_paths ?? [],
    tokens: fields.tokens ?? null,
    notes: fields.notes ?? null,
    probe: fields.probe === true,
  };
}

export function runManifestPath(runsDir, runId) {
  return join(runsDir, `${runId}.json`);
}

export function writeRunManifest(runsDir, record) {
  mkdirSync(runsDir, { recursive: true });
  const path = runManifestPath(runsDir, record.run_id);
  writeFileSync(path, JSON.stringify(record, null, 2) + '\n');
  return path;
}

export function readRunManifest(runsDir, runId) {
  const path = runManifestPath(runsDir, runId);
  if (!existsSync(path)) return null;
  return JSON.parse(readFileSync(path, 'utf8'));
}

export function listRunManifests(runsDir) {
  if (!existsSync(runsDir)) return [];
  return readdirSync(runsDir)
    .filter((f) => f.endsWith('.json'))
    .map((f) => JSON.parse(readFileSync(join(runsDir, f), 'utf8')));
}

// checkPromptHashParity — the runtime enforcement of spec §2.3: every dispatch
// of a given task, in EITHER cell and at ANY rep, must have been given the
// byte-identical prompt.md. So the check is simply: all records for one task
// carry ONE distinct prompt_sha256.
//
// It used to index `byTask[task][cell] = hash`, keeping only the LAST record
// per cell (codex CR). With 2 reps per cell that silently dropped half the
// evidence: a prompt edited mid-run would be invisible whenever the surviving
// rep happened to agree across cells, and a rep-to-rep divergence WITHIN one
// cell was never compared at all. Both are exactly the corruption this guard
// exists to catch, so it now compares every record.
//
// Pure: takes an array of manifest-shaped records, never touches disk, so a
// test can inject a deliberate mismatch without writing files.
export function checkPromptHashParity(records) {
  const byTask = new Map();
  for (const r of records) {
    if (!r || !r.task || !r.cell || !r.prompt_sha256) continue;
    if (!byTask.has(r.task)) byTask.set(r.task, []);
    byTask.get(r.task).push({ cell: r.cell, rep: r.rep, hash: r.prompt_sha256, run_id: r.run_id });
  }
  const mismatches = [];
  for (const [task, entries] of byTask) {
    const distinct = [...new Set(entries.map((e) => e.hash))];
    if (distinct.length > 1) {
      mismatches.push({ task, distinct, entries });
    }
  }
  return { ok: mismatches.length === 0, mismatches };
}

function parseFlags(args) {
  const out = {};
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = args[i + 1];
      if (next === undefined || next.startsWith('--')) out[key] = true;
      else { out[key] = next; i++; }
    }
  }
  return out;
}

function main() {
  const args = process.argv.slice(2);
  const cmd = args[0];

  if (cmd === 'write') {
    const flags = parseFlags(args.slice(1));
    if (!flags['runs-dir']) { process.stderr.write('run-manifest write: --runs-dir is required\n'); process.exitCode = 2; return; }
    let promptSha = flags['prompt-sha256'];
    if (!promptSha && flags['prompt-file']) {
      promptSha = promptSha256(readFileSync(flags['prompt-file'], 'utf8'));
    }
    let record;
    try {
      record = buildRunRecord({
        run_id: flags['run-id'],
        task: flags.task,
        cell: flags.cell,
        rep: flags.rep,
        model: flags.model,
        effort: flags.effort,
        prompt_sha256: promptSha,
        fixture_path: flags['fixture-path'],
        transcript_path: flags['transcript-path'],
        started_at: flags['started-at'],
        ended_at: flags['ended-at'],
        duration_ms: flags['duration-ms'],
        exit_code: flags['exit-code'],
        // An empty string means "no --verdict was meaningfully supplied" —
        // bash callers (run-batch.sh) pass `--verdict "$verdict"`
        // UNCONDITIONALLY (verdict defaults to "") to avoid the bash-3.2
        // "${array[@]}" -on-an-empty-array-under-set -u pitfall that an
        // optional-flag array would otherwise hit.
        verdict: flags.verdict || undefined,
        notes: flags.notes,
      });
    } catch (e) {
      process.stderr.write(`run-manifest write: ${e.message}\n`);
      process.exitCode = 2;
      return;
    }
    const path = writeRunManifest(flags['runs-dir'], record);
    process.stdout.write(`${path}\n`);
    return;
  }

  if (cmd === 'check-parity') {
    const flags = parseFlags(args.slice(1));
    if (!flags['runs-dir']) { process.stderr.write('run-manifest check-parity: --runs-dir is required\n'); process.exitCode = 2; return; }
    const records = listRunManifests(flags['runs-dir']);
    const result = checkPromptHashParity(records);
    if (!result.ok) {
      for (const m of result.mismatches) {
        // Name every dissenting dispatch, not just a haiku/luna pair — the
        // divergence can be rep-to-rep within one cell (codex CR).
        const who = m.entries.map((e) => `${e.run_id || `${e.cell}-rep${e.rep}`}=${e.hash}`).join(' ');
        process.stderr.write(`check-parity: MISMATCH task=${m.task} distinct=${m.distinct.length} ${who}\n`);
      }
      process.exitCode = 1;
      return;
    }
    process.stdout.write('check-parity: OK\n');
    return;
  }

  process.stderr.write('usage: run-manifest.mjs write --runs-dir <dir> --run-id <id> --task <t> --cell <c> --rep <n> --model <m> --effort <e> (--prompt-sha256 <hex> | --prompt-file <path>) --fixture-path <dir> [...] | check-parity --runs-dir <dir>\n');
  process.exitCode = 2;
}

// Resolved-path comparison, not a filename suffix (codex CR) — the last of the
// four bench modules carrying this guard.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
