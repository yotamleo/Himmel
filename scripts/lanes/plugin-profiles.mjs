// scripts/lanes/plugin-profiles.mjs
// HIMMEL-1040 — resolve a named plugin profile into an enabledPlugins settings
// object, injected per-dispatch via `claude --settings` (lever-b) so lane
// workers run lean while the operator's own ~/.claude stays full. Zero-dep ESM,
// mirroring resolve.mjs — the CI lanes-suite runs node --test over this dir.
// Consumed by the Bun spawn scripts (spawn-glm.ts / spawn-claudex.ts import
// resolveProfileByName) and by a small CLI (measurement / launcher use).
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REGISTRY = process.env.PLUGIN_PROFILES_REGISTRY || join(SCRIPT_DIR, 'plugin-profiles.json');

// plugin@marketplace id shape: `name@marketplace`, each side restricted to
// [A-Za-z0-9._-]. The character class is deliberately TIGHT (not just "no @/space")
// so a `--add-plugins` overlay id can never carry shell metacharacters (`;`, `$`,
// backticks, …) — the resolver's overlay-validation is the single gate before an
// id is emitted unquoted into the spawn-glm cap-respawn command line. Every real
// plugin id (see catalog) matches this.
const ID_RE = /^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$/;

export function loadRegistry(path = REGISTRY) {
  return JSON.parse(readFileSync(path, 'utf8'));
}

// Split a `--add-plugins a@m,b@m` CSV into trimmed, non-empty ids. Pure so the
// spawn scripts and the CLI parse identically.
export function parseAddPlugins(csv) {
  if (!csv) return [];
  return csv.split(',').map((s) => s.trim()).filter(Boolean);
}

// The caller's LIVE plugin universe: every id ANY applicable settings layer has an
// opinion on (enabledPlugins keys), unioned. Exactly the ids that could leak into a
// lane — a plugin enabled in any layer but absent from the static catalog would
// otherwise inherit `true` in the worker. Fed to resolveProfile as opts.installed
// so the deny-by-default baseline covers the real machine, not the checked-in list.
//
// ALL THREE SCOPES, not just user (CR): Claude Code also reads
// <cwd>/.claude/settings.json and settings.local.json, and those OVERRIDE user
// scope — reading only ~/.claude would miss a project/local-enabled plugin
// entirely. Same layer set glm-env's findSettingsConflicts already screens.
//
// Missing layer = no opinion (normal — most repos have no settings.local.json).
// Present-but-unparseable = FAIL CLOSED (throw): if the active plugin universe
// cannot be determined we must not inject a profile that silently leaves unknown
// plugins enabled. `home`/`cwd` are injected so this is testable hermetically.
// `configDir` overrides the USER-scope layer: the child reads whatever
// CLAUDE_CONFIG_DIR it inherits, which is NOT always <home>/.claude (CR). Callers
// that know the child's effective config dir pass it; otherwise <home>/.claude.
export function readEnabledPluginIds(home, cwd, configDir) {
  const files = [join(configDir || join(home, '.claude'), 'settings.json')];
  if (cwd) {
    // Walk cwd -> filesystem root (CR): Claude Code resolves project settings by
    // WALKING UP from cwd, so every ancestor's .claude/settings{,.local}.json is
    // active — exactly the model claude-codex's project-settings screen already
    // uses (HIMMEL-979 R5, "a nested launch must not miss an ancestor settings
    // file"). This matters concretely here: himmel worktrees live INSIDE the main
    // checkout (<repo>/.claude/worktrees/<name>), so the MAIN checkout's
    // .claude/settings.local.json is an ANCESTOR of the worker's cwd. Reading only
    // the worktree's own layer would miss a locally-enabled uncatalogued plugin and
    // leave its lower-layer `true` intact under merge semantics.
    let d = resolve(cwd);
    for (;;) {
      files.push(join(d, '.claude', 'settings.json'), join(d, '.claude', 'settings.local.json'));
      const parent = dirname(d);
      if (parent === d) break; // filesystem root
      d = parent;
    }
  }
  const ids = new Set();
  for (const f of files) {
    if (!existsSync(f)) continue; // absent layer carries no opinion
    let j;
    try { j = JSON.parse(readFileSync(f, 'utf8')); }
    catch (e) {
      throw new Error(`plugin-profiles: cannot determine the active plugin universe — ${f} is unreadable/unparseable (${e?.message ?? e}). Refusing rather than injecting a profile that may leave unknown plugins enabled.`);
    }
    const m = j?.enabledPlugins;
    if (m && typeof m === 'object' && !Array.isArray(m)) for (const k of Object.keys(m)) ids.add(k);
  }
  return [...ids];
}

