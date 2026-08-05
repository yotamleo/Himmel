// HIMMEL-1551 — the suite is the spec for the trust-ledger wiring script.
//
// The properties that matter, in order:
//   1. it is REVERSIBLE byte-for-byte (HIMMEL-1529's zero-behaviour-change
//      claim is untestable if removal cannot restore the file exactly);
//   2. it is IDEMPOTENT in both directions;
//   3. it never touches permissions, and never touches anybody else's hooks.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, before, describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  ENTRIES, install, remove, statusOf, writeAtomic,
} from '../wire-trust-hooks.mjs';
import { EXPECTED_HOOKS } from '../shadow-ledger.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.join(HERE, '..', 'wire-trust-hooks.mjs');

let TMP;
before(() => { TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'wire-trust-')); });
after(() => { try { fs.rmSync(TMP, { recursive: true, force: true }); } catch { /* best effort */ } });

// A settings file shaped like the real one: existing hooks that are NOT ours,
// plus a permissions block the script must never touch.
const BASE = {
  permissions: {
    defaultMode: 'auto',
    allow: ['Bash(git status)'],
    deny: ['Edit(**/.claude/settings.json)'],
  },
  hooks: {
    PreToolUse: [
      { matcher: 'Bash', hooks: [{ type: 'command', command: 'node "$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash.js" "$CLAUDE_PROJECT_DIR/scripts/hooks/guard.sh"' }] },
    ],
    SessionStart: [
      { hooks: [{ type: 'command', command: 'bash "$CLAUDE_PROJECT_DIR/scripts/hooks/session.sh"' }] },
    ],
  },
};

const serialize = (o) => `${JSON.stringify(o, null, 2)}\n`;

// A fixture is a whole fake PROJECT, not a loose settings file: the hooks
// resolve the recorder relative to the settings file's project root, and
// install now refuses when it is absent (see the adopted-project case below).
// `withRecorder: false` builds the adopted-project shape deliberately.
function fixture(name, obj = BASE, { withRecorder = true } = {}) {
  const root = path.join(TMP, name);
  fs.mkdirSync(path.join(root, '.claude'), { recursive: true });
  if (withRecorder) {
    fs.mkdirSync(path.join(root, 'scripts', 'trust'), { recursive: true });
    fs.writeFileSync(path.join(root, 'scripts', 'trust', 'shadow-ledger.mjs'), '// stub\n', 'utf8');
  }
  const p = path.join(root, '.claude', 'settings.json');
  fs.writeFileSync(p, serialize(obj), 'utf8');
  return p;
}

const run = (args, file) => spawnSync(process.execPath, [SCRIPT, ...args, file], { encoding: 'utf8' });

// HIMMEL-1547 CR round — Bug 2's fix moved the wiring table into
// shadow-ledger.mjs (`EXPECTED_HOOKS`) as the ONE definition, with this
// script importing it rather than keeping its own copy. Before that, the two
// tables were free to disagree on which event/matcher a verb belongs to — and
// they did: `wiredVerbs()` in shadow-ledger.mjs used to accept a verb wired
// under ANY event, so a settings file with all seven commands parked under
// `SessionStart` read as fully wired. Asserting SAME OBJECT, not just equal
// content, is what stops a future edit from quietly re-forking the table into
// two copies that drift apart again.
describe('the wiring table has exactly ONE definition', () => {
  test('ENTRIES here IS shadow-ledger.mjs\'s EXPECTED_HOOKS — not a copy of it', () => {
    assert.strictEqual(ENTRIES, EXPECTED_HOOKS, 'same object reference: they cannot disagree because there is only one');
  });
});

