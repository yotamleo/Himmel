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
test('non-subagent transcripts (consoles/legs) are excluded from the sweep', () => {
  assert.doesNotMatch(sweep('2026-09-01T00:00:00Z'), /^opus /m);
});
test('an invalid --since is rejected rather than silently disabling the cutoff', () => {
  assert.throws(() => sweep('not-a-date'));
});
test('a Tier-return marker quoted earlier in the message does not count as a return', () => {
  const out = execFileSync('node', ['scripts/lanes/tier-return-sweep.mjs', '--since', '2026-09-01T00:00:00Z', '--projects-dir', 'scripts/lanes/tests/fixtures/tier-return-anchor'], { encoding: 'utf8' });
  assert.match(out, /^sonnet 0\/1$/m);
});
test('with no --projects-dir, falls back to $CLAUDE_CONFIG_DIR/projects rather than always $HOME/.claude/projects', () => {
  const out = execFileSync('node', ['scripts/lanes/tier-return-sweep.mjs', '--since', '2026-09-01T00:00:00Z'], {
    encoding: 'utf8',
    env: { ...process.env, CLAUDE_CONFIG_DIR: 'scripts/lanes/tests/fixtures/tier-return-configdir', HOME: '/nonexistent-home-for-test' },
  });
  assert.match(out, /^sonnet 4\/7$/m);
});
test('an unknown flag is rejected rather than silently ignored (HIMMEL-2977 /pr-check codex-7)', () => {
  assert.throws(() => execFileSync('node', ['scripts/lanes/tier-return-sweep.mjs', '--since', '2026-09-01T00:00:00Z', '--bogus-flag'], { encoding: 'utf8' }));
});
test('--projects-dir with no following value is rejected rather than falling back to the real transcript root (HIMMEL-2977 /pr-check codex-7)', () => {
  assert.throws(() => execFileSync('node', ['scripts/lanes/tier-return-sweep.mjs', '--since', '2026-09-01T00:00:00Z', '--projects-dir'], { encoding: 'utf8' }));
});
