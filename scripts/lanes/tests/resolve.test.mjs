// scripts/lanes/tests/resolve.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { resolveLanes, resolveLaneInventory, formatCodexHealth, buildCtx, fmtCtx, mergeLocalOverlay } from '../resolve.mjs';
import { applyLaneOverride, applyProfileAllowlist, writeProfileAllowlist } from '../set-lane-override.mjs';

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const RESOLVER = join(TEST_DIR, '..', 'resolve.mjs');
const REG = JSON.parse(readFileSync(join(TEST_DIR, '..', 'lanes.json'), 'utf8'));
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
test('codex-exec lane keys off the codex CLI on PATH (HIMMEL-781)', () => {
  assert.ok(resolveLanes(REG, ctx({ paths: ['codex'] })).some((l) => l.id === 'codex-exec'));
  assert.ok(!resolveLanes(REG, ctx()).some((l) => l.id === 'codex-exec'));
});
test('hermes-critics lane keys off the resolved install', () => {
  assert.ok(resolveLanes(REG, ctx({ installed: { hermes: true } })).some((l) => l.id === 'hermes-critics'));
  assert.ok(!resolveLanes(REG, ctx()).some((l) => l.id === 'hermes-critics'));
});
// HIMMEL-780 — these four rows used probe kind "installed" with tools buildCtx
// never populates, so they could NEVER resolve; they key off PATH now.
test('free-bank CLI lanes (copilot/agy/ollama) resolve via PATH (HIMMEL-780)', () => {
  const onPath = resolveLanes(REG, ctx({ paths: ['copilot', 'agy', 'ollama'] })).map((l) => l.id);
  for (const id of ['copilot-cli', 'antigravity-cli', 'ollama-local', 'ollama-cloud']) {
    assert.ok(onPath.includes(id), `${id} should resolve with its CLI on PATH`);
    assert.ok(!resolveLanes(REG, ctx()).some((l) => l.id === id), `${id} should not resolve on a bare machine`);
  }
});
test('buildCtx pathHas does real PATH/PATHEXT lookup (HIMMEL-780 follow-through)', () => {
  const bin = mkdtempSync(join(tmpdir(), 'lanes-bin-'));
  writeFileSync(join(bin, 'copilot.cmd'), '@echo off\n');
  writeFileSync(join(bin, 'agy'), '#!/bin/sh\n');
  const repo = mkdtempSync(join(tmpdir(), 'lanes-repo-'));
  const { pathHas } = buildCtx(repo, { PATH: bin, PATHEXT: '.COM;.EXE;.BAT;.CMD' });
  if (process.platform === 'win32') {
    assert.equal(pathHas('copilot'), true, 'PATHEXT .cmd shim should resolve on Windows');
    assert.equal(pathHas('agy'), false, 'bare extensionless file is not executable on Windows');
  } else {
    assert.equal(pathHas('agy'), true, 'bare name should resolve on POSIX');
    assert.equal(pathHas('copilot'), false, 'POSIX matches the bare name only, not .cmd');
  }
  assert.equal(pathHas('missing-cli'), false);
});
test('every "installed" probe names a tool buildCtx actually populates (HIMMEL-780 lockstep guard)', () => {
  const populated = Object.keys(buildCtx(mkdtempSync(join(tmpdir(), 'lanes-ctx-')), {}).installed);
  for (const l of REG.lanes) {
    if (l.probe?.kind !== 'installed') continue;
    assert.ok(populated.includes(l.probe.tool),
      `${l.id}: probe tool "${l.probe.tool}" is not populated by buildCtx (${populated.join(', ')}) — it can never resolve; use kind "path" or extend buildCtx`);
  }
});
test('registry is valid JSON with the required per-lane keys', () => {
  for (const l of REG.lanes) for (const k of ['id', 'label', 'class', 'probe']) assert.ok(k in l, `${l.id ?? '?'} missing ${k}`);
});
test('malformed/empty registry → [] (the ?? [] guard, no throw)', () => {
  assert.deepEqual(resolveLanes({}, ctx()), []);
  assert.deepEqual(resolveLanes({ lanes: [] }, ctx()), []);
});

