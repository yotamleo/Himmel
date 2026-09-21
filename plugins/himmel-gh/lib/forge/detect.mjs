// forge/detect.mjs — JS mirror of forge_detect in scripts/lib/forge.sh.
//
// Returns the forge backend for the current repo. Detection precedence:
//   1. env.FORGE (github|bitbucket) verbatim — the override + test seam.
//   2. else `git remote get-url origin`, its HOST (https, ssh://, scp-like; the
//      domain or a subdomain of it, case-insensitive) matched against
//      github.com / bitbucket.org — never a substring of the URL (HIMMEL-3337).
//   3. else (no origin / unknown host / git error) → 'github'.
//
// Note the ONE deliberate divergence from the shell seam: forge.sh returns
// non-zero on an undetermined forge, but the plugin DEFAULTS TO github. The
// existing github tests run in the himmel repo (github origin) and inject
// execGh; github must stay the safe fallback so they pass unchanged and so a
// detached/origin-less checkout keeps the legacy gh path.

import { spawnSync } from 'node:child_process';

// The lowercased HOST of a git remote URL — the same extraction as forge.sh
// _forge_origin_host (scripts/lib/forge.sh) and originHost in
// scripts/himmelctl/lib/status-report.js; scripts/lib/fixtures/forge-origins.tsv
// holds the answers all three must give.
//   scheme://[userinfo@]host[:port]/path   (https, http, ssh, git, file, …)
//   [userinfo@]host:path                   (scp-like; a `:` before the first `/`)
// Anything else (a local path, `host/path`) has no host and yields ''.
function originHost(url) {
  const u = String(url).trim().toLowerCase();
  const scheme = /^([a-z0-9+.-]+):\/\/([^/]*)/.exec(u);
  const authority = scheme ? scheme[2] : (u.split('/')[0].includes(':') ? u.split(':')[0] : '');
  return authority.replace(/^.*@/, '').replace(/:.*$/, '');
}

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

  // HIMMEL-3337: decide on the HOST, never a substring — a path segment
  // (github.com/bitbucket.org/x) or a longer hostname (notbitbucket.org) must not win.
  const host = originHost(origin);
  if (host === 'github.com' || host.endsWith('.github.com')) return 'github';
  if (host === 'bitbucket.org' || host.endsWith('.bitbucket.org')) return 'bitbucket';
  return 'github';
}
