// scripts/where-are-we/tests/collect.jira-limit.test.mjs
// HIMMEL-567: the collector queried `jira list --status 'To Do,In Progress,Done'`
// with no --limit. The CLI defaults to --limit 25, and with Done in the filter
// (hundreds of historical tickets) the 25-row page filled with To-Do rows — live
// In-Progress tickets never entered the ledger ("In flight: none" while work was
// in progress). These tests pin the fix: per-status queries with an explicit high
// limit, plus a Done read scoped to the active in-flight keys (for self-clear).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { jiraQueries, main } from '../collect.mjs';

const statusOf = (q) => q[q.indexOf('--status') + 1];
const isStatusQuery = (q) => q.includes('--status');
const isKeyQuery = (q) => q.some((a) => typeof a === 'string' && a.startsWith('key in ('));

test('jiraQueries: pulls In Progress and To Do as separate queries (no combined comma filter)', () => {
  const statuses = jiraQueries([]).filter(isStatusQuery).map(statusOf);
  assert.ok(statuses.includes('In Progress'), 'must query In Progress on its own');
  assert.ok(statuses.includes('To Do'), 'must query To Do on its own');
  assert.ok(!statuses.some((s) => s.includes(',')), 'must NOT use a combined comma status filter (the truncation source)');
});

test('jiraQueries: every status query carries an explicit --limit above the CLI default of 25', () => {
  for (const q of jiraQueries([]).filter(isStatusQuery)) {
    const li = q.indexOf('--limit');
    assert.ok(li !== -1, 'each status query must pass --limit');
    assert.ok(Number(q[li + 1]) > 25, 'limit must exceed the CLI default of 25');
  }
});

test('jiraQueries: no by-key query when nothing is in flight', () => {
  assert.ok(!jiraQueries([]).some(isKeyQuery), 'empty active set → no by-key query');
});

test('jiraQueries: the by-key status read is scoped to the active in-flight keys only', () => {
  const byKey = jiraQueries(['HIMMEL-1', 'HIMMEL-2']).find(isKeyQuery);
  assert.ok(byKey, 'active keys → a by-key query');
  const jql = byKey[byKey.indexOf('--jql') + 1];
  assert.match(jql, /^key in \(HIMMEL-1,HIMMEL-2\)$/, 'all statuses — not scoped to Done');
});

test('jiraQueries: sanitizes keys so a malformed entry cannot inject JQL', () => {
  const byKey = jiraQueries(['HIMMEL-1', 'HIMMEL-1) OR status != Done --', 'evil']).find(isKeyQuery);
  const jql = byKey[byKey.indexOf('--jql') + 1];
  assert.match(jql, /^key in \(HIMMEL-1\)$/, 'only well-formed ticket keys survive');
});

test('main: derives active in-flight ticket keys from the ledger and scopes the by-key read to them', () => {
  const dir = mkdtempSync(join(tmpdir(), 'waw-jira-limit-'));
  const ledger = join(dir, 'ledger.jsonl');
  writeFileSync(ledger, [
    JSON.stringify({ ts: '2026-01-01T00:00:00Z', source: 'jira', key: 'HIMMEL-1', kind: 'ticket', status: 'in-progress' }),
    JSON.stringify({ ts: '2026-01-01T00:00:00Z', source: 'jira', key: 'HIMMEL-2', kind: 'ticket', status: 'done' }),
    JSON.stringify({ ts: '2026-01-01T00:00:00Z', source: 'pr', key: '#7', kind: 'pr', status: 'open', branch: 'feat/x' }),
  ].join('\n') + '\n');

  let captured = null;
  const readers = {
    readJira: (activeKeys) => { captured = activeKeys; return []; },
    readPRs: () => [],
    readWorktrees: () => '',
  };
  main(['--ledger', ledger, '--now', '2026-02-01T00:00:00Z'], { readers });
  assert.deepEqual(captured, ['HIMMEL-1'], 'only the non-terminal ticket key is passed for the by-key status read');
});
