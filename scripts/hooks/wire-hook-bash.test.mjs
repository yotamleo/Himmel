import { test as baseTest } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { assertOnlyHookCommandsChanged, assertPermissionsUnchanged } from './wire-hook-bash.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const WIRER = join(HERE, 'wire-hook-bash.mjs');
const SETTINGS = join(HERE, '..', '..', '.claude', 'settings.json');

// Public/adopter clones lack .claude/settings.json (it is in PRIVATE_PATHS and
// redacted on the public mirror), so the live file this suite exercises is
// absent there. Every case below is a spec FOR that real file; none can run
// without it, so skip them — naming the reason — rather than fail on the
// missing private fixture (HIMMEL-1590). The one case that does not touch
// settings.json (the permission-gate unit test) stays a plain baseTest.
const SETTINGS_SKIP = existsSync(SETTINGS)
  ? undefined
  : '.claude/settings.json (PRIVATE_PATHS) is absent — public mirror / adopter checkout lacks the private fixture this suite is the spec for';
const test = (name, fn) => baseTest(name, SETTINGS_SKIP ? { skip: SETTINGS_SKIP } : {}, fn);

// The live settings.json is the fixture SOURCE (it carries the real 17-script
// inventory the wirer asserts against), but the fixture must not inherit its
// current wiring state: once the tree is wired, a fixture copied verbatim makes
// every "rewrote 17" expectation read "already wired" and the suite fails on a
// correctly-wired repo. Normalize each hook command back to the bare-bash form
// so the rewrite tests always start unwired, whatever the tree looks like.
function unwire(text) {
  return text.replace(
    /"node \\"\$CLAUDE_PROJECT_DIR\/scripts\/hooks\/run-hook-with-bash\.js\\" \\"\$CLAUDE_PROJECT_DIR\/scripts\/hooks\/([A-Za-z0-9._-]+\.sh)\\""/g,
    '"bash $CLAUDE_PROJECT_DIR/scripts/hooks/$1"'
  );
}

function withFixture(run, { wired = false } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'wire-hook-bash-'));
  const fixture = join(dir, 'settings.json');
  try {
    const source = readFileSync(SETTINGS, 'utf8');
    writeFileSync(fixture, wired ? source : unwire(source));
    return run(fixture);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function invoke(...args) {
  return spawnSync(process.execPath, [WIRER, ...args], { encoding: 'utf8' });
}

function commands(settings) {
  return Object.values(settings.hooks).flatMap((groups) =>
    groups.flatMap((group) => group.hooks.map((hook) => hook.command))
  );
}

test('rewrites the known hook inventory through the Bash resolver', () => {
  withFixture((fixture) => {
    const before = JSON.parse(readFileSync(fixture, 'utf8'));
    const result = invoke(fixture);
    const after = JSON.parse(readFileSync(fixture, 'utf8'));

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /rewrote 17 hook command\(s\)/);

    const all = commands(after);
    // The 17 OWNED scripts are routed through the Bash resolver.
    const wired = all.filter((c) => c.startsWith('node "$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash.js"'));
    assert.equal(wired.length, 17);
    for (const command of wired) {
      assert.match(command, /^node "\$CLAUDE_PROJECT_DIR\/scripts\/hooks\/run-hook-with-bash\.js" /);
    }
    // Foreign commands (the trust ledger under the owned events + speak-reply
    // under Stop) coexist and are NOT touched by this tool — the point of
    // HIMMEL-1552. They remain present, in their original form.
    const foreign = all.filter((c) => !c.startsWith('node "$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash.js"'));
    assert.ok(foreign.length > 0, 'foreign hook commands coexist with the owned inventory');
    assert.deepEqual(after.permissions, before.permissions);
  });
});

test('is idempotent after the first rewrite', () => {
  withFixture((fixture) => {
    const first = invoke(fixture);
    assert.equal(first.status, 0, first.stderr);
    const afterFirst = readFileSync(fixture, 'utf8');

    const second = invoke(fixture);
    assert.equal(second.status, 0, second.stderr);
    assert.match(second.stdout, /already wired; no change made/);
    assert.equal(readFileSync(fixture, 'utf8'), afterFirst);
  });
});

test('refuses an unrecognised hook entry without writing', () => {
  withFixture((fixture) => {
    const settings = JSON.parse(readFileSync(fixture, 'utf8'));
    settings.hooks.PreToolUse[0].hooks[0].command =
      'bash $CLAUDE_PROJECT_DIR/scripts/hooks/not-in-the-inventory.sh';
    writeFileSync(fixture, `${JSON.stringify(settings, null, 2)}\n`);
    const before = readFileSync(fixture, 'utf8');

    const result = invoke(fixture);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /unrecognised hook script: not-in-the-inventory\.sh/);
    assert.equal(readFileSync(fixture, 'utf8'), before);
  });
});

