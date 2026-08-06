import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { assertPermissionsUnchanged } from './wire-hook-bash.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const WIRER = join(HERE, 'wire-hook-bash.mjs');
const SETTINGS = join(HERE, '..', '..', '.claude', 'settings.json');

// The live settings.json is the fixture SOURCE (it carries the real 16-script
// inventory the wirer asserts against), but the fixture must not inherit its
// current wiring state: once the tree is wired, a fixture copied verbatim makes
// every "rewrote 16" expectation read "already wired" and the suite fails on a
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
    assert.match(result.stdout, /rewrote 16 hook command\(s\)/);

    const all = commands(after);
    // The 16 OWNED scripts are routed through the Bash resolver.
    const wired = all.filter((c) => c.startsWith('node "$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash.js"'));
    assert.equal(wired.length, 16);
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
    settings.hooks.PostToolUse[0].hooks.pop();
    writeFileSync(fixture, `${JSON.stringify(settings, null, 2)}\n`);
    const before = readFileSync(fixture, 'utf8');

    const result = invoke(fixture);
    assert.equal(result.status, 1);
    // Foreign entries are no longer counted, so a missing OWNED script is caught
    // by the owned-set size assertion (HIMMEL-1552), not a per-event count.
    assert.match(result.stderr, /owned hook inventory size mismatch: expected 16, found 15/);
    assert.equal(readFileSync(fixture, 'utf8'), before);
  });
});

test('permission gate refuses an injected permissions mutation', () => {
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
    assert.match(result.stdout, /would rewrite 16 hook command\(s\).*wrote nothing/);
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
    assert.match(result.stdout, /would rewrite 16 hook command\(s\)/);
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
    assert.match(result.stdout, /rewrote 16 hook command\(s\)/);

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
    assert.match(result.stdout, /rewrote 16 hook command\(s\)/);

    const after = JSON.parse(readFileSync(fixture, 'utf8'));
    // The 16 OWNED scripts still route through the resolver.
    const wired = commands(after).filter((c) =>
      c.startsWith('node "$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash.js"'));
    assert.equal(wired.length, 16);
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
    assert.match(result.stdout, /rewrote 16 hook command\(s\)/);

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
    assert.match(result.stdout, /rewrote 16 hook command\(s\)/);

    const after = JSON.parse(readFileSync(fixture, 'utf8'));
    const stopCommands = after.hooks.Stop.flatMap((g) => g.hooks).map((h) => h.command);
    assert.ok(stopCommands.includes(planted),
      'the unrecognised .sh under the foreign Stop key was left byte-identical');
  });
});
