// scripts/lanes/tests/vendored-skill-dupes.test.mjs
// HIMMEL-3064 — lean-skills@himmel / upstream-plugin overlap detector.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { makeTmpDir } from '../../lib/test-tmpdir.mjs';
import { findOverlap } from '../vendored-skill-dupes.mjs';

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const CLI = join(dirname(fileURLToPath(import.meta.url)), '..', 'vendored-skill-dupes.mjs');

function settingsHome(enabledPlugins) {
  const home = makeTmpDir('vsd-home-');
  mkdirSync(join(home, '.claude'), { recursive: true });
  writeFileSync(join(home, '.claude', 'settings.json'), JSON.stringify({ enabledPlugins }));
  return home;
}

test('no overlap when only lean-skills@himmel is on', () => {
  const home = settingsHome({ 'lean-skills@himmel': true });
  const out = findOverlap({ home, cwd: '', configDir: '', repoRoot: REPO_ROOT });
  assert.deepEqual(out, []);
});

test('no overlap when lean-skills@himmel is off, even with both upstreams on', () => {
  const home = settingsHome({
    'lean-skills@himmel': false,
    'superpowers@claude-plugins-official': true,
    'mattpocock-skills@claude-plugins-official': true,
  });
  const out = findOverlap({ home, cwd: '', configDir: '', repoRoot: REPO_ROOT });
  assert.deepEqual(out, []);
});

test('no overlap when lean-skills@himmel is simply absent from settings', () => {
  const home = settingsHome({
    'superpowers@claude-plugins-official': true,
    'mattpocock-skills@claude-plugins-official': true,
  });
  const out = findOverlap({ home, cwd: '', configDir: '', repoRoot: REPO_ROOT });
  assert.deepEqual(out, []);
});

test('both overlaps reported when lean-skills and both upstream plugins are on', () => {
  const home = settingsHome({
    'lean-skills@himmel': true,
    'superpowers@claude-plugins-official': true,
    'mattpocock-skills@claude-plugins-official': true,
  });
  const out = findOverlap({ home, cwd: '', configDir: '', repoRoot: REPO_ROOT });
  assert.equal(out.length, 2, 'expected one result per enabled upstream source');

  const superpowers = out.find((o) => o.plugin === 'superpowers@claude-plugins-official');
  assert.ok(superpowers, 'superpowers overlap missing');
  assert.equal(superpowers.repo, 'obra/superpowers');
  assert.deepEqual(superpowers.skills, [
    'brainstorming',
    'executing-plans',
    'finishing-a-development-branch',
    'requesting-code-review',
    'subagent-driven-development',
    'systematic-debugging',
    'test-driven-development',
    'using-git-worktrees',
    'verification-before-completion',
    'writing-plans',
    'writing-skills',
  ], 'expected exactly the 11 vendored superpowers skills, in sorted order');

  const mattpocock = out.find((o) => o.plugin === 'mattpocock-skills@claude-plugins-official');
  assert.ok(mattpocock, 'mattpocock-skills overlap missing (HIMMEL-3064 Defect B regression)');
  assert.equal(mattpocock.repo, 'mattpocock/skills');
  assert.deepEqual(mattpocock.skills, ['grilling']);
});

test('context7-mcp (himmel-authored, no upstream) is never reported as an overlap', () => {
  const home = settingsHome({
    'lean-skills@himmel': true,
    'superpowers@claude-plugins-official': true,
    'mattpocock-skills@claude-plugins-official': true,
  });
  const out = findOverlap({ home, cwd: '', configDir: '', repoRoot: REPO_ROOT });
  for (const o of out) assert.ok(!o.skills.includes('context7-mcp'), `${o.plugin} must not claim context7-mcp`);
});

test('a nearer settings layer\'s false overrides an outer layer\'s true', () => {
  const home = settingsHome({
    'lean-skills@himmel': true,
    'superpowers@claude-plugins-official': true,
  });
  const cwd = makeTmpDir('vsd-cwd-');
  mkdirSync(join(cwd, '.claude'), { recursive: true });
  // nearer layer (cwd) disables superpowers again — must win over the outer home `true`.
  writeFileSync(join(cwd, '.claude', 'settings.local.json'), JSON.stringify({
    enabledPlugins: { 'superpowers@claude-plugins-official': false },
  }));
  const out = findOverlap({ home, cwd, configDir: '', repoRoot: REPO_ROOT });
  assert.deepEqual(out, [], 'nearer false must suppress the overlap the outer true would have reported');
});

// HIMMEL-3064 Defect B: the CLI's env-var parsing used `||`, which treats an
// explicit empty string (the test-hermetic "skip the cwd walk" seam) the same
// as "unset" and falls back to the REAL process.cwd() — silently walking the
// operator's actual ~/.claude ancestry into what was meant to be an isolated
// fixture run. Exercised at the CLI (spawnSync), because `findOverlap` itself
// never had this bug — only the `isMain` env-var seam did.
test('CLI: an explicit empty VENDORED_DUPES_CWD is honoured as "no cwd layers", not the real cwd', () => {
  const home = settingsHome({
    'lean-skills@himmel': true,
    'superpowers@claude-plugins-official': true,
    'mattpocock-skills@claude-plugins-official': true,
  });
  const run = spawnSync(process.execPath, [CLI, '--json'], {
    encoding: 'utf8',
    cwd: REPO_ROOT,
    env: { ...process.env, VENDORED_DUPES_HOME: home, VENDORED_DUPES_CWD: '' },
  });
  assert.equal(run.status, 10, run.stderr);
  const out = JSON.parse(run.stdout);
  assert.equal(out.length, 2);
  assert.ok(out.some((o) => o.plugin === 'mattpocock-skills@claude-plugins-official'), 'mattpocock-skills must survive an empty-string cwd seam');
});