test('refuses a known hook script in the wrong inventory entry', () => {
  withFixture((fixture) => {
    const settings = JSON.parse(readFileSync(fixture, 'utf8'));
    const hooks = settings.hooks.PreToolUse[0].hooks;
    [hooks[0].command, hooks[1].command] = [hooks[1].command, hooks[0].command];
    writeFileSync(fixture, `${JSON.stringify(settings, null, 2)}\n`);
    const before = readFileSync(fixture, 'utf8');

    const result = invoke(fixture);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /script inventory mismatch: expected auto-approve-safe-bash\.sh, found check-cr-marker-on-pr-create\.sh/);
    assert.equal(readFileSync(fixture, 'utf8'), before);
  });
});

test('refuses a missing owned hook script without writing', () => {
  withFixture((fixture) => {
    const settings = JSON.parse(readFileSync(fixture, 'utf8'));
    // Remove the OWNED hook specifically, not just the last array element:
    // HIMMEL-1635 coexists in this same PostToolUse "Agent" group by
    // appending its own foreign hook after auto-arm-on-subagent-cap.sh, so a
    // blind .pop() would remove that coexisting foreign hook instead of
    // simulating the missing-owned-script case this test is about.
    const hooks = settings.hooks.PostToolUse[0].hooks;
    // Defensive read (h.command ?? '') so a malformed entry without a command
    // field fails as the ownedIndex assertion below, not a TypeError. The guard
    // stops findIndex's -1 from splice(-1, 1), which would drop the coexisting
    // HIMMEL-1635 foreign hook (the array's last element) instead of the owned
    // entry this test means to remove.
    const ownedIndex = hooks.findIndex((h) => (h.command ?? '').includes('/scripts/hooks/'));
    assert.ok(ownedIndex >= 0, 'expected an OWNED scripts/hooks/*.sh entry to splice out');
    hooks.splice(ownedIndex, 1);
    writeFileSync(fixture, `${JSON.stringify(settings, null, 2)}\n`);
    const before = readFileSync(fixture, 'utf8');

    const result = invoke(fixture);
    assert.equal(result.status, 1);
    // HIMMEL-1643: install-when-missing makes the wirer TOLERANT of a missing
    // owned script (the size check alone no longer refuses this fixture — the
    // shortfall is fully explained by the one script removed above). It is
    // still refused, but via a DIFFERENT gate: auto-arm-on-subagent-cap.sh is
    // a PostToolUse script, and install only knows how to insert into
    // hooks.SessionStart, so there is no preceding SessionStart entry to
    // anchor it after — installMissingEntries refuses rather than guessing a
    // location. See the dedicated install tests below for the case this
    // capability DOES handle (a missing SessionStart script with a present
    // anchor).
    assert.match(result.stderr, /cannot install auto-arm-on-subagent-cap\.sh: no preceding EXPECTED_SCRIPT_ORDER script is present in hooks\.SessionStart to anchor after/);
    assert.equal(readFileSync(fixture, 'utf8'), before);
  });
});

// HIMMEL-1643: install-when-missing. wire-hook-bash.mjs is REWRITE-ONLY
// before this (plan-critic r1 F1, settled) — any owned script with zero
// present entries was an unconditional refusal. These tests pin the
// extended behaviour: a missing SessionStart script (one with a preceding
// SessionStart anchor already present) is INSTALLED, not refused; an
// unrelated foreign SessionStart hook survives untouched; and an impostor
// present alongside a legitimately-missing script still refuses the whole
// write (the security gate is widened ONLY for the scripts this tool itself
// installs, nothing else). Uses 'qmd-staleness-notice.sh' — the current
// inventory's own last SessionStart entry — as the "missing script" fixture,
// so this suite does not depend on graphify-freshness-advisory.sh existing in
// EXPECTED_SCRIPT_ORDER yet (that inventory bump is a separate commit; the
// repo's own pre-commit gate requires every commit's node --test run green,
// so the install CAPABILITY has to land, and be provable, before the
// inventory grows to need it).

function withoutScript(source, script) {
  const settings = JSON.parse(source);
  for (const group of settings.hooks.SessionStart) {
    const idx = group.hooks.findIndex((h) => (h.command ?? '').includes(`/scripts/hooks/${script}`));
    if (idx !== -1) {
      group.hooks.splice(idx, 1);
      return settings;
    }
  }
  throw new Error(`fixture setup: ${script} not found in hooks.SessionStart to remove`);
}