describe('reversibility — the zero-behaviour-change claim', () => {
  test('install then remove restores the file BYTE FOR BYTE', () => {
    const f = fixture('roundtrip');
    const original = fs.readFileSync(f, 'utf8');

    const on = run([], f);
    assert.equal(on.status, 0, on.stderr);
    assert.notEqual(fs.readFileSync(f, 'utf8'), original, 'install must actually change something');

    const off = run(['--off'], f);
    assert.equal(off.status, 0, off.stderr);
    // If removal could not restore the file exactly, "adding it changes no
    // behaviour and removing it changes no behaviour" would be unverifiable.
    assert.equal(fs.readFileSync(f, 'utf8'), original);
  });

  // [codex round 1] remove() used to delete an event key whenever the kept list
  // was empty — even when it had removed NOTHING from it. An array this script
  // never touched is not its to delete.
  test('an UNTOUCHED empty event array is preserved', () => {
    const withEmpty = { ...BASE, hooks: { ...BASE.hooks, Stop: [] } };
    const f = fixture('untouched-empty', withEmpty);
    const original = fs.readFileSync(f, 'utf8');
    // [CodeRabbit] Both runs need a status assertion, and the install needs to
    // be shown to have CHANGED something. Without them a refusal on either run
    // leaves the file untouched and the final comparison passes — the test
    // would read as coverage of the round-trip while never exercising it. Same
    // overclaim the concurrency test's own comment calls out below.
    const on = run([], f);
    assert.equal(on.status, 0, on.stderr);
    assert.notEqual(fs.readFileSync(f, 'utf8'), original, 'install must actually change something');
    const off = run(['--off'], f);
    assert.equal(off.status, 0, off.stderr);
    assert.equal(fs.readFileSync(f, 'utf8'), original, 'Stop: [] is none of our business');
  });

  // The documented limit, asserted rather than left to be discovered: an event
  // array that WAS empty and that we then wired into normalizes to absent on
  // removal. remove() runs in its own process and cannot know the prior state,
  // so some shape must normalize; `[]` and absent are identical to every
  // consumer, which makes this the harmless choice — but it is a real edge, so
  // it is pinned here rather than described as byte-exact.
  test('an empty array we DID wire into normalizes to absent', () => {
    const withEmpty = { ...BASE, hooks: { ...BASE.hooks, PostToolUse: [] } };
    const f = fixture('touched-empty', withEmpty);
    run([], f);
    run(['--off'], f);
    const s = JSON.parse(fs.readFileSync(f, 'utf8'));
    assert.equal('PostToolUse' in s.hooks, false);
    assert.deepEqual(s.hooks.PreToolUse, BASE.hooks.PreToolUse, 'everything else is untouched');
  });

  // [glm round 1] install() creates the `hooks` container when a settings file
  // has none, so remove() must drop it again — otherwise the round trip leaves
  // `hooks: {}` where there was no key at all.
  test('a settings file with NO hooks key round-trips exactly', () => {
    const f = fixture('nohooks-roundtrip', { permissions: { defaultMode: 'auto' } });
    const original = fs.readFileSync(f, 'utf8');
    run([], f);
    assert.equal(statusOf(JSON.parse(fs.readFileSync(f, 'utf8'))).wired, 7);
    run(['--off'], f);
    assert.equal(fs.readFileSync(f, 'utf8'), original);
  });

  test('removal leaves no empty event keys behind', () => {
    const f = fixture('nokeys');
    run([], f);
    run(['--off'], f);
    const s = JSON.parse(fs.readFileSync(f, 'utf8'));
    for (const k of ['Notification', 'PostToolUseFailure', 'PermissionDenied', 'PermissionRequest']) {
      assert.equal(k in s.hooks, false, `${k} must be gone, not left as []`);
    }
    // ...but keys that existed before must survive.
    assert.equal(Array.isArray(s.hooks.PreToolUse), true);
    assert.equal(Array.isArray(s.hooks.SessionStart), true);
  });
});

describe('a hand-pasted entry is REPAIRED, not reported wired', () => {
  // [codex round 1] The README told operators to paste these six blocks by hand
  // for two releases. Command equality alone would call such an entry "wired" —
  // including one with NO timeout, where a command hook defaults to 600 SECONDS
  // and can hold every matching tool call for ten minutes. That is exactly the
  // behaviour change the recorder claims not to be.
  const handPasted = (over) => ({
    permissions: BASE.permissions,
    hooks: {
      PreToolUse: [{
        matcher: 'Bash|Edit|Write|MultiEdit|NotebookEdit',
        hooks: [{ type: 'command', command: 'node "$CLAUDE_PROJECT_DIR/scripts/trust/shadow-ledger.mjs" pre', ...over }],
      }],
    },
  });

  test('a missing timeout is not "wired"', () => {
    const s = handPasted({});
    assert.equal(statusOf(s).wired, 0, 'present is not the same as canonical');
    const { settings, changed } = install(s);
    assert.equal(changed, 7, 'the malformed entry is repaired, not skipped');
    assert.equal(settings.hooks.PreToolUse[0].hooks[0].timeout, 10);
    assert.equal(settings.hooks.PreToolUse.length, 1, 'repaired in place, not duplicated');
  });

  test('a wrong matcher is repaired', () => {
    const s = handPasted({ timeout: 10 });
    s.hooks.PreToolUse[0].matcher = 'Bash';
    assert.equal(statusOf(s).wired, 0);
    const { settings } = install(s);
    assert.equal(settings.hooks.PreToolUse[0].matcher, 'Bash|Edit|Write|MultiEdit|NotebookEdit');
    assert.equal(settings.hooks.PreToolUse.length, 1);
  });

  // [codex round 2] Repairing only the FIRST match left a duplicate in place,
  // and a duplicated hook records the same event TWICE — inflating the very
  // count this ledger exists to produce, in the direction that would make the
  // trust programme look more expensive than it is.
  test('a duplicate entry is collapsed to exactly one', () => {
    const { settings: on } = install(BASE);
    // Two identical canonical entries, as a double-paste would leave.
    on.hooks.PermissionRequest.push(structuredClone(on.hooks.PermissionRequest[0]));
    assert.equal(on.hooks.PermissionRequest.length, 2);

    const { settings, changed } = install(on);
    assert.equal(changed, 1, 'the extra is removed and counted');
    assert.equal(settings.hooks.PermissionRequest.length, 1);
    assert.equal(statusOf(settings).wired, 7);
  });

  test('a duplicate is collapsed even when the survivor also needs repair', () => {
    const { settings: on } = install(BASE);
    const dupe = structuredClone(on.hooks.PreToolUse.at(-1));
    delete on.hooks.PreToolUse.at(-1).hooks[0].timeout; // malformed original
    on.hooks.PreToolUse.push(dupe);

    const { settings } = install(on);
    const ours = settings.hooks.PreToolUse.filter((e) => JSON.stringify(e).includes('shadow-ledger.mjs'));
    assert.equal(ours.length, 1);
    assert.equal(ours[0].hooks[0].timeout, 10);
    assert.deepEqual(settings.hooks.PreToolUse[0], BASE.hooks.PreToolUse[0], 'the foreign hook is untouched');
  });

  test('a canonical entry is left exactly alone', () => {
    const { settings: on } = install(BASE);
    const { changed } = install(on);
    assert.equal(changed, 0, 'repair must not fire on already-correct wiring');
  });
});

