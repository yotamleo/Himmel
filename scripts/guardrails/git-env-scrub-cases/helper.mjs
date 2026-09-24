// GREEN: routes through the shared gitClean() helper instead of a raw
// execFileSync('git', ...) — never matched by the raw-call regex at all.
import { gitClean } from '../../lanes/git-clean.mjs';

export function status(repoRoot) {
  return gitClean(['-C', repoRoot, 'status'], { encoding: 'utf8' });
}
