// HIMMEL-1677 — lane workers route through provider env overrides and must not
// start the redundant openai-codex plugin's unreaped app-server stack.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { resolveProfile } from '../plugin-profiles.mjs';

const CODEX_PLUGIN = 'codex@openai-codex';
const REGISTRY = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin-profiles.json'), 'utf8'));

test('lane worker profiles disable the redundant codex plugin', () => {
  assert.ok(REGISTRY.catalog.includes(CODEX_PLUGIN), 'codex plugin must stay catalogued so worker settings explicitly disable it');
  for (const name of Object.keys(REGISTRY.profiles).filter((profile) => profile.startsWith('lane-'))) {
    const settings = resolveProfile(REGISTRY, name);
    assert.equal(settings.enabledPlugins[CODEX_PLUGIN], false, `${name} must not start the codex app-server stack`);
  }

  assert.equal(resolveProfile(REGISTRY, 'user').enabledPlugins[CODEX_PLUGIN], true, 'the worker-only change must not alter the non-worker user profile');
});
