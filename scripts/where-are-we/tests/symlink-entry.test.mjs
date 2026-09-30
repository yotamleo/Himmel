// scripts/where-are-we/tests/symlink-entry.test.mjs — HIMMEL-3871. Each CLI must
// run main() when invoked through a symlinked directory (macOS /var → /private/var,
// any symlinked dir on Linux). A raw `import.meta.url === pathToFileURL(argv[1])`
// guard is false there, so main() never runs: empty output, rc 0. Every case
// triggers a usage error, so "main ran" is observable as rc 1 + a stderr message
// (rc 0 alone is exactly the bug).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, symlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const realDir = join(dirname(fileURLToPath(import.meta.url)), '..');
const scratch = mkdtempSync(join(tmpdir(), 'wat-symlink-'));
const linkDir = join(scratch, 'link');
symlinkSync(realDir, linkDir, 'dir');

const run = (script, args) =>
  spawnSync(process.execPath, [join(linkDir, script), ...args], { encoding: 'utf8' });

const cases = [
  ['index.mjs', [], /--ledger <path> is required/],
  ['collect.mjs', [], /--ledger <path> is required/],
  ['provision.mjs', ['bogus'], /unknown verb: bogus/],
];

for (const [script, args, re] of cases) {
  test(`${script}: main() runs when invoked through a symlinked dir`, () => {
    const r = run(script, args);
    assert.match(r.stderr, re);
    assert.equal(r.status, 1);
  });
}

test.after(() => rmSync(scratch, { recursive: true, force: true }));
