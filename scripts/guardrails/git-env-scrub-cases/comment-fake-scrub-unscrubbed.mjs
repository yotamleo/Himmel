import { execFileSync } from 'node:child_process';

// RED: the four scrub-key names appear only in a COMMENT, never in real
// code — the window check used to do a raw substring match, so a comment
// merely mentioning the names satisfied it (HIMMEL-3570 CR fixup).
export function status(repoRoot) {
  return execFileSync('git', ['-C', repoRoot, 'status'], { encoding: 'utf8' });
  // GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE are NOT actually scrubbed
}