// Registry-integrity check (design follow-up: a pre-commit floor-present guard).
// Returns an array of human-readable problems ([] === valid). Kept separate from
// resolveProfile so a resolve stays cheap and a validator can gate the JSON.
export function validateRegistry(registry) {
  const errors = [];
  const floor = registry?.floor;
  const catalog = registry?.catalog;
  const profiles = registry?.profiles;
  // Guard the shapes FIRST and only iterate a field once it is the right shape —
  // a malformed registry must produce COLLECTED errors, never a thrown
  // TypeError (a non-iterable floor/catalog or a null profiles would otherwise
  // crash the validator that exists to report exactly those problems).
  const floorOk = Array.isArray(floor) && floor.length > 0;
  const catalogOk = Array.isArray(catalog) && catalog.length > 0;
  const profilesOk = profiles !== null && typeof profiles === 'object' && !Array.isArray(profiles);
  if (!floorOk) errors.push('floor must be a non-empty array');
  if (!catalogOk) errors.push('catalog must be a non-empty array');
  if (!profilesOk) errors.push('profiles must be a non-null object');
  const catalogSet = new Set(catalogOk ? catalog : []);
  if (floorOk) for (const id of floor) {
    if (!ID_RE.test(id)) errors.push(`floor id "${id}" is not a valid plugin@marketplace id`);
    if (!catalogSet.has(id)) errors.push(`floor id "${id}" is missing from catalog (a complete map cannot guarantee it)`);
  }
  if (catalogOk) {
    for (const id of catalog) if (!ID_RE.test(id)) errors.push(`catalog id "${id}" is not a valid plugin@marketplace id`);
    if (catalog.length !== catalogSet.size) errors.push('catalog contains duplicate ids');
  }
  if (profilesOk) {
    if (!Object.hasOwn(profiles, 'operator') || profiles.operator !== null) errors.push('profile "operator" must be present and null (the never-injected sentinel)');
    for (const [name, spec] of Object.entries(profiles)) {
      if (spec === null) {
        // Only "operator" may be null — a null on any other profile silently
        // disables its injection, so reject it here (the operator-null check
        // above already validates operator itself).
        if (name !== 'operator') errors.push(`profile "${name}" must be { enable: [...] } — only "operator" may be null (the never-injected sentinel)`);
        continue;
      }
      if (typeof spec !== 'object' || !Array.isArray(spec.enable)) { errors.push(`profile "${name}" must be null or { enable: [...] }`); continue; }
      for (const id of spec.enable) {
        if (!ID_RE.test(id)) errors.push(`profile "${name}" enable id "${id}" is not a valid plugin@marketplace id`);
        if (!catalogSet.has(id)) errors.push(`profile "${name}" enable id "${id}" is missing from catalog`);
      }
    }
  }
  return errors;
}

// Resolve a profile into a settings object, or null for the operator sentinel
// (never injected — that IS ~/.claude). The returned map is COMPLETE: every
// catalog id is present (false unless enabled), so injection is correct whether
// Claude Code MERGES or REPLACES enabledPlugins. Floor is forced true LAST so
// nothing — a mis-declared enable, an overlay — can drop it (design Rule 1).
// `opts.addPlugins` is the per-dispatch overlay (design Rule 4): task-specific
// plugins enabled over the base for this one dispatch.
export function resolveProfile(registry, name, opts = {}) {
  const profiles = registry.profiles ?? {};
  // Own-property test, NOT `name in profiles` — `in` walks the prototype chain,
  // so a --profile value colliding with an Object.prototype member (constructor,
  // toString, hasOwnProperty, …) would read as "known" and fall through to that
  // inherited function instead of failing closed (the fail-closed refusal is the
  // contract the whole feature rests on).
  if (!Object.hasOwn(profiles, name)) {
    throw new Error(`plugin-profiles: unknown profile "${name}" (known: ${Object.keys(profiles).join(', ')})`);
  }
  const addPlugins = opts.addPlugins ?? [];
  // Overlay ids must be BOTH well-formed AND known to the catalog — a shape-valid
  // typo (`valid-looking@marketplace`) would otherwise bypass the fail-closed
  // refusal and be emitted as enabled despite belonging to no real plugin.
  // Validated BEFORE the operator return (CR): otherwise `--profile operator
  // --add-plugins <garbage>` skips the refusal entirely.
  const catalogSet = new Set(registry.catalog ?? []);
  for (const id of addPlugins) {
    if (!ID_RE.test(id)) throw new Error(`plugin-profiles: --add-plugins entry "${id}" is not a valid plugin@marketplace id`);
    if (!catalogSet.has(id)) throw new Error(`plugin-profiles: --add-plugins entry "${id}" is missing from catalog`);
  }

  // The operator sentinel is recognized BY NAME (the design's single
  // no-injection profile), NOT by "any null spec". A null spec on any OTHER
  // profile is a registry-authoring error (validateRegistry rejects it) and must
  // never masquerade as operator — that would silently disable injection, i.e.
  // run the worker on the FULL profile, the exact leak this feature closes.
  if (name === 'operator') {
    // operator = inject NOTHING, so an overlay cannot be honoured. Refuse rather
    // than silently dropping a capability the caller explicitly asked for (CR).
    if (addPlugins.length) {
      throw new Error(`plugin-profiles: --profile operator is incompatible with --add-plugins (operator injects no settings at all, so the overlay could not be applied). Use a lane-* profile to add plugins.`);
    }
    return null;
  }
  const spec = profiles[name];

  // 1. deny-by-default baseline = the checked-in catalog UNION the caller's live
  //    plugin universe (opts.installed). The static catalog alone cannot enforce
  //    deny-by-default across version skew: a plugin installed on this machine but
  //    absent from the catalog would go unmentioned and INHERIT its enabled state,
  //    silently loading its hooks/MCP/tools into an unattended worker — i.e. the
  //    lane would not actually be lean. Callers pass the runtime set; a caller that
  //    passes nothing falls back to catalog-only (the historical behaviour).
  const enabledPlugins = {};
  for (const id of (registry.catalog ?? [])) enabledPlugins[id] = false;
  for (const id of (opts.installed ?? [])) enabledPlugins[id] = false;
  // Defensive: a malformed non-operator null/other spec yields the lean floor
  // (Array.isArray guard), never a crash or a silent no-inject.
  for (const id of (Array.isArray(spec?.enable) ? spec.enable : [])) enabledPlugins[id] = true; // 2. profile base on
  for (const id of addPlugins) enabledPlugins[id] = true;                 // 3. per-dispatch overlay on
  for (const id of (registry.floor ?? [])) enabledPlugins[id] = true;     // 4. floor forced on (inviolable)
  return { enabledPlugins };
}