describe('idempotence', () => {
  test('installing twice changes nothing the second time', () => {
    const f = fixture('idem-on');
    run([], f);
    const afterFirst = fs.readFileSync(f, 'utf8');
    const second = run([], f);
    assert.equal(second.status, 0);
    assert.match(second.stdout, /already wired/);
    assert.equal(fs.readFileSync(f, 'utf8'), afterFirst);
  });

  test('removing twice changes nothing the second time', () => {
    const f = fixture('idem-off');
    run([], f);
    run(['--off'], f);
    const afterFirst = fs.readFileSync(f, 'utf8');
    const second = run(['--off'], f);
    assert.equal(second.status, 0);
    assert.match(second.stdout, /already unwired/);
    assert.equal(fs.readFileSync(f, 'utf8'), afterFirst);
  });

  test('idempotence keys on the COMMAND, not array position', () => {
    // Somebody appends their own hook between two runs. Ours must still be
    // recognised as present rather than duplicated.
    const f = fixture('interleaved');
    run([], f);
    const s = JSON.parse(fs.readFileSync(f, 'utf8'));
    s.hooks.PreToolUse.push({ matcher: 'Write', hooks: [{ type: 'command', command: 'echo other' }] });
    fs.writeFileSync(f, serialize(s), 'utf8');

    const again = run([], f);
    assert.match(again.stdout, /already wired/);
    const final = JSON.parse(fs.readFileSync(f, 'utf8'));
    const ours = final.hooks.PreToolUse.filter((e) => JSON.stringify(e).includes('shadow-ledger.mjs'));
    assert.equal(ours.length, 1, 'exactly one of ours, never a duplicate');
  });
});

describe('what it must never touch', () => {
  test('permissions are unchanged by install and by remove', () => {
    const f = fixture('perms');
    for (const args of [[], ['--off']]) {
      run(args, f);
      const s = JSON.parse(fs.readFileSync(f, 'utf8'));
      assert.deepEqual(s.permissions, BASE.permissions);
    }
  });

  test("another owner's hooks survive install and remove", () => {
    const f = fixture('foreign');
    run([], f);
    run(['--off'], f);
    const s = JSON.parse(fs.readFileSync(f, 'utf8'));
    assert.deepEqual(s.hooks.PreToolUse, BASE.hooks.PreToolUse);
    assert.deepEqual(s.hooks.SessionStart, BASE.hooks.SessionStart);
  });

  test('a foreign hook sharing an event key is not removed with ours', () => {
    // The gate's job is to prove IT did not corrupt the file — not to forbid
    // the file from growing. This is the frozen-inventory trap, avoided.
    const f = fixture('shared-key');
    run([], f);
    const s = JSON.parse(fs.readFileSync(f, 'utf8'));
    s.hooks.Notification.push({ hooks: [{ type: 'command', command: 'bash notify-me.sh' }] });
    fs.writeFileSync(f, serialize(s), 'utf8');

    run(['--off'], f);
    const final = JSON.parse(fs.readFileSync(f, 'utf8'));
    assert.equal(final.hooks.Notification.length, 1, 'the foreign hook survives');
    assert.match(final.hooks.Notification[0].hooks[0].command, /notify-me\.sh/);
  });
});

