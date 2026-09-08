import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { frontmatterDescription, regenerateCatalog, loadGeneratedStaged } from './gen-commands-catalog.mjs';

test('frontmatterDescription reads the description: scalar', () => {
  const md = '---\nname: foo\ndescription: Does the thing.\n---\nbody\n';
  assert.equal(frontmatterDescription(md), 'Does the thing.');
});

test('frontmatterDescription returns empty string when no frontmatter', () => {
  assert.equal(frontmatterDescription('no frontmatter here'), '');
});

test('check mode: no violation when description already matches', () => {
  const catalog = [
    '| Command | Description | Notes |',
    '|---|---|---|',
    '| /foo | Does the thing. | some note |',
  ].join('\n');
  const generated = new Map([['foo', 'Does the thing.']]);
  const { violations } = regenerateCatalog(catalog, generated, 'check');
  assert.deepEqual(violations, []);
});

test('check mode: flags a drifted description', () => {
  const catalog = '| /foo | Old stale text | notes |';
  const generated = new Map([['foo', 'New correct text']]);
  const { violations } = regenerateCatalog(catalog, generated, 'check');
  assert.equal(violations.length, 1);
  assert.equal(violations[0].name, 'foo');
  assert.equal(violations[0].have, 'Old stale text');
  assert.equal(violations[0].want, 'New correct text');
});

test('check mode: flags a legacy 2-col row even when its description already matches (write would still restructure it)', () => {
  const catalog = '| /foo | Same text |';
  const generated = new Map([['foo', 'Same text']]);
  const { violations } = regenerateCatalog(catalog, generated, 'check');
  assert.equal(violations.length, 1);
  assert.equal(violations[0].name, 'foo');
  assert.equal(violations[0].have, '<legacy 2-column row>');
});

test('check mode: exempt rows (no matching command file) never flagged', () => {
  const catalog = '| /plugin-thing (some plugin) | Whatever paraphrase | |';
  const generated = new Map(); // plugin-thing has no .claude/commands file
  const { violations } = regenerateCatalog(catalog, generated, 'check');
  assert.deepEqual(violations, []);
});

test('write mode: migrates a legacy 2-col row to 3-col, preserving old text as Notes', () => {
  const catalog = '| /foo | Old elaborate paraphrase |';
  const generated = new Map([['foo', 'New short desc']]);
  const { text } = regenerateCatalog(catalog, generated, 'write');
  assert.equal(text, '| /foo | New short desc | Old elaborate paraphrase |');
});

test('write mode: a row already equal to frontmatter gets an empty Notes cell', () => {
  const catalog = '| /foo | Same text |';
  const generated = new Map([['foo', 'Same text']]);
  const { text } = regenerateCatalog(catalog, generated, 'write');
  assert.equal(text, '| /foo | Same text |  |');
});

test('write mode: re-running on an already-migrated row is a no-op (idempotent)', () => {
  const catalog = '| /foo | Same text | some note |';
  const generated = new Map([['foo', 'Same text']]);
  const { text, changed } = regenerateCatalog(catalog, generated, 'write');
  assert.equal(text, catalog);
  assert.equal(changed, false);
});

test('write mode: exempt row (no command file) is left untouched', () => {
  const catalog = '| /plugin-thing (some plugin) | Whatever paraphrase |';
  const generated = new Map();
  const { text } = regenerateCatalog(catalog, generated, 'write');
  assert.equal(text, catalog);
});

test('check mode: a command with no catalog row at all is flagged (added/renamed command, doc-guard only proves the file was touched)', () => {
  const catalog = [
    '| Command | Description | Notes |',
    '|---|---|---|',
    '| /foo | Does the thing. |  |',
  ].join('\n');
  const generated = new Map([['foo', 'Does the thing.'], ['bar', 'New command, no row yet.']]);
  const { violations } = regenerateCatalog(catalog, generated, 'check');
  assert.equal(violations.length, 1);
  assert.equal(violations[0].name, 'bar');
  assert.equal(violations[0].have, '<no catalog row>');
  assert.equal(violations[0].want, 'New command, no row yet.');
});

test('write mode: an exempt row inside an upgraded table gets padded to 3 columns too (regression: mixed-column table is broken markdown)', () => {
  const catalog = [
    '| Command | What it does |',
    '|---|---|',
    '| /foo | Old paraphrase |',
    '| /plugin-thing (some plugin) | Whatever paraphrase |',
  ].join('\n');
  const generated = new Map([['foo', 'New short desc']]);
  const { text } = regenerateCatalog(catalog, generated, 'write');
  assert.equal(text, [
    '| Command | Description | Notes |',
    '|---|---|---|',
    '| /foo | New short desc | Old paraphrase |',
    '| /plugin-thing (some plugin) | Whatever paraphrase |  |',
  ].join('\n'));
});

