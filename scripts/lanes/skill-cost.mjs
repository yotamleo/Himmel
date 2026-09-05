// scripts/lanes/skill-cost.mjs
// HIMMEL-1461 phase 0 — measure the UNCAPPED skill-routing listing. Claude
// Code applies its context-dependent cap later; `/context` remains the only
// authority for the post-cap figure.
// Exit codes: 0 = complete scan, 2 = usage/runtime error, 3 = scan completed
// but one or more paths were skipped (EACCES/EPERM/ELOOP) - the totals are
// understated; see `skipped` in --json or the table's `skipped` column.
import {
  readdirSync,
  readFileSync,
  statSync,
} from 'node:fs';
import { homedir } from 'node:os';
import {
  basename,
  extname,
  join,
  resolve,
} from 'node:path';
import { fileURLToPath } from 'node:url';

const ROUTING_TEXT_CAP = 1536;
const PLUGIN_SCAN_MAX_DEPTH = 6;
const PLUGIN_SKILLS_SCOPE = 'plugin-skills';
const SCOPES = [
  PLUGIN_SKILLS_SCOPE,
  'project-commands',
  'project-skills',
  'user-commands',
  'user-skills',
];
const UNCAPPED_CAVEAT = 'UNCAPPED listing size; `/context` is the only authority for the post-cap figure.';

const compareText = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

const IGNORABLE_FS_ERROR_CODES = new Set(['ENOENT', 'ENOTDIR', 'EACCES', 'EPERM', 'ELOOP']);
const isIgnorableFsError = (error) => IGNORABLE_FS_ERROR_CODES.has(error?.code);
// ENOENT/ENOTDIR mean the root simply doesn't exist - pre-existing, benign
// tolerance, not data loss. EACCES/EPERM mean a real permission denial hid
// data, and ELOOP means a cyclic/self-referential symlink hid a real entry -
// all three get recorded in `skipped` and surfaced to the caller.
const SURFACED_SKIP_CODES = new Set(['EACCES', 'EPERM', 'ELOOP']);
const isSurfacedSkip = (error) => SURFACED_SKIP_CODES.has(error?.code);

function directoryEntries(path, scope, skipped) {
  try {
    return readdirSync(path, { withFileTypes: true });
  } catch (error) {
    if (isIgnorableFsError(error)) {
      if (isSurfacedSkip(error)) skipped.push({ path: resolve(path), code: error.code, scope });
      return [];
    }
    throw error;
  }
}

function statThroughLink(path, scope, skipped) {
  try {
    return statSync(path);
  } catch (error) {
    // A broken user-skill link is common enough to be an invalid entry, not a
    // reason to lose the rest of the measurement.
    if (isIgnorableFsError(error)) {
      if (isSurfacedSkip(error)) skipped.push({ path: resolve(path), code: error.code, scope });
      return null;
    }
    throw error;
  }
}

function isDirectoryEntry(entry, path, scope, skipped) {
  if (entry.isDirectory()) return true;
  return entry.isSymbolicLink() && statThroughLink(path, scope, skipped)?.isDirectory() === true;
}

function isFileEntry(entry, path, scope, skipped) {
  if (entry.isFile()) return true;
  return entry.isSymbolicLink() && statThroughLink(path, scope, skipped)?.isFile() === true;
}

function decodeScalar(value) {
  const trimmed = value.trim();
  if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
    try {
      return JSON.parse(trimmed);
    } catch {
      return trimmed.slice(1, -1);
    }
  }
  if (trimmed.length >= 2 && trimmed.startsWith("'") && trimmed.endsWith("'")) {
    return trimmed.slice(1, -1).replaceAll("''", "'");
  }
  return trimmed;
}

// This intentionally reads only the three routing fields. It is not a YAML
// parser, but it does join indented continuation/folded lines so wrapped skill
// descriptions are measured as one scalar instead of being silently truncated
// at the first physical line.
export function readSkillFrontmatter(markdown) {
  const frontmatter = markdown.match(/^﻿?---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/)?.[1];
  const fields = { name: '', description: '', whenToUse: '' };
  if (frontmatter === undefined) return fields;

  const lines = frontmatter.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const match = lines[i].match(/^(name|description|when_to_use)\s*:\s*(.*)$/);
    if (!match) continue;

    const [, yamlKey, first] = match;
    const parts = [];
    if (!/^[>|][+-]?$/.test(first.trim()) && first.trim()) parts.push(first.trim());

    while (i + 1 < lines.length) {
      const next = lines[i + 1];
      if (next.trim() === '') {
        i++;
        continue;
      }
      if (!/^[ \t]+/.test(next)) break;
      parts.push(next.trim());
      i++;
    }

    const key = yamlKey === 'when_to_use' ? 'whenToUse' : yamlKey;
    fields[key] = decodeScalar(parts.join(' ').replace(/\s+/g, ' ').trim());
  }
  return fields;
}