describe('the wiring it produces', () => {
  test('all seven entries, with PermissionRequest and SessionStart deliberately matcher-less', () => {
    const { settings } = install(BASE);
    const { wired, total } = statusOf(settings);
    assert.equal(total, 7);
    assert.equal(wired, 7);

    const permreq = settings.hooks.PermissionRequest[0];
    assert.equal('matcher' in permreq, false, 'an interrupt counts whatever tool raised it');

    // HIMMEL-1547: the heartbeat must fire on EVERY session source (startup,
    // resume, clear, compact) — a matcher key here would narrow it and open a
    // gap `collection.proven` would then refuse a rate over.
    const heartbeat = settings.hooks.SessionStart.at(-1);
    assert.equal('matcher' in heartbeat, false, 'must fire on every session source, not a filtered subset');

    const pre = settings.hooks.PreToolUse.at(-1);
    assert.equal(pre.matcher, 'Bash|Edit|Write|MultiEdit|NotebookEdit');
  });

  test('every entry carries an explicit 10s timeout', () => {
    // A command hook DEFAULTS to 600 seconds. A stalled PreToolUse hook would
    // hold every matching tool call for ten minutes, which would make this a
    // behaviour change — the one thing the recorder claims not to be.
    const { settings } = install(BASE);
    for (const list of Object.values(settings.hooks)) {
      for (const entry of list) {
        for (const h of entry.hooks) {
          if (!h.command.includes('shadow-ledger.mjs')) continue;
          assert.equal(h.timeout, 10, `missing timeout on: ${h.command}`);
        }
      }
    }
  });

  test('$CLAUDE_PROJECT_DIR is quoted in every command', () => {
    // An unquoted expansion word-splits on a project path containing a space,
    // and the hook then fails open — losing observations silently.
    const { settings } = install(BASE);
    for (const list of Object.values(settings.hooks)) {
      for (const entry of list) {
        for (const h of entry.hooks) {
          if (!h.command.includes('shadow-ledger.mjs')) continue;
          assert.match(h.command, /"\$CLAUDE_PROJECT_DIR\/scripts\/trust\/shadow-ledger\.mjs"/);
        }
      }
    }
  });

  test('it invokes node directly, never bash', () => {
    const { settings } = install(BASE);
    const cmds = Object.values(settings.hooks).flat()
      .flatMap((e) => e.hooks.map((h) => h.command))
      .filter((c) => c.includes('shadow-ledger.mjs'));
    assert.equal(cmds.length, 7);
    for (const c of cmds) assert.match(c, /^node "/);
  });
});

describe('--check writes nothing', () => {
  test('it reports state and leaves the file alone', () => {
    const f = fixture('check');
    const original = fs.readFileSync(f, 'utf8');
    const r = run(['--check'], f);
    assert.equal(r.status, 0);
    assert.match(r.stdout, /0\/7 entries wired/);
    assert.match(r.stdout, /wrote nothing/);
    assert.equal(fs.readFileSync(f, 'utf8'), original);
  });

  test('it reports full wiring after an install', () => {
    const f = fixture('check-after');
    run([], f);
    const r = run(['--check'], f);
    assert.match(r.stdout, /7\/7 entries wired/);
  });
});

describe('it will not wire hooks that point at a recorder that is not there', () => {
  // [codex-adv round 1, high] himmelctl passes no explicit settings path, so
  // the script targets the ambient project. Run from an ADOPTED project — which
  // does not ship scripts/trust/ — it would install six hooks resolving to a
  // file that does not exist: every hook fails, `report` shows zero rows, and
  // status still says 6/6. That is this programme's own failure mode, installed
  // by the tool built to prevent it.
  test('install REFUSES when the recorder is absent', () => {
    const f = fixture('adopted', BASE, { withRecorder: false });
    const original = fs.readFileSync(f, 'utf8');
    const r = run([], f);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /no recorder at/);
    assert.match(r.stderr, /record nothing while reporting as wired/);
    assert.equal(fs.readFileSync(f, 'utf8'), original, 'nothing is written');
  });

  test('--off and --check still work without a recorder', () => {
    // Removing dead wiring is exactly what you want in that project; refusing
    // would strand it.
    const withHooks = fixture('adopted-cleanup');
    run([], withHooks);
    const wired = fs.readFileSync(withHooks, 'utf8');

    const stranded = fixture('adopted-stranded', JSON.parse(wired), { withRecorder: false });
    assert.equal(run(['--check'], stranded).status, 0);
    const off = run(['--off'], stranded);
    assert.equal(off.status, 0, off.stderr);
    assert.equal(statusOf(JSON.parse(fs.readFileSync(stranded, 'utf8'))).wired, 0);
  });
});

