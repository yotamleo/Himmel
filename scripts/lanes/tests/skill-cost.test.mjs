// scripts/lanes/tests/skill-cost.test.mjs
// HIMMEL-1461 phase 0 — hermetic coverage for the UNCAPPED skill-listing
// measurement, especially Windows junctions (the common user-skill shape).
import { after, test } from 'node:test';
import assert from 'node:assert/strict';
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  readSkillFrontmatter,
  scanSkillCosts,
  summarizeSkillCosts,
} from '../skill-cost.mjs';

const ROOT = mkdtempSync(join(tmpdir(), 'skill-cost-'));
const CWD = join(ROOT, 'repo');
const CONFIG_DIR = join(ROOT, 'config');
const LONG_DESCRIPTION = 'x'.repeat(1600);

function write(path, content) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, content);
}

function skill(frontmatter, body = '# Fixture\n') {
  return `---\n${frontmatter}\n---\n${body}`;
}

write(join(CONFIG_DIR, 'skills', 'plain', 'SKILL.md'), skill([
  'name: plain-user',
  'description: Plain user skill',
  'when_to_use: Use for fixtures',
].join('\n')));
write(join(CONFIG_DIR, 'skills', 'not-a-skill', 'README.md'), '# No SKILL.md\n');

write(join(CONFIG_DIR, 'commands', 'user-command.md'), skill([
  'description: User command description',
  'when_to_use: Run the user command fixture',
].join('\n')));

write(join(CWD, '.claude', 'skills', 'long', 'SKILL.md'), skill([
  'name: long-project',
  `description: ${LONG_DESCRIPTION}`,
  'when_to_use: now',
].join('\n')));
write(join(CWD, '.claude', 'skills', 'missing-skill-md', 'README.md'), '# Ignored\n');

write(join(CWD, '.claude', 'commands', 'flat-command.md'), skill([
  'description: Flat command description',
  'when_to_use: Run the fixture command',
].join('\n')));
write(join(CWD, '.claude', 'commands', 'nested', 'ignored.md'), skill('description: Nested commands are not entries'));
write(join(CWD, '.claude', 'commands', 'not-markdown.txt'), 'ignored\n');

write(join(CONFIG_DIR, 'plugins', 'cache', 'market', 'plugin', '1.0.0', 'skills', 'folded', 'SKILL.md'), skill([
  'name: folded-plugin',
  'description: >',
  '  first wrapped line',
  '  second wrapped line',
  'when_to_use: >-',
  '  when folding',
  '  matters',
].join('\n')));
write(join(CONFIG_DIR, 'plugins', 'temp_git_checkout', 'skills', 'ignored-plugin', 'SKILL.md'), skill([
  'name: ignored-plugin',
  'description: Temporary checkout must not count',
].join('\n')));

const linkedTarget = join(ROOT, 'linked-target');
write(join(linkedTarget, 'SKILL.md'), skill([
  'name: linked-user',
  'description: Junction-backed user skill',
  'when_to_use: Prove links are resolved',
].join('\n')));
mkdirSync(join(CONFIG_DIR, 'skills'), { recursive: true });
let junctionError;
try {
  symlinkSync(linkedTarget, join(CONFIG_DIR, 'skills', 'linked'), 'junction');
} catch (error) {
  junctionError = error;
}

after(() => rmSync(ROOT, { recursive: true, force: true }));

const scan = () => scanSkillCosts({ cwd: CWD, configDir: CONFIG_DIR });

test('frontmatter reader joins folded and continued routing scalars', () => {
  const fields = readSkillFrontmatter(skill([
    'name: wrapped',
    'description: first physical line',
    '  second physical line',
    'when_to_use: >',
    '  use when',
    '  wrapping matters',
  ].join('\n')));
  assert.deepEqual(fields, {
    name: 'wrapped',
    description: 'first physical line second physical line',
    whenToUse: 'use when wrapping matters',
  });
});

