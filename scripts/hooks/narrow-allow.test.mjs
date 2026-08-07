import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { assertDenyAskUnchanged, assertStrictNarrowing, tempPathFor, writeSettingsAtomic } from './narrow-allow.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const NARROWER = join(HERE, 'narrow-allow.mjs');

// This fixture is fully synthetic — it deliberately does NOT read the live
// .claude/settings.json. A fixture derived from the live file would pass or
// fail depending on whether this task's own apply step (which removes
// `Bash(bun run *)` from the real file) has already run, which is exactly
// the test-ordering trap that bit wire-hook-bash.test.mjs once already.
const FIXTURE = `{
  "permissions": {
    "allow": [
      "Bash(cp *)",
      "Bash(git *)",
      "Bash(bun run *)",
      "Bash(bun test *)",
      "Bash(node *)"
    ],
    "deny": [
      "Bash(rm -rf *)"
    ],
    "ask": [
      "Read(*)"
    ]
  },
  "hooks": {
    "PreToolUse": []
  }
}
`;

function withFixture(run, text = FIXTURE) {
  const dir = mkdtempSync(join(tmpdir(), 'narrow-allow-'));
  const fixture = join(dir, 'settings.json');
  try {
    writeFileSync(fixture, text);
    return run(fixture);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function invoke(...args) {
  return spawnSync(process.execPath, [NARROWER, ...args], { encoding: 'utf8' });
}

test('removes a requested allow entry and leaves everything else unchanged', () => {
  withFixture((fixture) => {
    const before = JSON.parse(readFileSync(fixture, 'utf8'));
    const result = invoke(fixture, '--remove', 'Bash(bun run *)');
    const after = JSON.parse(readFileSync(fixture, 'utf8'));

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /removed 1 allow entry/);
    assert.deepEqual(after.permissions.allow, [
      'Bash(cp *)',
      'Bash(git *)',
      'Bash(bun test *)',
      'Bash(node *)',
    ]);
    assert.deepEqual(after.permissions.deny, before.permissions.deny);
    assert.deepEqual(after.permissions.ask, before.permissions.ask);
    assert.deepEqual(after.hooks, before.hooks);
  });
});

test('removes multiple requested entries in one invocation, preserving order of survivors', () => {
  withFixture((fixture) => {
    const result = invoke(fixture, '--remove', 'Bash(bun run *)', '--remove', 'Bash(node *)');
    const after = JSON.parse(readFileSync(fixture, 'utf8'));

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /removed 2 allow entries/);
    assert.deepEqual(after.permissions.allow, ['Bash(cp *)', 'Bash(git *)', 'Bash(bun test *)']);
  });
});

test('is idempotent after the first removal', () => {
  withFixture((fixture) => {
    const first = invoke(fixture, '--remove', 'Bash(bun run *)');
    assert.equal(first.status, 0, first.stderr);
    const afterFirst = readFileSync(fixture, 'utf8');

    const second = invoke(fixture, '--remove', 'Bash(bun run *)');
    assert.equal(second.status, 0, second.stderr);
    assert.match(second.stdout, /already narrowed; no change made/);
    assert.equal(readFileSync(fixture, 'utf8'), afterFirst);
  });
});

test('an already-absent entry is a no-op, not an error', () => {
  withFixture((fixture) => {
    const before = readFileSync(fixture, 'utf8');
    const result = invoke(fixture, '--remove', 'Bash(does-not-exist *)');

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /already narrowed; no change made/);
    assert.equal(readFileSync(fixture, 'utf8'), before);
  });
});

test('refuses an ambiguous removal (entry appears more than once) without writing', () => {
  const duplicated = FIXTURE.replace(
    '"Bash(node *)"',
    '"Bash(node *)",\n      "Bash(node *)"'
  );
  withFixture((fixture) => {
    const before = readFileSync(fixture, 'utf8');
    const result = invoke(fixture, '--remove', 'Bash(node *)');

    assert.equal(result.status, 1);
    assert.match(result.stderr, /appears 2 times.*refusing ambiguous removal/);
    assert.equal(readFileSync(fixture, 'utf8'), before);
  }, duplicated);
});

test('--check reports the removal and writes nothing', () => {
  withFixture((fixture) => {
    const before = readFileSync(fixture, 'utf8');
    const result = invoke('--check', fixture, '--remove', 'Bash(bun run *)');

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /would remove 1 allow entry.*wrote nothing/);
    assert.equal(readFileSync(fixture, 'utf8'), before);
  });
});

