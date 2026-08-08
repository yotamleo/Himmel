#!/usr/bin/env node
// wire-session-telemetry-hooks.mjs — HIMMEL-1635: install/remove the
// HIMMEL-1052 session-telemetry writer's four hook entries in
// `.claude/settings.json`.
//
// WHY THIS EXISTS
// session-run-hook.ts shipped with its wiring documented in README.md's
// "Wiring the writer" section as four JSON blocks to paste by hand. The
// trust ledger (HIMMEL-1551) shipped the same way first and paid for it:
// three chain legs measured zero rows because nothing ever pasted the
// blocks in. A capability that ships behind a manual paste is a capability
// that does not ship. This makes the wiring reviewable in a PR, versioned,
// idempotent, and reversible — modeled directly on
// scripts/trust/wire-trust-hooks.mjs (HIMMEL-1551).
//
// WHY A SCRIPT IS ALLOWED TO WRITE A DENY-LISTED FILE
// `Edit(**/.claude/settings.json)` is deny-listed so nothing edits it ad hoc.
// A reviewed script with a narrow, asserted mutation is the sanctioned path;
// an agent's free-form Edit is not. That distinction only holds while the
// assertions below hold, so they are unconditional.
//
// COEXISTENCE WITH OTHER SANCTIONED WRITERS
// wire-hook-bash.mjs (HIMMEL-1516/1552) owns PreToolUse/PostToolUse/
// SessionStart, but only commands matching its own `scripts/hooks/*.sh`
// routing pattern — a `bun .../session-run-hook.ts` command never matches
// that pattern, so it is invisible to wire-hook-bash's owned-inventory count
// (own-only validation, HIMMEL-1552 style) and the two writers never
// disagree about it. wire-trust-hooks.mjs owns its own `shadow-ledger.mjs`
// commands the same way. All three hold the SAME shared lock
// (scripts/lib/settings-lock.mjs) across their read -> transform -> write,
// so they serialise rather than race.
//
// The PostToolUse "Agent" matcher group already carries
// auto-arm-on-subagent-cap.sh's hook (wired by wire-hook-bash). This script
// APPENDS its own hook into that existing group rather than creating a
// second "Agent" group — ownership below is tracked per HOOK OBJECT, not
// per group (the wire-hook-bash model), specifically so two independent
// writers can share one matcher group without either refusing the other's
// hook or disturbing it.
//
// USAGE
//   node wire-session-telemetry-hooks.mjs            # install (idempotent)
//   node wire-session-telemetry-hooks.mjs --off      # remove (idempotent)
//   node wire-session-telemetry-hooks.mjs --check    # report, write nothing
//   node wire-session-telemetry-hooks.mjs [--...] <settings-path>