test('installs a missing owned SessionStart entry back into place', () => {
  withFixture((fixture) => {
    const settings = withoutScript(readFileSync(fixture, 'utf8'), 'qmd-staleness-notice.sh');
    writeFileSync(fixture, `${JSON.stringify(settings, null, 2)}\n`);
    const beforePermissions = settings.permissions;

    const result = invoke(fixture);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /rewrote 17 hook command\(s\)/);

    const after = JSON.parse(readFileSync(fixture, 'utf8'));
    assert.deepEqual(after.permissions, beforePermissions);

    // Reinstalled, wired, and positioned immediately after its preceding
    // inventory script (inject-initiative.sh) — i.e. right where it started.
    const sessionHooks = after.hooks.SessionStart[0].hooks;
    const idx = sessionHooks.findIndex((h) => (h.command ?? '').includes('qmd-staleness-notice.sh'));
    assert.ok(idx > 0, 'qmd-staleness-notice.sh entry was reinstalled');
    assert.match(sessionHooks[idx].command, /^node "\$CLAUDE_PROJECT_DIR\/scripts\/hooks\/run-hook-with-bash\.js" /);
    assert.match(sessionHooks[idx - 1].command, /inject-initiative\.sh/);
    // HIMMEL-1643 (codex-adv-3): an installer-produced SessionStart entry must
    // carry a bounded timeout so a hung advisory can never block session startup
    // for the 600s default. The installed entry is indistinguishable from its
    // hand-wired siblings, which all carry an explicit timeout.
    assert.equal(sessionHooks[idx].timeout, 30, 'installed entry carries a bounded 30s timeout');
  });
});

test('installs a missing entry without disturbing an unrelated foreign SessionStart hook', () => {
  withFixture((fixture) => {
    const settings = withoutScript(readFileSync(fixture, 'utf8'), 'qmd-staleness-notice.sh');
    const planted = 'node "$CLAUDE_PROJECT_DIR/scripts/some-other-tool.mjs" hello';
    settings.hooks.SessionStart[0].hooks.push({ type: 'command', command: planted });
    writeFileSync(fixture, `${JSON.stringify(settings, null, 2)}\n`);

    const result = invoke(fixture);
    assert.equal(result.status, 0, result.stderr);

    const after = JSON.parse(readFileSync(fixture, 'utf8'));
    const sessionCommands = after.hooks.SessionStart[0].hooks.map((h) => h.command);
    assert.ok(sessionCommands.includes(planted), 'the unrelated foreign SessionStart hook was left untouched');
    assert.ok(sessionCommands.some((c) => c.includes('qmd-staleness-notice.sh')), 'the missing entry was reinstalled');
  });
});

test('still refuses the whole write when an impostor accompanies a legitimately-missing script', () => {
  withFixture((fixture) => {
    const settings = withoutScript(readFileSync(fixture, 'utf8'), 'qmd-staleness-notice.sh');
    settings.hooks.SessionStart[0].hooks.push({
      type: 'command',
      command: 'bash $CLAUDE_PROJECT_DIR/scripts/hooks/totally-rogue.sh',
    });
    writeFileSync(fixture, `${JSON.stringify(settings, null, 2)}\n`);
    const before = readFileSync(fixture, 'utf8');

    const result = invoke(fixture);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /invokes unrecognised hook script: totally-rogue\.sh/);
    assert.equal(readFileSync(fixture, 'utf8'), before);
  });
});

baseTest('assertOnlyHookCommandsChanged tolerates ONLY the declared inserted scripts', () => {
  const before = {
    permissions: { allow: [], deny: [], ask: [] },
    hooks: {
      SessionStart: [{ hooks: [
        { type: 'command', command: 'bash $CLAUDE_PROJECT_DIR/scripts/hooks/inject-initiative.sh' },
      ] }],
    },
  };
  const afterLegit = structuredClone(before);
  afterLegit.hooks.SessionStart[0].hooks.push({
    type: 'command', command: 'bash $CLAUDE_PROJECT_DIR/scripts/hooks/qmd-staleness-notice.sh',
  });
  // Declaring exactly the one legitimately-inserted script is accepted.
  assert.doesNotThrow(() => assertOnlyHookCommandsChanged(before, afterLegit, ['qmd-staleness-notice.sh']));

  const afterExtra = structuredClone(afterLegit);
  afterExtra.hooks.SessionStart[0].hooks.push({
    type: 'command', command: 'bash $CLAUDE_PROJECT_DIR/scripts/hooks/check-update-available.sh',
  });
  // A SECOND addition beyond the declared list must still refuse — the gate
  // tolerates exactly the N declared entries, not "however many appeared".
  assert.throws(
    () => assertOnlyHookCommandsChanged(before, afterExtra, ['qmd-staleness-notice.sh']),
    /a parsed field outside hook commands changed; refusing to write/
  );
});

