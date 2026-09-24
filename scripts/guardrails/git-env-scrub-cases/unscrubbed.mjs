import { execFileSync } from 'node:child_process';

// RED: no scrub visible in the window, no gitClean(), no exemption.
export function status(repoRoot) {
  return execFileSync('git', ['-C', repoRoot, 'status'], { encoding: 'utf8' });
}
