// scripts/lanes/tests/gate-allow-hook-survival.test.mjs
// HIMMEL-3469 / HIMMEL-3470 — settings-allow.test.mjs's `ruleMatches` is an
// explicit MODEL of Claude Code's own permission-list matcher (see its header
// comment), not of scripts/hooks/guard-pr-check-literal.sh (HIMMEL-3383/3495),
// which is the ACTUAL structural fence that stops a rider/compound command
// from riding the ledger-append.sh / clear-cr-marker.sh gateAllow `:*`
// wildcard tail (the model itself says as much — it deliberately excludes
// `:*` rules from its rider assertions, since the model "lets a `:*` tail
// absorb anything"). Two prior gate/hook PRs this shift shipped a rule backed
// only by that kind of model and failed adversarial review because the real
// hook chain was never exercised. This file spawns the REAL hook binary
// (read-only subprocess — never edited or copied here) with real PreToolUse
// JSON payloads and asserts its actual exit code/stderr, so the safety
// argument in plugin-profiles.json's `_comment_gateAllow` is checked against
// the hook's current bytes, not a description of them.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createRequire } from 'node:module';

// HIMMEL-1992: never spawn a bare "bash" — on Windows that resolves through
// PATH to the WSL launcher before Git Bash (a 600s hang or a silent
// wrong-shell run). Use this tree's own resolver, same convention as
// scripts/lanes/profile-context-probe.mjs.
const { resolveBash } = createRequire(import.meta.url)('../../hooks/run-hook-with-bash.js');
const BASH_BIN = resolveBash() || 'bash';

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const HOOK = join(REPO_ROOT, 'scripts', 'hooks', 'guard-pr-check-literal.sh');

function runHook(command, { env = {} } = {}) {
  const payload = JSON.stringify({ tool_name: 'Bash', tool_input: { command }, cwd: REPO_ROOT });
  const { status, stderr } = spawnSync(BASH_BIN, [HOOK], {
    input: payload,
    cwd: REPO_ROOT,
    env: { ...process.env, ...env },
    encoding: 'utf8',
  });
  return { status, stderr: stderr ?? '' };
}

// RIDER shapes on the scripts HIMMEL-3470/HIMMEL-3698 re-review. Each must be
// denied by the hook itself — the gateAllow `:*` rule's own text would
// otherwise match every one of these (that is exactly what a wildcard tail
// means).
const RIDER_COMMANDS = [
  'bash scripts/cr/ledger-append.sh amend --head abc123 --id x --set severity=crit --reason y; echo evil',
  'bash scripts/cr/ledger-append.sh finding --branch x $(echo evil)',
  'bash scripts/cr/ledger-append.sh finding --branch x `echo evil`',
  'bash scripts/cr/ledger-append.sh finding --branch x && echo evil',
  'bash scripts/cr/ledger-append.sh finding --branch x || echo evil',
  'bash scripts/cr/clear-cr-marker.sh fix/x | sh',
  'bash scripts/cr/clear-cr-marker.sh fix/x && echo evil',
  'bash scripts/cr/clear-cr-marker.sh fix/x\necho evil',
  // HIMMEL-3698: cr-scores.sh's new gateAllow `:*` grant reuses this same
  // hook-target safety, so it needs the same real-binary proof.
  'bash scripts/cr/cr-scores.sh --by-branch fix/x; echo evil',
  'bash scripts/cr/cr-scores.sh --by-branch fix/x && echo evil',
  'bash scripts/cr/cr-scores.sh --by-branch fix/x | sh',
  'bash scripts/cr/cr-scores.sh --by-branch fix/x $(echo evil)',
];

for (const command of RIDER_COMMANDS) {
  test(`guard-pr-check-literal.sh denies a rider on the gateAllow wildcard tail: ${JSON.stringify(command)}`, () => {
    const { status, stderr } = runHook(command, { env: { HIMMEL_REPO: '' } });
    assert.equal(status, 2, `expected deny (rc=2), got rc=${status}: ${stderr}`);
    assert.match(stderr, /not one simple command/);
  });
}

// Control: a clean, single-simple-command invocation of each script (no
// rider) must never be denied FOR THE RIDER REASON — otherwise the RIDER
// denials above would prove nothing (the hook could just be refusing the
// script names outright, meaning the gateAllow grant is unreachable dead
// weight, the exact defect closed PR #1204 shipped for a different rule
// shape). This does NOT assert a full allow (rc=0): the hook's other
// runbook conditions (worktree root, byte-equal anchor tree, and — CI-only —
// the anchor being checked out on refs/heads/main rather than a detached
// HEAD) are environment-dependent and orthogonal to the property this file
// tests, so asserting rc=0 here would make the suite fail under a detached
// HEAD (e.g. GitHub Actions' checkout) for a reason unrelated to riders.
const CLEAN_COMMANDS = [
  'bash scripts/cr/ledger-append.sh amend --head abc123 --id x --set severity=crit --reason y',
  'bash scripts/cr/clear-cr-marker.sh --dry-run',
  'bash scripts/cr/cr-scores.sh --by-branch fix/x',
];

for (const command of CLEAN_COMMANDS) {
  test(`guard-pr-check-literal.sh does not deny a clean single-simple-command as a rider: ${JSON.stringify(command)}`, () => {
    const { status, stderr } = runHook(command, { env: { HIMMEL_REPO: '' } });
    if (status !== 0) assert.doesNotMatch(stderr, /not one simple command/, `denied as a rider, not just an unmet runbook condition: ${stderr}`);
  });
}
