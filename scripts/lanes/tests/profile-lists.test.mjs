// scripts/lanes/tests/profile-lists.test.mjs
// HIMMEL-4014 — composable --profile lists: `a,b` resolves to the union of the members.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { resolveProfile, mcpServersForProfile, loadListingLib } from '../plugin-profiles.mjs';
import { ROLE_REQUIRES } from '../role-requires.mjs';

const REG = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin-profiles.json'), 'utf8'));
const on = (s) => Object.entries(s.enabledPlugins).filter(([, v]) => v).map(([k]) => k).sort();

test('HIMMEL-4014: design,design-motion enables the union of both members', () => {
  const a = on(resolveProfile(REG, 'design'));
  const b = on(resolveProfile(REG, 'design-motion'));
  const both = on(resolveProfile(REG, 'design,design-motion'));
  assert.deepEqual(both, [...new Set([...a, ...b])].sort());
  for (const id of ROLE_REQUIRES['design-motion']) assert.ok(both.includes(id), id);
  for (const id of ROLE_REQUIRES.design) assert.ok(both.includes(id), id);
});

test('HIMMEL-4014: member order does not change the result', () => {
  assert.deepEqual(resolveProfile(REG, 'design-motion,design').enabledPlugins, resolveProfile(REG, 'design,design-motion').enabledPlugins);
});

test('HIMMEL-4014: one member dropping a plugin never turns off another member that enables it', () => {
  const reg = structuredClone(REG);
  const id = reg.base.find((b) => !reg.floor.includes(b));
  reg.profiles.__drops = { drop: [id] };
  reg.profiles.__keeps = { enable: [] };
  assert.equal(resolveProfile(reg, '__drops').enabledPlugins[id], false);
  assert.equal(resolveProfile(reg, '__drops,__keeps').enabledPlugins[id], true);
});

test('HIMMEL-4014: the floor stays on in a list', () => {
  const s = resolveProfile(REG, 'design,design-motion');
  for (const id of REG.floor) assert.equal(s.enabledPlugins[id], true, id);
});

test('HIMMEL-4014: a one-name call is unchanged by composition support', () => {
  assert.deepEqual(resolveProfile(REG, 'design-motion'), resolveProfile(REG, 'design-motion', {}));
  assert.ok(!('skillOverrides' in resolveProfile(REG, 'design-motion')));
});

test('HIMMEL-4014: gateAllow permissions are the de-duplicated union', () => {
  const s = resolveProfile(REG, 'leg-impl,design');
  assert.deepEqual(s.permissions.allow, [...new Set(s.permissions.allow)]);
  for (const rule of REG.gateAllow) assert.ok(s.permissions.allow.includes(rule), rule);
});

for (const bad of ['operator,design', 'design,bare', 'design,console', 'design,console-relay', 'console-judge,design']) {
  test(`HIMMEL-4014: refuses a role/non-additive profile in a list (${bad})`, () => {
    assert.throws(() => resolveProfile(REG, bad), /cannot be composed/);
  });
}

for (const bad of ['design,', ',design', 'design,,design-motion', 'design,design', 'design, design-motion']) {
  test(`HIMMEL-4014: refuses a malformed list (${JSON.stringify(bad)})`, () => {
    assert.throws(() => resolveProfile(REG, bad), /profile list/);
  });
}

test('HIMMEL-4014: an unknown member fails closed with the unknown-profile error', () => {
  assert.throws(() => resolveProfile(REG, 'design,nope'), /unknown profile "nope"/);
});

test('HIMMEL-4014/4401: composed mcpServers refuses differing allowlists, keeps identical or the one declared', () => {
  const reg = structuredClone(REG);
  reg.profiles.__m1 = { enable: [], mcpServers: ['qmd'] };
  reg.profiles.__m2 = { enable: [], mcpServers: ['qmd', 'context7'] };
  reg.profiles.__m3 = { enable: [] };
  assert.throws(() => mcpServersForProfile(reg, '__m1,__m2'), /different mcpServers allowlists.*__m1.*__m2/s);
  // a member with no allowlist never widens another member's list to "all servers"
  assert.deepEqual(mcpServersForProfile(reg, '__m1,__m3'), ['qmd']);
  assert.deepEqual(mcpServersForProfile(reg, '__m3,__m1'), ['qmd']);
  reg.profiles.__m4 = { enable: [] };
  assert.equal(mcpServersForProfile(reg, '__m3,__m4'), undefined);
  // an explicit [] is a declared strip-everything allowlist: differing from ['qmd'] refuses
  reg.profiles.__m5 = { enable: [], mcpServers: [] };
  assert.throws(() => mcpServersForProfile(reg, '__m1,__m5'), /different mcpServers allowlists/);
});

test('HIMMEL-4014: the --mcp-servers list path refuses duplicate members like resolveProfile', () => {
  assert.throws(() => mcpServersForProfile(REG, 'design,design'), /malformed profile list/);
});

for (const bad of ['operator', 'bare', 'console', 'console-relay', 'console-judge']) {
  test(`HIMMEL-4014: the --mcp-servers list path refuses a non-additive member (${bad})`, () => {
    assert.throws(() => mcpServersForProfile(REG, `design,${bad}`), /cannot be composed/);
  });
}

test('HIMMEL-4014: skill listing runs once over the union of required ids', async () => {
  await loadListingLib();
  const entries = [
    { scope: 'plugin-skills', name: 'a', path: '/x/emilkowalski-skills/a/SKILL.md', countedRoutingChars: 400 },
    { scope: 'plugin-skills', name: 'b', path: '/x/impeccable/b/SKILL.md', countedRoutingChars: 400 },
  ];
  const s = resolveProfile(REG, 'design,design-motion', { skillEntries: entries });
  assert.ok(s.skillListingBudgetFraction >= 0.01);
  assert.equal(typeof s.skillOverrides, 'object');
});
