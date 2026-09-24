import { execFileSync } from 'node:child_process';

// GREEN: same-line exemption marker with a reason.
export function status(repoRoot) {
  return execFileSync('git', ['-C', repoRoot, 'status'], { encoding: 'utf8' }); // git-env-ok: read-only, trusted repoRoot
}
