// scripts/lanes/tests/probe.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { evalProbe } from '../probe.mjs';

const ctx = (o = {}) => ({
  env: o.env ?? {},
  pathHas: (c) => (o.paths ?? []).includes(c),
  installed: o.installed ?? {},
});

test('always → true regardless of ctx', () => {
  assert.equal(evalProbe({ kind: 'always' }, ctx()), true);
});
test('env → true only when the var is present and non-empty', () => {
  assert.equal(evalProbe({ kind: 'env', name: 'ZAI_API_KEY' }, ctx({ env: { ZAI_API_KEY: 'sk-x' } })), true);
  assert.equal(evalProbe({ kind: 'env', name: 'ZAI_API_KEY' }, ctx({ env: { ZAI_API_KEY: '' } })), false);
  assert.equal(evalProbe({ kind: 'env', name: 'ZAI_API_KEY' }, ctx({ env: { ZAI_API_KEY: '   ' } })), false); // whitespace-only (realistic .env artifact) → false via .trim()
  assert.equal(evalProbe({ kind: 'env', name: 'ZAI_API_KEY' }, ctx()), false);
});
test('path → true only when the cli resolves on PATH', () => {
  assert.equal(evalProbe({ kind: 'path', cli: 'gemini' }, ctx({ paths: ['gemini'] })), true);
  assert.equal(evalProbe({ kind: 'path', cli: 'gemini' }, ctx()), false);
});
test('crprofile → token-exact against a comma/space list', () => {
  assert.equal(evalProbe({ kind: 'crprofile', token: 'paid' }, ctx({ env: { CR_PROFILE: 'free,paid' } })), true);
  assert.equal(evalProbe({ kind: 'crprofile', token: 'paid' }, ctx({ env: { CR_PROFILE: 'free' } })), false);
  assert.equal(evalProbe({ kind: 'crprofile', token: 'paid' }, ctx({ env: { CR_PROFILE: 'unpaid' } })), false); // substring guard
  assert.equal(evalProbe({ kind: 'crprofile', token: 'paid' }, ctx({ env: { CR_PROFILE: 'none' } })), false);   // none → false
  assert.equal(evalProbe({ kind: 'crprofile', token: 'paid' }, ctx()), false);
});
test('installed → reads the runtime install map', () => {
  assert.equal(evalProbe({ kind: 'installed', tool: 'hermes' }, ctx({ installed: { hermes: true } })), true);
  assert.equal(evalProbe({ kind: 'installed', tool: 'hermes' }, ctx({ installed: { hermes: false } })), false);
  assert.equal(evalProbe({ kind: 'installed', tool: 'hermes' }, ctx()), false); // absent → false
});
test('unknown kind → false (fail-closed, never throw)', () => {
  assert.equal(evalProbe({ kind: 'bogus' }, ctx()), false);
});
