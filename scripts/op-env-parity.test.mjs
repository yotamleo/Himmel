// Tests for op-env-parity. Hermetic: inline fixtures, no real .env, no secrets, no network.
// Run: node --test scripts/op-env-parity.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseEnvKeys, parseOpKeys, diffKeys, formatReport } from './op-env-parity.mjs';

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), 'op-env-parity.mjs');

/** Run the CLI in a subprocess. Hermetic: caller supplies temp file paths. */
function runCli(args, { input } = {}) {
  const res = spawnSync(process.execPath, [SCRIPT, ...args], { input, encoding: 'utf8' });
  return { code: res.status, stdout: res.stdout, stderr: res.stderr };
}

/** Make a throwaway temp dir with named files; returns { dir, path(name) } and auto-cleanup via t.after. */
function tmpFiles(t, files) {
  const dir = mkdtempSync(join(tmpdir(), 'op-env-parity-test-'));
  for (const [name, content] of Object.entries(files)) writeFileSync(join(dir, name), content);
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return { dir, path: (name) => join(dir, name) };
}

test('parseEnvKeys: basic one-per-line assignments', () => {
  const keys = parseEnvKeys('JIRA_EMAIL=a@b.com\nJIRA_API_TOKEN=xyz\n');
  assert.deepEqual(keys, ['JIRA_API_TOKEN', 'JIRA_EMAIL']); // sorted
});

test('parseEnvKeys: TWO assignments on one physical line (the reported bug)', () => {
  // HIMMEL_WHERE_ARE_WE=1 USER_SLUG=exampleuser on a single line must yield BOTH keys.
  const keys = parseEnvKeys('HIMMEL_WHERE_ARE_WE=1 USER_SLUG=exampleuser\n');
  assert.deepEqual(keys, ['HIMMEL_WHERE_ARE_WE', 'USER_SLUG']);
});

test('parseEnvKeys: three assignments on one line', () => {
  const keys = parseEnvKeys('A=1 B=2 C=3');
  assert.deepEqual(keys, ['A', 'B', 'C']);
});

test('parseEnvKeys: skips blank lines and comments', () => {
  const keys = parseEnvKeys('\n# a comment\n   # indented comment\nFOO=bar\n');
  assert.deepEqual(keys, ['FOO']);
});

test('parseEnvKeys: handles a leading export', () => {
  const keys = parseEnvKeys('export FOO=bar\nexport BAZ=qux QUX=1');
  assert.deepEqual(keys, ['BAZ', 'FOO', 'QUX']);
});

test('parseEnvKeys: quoted value with spaces stays one token; trailing assignment still captured', () => {
  const keys = parseEnvKeys('MSG="hello world" NEXT=2');
  assert.deepEqual(keys, ['MSG', 'NEXT']);
});

test('parseEnvKeys: de-duplicates repeated key names', () => {
  const keys = parseEnvKeys('FOO=1\nFOO=2');
  assert.deepEqual(keys, ['FOO']);
});

test('parseEnvKeys: never leaks a value into the output', () => {
  const keys = parseEnvKeys('SECRET_TOKEN=sk-supersecret-abc123 OTHER=plainvalue');
  assert.deepEqual(keys, ['OTHER', 'SECRET_TOKEN']);
  for (const k of keys) {
    assert.ok(!k.includes('supersecret'), 'value substring leaked into a key');
    assert.ok(!k.includes('plainvalue'), 'value substring leaked into a key');
  }
});

test('parseOpKeys: JSON array form', () => {
  assert.deepEqual(parseOpKeys('["B","A","A"]'), ['A', 'B']); // sorted + deduped
});

test('parseOpKeys: newline-separated form', () => {
  assert.deepEqual(parseOpKeys('B\nA\n\n  C  \n'), ['A', 'B', 'C']);
});

test('parseOpKeys: rejects an invalid variable name', () => {
  assert.throws(() => parseOpKeys('["OK","not a name"]'), /invalid variable name/);
});

test('diffKeys: reports each side of the drift', () => {
  const diff = diffKeys(['A', 'B', 'PERPLEXITY_API_KEY'], ['A', 'B', 'USER_SLUG']);
  assert.deepEqual(diff.missingInOp, ['PERPLEXITY_API_KEY']); // in .env, absent from Environment
  assert.deepEqual(diff.missingInEnv, ['USER_SLUG']); // in Environment, absent from .env
});

test('diffKeys: identical sets produce no drift', () => {
  const diff = diffKeys(['A', 'B'], ['B', 'A']);
  assert.deepEqual(diff.missingInOp, []);
  assert.deepEqual(diff.missingInEnv, []);
});

test('formatReport: in-sync message', () => {
  const env = ['A', 'B'];
  const op = ['A', 'B'];
  const report = formatReport(env, op, diffKeys(env, op));
  assert.match(report, /OK — key sets are identical\./);
});