// Exported only for the disappears-after-discovery regression test (see
// skill-cost.test.mjs): there is no deterministic, non-racy way to trigger
// that scenario through the full scanSkillCosts() call chain (fs builtins'
// properties are non-configurable, so mock.method cannot intercept the
// intervening statSync), so the test calls makeEntry directly instead.
export function makeEntry(scope, markdownPath, fallbackName, symlinked, skipped) {
  let buf;
  try {
    buf = readFileSync(markdownPath);
  } catch (error) {
    if (isIgnorableFsError(error)) {
      // Unlike directoryEntries/statThroughLink, makeEntry ONLY ever runs on
      // a path that enumeration already proved exists (readdirSync listed
      // it, and for skills statThroughLink confirmed SKILL.md is a file).
      // So ANY ignorable error here - including ENOENT/ENOTDIR - means the
      // entry was removed/replaced between discovery and this read, not a
      // root that was never there. Surface every one of them; do not gate
      // through isSurfacedSkip, which exists to keep benign "root doesn't
      // exist" cases quiet at the other two call sites.
      skipped.push({ path: resolve(markdownPath), code: error.code, scope });
      return null;
    }
    throw error;
  }
  const markdown = buf.toString('utf8');
  const frontmatter = readSkillFrontmatter(markdown);
  const name = frontmatter.name || fallbackName;
  const routingText = `${frontmatter.description} ${frontmatter.whenToUse}`;
  const countedRoutingChars = Math.min(routingText.length, ROUTING_TEXT_CAP);
  return {
    scope,
    name,
    description: frontmatter.description,
    whenToUse: frontmatter.whenToUse,
    chars: name.length + 2 + routingText.length,
    routingChars: routingText.length,
    countedRoutingChars,
    truncated: routingText.length > ROUTING_TEXT_CAP,
    bodyBytes: buf.length,
    symlinked,
    path: resolve(markdownPath),
  };
}

function scanSkillDirectory(root, scope, skipped) {
  const entries = [];
  for (const entry of directoryEntries(root, scope, skipped)) {
    const entryPath = join(root, entry.name);
    if (!isDirectoryEntry(entry, entryPath, scope, skipped)) continue;
    const skillMd = join(entryPath, 'SKILL.md');
    if (statThroughLink(skillMd, scope, skipped)?.isFile() !== true) continue;
    const skillEntry = makeEntry(scope, skillMd, entry.name, entry.isSymbolicLink(), skipped);
    if (skillEntry) entries.push(skillEntry);
  }
  return entries;
}

function scanCommands(root, scope, skipped) {
  const entries = [];
  for (const entry of directoryEntries(root, scope, skipped)) {
    if (extname(entry.name).toLowerCase() !== '.md') continue;
    const entryPath = join(root, entry.name);
    if (!isFileEntry(entry, entryPath, scope, skipped)) continue;
    const commandEntry = makeEntry(scope, entryPath, basename(entry.name, extname(entry.name)), entry.isSymbolicLink(), skipped);
    if (commandEntry) entries.push(commandEntry);
  }
  return entries;
}

function findPluginSkillDirectories(root, skipped) {
  const skillDirectories = [];
  const visited = new Set();

  function walk(path, depth) {
    const pathStat = statThroughLink(path, PLUGIN_SKILLS_SCOPE, skipped);
    if (!pathStat?.isDirectory()) return;
    const identity = `${pathStat.dev}:${pathStat.ino}`;
    if (visited.has(identity)) return;
    visited.add(identity);

    for (const entry of directoryEntries(path, PLUGIN_SKILLS_SCOPE, skipped)) {
      if (entry.name.startsWith('temp_git_')) continue;
      const entryPath = join(path, entry.name);
      if (!isDirectoryEntry(entry, entryPath, PLUGIN_SKILLS_SCOPE, skipped)) continue;
      if (entry.name === 'skills') {
        skillDirectories.push(entryPath);
        continue;
      }
      if (depth < PLUGIN_SCAN_MAX_DEPTH) walk(entryPath, depth + 1);
    }
  }

  walk(root, 0);
  return skillDirectories;
}