test('check mode: flags a 2-column exempt row inside an ALREADY 3-column table, but not one inside a still-legacy 2-column table (codex-2, HIMMEL-2064 CR round)', () => {
  const alreadyMigrated = [
    '| Command | Description | Notes |',
    '|---|---|---|',
    '| /foo | Does the thing. |  |',
    '| /plugin-thing (some plugin) | Whatever paraphrase |',
  ].join('\n');
  const { violations: migratedViolations } = regenerateCatalog(alreadyMigrated, new Map([['foo', 'Does the thing.']]), 'check');
  assert.equal(migratedViolations.length, 1);
  assert.equal(migratedViolations[0].name, 'plugin-thing');
  assert.equal(migratedViolations[0].have, '<unpadded exempt row>');

  const stillLegacy = [
    '| Command | What it does |',
    '|---|---|',
    '| /plugin-thing (some plugin) | Whatever paraphrase |',
  ].join('\n');
  const { violations: legacyViolations } = regenerateCatalog(stillLegacy, new Map(), 'check');
  assert.deepEqual(legacyViolations, []);
});

test('a hand-written Notes cell with an UNESCAPED pipe is flagged by check and self-heals under write (no silent truncation) (codex-1, HIMMEL-2064 CR round)', () => {
  const catalog = '| /foo | Does the thing. | uses cmd1 | cmd2 as fallback |';
  const generated = new Map([['foo', 'Does the thing.']]);

  const { violations } = regenerateCatalog(catalog, generated, 'check');
  assert.equal(violations.length, 1);
  assert.equal(violations[0].name, 'foo');
  assert.equal(violations[0].have, '<unescaped pipe in row>');

  // write must NOT silently drop everything after the unescaped pipe — it
  // rejoins the full Notes text and re-escapes it into canonical form.
  const { text } = regenerateCatalog(catalog, generated, 'write');
  assert.equal(text, '| /foo | Does the thing. | uses cmd1 \\| cmd2 as fallback |');
  // The re-escaped output round-trips clean.
  const { violations: afterWrite } = regenerateCatalog(text, generated, 'check');
  assert.deepEqual(afterWrite, []);
});

test('an unescaped pipe with NO surrounding whitespace is still caught (codex-1, HIMMEL-2064 CR round: split(\' | \') missed a no-space "|")', () => {
  const catalog = '| /foo | Does the thing. | note-a|note-b |';
  const generated = new Map([['foo', 'Does the thing.']]);

  const { violations } = regenerateCatalog(catalog, generated, 'check');
  assert.equal(violations.length, 1);
  assert.equal(violations[0].have, '<unescaped pipe in row>');

  const { text } = regenerateCatalog(catalog, generated, 'write');
  assert.equal(text, '| /foo | Does the thing. | note-a \\| note-b |');
  const { violations: afterWrite } = regenerateCatalog(text, generated, 'check');
  assert.deepEqual(afterWrite, []);
});

test('write mode: a blank line ends the table, so a plugin-only table after it stays 2-col', () => {
  const catalog = [
    '| Command | What it does |',
    '|---|---|',
    '| /foo | Old paraphrase |',
    '',
    '## Plugin skills',
    '',
    '| Skill / command | What it does |',
    '|---|---|',
    '| /plugin-thing (some plugin) | Whatever paraphrase |',
  ].join('\n');
  const generated = new Map([['foo', 'New short desc']]);
  const { text } = regenerateCatalog(catalog, generated, 'write');
  assert.equal(text, [
    '| Command | Description | Notes |',
    '|---|---|---|',
    '| /foo | New short desc | Old paraphrase |',
    '',
    '## Plugin skills',
    '',
    '| Skill / command | What it does |',
    '|---|---|',
    '| /plugin-thing (some plugin) | Whatever paraphrase |',
  ].join('\n'));
});

test('a frontmatter description containing a literal | is escaped, not corrupted (CR round 2 MAJOR)', () => {
  const catalog = '| /foo | old desc |';
  const generated = new Map([['foo', 'Runs a | b | c pipeline']]);
  const { text } = regenerateCatalog(catalog, generated, 'write');
  assert.equal(text, '| /foo | Runs a \\| b \\| c pipeline | old desc |');
  // Round-trips: re-parsing the written row must read back the UNESCAPED
  // description, and check mode must see no drift against it.
  const { violations } = regenerateCatalog(text, generated, 'check');
  assert.deepEqual(violations, []);
});

test('a Notes cell containing a literal | round-trips through escape/unescape', () => {
  const generated = new Map([['foo', 'Same text']]);
  const escaped = '| /foo | Same text | a \\| b note |';
  const { text, changed } = regenerateCatalog(escaped, generated, 'write');
  assert.equal(text, escaped);
  assert.equal(changed, false);
});