baseTest('permission gate refuses an injected permissions mutation', () => {
  const before = { permissions: { allow: ['Bash(git *)'], deny: [], ask: ['Read(*)'] } };
  const after = structuredClone(before);
  after.permissions.allow.push('Bash(everything *)');

  assert.throws(
    () => assertPermissionsUnchanged(before, after),
    /permissions\.allow changed; refusing to write/
  );
});

test('--check reports the rewrite and writes nothing', () => {
  withFixture((fixture) => {
    const before = readFileSync(fixture, 'utf8');
    const result = invoke('--check', fixture);

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /would rewrite 17 hook command\(s\).*wrote nothing/);
    assert.equal(readFileSync(fixture, 'utf8'), before);
  });
});

// HIMMEL-1552: the two settings.json writers must coexist. The trust ledger
// adds foreign event keys (Stop, Notification, ...) and foreign entries inside
// the owned events. These three tests pin the own-only contract: foreign shape
// is accepted, an impostor is still refused, and document-order enumeration
// keeps the rewrite on target when a foreign event precedes an owned one.

test('accepts the live repo settings shape (foreign event keys + interleaved foreign entries)', () => {
  // Precondition: the live file really carries foreign event keys AND foreign
  // entries inside the owned events. If that drifts, the acceptance check below
  // would still pass but stop exercising what its name claims — assert it first.
  const live = JSON.parse(unwire(readFileSync(SETTINGS, 'utf8')));
  const eventKeys = Object.keys(live.hooks);
  assert.ok(eventKeys.includes('Stop') && eventKeys.includes('Notification'),
    'live file carries foreign event keys');
  assert.ok(
    live.hooks.PreToolUse.some((g) => g.hooks.some((h) => h.command.includes('/scripts/trust/shadow-ledger.mjs'))),
    'an owned event carries a foreign (trust-ledger) entry',
  );

  withFixture((fixture) => {
    const result = invoke('--check', fixture);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /would rewrite 17 hook command\(s\)/);
  });
});

test('still refuses an impostor scripts/hooks/*.sh script under an owned event', () => {
  withFixture((fixture) => {
    const settings = JSON.parse(readFileSync(fixture, 'utf8'));
    settings.hooks.PreToolUse[0].hooks[0].command =
      'bash $CLAUDE_PROJECT_DIR/scripts/hooks/totally-rogue.sh';
    writeFileSync(fixture, `${JSON.stringify(settings, null, 2)}\n`);
    const before = readFileSync(fixture, 'utf8');

    const result = invoke(fixture);
    assert.equal(result.status, 1);
    // Foreign events/entries are ignored, but an unrecognised scripts/hooks/*.sh
    // invocation under an OWNED event is an impostor this tool would otherwise
    // route — so it is still refused, by name.
    assert.match(result.stderr, /invokes unrecognised hook script: totally-rogue\.sh/);
    assert.equal(readFileSync(fixture, 'utf8'), before);
  });
});

test('rewrites the correct slots when a foreign event key precedes an owned one', () => {
  withFixture((fixture) => {
    const settings = JSON.parse(readFileSync(fixture, 'utf8'));
    // Reorder so a FOREIGN event key (Stop) appears BEFORE the first owned event.
    // A frozen-order textual walk would then mis-slot the first owned command
    // into the foreign slot; document-order enumeration must keep the rewrite on
    // target (HIMMEL-1552).
    const hooks = settings.hooks;
    const reordered = { Stop: hooks.Stop };
    for (const k of Object.keys(hooks)) if (k !== 'Stop') reordered[k] = hooks[k];
    settings.hooks = reordered;
    writeFileSync(fixture, `${JSON.stringify(settings, null, 2)}\n`);

    const result = invoke(fixture);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /rewrote 17 hook command\(s\)/);

    const after = JSON.parse(readFileSync(fixture, 'utf8'));
    const preCommands = after.hooks.PreToolUse.flatMap((g) => g.hooks).map((h) => h.command);
    assert.ok(preCommands[0].includes('/scripts/hooks/run-hook-with-bash.js'),
      'the first OWNED command was rewritten to its resolver');
    const stopCommand = after.hooks.Stop[0].hooks[0].command;
    assert.match(stopCommand, /speak-reply\.sh/);
    assert.ok(!stopCommand.includes('run-hook-with-bash.js'),
      'the foreign Stop command was left untouched');
  });
});

