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
import { homedir } from 'node:os';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REGISTRY = process.env.PLUGIN_PROFILES_REGISTRY || join(SCRIPT_DIR, 'plugin-profiles.json');

// plugin@marketplace id shape: `name@marketplace`, each side restricted to
// [A-Za-z0-9._-]. The character class is deliberately TIGHT (not just "no @/space")
// so a `--add-plugins` overlay id can never carry shell metacharacters (`;`, `$`,
// backticks, …) — the resolver's overlay-validation is the single gate before an
// id is emitted unquoted into the spawn-glm cap-respawn command line. Every real
// plugin id (see catalog) matches this.
const ID_RE = /^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$/;

// mcpCatalog url/command/args credential-literal guard (glm-3): unlike env/
// headers (which must be a BARE $VAR reference, nothing else — see
// validateRegistry), these fields are ordinary invocation literals, so a
// plain value ("npx", "http://localhost:8181/mcp", a filesystem path) is
// fine. What is NOT fine: a $-token that isn't a clean bare reference (a
// stray "${...}" or "$1foo" reads as broken/unintended interpolation, not a
// real var — flag it), or a substring matching a HIGH-SIGNAL secret prefix
// (API-key/token prefix, a Bearer header). Deliberately NOT a generic
// base64/hex-blob heuristic: `[A-Za-z0-9+/]{32,}` false-positives on an
// ordinary POSIX path (`/` is in the class and nothing in a path breaks the
// run) — exactly the shape T3.1 will populate command/args with for a local
// stdio server. This validator's job is the $VAR contract, not entropy
// detection; the registry's authoritative leak gate is the pre-push/gitleaks
// scan (spec'd for T3.1), so a weak heuristic here buys little and costs a
// false rejection of ordinary paths. Returns a problem string, or null if clean.
const SECRET_SHAPE_RE = /sk-[A-Za-z0-9]{10,}|gh[pousr]_[A-Za-z0-9]{10,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{12,}|Bearer\s+\S+/;
function credentialLiteralIssue(value) {
  for (const token of value.match(/\$\w*/g) ?? []) {
    if (!/^\$[A-Za-z_][A-Za-z0-9_]*$/.test(token)) return `contains a malformed $-interpolation "${token}" (an embedded $VAR is fine, but this token isn't one — expected $ followed by a variable name)`;
  }
  if (SECRET_SHAPE_RE.test(value)) return 'looks like it contains an embedded credential literal';
  return null;
}

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

// Shared field-spec helpers (HIMMEL-2154): floor/catalog/base/profile.enable/
// profile.drop all validate the same two facts about an id list — each id
// matches ID_RE, and each id is a catalog member — plus an optional
// no-duplicates check. Pulling that out here is what collapses validateRegistry's
// complexity; the per-field CALL SITES below still decide which checks apply and
// with what wording, so every existing rejection case keeps its exact message.
function validateIdList(errors, ids, catalogSet, label, missingSuffix = '') {
  for (const id of ids) {
    if (!ID_RE.test(id)) errors.push(`${label} id "${id}" is not a valid plugin@marketplace id`);
    if (!catalogSet.has(id)) errors.push(`${label} id "${id}" is missing from catalog${missingSuffix}`);
  }
}
function checkNoDuplicates(errors, ids, message) {
  if (ids.length !== new Set(ids).size) errors.push(message);
}

// One profile entry's validation (enable/drop/disallowedTools + the "bare"
// floor-only invariant). Pulled out of validateRegistry's profiles loop for
// the same reason as validateIdList above: this body repeats once per
// profile in the registry, so extracting it is what collapses the parent's
// complexity, not a behavior change.
function validateProfileSpec(errors, name, spec, catalogSet, floorSet) {
  if (spec === null) {
    // Only "operator" may be null — a null on any other profile silently
    // disables its injection, so reject it here (the operator-null check
    // above already validates operator itself).
    if (name !== 'operator') errors.push(`profile "${name}" must be { enable: [...] } — only "operator" may be null (the never-injected sentinel)`);
    return;
  }
  if (typeof spec !== 'object' || !Array.isArray(spec.enable)) { errors.push(`profile "${name}" must be null or { enable: [...] }`); return; }
  if (name === 'bare') {
    // ENFORCE the floor-only promise, not just document it (codex-adv-2):
    // resolveProfile skips the base step for "bare" by name, so a non-empty
    // enable/drop/disallowedTools here would silently grant bare a
    // persistent capability its whole reason to exist says it shouldn't
    // have. --add-plugins is the only sanctioned way to add anything.
    if (spec.enable.length !== 0) errors.push('profile "bare" enable must be empty — bare is floor-only by construction; add plugins per-dispatch via --add-plugins, never persistently in the registry');
    if (spec.drop !== undefined) errors.push('profile "bare" must not declare drop — bare already resolves to floor-only, a drop list is meaningless there');
    if (spec.disallowedTools !== undefined) errors.push('profile "bare" must not declare disallowedTools — bare has no base capability to restrict');
  }
  validateIdList(errors, spec.enable, catalogSet, `profile "${name}" enable`);
  if (spec.drop !== undefined) {
    if (!Array.isArray(spec.drop)) {
      errors.push(`profile "${name}" drop must be an array`);
    } else {
      validateIdList(errors, spec.drop, catalogSet, `profile "${name}" drop`);
      const enableSet = new Set(spec.enable);
      for (const id of spec.drop) {
        if (floorSet.has(id)) errors.push(`profile "${name}" drop id "${id}" is a floor id (the floor is inviolable)`);
        if (enableSet.has(id)) errors.push(`profile "${name}" drop id "${id}" is also in enable (drop and enable are mutually exclusive)`);
      }
    }
  }
  // disallowedTools is SCHEMA-ONLY here — nothing consumes it yet. The
  // producer is T2.3 (a --disallowedTools CLI flag threaded through the
  // claudex builder via a second resolver export, deliberately NOT by
  // widening resolveProfile's return shape — that would break pinned
  // spawn-glm.test.ts literals and touches a file another session owns).
  if (spec.disallowedTools !== undefined) {
    const toolsOk = Array.isArray(spec.disallowedTools) && spec.disallowedTools.every((t) => typeof t === 'string' && t.length > 0);
    if (!toolsOk) errors.push(`profile "${name}" disallowedTools must be an array of non-empty strings`);
  }
  // contextBudget (HIMMEL-2189) — the first-turn token ceiling the measured
  // probe asserts against, so it is REQUIRED on every non-operator profile
  // (a missing budget would let a lane's context footprint grow unnoticed).
  if (!Number.isInteger(spec.contextBudget) || spec.contextBudget <= 0) {
    errors.push(`profile "${name}" contextBudget must be a positive integer`);
  }
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
  if (floorOk) validateIdList(errors, floor, catalogSet, 'floor', ' (a complete map cannot guarantee it)');
  if (catalogOk) {
    validateIdList(errors, catalog, catalogSet, 'catalog');
    checkNoDuplicates(errors, catalog, 'catalog contains duplicate ids');
  }
  const floorSet = new Set(floorOk ? floor : []);
  const VAR_RE = /^\$[A-Za-z_][A-Za-z0-9_]*$/;

  // base is OPTIONAL (absent -> treated as [] at resolve time, which fails in
  // the SAFE direction — fewer plugins on): a custom registry that predates
  // this field must not hard-fail on upgrade. When PRESENT it is fully
  // validated, same rigor as floor/catalog.
  const base = registry?.base;
  const baseOk = base === undefined || Array.isArray(base);
  if (!baseOk) errors.push('base must be an array');
  if (baseOk && base !== undefined) {
    validateIdList(errors, base, catalogSet, 'base');
    checkNoDuplicates(errors, base, 'base contains duplicate ids');
  }

  // mcpCatalog is structure-only in this task (populating it is T3.1) and also
  // OPTIONAL (absent -> treated as {}, same upgrade-safety reasoning as base).
  // When present, validate the shape and the credential-literal guard: env/
  // headers values must be a BARE $VAR reference (never a literal — those two
  // fields exist solely to carry secrets); url/command/args are ordinary
  // literals (a plain URL or command is fine) but may not embed a malformed
  // $-interpolation or an obvious secret shape — the registry ships publicly.
  const mcpCatalog = registry?.mcpCatalog;
  const mcpOk = mcpCatalog === undefined || (mcpCatalog !== null && typeof mcpCatalog === 'object' && !Array.isArray(mcpCatalog));
  if (!mcpOk) errors.push('mcpCatalog must be a non-null object');
  if (mcpOk && mcpCatalog !== undefined) {
    for (const [id, entry] of Object.entries(mcpCatalog)) {
      if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) { errors.push(`mcpCatalog entry "${id}" must be an object`); continue; }
      for (const field of ['env', 'headers']) {
        const map = entry[field];
        if (map === undefined) continue;
        if (map === null || typeof map !== 'object' || Array.isArray(map)) { errors.push(`mcpCatalog entry "${id}" ${field} must be an object`); continue; }
        for (const [k, v] of Object.entries(map)) {
          if (typeof v !== 'string' || !VAR_RE.test(v)) errors.push(`mcpCatalog entry "${id}" ${field}.${k} must be a $VAR reference (e.g. "$TOKEN"), never a literal`);
        }
      }
      for (const field of ['url', 'command']) {
        const v = entry[field];
        if (v === undefined) continue;
        if (typeof v !== 'string') { errors.push(`mcpCatalog entry "${id}" ${field} must be a string`); continue; }
        const issue = credentialLiteralIssue(v);
        if (issue) errors.push(`mcpCatalog entry "${id}" ${field} ${issue}`);
      }
      if (entry.args !== undefined) {
        if (!Array.isArray(entry.args) || !entry.args.every((a) => typeof a === 'string')) {
          errors.push(`mcpCatalog entry "${id}" args must be an array of strings`);
        } else {
          entry.args.forEach((a, i) => {
            const issue = credentialLiteralIssue(a);
            if (issue) errors.push(`mcpCatalog entry "${id}" args[${i}] ${issue}`);
          });
        }
      }
    }
  }

  if (profilesOk) {
    if (!Object.hasOwn(profiles, 'operator') || profiles.operator !== null) errors.push('profile "operator" must be present and null (the never-injected sentinel)');
    // "bare" itself is OPTIONAL (glm-1): a registry without it simply doesn't
    // offer that profile, and resolveProfile already fails closed on an
    // unknown name — nothing is lost, and requiring it would hard-fail the
    // exact pre-existing custom registries base/mcpCatalog were made optional
    // for. What must not exist is a LYING bare — that invariant is enforced
    // below, unconditionally, whenever "bare" IS present.
    for (const [name, spec] of Object.entries(profiles)) {
      validateProfileSpec(errors, name, spec, catalogSet, floorSet);
    }
  }
  return errors;
}

