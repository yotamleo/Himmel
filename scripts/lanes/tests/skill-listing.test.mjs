// scripts/lanes/tests/skill-listing.test.mjs
// HIMMEL-4038 — per-profile skillOverrides (non-plugin skills name-only) and a
// computed skillListingBudgetFraction. Pure functions + the resolver hook; no
// live claude spawn (the measured half lives in profile-context-probe.mjs).
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, symlinkSync } from 'node:fs';
import { scanCommandTrees } from '../skill-cost.mjs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  skillListingSettings, DEFAULT_FRACTION, MAX_FRACTION, BUILTIN_SKILL_NAMES,
} from '../skill-listing.mjs';
import { resolveProfile, loadListingLib } from '../plugin-profiles.mjs';

await loadListingLib();

const plugin = (name, routing, p = name) => ({
  scope: 'plugin-skills', name, countedRoutingChars: routing, chars: name.length + 2 + routing,
  path: `/h/.claude/plugins/cache/himmel/${p}/1.0/skills/${name}/SKILL.md`,
});
const user = (name, routing = 300) => ({ scope: 'user-skills', name, countedRoutingChars: routing, chars: name.length + 2 + routing, path: `/h/.claude/skills/${name}/SKILL.md` });
const cmd = (name) => ({ scope: 'project-commands', name, countedRoutingChars: 80, chars: name.length + 82, path: `/r/.claude/commands/${name}.md` });

test('skillOverrides: every non-plugin skill and command is name-only, plugin skills are not listed', () => {
  const s = skillListingSettings({
    entries: [user('find-docs'), cmd('worktree'), plugin('impeccable', 400)],
    enabledIds: ['impeccable@himmel'], requiredIds: ['impeccable@himmel'],
  });
  assert.equal(s.skillOverrides['find-docs'], 'name-only');
  assert.equal(s.skillOverrides.worktree, 'name-only');
  assert.equal(Object.hasOwn(s.skillOverrides, 'impeccable'), false);
  assert.equal(s.skillOverrides['update-config'], 'name-only'); // a bundled skill
  assert.ok(BUILTIN_SKILL_NAMES.includes('update-config'));
});

test('fraction: sized on the UNSHRUNK enabled plugin skills (overrides do not help plugin skills), floor 0.01, 3 decimals', () => {
  const big = [plugin('a', 4000, 'p1'), plugin('b', 4000, 'p1'), plugin('c', 4000, 'p2')];
  const s = skillListingSettings({ entries: big, enabledIds: ['p1@himmel', 'p2@himmel'], requiredIds: ['p1@himmel'] });
  // each ~ (1+2+4000+3)/4 = 1002 tok -> 3006 plus name-only tokens and the unscanned reserve, over 200k
  assert.ok(s.skillListingBudgetFraction > 0.015 && s.skillListingBudgetFraction < 0.03, String(s.skillListingBudgetFraction));
  assert.equal(s.skillListingBudgetFraction, Math.ceil(s.skillListingBudgetFraction * 1000) / 1000);
  const small = skillListingSettings({ entries: [plugin('a', 10, 'p1')], enabledIds: ['p1@himmel'], requiredIds: ['p1@himmel'] });
  assert.ok(small.skillListingBudgetFraction >= DEFAULT_FRACTION && small.skillListingBudgetFraction < 0.02);
});

test('fraction: skills of a plugin that is NOT enabled in the profile do not count', () => {
  const entries = [plugin('a', 4000, 'p1'), plugin('z', 40000, 'other')];
  const s = skillListingSettings({ entries, enabledIds: ['p1@himmel'], requiredIds: ['p1@himmel'] });
  assert.ok(s.skillListingBudgetFraction < 0.03, String(s.skillListingBudgetFraction));
});

test('fraction above the 0.05 sanity cap is refused, not emitted', () => {
  const entries = Array.from({ length: 20 }, (_, i) => plugin(`s${i}`, 1500, 'p1'));
  assert.equal(MAX_FRACTION, 0.05);
  assert.throws(() => skillListingSettings({ entries, enabledIds: ['p1@himmel'], requiredIds: ['p1@himmel'], window: 200000 / 2 }), /exceeds the 0\.05 sanity cap/);
});

// HIMMEL-4060 item 1: the plugin match is the plugin-cache DIRECTORY COMPONENT.
test('fraction: a skill DIRECTORY named like an enabled plugin does not count toward that plugin', () => {
  const decoy = { ...plugin('p1', 40000, 'other'), path: '/h/.claude/plugins/cache/himmel/other/1.0/skills/p1/SKILL.md' };
  const s = skillListingSettings({ entries: [plugin('a', 10, 'p1'), decoy], enabledIds: ['p1@himmel'], requiredIds: ['p1@himmel'] });
  assert.ok(s.skillListingBudgetFraction < 0.02, String(s.skillListingBudgetFraction));
});

