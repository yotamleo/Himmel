// scripts/lanes/tests/bench-verify-common.test.mjs — HIMMEL-1723 P2.1
// verify-common.sh is bash, sourced by every fixture's verify.sh. It is
// exercised here by writing a tiny driver script that sources it and calls
// one function, then checking the driver's exit code / stderr — the same
// shape used to test any other shell helper in this repo that has no direct
// node binding.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { BASH_BIN } from './lib/resolve-bash.mjs';

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const LIB = join(TEST_DIR, '..', 'bench', 'lib', 'verify-common.sh');

function runBash(script, cwd) {
  try {
    const stdout = execFileSync(BASH_BIN, ['-c', script], { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    return { rc: 0, stdout, stderr: '' };
  } catch (e) {
    return { rc: e.status ?? 1, stdout: e.stdout?.toString() ?? '', stderr: e.stderr?.toString() ?? '' };
  }
}

function makeFixture() {
  const dir = mkdtempSync(join(tmpdir(), 'bench-verify-common-'));
  const original = join(dir, 'original');
  const working = join(dir, 'working');
  mkdirSync(original, { recursive: true });
  mkdirSync(join(original, 'sub'), { recursive: true });
  mkdirSync(working, { recursive: true });
  mkdirSync(join(working, 'sub'), { recursive: true });
  writeFileSync(join(original, 'a.txt'), 'A\n');
  writeFileSync(join(original, 'sub', 'b.txt'), 'B\n');
  writeFileSync(join(working, 'a.txt'), 'A\n');
  writeFileSync(join(working, 'sub', 'b.txt'), 'B\n');
  const manifest = join(dir, 'manifest.txt');
  writeFileSync(manifest, 'a.txt\n');
  return { dir, original, working, manifest };
}

test('assert_only_paths_changed PASSES when only a sanctioned file changed', () => {
  const { original, working, manifest } = makeFixture();
  writeFileSync(join(working, 'a.txt'), 'A-edited\n'); // a.txt IS in the manifest
  const script = `. "${LIB.replace(/\\/g, '/')}" && assert_only_paths_changed "${original.replace(/\\/g, '/')}" "${manifest.replace(/\\/g, '/')}"`;
  const result = runBash(script, working);
  assert.equal(result.rc, 0, result.stderr);
});

test('assert_only_paths_changed FAILS when an out-of-scope file changed', () => {
  const { original, working, manifest } = makeFixture();
  writeFileSync(join(working, 'a.txt'), 'A-edited\n');       // sanctioned
  writeFileSync(join(working, 'sub', 'b.txt'), 'B-edited\n'); // NOT sanctioned
  const script = `. "${LIB.replace(/\\/g, '/')}" && assert_only_paths_changed "${original.replace(/\\/g, '/')}" "${manifest.replace(/\\/g, '/')}"`;
  const result = runBash(script, working);
  assert.notEqual(result.rc, 0);
  assert.match(result.stderr, /OUT-OF-SCOPE change: sub\/b\.txt/);
});

test('assert_only_paths_changed FAILS on an unsanctioned ADDED file', () => {
  const { original, working, manifest } = makeFixture();
  writeFileSync(join(working, 'new-file.txt'), 'unexpected\n');
  const script = `. "${LIB.replace(/\\/g, '/')}" && assert_only_paths_changed "${original.replace(/\\/g, '/')}" "${manifest.replace(/\\/g, '/')}"`;
  const result = runBash(script, working);
  assert.notEqual(result.rc, 0);
  assert.match(result.stderr, /OUT-OF-SCOPE change: new-file\.txt/);
});

test('assert_only_paths_changed PASSES on a no-op (identical trees)', () => {
  const { original, working, manifest } = makeFixture();
  const script = `. "${LIB.replace(/\\/g, '/')}" && assert_only_paths_changed "${original.replace(/\\/g, '/')}" "${manifest.replace(/\\/g, '/')}"`;
  const result = runBash(script, working);
  assert.equal(result.rc, 0, result.stderr);
});

test('assert_no_hits passes with zero matches and fails when the pattern is found', () => {
  const dir = mkdtempSync(join(tmpdir(), 'bench-verify-common-nohits-'));
  writeFileSync(join(dir, 'clean.txt'), 'nothing interesting here\n');
  const script = `. "${LIB.replace(/\\/g, '/')}" && assert_no_hits "forbidden-pattern" .`;
  const ok = runBash(script, dir);
  assert.equal(ok.rc, 0, ok.stderr);

  writeFileSync(join(dir, 'dirty.txt'), 'this has a forbidden-pattern in it\n');
  const bad = runBash(script, dir);
  assert.notEqual(bad.rc, 0);
});

test('assert_bytes_equal passes on identical files and fails on a mismatch', () => {
  const dir = mkdtempSync(join(tmpdir(), 'bench-verify-common-bytes-'));
  writeFileSync(join(dir, 'x.bin'), 'same-bytes');
  writeFileSync(join(dir, 'y.bin'), 'same-bytes');
  writeFileSync(join(dir, 'z.bin'), 'different-bytes');
  const okScript = `. "${LIB.replace(/\\/g, '/')}" && assert_bytes_equal x.bin y.bin`;
  assert.equal(runBash(okScript, dir).rc, 0);
  const badScript = `. "${LIB.replace(/\\/g, '/')}" && assert_bytes_equal x.bin z.bin`;
  assert.notEqual(runBash(badScript, dir).rc, 0);
});

test('assert_json_parses passes on valid JSON and fails on invalid JSON', () => {
  const dir = mkdtempSync(join(tmpdir(), 'bench-verify-common-json-'));
  writeFileSync(join(dir, 'good.json'), '{"a":1}');
  writeFileSync(join(dir, 'bad.json'), '{not json');
  const okScript = `. "${LIB.replace(/\\/g, '/')}" && assert_json_parses good.json`;
  assert.equal(runBash(okScript, dir).rc, 0);
  const badScript = `. "${LIB.replace(/\\/g, '/')}" && assert_json_parses bad.json`;
  assert.notEqual(runBash(badScript, dir).rc, 0);
});
