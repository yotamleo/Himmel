#!/usr/bin/env node
// guardrail-skip-in-himmel.js  (HIMMEL-709)
//
// Runtime-guard wrapper for the THREE generic himmel guardrails that the
// user-level ~/.claude/settings.json declares to protect NON-himmel repos
// (auto-approve-safe-bash, block-edit-on-main, block-read-secrets). A repo that
// ALSO declares the same guardrail at the project level (himmel does, via
// $CLAUDE_PROJECT_DIR) would otherwise fire it TWICE per matching tool call — a
// doubled MSYS2 bash-spawn (bash -c 'exit 0' ~= 1.7-3.3s on Windows). This
// wrapper removes the duplicate WORK where the project layer already covers the
// guardrail, while keeping it live everywhere else.
//
//   PROJECT ALREADY DECLARES IT  -> exit 0 immediately (cost: one cheap node
//                                   spawn instead of a second bash spawn).
//   ELSEWHERE                    -> run the real bash guardrail, forwarding
//                                   stdin and propagating stdout/stderr + code.
//
// "Project already declares it" is decided by READING the tool call's own
// project settings (self-describing) — so it is correct in the himmel repo root
// AND in any git worktree (.claude/worktrees/<b> or elsewhere), which is where
// parallel himmel work actually runs. A stale exact-root check would miss
// worktrees and re-introduce the double-fire in exactly the parallel case.
//
// Fail-closed: if the bash guardrail cannot be spawned, exit 2 (block). Two of
// the three wrapped hooks are security hooks that MUST fail closed; this path is
// reached ONLY when the project layer does not already cover the guardrail.
//
// Usage (from a user-level hook `command`):
//   <node> guardrail-skip-in-himmel.js <abs-path-to-guardrail.sh>
//   env GUARDRAIL_BASH=<abs-bash> selects the bash used for the real guardrail
//   (the installer bakes the resolved git-bash; bare `bash` is a last resort so
//   a WSL System32 stub on PATH cannot fail the guardrail closed machine-wide).
'use strict';

const fs = require('fs');
const path = require('path');

const norm = (p) =>
  (p || '').replace(/\\/g, '/').replace(/\/+$/, '');

const script = process.argv[2];
if (!script) {
  // Misconfiguration: no guardrail to run. Fail closed.
  process.stderr.write('guardrail-skip-in-himmel: missing script path arg\n');
  process.exit(2);
}

// The guardrail this invocation wraps, e.g. "block-read-secrets.sh".
const guardrailName = path.basename(script);

const projectDir = norm(process.env.CLAUDE_PROJECT_DIR);

// Self-describing skip: if the tool call's OWN project declares this guardrail,
// the project layer already runs it — skip the duplicate. Correct in the himmel
// root and in any worktree, since a worktree checks out the same tracked
// .claude/settings.json.
function projectDeclaresGuardrail() {
  if (!projectDir) return false;
  const settings = path.join(projectDir.replace(/\//g, path.sep), '.claude', 'settings.json');
  let text;
  try {
    text = fs.readFileSync(settings, 'utf8');
  } catch (_e) {
    return false; // no project settings -> project layer does not cover it.
  }
  return text.includes(guardrailName);
}

// Skip ONLY when the project provably declares this guardrail. FAIL CLOSED: if
// the project settings are missing or unreadable we do NOT assume coverage by
// location — a root-prefix "we're inside himmel" guess would skip a security
// guardrail whenever the project layer isn't actually present (fail open). The
// cost of not skipping is at worst one extra bash spawn (a double-fire), which
// is strictly safer than silently dropping block-read-secrets / block-edit-on-main.
if (projectDeclaresGuardrail()) {
  process.exit(0);
}

// Not covered by a project layer: run the real guardrail. Forward the hook
// payload on stdin. Use the installer-resolved bash; fall back to bare `bash`.
const { execFileSync } = require('child_process');
const bash = process.env.GUARDRAIL_BASH || 'bash';

let input = '';
try {
  input = fs.readFileSync(0);
} catch (_e) {
  input = '';
}

try {
  execFileSync(bash, [script], { input, stdio: ['pipe', 'inherit', 'inherit'] });
  process.exit(0);
} catch (e) {
  // Non-zero exit from the guardrail (e.g. a real block=2) -> propagate it.
  // Spawn failure (no numeric status) -> fail closed with 2.
  process.exit(typeof e.status === 'number' ? e.status : 2);
}
