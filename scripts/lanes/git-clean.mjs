// scripts/lanes/git-clean.mjs — shared env-scrub helper for trust-path git
// calls from JS (HIMMEL-3570). See scripts/lib/git-clean.sh for the shell
// twin and the WHY (PR 1212, PR 1217 — a git subprocess on a trust path
// inherits the caller's GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR/GIT_INDEX_FILE,
// and an attacker-set value for any of the four steers which repo/worktree
// it actually answers about).
//
// Use in place of a raw execFileSync('git', ...) / spawnSync('git', ...) on
// any trust-path script (scripts/handover/**, scripts/lanes/**,
// scripts/hooks/**, scripts/cr/**, scripts/lib/go-gate.sh):
//
//   import { gitClean } from './git-clean.mjs';
//   const out = gitClean(['-C', repoRoot, 'rev-parse', '--git-common-dir'], { encoding: 'utf8' });
//
// check-git-env-scrub.sh (the pre-commit/CI gate) treats a `gitClean(` call
// site as already-scrubbed and does not flag it.
import { execFileSync } from 'node:child_process';

const SCRUB_KEYS = ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE'];

export function gitCleanEnv(env = process.env) {
  const out = { ...env };
  for (const k of SCRUB_KEYS) delete out[k];
  return out;
}

export function gitClean(args, options = {}) {
  return execFileSync('git', args, { ...options, env: gitCleanEnv(options.env) }); // git-env-ok: env built by gitCleanEnv() above
}
