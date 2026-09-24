import { execFileSync } from 'node:child_process';

// GREEN only under a baseline that lists JS:<this-path>:<hash-of-this-line>
// — otherwise RED, same shape as unscrubbed.mjs.
export function status(repoRoot) {
  return execFileSync('git', ['-C', repoRoot, 'status'], { encoding: 'utf8' });
}
