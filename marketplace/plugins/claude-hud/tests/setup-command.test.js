import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('setup commands silence /dev/tty failures before opening the device', async () => {
  const setup = await readFile(new URL('../commands/setup.md', import.meta.url), 'utf8');

  assert.doesNotMatch(setup, /stty size <\/dev\/tty 2>\/dev\/null/);
  assert.equal(setup.match(/stty size 2>\/dev\/null <\/dev\/tty/g)?.length, 3);
});