export function scanSkillCosts(options = {}) {
  const cwd = resolve(options.cwd ?? process.cwd());
  const configDir = resolve(options.configDir ?? join(homedir(), '.claude'));
  const skipped = [];
  const entries = [
    ...scanSkillDirectory(join(configDir, 'skills'), 'user-skills', skipped),
    ...scanCommands(join(configDir, 'commands'), 'user-commands', skipped),
    ...scanSkillDirectory(join(cwd, '.claude', 'skills'), 'project-skills', skipped),
    ...scanCommands(join(cwd, '.claude', 'commands'), 'project-commands', skipped),
  ];
  for (const skillsDir of findPluginSkillDirectories(join(configDir, 'plugins'), skipped)) {
    entries.push(...scanSkillDirectory(skillsDir, PLUGIN_SKILLS_SCOPE, skipped));
  }

  return {
    entries: entries.sort((a, b) => (
      compareText(a.scope, b.scope)
      || compareText(a.name, b.name)
      || compareText(a.path, b.path)
    )),
    skipped,
  };
}

// HIMMEL-2037 — the listing pays for every description byte on every session
// start, so a cap needs a gate. Takes explicit paths (pre-commit passes staged
// filenames; CI passes the tracked globs) rather than re-scanning a whole tree.
export function lintDescriptions(files, maxDesc) {
  return files
    .map((file) => ({ file, length: readSkillFrontmatter(readFileSync(file, 'utf8')).description.length }))
    .filter((entry) => entry.length > maxDesc);
}

// HIMMEL-2051 — Claude Code substitutes $ARGUMENTS/$<digit> for the caller's
// Skill-tool args throughout a command's ENTIRE body (fenced code included).
// Evidence (no local Claude Code source tree; extracted via `grep -a` over
// the installed claude.exe binary's string constants): the substitution
// regex is built from `(?<!\\)\$`, `ARGUMENTS\[(\d+)\]`, `ARGUMENTS`, and
// `(\d+)(?!\w)` fragments — i.e. it matches a bare `$1`/`$2`/... not preceded
// by a backslash. A bare positional/field ref inside a fenced awk/shell
// snippet gets clobbered into the literal argument text and stops being
// runnable (HIMMEL-2039). `${1}` (bash) and `$(1)` (awk) are semantically
// identical but don't match that regex (no digit immediately after `$`), so
// they are the prescribed fix.
//
// This lint deliberately does NOT mirror the `(?<!\\)` half of Claude Code's
// own regex (CR round 2, codex-1): a `\$1` here is skipped by the harness's
// substitution, but nothing shows the backslash itself is stripped from the
// rendered text afterward — and inside a SINGLE-QUOTED awk program (the
// common case this lint guards) a literal backslash before `$1` is not valid
// awk syntax either way, so an "escaped" ref can still land broken. The lint
// refuses every bare-or-escaped `$<digit>` and only accepts `${N}`/`$(N)`.
const BARE_POSITIONAL_RE = /\$[0-9]+(?!\w)/;
// CommonMark fence matching (CR round 2, codex-2; trailing-content half of
// CR round 3, codex-1; closing-indentation half of CR round 4, codex-1): a
// fence-looking line only OPENS/CLOSES the current fence when its marker
// char matches, its run length is >= the opening run length, nothing but
// whitespace follows the marker, AND its own indentation does not EXCEED the
// opening marker's indentation — an over-indented fence-looking line is
// CONTENT under CommonMark (e.g. an example shown "    ```" deep inside an
// already-open, less-indented fence), and treating it as a close would end
// tracking early and let real content after it evade the lint (the false
// negative round 4 named). Anything that fails any of those checks (a
// different char, a shorter run of the same char, trailing content, or
// over-indentation) is literal content of the still-open fence, e.g. a ```
// example nested inside an outer ```` fence.
//
// Deliberately NOT capping OPENING indentation at CommonMark's <=3-space
// top-level rule (round 3): this corpus's own numbered-list fences are
// legitimately indented 5-6 spaces (list-relative, not absolute-column, per
// CommonMark's container rules — e.g. .claude/commands/pr-check.md:1461,
// .claude/commands/overnight-shift.md:73, both open AND close at that same
// indent). Full container-relative indentation tracking is out of proportion
// for this lint; staying permissive about what counts as an OPEN can only
// ever over-scan. Closing is the opposite risk (ending protection too
// early), which is why it alone is bounded against the opener's own indent.
//
// Declined (CR round 4, codex-2, Suggestion): recognizing a fence prefixed
// by a blockquote marker (`> \`\`\`bash`). No command file in this repo uses
// one today, and blockquote-nested fences add another layer of CommonMark
// container tracking for a markdown shape this corpus has never had a
// reason to produce — chasing every remaining CommonMark construct this way
// has no natural stopping point. Revisit if a real command ever needs one.
const FENCE_RE = /^(\s*)(`{3,}|~{3,})(.*)$/;

// HIMMEL-2051 CR round 1 (codex-1): pr-check.md itself proved that the Skill
// tool substitutes args into a command regardless of whether it declares
// `argument-hint`/`$ARGUMENTS` — so gating this lint on that declaration left
// the identical hazard undetected in any other command (confirmed: a bare
// $1/$2 JS/PowerShell `.replace()`/`-replace` backreference sits unguarded in
// marketplace/plugins/claude-hud/commands/setup.md, which declares neither).
// Every scanned command file is checked unconditionally; callers exclude
// files this lint must not touch (e.g. claude-hud's byte-pinned vendor tree,
// HIMMEL-718) via their own file selection, same as the other doc gates do.
export function lintPositionalArgs(files) {
  const offenders = [];
  for (const file of files) {
    const content = readFileSync(file, 'utf8');
    let fenceChar = null;
    let fenceLen = 0;
    let fenceIndent = 0;
    const lines = content.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const fenceMatch = line.match(FENCE_RE);
      if (fenceMatch) {
        const indent = fenceMatch[1].length;
        const marker = fenceMatch[2];
        const rest = fenceMatch[3];
        if (fenceChar === null) {
          // Opening fence: an info string (rest) is allowed here.
          fenceChar = marker[0];
          fenceLen = marker.length;
          fenceIndent = indent;
          continue;
        }
        if (marker[0] === fenceChar && marker.length >= fenceLen && indent <= fenceIndent && /^\s*$/.test(rest)) {
          // Closing fence: same-or-longer run of the same char, indented no
          // MORE than the opener, and NOTHING but whitespace after it — an
          // info string here means this line is content (e.g. a literal
          // "```bash" example), not a real close.
          fenceChar = null;
          fenceLen = 0;
          fenceIndent = 0;
          continue;
        }
        // Not a valid close (different char, shorter run, trailing content,
        // or over-indented) — it's content; fall through.
      }
      if (fenceChar === null) continue;
      const match = line.match(BARE_POSITIONAL_RE);
      if (match) offenders.push({ file, line: i + 1, token: match[0], text: line.trim() });
    }
  }
  return offenders;
}

