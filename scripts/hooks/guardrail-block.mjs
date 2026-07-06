#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const WRAPPER = 'guardrail-skip-in-himmel.js';
const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));

export const GUARDRAILS = [
  { basename: 'auto-approve-safe-bash.sh', matcher: 'Bash' },
  { basename: 'block-edit-on-main.sh', matcher: 'Edit|Write|MultiEdit|NotebookEdit' },
  { basename: 'block-read-secrets.sh', matcher: 'Bash|PowerShell|Read|Grep' },
];

function repoRoot() {
  return path.resolve(process.env.HIMMEL_REPO || path.join(MODULE_DIR, '..', '..'));
}

function settingsPath() {
  return process.env.CLAUDE_USER_SETTINGS || path.join(os.homedir(), '.claude', 'settings.json');
}

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--node' || arg === '--bash' || arg === '--stamp') {
      if (i + 1 >= argv.length) throw new Error(`${arg} requires a value`);
      args[arg.slice(2)] = argv[i + 1];
      i += 1;
    } else {
      args._.push(arg);
    }
  }
  return args;
}

function readSettings(file) {
  const text = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '{}';
  return { text, data: JSON.parse(text || '{}') };
}

function ensureHookRoot(data) {
  if (!data.hooks || typeof data.hooks !== 'object' || Array.isArray(data.hooks)) data.hooks = {};
  if (!Array.isArray(data.hooks.PreToolUse)) data.hooks.PreToolUse = [];
  return data.hooks.PreToolUse;
}

function hookGroups(data) {
  const groups = data?.hooks?.PreToolUse;
  return Array.isArray(groups) ? groups : [];
}

function isOwnedHook(hook, basename) {
  const command = hook?.command;
  if (typeof command !== 'string') return false;
  if (!command.includes(WRAPPER)) return false;
  return basename ? command.includes(basename) : true;
}

function commandFor({ nodePath, bashPath, himmelRepo, basename }) {
  const wrapper = path.join(himmelRepo, 'scripts', 'hooks', WRAPPER);
  const script = path.join(himmelRepo, 'scripts', 'hooks', basename);
  return `GUARDRAIL_BASH=${JSON.stringify(bashPath)} ${JSON.stringify(nodePath)} ${JSON.stringify(wrapper)} ${JSON.stringify(script)}`;
}

function desiredHook(opts, guardrail) {
  return {
    type: 'command',
    command: commandFor({ ...opts, basename: guardrail.basename }),
  };
}

function installData(data, opts) {
  const groups = ensureHookRoot(data);

  for (const guardrail of GUARDRAILS) {
    // Remove EVERY existing owned hook for this guardrail (dedups stale copies),
    // remembering the first group that held one so the fresh entry stays in its
    // established place. Rebuilding each group's hooks array avoids the
    // splice-invalidates-a-saved-index bug that let a duplicate survive.
    let homeGroup = null;
    for (const group of groups) {
      if (!Array.isArray(group.hooks)) continue;
      const kept = [];
      for (const hook of group.hooks) {
        if (isOwnedHook(hook, guardrail.basename)) {
          if (!homeGroup) homeGroup = group;
        } else {
          kept.push(hook);
        }
      }
      group.hooks = kept;
    }

    // Place exactly ONE fresh entry: back in its home group if it had one, else
    // an existing matcher group, else a new one.
    let targetGroup = homeGroup
      || groups.find((group) => group.matcher === guardrail.matcher && Array.isArray(group.hooks));
    if (!targetGroup) {
      targetGroup = { matcher: guardrail.matcher, hooks: [] };
      groups.push(targetGroup);
    }
    targetGroup.hooks.push(desiredHook(opts, guardrail));
  }

  data.hooks.PreToolUse = groups.filter((group) => !Array.isArray(group.hooks) || group.hooks.length > 0);
  return data;
}

function removeData(data) {
  const groups = hookGroups(data);
  for (const group of groups) {
    if (!Array.isArray(group.hooks)) continue;
    group.hooks = group.hooks.filter((hook) => !isOwnedHook(hook));
  }
  if (data?.hooks && Array.isArray(data.hooks.PreToolUse)) {
    data.hooks.PreToolUse = data.hooks.PreToolUse.filter((group) => !Array.isArray(group.hooks) || group.hooks.length > 0);
  }
  return data;
}

function stringify(data) {
  return `${JSON.stringify(data, null, 2)}\n`;
}

function backupPath(file, stamp) {
  const base = `${file}.${stamp}.bak`;
  if (!fs.existsSync(base)) return base;
  for (let i = 1; ; i += 1) {
    const candidate = `${base}.${i}`;
    if (!fs.existsSync(candidate)) return candidate;
  }
}

function atomicWrite(file, originalText, nextText, stamp) {
  if (nextText === originalText) return { wrote: false, backup: null };

  const dir = path.dirname(file);
  fs.mkdirSync(dir, { recursive: true });
  const backup = backupPath(file, stamp || String(Date.now()));
  const temp = path.join(dir, `${path.basename(file)}.${process.pid}.tmp`);

  if (fs.existsSync(file)) fs.copyFileSync(file, backup);
  fs.writeFileSync(temp, nextText);
  JSON.parse(fs.readFileSync(temp, 'utf8'));
  fs.renameSync(temp, file);
  return { wrote: true, backup };
}

export function detectMode(data) {
  for (const group of hookGroups(data)) {
    if (!Array.isArray(group.hooks)) continue;
    if (group.hooks.some((hook) => isOwnedHook(hook))) return 'global';
  }
  return 'project';
}

export function install(data, opts) {
  return installData(data, opts);
}

export function remove(data) {
  return removeData(data);
}

function requireAbsolute(name, value) {
  if (!value) throw new Error(`--${name} is required`);
  if (!path.isAbsolute(value)) throw new Error(`--${name} must be absolute`);
}

function nodeResolves(data) {
  for (const group of hookGroups(data)) {
    if (!Array.isArray(group.hooks)) continue;
    for (const hook of group.hooks) {
      if (!isOwnedHook(hook)) continue;
      const command = hook.command.replace(/^GUARDRAIL_BASH="[^"]*"\s+/, '');
      const match = command.match(/^"([^"]+)"/);
      if (match) return fs.existsSync(match[1]);
    }
  }
  return false;
}

function run(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  const command = args._[0];
  const file = settingsPath();

  if (!['detect', 'install', 'remove', 'status', 'global', 'project'].includes(command)) {
    throw new Error('usage: guardrail-block.mjs detect|install|remove|status|global|project [--node ABS --bash ABS] [--stamp VALUE]');
  }

  const { text, data } = readSettings(file);

  if (command === 'detect') {
    process.stdout.write(`${detectMode(data)}\n`);
    return;
  }

  if (command === 'status') {
    process.stdout.write(`guardrail-mode=${detectMode(data)} node-resolves=${nodeResolves(data) ? 'yes' : 'no'}\n`);
    return;
  }

  let next;
  if (command === 'install' || command === 'global') {
    requireAbsolute('node', args.node);
    requireAbsolute('bash', args.bash);
    next = installData(data, { nodePath: args.node, bashPath: args.bash, himmelRepo: repoRoot() });
  } else {
    next = removeData(data);
  }

  const result = atomicWrite(file, text, stringify(next), args.stamp);
  process.stdout.write(`${command === 'project' ? 'remove' : command}: ${result.wrote ? `updated ${file}` : 'no changes'}\n`);
}

const invoked = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invoked) {
  try {
    run();
  } catch (e) {
    process.stderr.write(`guardrail-block: ${e.message}\n`);
    process.exit(1);
  }
}