test('a description containing a literal backslash-pipe doubles the backslash so CommonMark rendering does not swallow it (codex-1, HIMMEL-2064 CR round)', () => {
  // frontmatter description is the 4 chars: a \ | b (one literal backslash
  // directly before a literal pipe).
  const generated = new Map([['foo', 'a\\|b']]);
  const { text } = regenerateCatalog('| /foo | old |', generated, 'write');
  // The stored cell must escape the backslash TOO (not just the pipe): a
  // bare "\|" is itself a CommonMark escape sequence and would render as a
  // lone "|", silently dropping the backslash. Doubling it first forces
  // CommonMark's own escaping to reproduce "a\|b" when rendered.
  assert.equal(text, '| /foo | a\\\\\\|b | old |');
  // Our own parser must still read the ORIGINAL description back (no drift).
  const { violations } = regenerateCatalog(text, generated, 'check');
  assert.deepEqual(violations, []);
});

test('write mode: drops an orphaned row (command file removed) outside an exempt section', () => {
  const catalog = [
    '## Utility',
    '',
    '| Command | What it does |',
    '|---|---|',
    '| /foo | Still here |',
    '| /gone | Command file was deleted |',
  ].join('\n');
  const generated = new Map([['foo', 'Still here']]);
  const { text } = regenerateCatalog(catalog, generated, 'write');
  assert.equal(text, [
    '## Utility',
    '',
    '| Command | Description | Notes |',
    '|---|---|---|',
    '| /foo | Still here |  |',
  ].join('\n'));
});

test('check mode: flags an orphaned row outside an exempt section', () => {
  const catalog = [
    '## Utility',
    '',
    '| Command | What it does |',
    '|---|---|',
    '| /gone | Command file was deleted |',
  ].join('\n');
  const { violations } = regenerateCatalog(catalog, new Map(), 'check');
  assert.equal(violations.length, 1);
  assert.equal(violations[0].name, 'gone');
  assert.equal(violations[0].have, '<orphaned row>');
});

test('an untagged, unmatched row INSIDE an exempt section is never dropped or flagged (legitimate plugin row)', () => {
  const catalog = [
    '## Clipper pipeline (obsidian-triage plugin)',
    '',
    '| Command | What it does |',
    '|---|---|',
    '| /harvest-clips | Stage 1 |',
  ].join('\n');
  const { text: writeText } = regenerateCatalog(catalog, new Map(), 'write');
  assert.equal(writeText, [
    '## Clipper pipeline (obsidian-triage plugin)',
    '',
    '| Command | Description | Notes |',
    '|---|---|---|',
    '| /harvest-clips | Stage 1 |  |',
  ].join('\n'));
  const { violations } = regenerateCatalog(catalog, new Map(), 'check');
  assert.deepEqual(violations, []);
});

test('a TAGGED row is exempt (never dropped/flagged) even outside an exempt section', () => {
  const catalog = [
    '## Utility',
    '',
    '| Command | What it does |',
    '|---|---|',
    '| /himmel-doctor (himmel-ops) | Diagnose problems |',
  ].join('\n');
  const { text } = regenerateCatalog(catalog, new Map(), 'write');
  assert.equal(text, [
    '## Utility',
    '',
    '| Command | Description | Notes |',
    '|---|---|---|',
    '| /himmel-doctor (himmel-ops) | Diagnose problems |  |',
  ].join('\n'));
  const { violations } = regenerateCatalog(catalog, new Map(), 'check');
  assert.deepEqual(violations, []);
});

test('an untagged parenthetical that is not a real plugin marker cannot fake exemption (codex-2, HIMMEL-2064 CR round: /foo (beta) evading the orphan check)', () => {
  const catalog = '| /foo (beta) | Some paraphrase |';
  const { violations } = regenerateCatalog(catalog, new Map(), 'check');
  assert.equal(violations.length, 1);
  assert.equal(violations[0].name, 'foo');
  assert.equal(violations[0].have, '<orphaned row>');
});

test('write mode: a newly hand-added exempt row inside an ALREADY-migrated (3-col) table still gets padded (CR round 3)', () => {
  const catalog = [
    '| Command | Description | Notes |',
    '|---|---|---|',
    '| /foo | Does the thing. |  |',
    '| /new-plugin-thing (some plugin) | Whatever paraphrase |',
  ].join('\n');
  const generated = new Map([['foo', 'Does the thing.']]);
  const { text } = regenerateCatalog(catalog, generated, 'write');
  assert.equal(text, [
    '| Command | Description | Notes |',
    '|---|---|---|',
    '| /foo | Does the thing. |  |',
    '| /new-plugin-thing (some plugin) | Whatever paraphrase |  |',
  ].join('\n'));
});