import {
  existsSync, readFileSync, renameSync, unlinkSync, writeFileSync,
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { acquireLock } from '../lib/settings-lock.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

// `"timeout": 10` is not decoration. A command hook defaults to 600 SECONDS,
// so a stalled writer (a full disk, a wedged filesystem) would hold every
// matching tool call for ten minutes — the one failure mode a fail-open
// telemetry writer must never cause. See session-run-hook.ts's own header:
// it is designed to always exit 0 fast, but the hook-side timeout is the
// backstop if that design is ever violated.
const TIMEOUT = 10;

// $CLAUDE_PROJECT_DIR is QUOTED inside the command string deliberately: an
// unquoted expansion word-splits on a project path containing a space, and
// the hook then fails open — losing observations silently, which is the one
// failure mode a measurement tool must not have.
const WRITER_PATH = '"$CLAUDE_PROJECT_DIR/scripts/observability/session-run-hook.ts"';

// The four entries, exactly as documented in README.md's "Wiring the
// writer" (HIMMEL-1052). `matcher: null` means no matcher key is emitted —
// SessionStart/SessionEnd fire on every session lifecycle event regardless
// of which tool (if any) is involved, so narrowing with a matcher would open
// a gap.
export const ENTRIES = [
  { event: 'SessionStart', matcher: null, verb: 'session-start' },
  { event: 'SessionEnd', matcher: null, verb: 'session-end' },
  { event: 'PreToolUse', matcher: 'Agent', verb: 'subagent-start' },
  { event: 'PostToolUse', matcher: 'Agent', verb: 'subagent-end' },
];

const commandFor = (verb) => `bun ${WRITER_PATH} ${verb}`;

function hookFor(spec) {
  return { type: 'command', command: commandFor(spec.verb), timeout: TIMEOUT };
}

// Two recognition layers, deliberately separate (mirrors wire-trust-hooks'
// isLedgerCommand + the per-spec canonical command it pairs with):
//   - WRITER-level (isWriterCommand): quote- and argument-insensitive. A
//     command that merely INVOKES this writer, in ANY shape — an unquoted
//     $CLAUDE_PROJECT_DIR, a `bun run` form, a stray extra flag — is "ours"
//     generically: enough to walk, repair, or strip it.
//   - SPEC-level (isOurs): our writer AND carrying THIS spec's verb as one of
//     its arguments, so a session-start hook never reads as a session-end one.
// Exact canonical match is a THIRD question (matchesCanonical / statusOf): it
// decides wired-vs-not and NEVER who owns the object. Keeping "owned" broader
// than "canonical" is exactly what lets install converge a near-variant IN
// PLACE instead of appending a duplicate (both would fire, every event twice),
// and lets --off strip the variant too instead of stranding it.
const isWriterCommand = (cmd) => typeof cmd === 'string' && cmd.includes('/scripts/observability/session-run-hook.ts');

// Does this hook object belong to THIS spec — our writer, invoked with this
// spec's verb? The verb is the writer's argument and is matched as a
// whitespace-delimited token, so the four verbs never cross-match. This is NOT
// a canonical check: a near-variant shape still counts as ours.
function isOurs(hook, spec) {
  if (!hook || !isWriterCommand(hook.command)) return false;
  return hook.command.trim().split(/\s+/).includes(spec.verb);
}

// Does this hook object match the canonical wiring EXACTLY — command AND
// timeout, nothing extra? Command equality alone is not enough: a
// hand-pasted entry could carry the right command with NO timeout, and a
// command hook defaults to 600 seconds.
function matchesCanonical(hook, spec) {
  return JSON.stringify(hook) === JSON.stringify(hookFor(spec));
}

// A group "matches" a spec's matcher if its `matcher` key equals the spec's
// (both absent/null for SessionStart+SessionEnd, both the literal string for
// PreToolUse/PostToolUse "Agent"). Distinguishes matcher-less groups from a
// group whose matcher happens to be the empty string, which JSON permits.
function matcherMatches(group, spec) {
  const groupMatcher = group && Object.prototype.hasOwnProperty.call(group, 'matcher')
    ? group.matcher
    : null;
  return groupMatcher === spec.matcher;
}

function fail(message) {
  throw new Error(message);
}

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch (e) {
    fail(`${label} is not valid JSON: ${e.message}`);
  }
}

// Same one-layer-short trap wire-trust-hooks documents: the `hooks`
// CONTAINER and the settings ROOT must both be validated, not just the
// per-event arrays, or a malformed shape is silently destroyed by
// `{ ...settings }` / `{ ...hooks }` spreading it into a garbage
// index-keyed object.
function assertHooksContainer(settings) {
  if (settings === null || typeof settings !== 'object' || Array.isArray(settings)) {
    fail('settings root is not a JSON object — refusing to overwrite an unrecognised shape');
  }
  const h = settings.hooks;
  if (h === undefined) return;
  if (h === null || typeof h !== 'object' || Array.isArray(h)) {
    fail('hooks is not an object — refusing to overwrite an unrecognised shape');
  }
}

function assertEventShape(settings, event) {
  const list = settings.hooks?.[event];
  if (list !== undefined && !Array.isArray(list)) {
    fail(`hooks.${event} is not an array — refusing to overwrite an unrecognised shape`);
  }
}

function assertGroupShape(settings, event) {
  const list = settings.hooks?.[event];
  if (!Array.isArray(list)) return;
  list.forEach((group, i) => {
    if (!group || !Array.isArray(group.hooks)) {
      fail(`hooks.${event}[${i}].hooks must be an array — refusing to overwrite an unrecognised shape`);
    }
  });
}

// SECURITY GATE, unconditional. This script is trusted only because it
// refuses any change to the permission policy.
function assertPermissionsUnchanged(before, after) {
  const a = JSON.stringify(before?.permissions ?? null);
  const b = JSON.stringify(after?.permissions ?? null);
  if (a !== b) fail('permissions changed — refusing to write');
}

// Nothing outside `hooks` may differ. Cheap, total, and it catches an entire
// class of mistake (a stray key, a dropped section) that no targeted
// assertion would — same invariant wire-trust-hooks holds.
function assertOnlyHooksChanged(before, after) {
  const strip = (o) => {
    const copy = { ...o };
    delete copy.hooks;
    return JSON.stringify(copy);
  };
  if (strip(before) !== strip(after)) fail('a non-hook section changed — refusing to write');
}

