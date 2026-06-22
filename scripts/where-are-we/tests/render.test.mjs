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

// HIMMEL-530 Task 1: natural-numeric key sort (HIMMEL-10 after HIMMEL-9, not before)
test('keys sort in natural-numeric order, not lexical', () => {
  const s = fold([
    { ts: '1', source: 'jira', key: 'HIMMEL-2', kind: 'ticket', status: 'in-progress' },
    { ts: '1', source: 'jira', key: 'HIMMEL-9', kind: 'ticket', status: 'in-progress' },
    { ts: '1', source: 'jira', key: 'HIMMEL-10', kind: 'ticket', status: 'in-progress' },
    { ts: '1', source: 'jira', key: 'HIMMEL-11', kind: 'ticket', status: 'in-progress' },
    { ts: '1', source: 'jira', key: 'HIMMEL-21', kind: 'ticket', status: 'in-progress' },
    { ts: '1', source: 'jira', key: 'HIMMEL-99', kind: 'ticket', status: 'in-progress' },
    { ts: '1', source: 'jira', key: 'HIMMEL-100', kind: 'ticket', status: 'in-progress' },
    { ts: '1', source: 'jira', key: 'HIMMEL-101', kind: 'ticket', status: 'in-progress' },
    { ts: '1', source: 'jira', key: 'HIMMEL-3', kind: 'ticket', status: 'in-progress' },
    { ts: '1', source: 'jira', key: 'HIMMEL-7', kind: 'ticket', status: 'in-progress' },
    { ts: '1', source: 'jira', key: 'HIMMEL-200', kind: 'ticket', status: 'in-progress' },
  ]);
  const md = render(s);
  const order = ['HIMMEL-2', 'HIMMEL-3', 'HIMMEL-7', 'HIMMEL-9', 'HIMMEL-10', 'HIMMEL-11',
    'HIMMEL-21', 'HIMMEL-99', 'HIMMEL-100', 'HIMMEL-101', 'HIMMEL-200'];
  const idx = order.map((k) => md.indexOf(`**${k}**`));
  for (let i = 1; i < idx.length; i++) {
    assert.ok(idx[i - 1] < idx[i], `${order[i - 1]} must render before ${order[i]}`);
  }
});

test('natural-sort render is byte-identical on re-render (idempotent)', () => {
  const s = fold([
    { ts: '1', source: 'jira', key: 'HIMMEL-2', kind: 'ticket', status: 'in-progress' },
    { ts: '1', source: 'jira', key: 'HIMMEL-10', kind: 'ticket', status: 'in-progress' },
    { ts: '1', source: 'jira', key: 'HIMMEL-100', kind: 'ticket', status: 'in-progress' },
  ]);
  assert.equal(render(s), render(s));
});

// HIMMEL-530 Task 2: "Other in-flight" catch-all for non-terminal, non-(in-progress/blocked) statuses
test('non-terminal "other" statuses render in Other in-flight, not In flight/Blocked', () => {
  const s = fold([
    { ts: '1', source: 'jira', key: 'HIMMEL-1', kind: 'ticket', status: 'in-progress' },
    { ts: '1', source: 'jira', key: 'HIMMEL-2', kind: 'ticket', status: 'to-do' },
    { ts: '1', source: 'jira', key: 'HIMMEL-3', kind: 'ticket', status: 'in-review' },
    { ts: '1', source: 'jira', key: 'HIMMEL-4', kind: 'ticket', status: 'blocked' },
  ]);
  const md = render(s);
  const lines = md.split('\n');
  const reviewLine = lines.find((l) => l.includes('HIMMEL-3'));
  assert.ok(reviewLine.includes('(in-review)'), 'in-review status must show on the line');
  const otherStart = md.indexOf('## Other in-flight');
  const blockedStart = md.indexOf('## Blocked');
  // HIMMEL-2 (to-do) and HIMMEL-3 (in-review) live in the Other in-flight block
  for (const k of ['HIMMEL-2', 'HIMMEL-3']) {
    const at = md.indexOf(`**${k}**`);
    assert.ok(at > otherStart && at < blockedStart, `${k} must be under Other in-flight`);
  }
});

test('Other in-flight section is positioned between In flight and Blocked', () => {
  const s = fold([
    { ts: '1', source: 'jira', key: 'HIMMEL-1', kind: 'ticket', status: 'in-progress' },
    { ts: '1', source: 'jira', key: 'HIMMEL-2', kind: 'ticket', status: 'to-do' },
    { ts: '1', source: 'jira', key: 'HIMMEL-4', kind: 'ticket', status: 'blocked' },
  ]);
  const md = render(s);
  const iF = md.indexOf('## In flight');
  const todo = md.indexOf('**HIMMEL-2**');
  const iB = md.indexOf('## Blocked');
  assert.ok(iF < todo && todo < iB, 'to-do item must fall between In flight and Blocked headers');
});

test('terminal (done) item never appears in Other in-flight', () => {
  const s = fold([{ ts: '1', source: 'jira', key: 'HIMMEL-9', kind: 'ticket', status: 'done' }]);
  const md = render(s);
  const otherStart = md.indexOf('## Other in-flight');
  const blockedStart = md.indexOf('## Blocked');
  const block = md.slice(otherStart, blockedStart);
  assert.ok(!block.includes('HIMMEL-9'), 'done item must not appear in Other in-flight');
});

test('header order: In flight < Other in-flight < Blocked', () => {
  const md = render(fold([{ ts: '1', source: 'jira', key: 'K', kind: 'ticket', status: 'done' }]));
  assert.ok(md.indexOf('## In flight') < md.indexOf('## Other in-flight'));
  assert.ok(md.indexOf('## Other in-flight') < md.indexOf('## Blocked'));
});

// HIMMEL-530 Task 1: comparator total-order tie-breaks (leading-zero + segment-length
// branches) must give a deterministic order so the byte-identical contract holds even
// on near-collision keys, regardless of fold's input order.
test('natural sort is deterministic on leading-zero and segment-length tie-break keys', () => {
  const keys = ['HIMMEL-01', 'HIMMEL-1', 'HIMMEL-1-2', 'HIMMEL-10'];
  const mk = (ks) => fold(ks.map((k) => ({ ts: '1', source: 'jira', key: k, kind: 'ticket', status: 'in-progress' })));
  // Two different input orders must render identically (total order, order-independent).
  const a = render(mk(keys));
  const b = render(mk([...keys].reverse()));
  assert.equal(a, b);
  assert.equal(a, render(mk(keys))); // byte-identical re-render
  for (const k of keys) assert.ok(a.includes(`**${k}**`), `${k} must render`);
});
