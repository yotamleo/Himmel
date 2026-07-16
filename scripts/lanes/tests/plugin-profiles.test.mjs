// scripts/lanes/tests/plugin-profiles.test.mjs
// HIMMEL-1040 — resolver invariants for the named plugin-profile registry.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { resolveProfile, validateRegistry, parseAddPlugins, loadRegistry, readEnabledPluginIds, resolveProfileByName } from '../plugin-profiles.mjs';

const REG = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin-profiles.json'), 'utf8'));
const FLOOR = REG.floor;

// A tiny synthetic registry keeps the invariant tests independent of the shipped
// data (which the "real registry" tests below pin separately).
const MINI = {
  floor: ['handover@himmel', 'qmd@himmel'],
  catalog: ['handover@himmel', 'qmd@himmel', 'obsidian@x', 'skill-creator@y', 'coderabbit@y'],
  profiles: {
    operator: null,
    lean: { enable: ['coderabbit@y'] },
  },
};

test('operator profile resolves to null (never injected)', () => {
  assert.equal(resolveProfile(REG, 'operator'), null);
  assert.equal(resolveProfile(MINI, 'operator'), null);
});

test('floor is always true — even when no profile enables it', () => {
  for (const name of Object.keys(REG.profiles)) {
    const r = resolveProfile(REG, name);
    if (r === null) continue; // operator
    for (const id of FLOOR) assert.equal(r.enabledPlugins[id], true, `${name}: floor ${id} must be true`);
  }
});

test('resolved map is COMPLETE — every catalog id is present', () => {
  const r = resolveProfile(REG, 'lane-impl');
  for (const id of REG.catalog) assert.ok(id in r.enabledPlugins, `catalog ${id} missing from resolved map`);
  assert.equal(Object.keys(r.enabledPlugins).length, new Set(REG.catalog).size);
});

test('lane-impl drops all content/authoring but keeps floor + pr-review', () => {
  const { enabledPlugins: p } = resolveProfile(REG, 'lane-impl');
  assert.equal(p['pr-review-toolkit-himmel@himmel'], true);
  assert.equal(p['claude-obsidian@himmel'], false);
  assert.equal(p['obsidian-triage@himmel'], false);
  assert.equal(p['skill-creator@claude-plugins-official'], false);
  assert.equal(p['hookify@claude-plugins-official'], false);
});

test('lane-content adds obsidian on top of the impl floor', () => {
  const { enabledPlugins: p } = resolveProfile(REG, 'lane-content');
  assert.equal(p['claude-obsidian@himmel'], true);
  assert.equal(p['obsidian-triage@himmel'], true);
  assert.equal(p['pr-review-toolkit-himmel@himmel'], true);
  // still lean on dev-authoring
  assert.equal(p['skill-creator@claude-plugins-official'], false);
});

test('per-dispatch overlay enables a plugin over the base profile', () => {
  const { enabledPlugins: p } = resolveProfile(REG, 'lane-impl', { addPlugins: ['claude-obsidian@himmel'] });
  assert.equal(p['claude-obsidian@himmel'], true); // overlaid on
  assert.equal(p['pr-review-toolkit-himmel@himmel'], true); // base still there
});

test('overlay can never drop the floor (floor forced last)', () => {
  // Even if a caller tries to name a floor plugin, it stays true; and a normal
  // overlay leaves the floor intact.
  const { enabledPlugins: p } = resolveProfile(MINI, 'lean', { addPlugins: ['obsidian@x'] });
  for (const id of MINI.floor) assert.equal(p[id], true);
  assert.equal(p['obsidian@x'], true);
});

test('unknown profile throws', () => {
  assert.throws(() => resolveProfile(REG, 'nope'), /unknown profile/);
});

test('a profile name colliding with Object.prototype still throws (own-property test, not `in`)', () => {
  for (const evil of ['constructor', 'toString', 'hasOwnProperty', 'valueOf', '__proto__']) {
    assert.throws(() => resolveProfile(REG, evil), /unknown profile/, `${evil} must be rejected, not silently resolved`);
  }
});

test('malformed overlay id throws', () => {
  assert.throws(() => resolveProfile(REG, 'lane-impl', { addPlugins: ['no-marketplace'] }), /not a valid plugin@marketplace/);
});

