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
  writeFileSync(good, JSON.stringify({ floor: ['a@m'], catalog: ['a@m', 'b@m'], profiles: { operator: null, bare: { enable: [], contextBudget: 5000 }, 'lane-impl': { enable: ['b@m'], contextBudget: 5000 } } }));
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

test('settings-template enabledPlugins mirrors the registry `user` profile (HIMMEL-1044 wiring)', () => {
  // The adopter-facing docs/setup/settings-template.json is the human-readable
  // mirror of the registry's `user` profile (HIMMEL-1040/1044). They are
  // hand-maintained and MUST NOT silently drift: if the template re-enables a
  // dev plugin the registry keeps off (or drops one it expects on) an adopter
  // gets the wrong set. This locks the two together so the drift that made
  // HIMMEL-1044 necessary cannot recur. ONE justified carve-out:
  // `codex@openai-codex` is enabled by the registry's `user` profile
  // explicitly (HIMMEL-1677 took it OUT of the floor so `lane-*` workers
  // disable it), but no adopter machine carries the codex marketplace — the
  // adopter template legitimately omits it. The lane spawn scripts only ever
  // resolve `lane-*` profiles (never `user`), so the `user` profile exists
  // purely as this template's source of truth.
  const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
  const tmpl = JSON.parse(readFileSync(join(REPO_ROOT, 'docs', 'setup', 'settings-template.json'), 'utf8'));
  const user = resolveProfile(REG, 'user').enabledPlugins;
  const LANE_ONLY = new Set(['codex@openai-codex']);
  // Forward: every plugin the adopter template has an opinion on must agree with
  // the registry's user profile (catches the template re-enabling a dev plugin).
  for (const [id, on] of Object.entries(tmpl.enabledPlugins)) {
    if (LANE_ONLY.has(id) || !Object.hasOwn(user, id)) continue;
    assert.equal(on, user[id], `template/registry drift on ${id}: template=${on} registry-user=${user[id]}`);
  }
  // Reverse: every plugin the registry enables for a user must also be enabled
  // in the adopter template (catches the template dropping a user plugin),
  // except lane-dispatch-only ids an adopter machine lacks.
  const tmplTrue = new Set(Object.entries(tmpl.enabledPlugins).filter(([, v]) => v).map(([k]) => k));
  for (const id of Object.keys(user).filter((k) => user[k])) {
    if (LANE_ONLY.has(id)) continue;
    assert.ok(tmplTrue.has(id), `registry user enables ${id} but the adopter template does not — drift`);
  }
});

// ── Schema (HIMMEL-1461 T2.1b): base / drop / disallowedTools / mcpCatalog / bare ──
// A synthetic registry, independent of the shipped data, so these tests pin the
// ORDER of operations rather than any particular catalog content.
const SCHEMA_REG = {
  floor: ['floor@m'],
  base: ['floor@m', 'base-only@m'],
  mcpCatalog: {},
  catalog: ['floor@m', 'base-only@m', 'dropped@m', 'enabled@m', 'overlay@m'],
  profiles: {
    operator: null,
    bare: { enable: [], contextBudget: 5000 },
    schema: { enable: ['enabled@m'], drop: ['base-only@m'], contextBudget: 5000 },
  },
};

test('resolution order: base -> drop -> enable -> overlay -> floor (last)', () => {
  const { enabledPlugins: p } = resolveProfile(SCHEMA_REG, 'schema', { addPlugins: ['overlay@m'] });
  assert.equal(p['base-only@m'], false, 'an id in base AND drop must end false — drop must apply after base');
  assert.equal(p['enabled@m'], true, 'profile.enable must apply');
  assert.equal(p['overlay@m'], true, 'the dispatch overlay must apply');
  assert.equal(p['floor@m'], true, 'the floor must be on');
  assert.equal(p['dropped@m'], false, 'an untouched catalog id stays denied by default');
});

test('the dispatch overlay overrides a profile drop — overlay applies AFTER drop', () => {
  const { enabledPlugins: p } = resolveProfile(SCHEMA_REG, 'schema', { addPlugins: ['base-only@m'] });
  assert.equal(p['base-only@m'], true, 'an explicit --add-plugins ask must win over a profile drop');
});

