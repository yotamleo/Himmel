// scripts/where-are-we/tests/query.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fold } from '../lib/fold.mjs';
import { branchToKey, query } from '../lib/query.mjs';

const state = fold([
  { ts: '1', source: 'jira', key: 'HIMMEL-7', kind: 'ticket', status: 'in-progress' },
  { ts: '1', source: 'git', key: 'HIMMEL-7', kind: 'ticket', lock: 'main: dep-sweep live' },
]);

test('branchToKey parses feature branches, null on main', () => {
  assert.equal(branchToKey('feat/himmel-7-thing'), 'HIMMEL-7');
  assert.equal(branchToKey('main'), null);
  assert.equal(branchToKey('chore/no-ticket'), null);
});

test('--for hit returns item + touching locks', () => {
  const r = query(state, { mode: 'for', key: 'HIMMEL-7' });
  assert.equal(r.item.key, 'HIMMEL-7');
  assert.equal(r.locks.length, 1);
});

test('--branch that resolves behaves as --for', () => {
  assert.equal(query(state, { mode: 'branch', name: 'feat/himmel-7-x' }).item.key, 'HIMMEL-7');
});

test('--branch main falls back to global (no random assign)', () => {
  const r = query(state, { mode: 'branch', name: 'main' });
  assert.ok(Array.isArray(r.inFlight));   // global shape
  assert.equal(r.item, undefined);
});

test('--locks returns only locks', () => {
  assert.deepEqual(Object.keys(query(state, { mode: 'locks' })), ['locks']);
});