test('overlay ids carrying shell metacharacters are rejected (no injection into the respawn command)', () => {
  for (const evil of ['a@m;rm', 'a@m$(id)', 'a@m`id`', 'a@m|x', 'a@m>f', 'a@m&b']) {
    assert.throws(() => resolveProfile(REG, 'lane-impl', { addPlugins: [evil] }), /not a valid plugin@marketplace/, `${evil} must be rejected`);
  }
});

test('overlay id that is shape-valid but not in the catalog is rejected (typo protection)', () => {
  assert.throws(() => resolveProfile(REG, 'lane-impl', { addPlugins: ['valid-looking@marketplace'] }), /missing from catalog/);
  // a real catalog id still resolves
  const { enabledPlugins: p } = resolveProfile(REG, 'lane-impl', { addPlugins: ['claude-obsidian@himmel'] });
  assert.equal(p['claude-obsidian@himmel'], true);
});

test('CLI arg parsing: unknown/dangling args die instead of being silently ignored', () => {
  // The CLI is a thin wrapper, but a typo'd flag that LOOKS applied while doing
  // nothing is the opposite of this resolver's fail-closed contract.
  const cli = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin-profiles.mjs');
  const run = (args) => spawnSync(process.execPath, [cli, ...args], { encoding: 'utf8' });
  const unknown = run(['lane-impl', '--bogus']);
  assert.equal(unknown.status, 2);
  assert.match(unknown.stderr, /unknown argument "--bogus"/);
  const dangling = run(['lane-impl', '--add-plugins']);
  assert.equal(dangling.status, 2);
  assert.match(dangling.stderr, /--add-plugins requires a value/);
  // repeated --add-plugins accumulate, and the happy path still emits the map
  const ok = run(['lane-impl', '--add-plugins', 'claude-obsidian@himmel', '--add-plugins', 'obsidian-triage@himmel']);
  assert.equal(ok.status, 0);
  const p = JSON.parse(ok.stdout).enabledPlugins;
  assert.equal(p['claude-obsidian@himmel'], true);
  assert.equal(p['obsidian-triage@himmel'], true);
});

test('parseAddPlugins splits, trims, drops empties', () => {
  assert.deepEqual(parseAddPlugins('a@m, b@m ,,c@m'), ['a@m', 'b@m', 'c@m']);
  assert.deepEqual(parseAddPlugins(''), []);
  assert.deepEqual(parseAddPlugins(undefined), []);
});

test('opts.installed widens the deny-by-default baseline beyond the static catalog', () => {
  // A plugin present on the machine but NOT in the checked-in catalog must still
  // be turned OFF for a lane — otherwise it inherits `true` (version-skew gap).
  const skew = 'brand-new@somewhere';
  const bare = resolveProfile(REG, 'lane-impl');
  assert.ok(!(skew in bare.enabledPlugins), 'precondition: unknown to the catalog');
  const { enabledPlugins: p } = resolveProfile(REG, 'lane-impl', { installed: [skew] });
  assert.equal(p[skew], false, 'installed-but-uncatalogued plugin must be explicitly disabled');
  // the floor still wins over the widened baseline
  for (const id of FLOOR) assert.equal(p[id], true);
});

test('opts.installed cannot disable the floor or an enabled profile plugin', () => {
  const { enabledPlugins: p } = resolveProfile(REG, 'lane-content', { installed: [...FLOOR, 'claude-obsidian@himmel'] });
  for (const id of FLOOR) assert.equal(p[id], true);
  assert.equal(p['claude-obsidian@himmel'], true); // profile enable beats the baseline
});

// NOTE: the cwd walk goes to the FILESYSTEM ROOT (matching Claude Code / the
// claude-codex screen), so on a machine whose tmpdir sits under $HOME the walk
// legitimately also picks up the real ~/.claude ids. These tests therefore assert
// INCLUSION of the seeded ids (and the fail-closed behaviour), not exact equality —
// asserting equality would be asserting the test host's own config.
test('readEnabledPluginIds unions USER + PROJECT + LOCAL settings layers', () => {
  const home = mkdtempSync(join(tmpdir(), 'pp-home-'));
  const cwd = mkdtempSync(join(tmpdir(), 'pp-cwd-'));
  mkdirSync(join(home, '.claude'), { recursive: true });
  mkdirSync(join(cwd, '.claude'), { recursive: true });
  writeFileSync(join(home, '.claude', 'settings.json'), JSON.stringify({ enabledPlugins: { 'user@m': true } }));
  writeFileSync(join(cwd, '.claude', 'settings.json'), JSON.stringify({ enabledPlugins: { 'proj@m': true } }));
  writeFileSync(join(cwd, '.claude', 'settings.local.json'), JSON.stringify({ enabledPlugins: { 'local@m': false } }));
  // project/local scopes OVERRIDE user, so ids from all three must be in the universe
  const ids = readEnabledPluginIds(home, cwd);
  for (const id of ['user@m', 'proj@m', 'local@m']) assert.ok(ids.includes(id), `${id} must be in the universe`);
  // no cwd => user layer only (hermetic: no walk)
  assert.deepEqual(readEnabledPluginIds(home).sort(), ['user@m']);
});

