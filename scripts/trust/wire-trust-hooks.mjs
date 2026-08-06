#!/usr/bin/env node
// wire-trust-hooks.mjs — HIMMEL-1551: install/remove the HIMMEL-1529 shadow
// ledger's hook entries in `.claude/settings.json`.
//
// WHY THIS EXISTS
// The recorder shipped behind a manual paste of six JSON blocks, and three
// consecutive chain legs measured `requests recorded 0` as a result. A
// capability that ships behind a manual paste is a capability that does not
// ship. This makes the wiring reviewable in a PR, versioned, idempotent, and
// reversible.
//
// WHY A SCRIPT IS ALLOWED TO WRITE A DENY-LISTED FILE
// `Edit(**/.claude/settings.json)` is deny-listed so nothing edits it ad hoc.
// The precedent is scripts/hooks/wire-hook-bash.mjs (HIMMEL-1516), which writes
// the same file: a reviewed script with a narrow, asserted mutation is the
// sanctioned path; an agent's free-form Edit is not. That distinction only
// holds while the assertions below hold, so they are unconditional.
//
// REVERSIBILITY IS A CORRECTNESS PROPERTY, NOT A CONVENIENCE
// HIMMEL-1529's whole claim is that adding the recorder changes no behaviour
// and removing it changes no behaviour. `--off` therefore has to restore the
// file byte-for-byte, and the test suite asserts exactly that. If it could not,
// the claim would be untestable.
//
// ⚠ KNOWN INTERACTION — scripts/hooks/wire-hook-bash.mjs (HIMMEL-1516)
// That script freezes the hook inventory as constants (EXPECTED_COUNTS
// { PreToolUse: 11, PostToolUse: 2, SessionStart: 3 }, EXPECTED_TOTAL 16) and
// hard-fails on ANY unexpected event key. Wiring the ledger adds entries to two
// of those and introduces four new keys, so once this script has run,
// wire-hook-bash.mjs REFUSES until its constants are reconciled.
//
// Verified across five chain legs that nothing invokes it today (only its own
// test references it), so this blocks nobody right now — and bumping its
// constants is NOT the fix, because the counts differ depending on whether the
// ledger is on or off, which a frozen constant cannot express. That is the
// point: an inventory frozen as a constant is a good gate for the file it owns
// and a trap for everything added later. The gate's job is to prove IT did not
// corrupt the file, not to forbid the file from growing. Tracked as the
// remaining item on HIMMEL-1551, deliberately separated because it is a change
// to a SECURITY gate and deserves its own review.
//
// USAGE
//   node wire-trust-hooks.mjs            # install (idempotent)
//   node wire-trust-hooks.mjs --off      # remove (idempotent)
//   node wire-trust-hooks.mjs --check    # report state, write nothing
//   node wire-trust-hooks.mjs [--...] <settings-path>

