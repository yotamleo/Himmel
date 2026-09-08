// scripts/lanes/tests/profile-manifest.test.mjs
// HIMMEL-2189 — static (hermetic, no spawning) half of the profile
// context-budget architecture tests. Pins, per non-operator profile, the
// EXACT enabled-plugin-id set and the contextBudget the registry declares,
// so any registry edit that grows a profile's surface (bloat) or drops one
// (manifest drift, e.g. a rename) goes RED until this fixture is updated in
// the SAME commit — a reviewer sees the diff, not a silent surface change.
//
// Deliberately catalog-only (no opts.installed): this file must run inside
// pre-commit with no network/agent stack, so the resolve below cannot depend
// on the machine's live plugin universe (that gap is the measured probe's
// job — scripts/lanes/profile-context-probe.mjs — which is NOT wired into
// this hermetic suite because it spawns real, billed `claude` calls).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadRegistry, resolveProfile } from '../plugin-profiles.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const FIXTURE = JSON.parse(readFileSync(join(HERE, 'fixtures', 'profile-manifests.json'), 'utf8'));
const registry = loadRegistry(); // default path: relative to plugin-profiles.mjs, not this test file

const nonOperatorProfiles = Object.keys(registry.profiles).filter((name) => name !== 'operator');

test('fixture profile-name set matches the registry\'s non-operator profiles (a renamed/added/removed profile must update the fixture)', () => {
  assert.deepEqual(Object.keys(FIXTURE).sort(), [...nonOperatorProfiles].sort());
});

for (const name of nonOperatorProfiles) {
  test(`profile "${name}" enabled-id set and contextBudget match the checked-in manifest`, () => {
    const expected = FIXTURE[name];
    assert.ok(expected, `profile "${name}" is in the registry but has no fixture entry — manifest drift`);

    const { enabledPlugins } = resolveProfile(registry, name); // catalog-only, no opts.installed
    const actualEnabled = new Set(Object.entries(enabledPlugins).filter(([, on]) => on).map(([id]) => id));
    const expectedEnabled = new Set(expected.enabled);

    const extra = [...actualEnabled].filter((id) => !expectedEnabled.has(id)).sort();
    const missing = [...expectedEnabled].filter((id) => !actualEnabled.has(id)).sort();
    assert.deepEqual(extra, [], `profile "${name}" now enables id(s) not in the fixture — BLOAT: ${extra.join(', ')} (update fixtures/profile-manifests.json if intentional)`);
    assert.deepEqual(missing, [], `profile "${name}" no longer enables fixture id(s) — MANIFEST DRIFT: ${missing.join(', ')} (update fixtures/profile-manifests.json if intentional)`);

    assert.equal(registry.profiles[name].contextBudget, expected.contextBudget, `profile "${name}" contextBudget drifted from the fixture — update fixtures/profile-manifests.json if intentional`);
  });
}
