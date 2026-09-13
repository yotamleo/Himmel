// scripts/lib/test-tmpdir.test.mjs — HIMMEL-2864 finding 3: makeTmpDir()
// used to register a new process.on('exit') listener per call; suites
// calling it 10+ times in one process trip Node's MaxListenersExceededWarning.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makeTmpDir } from './test-tmpdir.mjs';

test('makeTmpDir() registers at most one shared exit listener across many calls', () => {
  const before = process.listenerCount('exit');
  for (let i = 0; i < 15; i++) makeTmpDir('himmel-test-tmpdir-listener-leak-');
  const after = process.listenerCount('exit');
  assert.ok(after - before <= 1, `exit listener count grew by ${after - before}, expected <= 1`);
});
