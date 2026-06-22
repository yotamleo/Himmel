// scripts/where-are-we/tests/collect.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeJiraStatus, jiraRecords, prRecords, gitRecords } from '../lib/collect.mjs';
import { fold, inFlight } from '../lib/fold.mjs';
import { render } from '../lib/render.mjs';

const NOW = '2026-01-01T00:00:00Z';

// ---------------------------------------------------------------------------
// normalizeJiraStatus
// ---------------------------------------------------------------------------

test('normalizeJiraStatus: To Do → to-do', () => {
  assert.equal(normalizeJiraStatus('To Do'), 'to-do');
});

test('normalizeJiraStatus: In Progress → in-progress', () => {
  assert.equal(normalizeJiraStatus('In Progress'), 'in-progress');
});

test('normalizeJiraStatus: Done → done', () => {
  assert.equal(normalizeJiraStatus('Done'), 'done');
});

test('normalizeJiraStatus: unknown state → lowercase-hyphenated fallback', () => {
  assert.equal(normalizeJiraStatus('Some New State'), 'some-new-state');
});

// ---------------------------------------------------------------------------
// jiraRecords
// ---------------------------------------------------------------------------

test('jiraRecords: maps rows to ticket records with normalized status', () => {
  const rows = [
    { key: 'HIMMEL-1', status: 'In Progress' },
    { key: 'HIMMEL-2', status: 'Done' },
  ];
  const recs = jiraRecords(rows, NOW);
  assert.equal(recs.length, 2);
  assert.deepEqual(recs[0], {
    ts: NOW,
    source: 'jira',
    key: 'HIMMEL-1',
    kind: 'ticket',
    status: 'in-progress',
  });
  assert.deepEqual(recs[1], {
    ts: NOW,
    source: 'jira',
    key: 'HIMMEL-2',
    kind: 'ticket',
    status: 'done',
  });
});

test('jiraRecords: ignores extra fields (type, title)', () => {
  const rows = [{ key: 'HIMMEL-3', status: 'To Do', type: 'Story', title: 'Foo' }];
  const recs = jiraRecords(rows, NOW);
  assert.equal(recs.length, 1);
  assert.ok(!Object.prototype.hasOwnProperty.call(recs[0], 'type'));
  assert.ok(!Object.prototype.hasOwnProperty.call(recs[0], 'title'));
});

test('jiraRecords: empty input returns empty array', () => {
  assert.deepEqual(jiraRecords([], NOW), []);
});

// ---------------------------------------------------------------------------
// prRecords
// ---------------------------------------------------------------------------

test('prRecords: maps prs to pr records with lowercased status and branch', () => {
  const prs = [
    { number: 7, state: 'OPEN', headRefName: 'feat/x' },
    { number: 8, state: 'MERGED', headRefName: 'fix/y' },
  ];
  const recs = prRecords(prs, NOW);
  assert.equal(recs.length, 2);
  assert.deepEqual(recs[0], {
    ts: NOW,
    source: 'pr',
    key: '#7',
    kind: 'pr',
    status: 'open',
    branch: 'feat/x',
  });
  assert.deepEqual(recs[1], {
    ts: NOW,
    source: 'pr',
    key: '#8',
    kind: 'pr',
    status: 'merged',
    branch: 'fix/y',
  });
});

test('prRecords: ignores extra fields (title)', () => {
  const prs = [{ number: 9, state: 'CLOSED', headRefName: 'fix/z', title: 'ignore me' }];
  const recs = prRecords(prs, NOW);
  assert.equal(recs.length, 1);
  assert.ok(!Object.prototype.hasOwnProperty.call(recs[0], 'title'));
});

test('prRecords: empty input returns empty array', () => {
  assert.deepEqual(prRecords([], NOW), []);
});

// ---------------------------------------------------------------------------
// gitRecords
// ---------------------------------------------------------------------------

// Fixture: one locked feat/HIMMEL block with reason, one locked bare-locked block,
// one unlocked block, one locked main block.
const GIT_PORCELAIN = `worktree /path/to/feat-himmel-9
HEAD abc123
branch refs/heads/feat/himmel-9-x
locked busy reason

worktree /path/to/bare-locked
HEAD def456
branch refs/heads/fix/himmel-42-bare
locked

worktree /path/to/unlocked
HEAD ghi789
branch refs/heads/chore/himmel-10-clean

worktree /path/to/main
HEAD jkl012
branch refs/heads/main
locked main is special
`;

