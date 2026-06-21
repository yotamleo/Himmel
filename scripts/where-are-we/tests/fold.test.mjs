// scripts/where-are-we/tests/fold.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fold, inFlight } from '../lib/fold.mjs';

const R = (o) => ({ ts: o.ts, source: o.source, key: o.key, kind: o.kind, ...o });

test('newest authoritative wins; omitted is a no-op', () => {
  const recs = [
    R({ ts: '1', source: 'handover', key: 'HIMMEL-1', kind: 'ticket', next_action: 'do X' }),
    R({ ts: '2', source: 'jira', key: 'HIMMEL-1', kind: 'ticket', status: 'in-progress' }),
  ];
  const s = fold(recs);
  assert.equal(s.items['HIMMEL-1'].next_action, 'do X');       // not erased by the jira record
  assert.equal(s.items['HIMMEL-1'].status, 'in-progress');
});

test('non-authoritative status is ignored', () => {
  const recs = [
    R({ ts: '1', source: 'jira', key: 'HIMMEL-1', kind: 'ticket', status: 'in-progress' }),
    R({ ts: '2', source: 'handover', key: 'HIMMEL-1', kind: 'ticket', status: 'done' }), // handover not authoritative for ticket status
  ];
  assert.equal(fold(recs).items['HIMMEL-1'].status, 'in-progress');
});

test('explicit-empty clears a list; awaiting_operator drops out', () => {
  const recs = [
    R({ ts: '1', source: 'git', key: 'HIMMEL-1', kind: 'ticket', awaiting_operator: ['merge'] }),
    R({ ts: '2', source: 'git', key: 'HIMMEL-1', kind: 'ticket', awaiting_operator: [] }),
  ];
  const s = fold(recs);
  assert.equal(s.items['HIMMEL-1'].awaiting_operator, undefined); // cleared = removed (not [])
  assert.equal(s.awaiting_operator.length, 0);
});

test('list newest-replace (not union)', () => {
  const recs = [
    R({ ts: '1', source: 'handover', key: 'K', kind: 'ticket', blockers: ['a', 'b'] }),
    R({ ts: '2', source: 'handover', key: 'K', kind: 'ticket', blockers: ['c'] }),
  ];
  assert.deepEqual(fold(recs).items['K'].blockers, ['c']);
});

test('equal-ts same-field: last-in-input wins (stable sort)', () => {
  const recs = [
    R({ ts: '1', source: 'jira', key: 'K', kind: 'ticket', status: 'to-do' }),
    R({ ts: '1', source: 'jira', key: 'K', kind: 'ticket', status: 'in-progress' }),
  ];
  assert.equal(fold(recs).items['K'].status, 'in-progress');
});

test('records missing a required field are skipped by fold', () => {
  const recs = [
    { ts: '1', source: 'jira', key: 'K', kind: 'ticket', status: 'in-progress' },
    { ts: '2', source: 'jira', key: 'BAD' }, // no kind → invalid → skipped
  ];
  const s = fold(recs);
  assert.ok(s.items['K']);
  assert.equal(s.items['BAD'], undefined);
});

test('terminal status excluded from in-flight, retained in items', () => {
  const s = fold([R({ ts: '1', source: 'jira', key: 'K', kind: 'ticket', status: 'done' })]);
  assert.ok(s.items['K']);
  assert.equal(inFlight(s).length, 0);
});

test('ticket and pr are separate keys', () => {
  const s = fold([
    R({ ts: '1', source: 'jira', key: 'HIMMEL-1', kind: 'ticket', status: 'in-progress', pr: 2 }),
    R({ ts: '1', source: 'pr', key: '#2', kind: 'pr', status: 'merged' }),
  ]);
  assert.equal(s.items['HIMMEL-1'].status, 'in-progress');
  assert.equal(s.items['#2'].status, 'merged');
});

test('unknown fields tolerated', () => {
  const s = fold([R({ ts: '1', source: 'jira', key: 'K', kind: 'ticket', futurething: 42 })]);
  assert.ok(s.items['K']);
});

test('merged status excluded from in-flight, retained in items', () => {
  const s = fold([R({ ts: '1', source: 'pr', key: '#1', kind: 'pr', status: 'merged' })]);
  assert.ok(s.items['#1']);
  assert.equal(inFlight(s).length, 0);
});

test('pr-kind: jira source is not authoritative for status', () => {
  const recs = [
    R({ ts: '1', source: 'pr', key: '#1', kind: 'pr', status: 'open' }),
    R({ ts: '2', source: 'jira', key: '#1', kind: 'pr', status: 'merged' }),
  ];
  assert.equal(fold(recs).items['#1'].status, 'open');
});

// REQUIRED extra test (residual critic note): handover-item accepts status from any source
test('handover-item: status accepted from non-jira/non-pr source', () => {
  const recs = [
    R({ ts: '1', source: 'handover', key: 'HI-1', kind: 'handover-item', status: 'in-progress' }),
    R({ ts: '2', source: 'git', key: 'HI-2', kind: 'handover-item', status: 'done' }),
  ];
  const s = fold(recs);
  // For handover-item, status authority is "any source" — both should be accepted
  assert.equal(s.items['HI-1'].status, 'in-progress');
  assert.equal(s.items['HI-2'].status, 'done');
  // HI-2 has terminal status so excluded from inFlight; HI-1 is in-flight
  assert.equal(inFlight(s).length, 1);
  assert.equal(inFlight(s)[0].key, 'HI-1');
});
