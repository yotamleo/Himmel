// scripts/lanes/resolve.mjs
// HIMMEL-689 — resolve the machine-available delegation lanes from lanes.json.
// Pure resolveLanes (tested) + buildCtx (real machine, untested by design) + CLI.
import { accessSync, constants, existsSync, readFileSync, statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join, delimiter, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { evalProbe } from './probe.mjs';
import { formatBankAnnotation, parseBankStatusOutput } from './bank-status-core.mjs';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT  = join(SCRIPT_DIR, '..', '..');           // scripts/lanes -> repo (or worktree) root
const REGISTRY   = process.env.LANES_REGISTRY || join(SCRIPT_DIR, 'lanes.json');
// HIMMEL-758: the machine-local, gitignored overlay `himmelctl config` writes
// to (via set-lane-override.mjs) — never scripts/lanes/lanes.json itself.
const LOCAL_REGISTRY = join(SCRIPT_DIR, 'lanes.local.json');

const die = (code, msg) => { process.stderr.write(msg + '\n'); process.exit(code); };

// The adopter profile is a NARROWING overlay: a listed lane still has to pass
// its real probe, while an otherwise-available non-Claude lane omitted from the
// allowlist is reported as suppressed-by-profile rather than as absent. When a
// profileAllowlistScope is present, only that wizard-owned subset is constrained;
// registry lanes outside it stay on their real probes. Absence of the allowlist
// preserves the pre-HIMMEL-1428 behaviour for existing installs, while absence
// of the scope preserves the original global-allowlist semantics for old files.
export function resolveLaneInventory(registry, ctx) {
  const allowlist = Array.isArray(registry.profileAllowlist)
    ? new Set(registry.profileAllowlist)
    : null;
  const allowlistScope = Array.isArray(registry.profileAllowlistScope)
    ? new Set(registry.profileAllowlistScope)
    : null;
  return (registry.lanes ?? [])
    .filter((l) => evalProbe(l.probe, ctx))
    .map((lane) => ({
      lane,
      suppressedByProfile: Boolean(allowlist)
        && lane.class !== 'claude-tier'
        && (!allowlistScope || allowlistScope.has(lane.id))
        && !allowlist.has(lane.id),
    }));
}

export function resolveLanes(registry, ctx) {
  return resolveLaneInventory(registry, ctx)
    .filter((row) => !row.suppressedByProfile)
    .map((row) => row.lane);
}

// unknownOverlayKeys(base, local) -> [{ id, keys }] (HIMMEL-1913). Known
// per-lane keys come from the shared registry itself, so adding a field there
// automatically permits the same field in local deltas and overlay-only lanes.
// Pure — no I/O, no process.env reads.
export function unknownOverlayKeys(base, local) {
  const baseLanes = (base && Array.isArray(base.lanes)) ? base.lanes : [];
  const localLanes = (local && Array.isArray(local.lanes)) ? local.lanes : [];
  const known = new Set(['id']);
  for (const lane of baseLanes) {
    if (!lane || typeof lane !== 'object' || Array.isArray(lane)) continue;
    for (const key of Object.keys(lane)) known.add(key);
  }
  const unknown = [];
  for (const patch of localLanes) {
    if (!patch || typeof patch !== 'object' || Array.isArray(patch)) continue;
    const keys = Object.keys(patch).filter((key) => !known.has(key));
    if (keys.length > 0) unknown.push({ id: patch.id, keys });
  }
  return unknown;
}

// mergeLocalOverlay(base, local) -> merged registry object (HIMMEL-758). A
// TRUE per-lane overlay, not a wholesale replace: each entry in
// `local.lanes` is merged onto the base lane sharing its `id` (local fields
// win). The structured dispatch object and its flag maps are deep-merged;
// other established lane fields retain the original shallow merge. Thus
// lanes.local.json only needs to carry the DELTA (e.g. `{ id, probe }` or a
// dispatch flag override), never a full copy of the shared registry. A local
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
    if (existing && existing.dispatch && patch.dispatch) {
      const dispatch = {
        ...existing.dispatch,
        ...patch.dispatch,
        flags: { ...(existing.dispatch.flags ?? {}), ...(patch.dispatch.flags ?? {}) },
        requiredEnvFlags: { ...(existing.dispatch.requiredEnvFlags ?? {}), ...(patch.dispatch.requiredEnvFlags ?? {}) },
      };
      byId.set(patch.id, { ...existing, ...patch, dispatch });
    } else {
      byId.set(patch.id, existing ? { ...existing, ...patch } : patch);
    }
  }
  const baseIds = new Set(baseLanes.map((l) => l.id));
  const merged = baseLanes.map((l) => byId.get(l.id));
  for (const patch of localLanes) {
    if (patch && patch.id && !baseIds.has(patch.id)) merged.push(byId.get(patch.id));
  }
  // Only supported top-level local policy overlays the base; unknown/typoed
  // keys must not shadow shared registry fields. Per-lane entries still use the
  // id-aware merge above.
  const out = { ...base, lanes: merged };
  for (const key of ['profileAllowlist', 'profileAllowlistScope', 'defaultImplLane']) {
    if (local && Object.prototype.hasOwnProperty.call(local, key)) out[key] = local[key];
  }
  return out;
}