import { spawnSync } from 'node:child_process';
import {
  existsSync, readFileSync, renameSync, unlinkSync, writeFileSync,
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { EXPECTED_HOOKS } from './shadow-ledger.mjs';
import { acquireLock } from '../lib/settings-lock.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

// The recorder is invoked through `node` directly rather than `bash`, so it is
// not exposed to the Windows bare-`bash` resolution failure behind
// HIMMEL-1516/1526. `$CLAUDE_PROJECT_DIR` is quoted because an unquoted
// expansion word-splits on a project path containing a space — and the hook
// would then fail open, losing observations silently, which is the one failure
// mode a measurement tool must not have.
const LEDGER = '"$CLAUDE_PROJECT_DIR/scripts/trust/shadow-ledger.mjs"';

// `"timeout": 10` is not decoration. A command hook defaults to 600 SECONDS, so
// a stalled syscall in the PreToolUse hook would hold every matching tool call
// for ten minutes — which would make this a behaviour change, and the whole
// claim of the ticket is that it is not one.
const TIMEOUT = 10;

// HIMMEL-1560: the recorder's identity, exactly as its `capabilities` verb
// prints it. A LITERAL here rather than an import of the recorder's RECORDER_ID,
// because the two artefacts are deliberately decoupled — the whole skew
// scenario is one checkout's wiring tool pointed at ANOTHER checkout's
// recorder, so they must not share an import (the import would resolve against
// THIS checkout's recorder and the cross-checkout case could never be caught).
// The string is the handshake protocol, not an internal symbol: comparing it is
// asking the artefact at the resolved path "are you the recorder I expect?".
const SHADOW_LEDGER_ID = 'himmel-shadow-ledger';
// A handshake that never returns is worse than one that fails: it stalls the
// very tool the operator ran. The recorder's own hook timeout is 10s, and a
// capability answer does no stdin read and no ledger IO — so anything still
// running at 10s is a wedged process, not a slow one.
const CAPABILITY_TIMEOUT_MS = 10000;

// The wiring table itself lives in shadow-ledger.mjs, as `EXPECTED_HOOKS` —
// the recorder OWNS the contract of which verb belongs to which event and
// matcher, and this script CONSUMES it (HIMMEL-1547 CR round). Two independent
// copies of that mapping is exactly how `wiredVerbs()` there used to certify a
// verb wired under the wrong event: a settings file with all seven
// canonical-looking commands parked under `SessionStart` read as a complete
// inventory because nothing checked the event key against a shared source of
// truth. The recorder is the hot path (it runs on every tool call) and gains
// nothing from importing this file; this script runs rarely and pays the
// import instead. Kept as the local name `ENTRIES` to minimise the diff below.
//
// `matcher: null` means NO matcher key is emitted. For PermissionRequest that
// is deliberate: an approval interrupt counts whatever tool raised it, and the
// row carries no request payload to classify. For SessionStart it is load-
// bearing in a different way: the heartbeat must fire on EVERY session source
// (startup, resume, clear, compact), because a matcher that misses one produces
// a gap the report then refuses a rate over.
export const ENTRIES = EXPECTED_HOOKS;

const commandFor = (verb) => `node ${LEDGER} ${verb}`;

function entryFor({ verb, matcher }) {
  const entry = {};
  if (matcher !== null) entry.matcher = matcher;
  entry.hooks = [{ type: 'command', command: commandFor(verb), timeout: TIMEOUT }];
  return entry;
}

// An entry belongs to US only if its single hook invokes the shadow ledger.
// Anything else in these arrays is somebody else's and is never touched — the
// gate's job is to prove IT did not corrupt the file, not to forbid the file
// from growing (the frozen-inventory trap this ticket also exists to avoid).
// Deliberately QUOTE-INSENSITIVE. Requiring the trailing `"` made this blind to
// `node $CLAUDE_PROJECT_DIR/scripts/trust/shadow-ledger.mjs pre` — the unquoted
// form, which is the paste mistake the LEDGER comment above explicitly names.
// An unrecognised ledger entry is treated as FOREIGN by install/remove/statusOf,
// so install appends a canonical entry beside it, both fire, every event is
// recorded twice, `off` leaves the stray, and `--check` still reads 6/6 with
// zero duplicates: the exact double-count the ownership guard exists to refuse,
// reachable through the one variant the guard could not see.
const isLedgerCommand = (cmd) => typeof cmd === 'string' && cmd.includes('/scripts/trust/shadow-ledger.mjs');

function isOurs(entry) {
  const hooks = entry && entry.hooks;
  if (!Array.isArray(hooks) || hooks.length !== 1) return false;
  return isLedgerCommand(hooks[0] && hooks[0].command);
}

// A ledger command sharing an entry with somebody else's hook. `isOurs` cannot
// claim it (the entry is not solely ours) and previously that meant it was
// INVISIBLE: install appended a second ledger entry beside it — seven live
// invocations reported as 6/6 with zero duplicates — and remove reported 0/6
// while one invocation stayed wired.
//
// Fail closed rather than surgically editing an entry we do not own. Rewriting
// somebody else's grouping is how a wiring tool destroys a configuration it did
// not understand, and every count this script reports would be a guess until
// the grouping is separated.
// The one command this script owns per event. Anything else carrying a
// shadow-ledger invocation is not ours to reason about.
const CANONICAL_BY_EVENT = new Map(ENTRIES.map((s) => [s.event, commandFor(s.verb)]));

function assertNoEmbeddedLedgerHooks(settings) {
  const hooks = settings?.hooks;
  if (!hooks || typeof hooks !== 'object') return;
  for (const [event, list] of Object.entries(hooks)) {
    if (!Array.isArray(list)) continue;
    list.forEach((entry, i) => {
      const inner = entry && entry.hooks;
      if (!Array.isArray(inner)) return;
      const ledger = inner.filter((h) => isLedgerCommand(h && h.command));
      if (ledger.length === 0) return;
      if (inner.length > 1) {
        fail(
          `hooks.${event}[${i}] mixes a shadow-ledger command with other hooks — `
          + 'refusing, because on/off/status would all misreport it. '
          + 'Split the ledger command into its own entry first.',
        );
      }
      // [codex-adv round 4, medium] A SINGLE-hook entry used to return early
      // here, one step outside the guard written for exactly this class.
      // `isOurs` accepts any single-hook ledger command, but install/remove/
      // statusOf all key on the EXACT canonical string — so an invocation that
      // is recognisably ours yet not canonical (an extra argument, or the right
      // command under the wrong event) was invisible to all three: install
      // appended a canonical entry beside it, BOTH fired, every event was
      // recorded twice, `off` left the stray behind, and status still read 6/6
      // with zero duplicates. A double-counted event inflates the one number
      // this ledger exists to produce, while the instrument reports healthy —
      // this programme's own failure mode, in the tool built to prevent it.
      if (ledger[0].command !== CANONICAL_BY_EVENT.get(event)) {
        fail(
          `hooks.${event}[${i}] carries a shadow-ledger command this script does not own:\n`
          + `  ${ledger[0].command}\n`
          + 'Refusing. It is close enough to be recognisable and different enough that '
          + 'install would append a SECOND entry beside it — both would fire, every event '
          + `would be recorded twice, and status would still report ${ENTRIES.length}/${ENTRIES.length}. `
          + 'Remove or correct that entry first.',
        );
      }
    });
  }
}

// Does this entry match the canonical wiring EXACTLY — matcher, command,
// timeout, and nothing extra?
//
// Command equality alone is not enough, and the gap is not theoretical: the
// README told operators to paste these six blocks by hand for two releases. A
// hand-pasted entry can easily carry the right command with NO `timeout`, and a
// command hook defaults to 600 SECONDS — so "already wired" would leave a hook
// that can hold every matching tool call for ten minutes, which is precisely
// the behaviour change the recorder claims not to be. Same for a wrong matcher,
// which silently narrows what is observed and biases the number.
function matchesCanonical(entry, spec) {
  return JSON.stringify(entry) === JSON.stringify(entryFor(spec));
}

function fail(message) {
  throw new Error(message);
}

// The `hooks` CONTAINER, one layer above the per-event arrays. Both need
// checking: an array or a string here would be spread by `{ ...hooks }` into a
// garbage index-keyed object, destroying the original — and neither security
// assertion catches it, because `assertOnlyHooksChanged` deliberately excludes
// `hooks` and `assertPermissionsUnchanged` never looks at it.
//
// Validating the entries but not the thing that holds them is the same
// one-layer-short mistake this subsystem keeps making; refuse-not-guess has to
// hold at every level it claims to.
// [glm/codex-1, sug] And one layer above THAT: the settings root itself. An
// array root is valid JSON, survives `{ ...settings }` (which produces an
// index-keyed object), and `JSON.stringify` then serializes an ARRAY — dropping
// every named property, including the `hooks` this script just added. The old
// code reported "added 7 entries" over a file that gained none.
//
// This is the same one-layer-short mistake the `hooks` check was written for,
// found one layer further out. Recording it that way rather than as a
// standalone bug: the pattern is the finding.
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

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch (e) {
    fail(`${label} is not valid JSON: ${e.message}`); // fail() always throws
  }
}