function emptyScope(scope) {
  return {
    scope,
    entries: 0,
    chars: 0,
    estimatedTokens: 0,
    bodyBytes: 0,
    bodyKB: 0,
    symlinked: 0,
    truncated: 0,
    skipped: 0,
  };
}

export function summarizeSkillCosts(entries, skipped = []) {
  const byScope = new Map(SCOPES.map((scope) => [scope, emptyScope(scope)]));
  const total = emptyScope('TOTAL');

  for (const entry of entries) {
    if (!byScope.has(entry.scope)) byScope.set(entry.scope, emptyScope(entry.scope));
    const scope = byScope.get(entry.scope);
    for (const summary of [scope, total]) {
      summary.entries++;
      summary.chars += entry.chars;
      summary.bodyBytes += entry.bodyBytes;
      summary.symlinked += entry.symlinked ? 1 : 0;
      summary.truncated += entry.truncated ? 1 : 0;
    }
  }

  for (const skip of skipped) {
    if (!byScope.has(skip.scope)) byScope.set(skip.scope, emptyScope(skip.scope));
    const scope = byScope.get(skip.scope);
    scope.skipped++;
    total.skipped++;
  }

  for (const summary of [...byScope.values(), total]) {
    summary.estimatedTokens = summary.chars / 4;
    summary.bodyKB = summary.bodyBytes / 1024;
  }

  return {
    measurement: 'uncapped',
    caveat: UNCAPPED_CAVEAT,
    scopes: [...byScope.values()].sort((a, b) => compareText(a.scope, b.scope)),
    total,
  };
}

function formatTable(summary) {
  const rows = [...summary.scopes, summary.total];
  const headers = ['scope', 'entries', 'uncapped chars', 'est. tokens (chars/4)', 'body KB', 'symlinked', 'truncated', 'skipped'];
  const values = rows.map((row) => [
    row.scope,
    String(row.entries),
    String(row.chars),
    Number.isInteger(row.estimatedTokens) ? String(row.estimatedTokens) : row.estimatedTokens.toFixed(1),
    row.bodyKB.toFixed(1),
    String(row.symlinked),
    String(row.truncated),
    String(row.skipped),
  ]);
  const widths = headers.map((header, index) => Math.max(header.length, ...values.map((row) => row[index].length)));
  const line = (row) => row.map((value, index) => (
    index === 0 ? value.padEnd(widths[index]) : value.padStart(widths[index])
  )).join('  ');
  const lines = [
    'UNCAPPED skill listing cost',
    line(headers),
    line(widths.map((width) => '-'.repeat(width))),
    ...values.map(line),
    summary.caveat,
  ];
  if (summary.total.skipped > 0) {
    lines.push(`INCOMPLETE: ${summary.total.skipped} path(s) skipped due to filesystem errors; the totals above UNDERSTATE the real listing.`);
  }
  return lines.join('\n');
}

