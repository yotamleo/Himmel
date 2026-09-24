import { execFileSync } from 'node:child_process';

// RED: exemption marker with no reason — must not exempt.
export function status(repoRoot) {
  return execFileSync('git', ['-C', repoRoot, 'status'], { encoding: 'utf8' }); // git-env-ok:
}