// Resolve a profile into a settings object, or null for the operator sentinel
// (never injected — that IS ~/.claude). The returned map is COMPLETE: every
// catalog id is present (false unless enabled), so injection is correct whether
// Claude Code MERGES or REPLACES enabledPlugins. Resolution order:
//   0. deny-by-default: catalog UNION opts.installed all false
//   1. registry.base on (skipped for "bare" — see below)
//   2. profile.drop off
//   3. profile.enable on
//   4. opts.addPlugins (the per-dispatch --add-plugins overlay) on
//   5. registry.floor on, LAST
// Floor is forced true LAST so nothing — a mis-declared drop, a bad overlay —
// can drop it (design Rule 1). "bare" is name-recognized (like operator) and
// skips step 1: it resolves to floor-only-plus-overlay so a dispatch can
// compose a one-off surface purely from --add-plugins with no registry entry.
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

  // 0. deny-by-default baseline = the checked-in catalog UNION the caller's live
  //    plugin universe (opts.installed). The static catalog alone cannot enforce
  //    deny-by-default across version skew: a plugin installed on this machine but
  //    absent from the catalog would go unmentioned and INHERIT its enabled state,
  //    silently loading its hooks/MCP/tools into an unattended worker — i.e. the
  //    lane would not actually be lean. Callers pass the runtime set; a caller that
  //    passes nothing falls back to catalog-only (the historical behaviour).
  const enabledPlugins = {};
  for (const id of (registry.catalog ?? [])) enabledPlugins[id] = false;
  for (const id of (opts.installed ?? [])) enabledPlugins[id] = false;
  // 1. registry.base on — skipped for "bare" (name-recognized): folding base in
  //    for bare would duplicate it as a drop list that rots the moment base
  //    grows, and "bare" would quietly stop meaning bare.
  if (name !== 'bare') {
    for (const id of (registry.base ?? [])) enabledPlugins[id] = true;
  }
  // Defensive: a malformed non-operator null/other spec yields the lean floor
  // (Array.isArray guard), never a crash or a silent no-inject.
  for (const id of (Array.isArray(spec?.drop) ? spec.drop : [])) enabledPlugins[id] = false;   // 2. profile.drop off
  for (const id of (Array.isArray(spec?.enable) ? spec.enable : [])) enabledPlugins[id] = true; // 3. profile.enable on
  for (const id of addPlugins) enabledPlugins[id] = true;                 // 4. per-dispatch overlay on
  for (const id of (registry.floor ?? [])) enabledPlugins[id] = true;     // 5. floor forced on, LAST (inviolable)
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
    // opts.installed = the LIVE plugin universe (CR, codex-adv-1): without it the
    // emitted map denies only catalogued ids, so a plugin enabled on this machine
    // but absent from catalog goes unmentioned and inherits its lower-layer
    // `true` under merge semantics — the exact leak "bare" promises floor-only
    // freedom from. readEnabledPluginIds already fails closed on an unparseable
    // settings layer, so this CLI stays fail-closed too. Pass CLAUDE_CONFIG_DIR
    // (glm-2): a child reading a non-default config dir has a different
    // user-scope layer, so skipping it would miss plugins enabled there —
    // the same leak class, just via a different layer. undefined falls back
    // to <home>/.claude, the existing behaviour.
    const installed = readEnabledPluginIds(homedir(), process.cwd(), process.env.CLAUDE_CONFIG_DIR);
    const settings = resolveProfileByName(name, { addPlugins, installed });
    if (settings === null) process.exit(0); // operator: nothing to inject
    process.stdout.write(JSON.stringify(settings) + '\n');
  } catch (e) {
    die(2, `plugin-profiles: ${e?.message ?? e}`);
  }
}