// Find every hook object matching this spec across every group under
// event whose matcher matches the spec's. Returns [{ groupIndex, hookIndex }].
function findOurs(settings, spec) {
  const list = settings.hooks?.[spec.event];
  if (!Array.isArray(list)) return [];
  const found = [];
  list.forEach((group, groupIndex) => {
    if (!matcherMatches(group, spec)) return;
    const hooks = Array.isArray(group.hooks) ? group.hooks : [];
    hooks.forEach((hook, hookIndex) => {
      if (isOurs(hook, spec)) found.push({ groupIndex, hookIndex });
    });
  });
  return found;
}

export function install(settings) {
  assertHooksContainer(settings);
  for (const spec of ENTRIES) assertEventShape(settings, spec.event);
  for (const spec of ENTRIES) assertGroupShape(settings, spec.event);
  const next = structuredClone(settings);
  next.hooks = next.hooks ? { ...next.hooks } : {};
  let changed = 0;

  for (const spec of ENTRIES) {
    const matches = findOurs(next, spec);
    const list = Array.isArray(next.hooks[spec.event]) ? [...next.hooks[spec.event]] : [];
    next.hooks[spec.event] = list;

    if (matches.length === 0) {
      // Nothing of ours exists yet. If an existing group already carries this
      // spec's matcher (e.g. PostToolUse's pre-existing "Agent" group), append
      // our hook into THAT group rather than creating a second one sharing the
      // same matcher — never disturbing its existing hook(s). Otherwise, this
      // spec gets its own dedicated new group so it never has to guess which
      // matcher-less group (if several exist) it should join.
      const targetGroupIndex = spec.matcher !== null
        ? list.findIndex((g) => matcherMatches(g, spec))
        : -1;
      if (targetGroupIndex === -1) {
        const group = spec.matcher === null ? { hooks: [hookFor(spec)] } : { matcher: spec.matcher, hooks: [hookFor(spec)] };
        list.push(group);
      } else {
        const group = { ...list[targetGroupIndex] };
        group.hooks = [...group.hooks, hookFor(spec)];
        list[targetGroupIndex] = group;
      }
      changed += 1;
      continue;
    }

    // Converge to exactly ONE canonical hook per spec. Repair the first match
    // if it drifted from canonical (missing timeout, etc); drop any extras —
    // a duplicate would fire the writer twice per event.
    const [first, ...extras] = matches;
    const firstGroup = { ...list[first.groupIndex] };
    const firstHooks = [...firstGroup.hooks];
    if (!matchesCanonical(firstHooks[first.hookIndex], spec)) {
      firstHooks[first.hookIndex] = hookFor(spec);
      changed += 1;
    }
    firstGroup.hooks = firstHooks;
    list[first.groupIndex] = firstGroup;

    // Extras may span multiple groups; remove them, grouping by groupIndex.
    // Same-group extras (sharing first.groupIndex) are handled against the
    // already-updated firstHooks/firstGroup above.
    const sameGroupExtraIdx = extras
      .filter((e) => e.groupIndex === first.groupIndex)
      .map((e) => e.hookIndex);
    if (sameGroupExtraIdx.length > 0) {
      const kept = list[first.groupIndex].hooks.filter(
        (_, i) => i === first.hookIndex || !sameGroupExtraIdx.includes(i),
      );
      list[first.groupIndex] = { ...list[first.groupIndex], hooks: kept };
      changed += sameGroupExtraIdx.length;
    }

    const extrasByGroup = new Map();
    for (const e of extras) {
      if (e.groupIndex === first.groupIndex) continue; // handled above
      if (!extrasByGroup.has(e.groupIndex)) extrasByGroup.set(e.groupIndex, []);
      extrasByGroup.get(e.groupIndex).push(e.hookIndex);
    }
    for (const [groupIndex, hookIndices] of extrasByGroup) {
      const g = list[groupIndex];
      const kept = g.hooks.filter((_, i) => !hookIndices.includes(i));
      changed += hookIndices.length;
      list[groupIndex] = kept.length === 0 ? null : { ...g, hooks: kept };
    }
    next.hooks[spec.event] = list.filter((g) => g !== null);
  }

  return { settings: next, changed };
}

