// scripts/lanes/tests/domain-modeling-plugin.test.mjs
// domain-modeling ships as ONE himmel marketplace plugin, vendored at a pinned
// upstream commit, enabled in exactly one profile (design) and no other.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { loadRegistry, resolveProfile } from '../plugin-profiles.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const REG_PATH = join(ROOT, 'scripts', 'lanes', 'plugin-profiles.json');
const REG = JSON.parse(readFileSync(REG_PATH, 'utf8'));
const MP = JSON.parse(readFileSync(join(ROOT, 'marketplace', '.claude-plugin', 'marketplace.json'), 'utf8'));
const PLUGIN = join(ROOT, 'marketplace', 'plugins', 'domain-modeling');
const ID = 'domain-modeling@himmel';
const PIN = '49dd158d1076134a641b33efb035946536778336';

test('domain-modeling@himmel is enabled by the design profile and no other profile, base or floor', () => {
  assert.ok(!REG.base.includes(ID), 'base would put it in every leg');
  assert.ok(!REG.floor.includes(ID), 'floor would put it in every leg');
  const on = Object.entries(REG.profiles).filter(([, p]) => (p?.enable ?? []).includes(ID)).map(([n]) => n);
  assert.deepEqual(on, ['design']);
  assert.ok(REG.catalog.includes(ID), 'catalog must list it so other profiles resolve it false');
});

test('resolver output lists it on for design and off for every other profile', () => {
  const registry = loadRegistry(REG_PATH);
  for (const name of Object.keys(REG.profiles).filter((n) => REG.profiles[n])) {
    const enabled = resolveProfile(registry, name, { installed: [] }).enabledPlugins[ID];
    assert.equal(enabled === true, name === 'design', `${name}: ${ID} = ${enabled}`);
  }
});

test('marketplace entry is a local MIT plugin whose VENDORED.md names the pinned upstream commit', () => {
  const e = MP.plugins.find((x) => x.name === 'domain-modeling');
  assert.ok(e, 'domain-modeling missing from marketplace.json');
  assert.equal(e.source, './plugins/domain-modeling');
  assert.equal(e.license, 'MIT');
  assert.ok(existsSync(PLUGIN), 'plugin dir missing');
  const vendored = readFileSync(join(PLUGIN, 'VENDORED.md'), 'utf8');
  assert.ok(vendored.includes(PIN), 'VENDORED.md must carry the pinned sha');
  assert.ok(vendored.includes('mattpocock/skills'), 'VENDORED.md must name the upstream repo');
  assert.equal(JSON.parse(readFileSync(join(PLUGIN, '.claude-plugin', 'plugin.json'), 'utf8')).version, '0.1.0');
});

test('the skill moved out of .claude/skills and keeps its vendored header', () => {
  assert.ok(!existsSync(join(ROOT, '.claude', 'skills', 'domain-modeling')), 'project copy must be gone');
  const text = readFileSync(join(PLUGIN, 'skills', 'domain-modeling', 'SKILL.md'), 'utf8');
  assert.ok(text.includes(PIN), 'header names the pin');
  assert.match(text, /Deviations from upstream/);
  assert.ok(existsSync(join(PLUGIN, 'skills', 'domain-modeling', 'GLOSSARY-FORMAT.md')));
});

test('the plugin ships no hooks, agents, commands, MCP servers or scripts', () => {
  for (const d of ['hooks', 'agents', 'commands', '.mcp.json', 'scripts']) assert.ok(!existsSync(join(PLUGIN, d)), `${d} must not exist`);
});

test('the plugin carries upstream LICENSE and a README documenting one-step removal', () => {
  assert.match(readFileSync(join(PLUGIN, 'LICENSE'), 'utf8'), /Copyright \(c\) 2026 Matt Pocock/);
  const readme = readFileSync(join(PLUGIN, 'README.md'), 'utf8');
  assert.match(readme, /plugin disable domain-modeling@himmel/);
  assert.match(readme, /plugin uninstall domain-modeling@himmel/);
});
