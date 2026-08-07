#!/usr/bin/env node
// hooks/narrow-allow.mjs — sanctioned settings narrowing chokepoint (HIMMEL-1513).
//
// `.claude/settings.json` is deliberately deny-listed for direct agent edits.
// This script performs one narrow transformation: remove specific entries
// from permissions.allow. It refuses any result that is not a strict
// narrowing — every entry in the new allow list must already have existed in
// the old one and the list must shrink — and it proves permissions.deny/ask
// and every other parsed field stay byte-for-byte equivalent. It does not
// support adding replacement entries: proving a replacement is a strict
// subset of the wildcard it replaces is a separate, non-trivial claim, so
// this chokepoint only ever removes.

import { readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { withSettingsLock } from '../lib/settings-lock.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ALLOW_ARRAY = /"allow"\s*:\s*\[([\s\S]*?)\]/;
const ELEMENT_LINE = /^(\s*)("(?:\\.|[^"\\])*")(,?)\s*$/;

function fail(message) {
  throw new Error(message);
}

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`);
  }
}

function serialized(value) {
  return JSON.stringify(value);
}

export function assertStrictNarrowing(beforeAllow, afterAllow) {
  const beforeCounts = new Map();
  for (const entry of beforeAllow) beforeCounts.set(entry, (beforeCounts.get(entry) || 0) + 1);
  const afterCounts = new Map();
  for (const entry of afterAllow) afterCounts.set(entry, (afterCounts.get(entry) || 0) + 1);

  for (const [entry, count] of afterCounts) {
    if (count > (beforeCounts.get(entry) || 0)) {
      fail(`permissions.allow gained an entry not present before: ${entry}`);
    }
  }
  if (afterAllow.length >= beforeAllow.length) {
    fail('permissions.allow did not shrink; refusing to write');
  }
}

export function assertDenyAskUnchanged(before, after) {
  for (const field of ['deny', 'ask']) {
    const beforeValue = before?.permissions?.[field];
    const afterValue = after?.permissions?.[field];
    if (serialized(beforeValue) !== serialized(afterValue)) {
      fail(`permissions.${field} changed; refusing to write`);
    }
  }
}

const ALLOW_SENTINEL = '__NARROW_ALLOW_SENTINEL__';

function scrubAllow(settings) {
  const copy = parseJson(JSON.stringify(settings), 'settings clone');
  if (copy?.permissions) copy.permissions.allow = ALLOW_SENTINEL;
  return copy;
}

export function assertOnlyAllowChanged(before, after) {
  const scrubbedBefore = scrubAllow(before);
  const scrubbedAfter = scrubAllow(after);
  if (serialized(scrubbedBefore) !== serialized(scrubbedAfter)) {
    fail('a parsed field outside permissions.allow changed; refusing to write');
  }
}

export function rewriteSettingsText(text, removals) {
  if (!Array.isArray(removals) || removals.length === 0) fail('no removal entries supplied');
  if (new Set(removals).size !== removals.length) fail('duplicate removal entries supplied');

  const before = parseJson(text, 'settings input');
  const allow = before?.permissions?.allow;
  if (!Array.isArray(allow)) fail('permissions.allow must be an array of strings');

  const toRemove = new Set();
  for (const entry of removals) {
    const count = allow.filter((value) => value === entry).length;
    if (count > 1) fail(`entry appears ${count} times in permissions.allow, refusing ambiguous removal: ${entry}`);
    if (count === 1) toRemove.add(entry);
  }

  if (toRemove.size === 0) {
    return { output: text, removed: 0, alreadyNarrowed: true };
  }

  const match = text.match(ALLOW_ARRAY);
  if (!match) fail('could not locate permissions.allow array in settings text');

  const lines = match[1].split('\n');
  const keptLines = [];
  let lastElementIndex = -1;
  let removedCount = 0;

  for (const rawLine of lines) {
    if (rawLine.trim() === '') {
      keptLines.push(rawLine);
      continue;
    }
    const lineMatch = rawLine.match(ELEMENT_LINE);
    if (!lineMatch) fail(`unrecognised permissions.allow line, refusing text-level edit: ${rawLine}`);
    const [, indent, literal, comma] = lineMatch;
    const value = parseJson(literal, 'allow entry literal');
    if (toRemove.has(value)) {
      removedCount += 1;
      continue;
    }
    keptLines.push(`${indent}${literal}${comma}`);
    lastElementIndex = keptLines.length - 1;
  }

  if (removedCount !== toRemove.size) {
    fail(`expected to remove ${toRemove.size} textual entr${toRemove.size === 1 ? 'y' : 'ies'}, removed ${removedCount}`);
  }
  if (lastElementIndex === -1) fail('permissions.allow would become empty; refusing');

  // The former final element line still carries its trailing comma; the new
  // final element must not, or the rewritten array is invalid JSON.
  keptLines[lastElementIndex] = keptLines[lastElementIndex].replace(/,\s*$/, '');

  const start = match.index;
  const end = start + match[0].length;
  const output = `${text.slice(0, start)}"allow": [${keptLines.join('\n')}]${text.slice(end)}`;

  const after = parseJson(output, 'rewritten settings');

  const expectedAfterAllow = allow.filter((value) => !toRemove.has(value));
  if (serialized(after?.permissions?.allow) !== serialized(expectedAfterAllow)) {
    fail('text-level removal did not match the expected result; refusing to write');
  }

  // SECURITY GATE: this comparison is unconditional. The chokepoint is
  // trusted only because it refuses any widening or other mutation of the
  // permission policy, including permissions.deny/ask or any field outside
  // permissions.allow.
  assertStrictNarrowing(before.permissions.allow, after.permissions.allow);
  assertDenyAskUnchanged(before, after);
  assertOnlyAllowChanged(before, after);

  return { output, removed: removedCount, alreadyNarrowed: false };
}

function parseArgs(argv) {
  let check = false;
  const removals = [];
  const paths = [];
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--check') {
      check = true;
      continue;
    }
    if (arg === '--remove') {
      const value = argv[i + 1];
      if (value === undefined) fail('--remove requires a value');
      removals.push(value);
      i += 1;
      continue;
    }
    if (arg.startsWith('-')) fail(`unknown option: ${arg}`);
    paths.push(arg);
  }
  if (paths.length > 1) fail('only one settings path may be supplied');
  return { check, removals, settingsPath: paths[0] };
}

function defaultSettingsPath() {
  const projectDir = process.env.CLAUDE_PROJECT_DIR || resolve(HERE, '..', '..');
  return join(projectDir, '.claude', 'settings.json');
}

// Per-process unique temp path (HIMMEL-1586). A FIXED name (.narrow-allow.tmp)
// would collide between concurrent narrow-allow runs: one truncates the
// other's staged output mid-write, and a catch-path cleanup would delete a
// temp the winner is about to rename — defeating the atomicity this PR added.
// The pid + randomUUID suffix makes a collision essentially impossible, and
// the exclusive open (flag 'wx' in writeSettingsAtomic) turns the residual
// impossibility into a loud EEXIST instead of silent corruption.
export function tempPathFor(settingsPath) {
  return join(dirname(settingsPath), `.narrow-allow.tmp.${process.pid}.${randomUUID()}`);
}

// Atomic settings write (HIMMEL-1586): stage a UNIQUE sibling temp in the
// same directory, then rename it over the target. rename is atomic within a
// directory on every platform this repo targets, so an interruption between
// stage and swap can never leave settings.json truncated or empty —
// permissions.deny/ask cannot be dropped mid-write.
//
// `wx` opens with O_CREAT|O_EXCL: it FAILS (EEXIST) if the path already
// exists, so a staged temp can never silently clobber another's. Cleanup
// removes ONLY a temp THIS process staged (the `staged` flag): if the
// exclusive open failed, staged is false and a foreign temp at that path is
// left untouched; only a rename failure after a successful stage cleans up,
// so one process never deletes another's temp.
//
// tmpPath is optional so the test can pin an exact path and prove the
// exclusive-open semantics — a regression to a shared name + clobbering
// write turns the test red.
export function writeSettingsAtomic(settingsPath, output, tmpPath = tempPathFor(settingsPath)) {
  let staged = false;
  try {
    writeFileSync(tmpPath, output, { encoding: 'utf8', flag: 'wx' });
    staged = true;
    renameSync(tmpPath, settingsPath);
  } catch (error) {
    if (staged) { try { unlinkSync(tmpPath); } catch { /* best-effort cleanup of our own staged temp */ } }
    throw error;
  }
}

async function main() {
  try {
    const args = parseArgs(process.argv.slice(2));
    if (args.removals.length === 0) fail('at least one --remove <entry> is required');
    const settingsPath = resolve(args.settingsPath || defaultSettingsPath());
    // HIMMEL-1552: hold the shared settings lock across the whole read ->
    // transform -> write/rename, so the three sanctioned settings writers
    // (wire-hook-bash, wire-trust-hooks, narrow-allow) serialise rather than
    // race. Without it, a concurrent writer's change that lands AFTER this
    // read but BEFORE this rename is silently reverted — last-writer-wins on
    // stale input.
    await withSettingsLock(settingsPath, () => {
      const input = readFileSync(settingsPath, 'utf8');
      const { output, removed, alreadyNarrowed } = rewriteSettingsText(input, args.removals);

      if (args.check) {
        const action = alreadyNarrowed
          ? 'already narrowed; no change needed'
          : `would remove ${removed} allow entr${removed === 1 ? 'y' : 'ies'}`;
        process.stdout.write(`narrow-allow: check passed for ${settingsPath} — ${action}; wrote nothing\n`);
        return;
      }

      if (alreadyNarrowed) {
        process.stdout.write(`narrow-allow: ${settingsPath} is already narrowed; no change made\n`);
        return;
      }

      writeSettingsAtomic(settingsPath, output);
      process.stdout.write(`narrow-allow: removed ${removed} allow entr${removed === 1 ? 'y' : 'ies'} from ${settingsPath}; deny/ask unchanged\n`);
    });
  } catch (error) {
    process.stderr.write(`narrow-allow: REFUSED — ${error.message}\n`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
