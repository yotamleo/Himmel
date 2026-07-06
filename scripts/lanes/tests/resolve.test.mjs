// scripts/lanes/tests/resolve.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { resolveLanes } from '../resolve.mjs';

const REG = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'lanes.json'), 'utf8'));
const ctx = (o = {}) => ({ env: o.env ?? {}, pathHas: (c) => (o.paths ?? []).includes(c), installed: o.installed ?? {} });

test('bare machine (no keys, no optional CLIs) → only the 4 Claude tiers', () => {
  const ids = resolveLanes(REG, ctx()).map((l) => l.id);
  assert.deepEqual(ids, ['haiku', 'sonnet', 'opus', 'fable']);
});
test('GLM lane appears with ZAI_API_KEY set', () => {
  assert.ok(resolveLanes(REG, ctx({ env: { ZAI_API_KEY: 'k' } })).some((l) => l.id === 'glm'));
  assert.ok(!resolveLanes(REG, ctx()).some((l) => l.id === 'glm'));
});
test('glm-subagent lane (inline Agent-tool dispatch) keys off ZAI_API_KEY too', () => {
  assert.ok(resolveLanes(REG, ctx({ env: { ZAI_API_KEY: 'k' } })).some((l) => l.id === 'glm-subagent'));
  assert.ok(!resolveLanes(REG, ctx()).some((l) => l.id === 'glm-subagent'));
});
test('codex lane keys off CR_PROFILE=paid', () => {
  assert.ok(resolveLanes(REG, ctx({ env: { CR_PROFILE: 'free,paid' } })).some((l) => l.id === 'codex'));
  assert.ok(!resolveLanes(REG, ctx({ env: { CR_PROFILE: 'free' } })).some((l) => l.id === 'codex'));
});
test('gemini lane is DE-LISTED (deprecated + out of budget, 2026-07-06) — never resolves even with the CLI on PATH', () => {
  assert.ok(!resolveLanes(REG, ctx({ paths: ['gemini'] })).some((l) => l.id === 'gemini'));
});
test('hermes-critics lane keys off the resolved install', () => {
  assert.ok(resolveLanes(REG, ctx({ installed: { hermes: true } })).some((l) => l.id === 'hermes-critics'));
  assert.ok(!resolveLanes(REG, ctx()).some((l) => l.id === 'hermes-critics'));
});
test('registry is valid JSON with the required per-lane keys', () => {
  for (const l of REG.lanes) for (const k of ['id', 'label', 'class', 'probe']) assert.ok(k in l, `${l.id ?? '?'} missing ${k}`);
});
test('malformed/empty registry → [] (the ?? [] guard, no throw)', () => {
  assert.deepEqual(resolveLanes({}, ctx()), []);
  assert.deepEqual(resolveLanes({ lanes: [] }, ctx()), []);
});