// SECURITY GATE, unconditional. This script is trusted only because it refuses
// any change to the permission policy — the single most security-relevant thing
// in the file, and the thing a settings-writing script must never be able to
// widen.
function assertPermissionsUnchanged(before, after) {
  const a = JSON.stringify(before?.permissions ?? null);
  const b = JSON.stringify(after?.permissions ?? null);
  if (a !== b) fail('permissions changed — refusing to write');
}

// Nothing outside `hooks` may differ. Cheap, total, and it catches an entire
// class of mistake (a stray key, a dropped section) that no targeted assertion
// would.
function assertOnlyHooksChanged(before, after) {
  const strip = (o) => {
    const copy = { ...o };
    delete copy.hooks;
    return JSON.stringify(copy);
  };
  if (strip(before) !== strip(after)) fail('a non-hook section changed — refusing to write');
}

export function install(settings) {
  assertHooksContainer(settings);
  assertNoEmbeddedLedgerHooks(settings);
  const next = structuredClone(settings);
  next.hooks = next.hooks ? { ...next.hooks } : {};
  let added = 0;
  for (const spec of ENTRIES) {
    const existing = next.hooks[spec.event];
    // A present-but-not-array value is a malformed file or a future schema this
    // script does not understand. Coercing it to `[]` would DESTROY it, and
    // `--off` could never restore it — `assertOnlyHooksChanged` cannot catch
    // that, because the loss happens inside the section it permits changing.
    // Refuse instead: losing data you did not understand is the worst outcome
    // available here.
    if (existing !== undefined && !Array.isArray(existing)) {
      fail(`hooks.${spec.event} is not an array — refusing to overwrite an unrecognised shape`);
    }
    const list = Array.isArray(existing) ? [...existing] : [];
    // Idempotence is keyed on the COMMAND, not on array position: a re-run must
    // change nothing even if somebody appended their own entry in between.
    const mine = [];
    list.forEach((e, i) => {
      if (isOurs(e) && e.hooks[0].command === commandFor(spec.verb)) mine.push(i);
    });
    if (mine.length === 0) {
      list.push(entryFor(spec));
      added += 1;
    } else {
      // Converge on EXACTLY ONE canonical entry. Repairing only the first match
      // would leave a duplicate in place — and a duplicated hook records the
      // same event twice, inflating the very count this ledger exists to
      // produce. Extras are dropped from the back so the surviving index is
      // stable.
      if (!matchesCanonical(list[mine[0]], spec)) {
        // Ours by command but not canonical in shape — a hand-paste that
        // dropped the timeout, or a matcher that has since changed. REPAIR it
        // rather than reporting it wired, or the operator keeps a hook this
        // script claims to have made safe.
        list[mine[0]] = entryFor(spec);
        added += 1;
      }
      for (let i = mine.length - 1; i >= 1; i -= 1) {
        list.splice(mine[i], 1);
        added += 1;
      }
    }
    next.hooks[spec.event] = list;
  }
  return { settings: next, changed: added };
}

