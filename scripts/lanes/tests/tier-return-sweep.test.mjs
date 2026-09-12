import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
const sweep = (since) => execFileSync('node', ['scripts/lanes/tier-return-sweep.mjs', '--since', since, '--projects-dir', 'scripts/lanes/tests/fixtures/tier-return'], { encoding: 'utf8' });
test('sweep counts Tier-return lines per dispatched model', () => {
  assert.match(sweep('2026-09-01T00:00:00Z'), /^sonnet 4\/7$/m);
});
test('--since excludes older transcripts from numerator and denominator', () => {
  assert.match(sweep('2026-09-30T00:00:00Z'), /^sonnet 2\/5$/m);
});
