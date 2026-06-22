// scripts/where-are-we/tests/provision.test.mjs — unit tests for lib/provision.mjs (pure)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fold } from '../lib/fold.mjs';
import { UsageError } from '../lib/errors.mjs';
import { renderSlice, buildEmitRecord } from '../lib/provision.mjs';

const NOW = '2026-06-22T12:00:00Z';
const rec = (over) => ({ ts: NOW, source: 'jira', key: 'HIMMEL-9', kind: 'ticket', ...over });

// --- renderSlice -------------------------------------------------------------

test('renderSlice: miss (no item for key) → empty string', () => {
  const state = fold([rec({ key: 'HIMMEL-9', status: 'in-progress' })]);
  assert.equal(renderSlice(state, 'HIMMEL-404'), '');
});

test('renderSlice: substantive hit (status) → item card', () => {
  const state = fold([rec({ key: 'HIMMEL-9', status: 'in-progress' })]);
  const out = renderSlice(state, 'HIMMEL-9');
  assert.match(out, /# HIMMEL-9/);
  assert.match(out, /- status: in-progress/);
});

test('renderSlice: hit with next_action (handover) → shows next', () => {
  const state = fold([
    rec({ key: 'HIMMEL-9', status: 'in-progress' }),
    { ts: NOW, source: 'handover', key: 'HIMMEL-9', kind: 'ticket', next_action: 'write the tests' },
  ]);
  const out = renderSlice(state, 'HIMMEL-9');
  assert.match(out, /- next: write the tests/);
});

test('renderSlice: hit with blockers (handover) → shows blockers', () => {
  const state = fold([
    rec({ key: 'HIMMEL-9', status: 'blocked' }),
    { ts: NOW, source: 'handover', key: 'HIMMEL-9', kind: 'ticket', blockers: ['waiting on VM', 'cred'] },
  ]);
  const out = renderSlice(state, 'HIMMEL-9');
  assert.match(out, /- blockers: waiting on VM; cred/);
});

test('renderSlice: hit with a lock (git) → shows lock', () => {
  const state = fold([
    rec({ key: 'HIMMEL-9', status: 'in-progress' }),
    { ts: NOW, source: 'git', key: 'HIMMEL-9', kind: 'ticket', lock: 'worktree locked' },
  ]);
  const out = renderSlice(state, 'HIMMEL-9');
  assert.match(out, /- lock: worktree locked/);
});

// Substantive WITHOUT status: the OR-chain's reason to exist — a key Jira has
// not seen yet but that carries a handover next_action / blockers, or a git lock.
// (Guards against a refactor collapsing the predicate to `it.status != null`.)
test('renderSlice: substantive via next_action only, status absent → card', () => {
  const state = fold([{ ts: NOW, source: 'handover', key: 'HIMMEL-9', kind: 'ticket', next_action: 'do the thing' }]);
  assert.equal(state.items['HIMMEL-9'].status, undefined); // precondition: no status
  assert.match(renderSlice(state, 'HIMMEL-9'), /- next: do the thing/);
});

test('renderSlice: substantive via blockers only, status absent → card', () => {
  const state = fold([{ ts: NOW, source: 'handover', key: 'HIMMEL-9', kind: 'ticket', blockers: ['stuck'] }]);
  assert.equal(state.items['HIMMEL-9'].status, undefined);
  assert.match(renderSlice(state, 'HIMMEL-9'), /- blockers: stuck/);
});

test('renderSlice: substantive via lock only, status absent → card', () => {
  const state = fold([{ ts: NOW, source: 'git', key: 'HIMMEL-9', kind: 'ticket', lock: 'worktree locked' }]);
  assert.equal(state.items['HIMMEL-9'].status, undefined);
  assert.match(renderSlice(state, 'HIMMEL-9'), /- lock: worktree locked/);
});

test('renderSlice: contentless hit (awaiting_operator only, no status/next/blockers/lock) → empty', () => {
  // An item seen only via a bare awaiting_operator emit folds to an item with no
  // status/next/blockers/locks — renderItem would emit "# KEY\n- status: —", a
  // contentless block. renderSlice must treat that as a miss (decision (b), #6).
  const state = fold([
    { ts: NOW, source: 'handover', key: 'HIMMEL-9', kind: 'ticket', awaiting_operator: ['decide X'] },
  ]);
  assert.equal(state.items['HIMMEL-9'].status, undefined); // precondition
  assert.equal(renderSlice(state, 'HIMMEL-9'), '');
});

// --- buildEmitRecord ---------------------------------------------------------

test('buildEmitRecord: next_action only → handover/ticket record with next_action', () => {
  const r = buildEmitRecord({ key: 'HIMMEL-1', next_action: 'ship it' }, NOW);
  assert.deepEqual(r, { ts: NOW, source: 'handover', key: 'HIMMEL-1', kind: 'ticket', next_action: 'ship it' });
});

test('buildEmitRecord: blockers (array) only', () => {
  const r = buildEmitRecord({ key: 'HIMMEL-1', blockers: ['a', 'b'] }, NOW);
  assert.deepEqual(r.blockers, ['a', 'b']);
  assert.equal(r.source, 'handover');
});

test('buildEmitRecord: awaiting only', () => {
  const r = buildEmitRecord({ key: 'HIMMEL-1', awaiting_operator: ['decide'] }, NOW);
  assert.deepEqual(r.awaiting_operator, ['decide']);
});

test('buildEmitRecord: clearBlockers → blockers []', () => {
  const r = buildEmitRecord({ key: 'HIMMEL-1', clearBlockers: true }, NOW);
  assert.deepEqual(r.blockers, []);
});

test('buildEmitRecord: clearNext → next_action null', () => {
  const r = buildEmitRecord({ key: 'HIMMEL-1', clearNext: true }, NOW);
  assert.equal(r.next_action, null);
});

test('buildEmitRecord: no key → UsageError', () => {
  assert.throws(() => buildEmitRecord({ next_action: 'x' }, NOW), UsageError);
});

test('buildEmitRecord: empty (no field) → UsageError', () => {
  assert.throws(() => buildEmitRecord({ key: 'HIMMEL-1' }, NOW), UsageError);
});

test('buildEmitRecord: set + clear conflict on same field → UsageError', () => {
  assert.throws(() => buildEmitRecord({ key: 'HIMMEL-1', blockers: ['a'], clearBlockers: true }, NOW), UsageError);
  assert.throws(() => buildEmitRecord({ key: 'HIMMEL-1', next_action: 'x', clearNext: true }, NOW), UsageError);
  assert.throws(() => buildEmitRecord({ key: 'HIMMEL-1', awaiting_operator: ['x'], clearAwaiting: true }, NOW), UsageError);
});

// --- fold round-trips (the write actually lands / is correctly scoped) --------

test('fold round-trip (positive): emitted blockers land in the folded item', () => {
  const r = buildEmitRecord({ key: 'HIMMEL-1', blockers: ['x'] }, NOW);
  const state = fold([r]);
  assert.deepEqual(state.items['HIMMEL-1'].blockers, ['x']);
});

test('fold round-trip (clear): a later-ts clear erases the field', () => {
  const set = buildEmitRecord({ key: 'HIMMEL-1', blockers: ['x'] }, '2026-06-22T10:00:00Z');
  const clr = buildEmitRecord({ key: 'HIMMEL-1', clearBlockers: true }, '2026-06-22T11:00:00Z');
  const state = fold([set, clr]);
  assert.equal(state.items['HIMMEL-1'].blockers, undefined);
});

test('authority guard: a status from source=handover does NOT win (emit is scoped)', () => {
  // Proves emit is correctly limited to the three handover-authoritative fields:
  // a hand-built handover record carrying status would vanish in fold (jira owns
  // status for kind:ticket). buildEmitRecord never emits status — this guards the
  // contract the scoping relies on.
  const stray = { ts: NOW, source: 'handover', key: 'HIMMEL-1', kind: 'ticket', status: 'in-progress' };
  const state = fold([stray]);
  assert.equal(state.items['HIMMEL-1'].status, undefined);
});