export function remove(settings) {
  assertHooksContainer(settings);
  assertNoEmbeddedLedgerHooks(settings);
  const next = structuredClone(settings);
  if (!next.hooks) return { settings: next, changed: 0 };
  next.hooks = { ...next.hooks };
  let removed = 0;
  for (const spec of ENTRIES) {
    const list = next.hooks[spec.event];
    if (!Array.isArray(list)) continue;
    let removedHere = 0;
    const kept = list.filter((e) => {
      const ours = isOurs(e) && e.hooks[0].command === commandFor(spec.verb);
      if (ours) removedHere += 1;
      return !ours;
    });
    removed += removedHere;
    // Drop an event key only if OUR removal emptied it — an event that still
    // holds somebody else's hook must survive, and an array this script never
    // TOUCHED is not its to delete. Guarding on `removedHere` rather than on
    // `kept.length` alone is what keeps that second case byte-identical.
    //
    // Documented limit: an array that WAS empty and that we then wired into
    // normalizes to absent here. remove() runs in its own process and cannot
    // know the prior state, so some shape has to normalize; `[]` and absent are
    // identical to every consumer, which makes this the harmless choice. Pinned
    // by a test rather than left to be discovered.
    if (removedHere > 0 && kept.length === 0) delete next.hooks[spec.event];
    else next.hooks[spec.event] = kept;
  }
  // If our removal emptied `hooks` entirely, drop it too: install creates the
  // container when a settings file has none, so leaving `hooks: {}` behind
  // would break byte-exact reversibility for that shape.
  //
  // Stated limit: a file whose ORIGINAL `hooks` was an explicit `{}` normalizes
  // to no `hooks` key after a wire/unwire round trip. The two are equivalent to
  // every consumer, and remove() cannot distinguish them without knowing the
  // original — so this is a documented normalization, not an unnoticed edge.
  if (removed > 0 && Object.keys(next.hooks).length === 0) delete next.hooks;
  return { settings: next, changed: removed };
}

// "Wired" means canonical, not merely present: an entry carrying our command
// with a missing timeout or a changed matcher is NOT wired, because reporting
// it as wired is how an operator keeps a hook this script never actually made
// safe.
export function statusOf(settings) {
  let duplicates = 0;
  const present = ENTRIES.filter((spec) => {
    const list = settings?.hooks?.[spec.event];
    if (!Array.isArray(list)) return false;
    // Count OWNED copies, not canonical ones: two entries carrying our command
    // record the same event twice, which inflates the very number this ledger
    // exists to produce. Reporting 6/6 over that would be a clean-looking
    // status on a corrupted instrument.
    const owned = list.filter((e) => isOurs(e) && e.hooks[0].command === commandFor(spec.verb));
    if (owned.length > 1) duplicates += owned.length - 1;
    return owned.some((e) => matchesCanonical(e, spec));
  });
  return { wired: present.length, total: ENTRIES.length, duplicates };
}