test('check mode: a duplicated row for the same command is flagged (CR round 3)', () => {
  const catalog = [
    '| /foo | Does the thing. | |',
    '| /foo | Does the thing. | |',
  ].join('\n');
  const generated = new Map([['foo', 'Does the thing.']]);
  const { violations } = regenerateCatalog(catalog, generated, 'check');
  assert.equal(violations.length, 1);
  assert.equal(violations[0].name, 'foo');
  assert.equal(violations[0].have, '<duplicate row>');
});

test('write mode: normalizes section headers to 3 columns', () => {
  const catalog = [
    '| Command | What it does |',
    '|---|---|',
  ].join('\n');
  const { text } = regenerateCatalog(catalog, new Map(), 'write');
  assert.equal(text, '| Command | Description | Notes |\n|---|---|---|');
});

test('loadGeneratedStaged reads the STAGED command frontmatter, ignoring an unstaged edit', () => {
  const root = mkdtempSync(join(tmpdir(), 'gen-catalog-staged-'));
  try {
    execFileSync('git', ['init', '-q'], { cwd: root });
    execFileSync('git', ['config', 'user.email', 'test@test'], { cwd: root });
    execFileSync('git', ['config', 'user.name', 'test'], { cwd: root });
    const cmdDir = join(root, '.claude', 'commands');
    mkdirSync(cmdDir, { recursive: true });
    writeFileSync(join(cmdDir, 'foo.md'), '---\ndescription: Staged desc\n---\nbody\n');
    execFileSync('git', ['add', '.'], { cwd: root });
    // Dirty the working tree AFTER staging — loadGeneratedStaged must read
    // the staged blob (`git show :<path>`), not this unstaged edit, mirroring
    // check-doc-guard.sh's staged-vs-working convention.
    writeFileSync(join(cmdDir, 'foo.md'), '---\ndescription: Unstaged desc\n---\nbody\n');
    const generated = loadGeneratedStaged(root, '.claude/commands');
    assert.equal(generated.get('foo'), 'Staged desc');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('check mode: a well-formed row with trailing whitespace is not falsely flagged (codex-2, HIMMEL-2064 CR round: slice(1,-1) removed a space, not the closing pipe)', () => {
  const catalog = '| /foo | Does the thing. | |  ';
  const generated = new Map([['foo', 'Does the thing.']]);
  const { violations } = regenerateCatalog(catalog, generated, 'check');
  assert.deepEqual(violations, []);
});

test('write mode: a row missing the OPTIONAL trailing pipe is not silently truncated (codex-1, HIMMEL-2064 CR round, CRITICAL: GFM makes the trailing | optional)', () => {
  const catalog = '| /foo | Does the thing. | note';
  const generated = new Map([['foo', 'Does the thing.']]);
  const { text } = regenerateCatalog(catalog, generated, 'write');
  // Must preserve the FULL Notes text ("note", not "not") and add the
  // canonical trailing pipe.
  assert.equal(text, '| /foo | Does the thing. | note |');
});

test('write mode: a row missing the trailing pipe whose Notes cell legitimately ends in an escaped literal pipe is not corrupted (codex-1, HIMMEL-2105 CR round, Important)', () => {
  const catalog = '| /foo | Does the thing. | note\\|';
  const generated = new Map([['foo', 'Does the thing.']]);
  const { text } = regenerateCatalog(catalog, generated, 'write');
  // The escaped `\|` is real content (a literal trailing pipe), not the
  // optional GFM delimiter — must round-trip intact, re-escaped.
  assert.equal(text, '| /foo | Does the thing. | note\\| |');
});

test('loadGeneratedStaged skips a NESTED staged command file (codex-1, HIMMEL-2064 CR round: git\'s * pathspec crosses directories, readdirSync does not)', () => {
  const root = mkdtempSync(join(tmpdir(), 'gen-catalog-nested-'));
  try {
    execFileSync('git', ['init', '-q'], { cwd: root });
    execFileSync('git', ['config', 'user.email', 'test@test'], { cwd: root });
    execFileSync('git', ['config', 'user.name', 'test'], { cwd: root });
    const cmdDir = join(root, '.claude', 'commands');
    mkdirSync(join(cmdDir, 'sub'), { recursive: true });
    writeFileSync(join(cmdDir, 'top.md'), '---\ndescription: Top level.\n---\nbody\n');
    writeFileSync(join(cmdDir, 'sub', 'nested.md'), '---\ndescription: Nested.\n---\nbody\n');
    execFileSync('git', ['add', '.'], { cwd: root });
    const generated = loadGeneratedStaged(root, '.claude/commands');
    assert.deepEqual([...generated.keys()], ['top']);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