test('gitRecords: locked block with reason emits ticket record with lock reason', () => {
  const recs = gitRecords(GIT_PORCELAIN, NOW);
  const r = recs.find((r) => r.key === 'HIMMEL-9');
  assert.ok(r, 'expected a record for HIMMEL-9');
  assert.equal(r.ts, NOW);
  assert.equal(r.source, 'git');
  assert.equal(r.kind, 'ticket');
  assert.equal(r.lock, 'busy reason');
});

test('gitRecords: bare locked line emits lock with fallback text', () => {
  const recs = gitRecords(GIT_PORCELAIN, NOW);
  const r = recs.find((r) => r.key === 'HIMMEL-42');
  assert.ok(r, 'expected a record for HIMMEL-42');
  assert.equal(r.lock, 'worktree locked');
});

test('gitRecords: unlocked block emits nothing', () => {
  const recs = gitRecords(GIT_PORCELAIN, NOW);
  assert.ok(!recs.some((r) => r.key === 'HIMMEL-10'), 'HIMMEL-10 should not appear (unlocked)');
});

test('gitRecords: locked main branch emits nothing (no key)', () => {
  const recs = gitRecords(GIT_PORCELAIN, NOW);
  // main does not yield a key from branchToKey, so should not appear
  assert.ok(!recs.some((r) => r.key === null || r.key === undefined));
  // There should be exactly 2 records (HIMMEL-9, HIMMEL-42) — not 3 or 4
  assert.equal(recs.length, 2);
});

test('gitRecords: empty/no-blocks input returns empty array', () => {
  assert.deepEqual(gitRecords('', NOW), []);
});

test('gitRecords: detached HEAD block (no branch line) emits nothing', () => {
  const detached = `worktree /path/to/detached
HEAD abc123
detached
locked some reason
`;
  const recs = gitRecords(detached, NOW);
  assert.equal(recs.length, 0);
});

// ---------------------------------------------------------------------------
// Authority cross-check: silent-drop guard
// ---------------------------------------------------------------------------

test('authority: jira ticket status survives fold', () => {
  const recs = jiraRecords([{ key: 'HIMMEL-1', status: 'In Progress' }], NOW);
  const state = fold(recs);
  assert.equal(state.items['HIMMEL-1'].status, 'in-progress');
});

test('authority: pr status and branch survive fold', () => {
  const recs = prRecords([{ number: 7, state: 'OPEN', headRefName: 'feat/x' }], NOW);
  const state = fold(recs);
  assert.equal(state.items['#7'].status, 'open');
  assert.equal(state.items['#7'].branch, 'feat/x');
});

test('authority: git lock on ticket survives fold and appears in state.locks', () => {
  const singleBlock = `worktree /path/to/feat-himmel-9
HEAD abc123
branch refs/heads/feat/himmel-9-x
locked busy reason
`;
  const recs = gitRecords(singleBlock, NOW);
  const state = fold(recs);
  const lockEntry = state.locks.find((l) => l.key === 'HIMMEL-9');
  assert.ok(lockEntry, 'expected HIMMEL-9 in state.locks');
  assert.equal(lockEntry.lock, 'busy reason');
});

// ---------------------------------------------------------------------------
// Render cross-check
// ---------------------------------------------------------------------------

test('render: locked-only ticket appears in ## Locks but NOT in ## In flight or ## Blocked', () => {
  const singleBlock = `worktree /path/to/feat-himmel-9
HEAD abc123
branch refs/heads/feat/himmel-9-x
locked busy reason
`;
  const recs = gitRecords(singleBlock, NOW);
  const state = fold(recs);
  const out = render(state);

  // Must appear under Locks section
  assert.ok(out.includes('## Locks'), 'output should have ## Locks section');
  const locksSection = out.split('## Locks')[1] || '';
  assert.ok(locksSection.includes('HIMMEL-9'), 'HIMMEL-9 should appear under ## Locks');

  // Must NOT appear under In flight (requires status=in-progress)
  const inFlightSection = (out.split('## In flight')[1] || '').split('##')[0];
  assert.ok(!inFlightSection.includes('HIMMEL-9'), 'HIMMEL-9 should not appear under ## In flight');

  // Must NOT appear under Blocked (requires status=blocked)
  const blockedSection = (out.split('## Blocked')[1] || '').split('##')[0];
  assert.ok(!blockedSection.includes('HIMMEL-9'), 'HIMMEL-9 should not appear under ## Blocked');
});

test('inFlight: Done ticket is excluded', () => {
  const recs = jiraRecords([{ key: 'HIMMEL-2', status: 'Done' }], NOW);
  const state = fold(recs);
  const flight = inFlight(state);
  assert.ok(!flight.some((it) => it.key === 'HIMMEL-2'), 'HIMMEL-2 (done) should not be in-flight');
});