test('profile allowlist narrows optional lanes but keeps Claude tiers and real probes', () => {
  const registry = {
    profileAllowlist: ['selected'],
    lanes: [
      { id: 'core', class: 'claude-tier', probe: { kind: 'always' } },
      { id: 'selected', class: 'impl', probe: { kind: 'path', cli: 'selected' } },
      { id: 'declined', class: 'impl', probe: { kind: 'path', cli: 'declined' } },
      { id: 'selected-but-absent', class: 'impl', probe: { kind: 'path', cli: 'missing' } },
    ],
  };
  const c = ctx({ paths: ['selected', 'declined'] });
  assert.deepEqual(resolveLanes(registry, c).map((l) => l.id), ['core', 'selected']);
  assert.deepEqual(
    resolveLaneInventory(registry, c)
      .filter((row) => row.suppressedByProfile)
      .map((row) => row.lane.id),
    ['declined'],
  );
  assert.ok(!resolveLaneInventory(registry, c).some((row) => row.lane.id === 'selected-but-absent'),
    'allowlisting an absent lane must never force it present');
});

test('profile allowlist scope leaves lanes outside the wizard-owned subset on their real probes', () => {
  const registry = {
    profileAllowlist: ['selected'],
    profileAllowlistScope: ['selected', 'declined'],
    lanes: [
      { id: 'selected', class: 'impl', probe: { kind: 'always' } },
      { id: 'declined', class: 'impl', probe: { kind: 'always' } },
      { id: 'outside-wizard', class: 'impl', probe: { kind: 'always' } },
    ],
  };
  assert.deepEqual(resolveLanes(registry, ctx()).map((l) => l.id), ['selected', 'outside-wizard']);
  assert.deepEqual(
    resolveLaneInventory(registry, ctx())
      .filter((row) => row.suppressedByProfile)
      .map((row) => row.lane.id),
    ['declined'],
  );
});

test('absent profile allowlist preserves the pre-profile inventory', () => {
  const registry = { lanes: [{ id: 'optional', class: 'impl', probe: { kind: 'always' } }] };
  assert.deepEqual(resolveLanes(registry, ctx()).map((l) => l.id), ['optional']);
  assert.equal(resolveLaneInventory(registry, ctx())[0].suppressedByProfile, false);
});

test('/lanes text distinguishes suppressed-by-profile while --json stays effective-only', () => {
  const dir = mkdtempSync(join(tmpdir(), 'lanes-profile-'));
  const file = join(dir, 'registry.json');
  writeFileSync(file, JSON.stringify({
    profileAllowlist: [],
    lanes: [
      { id: 'core', label: 'Core', class: 'claude-tier', bestFor: 'native', effort: 'low', probe: { kind: 'always' } },
      { id: 'optional', label: 'Optional', class: 'impl', bestFor: 'external', effort: 'low', probe: { kind: 'always' } },
    ],
  }));
  const env = { ...process.env, LANES_REGISTRY: file };
  const text = execFileSync(process.execPath, [RESOLVER], { env, encoding: 'utf8' });
  assert.match(text, /Available delegation lanes on this machine \(1\):/);
  assert.match(text, /Suppressed by adopter profile \(1; physically available, not routable\):/);
  assert.match(text, /Optional — suppressed-by-profile/);
  const json = JSON.parse(execFileSync(process.execPath, [RESOLVER, '--json'], { env, encoding: 'utf8' }));
  assert.deepEqual(json.map((lane) => lane.id), ['core']);
});

// HIMMEL-747 — codex startup-health annotation for /lanes.
test('formatCodexHealth: healthy (rc 0) / no-codex (rc 2) / spawn-fail (rc -1) render nothing', () => {
  assert.equal(formatCodexHealth(0, ''), '');
  assert.equal(formatCodexHealth(2, ''), '');
  assert.equal(formatCodexHealth(-1, ''), '');
});
test('formatCodexHealth: findings (rc 1) annotate with each WARN line, count, and the fix pointer', () => {
  const out = 'WARN hook-failure: codex ignored a hooks block\nWARN skill-truncation: codex truncated 3 prompts\n';
  const s = formatCodexHealth(1, out);
  assert.match(s, /codex lane health: DEGRADED/);
  assert.match(s, /2 startup finding\(s\)/);
  assert.match(s, /scripts\/codex\/startup-health\.sh/);
  assert.match(s, /- hook-failure: codex ignored a hooks block/);
  assert.match(s, /- skill-truncation: codex truncated 3 prompts/);
  assert.ok(!/WARN /.test(s), 'strips the WARN prefix in the rendered list');
});
test('formatCodexHealth: rc 1 but no WARN lines (defensive) → nothing', () => {
  assert.equal(formatCodexHealth(1, 'unexpected noise\n'), '');
});