// Serialize exactly as the file already is — 2-space indent, trailing newline.
// Verified byte-stable against the live settings.json, so an install produces a
// minimal diff instead of reformatting the whole file into the review.
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

// [codex-2, sug] With no path argument and no `CLAUDE_PROJECT_DIR`, this used to
// wire the SCRIPT's own checkout wherever it was run from. `himmelctl trust`
// always passes an explicit target, so this is the bare-script surface — but
// silently wiring a different project than the one the operator is standing in
// is the same targeting defect HIMMEL-1551 round 3 only appeared to fix, and it
// is not made safe by `assertRecorderPresent` (the himmel checkout DOES have a
// recorder, so the wrong answer passes every check).
//
// Refuse the ambiguity rather than resolve it by precedence. Standing in a
// project that has its own `.claude/` and typing no argument has two plausible
// meanings, and picking one silently is how the operator ends up reading a
// status for a file they never meant to touch.
function defaultSettingsPath() {
  const fromEnv = process.env.CLAUDE_PROJECT_DIR;
  if (fromEnv) return join(fromEnv, '.claude', 'settings.json');
  const own = resolve(HERE, '..', '..');
  const cwdProject = resolve(process.cwd());
  if (cwdProject !== own && existsSync(join(cwdProject, '.claude'))) {
    fail(
      `ambiguous target: you are in ${cwdProject}, which has its own .claude/, but this `
      + `script lives in ${own}. Refusing to guess which one you meant — pass the settings `
      + 'path explicitly, or set CLAUDE_PROJECT_DIR. (`himmelctl trust` always passes one.)',
    );
  }
  return join(own, '.claude', 'settings.json');
}

// The hooks resolve `$CLAUDE_PROJECT_DIR/scripts/trust/shadow-ledger.mjs` AT
// RUNTIME, against whatever project the session is rooted in — which is not
// necessarily the checkout this script lives in. `himmelctl trust` targets the
// project the operator is standing in, so running it from an ADOPTED project
// would wire six hooks pointing at a recorder that project does not contain:
// every hook fails, `report` shows zero rows, and `status` still says 6/6.
//
// That is this programme's own failure mode, installed by the tool built to
// prevent it. So the recorder's existence at the resolved path is a
// PRECONDITION, checked before anything is written.
function recorderPathFor(settingsPath) {
  return join(dirname(dirname(settingsPath)), 'scripts', 'trust', 'shadow-ledger.mjs');
}

function assertRecorderPresent(settingsPath) {
  const recorder = recorderPathFor(settingsPath);
  if (!existsSync(recorder)) {
    fail(
      `no recorder at ${recorder} — these hooks would resolve to a file this project `
      + 'does not have, and would record nothing while reporting as wired. '
      + 'Run this from the himmel checkout, or pass that checkout\'s settings path.',
    );
  }
}

