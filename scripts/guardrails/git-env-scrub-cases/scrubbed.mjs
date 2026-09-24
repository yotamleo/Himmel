import { execFileSync } from 'node:child_process';

// GREEN: the four scrub keys are visible in the same-statement window
// (the matched line plus the next few).
export function status(repoRoot, env) {
  return execFileSync('git', ['-C', repoRoot, 'status'], { encoding: 'utf8', env });
  // env was built by deleting GIT_DIR, GIT_WORK_TREE, GIT_COMMON_DIR, GIT_INDEX_FILE
}
