#!/usr/bin/env node
// op-env-parity — compare himmel/.env KEY NAMES against the variable names of a
// 1Password Environment, and report drift (keys present in one but not the other).
//
// KEYS ONLY. This tool never reads, prints, compares, or otherwise handles secret
// VALUES. From .env it captures only the token left of the first `=`; the
// Environment side is supplied as a list of variable NAMES.
//
// Why the Environment names come from a file/stdin rather than a live read:
// 1Password Environments are exposed only through the desktop app and the
// `onepassword` MCP server (a Labs experiment) — the `op` CLI has no
// environments-variable reader. So a Claude session dumps the Environment's
// variable names via the MCP `list_variables` tool (names only) into a manifest,
// and this checker diffs .env against that manifest. Refresh the manifest the
// same way when it drifts.
//
// Usage:
//   node scripts/op-env-parity.mjs --list-env-keys [--env <path>]
//       Print the .env key names (one per line, sorted). Names only.
//
//   node scripts/op-env-parity.mjs --op-keys <path|-> [--env <path>]
//       Compare .env keys against the Environment key list (JSON array of
//       strings, or newline-separated names; `-` reads stdin). Prints a drift
//       report and exits non-zero if there is any drift.
//
// Exit codes: 0 = in sync / list mode, 1 = drift found, 2 = usage/IO error.

import { readFileSync } from 'node:fs';

/** Split a line into whitespace-separated tokens, respecting single/double quotes so a
 * quoted value with spaces (FOO="a b") stays one token. Used only to locate NAME= starts;
 * values themselves are never returned to the caller. */
function tokenizeLine(line) {
  const tokens = [];
  let cur = '';
  let quote = null;
  let hasContent = false;
  for (const c of line) {
    if (quote) {
      cur += c;
      if (c === quote) quote = null;
    } else if (c === '"' || c === "'") {
      quote = c;
      cur += c;
      hasContent = true;
    } else if (/\s/.test(c)) {
      if (hasContent) {
        tokens.push(cur);
        cur = '';
        hasContent = false;
      }
    } else {
      cur += c;
      hasContent = true;
    }
  }
  if (hasContent) tokens.push(cur);
  return tokens;
}

/** Extract sorted, de-duplicated env-var KEY names from .env text. Values are never captured.
 * Multiple assignments on one physical line (e.g. `HIMMEL_WHERE_ARE_WE=1 USER_SLUG=exampleuser`)
 * are each captured — matching how a shell and 1Password's importer treat them. A bare
 * leading `export` token has no `=` and is skipped naturally. */
export function parseEnvKeys(text) {
  const keys = new Set();
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trimStart();
    if (line === '' || line.startsWith('#')) continue;
    for (const token of tokenizeLine(line)) {
      // A token that starts with `#` begins an inline comment (whitespace-delimited,
      // outside quotes) — stop, so `FOO=bar # NOTE=x` does not mint a phantom NOTE key.
      // `#` inside a quoted value (FOO="a # b") or with no leading space (FOO=a#b) stays
      // part of that single token and is captured as its name.
      if (token.startsWith('#')) break;
      // Capture group 1 = the name; everything from `=` onward (the value) is ignored.
      const m = token.match(/^([A-Za-z_][A-Za-z0-9_]*)=/);
      if (m) keys.add(m[1]);
    }
  }
  return [...keys].sort();
}

/** Parse an Environment key list: JSON array of strings, or newline-separated names. */
export function parseOpKeys(text) {
  const trimmed = text.trim();
  let names;
  if (trimmed.startsWith('[')) {
    const parsed = JSON.parse(trimmed);
    if (!Array.isArray(parsed)) throw new Error('op-keys JSON must be an array of strings');
    names = parsed;
  } else {
    names = trimmed.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  }
  const keys = new Set();
  for (const n of names) {
    if (typeof n !== 'string' || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(n)) {
      throw new Error(`invalid variable name in op-keys: ${JSON.stringify(n)}`);
    }
    keys.add(n);
  }
  return [...keys].sort();
}

