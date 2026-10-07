// project-mode.mjs — JS twin of scripts/lib/project-mode.sh (HIMMEL-4758,
// HIMMEL-4748 spec section 1). Same precedence, same answers: both are pinned
// to fixtures/project-modes.tsv and fixtures/forge-origins.tsv by
// project-mode.test.mjs and test-project-mode.sh. Each function takes
// { cwd, env } (defaults: process.cwd(), process.env) and throws an Error with
// code 2 where the shell function returns 2.
//
// CLI (for CommonJS callers that cannot import ESM on the Node 18 floor):
//   node project-mode.mjs tracker|forge|pattern|required|phases|env [--for-guard]
// prints the answer on stdout, or the message on stderr and exits 2.
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const PHASES = {
  github: 'LIVE PR-OPEN CI READY GO MERGED WRAPPED',
  bitbucket: 'LIVE PR-OPEN CI READY GO MERGED WRAPPED',
  'local-git': 'LIVE READY GO MERGED WRAPPED',
  none: 'LIVE READY WRAPPED',
};

function refuse(message) {
  const err = new Error(`project-mode: ${message}`);
  err.code = 2;
  return err;
}

function git(args, { cwd, env }) {
  try {
    return execFileSync('git', args, { cwd, env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return '';
  }
}

function opts(o = {}) {
  return { cwd: o.cwd || process.cwd(), env: o.env || process.env };
}

// Same rules as forge.sh _forge_origin_host and project-mode.sh.
export function originHost(url) {
  const u = String(url || '').toLowerCase();
  let authority = '';
  const i = u.indexOf('://');
  if (i !== -1) {
    const scheme = u.slice(0, i);
    if (scheme && !/[^a-z0-9+.-]/.test(scheme)) authority = u.slice(i + 3).split('/')[0];
  }
  if (!authority) {
    const head = u.split('/')[0];
    if (head.includes(':')) authority = u.split(':')[0];
  }
  authority = authority.slice(authority.lastIndexOf('@') + 1).split(':')[0];
  return authority.endsWith('.') ? authority.slice(0, -1) : authority;
}

function detectForge(o, quiet) {
  if (git(['rev-parse', '--is-inside-work-tree'], o) !== 'true') return 'none';
  const origin = git(['remote', 'get-url', 'origin'], o);
  const host = originHost(origin);
  if (host === 'github.com' || host.endsWith('.github.com')) return 'github';
  if (host === 'bitbucket.org' || host.endsWith('.bitbucket.org')) return 'bitbucket';
  if (origin && !quiet) {
    process.stderr.write(`project-mode: origin (${origin}) is neither github.com nor bitbucket.org — forge is local-git (set FORGE or git config himmel.forge to choose)\n`);
  }
  return 'local-git';
}

export function projectModeTracker(o) {
  o = opts(o);
  const key = o.env.JIRA_PROJECT_KEY || '';
  let t = o.env.TRACKER || '';
  let src = 'TRACKER';
  if (!t) {
    t = git(['config', '--get', 'himmel.tracker'], o);
    src = 'git config himmel.tracker';
  }
  if (!t) return key ? 'jira' : 'local';
  if (t === 'jira') {
    if (!key) throw refuse(`${src}=jira but JIRA_PROJECT_KEY is not set — set it, or choose TRACKER=local|none`);
  } else if (t !== 'local' && t !== 'none') {
    throw refuse(`invalid ${src}='${t}' (expected jira|local|none)`);
  }
  return t;
}

export function projectModeForge(o = {}) {
  const forGuard = Boolean(o.forGuard);
  const quiet = Boolean(o.quiet);
  o = opts(o);
  if (forGuard) return detectForge(o, true);
  let f = o.env.FORGE || '';
  let src = 'FORGE';
  if (f) {
    if (!['github', 'bitbucket', 'local-git', 'none'].includes(f)) {
      throw refuse(`invalid FORGE='${f}' (expected github|bitbucket|local-git|none)`);
    }
  } else {
    f = git(['config', '--get', 'himmel.forge'], o);
    src = 'git config himmel.forge';
    if (!f) return detectForge(o, quiet);
    if (!['github', 'bitbucket', 'local-git'].includes(f)) {
      throw refuse(`invalid ${src}='${f}' (expected github|bitbucket|local-git)`);
    }
  }
  if (f === 'local-git') {
    const detected = detectForge(o, true);
    if (detected === 'github' || detected === 'bitbucket') {
      const host = detected === 'github' ? 'github.com' : 'bitbucket.org';
      throw refuse(`${src}=local-git refused — origin is ${host}; local-git is never selected on a hosted origin (I8)`);
    }
  }
  return f;
}

export function projectModeIdPattern(o) {
  o = opts(o);
  if (o.env.TICKET_ID_PATTERN) {
    if (o.env.TICKET_ID_PATTERN.includes('\n')) throw refuse('TICKET_ID_PATTERN is multi-line (expected one ERE; join alternatives with |)');
    return o.env.TICKET_ID_PATTERN;
  }
  const t = projectModeTracker(o);
  if (t === 'jira') return `${o.env.JIRA_PROJECT_KEY.replace(/[\][\\.^$*+?(){}|]/g, '\\$&')}-[0-9]+`;
  if (t === 'none') return '';
  const prefix = git(['config', '--get', 'himmel.trackerPrefix'], o) || 'LOCAL';
  if (!/^[A-Z][A-Z0-9]*$/.test(prefix)) {
    throw refuse('invalid git config himmel.trackerPrefix (expected an uppercase letter, then A-Z/0-9)');
  }
  return `(^|[^0-9A-Za-z_])(#|${prefix}-)[0-9]+([^0-9A-Za-z_]|$)`;
}

export function projectModeIdRequired(o) {
  o = opts(o);
  if (o.env.TICKET_ID_REQUIRED) return o.env.TICKET_ID_REQUIRED;
  return projectModeTracker(o) === 'none' ? '0' : '1';
}

export function projectModePhases(o) {
  return PHASES[projectModeForge(o)];
}

export function projectModeEnv(o) {
  o = opts(o);
  const t = projectModeTracker(o);
  const f = projectModeForge({ ...o, quiet: true });
  const r = projectModeIdRequired(o);
  const p = projectModeIdPattern(o);
  return `TRACKER=${t}\tFORGE=${f}\tTICKET_ID_REQUIRED=${r}\tTICKET_ID_PATTERN=${p}`;
}

const CLI = {
  tracker: projectModeTracker,
  forge: projectModeForge,
  pattern: projectModeIdPattern,
  required: projectModeIdRequired,
  phases: projectModePhases,
  env: projectModeEnv,
};

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const fn = CLI[process.argv[2]];
  if (!fn) {
    process.stderr.write(`usage: node project-mode.mjs ${Object.keys(CLI).join('|')} [--for-guard]\n`);
    process.exit(64);
  }
  try {
    process.stdout.write(`${fn({ forGuard: process.argv[3] === '--for-guard' })}\n`);
  } catch (err) {
    process.stderr.write(`${err.message}\n`);
    process.exit(err.code === 2 ? 2 : 1);
  }
}
