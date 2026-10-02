// HIMMEL-4021: profile ceilings must reach the launchers; malformed input refuses.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import * as PP from '../plugin-profiles.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '../../..');
const registry = () => ({
  floor: ['qmd@himmel'], catalog: ['qmd@himmel'], profiles: {
    operator: null,
    'leg-impl': { enable: [], contextBudget: 35000, contextMode: 'standard', autocompact: 200000 },
    console: { enable: [], contextBudget: 50000, contextMode: 'standard', autocompact: 200000 },
    design: { enable: [], contextBudget: 50000, contextMode: '1m', autocompact: 400000 },
  },
});
function fixture(t, reg = registry()) {
  const dir = mkdtempSync(join(tmpdir(), 'profile-ceiling-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  mkdirSync(join(dir, 'config'));
  mkdirSync(join(dir, 'handovers'));
  writeFileSync(join(dir, 'registry.json'), JSON.stringify(reg));
  writeFileSync(join(dir, 'brief.md'), '# Hermetic fixture\n');
  return { dir, env: { PATH: process.env.PATH, HOME: dir, CLAUDE_CONFIG_DIR: join(dir, 'config'),
    PLUGIN_PROFILES_REGISTRY: join(dir, 'registry.json'), HANDOVER_DIR: join(dir, 'handovers'),
    LEG_REPO: dir, HEADED_ARM_REPO: dir, HIMMELCTL_CACHE_DIR: join(dir, 'cache'),
    HIMMEL_DENIAL_ACK_DIR: join(dir, 'acks'), XDG_RUNTIME_DIR: dir } };
}
function launch(f, profile, extra = {}) {
  return spawnSync('bash', [join(ROOT, 'scripts/handover/console-kit/headed-arm-leg.sh'),
    '--dry-run', '--profile', profile, 'HIMMEL-4021-fixture', join(f.dir, 'brief.md'),
    join(f.dir, 'signal'), '99999999999', join(f.dir, 'launch.log'), 'claude-sonnet-5-5'],
  { cwd: f.dir, env: { ...f.env, ...extra }, encoding: 'utf8', timeout: 20000 });
}

test('context resolver keeps legacy defaults without widening settings JSON', () => {
  const r = registry();
  delete r.profiles['leg-impl'].autocompact;
  delete r.profiles['leg-impl'].contextMode;
  assert.equal(typeof PP.contextForProfile, 'function');
  assert.deepEqual(PP.contextForProfile(r, 'leg-impl'), { contextMode: 'standard', autocompact: 200000 });
  assert.deepEqual(PP.contextForProfile(r, 'operator'), { contextMode: 'standard', autocompact: 200000 });
  assert.deepEqual(PP.resolveProfile(r, 'leg-impl'), { enabledPlugins: { 'qmd@himmel': true } });
});
test('composed profile ceiling takes the explicitly declared 1m member', () => {
  assert.equal(typeof PP.contextForProfile, 'function');
  assert.deepEqual(PP.contextForProfile(registry(), 'leg-impl,design'), { contextMode: '1m', autocompact: 400000 });
  assert.throws(() => PP.contextForProfile(registry(), 'missing'));
  assert.throws(() => PP.contextForProfile(registry(), 'constructor'));
});
for (const [field, value] of [['autocompact', '400000'], ['autocompact', 200001],
  ['autocompact', 199999], ['autocompact', null], ['autocompact', 200000.5], ['contextMode', 'auto'], ['contextMode', null]]) {
  test(`validator refuses unsafe standard ${field}=${JSON.stringify(value)}`, () => {
    const r = registry(); r.profiles['leg-impl'][field] = value;
    assert.ok(PP.validateRegistry(r).some((e) => e.includes(field)), 'invalid context field was accepted');
  });
}
test('leg launcher reads standard ceiling from the profile', (t) => {
  const result = launch(fixture(t), 'leg-impl');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /autocompact=200000/);
});
test('leg launcher reads a numeric design ceiling rather than hard-coding auto', (t) => {
  const result = launch(fixture(t), 'design');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /autocompact=400000/);
});
test('bare LEG_CONTEXT=1m on a standard profile remains refused', (t) => {
  const result = launch(fixture(t), 'leg-impl', { LEG_CONTEXT: '1m' });
  assert.equal(result.status, 2, result.stdout + result.stderr);
});
test('leg launcher refuses malformed autocompact even on dry-run', (t) => {
  const r = registry(); r.profiles.design.autocompact = '400000';
  const result = launch(fixture(t, r), 'design');
  assert.equal(result.status, 2, result.stdout + result.stderr);
  assert.match(result.stderr, /autocompact/);
});
test('headed console launcher validates the profile before rendering argv', (t) => {
  const r = registry(); r.profiles.console.autocompact = '200000';
  const f = fixture(t, r);
  const result = spawnSync('bash', [join(ROOT, 'scripts/handover/headed-arm.sh'), '--dry-run',
    'HIMMEL-4021-console-fixture', join(f.dir, 'brief.md'), join(f.dir, 'signal'),
    '99999999999', join(f.dir, 'launch.log')], { cwd: f.dir, env: f.env, encoding: 'utf8' });
  assert.equal(result.status, 2, result.stdout + result.stderr);
  assert.match(result.stderr, /autocompact/);
});
