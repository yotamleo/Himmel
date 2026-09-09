import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { makeTmpDir } from '../lib/test-tmpdir.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const WIRER = join(HERE, 'wire-plugin-hook-bash.mjs');
const PLUGIN_HOOKS = join(HERE, '..', '..', 'marketplace', 'plugins', 'himmel-ops', 'hooks', 'hooks.json');

// HIMMEL-2047/HIMMEL-2758: an independent restatement of
// wire-plugin-hook-bash.mjs's own wired-form prefix, not imported from it —
// so this spec pins the expected output rather than circularly re-running the
// generator it is meant to check. The launcher RUNS (via `command -p sh`, not
// sourced via `.` — dash drops `.`'s operands, HIMMEL-2758) run-node.sh VENDORED into the
// plugin itself (${CLAUDE_PLUGIN_ROOT}/hooks/run-node.sh, byte-identical to
// scripts/lib/run-node.sh — see test-plugin-hook-bash-wiring.sh's drift
// check), never $CLAUDE_PROJECT_DIR — see wiredCommand()'s own header
// comment for why (CR round 2, [codex-1]/[codex-2]).
const WIRED_PREFIX = 'command -p sh "${CLAUDE_PLUGIN_ROOT}/hooks/run-node.sh" "${CLAUDE_PLUGIN_ROOT}/hooks/run-hook-with-bash.js" ';

// The two SUPERSEDED launcher tokens. A command in either shape must still be
// recognised as owned (unwired) and MIGRATED to the current form on the next
// rewrite, exactly like the pre-HIMMEL-2047 bare-`node` legacyWiredCommand()
// already migrates.
//
//   `.`   pre-HIMMEL-2758: dash drops its operands.
//   `sh`  the first HIMMEL-2758 shape, superseded within the same ticket: a
//         bare `sh` is a PATH lookup, so a host whose PATH excludes the
//         shell's directory killed the whole chain at rc=127.
const LEGACY_LAUNCHER_TOKENS = ['.', 'sh'];
function legacyPrefix(token) {
  return `${token} "\${CLAUDE_PLUGIN_ROOT}/hooks/run-node.sh" "\${CLAUDE_PLUGIN_ROOT}/hooks/run-hook-with-bash.js" `;
}

// FULL dot-wired command for one project-source hook script (no
// --fail-closed-when) — the shape wire-plugin-hook-bash.mjs's
// legacyDotWiredCommand() recognises as owned/unwired and migrates.
function legacyDotWiredCommand(script, token = '.') {
  return `${legacyPrefix(token)}--optional "$CLAUDE_PROJECT_DIR/scripts/hooks/${script}"`;
}

function commands(pluginHooks) {
  return Object.values(pluginHooks.hooks).flatMap((groups) =>
    groups.flatMap((group) => group.hooks.map((hook) => hook.command))
  );
}

