// scripts/lanes/resolve.mjs
// HIMMEL-689 — resolve the machine-available delegation lanes from lanes.json.
// Pure resolveLanes (tested) + buildCtx (real machine, untested by design) + CLI.
import { readFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join, delimiter, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { evalProbe } from './probe.mjs';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT  = join(SCRIPT_DIR, '..', '..');           // scripts/lanes -> repo (or worktree) root
const REGISTRY   = process.env.LANES_REGISTRY || join(SCRIPT_DIR, 'lanes.json');
// HIMMEL-758: the machine-local, gitignored overlay `himmelctl config` writes
// to (via set-lane-override.mjs) — never scripts/lanes/lanes.json itself.
const LOCAL_REGISTRY = join(SCRIPT_DIR, 'lanes.local.json');

const die = (code, msg) => { process.stderr.write(msg + '\n'); process.exit(code); };

export function resolveLanes(registry, ctx) {
  return (registry.lanes ?? []).filter((l) => evalProbe(l.probe, ctx));
}

// mergeLocalOverlay(base, local) -> merged registry object (HIMMEL-758). A
// TRUE per-lane overlay, not a wholesale replace: each entry in
// `local.lanes` is shallow-merged onto the base lane sharing its `id` (local
// fields win), so lanes.local.json only ever needs to carry the DELTA (e.g.
// just `{ id, probe }`), never a full copy of the shared registry. A local
// entry naming an id absent from `base` is appended as a genuinely
// machine-local lane. Base lane order is preserved; local-only entries land
// at the end. Pure — no I/O, no process.env reads.
export function mergeLocalOverlay(base, local) {
  const baseLanes = (base && base.lanes) || [];
  const localLanes = (local && local.lanes) || [];
  const byId = new Map(baseLanes.map((l) => [l.id, l]));
  for (const patch of localLanes) {
    if (!patch || !patch.id) continue;
    const existing = byId.get(patch.id);
    byId.set(patch.id, existing ? { ...existing, ...patch } : patch);
  }
  const baseIds = new Set(baseLanes.map((l) => l.id));
  const merged = baseLanes.map((l) => byId.get(l.id));
  for (const patch of localLanes) {
    if (patch && patch.id && !baseIds.has(patch.id)) merged.push(byId.get(patch.id));
  }
  return { ...base, lanes: merged };
}

// Parse a KEY=VALUE from a .env line (one surrounding quote-pair stripped), matching glm-env.ts semantics.
function parseDotenv(file) {
  const out = {};
  if (!existsSync(file)) return out;
  for (const raw of readFileSync(file, 'utf8').split(/\r?\n/)) {
    const m = raw.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
    if (!m) continue;
    let v = m[2].trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
    out[m[1]] = v;
  }
  return out;
}

// When run from a git WORKTREE, repoRoot's own .env is gitignored/absent — the real
// .env lives in the MAIN checkout. Mirror glm-env.ts:27-57 (git-common-dir → parent).
// Returns undefined for non-git / not-a-worktree.
function mainCheckoutRoot(repoRoot) {
  try {
    const out = execFileSync('git', ['-C', repoRoot, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    if (!out) return undefined;
    const parent = dirname(out);
    return resolve(parent) !== resolve(repoRoot) ? parent : undefined;
  } catch { return undefined; }
}

function pathHasFactory(env) {
  const dirs = (env.PATH || env.Path || '').split(delimiter).filter(Boolean);
  // Windows resolves .cmd/.exe/.bat via PATHEXT; POSIX matches the bare name.
  const exts = process.platform === 'win32'
    ? (env.PATHEXT || '.COM;.EXE;.BAT;.CMD').split(';').map((e) => e.toLowerCase())
    : [''];
  return (cli) => dirs.some((d) => exts.some((e) => existsSync(join(d, cli + e))));
}

// hermes install probe — locate the venv python the SAME way resolve-hermes-py.sh:25-44
// does, but in PURE NODE (existsSync), NOT by spawning `bash resolve-hermes-py.sh`.
// R2 B-R2-1: that script is a SOURCED LIBRARY (only defines a function; "Source this
// file, then call resolve_hermes_py") — running it hits EOF and exits 0 on EVERY
// machine, so a bash-spawn probe is unconditionally true (re-opening R1 B2).
// Pure existsSync also sidesteps the Windows WSL-`bash`-stub trap (R2 I-R2-3).
function hermesInstalled(env) {
  const isExe = (p) => { try { return existsSync(p); } catch { return false; } };
  if (env.HERMES_PY && isExe(env.HERMES_PY)) return true;                     // honor a still-valid HERMES_PY
  const local = env.LOCALAPPDATA || join(env.HOME || env.USERPROFILE || '', 'AppData', 'Local');
  const root  = env.HERMES_HOME || join(local, 'hermes');
  for (const src of [join(root, 'hermes-agent'), root]) {                     // tolerate venv/ at root
    if (isExe(join(src, 'venv', 'Scripts', 'python.exe')) || isExe(join(src, 'venv', 'bin', 'python'))) return true;
  }
  return false;
}

export function buildCtx(repoRoot, procEnv) {
  // .env precedence: main-checkout .env (base) < worktree .env < process env (wins).
  const mainRoot = mainCheckoutRoot(repoRoot);
  const dotenv = { ...(mainRoot ? parseDotenv(join(mainRoot, '.env')) : {}), ...parseDotenv(join(repoRoot, '.env')) };
  const env = { ...dotenv, ...procEnv };
  return { env, pathHas: pathHasFactory(env), installed: { hermes: hermesInstalled(env) } };
}

function loadRegistry() {
  if (!existsSync(REGISTRY)) die(2, `lanes: cannot evaluate — missing registry: ${REGISTRY}`);
  let base;
  try { base = JSON.parse(readFileSync(REGISTRY, 'utf8')); }
  catch (e) { die(2, `lanes: cannot evaluate — registry is not valid JSON: ${e.message}`); }
  // Malformed-but-valid-JSON shapes (e.g. `{ "lanes": {} }`) would otherwise
  // reach the `for...of` / mergeLocalOverlay's `.map` and throw an uncaught
  // TypeError. Reject via the same controlled die(2) path here, covering BOTH
  // the LANES_REGISTRY early-return below AND the overlay-merge path.
  if (!base || typeof base !== 'object' || !Array.isArray(base.lanes)) {
    die(2, `lanes: cannot evaluate — registry ${REGISTRY} must be an object with a 'lanes' array`);
  }
  // LANES_REGISTRY (explicit full-override — tests/CI) replaces wholesale,
  // exactly as before HIMMEL-758: no local overlay applied on top of an
  // explicit override. Only the DEFAULT registry path layers lanes.local.json.
  if (process.env.LANES_REGISTRY || !existsSync(LOCAL_REGISTRY)) return base;
  let local;
  try { local = JSON.parse(readFileSync(LOCAL_REGISTRY, 'utf8')); }
  catch (e) { die(2, `lanes: cannot evaluate — lanes.local.json is not valid JSON: ${e.message}`); }
  if (!local || typeof local !== 'object' || !Array.isArray(local.lanes)) {
    die(2, `lanes: cannot evaluate — ${LOCAL_REGISTRY} must be an object with a 'lanes' array`);
  }
  return mergeLocalOverlay(base, local);
}

// HIMMEL-1029 P1: compact a context-window token count for the /lanes line
// (1000000 -> "1M", 272000 -> "272k"). Absent contextWindow renders nothing.
export function fmtCtx(n) {
  if (typeof n !== 'number' || !Number.isFinite(n) || n <= 0) return '';
  if (n % 1000000 === 0) return `${n / 1000000}M`;
  if (n % 1000 === 0) return `${n / 1000}k`;
  return String(n);
}

function renderText(lanes) {
  const rows = lanes.map((l) => {
    const ctx = fmtCtx(l.contextWindow);
    return `- ${l.label} — ${l.bestFor} (${l.effort})` + (ctx ? ` [ctx: ${ctx}]` : '');
  });
  return `Available delegation lanes on this machine (${lanes.length}):\n` + rows.join('\n') +
    '\n\nNote: codex(paid) reflects CR_PROFILE=paid (opt-in preference, not a funded-bank guarantee).\n' +
    'Note: [ctx: N] = the lane\'s max usable context; absent = unverified/varies. Route work to a lane whose window holds it (codex lanes are 272k, not 1M).\n';
}

// HIMMEL-747 — turn the codex startup-health detector's exit code + WARN lines
// into a /lanes annotation. PURE (unit-tested): only rc=1 (findings) annotates;
// rc=0 (healthy), rc=2 (no codex), or a spawn failure (rc<0) render nothing, so
// a degraded codex delegation lane stops looking healthy without ever breaking
// the lane listing.
export function formatCodexHealth(rc, stdout) {
  if (rc !== 1) return '';
  const lines = String(stdout).split(/\r?\n/).filter((l) => l.startsWith('WARN '));
  if (lines.length === 0) return '';
  return `\ncodex lane health: DEGRADED — ${lines.length} startup finding(s) (a routed codex lane looks healthy but is not; run scripts/codex/startup-health.sh):\n` +
    lines.map((l) => '  - ' + l.replace(/^WARN /, '')).join('\n') + '\n';
}

// Impure companion (real machine, untested by design, mirrors buildCtx). Spawns
// the bash detector non-fatally: findings make execFileSync throw with e.status=1
// and the WARN lines on e.stdout; a missing bash / missing script returns rc<0
// so formatCodexHealth renders nothing. Git-Bash is resolved explicitly on
// Windows (a bare `bash` is the WSL stub) — matching scripts/hooks tests.
function runCodexHealth(repoRoot, env) {
  const script = join(repoRoot, 'scripts', 'codex', 'startup-health.sh');
  if (!existsSync(script)) return { rc: -1, out: '' };
  let bash = '/bin/bash';
  if (process.platform === 'win32') {
    const cands = [env.GUARDRAIL_BASH, 'C:/Program Files/Git/bin/bash.exe', 'C:/Program Files/Git/usr/bin/bash.exe'].filter(Boolean);
    bash = cands.find((b) => existsSync(b)) || 'bash';
  }
  try {
    const out = execFileSync(bash, [script], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 20000 });
    return { rc: 0, out };
  } catch (e) {
    if (e && typeof e.status === 'number') return { rc: e.status, out: e.stdout ? String(e.stdout) : '' };
    return { rc: -1, out: '' };
  }
}

// --- CLI (no --check here; the drift guard is Task 6's check.mjs + bash hook) ---
const mode = process.argv[2];
if (process.argv[1]?.endsWith('resolve.mjs')) {
  const registry = loadRegistry();
  const lanes = resolveLanes(registry, buildCtx(REPO_ROOT, process.env));
  if (mode === '--json') process.stdout.write(JSON.stringify(lanes, null, 2) + '\n');
  else {
    const { rc, out } = runCodexHealth(REPO_ROOT, process.env);
    process.stdout.write(renderText(lanes) + formatCodexHealth(rc, out));
  }
  process.exit(0);
}
