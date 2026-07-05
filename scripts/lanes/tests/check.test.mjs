// scripts/lanes/tests/check.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { detectInventoryDrift } from '../check.mjs';

test('clean CLAUDE.md (policy + /lanes pointer) → no drift', () => {
  const md = '## Subagent policy\nDelegate down. Query `/lanes` (derived from scripts/lanes/lanes.json).\n';
  assert.equal(detectInventoryDrift(md), null);
});
test('re-introduced inventory as a TABLE row → drift', () => {
  const md = '| Lane | Best for |\n| GLM lane (scripts/telegram/spawn-glm.ts) | impl |\n';
  assert.notEqual(detectInventoryDrift(md), null);
});
test('re-introduced inventory as a BULLET (the HIMMEL-688 form) → drift', () => {
  const md = '- GLM lane (scripts/telegram/spawn-glm.ts) — impl chunks\n- codex (CR_PROFILE=paid) — escalation\n';
  assert.notEqual(detectInventoryDrift(md), null);
});
test('the sanctioned /lanes pointer line mentioning lanes.json is NOT drift', () => {
  const md = 'Query the live set with `/lanes` (derived from scripts/lanes/lanes.json + machine state).\n';
  assert.equal(detectInventoryDrift(md), null);
});
test('EACH inventory needle individually trips drift (guard covers all four, not just the first)', () => {
  // detectInventoryDrift returns on the FIRST match, so multi-needle inputs only
  // exercise needle[0]. Assert each needle alone → a deleted needle can't stay green.
  for (const needle of ['spawn-glm', 'gemini-subagent', 'CR_PROFILE=paid', 'qwen3coder']) {
    assert.notEqual(detectInventoryDrift(`prose mentioning ${needle} inline\n`), null, `needle not caught: ${needle}`);
  }
});
