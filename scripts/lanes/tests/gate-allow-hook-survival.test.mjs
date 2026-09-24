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
import { spawnSync, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const HOOK = join(REPO_ROOT, 'scripts', 'hooks', 'guard-pr-check-literal.sh');

function runHook(command, { env = {} } = {}) {
  const payload = JSON.stringify({ tool_name: 'Bash', tool_input: { command }, cwd: REPO_ROOT });
  const { status, stderr } = spawnSync('bash', [HOOK], {
    input: payload,
    cwd: REPO_ROOT,
    env: { ...process.env, ...env },
    encoding: 'utf8',
  });
  return { status, stderr: stderr ?? '' };
}

// RIDER shapes on the two scripts HIMMEL-3470 re-reviews. Each must be denied
// by the hook itself — the gateAllow `:*` rule's own text would otherwise
// match every one of these (that is exactly what a wildcard tail means).
const RIDER_COMMANDS = [
  'bash scripts/cr/ledger-append.sh amend --head abc123 --id x --set severity=crit --reason y; echo evil',
  'bash scripts/cr/ledger-append.sh finding --branch x $(echo evil)',
  'bash scripts/cr/ledger-append.sh finding --branch x `echo evil`',
  'bash scripts/cr/ledger-append.sh finding --branch x && echo evil',
  'bash scripts/cr/ledger-append.sh finding --branch x || echo evil',
  'bash scripts/cr/clear-cr-marker.sh fix/x | sh',
  'bash scripts/cr/clear-cr-marker.sh fix/x && echo evil',
  'bash scripts/cr/clear-cr-marker.sh fix/x\necho evil',
];

for (const command of RIDER_COMMANDS) {
  test(`guard-pr-check-literal.sh denies a rider on the gateAllow wildcard tail: ${JSON.stringify(command)}`, () => {
    const { status, stderr } = runHook(command, { env: { HIMMEL_REPO: '' } });
    assert.equal(status, 2, `expected deny (rc=2), got rc=${status}: ${stderr}`);
    assert.match(stderr, /not one simple command/);
  });
}

// Control: a clean, single-simple-command invocation of each script (no
// rider) must NOT be denied — otherwise the RIDER denials above would prove
// nothing (the hook could just be refusing the script names outright,
// meaning the gateAllow grant is unreachable dead weight, the exact defect
// closed PR #1204 shipped for a different rule shape). HIMMEL_REPO is
// resolved from git itself (never hardcoded), so this holds whether the
// suite runs from the primary checkout or a worktree of it.
const GIT_COMMON_DIR = execFileSync('git', ['-C', REPO_ROOT, 'rev-parse', '--git-common-dir'], { encoding: 'utf8' }).trim();
const ANCHOR_ROOT = resolve(REPO_ROOT, GIT_COMMON_DIR, '..');

const CLEAN_COMMANDS = [
  'bash scripts/cr/ledger-append.sh amend --head abc123 --id x --set severity=crit --reason y',
  'bash scripts/cr/clear-cr-marker.sh --dry-run',
];

for (const command of CLEAN_COMMANDS) {
  test(`guard-pr-check-literal.sh does not deny a clean single-simple-command: ${JSON.stringify(command)}`, () => {
    const { status, stderr } = runHook(command, { env: { HIMMEL_REPO: ANCHOR_ROOT } });
    assert.equal(status, 0, `expected allow (rc=0), got rc=${status}: ${stderr}`);
  });
}
