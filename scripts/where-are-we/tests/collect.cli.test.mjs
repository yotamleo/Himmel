// scripts/where-are-we/tests/collect.cli.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readRecords } from '../lib/ledger.mjs';
import { jiraRecords, prRecords, gitRecords } from '../lib/collect.mjs';
import { collectAll, main } from '../collect.mjs';
import { UsageError } from '../lib/errors.mjs';

const NOW = '2026-01-01T00:00:00Z';

// Fixture data
const FIXTURE_JIRA_ROWS = [{ key: 'HIMMEL-1', status: 'In Progress' }];
const FIXTURE_PRS = [{ number: 7, state: 'OPEN', headRefName: 'feat/x' }];
const FIXTURE_PORCELAIN = `worktree /path/to/feat-himmel-9
HEAD abc123
branch refs/heads/feat/himmel-9-active
locked active work
`;

// Fixture readers that never touch the network or shell
const fixtureReaders = {
  readJira: () => FIXTURE_JIRA_ROWS,
  readPRs: () => FIXTURE_PRS,
  readWorktrees: () => FIXTURE_PORCELAIN,
};

// ---------------------------------------------------------------------------
// collectAll wiring
// ---------------------------------------------------------------------------

test('collectAll: wires each reader to its mapper with the same now', () => {
  const result = collectAll(NOW, fixtureReaders);

  // Expected: jira + pr + git, in that order
  const expected = [
    ...jiraRecords(FIXTURE_JIRA_ROWS, NOW),
    ...prRecords(FIXTURE_PRS, NOW),
    ...gitRecords(FIXTURE_PORCELAIN, NOW),
  ];

  assert.equal(result.length, expected.length);
  assert.deepEqual(result, expected);
});

test('collectAll: passes now through to each mapper', () => {
  const customNow = '2026-06-21T12:00:00Z';
  const result = collectAll(customNow, fixtureReaders);
  assert.ok(result.every((r) => r.ts === customNow), 'every record should carry the same now');
});

test('collectAll: order is jira → pr → git', () => {
  const result = collectAll(NOW, fixtureReaders);
  // First record comes from jira reader
  assert.equal(result[0].source, 'jira');
  assert.equal(result[0].key, 'HIMMEL-1');
  // Second record comes from pr reader
  assert.equal(result[1].source, 'pr');
  assert.equal(result[1].key, '#7');
  // Third record comes from git reader (locked worktree)
  assert.equal(result[2].source, 'git');
  assert.equal(result[2].key, 'HIMMEL-9');
});

test('collectAll: returns empty array when all readers return empty', () => {
  const emptyReaders = {
    readJira: () => [],
    readPRs: () => [],
    readWorktrees: () => '',
  };
  const result = collectAll(NOW, emptyReaders);
  assert.deepEqual(result, []);
});

test('collectAll: partial data — only jira returns records', () => {
  const readers = {
    readJira: () => FIXTURE_JIRA_ROWS,
    readPRs: () => [],
    readWorktrees: () => '',
  };
  const result = collectAll(NOW, readers);
  assert.equal(result.length, 1);
  assert.equal(result[0].source, 'jira');
});

// ---------------------------------------------------------------------------
// main wiring + append
// ---------------------------------------------------------------------------

test('main: writes records to ledger and returns summary string', () => {
  const dir = mkdtempSync(join(tmpdir(), 'waw-collect-cli-'));
  const ledger = join(dir, 'ledger.jsonl');

  const summary = main(['--ledger', ledger, '--now', NOW], { readers: fixtureReaders });

  // The ledger should hold exactly the records collectAll produces
  const expectedCount = collectAll(NOW, fixtureReaders).length;
  const stored = readRecords(ledger);
  assert.equal(stored.length, expectedCount, 'ledger should hold all collected records');

  // Summary string should contain appended=N dropped=0
  assert.match(summary, /appended=\d+/);
  assert.match(summary, /dropped=0/);
  const match = summary.match(/appended=(\d+)/);
  assert.equal(Number(match[1]), expectedCount, 'appended count must match fixture count');
});