export function remove(settings) {
  assertHooksContainer(settings);
  for (const spec of ENTRIES) assertEventShape(settings, spec.event);
  for (const spec of ENTRIES) assertGroupShape(settings, spec.event);
  const next = structuredClone(settings);
  if (!next.hooks) return { settings: next, changed: 0 };
  next.hooks = { ...next.hooks };
  let removed = 0;

  for (const spec of ENTRIES) {
    const list = next.hooks[spec.event];
    if (!Array.isArray(list)) continue;
    const nextList = [];
    let removedFromEvent = 0;
    for (const group of list) {
      if (!matcherMatches(group, spec)) {
        nextList.push(group);
        continue;
      }
      const hooks = Array.isArray(group.hooks) ? group.hooks : [];
      const removedHere = hooks.filter((h) => isOurs(h, spec)).length;
      if (removedHere === 0) {
        nextList.push(group);
        continue;
      }
      removedFromEvent += removedHere;
      removed += removedHere;
      const kept = hooks.filter((h) => !isOurs(h, spec));
      // Drop the whole group only if OUR removal emptied it — a group that
      // still holds somebody else's hook (the PostToolUse "Agent" group's
      // auto-arm-on-subagent-cap.sh entry) must survive with just our hook
      // stripped out.
      if (kept.length > 0) {
        nextList.push({ ...group, hooks: kept });
      }
      // else: drop the group entirely (it was ours alone).
    }
    // Delete the event key ONLY when OUR removal emptied it (same guard as
    // wire-trust-hooks' `removedHere > 0 && kept.length === 0`). An array this
    // script never touched — a pre-existing `[]` under an owned event, or one
    // holding only foreign groups — is not ours to delete: doing so destroys a
    // key we did not create and breaks the byte-reversibility the serialize
    // guard (below in main) exists to protect. Snapshotting "did we remove
    // anything here" (removedFromEvent) is the byte-reversibility boundary.
    if (removedFromEvent > 0 && nextList.length === 0) {
      delete next.hooks[spec.event];
    } else {
      next.hooks[spec.event] = nextList;
    }
  }

  if (removed > 0 && Object.keys(next.hooks).length === 0) delete next.hooks;
  return { settings: next, changed: removed };
}

// "Wired" means canonical, not merely present.
export function statusOf(settings) {
  let duplicates = 0;
  const present = ENTRIES.filter((spec) => {
    const matches = findOurs(settings, spec);
    if (matches.length > 1) duplicates += matches.length - 1;
    return matches.some((m) => {
      const group = settings.hooks[spec.event][m.groupIndex];
      return matchesCanonical(group.hooks[m.hookIndex], spec);
    });
  });
  return { wired: present.length, total: ENTRIES.length, duplicates };
}

// Serialize exactly as the file already is — 2-space indent, trailing
// newline — so an install produces a minimal diff instead of reformatting
// the whole file into the review.
const serialize = (obj) => `${JSON.stringify(obj, null, 2)}\n`;

function parseArgs(argv) {
  let off = false;
  let check = false;
  const paths = [];
  for (const arg of argv) {
    if (arg === '--off') off = true;
    else if (arg === '--check') check = true;
    else if (arg.startsWith('-')) fail(`unknown option: ${arg}`);
    else paths.push(arg);
  }
  if (paths.length > 1) fail('only one settings path may be supplied');
  return { off, check, settingsPath: paths[0] };
}

// Same ambiguity refusal as wire-trust-hooks: no path argument and no
// CLAUDE_PROJECT_DIR while standing in a DIFFERENT project (one with its own
// .claude/) is refused rather than silently wiring the wrong checkout.
function defaultSettingsPath() {
  const fromEnv = process.env.CLAUDE_PROJECT_DIR;
  if (fromEnv) return join(fromEnv, '.claude', 'settings.json');
  const own = resolve(HERE, '..', '..');
  const cwdProject = resolve(process.cwd());
  if (cwdProject !== own && existsSync(join(cwdProject, '.claude'))) {
    fail(
      `ambiguous target: you are in ${cwdProject}, which has its own .claude/, but this `
      + `script lives in ${own}. Refusing to guess which one you meant — pass the settings `
      + 'path explicitly, or set CLAUDE_PROJECT_DIR.',
    );
  }
  return join(own, '.claude', 'settings.json');
}

// The hooks resolve `$CLAUDE_PROJECT_DIR/scripts/observability/session-run-
// hook.ts` AT RUNTIME against whatever project the session is rooted in.
// Existence is a precondition on install (never on --off/--check — removing
// dead wiring, or reporting on it, must still work against a project that
// never had the writer).
function writerPathFor(settingsPath) {
  return join(dirname(dirname(settingsPath)), 'scripts', 'observability', 'session-run-hook.ts');
}

function assertWriterPresent(settingsPath) {
  const writer = writerPathFor(settingsPath);
  if (!existsSync(writer)) {
    fail(
      `no writer at ${writer} — these hooks would resolve to a file this project `
      + 'does not have, and would record nothing while reporting as wired. '
      + 'Run this from a checkout with scripts/observability/session-run-hook.ts, '
      + 'or pass that checkout\'s settings path.',
    );
  }
}

