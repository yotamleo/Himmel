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
    } else if (arg === '--json') {
      args.json = true;
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

// commandFor() bakes EXACTLY `GUARDRAIL_BASH="<bash>" "<node>" "<wrapper>"
// "<script>"` — four double-quoted segments, nothing before or after. This
// is the inverse, but STRICT (CR fix, codex-adv-5): the `$` anchor requires
// the match to consume the WHOLE command string, so a trailing shell
// comment or any extra token after the 4th quoted segment fails the match
// entirely (returns null) rather than being silently ignored. Contrast with
// the pre-fix parseOwnedCommand(), which took the first three quoted
// segments off `rest` via matchAll and never checked what followed them —
// reproduced: a command whose real script arg is a decoy (e.g.
// "claude-stub.sh") with the guardrail's actual basename sitting in a
// trailing `# comment` still parsed "successfully" into 3 args, since the
// comment text was simply never looked at.
const GENERATED_COMMAND_RE = /^GUARDRAIL_BASH="([^"]*)"\s+"([^"]*)"\s+"([^"]*)"\s+"([^"]*)"\s*$/;

function parseGeneratedCommand(hook) {
  if (!hook || hook.type !== 'command' || typeof hook.command !== 'string') return null;
  const match = hook.command.match(GENERATED_COMMAND_RE);
  if (!match) return null;
  const [, bashPath, nodePath, wrapperPath, scriptPath] = match;
  return { bashPath, nodePath, wrapperPath, scriptPath };
}

// CR fix (codex-adv-5): ownership is IDENTITY, not mention. The pre-fix
// isOwnedHook() substring-searched the WHOLE command string for `basename`
// — matching a guardrail's name anywhere, including inside an inert
// trailing comment, while the actual (4th quoted) script argument pointed
// somewhere else entirely. This checks the PARSED wrapper/script paths'
// basenames against the expected constants exactly (path.basename(), never
// String#includes()) — a decoy command whose real script arg doesn't match
// `guardrail.basename` is not owned by this guardrail, full stop, no matter
// what a comment elsewhere in the string claims.
function ownsGuardrail(parsed, guardrail) {
  return Boolean(parsed)
    && path.basename(parsed.wrapperPath) === WRAPPER
    && path.basename(parsed.scriptPath) === guardrail.basename;
}

// Returns { hook, matcher, parsed } for EVERY owned entry matching
// `guardrail` (order = hookGroups() traversal order), keeping each entry's
// ENCLOSING group matcher alongside the hook itself — unlike isOwnedHook()
// above (used by installData()/removeData() for CLEANUP, where a loose
// substring match is the correct, DELIBERATE behavior: catching any
// hand-edited/stale hook that merely mentions the wrapper is a feature
// there, not a bug) — and unlike an earlier round's singular
// findOwnedHookInfo(), which returned only the FIRST match (CR fix,
// codex-adv-4: installData()'s own dedup step — "remove EVERY existing
// owned hook for this guardrail" — exists precisely because duplicate owned
// entries for the same basename are a real drift state; a second,
// dead-pathed duplicate is invisible to a probe that only ever looks at the
// first hit, even though it can still independently fire and fail closed at
// runtime). This is the STRICT counterpart used ONLY by the status --json
// attestation contract below — never by installData()/removeData(), whose
// loose cleanup semantics are unchanged and out of scope for this ticket.
function findGuardrailEntries(data, guardrail) {
  const found = [];
  for (const group of hookGroups(data)) {
    if (!Array.isArray(group.hooks)) continue;
    for (const hook of group.hooks) {
      const parsed = parseGeneratedCommand(hook);
      if (ownsGuardrail(parsed, guardrail)) found.push({ hook, matcher: group.matcher, parsed });
    }
  }
  return found;
}

// CR fix (codex-adv-7, round 5): round 4's ANCHORED GENERATED_COMMAND_RE
// correctly rejects a TRUE decoy (wrong script identity, real basename only
// in an inert trailing comment) — but it also makes an entry with the SAME
// wrapper/script identity plus a trailing extra token/comment invisible
// entirely, not merely "not canonical". That's wrong: guardrail-skip-in-
// himmel.js reads only process.argv[2] (the script path) and ignores
// anything after it, so Claude Code still executes such an entry
// identically to a canonical one — it is RUNTIME-RELEVANT. A duplicate
// wired in this shape with a dead node/bash path would fail closed on
// matching tool calls while sitting completely outside this contract's
// enumeration (entryCount would stay 1, complete:true), reopening exactly
// the blind spot round 3's duplicate detection was built to close, just
// through a different command shape.
//
// This is the BOUNDED structural test for "references our identity without
// being canonical": extract every double-quoted segment in the command
// (regardless of position — no `^`/`$` anchor, no fixed arg count) and
// check whether ANY of them, taken as a whole quoted VALUE and reduced with
// path.basename(), equals WRAPPER, and ANY (possibly a different one)
// equals guardrail.basename. This is deliberately NOT the old whole-string
// substring search (String#includes over the entire command) that codex-
// adv-5 fixed: a basename sitting in an unquoted trailing `# comment` is
// never captured by the quote-extraction regex at all, so it still reads as
// a decoy/not-owned, exactly preserving round 4's fix. Only an ACTUAL
// quoted path argument whose basename matches counts.
function referencesGuardrailIdentity(hook, guardrail) {
  if (!hook || hook.type !== 'command' || typeof hook.command !== 'string') return false;
  const quoted = [...hook.command.matchAll(/"([^"]*)"/g)].map((m) => m[1]);
  const hasWrapper = quoted.some((q) => path.basename(q) === WRAPPER);
  const hasScript = quoted.some((q) => path.basename(q) === guardrail.basename);
  return hasWrapper && hasScript;
}

// Returns { hook, matcher } for every hook that references `guardrail`'s
// identity (wrapper + script basenames, as quoted arguments) but did NOT
// match the canonical generated shape in findGuardrailEntries() — i.e. the
// tier-2 "runtime-relevant but non-attestable" anomaly this fix exists to
// surface. A hook already counted as canonical is excluded here (it would
// otherwise be double-counted as its own anomaly, since a canonical command
// trivially also "references" its own identity).
function findNonCanonicalEntries(data, guardrail) {
  const found = [];
  for (const group of hookGroups(data)) {
    if (!Array.isArray(group.hooks)) continue;
    for (const hook of group.hooks) {
      if (ownsGuardrail(parseGeneratedCommand(hook), guardrail)) continue;
      if (referencesGuardrailIdentity(hook, guardrail)) found.push({ hook, matcher: group.matcher });
    }
  }
  return found;
}

// CR fix (codex-adv-3): fs.existsSync() alone accepts a DIRECTORY, an
// unreadable file, or (for node/bash) a non-executable file as "resolves" —
// reproduced complete:true with a baked path pointing at a plain directory.
// isFile() is the load-bearing, fully portable check (a directory always
// fails it, on every platform); the accessSync() mode check layers on top
// but is a WEAK signal on Windows specifically — fs.accessSync(path, X_OK)
// on Windows has no real executable-bit concept and behaves like F_OK (just
// existence), confirmed empirically here, so it does not actually catch a
// non-executable regular file on Windows the way it does on POSIX. isFile()
// is what does the real work cross-platform; the mode check is included
// because it's free, harmless, and is the meaningful check on POSIX.
function isReadableFile(p) {
  let stat;
  try {
    stat = fs.statSync(p);
  } catch (_e) {
    return false;
  }
  if (!stat.isFile()) return false;
  try {
    fs.accessSync(p, fs.constants.R_OK);
  } catch (_e) {
    return false;
  }
  return true;
}

function isRunnableExecutable(p) {
  if (!isReadableFile(p)) return false;
  try {
    fs.accessSync(p, fs.constants.X_OK);
  } catch (_e) {
    return false;
  }
  return true;
}

// Resolves ONE owned entry ({ hook, matcher, parsed } from
// findGuardrailEntries — `parsed` is already strictly matched, so no null
// check is needed here) into its status --json shape (everything but
// basename/present/entryCount, which the caller already knows). Shared by
// the "primary" (first-found) entry and every entry in `duplicates`, so
// both are checked identically.
function resolveOwnedEntry(info, guardrail) {
  return {
    matcher: info.matcher ?? null,
    matcherMatches: (info.matcher ?? null) === guardrail.matcher,
    bashPath: info.parsed.bashPath,
    bashResolves: isRunnableExecutable(info.parsed.bashPath),
    nodePath: info.parsed.nodePath,
    nodeResolves: isRunnableExecutable(info.parsed.nodePath),
    wrapperPath: info.parsed.wrapperPath,
    wrapperResolves: isReadableFile(info.parsed.wrapperPath),
    scriptPath: info.parsed.scriptPath,
    scriptResolves: isReadableFile(info.parsed.scriptPath),
  };
}

// `status --json` contract (HIMMEL-1418, extended by CR fixes codex-adv-1/2,
// then codex-adv-3/4, then codex-adv-5): a STABLE, machine-readable
// enumeration of every EXPECTED guardrail hook (GUARDRAILS, in that fixed
// order), each with its own presence + matcher + usability detail — unlike
// the plain `status` verb below (kept byte-for-byte unchanged: himmel-
// update.sh's report_guardrail_block parses it), which only ever proves "at
// least one owned hook exists and ITS node path resolves" (detectMode()'s
// `.some()`, nodeResolves()'s first-match return). SCOPE (fixed as of
// codex-adv-3/4/5, round 4): this contract attests the FULL GENERATED
// COMMAND IDENTITY — presence, resolution, matcher, uniqueness, and shape —
// of the configured hook wiring. It does NOT execute the hook chain, check
// node/bash versions, reason about ACLs beyond isFile()+access(), or judge
// semantic equivalence of a differently-FORMED-but-still-correct command;
// that is explicitly out of scope for this ticket (a deeper runtime-proof
// contract, if ever wanted, is a follow-up ticket, not an extension here).
//
// Ownership semantics (CR fix, codex-adv-5, refined by codex-adv-7 — round
// 5): "owned by guardrail X" (canonical, drives entryCount/present/paths)
// means the ENTIRE command string parses as EXACTLY the generated shape
// (GENERATED_COMMAND_RE — 4 quoted segments, nothing trailing) AND the
// parsed script arg's basename === X's basename. A command that merely
// MENTIONS X's basename somewhere (e.g. in an unquoted trailing `# comment`)
// while its real (4th quoted) script arg points elsewhere is a TRUE DECOY —
// not owned by X, or by ANY guardrail — it reads present:false/entryCount:0
// for every GUARDRAILS entry, i.e. plain "missing", the same as if nothing
// were wired at all. This was the deliberately chosen semantic for decoys
// (over "owned but flagged"): the contract's job is to attest whether the
// REAL protection is wired, and a decoy is not real protection — "missing"
// is the most conservative, fail-closed characterization.
//
// BUT (codex-adv-7): a command whose wrapper/script ARE X's real identity —
// each appearing as an actual quoted argument, not a comment — that merely
// fails the canonical anchored shape (e.g. a trailing extra token/comment
// AFTER the 4th quoted segment) is NOT a decoy: guardrail-skip-in-himmel.js
// reads only process.argv[2] (the script path) and ignores anything after
// it, so Claude Code still executes this entry identically to a canonical
// one. Silently treating it as "missing" (round 4's blanket answer) would
// hide a genuinely runtime-relevant duplicate — reopening exactly the
// round-3 blind spot this ticket already closed once, just via a different
// command shape. `nonCanonicalCount`/`nonCanonical` (below) surface this as
// its own tracked anomaly, distinct from both a decoy (not referenced at
// all) and a canonical duplicate (entryCount, round 3): it FORCES
// complete:false for the affected guardrail even when the canonical entry
// alone would otherwise be perfectly valid, because an ignored-but-still-
// wired duplicate with a dead node/bash path can still fail closed on a
// matching real tool call.
//
// A decoy sitting in an otherwise mode=global settings.json (detectMode()
// still uses the intentionally loose isOwnedHook() below, so mode can read
// "global" off a decoy alone) simply yields entryCount:0/nonCanonicalCount:0
// for every real guardrail, so `complete` still correctly reads false and
// the probe's detail still correctly says "<basename>: missing" — never a
// false "present". Shape:
//   {
//     "mode": "global" | "project",
//     "complete": boolean,  // true iff mode === "global" AND every hook
//                            // below has EXACTLY ONE owned entry
//                            // (entryCount === 1), that entry's ACTUAL
//                            // matcher exactly equals expectedMatcher, and
//                            // its bash/node/wrapper/script paths are all
//                            // USABLE (see below). false otherwise.
//     "hooks": [
//       {
//         "basename": string,        // e.g. "auto-approve-safe-bash.sh"
//         "matcher": string|null,    // the FIRST-FOUND owned entry's ACTUAL
//                                    // PreToolUse matcher (null if absent)
//         "expectedMatcher": string, // the matcher this hook NEEDS for full
//                                    // tool coverage (GUARDRAILS' own value)
//         "matcherMatches": boolean, // matcher === expectedMatcher, EXACT
//                                    // string equality — a looser "does
//                                    // matcher cover expectedMatcher's tool
//                                    // set" check would need to parse both
//                                    // as alternation regexes and reason
//                                    // about set containment; exact-match is
//                                    // the simplest rule that can never
//                                    // silently under-verify coverage, at
//                                    // the cost of flagging a hand-authored
//                                    // matcher that's a harmless superset
//                                    // as non-compliant too (acceptable: an
//                                    // operator who wants to relax this
//                                    // should re-run setup-hooks, not craft
//                                    // one by hand).
//         "present": boolean,        // >= 1 owned hook entry exists for this basename
//         "entryCount": number,      // TOTAL owned entries found for this
//                                    // basename (CR fix, codex-adv-4:
//                                    // installData()'s own dedup step
//                                    // proves duplicate owned entries are a
//                                    // real drift state — a dead-pathed
//                                    // duplicate is still independently
//                                    // wired and can fail closed at
//                                    // runtime, so `complete` requires
//                                    // EXACTLY 1, not merely >= 1)
//         "bashPath": string|null,   // FIRST-FOUND entry's fields below —
//         "bashResolves": boolean,   // ADDITIONAL entries (if entryCount > 1)
//         "nodePath": string|null,   // are in `duplicates`, same shape as
//         "nodeResolves": boolean,   // this block minus basename/present/
//         "wrapperPath": string|null,// entryCount/duplicates itself.
//         "wrapperResolves": boolean,
//         "scriptPath": string|null,
//         "scriptResolves": boolean, // *Resolves fields (CR fix, codex-adv-3):
//                                    // "usable", not merely fs.existsSync().
//                                    // wrapper/script (passed as ARGUMENTS to
//                                    // node/bash, never exec'd directly) need
//                                    // only be a regular, READABLE file.
//                                    // node/bash (spawned as the executable
//                                    // itself) additionally need X_OK. isFile()
//                                    // is the load-bearing, fully portable
//                                    // check — it is what actually rejects a
//                                    // DIRECTORY, which fs.existsSync() alone
//                                    // accepted (the reproduced false-green).
//                                    // The X_OK layer is a WEAK signal on
//                                    // Windows specifically: fs.accessSync
//                                    // (path, X_OK) has no real executable-bit
//                                    // concept there and behaves like F_OK
//                                    // (existence only, confirmed empirically)
//                                    // — so a non-executable-but-readable file
//                                    // baked as the node/bash path will NOT
//                                    // be caught on Windows, only on POSIX.
//         "duplicates": [ /* same per-entry shape as above, one per
//                            ADDITIONAL owned entry beyond the first-found;
//                            [] when entryCount <= 1 */ ],
//         "nonCanonicalCount": number, // CR fix, codex-adv-7 (round 5):
//                                    // commands that reference THIS
//                                    // guardrail's wrapper+script identity
//                                    // as actual quoted arguments (not a
//                                    // comment mention — see
//                                    // referencesGuardrailIdentity()) but
//                                    // fail the canonical anchored shape
//                                    // (e.g. a trailing extra token). These
//                                    // are RUNTIME-RELEVANT (the wrapper
//                                    // only reads argv[2] and ignores the
//                                    // rest) yet excluded from entryCount —
//                                    // `complete` requires this to be 0.
//         "nonCanonical": [ /* { matcher, command } per anomaly above;
//                              [] when nonCanonicalCount is 0 */ ]
//       },
//       ... one entry per GUARDRAILS item, in GUARDRAILS order (stable) ...
//     ]
//   }
// Field names/order and hook order are fixed once shipped — this is a probe
// contract (scripts/himmelctl/lib/probes.js's cmd:guardrail_block_status).
export function statusDetail(data) {
  const mode = detectMode(data);
  const hooks = GUARDRAILS.map((guardrail) => {
    const found = findGuardrailEntries(data, guardrail);
    const nonCanonical = findNonCanonicalEntries(data, guardrail);
    const entry = {
      basename: guardrail.basename,
      matcher: null,
      expectedMatcher: guardrail.matcher,
      matcherMatches: false,
      present: found.length > 0,
      entryCount: found.length,
      bashPath: null,
      bashResolves: false,
      nodePath: null,
      nodeResolves: false,
      wrapperPath: null,
      wrapperResolves: false,
      scriptPath: null,
      scriptResolves: false,
      duplicates: [],
      nonCanonicalCount: nonCanonical.length,
      nonCanonical: nonCanonical.map((info) => ({ matcher: info.matcher ?? null, command: info.hook.command })),
    };
    if (found.length > 0) {
      const primary = resolveOwnedEntry(found[0], guardrail);
      entry.matcher = primary.matcher;
      entry.matcherMatches = primary.matcherMatches;
      entry.bashPath = primary.bashPath;
      entry.bashResolves = primary.bashResolves;
      entry.nodePath = primary.nodePath;
      entry.nodeResolves = primary.nodeResolves;
      entry.wrapperPath = primary.wrapperPath;
      entry.wrapperResolves = primary.wrapperResolves;
      entry.scriptPath = primary.scriptPath;
      entry.scriptResolves = primary.scriptResolves;
      entry.duplicates = found.slice(1).map((info) => resolveOwnedEntry(info, guardrail));
    }
    return entry;
  });
  const complete = mode === 'global' && hooks.every((h) => (
    h.entryCount === 1 && h.nonCanonicalCount === 0
      && h.matcherMatches && h.bashResolves && h.nodeResolves && h.wrapperResolves && h.scriptResolves
  ));
  return { mode, complete, hooks };
}

function run(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  const command = args._[0];
  const file = settingsPath();

  if (!['detect', 'install', 'remove', 'status', 'global', 'project'].includes(command)) {
    throw new Error('usage: guardrail-block.mjs detect|install|remove|status|global|project [--node ABS --bash ABS] [--stamp VALUE] [--json]');
  }

  const { text, data } = readSettings(file);

  if (command === 'detect') {
    process.stdout.write(`${detectMode(data)}\n`);
    return;
  }

  if (command === 'status') {
    if (args.json) {
      process.stdout.write(`${JSON.stringify(statusDetail(data))}\n`);
    } else {
      process.stdout.write(`guardrail-mode=${detectMode(data)} node-resolves=${nodeResolves(data) ? 'yes' : 'no'}\n`);
    }
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
