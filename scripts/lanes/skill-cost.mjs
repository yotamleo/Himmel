// scripts/lanes/skill-cost.mjs
// HIMMEL-1461 phase 0 — measure the UNCAPPED skill-routing listing. Claude
// Code applies its context-dependent cap later; `/context` remains the only
// authority for the post-cap figure.
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
const SCOPES = [
  'plugin-skills',
  'project-commands',
  'project-skills',
  'user-commands',
  'user-skills',
];
const UNCAPPED_CAVEAT = 'UNCAPPED listing size; `/context` is the only authority for the post-cap figure.';

const compareText = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

function directoryEntries(path) {
  try {
    return readdirSync(path, { withFileTypes: true });
  } catch (error) {
    if (error?.code === 'ENOENT' || error?.code === 'ENOTDIR') return [];
    throw error;
  }
}

function statThroughLink(path) {
  try {
    return statSync(path);
  } catch (error) {
    // A broken user-skill link is common enough to be an invalid entry, not a
    // reason to lose the rest of the measurement.
    if (error?.code === 'ENOENT' || error?.code === 'EACCES' || error?.code === 'EPERM') return null;
    throw error;
  }
}

function isDirectoryEntry(entry, path) {
  if (entry.isDirectory()) return true;
  return entry.isSymbolicLink() && statThroughLink(path)?.isDirectory() === true;
}

function isFileEntry(entry, path) {
  if (entry.isFile()) return true;
  return entry.isSymbolicLink() && statThroughLink(path)?.isFile() === true;
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

function makeEntry(scope, markdownPath, fallbackName, symlinked) {
  const markdown = readFileSync(markdownPath, 'utf8');
  const frontmatter = readSkillFrontmatter(markdown);
  const name = frontmatter.name || fallbackName;
  const routingText = `${frontmatter.description} ${frontmatter.whenToUse}`;
  const countedRoutingChars = Math.min(routingText.length, ROUTING_TEXT_CAP);
  return {
    scope,
    name,
    description: frontmatter.description,
    whenToUse: frontmatter.whenToUse,
    chars: name.length + 2 + countedRoutingChars,
    routingChars: routingText.length,
    countedRoutingChars,
    truncated: routingText.length > ROUTING_TEXT_CAP,
    bodyBytes: statSync(markdownPath).size,
    symlinked,
    path: resolve(markdownPath),
  };
}

function scanSkillDirectory(root, scope) {
  const entries = [];
  for (const entry of directoryEntries(root)) {
    const entryPath = join(root, entry.name);
    if (!isDirectoryEntry(entry, entryPath)) continue;
    const skillMd = join(entryPath, 'SKILL.md');
    if (statThroughLink(skillMd)?.isFile() !== true) continue;
    entries.push(makeEntry(scope, skillMd, entry.name, entry.isSymbolicLink()));
  }
  return entries;
}

function scanCommands(root, scope) {
  const entries = [];
  for (const entry of directoryEntries(root)) {
    if (extname(entry.name).toLowerCase() !== '.md') continue;
    const entryPath = join(root, entry.name);
    if (!isFileEntry(entry, entryPath)) continue;
    entries.push(makeEntry(scope, entryPath, basename(entry.name, extname(entry.name)), entry.isSymbolicLink()));
  }
  return entries;
}

function findPluginSkillDirectories(root) {
  const skillDirectories = [];
  const visited = new Set();

  function walk(path, depth) {
    const pathStat = statThroughLink(path);
    if (!pathStat?.isDirectory()) return;
    const identity = `${pathStat.dev}:${pathStat.ino}`;
    if (visited.has(identity)) return;
    visited.add(identity);

    for (const entry of directoryEntries(path)) {
      if (entry.name.startsWith('temp_git_')) continue;
      const entryPath = join(path, entry.name);
      if (!isDirectoryEntry(entry, entryPath)) continue;
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
  const entries = [
    ...scanSkillDirectory(join(configDir, 'skills'), 'user-skills'),
    ...scanCommands(join(configDir, 'commands'), 'user-commands'),
    ...scanSkillDirectory(join(cwd, '.claude', 'skills'), 'project-skills'),
    ...scanCommands(join(cwd, '.claude', 'commands'), 'project-commands'),
  ];
  for (const skillsDir of findPluginSkillDirectories(join(configDir, 'plugins'))) {
    entries.push(...scanSkillDirectory(skillsDir, 'plugin-skills'));
  }

  return entries.sort((a, b) => (
    compareText(a.scope, b.scope)
    || compareText(a.name, b.name)
    || compareText(a.path, b.path)
  ));
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
  };
}

export function summarizeSkillCosts(entries) {
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
  const headers = ['scope', 'entries', 'uncapped chars', 'est. tokens (chars/4)', 'body KB', 'symlinked', 'truncated'];
  const values = rows.map((row) => [
    row.scope,
    String(row.entries),
    String(row.chars),
    Number.isInteger(row.estimatedTokens) ? String(row.estimatedTokens) : row.estimatedTokens.toFixed(1),
    row.bodyKB.toFixed(1),
    String(row.symlinked),
    String(row.truncated),
  ]);
  const widths = headers.map((header, index) => Math.max(header.length, ...values.map((row) => row[index].length)));
  const line = (row) => row.map((value, index) => (
    index === 0 ? value.padEnd(widths[index]) : value.padStart(widths[index])
  )).join('  ');
  return [
    'UNCAPPED skill listing cost',
    line(headers),
    line(widths.map((width) => '-'.repeat(width))),
    ...values.map(line),
    summary.caveat,
  ].join('\n');
}

function parseCliArgs(argv) {
  const options = {};
  let mode = 'table';
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
    throw new Error(`unknown argument "${arg}"`);
  }
  return { mode, options };
}

function runCli(argv) {
  const { mode, options } = parseCliArgs(argv);
  const entries = scanSkillCosts(options);
  const summary = summarizeSkillCosts(entries);
  if (mode === 'json') {
    process.stdout.write(JSON.stringify({ entries, summary }, null, 2) + '\n');
    return;
  }
  if (mode === 'estimate') {
    process.stdout.write(`UNCAPPED total: ${summary.total.chars} chars (${summary.total.estimatedTokens} estimated tokens at chars/4)\n${summary.caveat}\n`);
    return;
  }
  process.stdout.write(formatTable(summary) + '\n');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    runCli(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`skill-cost: ${error?.message ?? error}\n`);
    process.exit(2);
  }
}