// Atomic replace, because the destination is the deny-listed settings file: a
// truncating in-place write that is interrupted leaves it invalid, and an
// invalid settings.json takes every hook down with it.
export function writeAtomic(settingsPath, expectedBytes, output) {
  const current = readFileSync(settingsPath, 'utf8');
  if (current !== expectedBytes) {
    fail(`${settingsPath} changed while this ran — refusing to overwrite another writer`);
  }
  const tmp = `${settingsPath}.wire-session-telemetry.${process.pid}.tmp`;
  try {
    writeFileSync(tmp, output, 'utf8');
    renameSync(tmp, settingsPath);
  } catch (e) {
    try { unlinkSync(tmp); } catch { /* nothing left to clean up */ }
    throw e;
  }
}

async function main() {
  let releaseLock;
  try {
    const args = parseArgs(process.argv.slice(2));
    const settingsPath = resolve(args.settingsPath || defaultSettingsPath());
    // Hold the shared settings lock across the WHOLE read -> transform ->
    // write/rename sequence, so this writer and the other sanctioned writers
    // (wire-hook-bash, wire-trust-hooks) serialise rather than race.
    releaseLock = await acquireLock(settingsPath);
    const input = readFileSync(settingsPath, 'utf8');
    const before = parseJson(input, settingsPath);

    if (!args.off && !args.check) {
      assertWriterPresent(settingsPath);
    }

    // Reversibility is asserted on BYTES, and this script reserializes with a
    // FIXED 2-space indent + trailing newline — byte-stable only for a file
    // already in that shape. Prove the round-trip on the UNCHANGED input
    // before writing, and refuse rather than reformat (same guard as
    // wire-trust-hooks, for the same reason: --off could not restore a
    // reformatted file byte-for-byte).
    if (!args.check && serialize(before) !== input) {
      const crlf = input.includes('\r\n');
      fail(
        `${settingsPath} is formatted differently from how this script serializes JSON `
        + `(${crlf ? 'CRLF line endings; this script writes LF' : '2-space indent, trailing newline'}), `
        + 'so writing it would reformat the whole file and `--off` could not restore it '
        + 'byte-for-byte. Refusing: the reversibility guarantee is the point. '
        + (crlf
          ? 'Convert it to LF line endings first, or wire by hand.'
          : 'Reformat the file to 2-space indent first, or wire by hand.'),
      );
    }

    const status = statusOf(before);
    const { wired, total } = status;
    const { settings: after, changed } = args.off ? remove(before) : install(before);

    assertPermissionsUnchanged(before, after);
    assertOnlyHooksChanged(before, after);

    const verb = args.off ? 'removed' : 'added';
    if (args.check) {
      const dupes = status.duplicates;
      process.stdout.write(
        `wire-session-telemetry-hooks: ${wired}/${total} entries wired in ${settingsPath}; `
        + `would have ${verb} ${changed}; wrote nothing\n`
        + (dupes > 0
          ? `  ⚠ ${dupes} DUPLICATE owned entr${dupes === 1 ? 'y' : 'ies'} — each records the same `
            + 'event twice. Run `install` to converge.\n'
          : '')
        + (!args.off && !existsSync(writerPathFor(settingsPath))
          ? `  ⚠ no writer at ${writerPathFor(settingsPath)} — install would REFUSE here; `
            + 'these hooks would record nothing while reporting as wired.\n'
          : ''),
      );
      return;
    }
    if (changed === 0) {
      process.stdout.write(
        `wire-session-telemetry-hooks: ${settingsPath} already ${args.off ? 'unwired' : 'wired'} `
        + `(${wired}/${total}); no change made\n`,
      );
      return;
    }

    writeAtomic(settingsPath, input, serialize(after));
    process.stdout.write(
      `wire-session-telemetry-hooks: ${verb} ${changed} entr${changed === 1 ? 'y' : 'ies'} in ${settingsPath}; `
      + 'permissions unchanged.\n',
    );
    if (!args.off) {
      process.stdout.write(
        '  Hooks take effect on the next matching event — no restart needed. The ledger fills\n'
        + '  at ~/.himmel/session-runs.jsonl (override: HIMMEL_SESSION_RUNS_LEDGER); check for\n'
        + '  non-zero rows after your next session/subagent activity.\n',
      );
    }
  } catch (error) {
    process.stderr.write(`wire-session-telemetry-hooks: REFUSED — ${error.message}\n`);
    process.exitCode = 1;
  } finally {
    if (releaseLock) releaseLock();
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