// HIMMEL-4060 item 5: the unscanned reserve is a scan of skills-dir command trees.
const tmpDirs = [];
after(() => { for (const d of tmpDirs) rmSync(d, { recursive: true, force: true }); });
const mkConfigDir = (trees) => {
  const dir = mkdtempSync(join(tmpdir(), 'skill-listing-'));
  tmpDirs.push(dir);
  mkdirSync(join(dir, 'skills'), { recursive: true });
  for (const [tree, files] of Object.entries(trees)) {
    mkdirSync(join(dir, 'skills', tree, 'commands'), { recursive: true });
    for (const [f, body] of Object.entries(files)) writeFileSync(join(dir, 'skills', tree, 'commands', f), body);
  }
  return dir;
};
const bigCmds = Object.fromEntries(Array.from({ length: 40 }, (_, i) => [`c${i}.md`, `---\ndescription: ${'x'.repeat(600)}\n---\nbody\n`]));
const base = { entries: [plugin('a', 10, 'p1')], enabledIds: ['p1@himmel'], requiredIds: ['p1@himmel'] };

test('reserve: scanned command trees raise the fraction above the fixed-constant result', () => {
  const scanned = skillListingSettings({ ...base, configDir: mkConfigDir({ big: bigCmds }) });
  const fixed = skillListingSettings(base);
  assert.ok(scanned.skillListingBudgetFraction > fixed.skillListingBudgetFraction, `${scanned.skillListingBudgetFraction} vs ${fixed.skillListingBudgetFraction}`);
});

test('reserve: an empty skills dir shrinks the reserve below the fixed constant', () => {
  const none = skillListingSettings({ ...base, configDir: mkConfigDir({}) });
  assert.ok(none.skillListingBudgetFraction < skillListingSettings(base).skillListingBudgetFraction);
});

test('reserve: an unscannable configDir falls back to the fixed constant', () => {
  assert.deepEqual(skillListingSettings({ ...base, configDir: '/nonexistent/claude-config-4060' }), skillListingSettings(base));
});

// HIMMEL-4064 item 2: a command tree path the scan could not read is reported, as scanSkillCosts does.
test('scanCommandTrees: a skipped (ELOOP) command path lands in the caller\'s skipped array, entries still returned', () => {
  const dir = mkConfigDir({ t: { 'ok.md': '---\ndescription: d\n---\nbody\n' } });
  symlinkSync('loop.md', join(dir, 'skills', 't', 'commands', 'loop.md'));
  const skipped = [];
  const entries = scanCommandTrees(dir, skipped);
  assert.deepEqual(entries.map((e) => e.name), ['ok']);
  assert.equal(skipped.length, 1);
  assert.equal(skipped[0].code, 'ELOOP');
});

test('reserve: a skipped command path is warned about on stderr, not silently dropped', () => {
  const dir = mkConfigDir({ t: { 'ok.md': 'x\n' } });
  symlinkSync('loop.md', join(dir, 'skills', 't', 'commands', 'loop.md'));
  const lines = [];
  const orig = process.stderr.write;
  process.stderr.write = (s) => { lines.push(String(s)); return true; };
  try { skillListingSettings({ ...base, configDir: dir }); } finally { process.stderr.write = orig; }
  assert.match(lines.join(''), /skill-listing: .*ELOOP.*loop\.md/);
});

test('no required plugins: nothing emitted', () => {
  assert.deepEqual(skillListingSettings({ entries: [user('x')], enabledIds: [], requiredIds: [] }), {});
});

const registry = {
  floor: [], base: [], catalog: ['lean-skills@himmel', 'frontend-design@claude-plugins-official'], gateAllow: [],
  profiles: { user: { enable: ['lean-skills@himmel'] }, bare: { enable: [] } },
};

test('resolveProfile: opts.skillEntries adds skillOverrides + budget fraction to a profile with required plugins', () => {
  const r = resolveProfile(registry, 'user', { skillEntries: [user('find-docs'), plugin('brainstorming', 200, 'lean-skills')] });
  assert.equal(r.skillOverrides['find-docs'], 'name-only');
  assert.equal(typeof r.skillListingBudgetFraction, 'number');
  assert.equal(r.enabledPlugins['lean-skills@himmel'], true);
});

test('resolveProfile: without opts.skillEntries the output is unchanged (goldens stay byte-identical)', () => {
  const r = resolveProfile(registry, 'user', {});
  assert.deepEqual(Object.keys(r), ['enabledPlugins']);
});

test('resolveProfile: a profile with no required plugins (bare) gets no overrides', () => {
  const r = resolveProfile(registry, 'bare', { skillEntries: [user('find-docs')] });
  assert.deepEqual(Object.keys(r), ['enabledPlugins']);
});
