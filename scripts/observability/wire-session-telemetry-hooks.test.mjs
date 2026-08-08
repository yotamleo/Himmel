// HIMMEL-1635 — the suite is the spec for the session-telemetry wiring
// script. Mirrors scripts/trust/tests/wire-trust-hooks.test.mjs's approach:
// the properties that matter, in order:
//   1. it is REVERSIBLE byte-for-byte;
//   2. it is IDEMPOTENT in both directions;
//   3. it never touches permissions, and never disturbs anybody else's
//      hooks — including a hook sharing its OWN matcher group (the
//      PostToolUse "Agent" coexistence case this ticket exists for).

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, before, describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  install, remove, statusOf, writeAtomic,
} from './wire-session-telemetry-hooks.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.join(HERE, 'wire-session-telemetry-hooks.mjs');
const REAL_WRITER = path.join(HERE, 'session-run-hook.ts');

let TMP;
before(() => { TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'wire-session-telemetry-')); });
after(() => { try { fs.rmSync(TMP, { recursive: true, force: true }); } catch { /* best effort */ } });

// A settings file shaped like the real one: existing PreToolUse/PostToolUse/
// SessionStart hooks belonging to OTHER writers (wire-hook-bash-shaped and
// trust-ledger-shaped), including the PostToolUse "Agent" matcher group this
// script must append into, never replace.
const BASE = {
  permissions: {
    allow: ['Bash(git status)'],
    deny: ['Edit(**/.claude/settings.json)'],
  },
  hooks: {
    PreToolUse: [
      { matcher: 'Bash', hooks: [{ type: 'command', command: 'node "$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash.js" "$CLAUDE_PROJECT_DIR/scripts/hooks/guard.sh"' }] },
      { matcher: 'Bash|Edit|Write|MultiEdit|NotebookEdit', hooks: [{ type: 'command', command: 'node "$CLAUDE_PROJECT_DIR/scripts/trust/shadow-ledger.mjs" pre', timeout: 10 }] },
    ],
    PostToolUse: [
      { matcher: 'Agent', hooks: [{ type: 'command', command: 'node "$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash.js" "$CLAUDE_PROJECT_DIR/scripts/hooks/auto-arm-on-subagent-cap.sh"' }] },
    ],
    SessionStart: [
      { hooks: [{ type: 'command', command: 'node "$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash.js" "$CLAUDE_PROJECT_DIR/scripts/hooks/check-update-available.sh"', timeout: 15 }] },
      { hooks: [{ type: 'command', command: 'node "$CLAUDE_PROJECT_DIR/scripts/trust/shadow-ledger.mjs" heartbeat', timeout: 10 }] },
    ],
  },
};

const serialize = (o) => `${JSON.stringify(o, null, 2)}\n`;

// A fixture is a whole fake PROJECT: the hooks resolve the writer relative to
// the settings file's project root, and install refuses when it is absent.
function fixture(name, obj = BASE, { withWriter = true } = {}) {
  const root = path.join(TMP, name);
  fs.mkdirSync(path.join(root, '.claude'), { recursive: true });
  if (withWriter) {
    fs.mkdirSync(path.join(root, 'scripts', 'observability'), { recursive: true });
    fs.copyFileSync(REAL_WRITER, path.join(root, 'scripts', 'observability', 'session-run-hook.ts'));
  }
  const p = path.join(root, '.claude', 'settings.json');
  fs.writeFileSync(p, serialize(obj), 'utf8');
  return p;
}

const run = (args, file) => spawnSync(process.execPath, [SCRIPT, ...args, file], { encoding: 'utf8' });

describe('reversibility — install then remove round-trips byte for byte', () => {
  test('install then --off restores the file exactly', () => {
    const f = fixture('roundtrip');
    const original = fs.readFileSync(f, 'utf8');

    const on = run([], f);
    assert.equal(on.status, 0, on.stderr);
    assert.notEqual(fs.readFileSync(f, 'utf8'), original, 'install must actually change something');

    const off = run(['--off'], f);
    assert.equal(off.status, 0, off.stderr);
    assert.equal(fs.readFileSync(f, 'utf8'), original);
  });

  test('a settings file with no hooks section round-trips exactly', () => {
    const f = fixture('nohooks-roundtrip', { permissions: { defaultMode: 'auto' } });
    const original = fs.readFileSync(f, 'utf8');
    run([], f);
    assert.equal(statusOf(JSON.parse(fs.readFileSync(f, 'utf8'))).wired, 4);
    run(['--off'], f);
    assert.equal(fs.readFileSync(f, 'utf8'), original);
  });

  test('removal leaves no empty event keys behind (SessionEnd is our own new key)', () => {
    const f = fixture('nokeys');
    run([], f);
    assert.equal('SessionEnd' in JSON.parse(fs.readFileSync(f, 'utf8')).hooks, true);
    run(['--off'], f);
    const s = JSON.parse(fs.readFileSync(f, 'utf8'));
    assert.equal('SessionEnd' in s.hooks, false, 'SessionEnd must be gone, not left as []');
    assert.equal(Array.isArray(s.hooks.PreToolUse), true);
    assert.equal(Array.isArray(s.hooks.PostToolUse), true);
    assert.equal(Array.isArray(s.hooks.SessionStart), true);
  });
});