/** Diff two key-name lists. Returns names missing from each side. */
export function diffKeys(envKeys, opKeys) {
  const envSet = new Set(envKeys);
  const opSet = new Set(opKeys);
  return {
    missingInOp: envKeys.filter((k) => !opSet.has(k)).sort(), // in .env, absent from Environment
    missingInEnv: opKeys.filter((k) => !envSet.has(k)).sort(), // in Environment, absent from .env
  };
}

/** Build the human-readable drift report. `renamed` is not detected directly — a rename
 * surfaces as one entry in each list; the report says so. Pure: takes counts + diff. */
export function formatReport(envKeys, opKeys, diff) {
  const lines = [];
  lines.push(`.env keys:         ${envKeys.length}`);
  lines.push(`Environment keys:  ${opKeys.length}`);
  const inSync = diff.missingInOp.length === 0 && diff.missingInEnv.length === 0;
  if (inSync) {
    lines.push('');
    lines.push('OK — key sets are identical.');
    return lines.join('\n');
  }
  if (diff.missingInOp.length) {
    lines.push('');
    lines.push(`In .env but NOT in Environment (${diff.missingInOp.length}):`);
    for (const k of diff.missingInOp) lines.push(`  - ${k}`);
  }
  if (diff.missingInEnv.length) {
    lines.push('');
    lines.push(`In Environment but NOT in .env (${diff.missingInEnv.length}):`);
    for (const k of diff.missingInEnv) lines.push(`  + ${k}`);
  }
  if (diff.missingInOp.length && diff.missingInEnv.length) {
    lines.push('');
    lines.push('Note: a renamed key appears as one `-` (old name) and one `+` (new name).');
  }
  return lines.join('\n');
}

function parseArgs(argv) {
  const opts = { env: '.env', opKeys: null, listEnvKeys: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--env') opts.env = argv[++i];
    else if (a === '--op-keys') opts.opKeys = argv[++i];
    else if (a === '--list-env-keys') opts.listEnvKeys = true;
    else if (a === '-h' || a === '--help') opts.help = true;
    else throw new Error(`unknown argument: ${a}`);
  }
  return opts;
}

const HELP = `op-env-parity — compare .env key NAMES against a 1Password Environment's variable names (keys only, never values)

  node scripts/op-env-parity.mjs --list-env-keys [--env <path>]
  node scripts/op-env-parity.mjs --op-keys <path|-> [--env <path>]

Refresh the Environment key list with a Claude session:
  mcp__onepassword__list_variables → save "variableNames" as a JSON array.`;

function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(`${e.message}\n\n${HELP}\n`);
    process.exit(2);
  }
  if (opts.help) {
    process.stdout.write(`${HELP}\n`);
    return;
  }

  let envText;
  try {
    envText = readFileSync(opts.env, 'utf8');
  } catch (e) {
    process.stderr.write(`cannot read env file ${opts.env}: ${e.message}\n`);
    process.exit(2);
  }
  const envKeys = parseEnvKeys(envText);

  if (opts.listEnvKeys) {
    process.stdout.write(envKeys.join('\n') + (envKeys.length ? '\n' : ''));
    return;
  }

  if (!opts.opKeys) {
    process.stderr.write(`missing --op-keys (or use --list-env-keys)\n\n${HELP}\n`);
    process.exit(2);
  }

  let opText;
  try {
    opText = opts.opKeys === '-' ? readFileSync(0, 'utf8') : readFileSync(opts.opKeys, 'utf8');
  } catch (e) {
    process.stderr.write(`cannot read op-keys ${opts.opKeys}: ${e.message}\n`);
    process.exit(2);
  }
  let opKeys;
  try {
    opKeys = parseOpKeys(opText);
  } catch (e) {
    process.stderr.write(`bad op-keys: ${e.message}\n`);
    process.exit(2);
  }

  const diff = diffKeys(envKeys, opKeys);
  process.stdout.write(formatReport(envKeys, opKeys, diff) + '\n');
  const drift = diff.missingInOp.length > 0 || diff.missingInEnv.length > 0;
  process.exit(drift ? 1 : 0);
}

// Run main only when invoked directly (not when imported by the test).
if (process.argv[1]?.endsWith('op-env-parity.mjs')) {
  main();
}