test('main: returned summary reports M=0 for clean fixtures (no invalid records)', () => {
  const dir = mkdtempSync(join(tmpdir(), 'waw-collect-cli-'));
  const ledger = join(dir, 'ledger.jsonl');
  const summary = main(['--ledger', ledger, '--now', NOW], { readers: fixtureReaders });
  assert.match(summary, /dropped=0/);
});

test('main: throws clear error when --ledger is missing', () => {
  assert.throws(
    () => main(['--now', NOW], { readers: fixtureReaders }),
    /--ledger.*required/i,
  );
});

// HIMMEL-530 Task 3: collect-path error hygiene mirrors the index path
test('main([]) throws a UsageError for the missing-ledger case', () => {
  let thrown = null;
  try { main(['--now', NOW], { readers: fixtureReaders }); } catch (e) { thrown = e; }
  assert.ok(thrown instanceof UsageError, 'missing --ledger must throw UsageError');
  assert.match(thrown.message, /--ledger.*required/i);
});

test('main throws a non-UsageError on a runtime fault (ledger path is a directory)', () => {
  const dir = mkdtempSync(join(tmpdir(), 'waw-collect-cli-')); // a directory, not a file
  let thrown = null;
  try { main(['--ledger', dir, '--now', NOW], { readers: fixtureReaders }); } catch (e) { thrown = e; }
  assert.ok(thrown !== null, 'appending to a directory path must throw');
  assert.ok(!(thrown instanceof UsageError), 'a runtime fault must NOT be a UsageError');
});

test('main: works with only --ledger (no --now, uses default)', () => {
  const dir = mkdtempSync(join(tmpdir(), 'waw-collect-cli-'));
  const ledger = join(dir, 'ledger.jsonl');
  // Should not throw; now defaults to new Date().toISOString()
  const summary = main(['--ledger', ledger], { readers: fixtureReaders });
  assert.match(summary, /appended=\d+/);
});

test('main: dropped > 0 branch — invalid record is counted and absent from ledger', () => {
  // jiraRecords maps row.key directly to record.key.
  // validateRecord rejects key==='' (REQUIRED check: obj[f] === '').
  // So {key:'', status:'In Progress'} produces a dropped record, exercising the
  // `if (r.dropped > 0) console.error(...)` branch in main.
  const dir = mkdtempSync(join(tmpdir(), 'waw-collect-cli-'));
  const ledger = join(dir, 'ledger.jsonl');

  const summary = main(
    ['--ledger', ledger, '--now', NOW],
    {
      readers: {
        readJira: () => [
          { key: '', status: 'In Progress' },      // invalid — empty key → dropped
          { key: 'HIMMEL-1', status: 'Done' },     // valid
        ],
        readPRs: () => [],
        readWorktrees: () => '',
      },
    },
  );

  // Summary must report exactly 1 dropped record
  assert.match(summary, /dropped=1/, 'summary should report dropped=1');
  assert.match(summary, /appended=1/, 'summary should report appended=1');

  // The ledger should contain only the valid record (HIMMEL-1), not the empty-key one
  const stored = readRecords(ledger);
  assert.equal(stored.length, 1, 'ledger should hold exactly 1 valid record');
  assert.equal(stored[0].key, 'HIMMEL-1', 'only the valid record should be in the ledger');
  assert.ok(!stored.some((r) => r.key === ''), 'empty-key record must not appear in ledger');
});

test('main: records in ledger have correct structure', () => {
  const dir = mkdtempSync(join(tmpdir(), 'waw-collect-cli-'));
  const ledger = join(dir, 'ledger.jsonl');
  main(['--ledger', ledger, '--now', NOW], { readers: fixtureReaders });
  const stored = readRecords(ledger);
  for (const r of stored) {
    assert.ok(r.ts, 'record should have ts');
    assert.ok(r.source, 'record should have source');
    assert.ok(r.key, 'record should have key');
    assert.ok(r.kind, 'record should have kind');
  }
});