test('readEnabledPluginIds honours an explicit configDir (the child\'s effective CLAUDE_CONFIG_DIR)', () => {
  // The child reads whatever CLAUDE_CONFIG_DIR it inherits — not always <home>/.claude.
  // Scanning the wrong dir would miss an uncatalogued plugin enabled in the ACTIVE one.
  const home = mkdtempSync(join(tmpdir(), 'pp-home4-'));
  const alt = mkdtempSync(join(tmpdir(), 'pp-altcfg-'));
  mkdirSync(join(home, '.claude'), { recursive: true });
  writeFileSync(join(home, '.claude', 'settings.json'), JSON.stringify({ enabledPlugins: { 'home-only@m': true } }));
  writeFileSync(join(alt, 'settings.json'), JSON.stringify({ enabledPlugins: { 'altcfg-only@m': true } }));
  const ids = readEnabledPluginIds(home, undefined, alt);
  assert.ok(ids.includes('altcfg-only@m'), 'the ACTIVE config dir must be scanned');
  assert.ok(!ids.includes('home-only@m'), 'the overridden <home>/.claude must NOT be scanned');
});

test('readEnabledPluginIds walks ANCESTORS (a worktree inherits the main checkout layers)', () => {
  // himmel worktrees live INSIDE the main checkout, so an ancestor's settings are
  // active for the worker — reading only the leaf dir would miss them.
  const home = mkdtempSync(join(tmpdir(), 'pp-home3-'));
  const root = mkdtempSync(join(tmpdir(), 'pp-root-'));
  const leaf = join(root, '.claude', 'worktrees', 'glm+x');
  mkdirSync(join(root, '.claude'), { recursive: true });
  mkdirSync(leaf, { recursive: true });
  writeFileSync(join(root, '.claude', 'settings.local.json'), JSON.stringify({ enabledPlugins: { 'ancestor-local@m': true } }));
  const ids = readEnabledPluginIds(home, leaf);
  assert.ok(ids.includes('ancestor-local@m'), 'an ANCESTOR local layer must reach the universe');
});

test('readEnabledPluginIds: an ABSENT layer is no-opinion; an UNPARSEABLE layer FAILS CLOSED', () => {
  const home = mkdtempSync(join(tmpdir(), 'pp-home2-'));
  const cwd = mkdtempSync(join(tmpdir(), 'pp-cwd2-'));
  // absent layers must not throw (the normal case: most repos have no settings.local.json)
  assert.doesNotThrow(() => readEnabledPluginIds(home, cwd));
  // a layer that EXISTS but cannot be parsed must throw — we cannot know the
  // universe, so we must not inject a profile that may leave plugins enabled
  mkdirSync(join(cwd, '.claude'), { recursive: true });
  writeFileSync(join(cwd, '.claude', 'settings.local.json'), 'not json');
  assert.throws(() => readEnabledPluginIds(home, cwd), /cannot determine the active plugin universe/);
  // a non-object enabledPlugins is parseable => contributes no ids, no throw
  writeFileSync(join(cwd, '.claude', 'settings.local.json'), JSON.stringify({ enabledPlugins: [] }));
  assert.doesNotThrow(() => readEnabledPluginIds(home, cwd));
  assert.ok(!readEnabledPluginIds(home, cwd).includes('nothing@m'));
});

test('resolveProfileByName FAILS CLOSED on an invalid registry (guard, not just --validate)', () => {
  const dir = mkdtempSync(join(tmpdir(), 'pp-reg-'));
  const bad = join(dir, 'bad.json');
  // floor id missing from catalog => the complete-map guarantee cannot hold
  writeFileSync(bad, JSON.stringify({ floor: ['a@m', 'b@m'], catalog: ['a@m'], profiles: { operator: null, 'lane-impl': { enable: [] } } }));
  assert.throws(() => resolveProfileByName('lane-impl', {}, bad), /registry invalid/);
  // a valid registry still resolves through the same wrapper
  const good = join(dir, 'good.json');
  writeFileSync(good, JSON.stringify({ floor: ['a@m'], catalog: ['a@m', 'b@m'], profiles: { operator: null, 'lane-impl': { enable: ['b@m'] } } }));
  assert.equal(resolveProfileByName('lane-impl', {}, good).enabledPlugins['a@m'], true);
});