test('scan applies each root\'s entry rules to the fixture tree only', () => {
  const entries = scan();
  const names = entries.map((entry) => entry.name);
  const expected = ['flat-command', 'folded-plugin', 'long-project', 'plain-user', 'user-command'];
  if (!junctionError) expected.push('linked-user');
  assert.deepEqual([...names].sort(), expected.sort());

  assert.ok(!names.includes('not-a-skill'));
  assert.ok(!names.includes('missing-skill-md'));
  assert.ok(!names.includes('ignored'));
  assert.ok(!names.includes('ignored-plugin'));

  assert.equal(entries.find((entry) => entry.name === 'flat-command').scope, 'project-commands');
  assert.equal(entries.find((entry) => entry.name === 'user-command').scope, 'user-commands');
  assert.equal(entries.find((entry) => entry.name === 'folded-plugin').description, 'first wrapped line second wrapped line');
  assert.ok(entries.every((entry) => entry.bodyBytes > 0));
});

test('listing arithmetic caps routing text at 1536 chars and reports truncation', () => {
  const entry = scan().find((candidate) => candidate.name === 'long-project');
  assert.equal(entry.truncated, true);
  assert.equal(entry.countedRoutingChars, 1536);
  assert.equal(entry.routingChars, LONG_DESCRIPTION.length + ' '.length + 'now'.length);
  assert.equal(entry.chars, 'long-project'.length + 2 + 1536);
});

test('summary reports per-scope and uncapped totals from fixture entries', () => {
  const entries = scan();
  const summary = summarizeSkillCosts(entries);
  assert.equal(summary.measurement, 'uncapped');
  assert.match(summary.caveat, /UNCAPPED/);
  assert.equal(summary.total.entries, 5 + (junctionError ? 0 : 1));
  assert.equal(summary.total.chars, entries.reduce((sum, entry) => sum + entry.chars, 0));
  assert.equal(summary.total.estimatedTokens, summary.total.chars / 4);
  assert.equal(summary.total.truncated, 1);
  assert.equal(summary.scopes.find((scope) => scope.scope === 'project-commands').entries, 1);
  assert.equal(summary.scopes.find((scope) => scope.scope === 'user-commands').entries, 1);
  assert.equal(summary.scopes.find((scope) => scope.scope === 'plugin-skills').entries, 1);
});

test('a junction-backed user skill is counted and marked symlinked', (t) => {
  if (junctionError) {
    t.skip(`junction creation unavailable; symlink assertions skipped explicitly: ${junctionError.message}`);
    return;
  }
  const linked = scan().find((entry) => entry.name === 'linked-user');
  assert.ok(linked, 'the symlinked skill directory must survive directory validation');
  assert.equal(linked.scope, 'user-skills');
  assert.equal(linked.symlinked, true);
  assert.equal(summarizeSkillCosts(scan()).total.symlinked, 1);
});

test('two scans of the same tree are deeply deterministic', () => {
  const entries = scan();
  assert.deepEqual(entries, scan());

  const expectedOrder = [
    'plugin-skills:folded-plugin',
    'project-commands:flat-command',
    'project-skills:long-project',
    'user-commands:user-command',
  ];
  if (!junctionError) expectedOrder.push('user-skills:linked-user');
  expectedOrder.push('user-skills:plain-user');
  assert.deepEqual(entries.map((entry) => `${entry.scope}:${entry.name}`), expectedOrder);
});

test('CLI table, estimate, and JSON modes label the measurement uncapped', () => {
  const cli = join(dirname(fileURLToPath(import.meta.url)), '..', 'skill-cost.mjs');
  const run = (mode = []) => spawnSync(process.execPath, [cli, ...mode, '--cwd', CWD, '--config-dir', CONFIG_DIR], { encoding: 'utf8' });

  const table = run();
  assert.equal(table.status, 0, table.stderr);
  assert.match(table.stdout, /UNCAPPED skill listing cost/);
  assert.match(table.stdout, /est\. tokens \(chars\/4\)/);
  assert.match(table.stdout, /TOTAL/);

  const estimate = run(['--estimate']);
  assert.equal(estimate.status, 0, estimate.stderr);
  assert.match(estimate.stdout, /^UNCAPPED total: \d+ chars/);
  assert.match(estimate.stdout, /post-cap figure/);

  const json = run(['--json']);
  assert.equal(json.status, 0, json.stderr);
  const parsed = JSON.parse(json.stdout);
  assert.equal(parsed.summary.measurement, 'uncapped');
  assert.equal(parsed.entries.length, 5 + (junctionError ? 0 : 1));
});
