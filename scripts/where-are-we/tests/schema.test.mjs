// scripts/where-are-we/tests/schema.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { validateRecord, hasField, isClear } from '../lib/schema.mjs';

test('missing a required field fails validation', () => {
  assert.equal(validateRecord({ ts: 't', source: 'jira', key: 'K' }).ok, false); // no kind
  assert.equal(validateRecord({ ts: 't', source: 'jira', key: 'K', kind: 'ticket' }).ok, true);
});

test('omitted vs present-empty distinction', () => {
  const omitted = { ts: 't', source: 'jira', key: 'K', kind: 'ticket' };
  const cleared = { ...omitted, awaiting_operator: [], lock: null };
  assert.equal(hasField(omitted, 'awaiting_operator'), false);
  assert.equal(hasField(cleared, 'awaiting_operator'), true);
  assert.equal(isClear(cleared, 'awaiting_operator'), true);  // [] clears a list
  assert.equal(isClear(cleared, 'lock'), true);               // null clears a scalar
  assert.equal(isClear({ ...omitted, awaiting_operator: ['merge'] }, 'awaiting_operator'), false);
});