// HIMMEL-1560 — existence is not compatibility.
//
// assertRecorderPresent proves a FILE sits at the resolved path; this proves
// the ARTEFACT at that path can actually record every verb this tool is about
// to wire. The verb set grew from three (HIMMEL-1539) to seven (HIMMEL-1547),
// and the recorder's CLI dispatch is a deliberate silent fall-through: an
// unrecognised verb matches no branch and returns 0 WITHOUT recording, because
// fail-open is the hook contract (a non-zero PreToolUse exit BLOCKS the tool
// call). So a newer wiring tool pointed at an OLDER checkout installs entries
// invoking verbs that recorder does not implement — those hooks fire, exit 0,
// write nothing, and `trust status` still reports 7/7. That is an instrument
// reporting healthy while under-collecting, in the direction that makes the
// headline number look SMALLER: this programme's own failure mode, installed
// by the tool built to prevent it.
//
// Asking the ARTEFACT (not string-matching its source, not comparing a version
// constant) is the whole point. A source scan would pass on a file that merely
// MENTIONS the verbs; a version constant would drift from the code it describes.
// `capabilities` prints the keys of the recorder's own dispatch table, so a
// verb cannot be implemented without being advertised, or advertised without
// being implemented. The recorder is the hot path (every tool call); this
// probe runs only when wiring, so it pays the spawn.
//
// Spawns at the RESOLVED PATH (recorderPathFor), never the imported sibling
// module — the imported module is THIS checkout's recorder, and the entire skew
// case is this tool wiring hooks that resolve against a DIFFERENT checkout's
// recorder. Importing would measure the wrong artefact and the check could
// never fail.
export function recorderCapabilities(settingsPath) {
  const recorder = recorderPathFor(settingsPath);
  // Exactly what this tool installs — never a hardcoded list, so a verb added
  // to ENTRIES is required here automatically. This is the demand side of the
  // handshake: the tool asks the recorder to prove exactly what it is about to
  // wire, no more and no less.
  const required = ENTRIES.map((s) => s.verb);
  const probed = spawnSync(process.execPath, [recorder, 'capabilities'], {
    encoding: 'utf8',
    timeout: CAPABILITY_TIMEOUT_MS,
    // stdio[0] MUST be 'ignore'. An OLDER recorder has no `capabilities`
    // branch, so it falls through to a hook path that reads stdin; with stdin
    // inherited (the default) that read would BLOCK on a caller with nothing
    // to send, turning a capability query into a hang. 'ignore' hands it EOF,
    // the fall-through completes, the recorder exits, and its silence is read
    // as the honest INCAPABLE answer it is — never as a pass.
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  // FAIL CLOSED on every uncertain branch. The damaging error is the opposite
  // one — reading an incapable recorder as capable and wiring hooks that then
  // record nothing — so every path that cannot PROVE a verb is present reports
  // it missing. `missing` is therefore the FULL required set for any response
  // that is absent, untrusted or malformed: a recorder that advertised nothing
  // proved nothing, and "which verbs does it have?" has no honest answer but
  // "none of the ones it was asked to prove". Naming them keeps the refusal
  // actionable instead of opaque.
  // A TIMEOUT sets BOTH `error` (code ETIMEDOUT) and `signal` (SIGTERM), so
  // checking `error` first reported a recorder that STARTED and then hung as
  // "could not be started" — sending the operator to the wrong cause. Verified
  // by probe rather than reasoned: `spawnSync` with a 600 ms timeout against a
  // sleeping child returns `error.code = ETIMEDOUT`, `signal = SIGTERM`,
  // `status = null`. Both branches fail closed identically, so the defect is
  // the DIAGNOSIS, not the decision — the same class as this file's CRLF
  // message, which named the indent while the line endings were what tripped.
  // Not unit-tested: CAPABILITY_TIMEOUT_MS is a fixed 10s constant, so
  // asserting this would cost a 10-second test to prove a label; making it
  // injectable purely for the test would be speculative config.
  if (probed.error?.code === 'ETIMEDOUT') return { ok: false, reason: 'timeout', missing: required };
  if (probed.error) return { ok: false, reason: 'spawn_error', missing: required };
  if (probed.signal) {
    return { ok: false, reason: probed.signal === 'SIGTERM' ? 'timeout' : 'killed', missing: required };
  }
  if (probed.status !== 0) return { ok: false, reason: 'nonzero_exit', missing: required };
  const stdout = typeof probed.stdout === 'string' ? probed.stdout : '';
  if (!stdout.trim()) return { ok: false, reason: 'empty_stdout', missing: required };
  let parsed;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    return { ok: false, reason: 'unparseable_json', missing: required };
  }
  // The identity marker distinguishes "the recorder answered" from "some other
  // program happened to print JSON on stdout". A wrong id means the verb list
  // cannot be trusted even if it happens to match, so it counts as missing —
  // the same answer an empty stdout gives, for the same reason.
  if (parsed?.recorder !== SHADOW_LEDGER_ID) {
    return { ok: false, reason: 'wrong_recorder_id', missing: required };
  }
  const verbs = parsed.verbs;
  if (!Array.isArray(verbs) || !verbs.every((v) => typeof v === 'string')) {
    return { ok: false, reason: 'verbs_not_string_array', missing: required };
  }
  const have = new Set(verbs);
  const missing = required.filter((v) => !have.has(v));
  if (missing.length > 0) return { ok: false, reason: 'missing_verbs', missing };
  return { ok: true, verbs };
}

// A human gloss of WHY a probe failed, so a refusal names the cause rather than
// a reason code an operator would have to decode. Every ok:false branch above
// has an entry.
const CAPABILITY_REASONS = {
  spawn_error: 'the recorder could not be started',
  timeout: `the recorder did not answer within ${CAPABILITY_TIMEOUT_MS / 1000}s`,
  killed: 'the recorder was killed by a signal',
  nonzero_exit: 'the recorder exited non-zero',
  empty_stdout: 'the recorder advertised nothing (an unrecognised verb is its silent fall-through)',
  unparseable_json: 'the recorder answered with unparseable JSON',
  wrong_recorder_id: 'the recorder answered with the wrong identity',
  verbs_not_string_array: 'the recorder advertised a malformed verb list',
  missing_verbs: 'the recorder is missing verbs this tool wires',
};

// The install-path precondition: refuse to wire hooks the recorder cannot
// honour. `--check` reports the same state instead of refusing (see main), and
// `--off` skips it entirely — removing dead wiring is exactly what you want
// against a recorder that was never capable, and refusing would strand it.
function assertRecorderCapable(settingsPath) {
  const cap = recorderCapabilities(settingsPath);
  if (cap.ok) return;
  fail(
    `the recorder at ${recorderPathFor(settingsPath)} did not prove it can record every verb `
    + `this tool wires — ${CAPABILITY_REASONS[cap.reason] ?? cap.reason}. `
    + `Missing: ${cap.missing.join(', ')}. An unrecognised verb is the recorder's deliberate `
    + 'silent fall-through (fail-open is the hook contract), so these hooks would fire, exit 0, '
    + 'record nothing, and `trust status` would still report '
    + `${ENTRIES.length}/${ENTRIES.length} — an instrument reporting healthy while `
    + 'under-collecting, in the direction that makes the headline number look smaller. '
    + 'Point at a checkout whose recorder implements these verbs.',
  );
}

// Atomic replace, because the destination is the deny-listed settings file: a
// truncating in-place write that is interrupted (or hits ENOSPC) leaves it
// invalid, and an invalid settings.json takes every hook down with it.
//
// The re-read is an optimistic-concurrency check. This script reads, computes,
// then writes; another process editing settings.json in between would be
// silently reverted by the stale snapshot, and the permissions assertion cannot
// see that because it only compares two objects derived from the SAME read.
export function writeAtomic(settingsPath, expectedBytes, output) {
  const current = readFileSync(settingsPath, 'utf8');
  if (current !== expectedBytes) {
    fail(`${settingsPath} changed while this ran — refusing to overwrite another writer`);
  }
  const tmp = `${settingsPath}.wire-trust.${process.pid}.tmp`;
  try {
    writeFileSync(tmp, output, 'utf8');
    renameSync(tmp, settingsPath);
  } catch (e) {
    try { unlinkSync(tmp); } catch { /* nothing left to clean up */ }
    throw e;
  }
}

async function main() {
  // HIMMEL-1552: hold the shared settings lock across the WHOLE
  // read -> transform -> write/rename sequence, so this writer and
  // wire-hook-bash.mjs serialise rather than race. writeAtomic()'s re-read is an
  // optimistic check that narrows the lost-update window; only the lock closes
  // it. Acquired here rather than via withSettingsLock() so the 120-line body
  // needs no re-indent — the `finally` below gives the same release guarantee,
  // including on throw.
  let releaseLock;
  try {
    const args = parseArgs(process.argv.slice(2));
    const settingsPath = resolve(args.settingsPath || defaultSettingsPath());
    releaseLock = await acquireLock(settingsPath);
    const input = readFileSync(settingsPath, 'utf8');
    const before = parseJson(input, settingsPath);

    // Only for install: `--off` and `--check` must keep working in a project
    // whose recorder was never deployed — removing dead wiring is exactly what
    // you would want there, and refusing would strand it.
    if (!args.off && !args.check) {
      assertRecorderPresent(settingsPath);
      // HIMMEL-1560: present is not compatible. Probed right after existence and
      // only on the install path, for the same reason — `--off`/`--check` must
      // still reach a project whose recorder is old or absent.
      assertRecorderCapable(settingsPath);
    }

    // [codex round 5, important] Reversibility is asserted on BYTES, and this
    // script reserializes with a FIXED 2-space indent + trailing newline. That
    // is byte-stable for the settings file it was built against and NOT for a
    // project that formats JSON differently — a case the CLI's own targeting
    // fix just made reachable, since `trust` now follows the operator into
    // arbitrary projects. Silently reformatting a config we do not own is bad;
    // being unable to restore it on `--off` breaks the one guarantee the whole
    // suite is built around. So prove the round-trip on the UNCHANGED input
    // before writing, and refuse rather than reformat.
    if (!args.check && serialize(before) !== input) {
      // [glm-3, sug] Name the mismatch that ACTUALLY tripped. `serialize`
      // emits LF, so a CRLF settings.json fails this guard — and on Windows,
      // the one platform this project targets, that is the likeliest way to hit
      // it. The old message named only the indent, sending the operator to
      // reformat something that was already correct. Fails closed either way;
      // the defect was the diagnosis, not the decision.
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

    // [glm-4, sug] One read of the status, used by both branches below. The
    // `--check` path called `statusOf(before)` a second time purely to reach
    // `duplicates`, which is a second chance for the two reads to disagree.
    const status = statusOf(before);
    const { wired, total } = status;
    const { settings: after, changed } = args.off ? remove(before) : install(before);

    assertPermissionsUnchanged(before, after);
    assertOnlyHooksChanged(before, after);

    const verb = args.off ? 'removed' : 'added';
    if (args.check) {
      const dupes = status.duplicates;
      // The missing-recorder warning below covers the absent case; this probes
      // the recorder-PRESENT-but-incapable sibling, so `--check` reports the
      // same refusal `trust on` would actually give rather than hiding it
      // behind a clean N/N. Skipped when removing (`--off` never handshakes)
      // and when the recorder is absent (the other warning owns that case).
      let incapable = null;
      if (!args.off && existsSync(recorderPathFor(settingsPath))) {
        const cap = recorderCapabilities(settingsPath);
        if (!cap.ok) incapable = cap;
      }
      process.stdout.write(
        `wire-trust-hooks: ${wired}/${total} entries wired in ${settingsPath}; `
        + `would have ${verb} ${changed}; wrote nothing\n`
        + (dupes > 0
          ? `  ⚠ ${dupes} DUPLICATE owned entr${dupes === 1 ? 'y' : 'ies'} — each records the same `
            + 'event twice and inflates the count. Run `trust on` to converge.\n'
          : '')
        // `--check` deliberately does NOT refuse on a missing recorder (that
        // would strand `--off` semantics for a project with dead wiring), but
        // silently reporting "would have added 6" in a project `trust on` will
        // REFUSE describes an install that cannot happen. Report the refusal
        // the operator is actually going to get.
        + (!args.off && !existsSync(recorderPathFor(settingsPath))
          ? `  ⚠ no recorder at ${recorderPathFor(settingsPath)} — \`trust on\` would REFUSE here; `
            + 'these hooks would record nothing while reporting as wired.\n'
          : '')
        // HIMMEL-1560: the recorder EXISTS but cannot be trusted to record
        // every verb. Same refusal `trust on` would give, reported rather than
        // acted on — naming the missing verbs and the consequence, in the same
        // voice as the missing-recorder line above.
        + (incapable
          ? `  ⚠ the recorder at ${recorderPathFor(settingsPath)} did not prove it can record every `
            + `verb this tool wires — ${CAPABILITY_REASONS[incapable.reason] ?? incapable.reason}. `
            + `Missing: ${incapable.missing.join(', ')}. \`trust on\` would REFUSE here; these hooks `
            + 'would fire, exit 0, record nothing, and status would still report '
            + `${ENTRIES.length}/${ENTRIES.length}.\n`
          : ''),
      );
      return;
    }
    if (changed === 0) {
      process.stdout.write(
        `wire-trust-hooks: ${settingsPath} already ${args.off ? 'unwired' : 'wired'} `
        + `(${wired}/${total}); no change made\n`,
      );
      return;
    }

    writeAtomic(settingsPath, input, serialize(after));
    process.stdout.write(
      `wire-trust-hooks: ${verb} ${changed} entr${changed === 1 ? 'y' : 'ies'} in ${settingsPath}; `
      + 'permissions unchanged.\n',
    );
    if (!args.off) {
      // The number is the product; saying "wired" without it is the exact
      // conflation this programme exists to stop.
      // This used to say "Hooks load at SESSION START — restart claude". That
      // was inherited from the harness docs, repeated into a commit message, a
      // status artifact and a handover, and never once tested — and it is
      // FALSE: HIMMEL-1561 measured the ledger recording within seconds of the
      // settings file changing, in the very session that had just asserted it
      // could not. An unverified claim in a success message is this subsystem's
      // own recurring defect, printed by the tool built to prevent it.
      process.stdout.write(
        '  Hooks take effect on the next matching event — no restart needed. Verify with:\n'
        + '    node scripts/trust/shadow-ledger.mjs report\n'
        + '  It must show non-zero rows AND a PROVEN collection line. "It is wired" is not\n'
        + '  the same claim as "it is recording", and neither is "the rate can be trusted".\n',
      );
    }
  } catch (error) {
    process.stderr.write(`wire-trust-hooks: REFUSED — ${error.message}\n`);
    process.exitCode = 1;
  } finally {
    if (releaseLock) releaseLock();
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
