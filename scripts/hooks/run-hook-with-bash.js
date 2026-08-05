#!/usr/bin/env node
// Resolve the Bash interpreter for Claude Code hooks before running the hook.
// On Windows, bare `bash` can resolve to the WSL launcher or the 0-byte
// WindowsApps alias instead of Git Bash. This launcher selects a concrete,
// usable executable and fails closed when none exists. Node is intentionally
// required before the hook starts: if Node is missing, the launcher blocks the
// action rather than risking a guard script failing open under another shell.
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function normalize(candidate) {
  return String(candidate || '').replace(/\\/g, '/').replace(/\/+$/, '');
}

function isKnownBadWindowsBash(candidate) {
  const low = normalize(candidate).toLowerCase();
  return low.includes('/windows/system32/bash.exe') ||
    low.includes('/windows/sysnative/bash.exe') ||
    low.includes('/windowsapps/bash.exe');
}

function isUsable(candidate, platform = process.platform) {
  if (!candidate || (platform === 'win32' && isKnownBadWindowsBash(candidate))) return false;
  try {
    const stat = fs.statSync(candidate);
    if (!stat.isFile()) return false;
    // Windows App Execution Aliases are 0-byte reparse points. Refuse any
    // zero-byte candidate even if it appears outside the usual WindowsApps dir.
    if (platform === 'win32' && stat.size === 0) return false;
    if (platform !== 'win32') fs.accessSync(candidate, fs.constants.X_OK);
    return true;
  } catch (_e) {
    return false;
  }
}

function windowsCandidates(env) {
  const p = path.win32;
  const candidates = [];
  const addRoot = (root) => {
    if (!root) return;
    candidates.push(p.join(root, 'Git', 'bin', 'bash.exe'));
    candidates.push(p.join(root, 'Git', 'usr', 'bin', 'bash.exe'));
  };

  addRoot(env.ProgramFiles);
  addRoot(env['ProgramFiles(x86)']);
  if (env.LOCALAPPDATA) addRoot(p.join(env.LOCALAPPDATA, 'Programs'));
  // Keep canonical locations even when a non-Windows test or stripped process
  // environment omits ProgramFiles.
  addRoot('C:\\Program Files');
  addRoot('C:\\Program Files (x86)');

  const pathDirs = String(env.PATH || env.Path || '').split(';').filter(Boolean);
  for (const dir of pathDirs) {
    const base = p.basename(dir).toLowerCase();
    let gitRoot = null;
    if (base === 'bin' && p.basename(p.dirname(dir)).toLowerCase() === 'usr') gitRoot = p.dirname(p.dirname(dir));
    else if (base === 'cmd' || base === 'bin') gitRoot = p.dirname(dir);
    if (gitRoot) {
      candidates.push(p.join(gitRoot, 'bin', 'bash.exe'));
      candidates.push(p.join(gitRoot, 'usr', 'bin', 'bash.exe'));
    }
    candidates.push(p.join(dir, 'bash.exe'));
    candidates.push(p.join(dir, 'bash'));
  }
  return candidates;
}

function posixCandidates(env) {
  const candidates = [];
  for (const dir of String(env.PATH || '').split(path.posix.delimiter).filter(Boolean)) {
    candidates.push(path.posix.join(dir, 'bash'));
  }
  candidates.push('/bin/bash', '/usr/bin/bash');
  return candidates;
}

function resolveBash(options = {}) {
  const platform = options.platform || process.platform;
  const env = options.env || process.env;
  const usable = options.isUsable || ((candidate) => isUsable(candidate, platform));
  const candidates = platform === 'win32' ? windowsCandidates(env) : posixCandidates(env);
  const seen = new Set();
  for (const candidate of candidates) {
    const key = normalize(candidate).toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    if (usable(candidate)) return normalize(candidate);
  }
  return null;
}

function parseHookArgs(argv) {
  let optional = false;
  let failClosedWhen = null;
  let index = 0;

  while (index < argv.length && argv[index].startsWith('--')) {
    if (argv[index] === '--optional') {
      optional = true;
      index += 1;
      continue;
    }
    if (argv[index] === '--fail-closed-when') {
      const condition = argv[index + 1] || '';
      const match = condition.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
      if (!match) throw new Error('--fail-closed-when requires NAME=VALUE');
      failClosedWhen = { name: match[1], value: match[2], display: condition };
      index += 2;
      continue;
    }
    throw new Error(`unknown option: ${argv[index]}`);
  }

  const hookArgs = argv.slice(index);
  if (hookArgs.length === 0) throw new Error('missing hook script path');
  if (failClosedWhen && !optional) throw new Error('--fail-closed-when requires --optional');
  return { hookArgs, optional, failClosedWhen };
}

function main() {
  let parsed;
  try {
    parsed = parseHookArgs(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`run-hook-with-bash: ${error.message}\n`);
    process.exit(2);
  }

  const { hookArgs, optional, failClosedWhen } = parsed;
  const hookScript = hookArgs[0];
  if (optional && !fs.existsSync(hookScript)) {
    if (failClosedWhen && process.env[failClosedWhen.name] === failClosedWhen.value) {
      const hookName = path.basename(hookScript, path.extname(hookScript));
      process.stderr.write(`${hookName}: hook script missing while ${failClosedWhen.display} (stale checkout?) - failing closed\n`);
      process.exit(2);
    }
    process.exit(0);
  }

  const bash = resolveBash();
  if (!bash) {
    process.stderr.write('run-hook-with-bash: no usable Bash interpreter found; refusing to run hook\n');
    process.exit(2);
  }
  const result = spawnSync(bash, hookArgs, { stdio: 'inherit', env: process.env });
  if (result.error) {
    process.stderr.write(`run-hook-with-bash: failed to start ${bash}: ${result.error.message}\n`);
    process.exit(2);
  }
  process.exit(typeof result.status === 'number' ? result.status : 2);
}

module.exports = { isKnownBadWindowsBash, isUsable, resolveBash, windowsCandidates };
if (require.main === module) main();