test('the floor survives a drop naming a floor id — floor is forced true LAST regardless of validity', () => {
  // validateRegistry rejects a floor id in drop (below); this proves the
  // RESOLVER's floor-forced-last guarantee holds at resolve time too — nothing,
  // not even a mis-declared drop, can turn the floor off.
  const evil = { ...SCHEMA_REG, profiles: { ...SCHEMA_REG.profiles, evil: { enable: [], drop: ['floor@m'] } } };
  const { enabledPlugins: p } = resolveProfile(evil, 'evil');
  assert.equal(p['floor@m'], true);
});

test('"bare" skips base and resolves to floor-only, but still honours --add-plugins', () => {
  const { enabledPlugins: p } = resolveProfile(SCHEMA_REG, 'bare');
  assert.equal(p['floor@m'], true);
  assert.equal(p['base-only@m'], false, 'bare must NOT inherit base');
  const overlaid = resolveProfile(SCHEMA_REG, 'bare', { addPlugins: ['overlay@m'] });
  assert.equal(overlaid.enabledPlugins['overlay@m'], true, 'bare still honours the dispatch overlay — that is its purpose');
});

test('CLI: node plugin-profiles.mjs bare prints exactly the three shipped floor ids as true', () => {
  // Sandboxed HOME/cwd (glm-3): the CLI now calls readEnabledPluginIds, which
  // throws on an unparseable settings layer — running against the real dev
  // machine's HOME/cwd would make this test's pass/fail depend on whatever
  // happens to be on that machine. Point it at a clean tmpdir fixture instead,
  // the same pattern the codex-adv-1 regression test below already uses.
  const cli = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin-profiles.mjs');
  const home = mkdtempSync(join(tmpdir(), 'pp-cli-bare-home-'));
  const cwd = mkdtempSync(join(tmpdir(), 'pp-cli-bare-cwd-'));
  const run = spawnSync(process.execPath, [cli, 'bare'], {
    encoding: 'utf8',
    cwd,
    env: { ...process.env, HOME: home, USERPROFILE: home },
  });
  assert.equal(run.status, 0, run.stderr);
  const p = JSON.parse(run.stdout).enabledPlugins;
  const trueKeys = Object.keys(p).filter((k) => p[k]).sort();
  assert.deepEqual(trueKeys, [...FLOOR].sort());
});

test('CLI: --list includes bare', () => {
  const cli = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin-profiles.mjs');
  const run = spawnSync(process.execPath, [cli, '--list'], { encoding: 'utf8' });
  assert.equal(run.status, 0);
  assert.ok(run.stdout.split('\n').includes('bare'));
});

