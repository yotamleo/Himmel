import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';

// HIMMEL-3269: the Tier-return counter is retired. Nothing instructs a child to
// emit the marker (leg-preface.md is read by headed top-level legs; the sweep
// only counts subagent transcripts), so `sonnet 0/N` was the arithmetic of an
// unemitted marker, not evidence of no escalation. The script now refuses
// rather than print a count that cannot fail.
const run = (args) => spawnSync('node', ['scripts/lanes/tier-return-sweep.mjs', ...args], { encoding: 'utf8' });

// a real escalation: a Sonnet child returned the work as above its tier and the
// parent re-dispatched at Opus - no marker anywhere in the corpus
const NOMARKER = ['--since', '2026-09-01T00:00:00Z', '--projects-dir', 'scripts/lanes/tests/fixtures/tier-return-nomarker'];

test('a corpus with a real escalation but no marker does not read as "0 escalations"', () => {
  const r = run(NOMARKER);
  assert.notEqual(r.status, 0);
  assert.doesNotMatch(r.stdout, /^\w+ \d+\/\d+$/m);
});

test('the refusal says the counter is retired and where the replacement lives', () => {
  const r = run(NOMARKER);
  assert.match(r.stderr, /retired/i);
  assert.match(r.stderr, /HIMMEL-2976/);
});

test('a corpus WITH markers gets the same refusal, never a count', () => {
  const r = run(['--since', '2026-09-01T00:00:00Z', '--projects-dir', 'scripts/lanes/tests/fixtures/tier-return']);
  assert.notEqual(r.status, 0);
  assert.equal(r.stdout, '');
});

test('no arguments at all is refused too', () => {
  const r = run([]);
  assert.notEqual(r.status, 0);
  assert.equal(r.stdout, '');
});