describe('coexistence — the PostToolUse "Agent" group is shared, not replaced', () => {
  test('our hook is appended into the existing Agent group, its sibling untouched', () => {
    const { settings } = install(BASE);
    const agentGroups = settings.hooks.PostToolUse.filter((g) => g.matcher === 'Agent');
    assert.equal(agentGroups.length, 1, 'no second Agent group is created');
    assert.equal(agentGroups[0].hooks.length, 2, 'the existing hook plus ours');
    assert.deepEqual(agentGroups[0].hooks[0], BASE.hooks.PostToolUse[0].hooks[0], 'the pre-existing hook is byte-identical');
    assert.match(agentGroups[0].hooks[1].command, /session-run-hook\.ts" subagent-end/);
  });

  test('removing ours leaves the sibling hook and the group itself in place', () => {
    const { settings: on } = install(BASE);
    const { settings: off } = remove(on);
    assert.deepEqual(off.hooks.PostToolUse, BASE.hooks.PostToolUse);
  });

  test('PreToolUse gets its OWN new "Agent" group (none pre-existing)', () => {
    const { settings } = install(BASE);
    const agentGroups = settings.hooks.PreToolUse.filter((g) => g.matcher === 'Agent');
    assert.equal(agentGroups.length, 1);
    assert.equal(agentGroups[0].hooks.length, 1);
    assert.match(agentGroups[0].hooks[0].command, /subagent-start/);
    // The two pre-existing PreToolUse groups (foreign, trust-ledger) survive.
    assert.deepEqual(settings.hooks.PreToolUse[0], BASE.hooks.PreToolUse[0]);
    assert.deepEqual(settings.hooks.PreToolUse[1], BASE.hooks.PreToolUse[1]);
  });

  test('SessionStart gets its own dedicated group, existing groups untouched', () => {
    const { settings } = install(BASE);
    assert.equal(settings.hooks.SessionStart.length, 3);
    assert.deepEqual(settings.hooks.SessionStart[0], BASE.hooks.SessionStart[0]);
    assert.deepEqual(settings.hooks.SessionStart[1], BASE.hooks.SessionStart[1]);
    assert.match(settings.hooks.SessionStart[2].hooks[0].command, /session-start/);
    assert.equal('matcher' in settings.hooks.SessionStart[2], false);
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

  test('a hand-pasted entry missing its timeout is REPAIRED, not reported wired', () => {
    const handPasted = {
      ...BASE,
      hooks: {
        ...BASE.hooks,
        SessionEnd: [{ hooks: [{ type: 'command', command: 'bun "$CLAUDE_PROJECT_DIR/scripts/observability/session-run-hook.ts" session-end' }] }],
      },
    };
    assert.equal(statusOf(handPasted).wired, 0, 'present without a timeout is not canonical, and the other three are absent');
    const { settings, changed } = install(handPasted);
    assert.equal(changed, 4, 'the malformed SessionEnd entry is repaired, plus the 3 missing entries added');
    assert.equal(settings.hooks.SessionEnd[0].hooks[0].timeout, 10);
    assert.equal(settings.hooks.SessionEnd.length, 1, 'repaired in place, not duplicated');
  });

  test('a duplicate entry is collapsed to exactly one', () => {
    const { settings: on } = install(BASE);
    const dupeGroup = structuredClone(on.hooks.PreToolUse.find((g) => g.matcher === 'Agent'));
    on.hooks.PreToolUse.push(dupeGroup);
    const { settings, changed } = install(on);
    assert.equal(changed, 1, 'the extra is removed and counted');
    assert.equal(settings.hooks.PreToolUse.filter((g) => g.matcher === 'Agent').length, 1);
    assert.equal(statusOf(settings).wired, 4);
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

  test('foreign hooks under events we own survive install and remove', () => {
    const f = fixture('foreign');
    run([], f);
    run(['--off'], f);
    const s = JSON.parse(fs.readFileSync(f, 'utf8'));
    assert.deepEqual(s.hooks.PreToolUse[0], BASE.hooks.PreToolUse[0]);
    assert.deepEqual(s.hooks.PreToolUse[1], BASE.hooks.PreToolUse[1]);
  });
});

describe('the wiring it produces', () => {
  test('all four entries wired', () => {
    const { settings } = install(BASE);
    const { wired, total } = statusOf(settings);
    assert.equal(total, 4);
    assert.equal(wired, 4);
  });

  test('every entry carries an explicit 10s timeout', () => {
    const { settings } = install(BASE);
    for (const list of Object.values(settings.hooks)) {
      for (const entry of list) {
        for (const h of entry.hooks) {
          if (!h.command.includes('session-run-hook.ts')) continue;
          assert.equal(h.timeout, 10, `missing timeout on: ${h.command}`);
        }
      }
    }
  });

  test('$CLAUDE_PROJECT_DIR is quoted in every command', () => {
    const { settings } = install(BASE);
    for (const list of Object.values(settings.hooks)) {
      for (const entry of list) {
        for (const h of entry.hooks) {
          if (!h.command.includes('session-run-hook.ts')) continue;
          assert.match(h.command, /"\$CLAUDE_PROJECT_DIR\/scripts\/observability\/session-run-hook\.ts"/);
        }
      }
    }
  });

  test('it invokes bun, and the four verbs are exactly the README-documented set', () => {
    const { settings } = install(BASE);
    const cmds = Object.values(settings.hooks).flat()
      .flatMap((e) => e.hooks.map((h) => h.command))
      .filter((c) => c.includes('session-run-hook.ts'));
    assert.equal(cmds.length, 4);
    for (const c of cmds) assert.match(c, /^bun "/);
    const verbs = cmds.map((c) => c.trim().split(/\s+/).pop()).sort();
    assert.deepEqual(verbs, ['session-end', 'session-start', 'subagent-end', 'subagent-start']);
  });
});

describe('--check writes nothing', () => {
  test('it reports state and leaves the file alone', () => {
    const f = fixture('check');
    const original = fs.readFileSync(f, 'utf8');
    const r = run(['--check'], f);
    assert.equal(r.status, 0);
    assert.match(r.stdout, /0\/4 entries wired/);
    assert.match(r.stdout, /wrote nothing/);
    assert.equal(fs.readFileSync(f, 'utf8'), original);
  });

  test('it reports full wiring after an install', () => {
    const f = fixture('check-after');
    run([], f);
    const r = run(['--check'], f);
    assert.match(r.stdout, /4\/4 entries wired/);
  });
});

describe('it will not wire hooks that point at a writer that is not there', () => {
  test('install REFUSES when the writer is absent', () => {
    const f = fixture('adopted', BASE, { withWriter: false });
    const original = fs.readFileSync(f, 'utf8');
    const r = run([], f);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /no writer at/);
    assert.equal(fs.readFileSync(f, 'utf8'), original, 'nothing is written');
  });

  test('--off and --check still work without a writer', () => {
    const withHooks = fixture('adopted-cleanup');
    run([], withHooks);
    const wired = fs.readFileSync(withHooks, 'utf8');

    const stranded = fixture('adopted-stranded', JSON.parse(wired), { withWriter: false });
    assert.equal(run(['--check'], stranded).status, 0);
    const off = run(['--off'], stranded);
    assert.equal(off.status, 0, off.stderr);
    assert.equal(statusOf(JSON.parse(fs.readFileSync(stranded, 'utf8'))).wired, 0);
  });
});

describe('the write is atomic and concurrency-checked', () => {
  test('writeAtomic REFUSES when the file no longer matches the snapshot', () => {
    const f = fixture('concurrent');
    const onDisk = fs.readFileSync(f, 'utf8');
    assert.throws(
      () => writeAtomic(f, `${onDisk}// stale snapshot`, '{"clobbered":true}\n'),
      /changed while this ran/,
    );
    assert.equal(fs.readFileSync(f, 'utf8'), onDisk, 'the other writer survives');
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

  test('a corrupted settings file (invalid JSON) is refused on --off and --check too', () => {
    const f = path.join(TMP, 'broken2.json');
    fs.writeFileSync(f, '{"hooks": [1,2,', 'utf8');
    for (const args of [['--off'], ['--check']]) {
      const r = run(args, f);
      assert.equal(r.status, 1, `${args[0]} must refuse`);
      assert.match(r.stderr, /REFUSED/);
    }
    assert.equal(fs.readFileSync(f, 'utf8'), '{"hooks": [1,2,', 'the file is untouched');
  });

  test('an unknown option is refused', () => {
    const f = fixture('badopt');
    const r = run(['--yolo'], f);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /unknown option/);
  });

  test('a non-array hook value is REFUSED, not silently replaced', () => {
    const weird = { ...BASE, hooks: { ...BASE.hooks, Notification: { legacy: 'shape' } } };
    const f = fixture('weird-shape', weird);
    const original = fs.readFileSync(f, 'utf8');
    const r = run([], f);
    assert.equal(r.status, 0, 'Notification is not one of our events, so it is never inspected');
    assert.notEqual(fs.readFileSync(f, 'utf8'), original);
    const s = JSON.parse(fs.readFileSync(f, 'utf8'));
    assert.deepEqual(s.hooks.Notification, { legacy: 'shape' }, 'left completely alone');
  });

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

  test('an ARRAY settings root is refused, not silently serialized away', () => {
    const f = fixture('array-root', []);
    const original = fs.readFileSync(f, 'utf8');
    const r = run([], f);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /settings root is not a JSON object/);
    assert.doesNotMatch(r.stdout, /added/, 'and must not claim it added anything');
    assert.equal(fs.readFileSync(f, 'utf8'), original, 'the original survives');
  });

  test('one of our OWN event arrays being non-array is refused', () => {
    const bad = { ...BASE, hooks: { ...BASE.hooks, SessionStart: 'nope' } };
    const f = fixture('bad-own-event', bad);
    const original = fs.readFileSync(f, 'utf8');
    const r = run([], f);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /hooks\.SessionStart is not an array/);
    assert.equal(fs.readFileSync(f, 'utf8'), original);
  });
});
