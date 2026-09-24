import { execFileSync } from 'node:child_process';

// GREEN: the four scrub keys are visible in the same-statement window
// (the matched line plus the next few) as REAL code, not just a comment
// mentioning them — a comment alone must never satisfy this check.
export function status(repoRoot, fullEnv) {
  return execFileSync('git', ['-C', repoRoot, 'status'], {
    encoding: 'utf8',
    env: (() => {
      const { GIT_DIR, GIT_WORK_TREE, GIT_COMMON_DIR, GIT_INDEX_FILE, ...rest } = fullEnv;
      return rest;
    })(),
  });
}