// HIMMEL-1029 P1 — contextWindow formatting for the /lanes line.
test('fmtCtx: compacts M / k, drops non-positive + non-numeric', () => {
  assert.equal(fmtCtx(1000000), '1M');
  assert.equal(fmtCtx(272000), '272k');
  assert.equal(fmtCtx(200000), '200k');
  assert.equal(fmtCtx(1234), '1234');   // not a clean k/M multiple → verbatim
  assert.equal(fmtCtx(0), '');
  assert.equal(fmtCtx(-5), '');
  assert.equal(fmtCtx(undefined), '');  // absent contextWindow renders nothing
  assert.equal(fmtCtx(NaN), '');
});
test('every contextWindow in the registry is a positive integer', () => {
  for (const l of REG.lanes) {
    if (l.contextWindow === undefined) continue;
    assert.ok(Number.isInteger(l.contextWindow) && l.contextWindow > 0,
      `${l.id} contextWindow must be a positive integer`);
  }
});

// HIMMEL-758 — mergeLocalOverlay(): the true per-lane lanes.local.json overlay
// `himmelctl config` writes through set-lane-override.mjs.
test('mergeLocalOverlay: no local overrides -> base returned unchanged (same lane objects)', () => {
  const base = { lanes: [{ id: 'a', label: 'A', probe: { kind: 'always' } }] };
  const merged = mergeLocalOverlay(base, { lanes: [] });
  assert.deepEqual(merged.lanes, base.lanes);
});
test('mergeLocalOverlay: a local entry shallow-merges onto the matching base id (local wins)', () => {
  const base = { lanes: [
    { id: 'a', label: 'A', probe: { kind: 'always' } },
    { id: 'b', label: 'B', probe: { kind: 'env', name: 'X' } },
  ] };
  const local = { lanes: [{ id: 'a', probe: { kind: 'never' } }] };
  const merged = mergeLocalOverlay(base, local);
  assert.deepEqual(merged.lanes.map((l) => l.id), ['a', 'b']); // base order preserved
  assert.deepEqual(merged.lanes[0], { id: 'a', label: 'A', probe: { kind: 'never' } }); // label survives, probe overridden
  assert.deepEqual(merged.lanes[1], base.lanes[1]); // untouched lane unchanged
});
test('mergeLocalOverlay: a local-only id (absent from base) is appended', () => {
  const base = { lanes: [{ id: 'a', probe: { kind: 'always' } }] };
  const local = { lanes: [{ id: 'custom', probe: { kind: 'always' } }] };
  const merged = mergeLocalOverlay(base, local);
  assert.deepEqual(merged.lanes.map((l) => l.id), ['a', 'custom']);
});
test('mergeLocalOverlay: malformed/empty inputs never throw', () => {
  assert.deepEqual(mergeLocalOverlay({}, {}).lanes, []);
  assert.deepEqual(mergeLocalOverlay({ lanes: [] }, { lanes: [] }).lanes, []);
  assert.deepEqual(mergeLocalOverlay(undefined, undefined).lanes, []);
});
test('mergeLocalOverlay: carries top-level profile policy without disturbing lane overrides', () => {
  const base = { lanes: [{ id: 'a', probe: { kind: 'always' } }] };
  const local = {
    lanes: [{ id: 'a', probe: { kind: 'never' } }],
    profileAllowlist: ['a'],
    profileAllowlistScope: ['a', 'b'],
  };
  const merged = mergeLocalOverlay(base, local);
  assert.deepEqual(merged.profileAllowlist, ['a']);
  assert.deepEqual(merged.profileAllowlistScope, ['a', 'b']);
  assert.deepEqual(merged.lanes[0].probe, { kind: 'never' });
});
test('mergeLocalOverlay: unknown top-level local keys cannot shadow the base registry', () => {
  const base = { schemaVersion: 1, lanes: [{ id: 'a', probe: { kind: 'always' } }] };
  const local = { schemaVersion: 999, typoedPolicy: ['a'], lanes: [] };
  const merged = mergeLocalOverlay(base, local);
  assert.equal(merged.schemaVersion, 1);
  assert.ok(!Object.prototype.hasOwnProperty.call(merged, 'typoedPolicy'));
});
test('applyProfileAllowlist: preserves overrides and converges allowlist + scope ids', () => {
  const local = { lanes: [{ id: 'a', probe: { kind: 'never' } }], other: true };
  const next = applyProfileAllowlist(local, ['b', 'b', 'a'], ['a', 'b', 'a']);
  assert.deepEqual(next, {
    lanes: local.lanes,
    other: true,
    profileAllowlist: ['b', 'a'],
    profileAllowlistScope: ['a', 'b'],
  });
});
test('applyProfileAllowlist: legacy global persistence preserves non-wizard resolver verdicts', () => {
  const base = {
    lanes: [
      { id: 'wizard-selected', class: 'impl', probe: { kind: 'always' } },
      { id: 'wizard-declined', class: 'impl', probe: { kind: 'always' } },
      { id: 'outside-listed', class: 'impl', probe: { kind: 'always' } },
      { id: 'outside-suppressed', class: 'impl', probe: { kind: 'always' } },
    ],
  };
  const local = { lanes: [], profileAllowlist: ['outside-listed'] };
  assert.deepEqual(resolveLanes(mergeLocalOverlay(base, local), ctx()).map((l) => l.id), ['outside-listed']);

  const next = applyProfileAllowlist(
    local,
    ['wizard-selected'],
    ['wizard-selected', 'wizard-declined'],
  );
  assert.deepEqual(next.profileAllowlist, ['outside-listed', 'wizard-selected']);
  assert.ok(!Object.prototype.hasOwnProperty.call(next, 'profileAllowlistScope'));
  assert.deepEqual(
    resolveLanes(mergeLocalOverlay(base, next), ctx()).map((l) => l.id),
    ['wizard-selected', 'outside-listed'],
  );
});
test('applyLaneOverride: force-on extends the scoped profile allowlist before resolution', () => {
  const base = {
    lanes: [
      { id: 'selected', class: 'impl', probe: { kind: 'always' } },
      { id: 'declined', class: 'impl', probe: { kind: 'never' } },
    ],
  };
  const local = {
    lanes: [],
    profileAllowlist: ['selected'],
    profileAllowlistScope: ['selected', 'declined'],
  };
  const next = applyLaneOverride(local, 'declined', 'always');
  assert.deepEqual(next.profileAllowlist, ['selected', 'declined']);
  assert.deepEqual(resolveLanes(mergeLocalOverlay(base, next), ctx()).map((l) => l.id), ['selected', 'declined']);
});
test('applyLaneOverride: force-on extends a LEGACY scope-less allowlist too', () => {
  // No profileAllowlistScope: legacy global semantics — the allowlist
  // constrains every lane, so the force-on consent must extend it as well
  // (CR round 4 [codex-1]).
  const base = {
    lanes: [
      { id: 'selected', class: 'impl', probe: { kind: 'always' } },
      { id: 'declined', class: 'impl', probe: { kind: 'never' } },
    ],
  };
  const local = { lanes: [], profileAllowlist: ['selected'] };
  const next = applyLaneOverride(local, 'declined', 'always');
  assert.deepEqual(next.profileAllowlist, ['selected', 'declined']);
  assert.deepEqual(resolveLanes(mergeLocalOverlay(base, next), ctx()).map((l) => l.id), ['selected', 'declined']);
});
test('writeProfileAllowlist: malformed overlays are refused without changing file bytes', () => {
  for (const raw of ['{"lanes":{"bad":true}}\n', '[{"id":"a"}]\n']) {
    const dir = mkdtempSync(join(tmpdir(), 'lanes-malformed-'));
    const file = join(dir, 'lanes.local.json');
    writeFileSync(file, raw);
    assert.throws(
      () => writeProfileAllowlist(file, ['a'], ['a']),
      /must be a non-array object whose 'lanes' property is an array or absent/,
    );
    assert.equal(readFileSync(file, 'utf8'), raw);
  }
});

test('mergeLocalOverlay: never applied against the REAL lanes.json base + a synthetic override, resolveLanes then suppresses that lane', () => {
  const local = { lanes: [{ id: 'haiku', probe: { kind: 'never' } }] };
  const merged = mergeLocalOverlay(REG, local);
  const ids = resolveLanes(merged, ctx()).map((l) => l.id);
  assert.ok(!ids.includes('haiku'), 'a never-overridden lane must not resolve even though its base probe (always) would');
  assert.ok(ids.includes('sonnet'), 'every other always-on lane still resolves');
});