describe('the write is atomic and concurrency-checked', () => {
  // [codex-adv round 1, medium] read -> compute -> write is a lost-update
  // window on the deny-listed settings file, and the permissions assertion
  // cannot see it because both objects come from the SAME read.
  // [glm round 2] The previous version of this test mutated the file BEFORE the
  // script started, so the script simply read the mutated file and succeeded —
  // it never exercised the guard, despite being named for it. A test whose name
  // overclaims what it checks is worse than no test, because it reads as
  // coverage. The guard is now exercised DIRECTLY: a stale `expectedBytes` is
  // exactly the state a racing writer produces.
  test('writeAtomic REFUSES when the file no longer matches the snapshot', () => {
    const f = fixture('concurrent');
    const onDisk = fs.readFileSync(f, 'utf8');
    assert.throws(
      () => writeAtomic(f, `${onDisk}// stale snapshot`, '{"clobbered":true}\n'),
      /changed while this ran/,
    );
    assert.equal(fs.readFileSync(f, 'utf8'), onDisk, 'the other writer survives');
  });

  test('writeAtomic replaces the file when the snapshot still matches', () => {
    const f = fixture('atomic-ok');
    const onDisk = fs.readFileSync(f, 'utf8');
    writeAtomic(f, onDisk, '{"ok":true}\n');
    assert.equal(fs.readFileSync(f, 'utf8'), '{"ok":true}\n');
  });

  test("a concurrent writer's permission entry is not reverted", () => {
    const f = fixture('preserve-other');
    const mutated = JSON.parse(fs.readFileSync(f, 'utf8'));
    mutated.permissions.allow.push('Bash(echo hi)');
    fs.writeFileSync(f, serialize(mutated), 'utf8');

    const r = run([], f);
    assert.equal(r.status, 0, r.stderr);
    const after = JSON.parse(fs.readFileSync(f, 'utf8'));
    assert.deepEqual(after.permissions.allow, ['Bash(git status)', 'Bash(echo hi)']);
  });

  test('no temp file is left behind', () => {
    const f = fixture('notemp');
    run([], f);
    const leftovers = fs.readdirSync(path.dirname(f)).filter((n) => n.includes('.tmp'));
    assert.deepEqual(leftovers, []);
  });
});