// HIMMEL-1577: a KNOWN-inventory script under a FOREIGN event key is foreign
// to this tool (hookEntries skips foreign events), so the textual rewrite must
// leave it byte-identical — not refuse it. Previously the event-blind textual
// walk classified the known command string as owned, disagreed with the
// event-aware hookEntries, and refused a legitimate file.

test('accepts a known hook script under a foreign event key (appended)', () => {
  withFixture((fixture) => {
    const settings = JSON.parse(readFileSync(fixture, 'utf8'));
    const planted = 'bash "$CLAUDE_PROJECT_DIR/scripts/hooks/auto-approve-safe-bash.sh"';
    settings.hooks.Stop = settings.hooks.Stop || [];
    settings.hooks.Stop.push({
      hooks: [{ type: 'command', command: planted }],
    });
    writeFileSync(fixture, `${JSON.stringify(settings, null, 2)}\n`);

    const result = invoke(fixture);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /rewrote 17 hook command\(s\)/);

    const after = JSON.parse(readFileSync(fixture, 'utf8'));
    // The 17 OWNED scripts still route through the resolver.
    const wired = commands(after).filter((c) =>
      c.startsWith('node "$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash.js"'));
    assert.equal(wired.length, 17);
    // The known script planted under the FOREIGN Stop key is left untouched —
    // it is not this tool's hook, so neither its routing nor its text is owned.
    const stopCommands = after.hooks.Stop.flatMap((g) => g.hooks).map((h) => h.command);
    assert.ok(stopCommands.includes(planted),
      'the known script under the foreign Stop key was left byte-identical');
  });
});

test('accepts a known hook script under a foreign event key ordered first', () => {
  withFixture((fixture) => {
    const settings = JSON.parse(readFileSync(fixture, 'utf8'));
    const planted = 'bash "$CLAUDE_PROJECT_DIR/scripts/hooks/auto-approve-safe-bash.sh"';
    // Order the FOREIGN event key BEFORE the owned ones AND put the planted
    // known script first within it, so its command field is the first the
    // textual walk visits. An event-blind walk would classify it owned and
    // mis-slot it onto the first owned entry; the fix keeps the rewrite on
    // target (HIMMEL-1577).
    const hooks = settings.hooks;
    const stopGroup = { hooks: [{ type: 'command', command: planted }] };
    const reordered = { Stop: hooks.Stop ? [stopGroup, ...hooks.Stop] : [stopGroup] };
    for (const k of Object.keys(hooks)) if (k !== 'Stop') reordered[k] = hooks[k];
    settings.hooks = reordered;
    writeFileSync(fixture, `${JSON.stringify(settings, null, 2)}\n`);

    const result = invoke(fixture);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /rewrote 17 hook command\(s\)/);

    const after = JSON.parse(readFileSync(fixture, 'utf8'));
    // The first OWNED command (the real PreToolUse[0]) is still rewritten to its
    // resolver — the foreign command before it did not consume its slot.
    const preCommands = after.hooks.PreToolUse.flatMap((g) => g.hooks).map((h) => h.command);
    assert.ok(preCommands[0].includes('/scripts/hooks/run-hook-with-bash.js'),
      'the first OWNED command was rewritten to its resolver');
    // The known script planted under foreign Stop is untouched.
    const stopCommands = after.hooks.Stop.flatMap((g) => g.hooks).map((h) => h.command);
    assert.ok(stopCommands.includes(planted),
      'the known script under the foreign Stop key was left byte-identical');
  });
});

test('an unrecognised .sh under a foreign event key is left untouched (isolation)', () => {
  withFixture((fixture) => {
    const settings = JSON.parse(readFileSync(fixture, 'utf8'));
    const planted = 'bash "$CLAUDE_PROJECT_DIR/scripts/hooks/not-ours-at-all.sh"';
    settings.hooks.Stop = settings.hooks.Stop || [];
    settings.hooks.Stop.push({
      hooks: [{ type: 'command', command: planted }],
    });
    writeFileSync(fixture, `${JSON.stringify(settings, null, 2)}\n`);

    const result = invoke(fixture);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /rewrote 17 hook command\(s\)/);

    const after = JSON.parse(readFileSync(fixture, 'utf8'));
    const stopCommands = after.hooks.Stop.flatMap((g) => g.hooks).map((h) => h.command);
    assert.ok(stopCommands.includes(planted),
      'the unrecognised .sh under the foreign Stop key was left byte-identical');
  });
});