// File-reading convenience for the spawn scripts / CLI: load the registry and
// resolve. Returns null for the operator sentinel.
// VALIDATES first and fails closed (CR): resolveProfile trusts its registry, so a
// corrupted/mis-edited plugin-profiles.json would otherwise silently yield a
// profile that violates the floor / complete-map guarantees. Every consumer that
// reads the file goes through here, so this is the enforcement point — the
// --validate CLI and the tests are checks, not guards.
export function resolveProfileByName(name, opts = {}, path = REGISTRY) {
  const registry = loadRegistry(path);
  const errors = validateRegistry(registry);
  if (errors.length) {
    throw new Error(`plugin-profiles: registry invalid (${path}):\n  - ${errors.join('\n  - ')}`);
  }
  return resolveProfile(registry, name, opts);
}

// ── CLI (measurement / launcher use) ────────────────────────────────────────
// node plugin-profiles.mjs <profile> [--add-plugins a@m,b@m]  -> prints the
//   `--settings` JSON ({"enabledPlugins":{…}}) to stdout, or nothing for operator.
// node plugin-profiles.mjs --list      -> one profile name per line.
// node plugin-profiles.mjs --validate  -> prints registry errors (exit 1 if any).
if (import.meta.url === `file://${process.argv[1]}` || process.argv[1] === fileURLToPath(import.meta.url)) {
  const argv = process.argv.slice(2);
  const die = (code, msg) => { process.stderr.write(msg + '\n'); process.exit(code); };
  try {
    if (argv[0] === '--list') {
      for (const name of Object.keys(loadRegistry().profiles ?? {})) process.stdout.write(name + '\n');
      process.exit(0);
    }
    if (argv[0] === '--validate') {
      const errs = validateRegistry(loadRegistry());
      if (errs.length) die(1, 'plugin-profiles: registry invalid:\n  - ' + errs.join('\n  - '));
      process.stdout.write('plugin-profiles: registry valid\n');
      process.exit(0);
    }
    const name = argv[0];
    if (!name) die(2, 'usage: plugin-profiles.mjs <profile> [--add-plugins a@m,b@m] | --list | --validate');
    // Consume EVERY remaining argument and die on anything unexpected (CR): the
    // old indexOf-based parse silently ignored unknown options and trailing
    // values, so a typo'd flag looked like it applied while doing nothing — the
    // opposite of the fail-closed contract the rest of this resolver keeps.
    // Repeated --add-plugins accumulate (parity with the spawn parsers).
    const addPlugins = [];
    for (let i = 1; i < argv.length; i++) {
      if (argv[i] !== '--add-plugins') die(2, `plugin-profiles: unknown argument "${argv[i]}"`);
      if (argv[i + 1] === undefined) die(2, 'plugin-profiles: --add-plugins requires a value');
      addPlugins.push(...parseAddPlugins(argv[++i]));
    }
    const settings = resolveProfileByName(name, { addPlugins });
    if (settings === null) process.exit(0); // operator: nothing to inject
    process.stdout.write(JSON.stringify(settings) + '\n');
  } catch (e) {
    die(2, `plugin-profiles: ${e?.message ?? e}`);
  }
}