describe('it refuses rather than guessing', () => {
  test('invalid JSON is refused, not rewritten', () => {
    const f = path.join(TMP, 'broken.json');
    fs.writeFileSync(f, '{ not json', 'utf8');
    const r = run([], f);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /REFUSED/);
    assert.equal(fs.readFileSync(f, 'utf8'), '{ not json', 'the file is untouched');
  });

  test('an unknown option is refused', () => {
    const f = fixture('badopt');
    const r = run(['--yolo'], f);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /unknown option/);
  });

  // [codex-adv round 2] A present-but-not-array value was coerced to `[]` and
  // overwritten — destroying a malformed file or a future schema this script
  // does not understand, with no way for `--off` to restore it.
  test('a non-array hook value is REFUSED, not silently replaced', () => {
    const weird = { ...BASE, hooks: { ...BASE.hooks, Notification: { legacy: 'shape' } } };
    const f = fixture('weird-shape', weird);
    const original = fs.readFileSync(f, 'utf8');
    const r = run([], f);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /is not an array/);
    assert.equal(fs.readFileSync(f, 'utf8'), original, 'the unrecognised shape survives');
  });

  // [codex + glm round 3] The per-event non-array check was one layer short:
  // a `hooks` CONTAINER that is an array or a string would be spread by
  // `{ ...hooks }` into a garbage index-keyed object, destroying the original.
  // Neither security assertion catches it — assertOnlyHooksChanged deliberately
  // excludes `hooks`, and assertPermissionsUnchanged never looks at it.
  test('a non-object hooks CONTAINER is refused, not spread', () => {
    for (const bad of [['a'], 'nope', 42]) {
      const f = fixture(`bad-container-${typeof bad}-${Array.isArray(bad)}`, { ...BASE, hooks: bad });
      const original = fs.readFileSync(f, 'utf8');
      const r = run([], f);
      assert.equal(r.status, 1, `hooks=${JSON.stringify(bad)} must be refused`);
      assert.match(r.stderr, /hooks is not an object/);
      assert.equal(fs.readFileSync(f, 'utf8'), original, 'the original survives');
    }
  });

  // [codex-1, HIMMEL-1547 round] One layer further out again: the settings
  // ROOT. Filed as a suggestion; reproducing it showed it is worse than that.
  // An array root is valid JSON, `{ ...settings }` turns it into an index-keyed
  // object, and `JSON.stringify` then serializes an ARRAY — dropping every named
  // property including the `hooks` just added. Measured on the pre-fix script:
  // it printed "added 6 entries ... permissions unchanged" and exited 0 over a
  // file that was still `[]`. A wiring tool reporting six hooks it did not write
  // is this programme's own failure mode, in the tool built to prevent it.
  test('an ARRAY settings root is refused, not silently serialized away', () => {
    for (const bad of [[], [{ hooks: {} }]]) {
      // A whole fake PROJECT, so the recorder precondition passes and this test
      // reaches the assertion it is actually about.
      const f = fixture(`array-root-${bad.length}`, bad);
      const original = fs.readFileSync(f, 'utf8');
      const r = run([], f);
      assert.equal(r.status, 1, `root=${JSON.stringify(bad)} must be refused`);
      assert.match(r.stderr, /settings root is not a JSON object/);
      assert.doesNotMatch(r.stdout, /added/, 'and must not claim it added anything');
      assert.equal(fs.readFileSync(f, 'utf8'), original, 'the original survives');
    }
  });

  // [codex-2, HIMMEL-1547 round] The bare-script targeting surface. With no path
  // argument and no CLAUDE_PROJECT_DIR, the old default was the SCRIPT's own
  // checkout — so standing in another project and running `--check` reported on
  // himmel's settings.json, cheerfully, with rc=0. `himmelctl trust` always
  // passes an explicit target, which is why this survived; it is the same
  // targeting defect HIMMEL-1551 round 3 only appeared to fix, and
  // assertRecorderPresent does NOT catch it (the himmel checkout HAS a recorder,
  // so the wrong answer passes every check). Refuse the ambiguity, do not
  // resolve it by precedence.
  test('an ambiguous default target is refused, not resolved silently', () => {
    const elsewhere = path.join(TMP, 'other-project');
    fs.mkdirSync(path.join(elsewhere, '.claude'), { recursive: true });
    fs.writeFileSync(path.join(elsewhere, '.claude', 'settings.json'), '{}\n', 'utf8');
    const env = { ...process.env };
    delete env.CLAUDE_PROJECT_DIR;
    const r = spawnSync(process.execPath, [SCRIPT, '--check'], {
      encoding: 'utf8', cwd: elsewhere, env,
    });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /ambiguous target/);
    assert.doesNotMatch(r.stdout, /entries wired/, 'and reports on NO project rather than the wrong one');
  });

  // [codex-adv round 3] A ledger command sharing an entry with a foreign hook
  // was INVISIBLE to isOurs: install appended a second ledger entry beside it
  // (seven live invocations reported as 6/6, zero duplicates) and remove
  // reported 0/6 while one invocation stayed wired. on/off/status all lied.
  test('a ledger command embedded beside a foreign hook is REFUSED', () => {
    const mixed = {
      ...BASE,
      hooks: {
        ...BASE.hooks,
        Notification: [{
          hooks: [
            { type: 'command', command: 'node "$CLAUDE_PROJECT_DIR/scripts/trust/shadow-ledger.mjs" notify', timeout: 10 },
            { type: 'command', command: 'bash notify-me.sh' },
          ],
        }],
      },
    };
    const f = fixture('embedded', mixed);
    const original = fs.readFileSync(f, 'utf8');
    for (const args of [[], ['--off']]) {
      const r = run(args, f);
      assert.equal(r.status, 1, `${args[0] ?? 'on'} must refuse`);
      assert.match(r.stderr, /mixes a shadow-ledger command with other hooks/);
    }
    assert.equal(fs.readFileSync(f, 'utf8'), original, 'the operator\'s grouping is untouched');
  });

  test('a foreign multi-hook entry with NO ledger command is fine', () => {
    // The refusal must be about OUR command being embedded, not about
    // multi-hook entries in general — those are legitimate and common.
    const multi = {
      ...BASE,
      hooks: {
        ...BASE.hooks,
        Stop: [{ hooks: [{ type: 'command', command: 'a.sh' }, { type: 'command', command: 'b.sh' }] }],
      },
    };
    const f = fixture('foreign-multi', multi);
    assert.equal(run([], f).status, 0);
    assert.equal(statusOf(JSON.parse(fs.readFileSync(f, 'utf8'))).wired, 7);
  });

  test('remove() refuses the same shape rather than mangling it', () => {
    assert.throws(() => remove({ hooks: ['x'] }), /hooks is not an object/);
    assert.throws(() => install({ hooks: 'x' }), /hooks is not an object/);
  });

  test('a null hooks value is still refused', () => {
    // `null` is typeof 'object' — the classic hole in this exact check.
    assert.throws(() => install({ hooks: null }), /hooks is not an object/);
  });

  test('--check reports duplicates rather than a clean 6/6', () => {
    const f = fixture('dupe-status');
    run([], f);
    const s = JSON.parse(fs.readFileSync(f, 'utf8'));
    s.hooks.PermissionRequest.push(structuredClone(s.hooks.PermissionRequest[0]));
    fs.writeFileSync(f, serialize(s), 'utf8');
    const r = run(['--check'], f);
    assert.match(r.stdout, /DUPLICATE owned entr/);
    assert.equal(statusOf(JSON.parse(fs.readFileSync(f, 'utf8'))).duplicates, 1);
  });

  test('a settings file with no hooks section still wires cleanly', () => {
    const f = fixture('nohooks', { permissions: { defaultMode: 'auto' } });
    const r = run([], f);
    assert.equal(r.status, 0, r.stderr);
    const s = JSON.parse(fs.readFileSync(f, 'utf8'));
    assert.equal(statusOf(s).wired, 7);
  });
});

