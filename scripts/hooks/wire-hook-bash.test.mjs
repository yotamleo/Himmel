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
    assert.equal(commands(after).length, 16);
    for (const command of commands(after)) {
      assert.match(command, /^node "\$CLAUDE_PROJECT_DIR\/scripts\/hooks\/run-hook-with-bash\.js" /);
    }
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

test('refuses an inventory-count mismatch without writing', () => {
  withFixture((fixture) => {
    const settings = JSON.parse(readFileSync(fixture, 'utf8'));
    settings.hooks.PostToolUse[0].hooks.pop();
    writeFileSync(fixture, `${JSON.stringify(settings, null, 2)}\n`);
    const before = readFileSync(fixture, 'utf8');

    const result = invoke(fixture);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /inventory mismatch for PostToolUse: expected 2, found 1/);
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