test('the shipped registry passes validateRegistry', () => {
  assert.deepEqual(validateRegistry(REG), []);
  // loadRegistry reads the same shipped file
  assert.deepEqual(validateRegistry(loadRegistry()), []);
});

test('validateRegistry catches a floor id missing from catalog', () => {
  const bad = { floor: ['a@m', 'b@m'], catalog: ['a@m'], profiles: { operator: null } };
  assert.ok(validateRegistry(bad).some((e) => /floor id "b@m" is missing from catalog/.test(e)));
});

test('validateRegistry requires the operator null sentinel', () => {
  const bad = { floor: ['a@m'], catalog: ['a@m'], profiles: { lane: { enable: [] } } };
  assert.ok(validateRegistry(bad).some((e) => /operator.*must be present and null/.test(e)));
});

test('only "operator" may be null — a null on another profile is rejected + never masquerades as operator', () => {
  const bad = { floor: ['a@m'], catalog: ['a@m'], profiles: { operator: null, 'lane-impl': null } };
  assert.ok(validateRegistry(bad).some((e) => /lane-impl.*only "operator" may be null/.test(e)));
  // resolveProfile recognizes operator BY NAME — a null non-operator profile does
  // NOT silently no-inject; it yields the lean floor map (never null).
  assert.equal(resolveProfile(bad, 'operator'), null);
  const r = resolveProfile(bad, 'lane-impl');
  assert.notEqual(r, null);
  assert.equal(r.enabledPlugins['a@m'], true); // floor still forced on
});

test('operator resolves to null even if the registry mistakenly gave it a spec', () => {
  const reg = { floor: ['a@m'], catalog: ['a@m', 'b@m'], profiles: { operator: { enable: ['b@m'] } } };
  assert.equal(resolveProfile(reg, 'operator'), null); // by name — never injected
});

test('operator + --add-plugins is REFUSED, and a malformed overlay still throws under operator', () => {
  // operator injects nothing, so an overlay cannot be honoured — refuse rather than
  // silently drop a capability the caller explicitly asked for.
  assert.throws(() => resolveProfile(REG, 'operator', { addPlugins: ['claude-obsidian@himmel'] }), /incompatible with --add-plugins/);
  // overlay validation runs BEFORE the operator return, so garbage is still caught
  assert.throws(() => resolveProfile(REG, 'operator', { addPlugins: ['garbage'] }), /not a valid plugin@marketplace/);
  assert.throws(() => resolveProfile(REG, 'operator', { addPlugins: ['a@m;rm'] }), /not a valid plugin@marketplace/);
  // operator with NO overlay is still the plain no-injection sentinel
  assert.equal(resolveProfile(REG, 'operator', { addPlugins: [] }), null);
});

test('validateRegistry collects errors (never throws) on malformed shapes', () => {
  // non-iterable floor/catalog, null profiles, missing keys, {} — each returns a
  // problem list, not a thrown TypeError.
  for (const bad of [{}, { floor: 5, catalog: 'x', profiles: null }, { floor: {}, catalog: {}, profiles: 7 }, null, undefined]) {
    const out = validateRegistry(bad);
    assert.ok(Array.isArray(out) && out.length > 0, `expected collected errors for ${JSON.stringify(bad)}`);
  }
});

test('user profile keeps content plugins but drops dev-authoring (HIMMEL-1044 shape)', () => {
  const { enabledPlugins: p } = resolveProfile(REG, 'user');
  // content a user wants
  assert.equal(p['superpowers@claude-plugins-official'], true);
  assert.equal(p['coderabbit@claude-plugins-official'], true);
  assert.equal(p['claude-obsidian@himmel'], true);
  // dev-authoring dropped
  assert.equal(p['skill-creator@claude-plugins-official'], false);
  assert.equal(p['plugin-dev@claude-plugins-official'], false);
  assert.equal(p['claude-md-management@claude-plugins-official'], false);
  assert.equal(p['hookify@claude-plugins-official'], false);
});