describe('the report is not confused with the wiring', () => {
  test('a successful install tells the operator to VERIFY, not to believe it', () => {
    // Three chain legs reported "merged" while the recorder held zero rows.
    // The install message must not become the fourth way to say "wired" without
    // the number.
    const f = fixture('says-verify');
    const r = run([], f);
    assert.match(r.stdout, /shadow-ledger\.mjs report/);
    assert.match(r.stdout, /non-zero rows/);
    // HIMMEL-1547: "wired" now also requires a PROVEN collection line, not
    // just a non-zero row count — five live hooks can still grow a healthy-
    // looking window while the collector itself is dead.
    assert.match(r.stdout, /PROVEN collection line/);
  });

  // HIMMEL-1561 measured the previous "restart claude" claim FALSE: the ledger
  // recorded within seconds of the settings file changing, in the very session
  // that had just asserted it could not. An unverified claim in a success
  // message is this subsystem's own recurring defect — pin the correction so
  // it cannot silently regress back to the disproven claim.
  test('the success message no longer claims a restart is needed', () => {
    const f = fixture('says-no-restart');
    const r = run([], f);
    assert.match(r.stdout, /no restart needed/);
    assert.doesNotMatch(r.stdout, /restart claude/i);
  });
});

describe('remove() is exact', () => {
  test('it removes only our seven, counted', () => {
    const { settings: on } = install(BASE);
    const { settings: off, changed } = remove(on);
    assert.equal(changed, 7);
    assert.deepEqual(off, BASE);
  });
});

// The CLI's TARGET resolution (HIMMEL-1551 CR round 4).
//
// The defect these cover shipped through three review rounds because nothing
// exercised it: `cmdTrust` computed the target as `repoRoot()`, which is
// `resolve(__dirname, '..', '..')` — the himmel checkout this CLI lives in,
// whatever directory you ran from. Round 3 added a `target <path>` log line and
// was titled "name the target project", which made the wrong target VISIBLE
// without making it correct, and additionally suppressed the script's own
// CLAUDE_PROJECT_DIR fallback by passing an explicit path that overrode it.
//
// Reproduced live before the fix: `himmelctl trust status` run from an
// unrelated project printed the himmel worktree's settings.json.
describe('himmelctl trust targets the project you are standing in', () => {
  const CLI = path.join(HERE, '..', '..', 'himmelctl', 'bin.js');
  const rootOf = (settingsFile) => path.dirname(path.dirname(settingsFile));
  // `status` only — it writes nothing, so these can never mutate a real file.
  const cli = (cwd, env = {}) => spawnSync(
    process.execPath,
    [CLI, 'trust', 'status'],
    { encoding: 'utf8', cwd, env: { ...process.env, CLAUDE_PROJECT_DIR: '', ...env } },
  );

  test('CLAUDE_PROJECT_DIR names the target', () => {
    const root = rootOf(fixture('cli-explicit'));
    const r = cli(os.tmpdir(), { CLAUDE_PROJECT_DIR: root });
    assert.match(r.stdout, /himmelctl trust: target/);
    assert.ok(
      r.stdout.includes(path.join(root, '.claude', 'settings.json')),
      `expected the target to be the named project, got:\n${r.stdout}`,
    );
  });

  test('without CLAUDE_PROJECT_DIR it uses the working directory, NOT the himmel checkout', () => {
    const root = rootOf(fixture('cli-ambient'));
    const r = cli(root);
    assert.ok(
      r.stdout.includes(path.join(root, '.claude', 'settings.json')),
      `expected the target to be the cwd's project, got:\n${r.stdout}`,
    );
    // The regression itself: the himmel checkout must not be the target.
    const himmel = path.resolve(HERE, '..', '..', '..');
    assert.ok(
      !r.stdout.includes(path.join(himmel, '.claude', 'settings.json')),
      `targeted the himmel checkout instead of the cwd:\n${r.stdout}`,
    );
  });

  test('a project with no .claude/settings.json is refused by NAME, not silently redirected', () => {
    const empty = path.join(TMP, 'cli-no-settings');
    fs.mkdirSync(empty, { recursive: true });
    const r = cli(empty);
    assert.equal(r.status, 1);
    // `.` for the separator: win32 prints a backslash, POSIX a forward slash.
    assert.match(r.stderr, /no \.claude.settings\.json at/);
    // The old behaviour would have fallen back to himmel's and reported on it.
    assert.ok(!/6\/6|0\/6/.test(r.stdout), `reported on some other project:\n${r.stdout}`);
  });
});