function unwire(text) {
  const pluginHooks = JSON.parse(text);
  for (const commandHook of Object.values(pluginHooks.hooks).flatMap((groups) =>
    groups.flatMap((group) => group.hooks)
  )) {
    const command = commandHook.command;
    if (command.includes('/hooks/inject-minerva-critic.sh')) {
      commandHook.command = 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/inject-minerva-critic.sh"';
      continue;
    }
    const match = command.match(/scripts\/hooks\/([A-Za-z0-9._-]+\.sh)"/);
    assert.ok(match, `could not extract project hook script from ${command}`);
    const script = match[1];
    if (script === 'block-lesson-enforcement-writes.sh') {
      commandHook.command = 'bash -c \'h="$CLAUDE_PROJECT_DIR/scripts/hooks/block-lesson-enforcement-writes.sh"; if [ -f "$h" ]; then exec bash "$h"; elif [ "${HIMMEL_LESSON_LOOP:-0}" = "1" ]; then echo "block-lesson-enforcement-writes: hook script missing while HIMMEL_LESSON_LOOP=1 (stale checkout?) - failing closed" >&2; exit 2; fi\'';
    } else if (script === 'block-glm-external-writes.sh') {
      // HIMMEL-1649 round 5 [codex-adv-1] — second fail-closed entry. Spelled
      // out here rather than derived from the wirer, so this stays an
      // INDEPENDENT restatement of the expected output instead of a circular
      // re-run of the generator it is meant to pin.
      commandHook.command = 'bash -c \'h="$CLAUDE_PROJECT_DIR/scripts/hooks/block-glm-external-writes.sh"; if [ -f "$h" ]; then exec bash "$h"; elif [ "${HIMMEL_GLM_WORKER:-0}" = "1" ]; then echo "block-glm-external-writes: hook script missing while HIMMEL_GLM_WORKER=1 (stale checkout?) - failing closed" >&2; exit 2; fi\'';
    } else {
      commandHook.command = `bash -c 'h="$CLAUDE_PROJECT_DIR/scripts/hooks/${script}"; if [ -f "$h" ]; then exec bash "$h"; fi'`;
    }
  }
  return `${JSON.stringify(pluginHooks, null, 2)}\n`;
}

function withFixture(run, { wired = false } = {}) {
  const dir = makeTmpDir('wire-plugin-hook-bash-');
  const fixture = join(dir, 'hooks.json');
  try {
    const source = readFileSync(PLUGIN_HOOKS, 'utf8');
    writeFileSync(fixture, wired ? source : unwire(source));
    return run(fixture);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function invoke(...args) {
  return spawnSync(process.execPath, [WIRER, ...args], { encoding: 'utf8' });
}

test('rewrites the exact 21-command plugin inventory through the installed launcher', () => {
  withFixture((fixture) => {
    const before = JSON.parse(readFileSync(fixture, 'utf8'));
    const result = invoke(fixture);
    const after = JSON.parse(readFileSync(fixture, 'utf8'));

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /rewrote 21 hook command\(s\)/);
    assert.equal(commands(after).length, 21);
    for (const command of commands(after)) {
      assert.ok(command.startsWith(WIRED_PREFIX));
      assert.doesNotMatch(command, /(^|\s)bash(\s|$)/);
    }

    const scrub = (value) => {
      const copy = structuredClone(value);
      for (const hook of Object.values(copy.hooks).flatMap((groups) => groups.flatMap((group) => group.hooks))) {
        hook.command = '__COMMAND__';
      }
      return copy;
    };
    assert.deepEqual(scrub(after), scrub(before));
  });
});

// HIMMEL-2758 migration: a command still wired by either superseded launcher
// token must be recognised as owned (not refused as an inventory mismatch) and
// rewritten to the current form on the next pass.
for (const token of LEGACY_LAUNCHER_TOKENS) {
  test(`migrates a superseded \`${token}\`-wired plugin command to the command -p sh form`, () => {
    withFixture((fixture) => {
      const pluginHooks = JSON.parse(readFileSync(fixture, 'utf8'));
      // PreToolUse[1] is block-docker-privesc.sh (EXPECTED_HOOKS[1]): project-
      // source, no --fail-closed-when — the plain legacyDotWiredCommand shape.
      const group = pluginHooks.hooks.PreToolUse[1];
      group.hooks[0].command = legacyDotWiredCommand('block-docker-privesc.sh', token);
      writeFileSync(fixture, `${JSON.stringify(pluginHooks, null, 2)}\n`);

      const result = invoke(fixture);
      assert.equal(result.status, 0, result.stderr);
      assert.match(result.stdout, /rewrote 21 hook command\(s\)/);

      const after = JSON.parse(readFileSync(fixture, 'utf8'));
      const rewritten = after.hooks.PreToolUse[1].hooks[0].command;
      assert.ok(rewritten.startsWith(WIRED_PREFIX), `\`${token}\`-wired plugin entry migrated to the command -p sh form`);
      assert.ok(rewritten.includes('block-docker-privesc.sh'));
    });
  });
}

// HIMMEL-2758: the live plugin hooks.json must never carry either superseded
// launcher — the dot form dash drops operands from, nor the bare `sh` form
// that dies at rc=127 under a restricted PATH.
test('no hook command in the live plugin hooks.json matches a superseded launcher prefix', () => {
  const live = JSON.parse(readFileSync(PLUGIN_HOOKS, 'utf8'));
  for (const token of LEGACY_LAUNCHER_TOKENS) {
    const stale = commands(live).filter((c) => c.startsWith(legacyPrefix(token)));
    assert.deepEqual(stale, [], `every run-node.sh launch must use \`command -p sh\`, not \`${token}\` (HIMMEL-2758)`);
  }
});

test('is idempotent after the first plugin rewrite', () => {
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

test('refuses an added plugin hook without writing', () => {
  withFixture((fixture) => {
    const pluginHooks = JSON.parse(readFileSync(fixture, 'utf8'));
    pluginHooks.hooks.Notification.push({
      hooks: [{ type: 'command', command: 'bash "$CLAUDE_PROJECT_DIR/scripts/hooks/new-guard.sh"' }],
    });
    writeFileSync(fixture, `${JSON.stringify(pluginHooks, null, 2)}\n`);
    const before = readFileSync(fixture, 'utf8');

    const result = invoke(fixture);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /inventory mismatch for Notification: expected 1, found 2/);
    assert.equal(readFileSync(fixture, 'utf8'), before);
  });
});

test('refuses a command in the wrong inventory slot without writing', () => {
  withFixture((fixture) => {
    const pluginHooks = JSON.parse(readFileSync(fixture, 'utf8'));
    const hooks = pluginHooks.hooks.PreToolUse;
    [hooks[1].hooks[0].command, hooks[2].hooks[0].command] = [hooks[2].hooks[0].command, hooks[1].hooks[0].command];
    writeFileSync(fixture, `${JSON.stringify(pluginHooks, null, 2)}\n`);
    const before = readFileSync(fixture, 'utf8');

    const result = invoke(fixture);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /command inventory mismatch: expected block-docker-privesc\.sh/);
    assert.equal(readFileSync(fixture, 'utf8'), before);
  });
});

test('--check validates the live plugin inventory and writes nothing', () => {
  const before = readFileSync(PLUGIN_HOOKS, 'utf8');
  const result = invoke('--check', PLUGIN_HOOKS);

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /already wired; no change needed.*wrote nothing/);
  assert.equal(readFileSync(PLUGIN_HOOKS, 'utf8'), before);
});
