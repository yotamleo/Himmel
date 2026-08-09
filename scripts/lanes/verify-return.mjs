// scripts/lanes/verify-return.mjs
// Phase 1a (HIMMEL-1621, under the HIMMEL-654 dispatch plan) — did completed
// lane work actually come back? A STANDALONE verifier, deliberately not a
// wrapper edit on spawn-glm.ts or await-glm-worker.sh (Wave-1 property, locked
// by Phase 0.1). Read-only git/gh; four checks, first failure wins; one line
// out; a flow-runs ledger row; NEVER a Jira transition.
//
//   node scripts/lanes/verify-return.mjs <branch> [--ticket PROJECT-N] [--no-ledger]
//
// Checks (first failure wins):
//   1. no-upstream      git for-each-ref refs/heads/<b> --format=%(upstream:short)
//                       empty -> the orphan class (branches nothing can merge).
//   2. empty-diff       git rev-list --count origin/main..<b> == 0 -> the ~30%
//                       zero-output silent-death class.
//   3. no-pr            gh pr list --head <b> --json number empty -> work that
//                       exists but the single writer cannot see to merge.
//   4. no-test-receipt  head commit lacks a `Platforms tested:` / `Tests:`
//                       trailer -> "looks right" is not an acceptance test.
//
// Output contract: exactly one stdout line —
//   PASS <ticket> <branch>
//   FAILED <ticket> <branch> <first-failed-check>
// Exit 0 = PASS, 1 = FAILED, 2 = cannot evaluate (git/gh errored — a gh
// network failure must NOT read as "no PR"; fail closed, never a verdict).
// HIMMEL-1641: a no-upstream FAILED whose branch has local commits ahead of
// origin/main gets an EXTRA stderr hint line (never stdout — the one-line
// contract above is load-bearing) naming the GLM lane's push-block as a
// likely cause — see the "Parent-finish protocol" in docs/glm-offload.md.
// Contract-failing dispatches are counted, never silently absorbed: every
// evaluated run appends one end-row to the flow-runs ledger (best-effort — a
// ledger write failure warns on stderr but never flips the verdict).
import { execFileSync } from 'node:child_process';
import { appendFileSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const CHECKS = [
  {
    slug: 'no-upstream',
    run: (b, exec) => exec('git', ['for-each-ref', `refs/heads/${b}`, '--format=%(upstream:short)']).trim() !== '',
  },
  {
    slug: 'empty-diff',
    run: (b, exec) => {
      const n = parseInt(exec('git', ['rev-list', '--count', `origin/main..${b}`]).trim(), 10);
      if (Number.isNaN(n)) throw new Error(`git rev-list produced a non-count for ${b}`);
      return n > 0;
    },
  },
  {
    slug: 'no-pr',
    run: (b, exec) => {
      const out = exec('gh', ['pr', 'list', '--head', b, '--json', 'number']).trim();
      const parsed = JSON.parse(out || '[]');
      if (!Array.isArray(parsed)) throw new Error(`gh pr list returned non-array for ${b}`);
      return parsed.length > 0;
    },
  },
  {
    slug: 'no-test-receipt',
    // %B + line-anchored grep, NOT %(trailers:only): the house key
    // "Platforms tested:" has a space, which git's trailer parser cannot
    // represent, and the repo's own gate (check-platforms-tested.sh) greps
    // the full message — matching its semantics keeps this verifier from
    // rejecting commits the gate accepts.
    run: (b, exec) => /^(Platforms tested|Tests):/m.test(exec('git', ['log', '-1', '--format=%B', b])),
  },
];

// Ticket derivation: an explicit --ticket wins; else the first PROJECT-N token
// in the branch name (himmel-1234 -> HIMMEL-1234); else "-" so the one-line
// output keeps its field count for downstream parsers. The explicit value is
// whitespace-collapsed so a stray newline cannot break the one-line contract.
export function deriveTicket(branch, explicit) {
  if (explicit) return explicit.replace(/\s+/g, ' ').trim();
  const m = /([a-z]+-\d+)/i.exec(branch || '');
  return m ? m[1].toUpperCase() : '-';
}

// HIMMEL-1641: the no-upstream failure has two very different causes — a
// branch that plain doesn't exist, and a branch that exists WITH commits but
// was never pushed. The GLM lane's structural push-block
// (block-glm-external-writes.sh) makes the second shape common and
// non-obvious: a worker cannot push by design, so "no upstream" here often
// just means the parent hasn't finished the push yet, not that the work is
// missing. Best-effort: any exec failure (branch genuinely absent, no
// commits ahead, a git error) yields no hint, never a thrown error — this
// must never change the verdict, only optionally annotate it.
function computeNoUpstreamHint(branch, exec) {
  try {
    exec('git', ['rev-parse', '--verify', '--quiet', `refs/heads/${branch}`]);
  } catch {
    return undefined; // branch doesn't exist locally — the plain no-upstream case
  }
  try {
    const n = parseInt(exec('git', ['rev-list', '--count', `origin/main..${branch}`]).trim(), 10);
    if (!Number.isFinite(n) || n <= 0) return undefined; // nothing to push either
  } catch {
    return undefined;
  }
  return 'branch has local commits but no upstream — GLM lane push-block? the parent must push before verifying (HIMMEL-1641)';
}

// Pure core. `exec(cmd, args)` returns stdout or throws — injected by tests.
// Returns { verdict: 'PASS'|'FAILED', failedCheck: slug|null, line, hint? }.
// `hint` is set ONLY for a no-upstream failure whose branch has local
// commits ahead of origin/main (HIMMEL-1641) — the caller prints it to
// STDERR, never folding it into the one-line stdout contract.
// Throws on an exec error: the caller maps that to exit 2 (cannot evaluate),
// which is a DIFFERENT outcome from a FAILED verdict.
export function verifyReturn(branch, { exec, ticket } = {}) {
  const t = deriveTicket(branch, ticket);
  for (const check of CHECKS) {
    if (!check.run(branch, exec)) {
      const result = { verdict: 'FAILED', failedCheck: check.slug, line: `FAILED ${t} ${branch} ${check.slug}` };
      if (check.slug === 'no-upstream') {
        const hint = computeNoUpstreamHint(branch, exec);
        if (hint) result.hint = hint;
      }
      return result;
    }
  }
  return { verdict: 'PASS', failedCheck: null, line: `PASS ${t} ${branch}` };
}

// Ledger row — matches scripts/lib/flow-run-ledger.sh's end-row grammar
// (v:1, ev:end; run_id at MINUTES grain + pid disambiguator, HIMMEL-921).
const jsonStr = (s) => JSON.stringify(String(s));
export function ledgerRow(result, { now = new Date(), pid = process.pid } = {}) {
  const iso = now.toISOString().replace(/\.\d{3}Z$/, 'Z');
  const compact = iso.slice(0, 16).replace(/[-:]/g, '');
  const exitCode = result.verdict === 'PASS' ? 0 : 1;
  const outcome = exitCode === 0 ? 'complete' : 'error';
  return `{"v":1,"ev":"end","flow":"verify-return","run_id":${jsonStr(`verify-return-${compact}-${pid}`)},` +
    `"ended_at":${jsonStr(iso)},"exit_code":${exitCode},"outcome":${jsonStr(outcome)},` +
    `"items_processed":null,"note":${jsonStr(result.line)}}`;
}

// Same resolution as scripts/lib/flow-run-ledger-path.sh: explicit override,
// else the single-file default under $HOME.
export function ledgerPath(env = process.env) {
  if (env.HIMMEL_FLOW_RUNS_LEDGER) return env.HIMMEL_FLOW_RUNS_LEDGER;
  return join(env.HOME || env.USERPROFILE || '.', '.himmel', 'flow-runs.jsonl');
}

function appendLedger(result) {
  try {
    const path = ledgerPath();
    mkdirSync(dirname(path), { recursive: true });
    appendFileSync(path, ledgerRow(result) + '\n');
  } catch (e) {
    process.stderr.write(`verify-return: ledger append failed (verdict unaffected): ${e.message}\n`);
  }
}

// process.exitCode + return, never process.exit(): exit() can truncate a
// pending stdout/stderr write — including the one verdict line this tool
// exists to emit (CR round, PR #1608).
function main() {
  const args = process.argv.slice(2);
  let branch = '', ticket = '', ledger = true;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--ticket') {
      const v = args[++i];
      if (!v || !/^[A-Za-z]+-\d+$/.test(v)) {
        process.stderr.write('verify-return: --ticket requires a PROJECT-N value\n');
        process.exitCode = 2; return;
      }
      ticket = v;
    }
    else if (a === '--no-ledger') ledger = false;
    else if (a === '-h' || a === '--help') {
      process.stdout.write('usage: node scripts/lanes/verify-return.mjs <branch> [--ticket PROJECT-N] [--no-ledger]\n');
      return;
    } else if (!branch) branch = a;
    else { process.stderr.write(`verify-return: unexpected argument: ${a}\n`); process.exitCode = 2; return; }
  }
  if (!branch) { process.stderr.write('verify-return: a branch name is required\n'); process.exitCode = 2; return; }

  const exec = (cmd, cmdArgs) =>
    execFileSync(cmd, cmdArgs, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });

  let result;
  try {
    result = verifyReturn(branch, { exec, ticket });
  } catch (e) {
    // git/gh errored — cannot evaluate. Never a verdict, never a ledger row
    // (an unevaluable run is not a counted dispatch outcome).
    process.stderr.write(`verify-return: cannot evaluate ${branch}: ${e.message}\n`);
    process.exitCode = 2; return;
  }
  if (ledger) appendLedger(result);
  process.stdout.write(result.line + '\n');
  // HIMMEL-1641: the hint is STDERR-only — the one-line stdout contract above
  // is load-bearing for callers that parse it.
  if (result.hint) process.stderr.write(`verify-return: ${result.hint}\n`);
  process.exitCode = result.verdict === 'PASS' ? 0 : 1;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