// [codex-adv round 4, medium] A ledger invocation that is recognisably ours but
// NOT canonical — an extra argument, or the right command under an event we do
// not own. `isOurs` accepts any single-hook ledger command; install/remove/
// statusOf all key on the exact canonical string. The gap between those two
// definitions was invisible to every one of them.
describe('a noncanonical ledger invocation is refused, not silently doubled', () => {
  const LEDGER_CMD = 'node "$CLAUDE_PROJECT_DIR/scripts/trust/shadow-ledger.mjs"';
  const withEntry = (event, command) => ({
    ...BASE,
    hooks: {
      ...BASE.hooks,
      [event]: [
        ...(Array.isArray(BASE.hooks?.[event]) ? BASE.hooks[event] : []),
        { matcher: 'Bash', hooks: [{ type: 'command', command, timeout: 10 }] },
      ],
    },
  });

  test('install REFUSES an argument-extended ledger command', () => {
    const settings = withEntry('PreToolUse', `${LEDGER_CMD} pre --extra`);
    assert.throws(() => install(settings), /does not own/);
  });

  // [CodeRabbit, major] The predicate used to require the trailing quote, so
  // the UNQUOTED $CLAUDE_PROJECT_DIR form — the paste mistake the LEDGER
  // comment explicitly names — was invisible: treated as foreign, doubled by
  // install, and still reported 6/6. The reachable variant, not a theoretical
  // one, which is why it gets its own test rather than riding the one above.
  // [codex round 5, important] The suite asserts byte-for-byte reversibility on
  // 2-space fixtures, so it could never see that a differently-formatted file
  // gets reformatted by the write and cannot be restored by --off. The CLI's
  // targeting fix made that reachable: `trust` now follows the operator into
  // arbitrary projects, which do not all format JSON the same way.
  test('a differently-formatted settings file is REFUSED, not reformatted', () => {
    const root = path.join(TMP, 'four-space');
    fs.mkdirSync(path.join(root, 'scripts', 'trust'), { recursive: true });
    fs.writeFileSync(path.join(root, 'scripts', 'trust', 'shadow-ledger.mjs'), '// stub\n', 'utf8');
    fs.mkdirSync(path.join(root, '.claude'), { recursive: true });
    const f = path.join(root, '.claude', 'settings.json');
    fs.writeFileSync(f, `${JSON.stringify(BASE, null, 4)}\n`, 'utf8');
    const original = fs.readFileSync(f, 'utf8');
    const r = run([], f);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /formatted differently/);
    assert.equal(fs.readFileSync(f, 'utf8'), original, 'refusal must write nothing');
  });

  test('install REFUSES the UNQUOTED ledger path', () => {
    const settings = withEntry('PreToolUse', 'node $CLAUDE_PROJECT_DIR/scripts/trust/shadow-ledger.mjs pre');
    assert.throws(() => install(settings), /does not own/);
  });

  test('install REFUSES a ledger command under an event we do not own', () => {
    const settings = withEntry('SessionStart', `${LEDGER_CMD} pre`);
    assert.throws(() => install(settings), /does not own/);
  });

  test('remove REFUSES it too, rather than leaving the stray behind', () => {
    const settings = withEntry('PreToolUse', `${LEDGER_CMD} pre --extra`);
    assert.throws(() => remove(settings), /does not own/);
  });

  // The regression the guard must not cause: canonical wiring is still fine,
  // and a DUPLICATE canonical entry still converges rather than being refused.
  test('canonical entries — including duplicates — are still accepted', () => {
    const { settings: wired } = install(BASE);
    assert.doesNotThrow(() => install(wired));
    const doubled = structuredClone(wired);
    doubled.hooks.PreToolUse.push(structuredClone(
      doubled.hooks.PreToolUse.find((e) => String(e.hooks?.[0]?.command).includes('shadow-ledger')),
    ));
    assert.equal(statusOf(doubled).duplicates, 1);
    assert.doesNotThrow(() => install(doubled));
    assert.equal(statusOf(install(doubled).settings).duplicates, 0);
  });
});
