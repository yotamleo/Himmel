// scripts/where-are-we/tests/render.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fold } from '../lib/fold.mjs';
import { render } from '../lib/render.mjs';

const state = fold([
  { ts: '1', source: 'jira', key: 'HIMMEL-9', kind: 'ticket', status: 'in-progress' },
  { ts: '1', source: 'handover', key: 'HIMMEL-9', kind: 'ticket', next_action: 'finish fold' },
  { ts: '1', source: 'git', key: 'HIMMEL-2', kind: 'ticket', awaiting_operator: ['merge'] },
  { ts: '1', source: 'handover', key: 'HIMMEL-5', kind: 'ticket', status: 'blocked', blockers: ['waiting on X'] },
  { ts: '1', source: 'git', key: 'HIMMEL-5', kind: 'ticket', lock: 'main: dep-sweep live' },
]);

test('render has the four sections in order and is sorted by key', () => {
  const md = render(state);
  const iA = md.indexOf('## Awaiting YOU');
  const iF = md.indexOf('## In flight');
  const iB = md.indexOf('## Blocked');
  const iL = md.indexOf('## Locks');
  assert.ok(iA < iF && iF < iB && iB < iL);
  assert.ok(md.includes('HIMMEL-2'));  // awaiting
  assert.ok(md.includes('finish fold'));
});

test('render is byte-identical on re-render (idempotent, no wall-clock)', () => {
  assert.equal(render(state), render(state));
  assert.equal(/\d{2}:\d{2}:\d{2}/.test(render(state)), false); // no clock time in body
});

test('empty sections render (none)', () => {
  const empty = fold([{ ts: '1', source: 'jira', key: 'K', kind: 'ticket', status: 'done' }]);
  assert.ok(render(empty).includes('_(none)_'));
});

// REQUIRED extra test 1: ≥2 items in one section, verify sort by key
test('multiple items in same section are sorted by key', () => {
  const s = fold([
    { ts: '1', source: 'jira', key: 'HIMMEL-9', kind: 'ticket', status: 'in-progress' },
    { ts: '1', source: 'jira', key: 'HIMMEL-1', kind: 'ticket', status: 'in-progress' },
    { ts: '1', source: 'jira', key: 'HIMMEL-5', kind: 'ticket', status: 'in-progress' },
  ]);
  const md = render(s);
  const i1 = md.indexOf('HIMMEL-1');
  const i5 = md.indexOf('HIMMEL-5');
  const i9 = md.indexOf('HIMMEL-9');
  assert.ok(i1 < i5 && i5 < i9, 'items in In flight must appear sorted by key');
});

// REQUIRED extra test 2: status-less item (handover next_action only, no status) is not rendered in any section
test('status-less item (handover only, no status) appears in none of the four sections', () => {
  const s = fold([
    { ts: '1', source: 'handover', key: 'HIMMEL-99', kind: 'ticket', next_action: 'review draft' },
  ]);
  const md = render(s);
  assert.ok(!md.includes('HIMMEL-99'), 'status-less item must not appear in any rendered section');
});