test('CLI: --validate exits 0 on the shipped registry', () => {
  const cli = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin-profiles.mjs');
  const run = spawnSync(process.execPath, [cli, '--validate'], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
});

test('lane-review carries disallowedTools; every other shipped profile does not', () => {
  assert.deepEqual(REG.profiles['lane-review'].disallowedTools, ['Write', 'Edit', 'NotebookEdit']);
  for (const name of ['user', 'lane-impl', 'lane-content', 'bare']) {
    assert.equal(REG.profiles[name]?.disallowedTools, undefined, `${name} must not carry disallowedTools`);
  }
});

test('validateRegistry: base, when present, must be an array of valid, cataloged ids', () => {
  assert.ok(validateRegistry({ ...SCHEMA_REG, base: 'not-an-array' }).some((e) => /base must be an array/.test(e)));
  assert.ok(validateRegistry({ ...SCHEMA_REG, base: ['not-an-id'] }).some((e) => /base id "not-an-id" is not a valid/.test(e)));
  assert.ok(validateRegistry({ ...SCHEMA_REG, base: ['missing@m'] }).some((e) => /base id "missing@m" is missing from catalog/.test(e)));
});

test('validateRegistry: mcpCatalog shape + $VAR-reference rule (a literal is a credential leak)', () => {
  assert.ok(validateRegistry({ ...SCHEMA_REG, mcpCatalog: null }).some((e) => /mcpCatalog must be a non-null object/.test(e)));
  assert.ok(validateRegistry({ ...SCHEMA_REG, mcpCatalog: { x: 'nope' } }).some((e) => /mcpCatalog entry "x" must be an object/.test(e)));
  assert.ok(validateRegistry({ ...SCHEMA_REG, mcpCatalog: { x: { env: { TOKEN: 'sk-literal-secret' } } } }).some((e) => /mcpCatalog entry "x" env\.TOKEN must be a \$VAR reference/.test(e)));
  assert.deepEqual(validateRegistry({ ...SCHEMA_REG, mcpCatalog: { x: { env: { TOKEN: '$TOKEN' }, headers: { Authorization: '$AUTH_HEADER' } } } }), []);
});

test('validateRegistry: a profile naming an id in both drop and enable is an error', () => {
  const bad = { ...SCHEMA_REG, profiles: { ...SCHEMA_REG.profiles, both: { enable: ['enabled@m'], drop: ['enabled@m'] } } };
  assert.ok(validateRegistry(bad).some((e) => /"both" drop id "enabled@m" is also in enable/.test(e)));
});

test('validateRegistry: a profile naming a floor id in drop is an error', () => {
  const bad = { ...SCHEMA_REG, profiles: { ...SCHEMA_REG.profiles, evil: { enable: [], drop: ['floor@m'] } } };
  assert.ok(validateRegistry(bad).some((e) => /"evil" drop id "floor@m" is a floor id/.test(e)));
});

test('validateRegistry: every drop id must be valid per ID_RE and present in catalog', () => {
  assert.ok(validateRegistry({ ...SCHEMA_REG, profiles: { ...SCHEMA_REG.profiles, bad1: { enable: [], drop: ['not-an-id'] } } }).some((e) => /"bad1" drop id "not-an-id" is not a valid/.test(e)));
  assert.ok(validateRegistry({ ...SCHEMA_REG, profiles: { ...SCHEMA_REG.profiles, bad2: { enable: [], drop: ['missing@m'] } } }).some((e) => /"bad2" drop id "missing@m" is missing from catalog/.test(e)));
});

test('validateRegistry: disallowedTools must be an array of non-empty strings', () => {
  assert.ok(validateRegistry({ ...SCHEMA_REG, profiles: { ...SCHEMA_REG.profiles, bad: { enable: [], disallowedTools: 'Write' } } }).some((e) => /"bad" disallowedTools must be an array of non-empty strings/.test(e)));
  assert.ok(validateRegistry({ ...SCHEMA_REG, profiles: { ...SCHEMA_REG.profiles, bad: { enable: [], disallowedTools: [''] } } }).some((e) => /"bad" disallowedTools must be an array of non-empty strings/.test(e)));
  assert.deepEqual(validateRegistry({ ...SCHEMA_REG, profiles: { ...SCHEMA_REG.profiles, ok: { enable: [], disallowedTools: ['Write'], contextBudget: 5000 } } }), []);
});

test('validateRegistry: contextBudget is required on every non-operator profile and must be a positive integer', () => {
  const { contextBudget, ...noBudget } = SCHEMA_REG.profiles.schema;
  assert.ok(validateRegistry({ ...SCHEMA_REG, profiles: { ...SCHEMA_REG.profiles, schema: noBudget } }).some((e) => /"schema" contextBudget must be a positive integer/.test(e)), 'missing contextBudget must error');
  for (const bad of [0, -1, 1.5, '5000', null]) {
    assert.ok(validateRegistry({ ...SCHEMA_REG, profiles: { ...SCHEMA_REG.profiles, schema: { ...noBudget, contextBudget: bad } } }).some((e) => /"schema" contextBudget must be a positive integer/.test(e)), `contextBudget ${JSON.stringify(bad)} must error`);
  }
  assert.deepEqual(validateRegistry({ ...SCHEMA_REG, profiles: { ...SCHEMA_REG.profiles, schema: { ...noBudget, contextBudget: 5000 } } }), []);
});

test('validateRegistry: the shipped registry\'s non-operator profiles all carry a positive-integer contextBudget', () => {
  for (const [name, spec] of Object.entries(REG.profiles)) {
    if (spec === null) continue; // operator
    assert.ok(Number.isInteger(spec.contextBudget) && spec.contextBudget > 0, `${name} must carry a positive-integer contextBudget`);
  }
});

test('absent drop/disallowedTools on an existing profile is a clean no-op', () => {
  assert.deepEqual(validateRegistry(SCHEMA_REG), []);
  const p = resolveProfile(SCHEMA_REG, 'schema');
  assert.equal(p.enabledPlugins['enabled@m'], true);
  assert.equal(p.enabledPlugins['floor@m'], true);
});

test('base is OPTIONAL (absent -> clean; a custom pre-upgrade registry must not hard-fail)', () => {
  const { base, ...noBase } = SCHEMA_REG;
  assert.deepEqual(validateRegistry(noBase), []);
  // resolve-time: absent base behaves as [] — nothing base-only ends up on
  const p = resolveProfile(noBase, 'schema');
  assert.equal(p.enabledPlugins['base-only@m'], false);
});

test('mcpCatalog is OPTIONAL (absent -> clean); a present-but-malformed one still errors', () => {
  const { mcpCatalog, ...noMcp } = SCHEMA_REG;
  assert.deepEqual(validateRegistry(noMcp), []);
  assert.ok(validateRegistry({ ...noMcp, mcpCatalog: 'nope' }).some((e) => /mcpCatalog must be a non-null object/.test(e)));
});

test('validateRegistry: base contains duplicate ids is an error', () => {
  assert.ok(validateRegistry({ ...SCHEMA_REG, base: ['floor@m', 'floor@m'] }).some((e) => /base contains duplicate ids/.test(e)));
});

test('validateRegistry: mcpCatalog url/command/args reject malformed $-interpolation and obvious secret shapes; plain literals are fine', () => {
  // plain literals — no $ at all — are fine, including a bare URL
  assert.deepEqual(validateRegistry({ ...SCHEMA_REG, mcpCatalog: { x: { command: 'npx', args: ['-y', '@foo/bar'], url: 'http://localhost:8181/mcp' } } }), []);
  // an embedded bare $VAR reference inside a larger literal is fine
  assert.deepEqual(validateRegistry({ ...SCHEMA_REG, mcpCatalog: { x: { url: 'https://$HOST:$PORT/mcp' } } }), []);
  // malformed interpolation
  assert.ok(validateRegistry({ ...SCHEMA_REG, mcpCatalog: { x: { command: '${TOKEN}' } } }).some((e) => /mcpCatalog entry "x" command contains a malformed \$-interpolation/.test(e)));
  // an obvious secret shape embedded in a literal
  assert.ok(validateRegistry({ ...SCHEMA_REG, mcpCatalog: { x: { args: ['--token', 'sk-abcdefghijklmnop'] } } }).some((e) => /mcpCatalog entry "x" args\[1\] looks like it contains an embedded credential literal/.test(e)));
  // args must be an array of strings
  assert.ok(validateRegistry({ ...SCHEMA_REG, mcpCatalog: { x: { args: 'nope' } } }).some((e) => /mcpCatalog entry "x" args must be an array of strings/.test(e)));
});

test('validateRegistry: mcpCatalog url/command/args — ordinary filesystem paths validate clean (regression: the generic base64/hex-blob heuristic false-positived on POSIX paths, dropped)', () => {
  assert.deepEqual(validateRegistry({
    ...SCHEMA_REG,
    mcpCatalog: {
      x: {
        command: '/usr/local/lib/nodemodules/someserver/dist/index.js',
        args: ['/home/user/documents/mcpservers/server.js', 'C:/Users/user/Documents/github/himmel/scripts/x.js'],
      },
    },
  }), []);
});

test('regression (finding 1, codex-adv-1): the CLI passes opts.installed so "bare" is floor-only even with an uncatalogued plugin enabled on the machine', () => {
  const cli = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin-profiles.mjs');
  const home = mkdtempSync(join(tmpdir(), 'pp-cli-home-'));
  const cwd = mkdtempSync(join(tmpdir(), 'pp-cli-cwd-'));
  mkdirSync(join(home, '.claude'), { recursive: true });
  writeFileSync(join(home, '.claude', 'settings.json'), JSON.stringify({ enabledPlugins: { 'sneaky@somewhere': true } }));
  const run = spawnSync(process.execPath, [cli, 'bare'], {
    encoding: 'utf8',
    cwd,
    env: { ...process.env, HOME: home, USERPROFILE: home },
  });
  assert.equal(run.status, 0, run.stderr);
  const p = JSON.parse(run.stdout).enabledPlugins;
  assert.equal(p['sneaky@somewhere'], false, 'an uncatalogued plugin enabled on the machine must not leak into bare via the CLI');
});

test('regression (finding 2, codex-adv-2): validateRegistry rejects a non-empty bare.enable — the floor-only invariant is enforced, not just asserted', () => {
  const bad = { ...REG, profiles: { ...REG.profiles, bare: { enable: ['coderabbit@claude-plugins-official'] } } };
  const errs = validateRegistry(bad);
  assert.ok(errs.some((e) => /"bare" enable must be empty/.test(e)));
  // the same mis-edit resolved by hand (bypassing the validator) really would
  // have leaked the plugin — this is exactly what the validator now blocks
  const leaked = resolveProfile(bad, 'bare');
  assert.equal(leaked.enabledPlugins['coderabbit@claude-plugins-official'], true);
});

test('validateRegistry: "bare" is OPTIONAL — a registry with no bare key validates clean (glm-1: presence must not hard-fail a pre-existing custom registry)', () => {
  const { bare, ...noBare } = REG.profiles;
  assert.deepEqual(validateRegistry({ ...REG, profiles: noBare }), []);
});

test('validateRegistry: "bare", when present, must not declare a non-empty enable, drop, or disallowedTools', () => {
  assert.ok(validateRegistry({ ...REG, profiles: { ...REG.profiles, bare: { enable: [], drop: [] } } }).some((e) => /"bare" must not declare drop/.test(e)));
  assert.ok(validateRegistry({ ...REG, profiles: { ...REG.profiles, bare: { enable: [], disallowedTools: ['Write'] } } }).some((e) => /"bare" must not declare disallowedTools/.test(e)));
});

// ── Golden baseline (HIMMEL-1461 T2.1a) ─────────────────────────────────────
// Pins what the CURRENT resolver produces for every shipped profile, so a
// later registry-schema change is provably resolution-preserving. REGISTRY_PATH
// is passed POSITIONALLY, not via PLUGIN_PROFILES_REGISTRY: that env var is
// read once at module load and ESM imports are hoisted, so setting it in this
// file would land after evaluation and be silently ignored — the generator
// would then read the real registry while claiming to be pinned.
// "bare" included (glm-4): its resolution is deterministic under the golden's
// explicit { installed: [] }, and pinning floor-only here turns any future
// regression of the floor-only promise into a golden diff.
const REGISTRY_PATH = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin-profiles.json');
const GOLDEN_PROFILES = ['operator', 'user', 'lane-impl', 'lane-review', 'lane-content', 'bare'];
const GOLDEN_FIXTURE = join(dirname(fileURLToPath(import.meta.url)), 'fixtures', 'golden-profiles.json');

test('golden baseline — resolveProfile output for shipped profiles is pinned (HIMMEL-1461 T2.1a)', () => {
  // installed: [] — omitting it would make the result depend on the machine's
  // live plugin universe and the fixture would go red on every other clone.
  const registry = loadRegistry(REGISTRY_PATH);
  const actual = {};
  for (const name of GOLDEN_PROFILES) actual[name] = resolveProfile(registry, name, { installed: [] });

  // Regenerate with: PLUGIN_PROFILES_UPDATE_GOLDEN=1 node --test scripts/lanes/tests/plugin-profiles.test.mjs
  if (process.env.PLUGIN_PROFILES_UPDATE_GOLDEN) {
    writeFileSync(GOLDEN_FIXTURE, JSON.stringify(actual, null, 2) + '\n');
  }

  // deepEqual, never a JSON.stringify comparison — key order is not part of
  // the contract this fixture pins.
  const expected = JSON.parse(readFileSync(GOLDEN_FIXTURE, 'utf8'));
  assert.deepEqual(actual, expected);
});
