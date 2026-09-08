// scripts/lanes/tests/skill-cost.test.mjs
// HIMMEL-1461 phase 0 — hermetic coverage for the UNCAPPED skill-listing
// measurement, especially Windows junctions (the common user-skill shape).
import { after, test } from 'node:test';
import assert from 'node:assert/strict';
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  lintPositionalArgs,
  makeEntry,
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

const scan = () => scanSkillCosts({ cwd: CWD, configDir: CONFIG_DIR }).entries;

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

test('listing arithmetic reports uncapped chars and caps the routing-text diagnostics at 1536', () => {
  const entry = scan().find((candidate) => candidate.name === 'long-project');
  assert.equal(entry.truncated, true);
  assert.equal(entry.countedRoutingChars, 1536);
  assert.equal(entry.routingChars, LONG_DESCRIPTION.length + ' '.length + 'now'.length);
  assert.equal(entry.chars, 'long-project'.length + 2 + entry.routingChars);
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

test('an entry that throws EACCES/EPERM is skipped, not fatal to the scan, and is surfaced as skipped', (t) => {
  const permRoot = mkdtempSync(join(tmpdir(), 'skill-cost-perm-'));
  let unreadablePath;
  t.after(() => {
    if (unreadablePath) {
      try {
        chmodSync(unreadablePath, 0o600);
      } catch {
        // best-effort restore; removal below must still happen either way
      }
    }
    rmSync(permRoot, { recursive: true, force: true });
  });
  const permCwd = join(permRoot, 'repo');
  const permConfigDir = join(permRoot, 'config');
  write(join(permCwd, '.claude', 'skills', 'readable', 'SKILL.md'), skill([
    'name: readable-neighbor',
    'description: Must still be scanned',
    'when_to_use: Proves the scan survives a sibling failure',
  ].join('\n')));
  unreadablePath = join(permCwd, '.claude', 'skills', 'unreadable', 'SKILL.md');
  write(unreadablePath, skill([
    'name: unreadable-entry',
    'description: Must never be readable',
    'when_to_use: Simulates an EACCES/EPERM filesystem entry',
  ].join('\n')));
  chmodSync(unreadablePath, 0o000);

  let deniedCode;
  try {
    readFileSync(unreadablePath, 'utf8');
  } catch (error) {
    deniedCode = error.code;
  }

  if (deniedCode !== 'EACCES' && deniedCode !== 'EPERM') {
    t.skip(`chmod 000 did not deny read access for the current process on this platform (code: ${deniedCode ?? 'read succeeded'}); cannot exercise EACCES/EPERM hermetically`);
    return;
  }
  const { entries, skipped } = scanSkillCosts({ cwd: permCwd, configDir: permConfigDir });
  assert.ok(entries.some((entry) => entry.name === 'readable-neighbor'), 'the sibling entry must still be scanned');
  assert.ok(!entries.some((entry) => entry.name === 'unreadable-entry'), 'the unreadable entry must be omitted, not thrown');
  assert.equal(skipped.length, 1);
  assert.equal(skipped[0].code, deniedCode);
  assert.equal(skipped[0].scope, 'project-skills');
  const summary = summarizeSkillCosts(entries, skipped);
  assert.equal(summary.total.skipped, 1);
  assert.equal(summary.scopes.find((scope) => scope.scope === 'project-skills').skipped, 1);
});

test('a denied containing directory fails the stat itself, and is skipped and surfaced too', (t) => {
  // chmod 000 on the FILE (see the test above) denies read but leaves stat
  // working - it never exercises statThroughLink. Denying the containing
  // DIRECTORY's search/execute bit is what makes statSync(skillMd) itself
  // throw, which is the code path scanSkillDirectory calls BEFORE makeEntry.
  const permRoot = mkdtempSync(join(tmpdir(), 'skill-cost-perm-dir-'));
  let unreadableDir;
  t.after(() => {
    if (unreadableDir) {
      try {
        chmodSync(unreadableDir, 0o700);
      } catch {
        // best-effort restore; removal below must still happen either way
      }
    }
    rmSync(permRoot, { recursive: true, force: true });
  });
  const permCwd = join(permRoot, 'repo');
  const permConfigDir = join(permRoot, 'config');
  write(join(permCwd, '.claude', 'skills', 'readable', 'SKILL.md'), skill([
    'name: readable-neighbor-2',
    'description: Must still be scanned',
    'when_to_use: Proves the scan survives a sibling stat failure',
  ].join('\n')));
  unreadableDir = join(permCwd, '.claude', 'skills', 'unreadable-dir');
  const unreadableSkillMd = join(unreadableDir, 'SKILL.md');
  write(unreadableSkillMd, skill([
    'name: unreadable-dir-entry',
    'description: Must never be statable',
    'when_to_use: Simulates a denied containing directory',
  ].join('\n')));
  chmodSync(unreadableDir, 0o000);

  let deniedCode;
  try {
    statSync(unreadableSkillMd);
  } catch (error) {
    deniedCode = error.code;
  }

  if (deniedCode !== 'EACCES' && deniedCode !== 'EPERM') {
    t.skip(`chmod 000 on the containing directory did not deny stat for the current process on this platform (code: ${deniedCode ?? 'stat succeeded'}); cannot exercise the statThroughLink EACCES/EPERM path hermetically`);
    return;
  }
  const { entries, skipped } = scanSkillCosts({ cwd: permCwd, configDir: permConfigDir });
  assert.ok(entries.some((entry) => entry.name === 'readable-neighbor-2'), 'the sibling entry must still be scanned');
  assert.ok(!entries.some((entry) => entry.name === 'unreadable-dir-entry'), 'the entry behind the denied directory must be omitted, not thrown');
  assert.equal(skipped.length, 1);
  assert.equal(skipped[0].code, deniedCode);
  assert.equal(skipped[0].scope, 'project-skills');
  const summary = summarizeSkillCosts(entries, skipped);
  assert.equal(summary.total.skipped, 1);
  assert.equal(summary.scopes.find((scope) => scope.scope === 'project-skills').skipped, 1);
});

test('a self-referential (cyclic) symlink throws ELOOP and is skipped and surfaced too', (t) => {
  const permRoot = mkdtempSync(join(tmpdir(), 'skill-cost-perm-eloop-'));
  t.after(() => rmSync(permRoot, { recursive: true, force: true }));
  const permCwd = join(permRoot, 'repo');
  const permConfigDir = join(permRoot, 'config');
  write(join(permCwd, '.claude', 'skills', 'readable', 'SKILL.md'), skill([
    'name: readable-eloop-neighbor',
    'description: Must still be scanned',
    'when_to_use: Proves the scan survives a cyclic symlink sibling',
  ].join('\n')));
  const loopPath = join(permCwd, '.claude', 'skills', 'loop');
  mkdirSync(join(permCwd, '.claude', 'skills'), { recursive: true });
  let loopError;
  try {
    symlinkSync(loopPath, loopPath, 'junction');
  } catch (error) {
    loopError = error;
  }
  if (loopError) {
    t.skip(`self-referential junction creation unavailable; ELOOP assertions skipped explicitly: ${loopError.message}`);
    return;
  }

  let deniedCode;
  try {
    statSync(loopPath);
  } catch (error) {
    deniedCode = error.code;
  }
  if (deniedCode !== 'ELOOP') {
    t.skip(`self-referential junction did not raise ELOOP on this platform (code: ${deniedCode ?? 'stat succeeded'}); cannot exercise the ELOOP path hermetically`);
    return;
  }
  const { entries, skipped } = scanSkillCosts({ cwd: permCwd, configDir: permConfigDir });
  assert.ok(entries.some((entry) => entry.name === 'readable-eloop-neighbor'), 'the sibling entry must still be scanned');
  assert.ok(!entries.some((entry) => entry.name === 'loop'), 'the cyclic entry must be omitted, not thrown');
  assert.equal(skipped.length, 1);
  assert.equal(skipped[0].code, 'ELOOP');
  assert.equal(skipped[0].scope, 'project-skills');
  const summary = summarizeSkillCosts(entries, skipped);
  assert.equal(summary.total.skipped, 1);
  assert.equal(summary.scopes.find((scope) => scope.scope === 'project-skills').skipped, 1);
});

test('makeEntry surfaces ENOENT unconditionally, unlike directoryEntries/statThroughLink', (t) => {
  // Reproduces "disappeared between discovery and read" (concurrent plugin
  // install/skill update): readdirSync + statThroughLink already proved the
  // path existed, then it vanished before readFileSync. There is no
  // deterministic, non-racy way to interleave a deletion mid-way through the
  // full scanSkillCosts() call chain: everything on that path uses the sync
  // fs API with no yield point to inject at, and node:test's mock.method
  // cannot intercept it either - `fs`'s builtin exports are non-configurable
  // (verified: mock.method(fsNamespace, 'statSync', ...) throws
  // "TypeError: Cannot redefine property: statSync" in this Node version).
  // So this asserts the behaviour at the makeEntry level directly, per the
  // sanctioned fallback: create the file, delete it, then call makeEntry on
  // the now-gone path - a real ENOENT from a real readFileSync, just without
  // pretending the deletion happened concurrently with the scan.
  const permRoot = mkdtempSync(join(tmpdir(), 'skill-cost-perm-vanish-'));
  t.after(() => rmSync(permRoot, { recursive: true, force: true }));
  const skillMd = join(permRoot, 'vanishing', 'SKILL.md');
  write(skillMd, skill([
    'name: vanishing-entry',
    'description: Exists at enumeration time, gone by read time',
  ].join('\n')));
  rmSync(skillMd);

  const skipped = [];
  const result = makeEntry('project-skills', skillMd, 'vanishing', false, skipped);
  assert.equal(result, null, 'makeEntry must return null, not throw, on a post-discovery ENOENT');
  assert.equal(skipped.length, 1);
  assert.equal(skipped[0].code, 'ENOENT');
  assert.equal(skipped[0].scope, 'project-skills');

  // The exit-3 gate in runCli is `if (skipped.length > 0) process.exitCode = 3`
  // - generic over which call site populated `skipped` (already proven at the
  // CLI/process level by the ELOOP test above). This confirms the disappeared-
  // entry case produces the identical {path, code, scope} shape that feeds it.
  const summary = summarizeSkillCosts([], skipped);
  assert.equal(summary.total.skipped, 1);
  assert.equal(summary.scopes.find((scope) => scope.scope === 'project-skills').skipped, 1);
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

test('--max-desc refuses an over-cap description and names the file and length', () => {
  const cli = join(dirname(fileURLToPath(import.meta.url)), '..', 'skill-cost.mjs');
  const overCap = join(CWD, '.claude', 'skills', 'long', 'SKILL.md');
  const withinCap = join(CWD, '.claude', 'commands', 'flat-command.md');
  const run = (args) => spawnSync(process.execPath, [cli, ...args], { encoding: 'utf8' });

  const clean = run(['--max-desc', '120', withinCap]);
  assert.equal(clean.status, 0, clean.stderr);
  assert.equal(clean.stderr, '');

  const refused = run(['--max-desc', '120', withinCap, overCap]);
  assert.equal(refused.status, 1);
  assert.match(refused.stderr, /SKILL\.md: description is 1600 chars \(cap 120\)/);
  assert.ok(!refused.stderr.includes('flat-command'), 'a within-cap file must not be reported');

  assert.equal(run(['--max-desc', '120']).status, 2, 'lint mode needs at least one path');
  assert.equal(run(['--max-desc', '0', withinCap]).status, 2, 'the cap must be a positive integer');
  assert.equal(run(['--max-desc', '120', '--json', withinCap]).status, 2, 'lint mode is not a measurement mode');
  assert.equal(run([withinCap]).status, 2, 'a bare path without --max-desc stays an error');
});

test('lintPositionalArgs refuses a bare $<digit> in ANY command\'s fenced code, argument-hint or not (HIMMEL-2051)', (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'skill-cost-posargs-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));

  const withArgHint = join(dir, 'with-arg-hint.md');
  write(withArgHint, [
    '---',
    'argument-hint: <thing>',
    'description: fixture',
    '---',
    '',
    '```bash',
    "lane=\$(awk -F' [|] ' '{print \$3; exit}' \"\$marker\")",
    '```',
  ].join('\n'));

  const fixedArgHint = join(dir, 'fixed-arg-hint.md');
  write(fixedArgHint, [
    '---',
    'argument-hint: <thing>',
    'description: fixture',
    '---',
    '',
    '```bash',
    "lane=\$(awk -F' [|] ' '{print \$(3); exit}' \"\$marker\")",
    '```',
  ].join('\n'));

  const proseOnly = join(dir, 'prose-only.md');
  write(proseOnly, [
    '---',
    'argument-hint: <thing>',
    'description: fixture',
    '---',
    '',
    'Talking about $3 in prose, outside any fence, is fine.',
  ].join('\n'));

  // HIMMEL-2051 CR round 1 (codex-1): a command with NO argument-hint/$ARGUMENTS
  // is exactly as vulnerable as one that declares them — pr-check.md itself is
  // the proof, and the panel additionally found a live case in a vendored
  // plugin (marketplace/plugins/claude-hud/commands/setup.md, excluded from
  // the real gates because it's byte-pinned, HIMMEL-718). The lint no longer
  // gates on argument-hint at all, so this file is refused just like the one
  // above, and callers exclude what they must not touch.
  const noArgHint = join(dir, 'no-arg-hint.md');
  write(noArgHint, [
    '---',
    'description: takes no arguments',
    '---',
    '',
    '```bash',
    'echo $1',
    '```',
  ].join('\n'));

  // ~~~ fences (codex-2 round 1): the fence detector must not be backtick-only.
  const tildeFence = join(dir, 'tilde-fence.md');
  write(tildeFence, [
    '---',
    'description: uses a tilde fence',
    '---',
    '',
    '~~~bash',
    'echo $2',
    '~~~',
  ].join('\n'));

  // Nested fence lengths (codex-2 round 2): a ``` example nested inside an
  // outer ```` fence must not falsely close the outer fence, and the
  // genuinely-closing final ```` must end it — the $4 inside stays reachable.
  const nestedFence = join(dir, 'nested-fence.md');
  write(nestedFence, [
    '---',
    'description: nested fence lengths',
    '---',
    '',
    '````markdown',
    '```bash',
    'echo hi',
    '```',
    'echo $4',
    '````',
  ].join('\n'));

  // \$N backslash-escaping (codex-1 round 2): Claude Code's own substitution
  // regex skips it, but it is not valid awk syntax inside a single-quoted
  // program either way, so the lint refuses it exactly like the bare form.
  const escapedDigit = join(dir, 'escaped-digit.md');
  write(escapedDigit, [
    '---',
    'description: backslash-escaped positional ref',
    '---',
    '',
    '```bash',
    "awk '{print \\$5}'",
    '```',
  ].join('\n'));

  // Closing fence with trailing content (codex-1 round 3): a same-length,
  // same-char marker line followed by other text (a literal "```output"
  // shown as an example) must NOT close the real fence — only a marker
  // line followed by nothing but whitespace may close it.
  const trailingContentFence = join(dir, 'trailing-content-fence.md');
  write(trailingContentFence, [
    '---',
    'description: fence-looking line with trailing content is not a close',
    '---',
    '',
    '```bash',
    '```output',
    'echo $6',
    '```',
  ].join('\n'));

  // Over-indented close (codex-1 round 4): a fence-looking line indented
  // MORE than the opener is CommonMark content, not a close — treating it as
  // a close would end tracking early and let the real $8 after it evade the
  // lint (the false negative round 4 named).
  const overIndentedClose = join(dir, 'over-indented-close.md');
  write(overIndentedClose, [
    '---',
    'description: an over-indented fence-looking line does not close',
    '---',
    '',
    '```bash',
    '    ```',
    'echo $8',
    '```',
  ].join('\n'));

  // Deeply-indented open+close PAIR at the SAME indent (positive control,
  // round 4 rebuttal): this corpus's real numbered-list fences look exactly
  // like this and must still be recognized end to end.
  const deepIndentPair = join(dir, 'deep-indent-pair.md');
  write(deepIndentPair, [
    '---',
    'description: deeply indented open+close fence pair',
    '---',
    '',
    '1. Step one',
    '   - nested bullet',
    '     ```bash',
    '     echo $9',
    '     ```',
  ].join('\n'));

  const offenders = lintPositionalArgs([
    withArgHint, fixedArgHint, proseOnly, noArgHint, tildeFence, nestedFence,
    escapedDigit, trailingContentFence, overIndentedClose, deepIndentPair,
  ]);
  assert.deepEqual(offenders.map((o) => o.file), [
    withArgHint, noArgHint, tildeFence, nestedFence, escapedDigit,
    trailingContentFence, overIndentedClose, deepIndentPair,
  ]);
  assert.equal(offenders[0].line, 7);
  assert.equal(offenders[0].token, '$3');
  assert.equal(offenders[1].token, '$1');
  assert.equal(offenders[2].token, '$2');
  assert.equal(offenders[3].line, 9);
  assert.equal(offenders[3].token, '$4');
  assert.equal(offenders[4].token, '$5');
  assert.equal(offenders[5].line, 7);
  assert.equal(offenders[5].token, '$6');
  assert.equal(offenders[6].line, 7);
  assert.equal(offenders[6].token, '$8');
  assert.equal(offenders[7].line, 8);
  assert.equal(offenders[7].token, '$9');

  const cli = join(dirname(fileURLToPath(import.meta.url)), '..', 'skill-cost.mjs');
  const run = (args) => spawnSync(process.execPath, [cli, ...args], { encoding: 'utf8' });

  const refused = run(['--check-positional-args', withArgHint]);
  assert.equal(refused.status, 1);
  assert.match(refused.stderr, /bare \$3 inside a fenced block collides with Skill-tool arg substitution \(HIMMEL-2051\)/);

  const clean = run(['--check-positional-args', fixedArgHint, proseOnly]);
  assert.equal(clean.status, 0, clean.stderr);
  assert.equal(clean.stderr, '');

  assert.equal(run(['--check-positional-args']).status, 2, 'lint mode needs at least one path');
  assert.equal(run(['--check-positional-args', '--json', fixedArgHint]).status, 2, 'lint mode is not a measurement mode');
  assert.equal(run(['--check-positional-args', '--max-desc', '120', fixedArgHint]).status, 2, 'cannot combine with --max-desc');
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

test('CLI exits 3 (not 0, not 2) when a path is skipped, in all three modes', (t) => {
  // Drives the skip via a self-referential junction (ELOOP), not chmod:
  // chmod 000 does not deny access for the owning process on this platform
  // (see the tests above), but a self-referential junction reliably raises
  // ELOOP here, so this regression actually executes instead of skipping.
  const permRoot = mkdtempSync(join(tmpdir(), 'skill-cost-perm-cli-'));
  t.after(() => rmSync(permRoot, { recursive: true, force: true }));
  const permCwd = join(permRoot, 'repo');
  const permConfigDir = join(permRoot, 'config');
  write(join(permCwd, '.claude', 'skills', 'readable', 'SKILL.md'), skill([
    'name: readable-cli-neighbor',
    'description: Must still be scanned',
    'when_to_use: Proves the CLI still prints full output on a partial scan',
  ].join('\n')));
  const loopPath = join(permCwd, '.claude', 'skills', 'loop');
  mkdirSync(join(permCwd, '.claude', 'skills'), { recursive: true });
  let loopError;
  try {
    symlinkSync(loopPath, loopPath, 'junction');
  } catch (error) {
    loopError = error;
  }
  if (loopError) {
    t.skip(`self-referential junction creation unavailable; exit-3 assertions skipped explicitly: ${loopError.message}`);
    return;
  }
  let deniedCode;
  try {
    statSync(loopPath);
  } catch (error) {
    deniedCode = error.code;
  }
  if (deniedCode !== 'ELOOP') {
    t.skip(`self-referential junction did not raise ELOOP on this platform (code: ${deniedCode ?? 'stat succeeded'}); cannot exercise the exit-3 path hermetically`);
    return;
  }

  const cli = join(dirname(fileURLToPath(import.meta.url)), '..', 'skill-cost.mjs');
  const run = (mode = []) => spawnSync(process.execPath, [cli, ...mode, '--cwd', permCwd, '--config-dir', permConfigDir], { encoding: 'utf8' });

  const table = run();
  assert.equal(table.status, 3, table.stderr);
  assert.match(table.stdout, /INCOMPLETE: 1 path\(s\) skipped/);

  const estimate = run(['--estimate']);
  assert.equal(estimate.status, 3, estimate.stderr);
  assert.match(estimate.stdout, /^UNCAPPED total: \d+ chars/);
  assert.match(estimate.stderr, /WARNING - 1 path\(s\) skipped/);
  assert.ok(estimate.stderr.includes(loopPath), 'the stderr warning must name the skipped path, not just a count');

  const json = run(['--json']);
  assert.equal(json.status, 3, json.stderr);
  const parsed = JSON.parse(json.stdout);
  assert.equal(parsed.skipped.length, 1);
  assert.equal(parsed.skipped[0].code, 'ELOOP');
  assert.equal(parsed.summary.total.skipped, 1);
});
