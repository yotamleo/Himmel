// forge/detect.mjs — JS mirror of forge_detect in scripts/lib/forge.sh.
//
// Returns the forge backend for the current repo. Detection precedence:
//   1. env.FORGE (github|bitbucket) verbatim — the override + test seam.
//   2. else `git remote get-url origin`, lowercased, matched against the
//      github.com / bitbucket.org host substrings (https + ssh forms).
//   3. else (no origin / unknown host / git error) → 'github'.
//
// Note the ONE deliberate divergence from the shell seam: forge.sh returns
// non-zero on an undetermined forge, but the plugin DEFAULTS TO github. The
// existing github tests run in the himmel repo (github origin) and inject
// execGh; github must stay the safe fallback so they pass unchanged and so a
// detached/origin-less checkout keeps the legacy gh path.

import { spawnSync } from 'node:child_process';

export function detectForge(cwd = process.cwd(), env = process.env) {
  if (env.FORGE === 'github' || env.FORGE === 'bitbucket') return env.FORGE;

  let origin = '';
  try {
    const r = spawnSync('git', ['remote', 'get-url', 'origin'], {
      cwd,
      encoding: 'utf8',
    });
    if (r.status === 0 && typeof r.stdout === 'string') origin = r.stdout.trim();
  } catch {
    origin = '';
  }

  const lc = origin.toLowerCase();
  if (lc.includes('github.com')) return 'github';
  if (lc.includes('bitbucket.org')) return 'bitbucket';
  return 'github';
}