test('formatReport: drift lists both sides and the rename note', () => {
  const env = ['A', 'PERPLEXITY_API_KEY'];
  const op = ['A', 'USER_SLUG'];
  const report = formatReport(env, op, diffKeys(env, op));
  assert.match(report, /NOT in Environment/);
  assert.match(report, /- PERPLEXITY_API_KEY/);
  assert.match(report, /NOT in \.env/);
  assert.match(report, /\+ USER_SLUG/);
  assert.match(report, /renamed key appears as one/);
});

test('formatReport: one-sided drift omits the rename note', () => {
  const env = ['A', 'EXTRA'];
  const op = ['A'];
  const report = formatReport(env, op, diffKeys(env, op));
  assert.match(report, /NOT in Environment/);
  assert.doesNotMatch(report, /renamed key appears as one/);
});

// --- inline-comment handling (a `# ...` inline comment must not mint a phantom key) ---

test('parseEnvKeys: inline comment after an assignment is not a key', () => {
  assert.deepEqual(parseEnvKeys('FOO=bar # NOTE=x'), ['FOO']);
});

test('parseEnvKeys: a # with no leading space stays part of the value token', () => {
  assert.deepEqual(parseEnvKeys('FOO=bar#baz'), ['FOO']); // one token, name FOO
});

test('parseEnvKeys: a # inside a quoted value does not start a comment', () => {
  assert.deepEqual(parseEnvKeys('MSG="a # b" NEXT=2'), ['MSG', 'NEXT']);
});

test('parseEnvKeys: an unquoted spaced value word (no =) never becomes a key', () => {
  assert.deepEqual(parseEnvKeys('TOKEN=abc secretword'), ['TOKEN']);
});

// --- CLI layer: exit-code contract (0 in-sync/list, 1 drift, 2 usage/IO) and I/O paths ---

test('CLI: identical key sets exit 0', (t) => {
  const f = tmpFiles(t, { '.env': 'A=1\nB=2\n', 'op.json': '["A","B"]' });
  const r = runCli(['--env', f.path('.env'), '--op-keys', f.path('op.json')]);
  assert.equal(r.code, 0);
  assert.match(r.stdout, /identical/);
});

test('CLI: drift exits 1 and names the missing key', (t) => {
  const f = tmpFiles(t, { '.env': 'A=1\nB=2\n', 'op.json': '["A"]' });
  const r = runCli(['--env', f.path('.env'), '--op-keys', f.path('op.json')]);
  assert.equal(r.code, 1);
  assert.match(r.stdout, /NOT in Environment/);
  assert.match(r.stdout, /- B/);
});

test('CLI: unreadable env file exits 2', (t) => {
  const f = tmpFiles(t, { 'op.json': '["A"]' });
  const r = runCli(['--env', f.path('does-not-exist.env'), '--op-keys', f.path('op.json')]);
  assert.equal(r.code, 2);
  assert.match(r.stderr, /cannot read env file/);
});

test('CLI: unknown argument exits 2', (t) => {
  const f = tmpFiles(t, { '.env': 'A=1\n' });
  const r = runCli(['--env', f.path('.env'), '--bogus']);
  assert.equal(r.code, 2);
  assert.match(r.stderr, /unknown argument/);
});

test('CLI: missing --op-keys (compare mode) exits 2', (t) => {
  const f = tmpFiles(t, { '.env': 'A=1\n' });
  const r = runCli(['--env', f.path('.env')]);
  assert.equal(r.code, 2);
  assert.match(r.stderr, /missing --op-keys/);
});

test('CLI: --list-env-keys prints sorted names and exits 0', (t) => {
  const f = tmpFiles(t, { '.env': 'B_KEY=2\nA_KEY=1\n' });
  const r = runCli(['--list-env-keys', '--env', f.path('.env')]);
  assert.equal(r.code, 0);
  assert.equal(r.stdout, 'A_KEY\nB_KEY\n');
});

test('CLI: --op-keys from stdin (-) works and reports drift', (t) => {
  const f = tmpFiles(t, { '.env': 'A=1\nB=2\n' });
  const r = runCli(['--env', f.path('.env'), '--op-keys', '-'], { input: '["A"]' });
  assert.equal(r.code, 1);
  assert.match(r.stdout, /- B/);
});

test('CLI: malformed JSON op-keys exits 2', (t) => {
  const f = tmpFiles(t, { '.env': 'A=1\n', 'op.json': '["A"' }); // unterminated array
  const r = runCli(['--env', f.path('.env'), '--op-keys', f.path('op.json')]);
  assert.equal(r.code, 2);
  assert.match(r.stderr, /bad op-keys/);
});
