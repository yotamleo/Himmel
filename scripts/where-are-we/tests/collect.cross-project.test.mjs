// scripts/where-are-we/tests/collect.cross-project.test.mjs
// HIMMEL-573: where-are-we must track cross-project LUNA *harness* tickets (a
// LUNA-keyed ticket whose code ships in the himmel harness, e.g. the
// obsidian-triage plugin) the same way it tracks HIMMEL tickets — but NOT LUNA
// vault/content tickets (the second-brain wiki).
//
// The discriminator is the himmel footprint: a harness LUNA ticket carries an
// OPEN himmel PR (or a locked worktree); a content LUNA ticket carries neither.
// So we seed jira reads from open-PR branch keys and read every active key
// across ALL statuses (the HIMMEL-project status lists can't see LUNA at all).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { jiraQueries, collectAll } from '../collect.mjs';

const jqlOf = (queries) => {
  const q = queries.find((x) => x.includes('--jql'));
  return q ? q[q.indexOf('--jql') + 1] : null;
};

test('jiraQueries: active keys are re-read across ALL statuses, not just Done (cross-project harness status)', () => {
  const jql = jqlOf(jiraQueries(['HIMMEL-1', 'LUNA-87']));
  assert.ok(jql, 'active keys → a by-key query');
  assert.match(jql, /key in \(HIMMEL-1,LUNA-87\)/);
  assert.ok(!/status\s*=\s*Done/i.test(jql), 'no longer scoped to Done — any status surfaces');
});

test('collectAll: an open himmel PR on a LUNA branch seeds that key into the jira read', () => {
  let captured = null;
  const readers = {
    readJira: (keys) => { captured = keys; return []; },
    readPRs: () => [
      { number: 715, state: 'OPEN', headRefName: 'feat/luna-87-clip-lifecycle-phase2', title: 't' },
    ],
    readWorktrees: () => '',
  };
  collectAll('2026-02-01T00:00:00Z', readers, ['HIMMEL-1']);
  assert.ok(captured.includes('LUNA-87'), 'open LUNA PR branch key is read for its real status');
  assert.ok(captured.includes('HIMMEL-1'), 'ledger active keys are preserved');
});

test('collectAll: MERGED/CLOSED PR history is NOT re-queried (bounded — only open PRs seed keys)', () => {
  let captured = null;
  const readers = {
    readJira: (keys) => { captured = keys; return []; },
    readPRs: () => [
      { number: 700, state: 'MERGED', headRefName: 'feat/luna-50-old', title: 't' },
      { number: 690, state: 'CLOSED', headRefName: 'feat/luna-40-abandoned', title: 't' },
    ],
    readWorktrees: () => '',
  };
  collectAll('2026-02-01T00:00:00Z', readers, []);
  assert.ok(!captured.includes('LUNA-50'), 'merged PR history is not re-queried');
  assert.ok(!captured.includes('LUNA-40'), 'closed PR history is not re-queried');
  assert.deepEqual(captured, [], 'no open PRs and no ledger keys → no by-key read');
});

test('collectAll: a non-ticket / malformed PR branch does not leak into the jira read', () => {
  let captured = null;
  const readers = {
    readJira: (keys) => { captured = keys; return []; },
    readPRs: () => [
      { number: 720, state: 'OPEN', headRefName: 'chore/no-ticket-here', title: 't' },
    ],
    readWorktrees: () => '',
  };
  collectAll('2026-02-01T00:00:00Z', readers, []);
  assert.deepEqual(captured, [], 'a branch with no ticket key contributes nothing');
});