test('refuses when no --remove entry is supplied', () => {
  withFixture((fixture) => {
    const before = readFileSync(fixture, 'utf8');
    const result = invoke(fixture);

    assert.equal(result.status, 1);
    assert.match(result.stderr, /at least one --remove/);
    assert.equal(readFileSync(fixture, 'utf8'), before);
  });
});

test('assertStrictNarrowing refuses an added entry', () => {
  assert.throws(
    () => assertStrictNarrowing(['Bash(git *)'], ['Bash(git *)', 'Bash(evil *)']),
    /permissions\.allow gained an entry not present before/
  );
});

test('assertStrictNarrowing refuses a same-size or grown allow list', () => {
  assert.throws(
    () => assertStrictNarrowing(['Bash(git *)'], ['Bash(git *)']),
    /permissions\.allow did not shrink/
  );
});

test('assertDenyAskUnchanged refuses an injected deny mutation', () => {
  const before = { permissions: { deny: ['Bash(rm -rf *)'], ask: [] } };
  const after = structuredClone(before);
  after.permissions.deny.push('Bash(anything *)');

  assert.throws(
    () => assertDenyAskUnchanged(before, after),
    /permissions\.deny changed; refusing to write/
  );
});

test('tempPathFor yields a unique, per-process temp name — not the shared fixed name (F1)', () => {
  withFixture((fixture) => {
    const sharedName = join(dirname(fixture), '.narrow-allow.tmp');
    const a = tempPathFor(fixture);
    const b = tempPathFor(fixture);

    // Two calls must not collide: a FIXED name would return the same path
    // every time, so concurrent runs would stage into and clobber one file.
    assert.notEqual(a, b);
    // A sibling of settings.json (same directory), so the rename stays
    // intra-directory and atomic.
    assert.equal(dirname(a), dirname(fixture));
    // NOT the shared fixed name whose collision is the F1 bug.
    assert.notEqual(a, sharedName);
    assert.notEqual(b, sharedName);
    // Carries the per-process pid + uuid suffix so a collision is impossible.
    assert.match(basename(a), /^\.narrow-allow\.tmp\.\d+\.[0-9a-f-]{36}$/);
  });
});

test('writeSettingsAtomic opens the temp exclusively: a pre-existing temp is refused (EEXIST), never clobbered (F1)', () => {
  withFixture((fixture) => {
    // A foreign temp already staged at this path (a concurrent run). The
    // exclusive open MUST refuse rather than truncate it, and the failed
    // write MUST NOT delete it — it is not this process's temp.
    const foreignTmp = join(dirname(fixture), '.narrow-allow.foreign.tmp');
    const sentinel = 'CONCURRENT-PROCESS-STAGED-OUTPUT';
    writeFileSync(foreignTmp, sentinel, 'utf8');

    assert.throws(
      () => writeSettingsAtomic(fixture, '{}\n', foreignTmp),
      (error) => error.code === 'EEXIST',
    );

    // Untouched: not clobbered by the write, not deleted by the cleanup
    // (staged stayed false, so no unlink ran).
    assert.equal(readFileSync(foreignTmp, 'utf8'), sentinel);
  });
});

test('a concurrent process\'s temp at the shared name survives a narrow-allow run (F1, revert-differential)', () => {
  withFixture((fixture) => {
    // Plant the FIXED shared temp name a concurrent narrow-allow would have
    // used pre-F1. The unfixed code stages into this exact path, truncating
    // (and on a failure, deleting) a concurrent run's staged output; the F1
    // code uses a per-process name and never touches it.
    const sharedTmp = join(dirname(fixture), '.narrow-allow.tmp');
    const sentinel = 'CONCURRENT-PROCESS-STAGED-OUTPUT';
    writeFileSync(sharedTmp, sentinel, 'utf8');

    const result = invoke(fixture, '--remove', 'Bash(bun run *)');

    // The narrowing still happened (sanity — the run is otherwise correct).
    assert.equal(result.status, 0, result.stderr);
    const after = JSON.parse(readFileSync(fixture, 'utf8'));
    assert.equal(after.permissions.allow.includes('Bash(bun run *)'), false);

    // The core F1 assertion: the concurrent process's staged temp is intact.
    assert.equal(readFileSync(sharedTmp, 'utf8'), sentinel);
  });
});