// resolveBankTargets(base, local, bankIds) -> { withBank, without } (HIMMEL-1690).
// The bank probe (bank-status.ts) and /lanes must resolve quota-bank lanes
// through the SAME overlay-aware merge the rest of the lane system uses, so a
// lane that exists ONLY in lanes.local.json (an overlay-only quota bank)
// reaches the probe and gets a real status instead of "no status returned".
// Reuses mergeLocalOverlay — there is no second merge here to drift from it.
// Pure (no I/O); bankIds is passed in because BANK_IDS lives in
// scripts/observability/quota-sources.ts, which this module does not import.
export function resolveBankTargets(base, local, bankIds) {
  const merged = local ? mergeLocalOverlay(base, local) : base;
  const ids = Array.isArray(bankIds) ? bankIds : [];
  const withBank = [];
  const without = [];
  for (const lane of (merged && merged.lanes) || []) {
    if (!lane || typeof lane.id !== 'string' || !lane.id) continue;
    const bank = lane.quota && lane.quota.bank;
    if (typeof bank === 'string' && ids.includes(bank)) withBank.push({ lane: lane.id, bank, quota: lane.quota });
    else without.push(lane.id);
  }
  return { withBank, without };
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
  // A regular file that is executable, not merely a path that exists: the shell
  // resolver tests `[ -x ]`, so a directory or a non-executable file named like
  // an interpreter would otherwise pass here and fail there. On Windows Node
  // ignores X_OK, which matches what MSYS `[ -x ]` reports for the same file.
  const isExe = (p) => {
    try { if (!statSync(p).isFile()) return false; accessSync(p, constants.X_OK); return true; }
    catch { return false; }
  };
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
  const pathHas = pathHasFactory(env);
  // installed.hermes must mean "dispatch will find an interpreter", so it probes
  // exactly what invoke.sh consults (resolve-hermes-py.sh: HERMES_PY, then the
  // HERMES_HOME-derived venv) and nothing wider. A `hermes`/`hermes-agent` shim
  // on PATH was accepted here before; that resolver never reads PATH, so a
  // profile-scoped HERMES_HOME selected the default impl lane and then exited 3
  // after the dispatcher had already provisioned a worktree. An unavailable lane
  // reported up front beats a lane that fails mid-dispatch.
  return { env, pathHas, installed: { hermes: hermesInstalled(env) } };
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
  if (base.profileAllowlist !== undefined
      && (!Array.isArray(base.profileAllowlist) || !base.profileAllowlist.every((id) => typeof id === 'string'))) {
    die(2, `lanes: cannot evaluate — registry ${REGISTRY} profileAllowlist must be an array of lane ids`);
  }
  if (base.profileAllowlistScope !== undefined
      && (!Array.isArray(base.profileAllowlistScope) || !base.profileAllowlistScope.every((id) => typeof id === 'string'))) {
    die(2, `lanes: cannot evaluate — registry ${REGISTRY} profileAllowlistScope must be an array of lane ids`);
  }
  if (base.defaultImplLane !== undefined && typeof base.defaultImplLane !== 'string') {
    die(2, `lanes: cannot evaluate — registry ${REGISTRY} defaultImplLane must be a lane id`);
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
  if (local.profileAllowlist !== undefined
      && (!Array.isArray(local.profileAllowlist) || !local.profileAllowlist.every((id) => typeof id === 'string'))) {
    die(2, `lanes: cannot evaluate — ${LOCAL_REGISTRY} profileAllowlist must be an array of lane ids`);
  }
  if (local.profileAllowlistScope !== undefined
      && (!Array.isArray(local.profileAllowlistScope) || !local.profileAllowlistScope.every((id) => typeof id === 'string'))) {
    die(2, `lanes: cannot evaluate — ${LOCAL_REGISTRY} profileAllowlistScope must be an array of lane ids`);
  }
  if (local.defaultImplLane !== undefined && typeof local.defaultImplLane !== 'string') {
    die(2, `lanes: cannot evaluate — ${LOCAL_REGISTRY} defaultImplLane must be a lane id`);
  }
  for (const { id, keys } of unknownOverlayKeys(base, local)) {
    for (const key of keys) {
      if (key === 'drop') {
        process.stderr.write(`lanes.local.json: lane '${id}' sets unknown key 'drop' (it is silently ignored by lane resolution — lanes has no drop, unlike critics.local.json). To force a lane off, use {"probe":{"kind":"never"}} or run: node scripts/lanes/set-lane-override.mjs ${id} never\n`);
      } else {
        process.stderr.write(`lanes.local.json: lane '${id}' sets unknown key '${key}' (it is silently ignored by lane resolution)\n`);
      }
    }
  }
  return mergeLocalOverlay(base, local);
}

// HIMMEL-1029/HIMMEL-1768: context prose is derived only from structured
// context fields, so a stale hand-maintained descriptor cannot contradict them.
export function fmtCtx(n) {
  if (typeof n !== 'number' || !Number.isFinite(n) || n <= 0) return '';
  if (n % 1000000 === 0) return `${n / 1000000}M`;
  if (n % 1000 === 0) return `${n / 1000}k`;
  return String(n);
}

export function formatContextAnnotation(context) {
  const window = fmtCtx(context?.windowTokens);
  if (!window) return '';
  if (context?.overflow === 'compact-continue') return `[ctx: ${window}; compacts+continues past window (cost penalty)]`;
  if (context?.overflow === 'hard-limit') return `[ctx: ${window}; hard limit]`;
  return `[ctx: ${window}; overflow unknown]`;
}

// resolveActiveAccessPath(quota) -> { ok: true, path, index } | { ok: false, reason }
// (HIMMEL-1768 round 3). Resolve the lane's ACTIVE access path from explicit
// selection, never by positional fallback. An ABSENT activeAccessPath selects
// the first path — the registry's documented default shape, not an error. An
// EXPLICIT index that fails to select a path (out of range, fractional,
// non-number) is a registry ERROR: !ok plus a reason, so every consumer
// (guard verdict, /lanes display) reports unknown + a diagnostic instead of
// silently gating on paths[0]. Shared by bank-status.ts and
// formatQuotaAnnotation so the resolution rule cannot drift between them.
export function resolveActiveAccessPath(quota) {
  const paths = Array.isArray(quota?.accessPaths) ? quota.accessPaths : [];
  if (paths.length === 0) return { ok: false, reason: 'no access path declared' };
  const index = quota.activeAccessPath ?? 0;
  if (typeof index !== 'number' || !Number.isInteger(index) || index < 0 || index >= paths.length) {
    return { ok: false, reason: `activeAccessPath ${JSON.stringify(index)} does not select one of ${paths.length} declared access path(s)` };
  }
  const path = paths[index];
  if (!path || typeof path !== 'object') {
    return { ok: false, reason: `access path ${index} is not an object` };
  }
  return { ok: true, path, index };
}

export function formatQuotaAnnotation(quota, status) {
  const paths = Array.isArray(quota?.accessPaths) ? quota.accessPaths : [];
  if (paths.length === 0) return '';
  const resolved = resolveActiveAccessPath(quota);
  if (!resolved.ok) return `[access: unresolved — ${resolved.reason}]`;
  const active = resolved.path;
  const access = active.kind === 'metered-api-key'
    ? `metered API key${active.provider ? ` (${active.provider})` : ''}`
    : 'subscription';
  const windows = Array.isArray(active.windows) ? active.windows : [];
  let binding = windows.length === 0 ? 'metered spend' : 'unknown';
  if (status?.detail?.startsWith('measured ')) {
    const measured = [...status.detail.matchAll(/(\S+) used=([0-9.]+)%/g)]
      .map((m) => ({ window: m[1], usedPct: Number(m[2]) }))
      .filter((reading) => windows.includes(reading.window) && Number.isFinite(reading.usedPct));
    if (measured.length > 0) binding = measured.reduce((a, b) => b.usedPct > a.usedPct ? b : a).window;
  }
  const limits = windows.length > 0 ? windows.join('+') : 'none';
  // Alternatives are every declared path EXCEPT the resolved active one.
  // paths.slice(1) listed the ACTIVE path itself as an "alternative" whenever
  // activeAccessPath !== 0 — the display half of the positional-index
  // assumption HIMMEL-1768 removes.
  const alternatives = paths
    .filter((_, i) => i !== resolved.index)
    .map((path) => path.kind === 'metered-api-key'
      ? `metered API key${path.provider ? ` (${path.provider})` : ''}`
      : `${path.kind} ${(path.windows ?? []).join('+')}`)
    .join(', ');
  return `[access: ${access}; windows: ${limits}; binds: ${binding}${alternatives ? `; alternative: ${alternatives}` : ''}]`;
}

function renderText(lanes, suppressed, bankStatuses = new Map()) {
  const rows = lanes.map((l) => {
    const context = formatContextAnnotation(l.context);
    const status = bankStatuses.get(l.id);
    const quota = formatQuotaAnnotation(l.quota, status);
    const bank = l.quota?.bank ? ` ${formatBankAnnotation(status)}` : '';
    const dormant = l.dormant ? ` [DORMANT: ${l.dormant.reason} — opt in: ${l.dormant.optInEnv}=1]` : '';
    return `- ${l.label} — ${l.bestFor} (${l.effort})` + (context ? ` ${context}` : '') + (quota ? ` ${quota}` : '') + bank + dormant;
  });
  let out = `Available delegation lanes on this machine (${lanes.length}):\n` + rows.join('\n');
  if (suppressed.length > 0) {
    out += `\n\nSuppressed by adopter profile (${suppressed.length}; physically available, not routable):\n` +
      suppressed.map((l) => `- ${l.label} — suppressed-by-profile`).join('\n');
  }
  return out +
    '\n\nNote: codex(paid) reflects CR_PROFILE=paid (opt-in preference, not a funded-bank guarantee).\n' +
    'Note: [access: ...; windows: ...; binds: ...] distinguishes subscription windows from metered API access; unknown means the required source is unreadable.\n' +
    'Note: [ctx: ...] is derived from structured context.windowTokens + context.overflow; absent = unverified/varies.\n';
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

function runBankStatus(repoRoot, env, registry) {
  const statuses = new Map();
  try {
    const out = execFileSync('bun', [join(repoRoot, 'scripts', 'lanes', 'bank-status.ts')], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 10000,
      env,
      windowsHide: true, // HIMMEL-2081: same fix as HIMMEL-2042 (node spawn sites) -- this
      // runs unattended off guard-implementor-dispatch.sh on every lane dispatch and
      // popped a visible bun.exe console without this.
    });
    return parseBankStatusOutput(out);
  } catch (e) {
    const reason = e?.code === 'ETIMEDOUT'
      ? 'bank probe timed out'
      : `bank probe failed${typeof e?.status === 'number' ? ` (rc=${e.status})` : ''}`;
    for (const lane of registry.lanes ?? []) {
      if (lane.quota?.bank) statuses.set(lane.id, { guardState: 'unknown', detail: `unmeasurable reason=${JSON.stringify(reason)}` });
    }
    return statuses;
  }
}

// --- CLI (no --check here; the drift guard is Task 6's check.mjs + bash hook) ---
const mode = process.argv[2];
if (process.argv[1]?.endsWith('resolve.mjs')) {
  const registry = loadRegistry();
  const inventory = resolveLaneInventory(registry, buildCtx(REPO_ROOT, process.env));
  const lanes = inventory.filter((row) => !row.suppressedByProfile).map((row) => {
    const lane = row.lane;
    if (lane.class !== 'impl' || !lane.dispatch) return lane;
    return { ...lane, dispatch: { ...lane.dispatch, preferredDefault: lane.id === registry.defaultImplLane } };
  });
  const suppressed = inventory.filter((row) => row.suppressedByProfile).map((row) => row.lane);
  if (mode === '--json') process.stdout.write(JSON.stringify(lanes, null, 2) + '\n');
  else {
    const bankStatuses = runBankStatus(REPO_ROOT, process.env, registry);
    const { rc, out } = runCodexHealth(REPO_ROOT, process.env);
    process.stdout.write(renderText(lanes, suppressed, bankStatuses) + formatCodexHealth(rc, out));
  }
  process.exit(0);
}