function parseCliArgs(argv) {
  const options = {};
  const files = [];
  let mode = 'table';
  let maxDesc;
  let checkPositionalArgs = false;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--estimate' || arg === '--json') {
      if (mode !== 'table') throw new Error(`${arg} cannot be combined with --${mode}`);
      mode = arg.slice(2);
      continue;
    }
    if (arg === '--cwd' || arg === '--config-dir') {
      if (argv[i + 1] === undefined) throw new Error(`${arg} requires a value`);
      const key = arg === '--cwd' ? 'cwd' : 'configDir';
      options[key] = argv[++i];
      continue;
    }
    if (arg === '--max-desc') {
      if (argv[i + 1] === undefined) throw new Error('--max-desc requires a value');
      maxDesc = Number(argv[++i]);
      if (!Number.isInteger(maxDesc) || maxDesc <= 0) throw new Error('--max-desc requires a positive integer');
      continue;
    }
    if (arg === '--check-positional-args') {
      checkPositionalArgs = true;
      continue;
    }
    if (arg.startsWith('-')) throw new Error(`unknown argument "${arg}"`);
    files.push(arg);
  }
  if (maxDesc === undefined && !checkPositionalArgs && files.length > 0) throw new Error(`unknown argument "${files[0]}"`);
  if (maxDesc !== undefined && mode !== 'table') throw new Error(`--max-desc cannot be combined with --${mode}`);
  if (checkPositionalArgs && mode !== 'table') throw new Error(`--check-positional-args cannot be combined with --${mode}`);
  if (checkPositionalArgs && maxDesc !== undefined) throw new Error('--check-positional-args cannot be combined with --max-desc');
  return { mode, options, maxDesc, checkPositionalArgs, files };
}

function runCli(argv) {
  const { mode, options, maxDesc, checkPositionalArgs, files } = parseCliArgs(argv);
  if (maxDesc !== undefined) {
    if (files.length === 0) throw new Error('--max-desc requires at least one file path');
    const offenders = lintDescriptions(files, maxDesc);
    if (offenders.length === 0) return;
    for (const { file, length } of offenders) {
      process.stderr.write(`skill-cost: ${file}: description is ${length} chars (cap ${maxDesc})\n`);
    }
    process.exit(1);
  }
  if (checkPositionalArgs) {
    if (files.length === 0) throw new Error('--check-positional-args requires at least one file path');
    const offenders = lintPositionalArgs(files);
    if (offenders.length === 0) return;
    for (const { file, line, token } of offenders) {
      process.stderr.write(`skill-cost: ${file}:${line}: bare ${token} inside a fenced block collides with Skill-tool arg substitution (HIMMEL-2051) — use \${N} in bash or $(N) in awk\n`);
    }
    process.exit(1);
  }
  const { entries, skipped } = scanSkillCosts(options);
  const summary = summarizeSkillCosts(entries, skipped);
  if (mode === 'json') {
    process.stdout.write(JSON.stringify({ entries, skipped, summary }, null, 2) + '\n');
  } else if (mode === 'estimate') {
    process.stdout.write(`UNCAPPED total: ${summary.total.chars} chars (${summary.total.estimatedTokens} estimated tokens at chars/4)\n${summary.caveat}\n`);
    if (skipped.length > 0) {
      const skippedList = skipped.map((skip) => `  ${skip.path} (${skip.code})`).join('\n');
      process.stderr.write(`skill-cost: WARNING - ${skipped.length} path(s) skipped due to filesystem errors; this total is UNDERSTATED.\n${skippedList}\n`);
    }
  } else {
    process.stdout.write(formatTable(summary) + '\n');
  }
  // Print the full output first (above), then signal incompleteness via a
  // distinct exit code - 3, never 2 (usage/runtime error) - uniformly across
  // all three modes so a caller can rely on one rule.
  if (skipped.length > 0) process.exitCode = 3;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    runCli(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`skill-cost: ${error?.message ?? error}\n`);
    process.exit(2);
  }
}
