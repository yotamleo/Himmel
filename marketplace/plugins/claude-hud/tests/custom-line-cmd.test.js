import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import { runCustomLineCommand, shouldRunCustomLine } from '../dist/custom-line-cmd.js';

function nodeCommand(script) {
  return `node -e ${JSON.stringify(script)}`;
}

test('runCustomLineCommand pipes stdin JSON to the command', async () => {
  const stdinJson = '{"session_id":"abc123","cwd":"C:/tmp"}';
  const cmd = nodeCommand(
    'let data=""; process.stdin.on("data", chunk => data += chunk); process.stdin.on("end", () => process.stdout.write(data));',
  );

  const result = await runCustomLineCommand(cmd, stdinJson);

  assert.ok(result);
  assert.ok(result.join('\n').includes(stdinJson));
});

test('runCustomLineCommand runs in the session cwd', async () => {
  const cwd = fs.realpathSync(os.tmpdir());
  const cmd = nodeCommand('process.stdout.write(process.cwd());');

  const result = await runCustomLineCommand(cmd, '{}', { cwd });

  assert.ok(result);
  assert.equal(fs.realpathSync(result[0]).toLowerCase(), cwd.toLowerCase());
});

test('runCustomLineCommand returns null on timeout without hanging', async () => {
  const cmd = nodeCommand('setTimeout(() => {}, 10000);');
  const start = Date.now();

  const result = await runCustomLineCommand(cmd, '{}', { timeout: 300 });
  const elapsed = Date.now() - start;

  assert.equal(result, null);
  assert.ok(elapsed < 2000, `Expected timeout around 300ms, but took ${elapsed}ms`);
});

test('runCustomLineCommand returns multiline stdout as separate lines', async () => {
  // Build the newline via String.fromCharCode(10) so no backslash survives the
  // JSON.stringify + cmd.exe round-trip on Windows (a literal "\\n" gets mangled
  // to a backslash-n pair there — see the Windows shell-quoting note above).
  const cmd = nodeCommand('process.stdout.write(["a", "b", "c"].join(String.fromCharCode(10)));');

  const result = await runCustomLineCommand(cmd, '{}');

  assert.deepEqual(result, ['a', 'b', 'c']);
});

test('runCustomLineCommand preserves multi-byte UTF-8 output', async () => {
  // Guards the stdout.setEncoding('utf8') decode: raw-Buffer chunk
  // accumulation would garble multi-byte characters. Build the string from
  // code points so no non-ASCII bytes travel through the shell command line.
  const script =
    'process.stdout.write(String.fromCodePoint(99,97,102,233,127881));'; // "café" + 🎉
  const result = await runCustomLineCommand(nodeCommand(script), '{}');

  assert.deepEqual(result, ['café\u{1F389}']);
});

test('shouldRunCustomLine requires both command and ACE gate', () => {
  assert.equal(shouldRunCustomLine('node -e "process.stdout.write(\\"x\\")"', {}), false);
  assert.equal(shouldRunCustomLine('node -e "process.stdout.write(\\"x\\")"', {
    CLAUDE_HUD_ALLOW_EXTRA_CMD: '1',
  }), true);
  assert.equal(shouldRunCustomLine('', { CLAUDE_HUD_ALLOW_EXTRA_CMD: '1' }), false);
});
