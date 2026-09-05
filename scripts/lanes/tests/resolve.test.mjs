// scripts/lanes/tests/resolve.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { delimiter } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { resolveLanes, resolveLaneInventory, formatCodexHealth, buildCtx, fmtCtx, formatContextAnnotation, formatQuotaAnnotation, mergeLocalOverlay, unknownOverlayKeys } from '../resolve.mjs';
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
test('retired glm-subagent wrapper lane is absent from the registry', () => {
  assert.ok(!REG.lanes.some((l) => l.id === 'glm-subagent'));
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
test('buildCtx installed.hermes accepts only a real interpreter, matching resolve-hermes-py.sh', () => {
  const repo = mkdtempSync(join(tmpdir(), 'lanes-repo-'));
  const home = mkdtempSync(join(tmpdir(), 'lanes-hermes-'));
  // installed.hermes must mean "invoke.sh will find an interpreter". The shell
  // resolver tests `[ -x ]`, so anything it would reject must be rejected here
  // too -- otherwise the lane resolves and dispatch exits 3 after provisioning.
  const dir = join(home, 'a-directory');
  mkdirSync(dir);
  assert.equal(buildCtx(repo, { HERMES_PY: dir, HERMES_HOME: home }).installed.hermes, false,
    'a directory is not an interpreter');

  const plain = join(home, 'not-executable');
  writeFileSync(plain, 'x');
  if (process.platform !== 'win32') {
    chmodSync(plain, 0o644);
    assert.equal(buildCtx(repo, { HERMES_PY: plain, HERMES_HOME: home }).installed.hermes, false,
      'a non-executable file is not an interpreter');
  }

  const real = join(home, process.platform === 'win32' ? 'python.exe' : 'python');
  writeFileSync(real, '#!/bin/sh');
  chmodSync(real, 0o755);
  assert.equal(buildCtx(repo, { HERMES_PY: real, HERMES_HOME: home }).installed.hermes, true,
    'an executable regular file is an interpreter');

  assert.equal(buildCtx(repo, { HERMES_HOME: home }).installed.hermes, false,
    'no HERMES_PY and no venv under HERMES_HOME means the lane is unavailable');

  // Pins the round-10 removal: a hermes/hermes-agent shim on PATH must NOT make
  // the lane resolve, because resolve-hermes-py.sh never reads PATH.
  const bin = mkdtempSync(join(tmpdir(), 'lanes-shim-'));
  for (const nm of ['hermes', 'hermes.cmd', 'hermes-agent', 'hermes-agent.cmd']) {
    writeFileSync(join(bin, nm), 'shim');
    chmodSync(join(bin, nm), 0o755);
  }
  const shimEnv = { PATH: bin, PATHEXT: '.COM;.EXE;.BAT;.CMD', HERMES_HOME: mkdtempSync(join(tmpdir(), 'lanes-empty-')) };
  const shimCtx = buildCtx(repo, shimEnv);
  assert.equal(shimCtx.pathHas('hermes'), true, 'fixture must really put a shim on PATH');
  assert.equal(shimCtx.installed.hermes, false, 'a PATH shim is not an interpreter');
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

// HIMMEL-1967 — a registry-declared dormant lane must show as dormant in the
// /lanes text (not silently listed as if it were routable).
test('/lanes text flags a dormant lane with its reason and opt-in env', () => {
  const dir = mkdtempSync(join(tmpdir(), 'lanes-dormant-'));
  const file = join(dir, 'registry.json');
  writeFileSync(file, JSON.stringify({
    lanes: [
      {
        id: 'sleeper', label: 'Sleeper lane', class: 'impl', bestFor: 'nothing right now', effort: 'low',
        probe: { kind: 'always' },
        dormant: { reason: 'test dormancy reason', optInEnv: 'SLEEPER_LANE_OK' },
      },
    ],
  }));
  const env = { ...process.env, LANES_REGISTRY: file };
  const text = execFileSync(process.execPath, [RESOLVER], { env, encoding: 'utf8' });
  assert.match(text, /\[DORMANT: test dormancy reason — opt in: SLEEPER_LANE_OK=1\]/);
});

// HIMMEL-1967 — every registry-declared dormant impl lane must actually render.
test('every real registry dormant impl lane shows DORMANT in /lanes text', () => {
  // The resolver drops a lane whose probe fails BEFORE rendering, so a dormant lane
  // keyed on a machine-state probe is absent on a bare machine and this assertion
  // would be env-dependent. Force every dormant lane's probe inputs so the test
  // proves the RENDERER annotates dormancy, not that this box satisfies the probes.
  // LANES_REGISTRY pins the child to the tracked lanes.json: without it resolve.mjs
  // layers lanes.local.json over REG and an operator override could re-break this.
  const dormantLanes = REG.lanes.filter((l) => l.class === 'impl' && l.dormant);
  const forcedEnv = { LANES_REGISTRY: join(TEST_DIR, '..', 'lanes.json') };
  const resolvedPathDirs = new Set();
  const skippedPathProbes = [];
  // Resolve the REAL CLI location via the OS (where/which) - no synthetic stubs
  // that would drift from how the probe and the dispatcher actually resolve
  // binaries on this platform. Shared below by the HIMMEL-2573 re-check, so both
  // agree on what "on PATH" means instead of the assertion inventing a second
  // mechanism.
  const resolveCliDir = (cli) => {
    const isWin = process.platform === 'win32';
    const probe = isWin ? ['where', cli] : ['which', cli];
    try {
      const first = execFileSync(probe[0], probe.slice(1), { encoding: 'utf8' }).split(/\r?\n/)[0].trim();
      return first ? dirname(first) : null;
    } catch {
      return null;
    }
  };
  for (const l of dormantLanes) {
    if (!l.probe) continue;
    switch (l.probe.kind) {
      case 'env':
        if (l.probe.name) forcedEnv[l.probe.name] = 'test-forced';
        break;
      case 'installed':
        // buildCtx only models installed.hermes; HERMES_PY pointing at this running
        // node binary passes hermesInstalled's isExe check on every platform.
        if (l.probe.tool === 'hermes') forcedEnv.HERMES_PY = process.execPath;
        else throw new Error(`unhandled installed-probe tool '${l.probe.tool}' - extend this fixture`);
        break;
      case 'path': {
        if (l.probe.cli && !resolvedPathDirs.has(l.probe.cli)) {
          const dir = resolveCliDir(l.probe.cli);
          if (dir) resolvedPathDirs.add(dir);
          else {
            // CLI genuinely absent on this machine: the lane cannot be force-rendered
            // here. Record it so the gap is reported below, not silent.
            skippedPathProbes.push(`${l.id} (cli '${l.probe.cli}' not on this machine)`);
          }
        }
        break;
      }
      case 'always':
      case 'crprofile':
        break;
      default:
        throw new Error(`unhandled probe kind '${l.probe.kind}' - extend this fixture`);
    }
  }
  if (resolvedPathDirs.size > 0) {
    const prefix = [...resolvedPathDirs].join(delimiter) + delimiter;
    forcedEnv.PATH = prefix + (process.env.PATH || '');
    forcedEnv.Path = forcedEnv.PATH;
  }
  const text = execFileSync(process.execPath, [RESOLVER], { encoding: 'utf8', env: { ...process.env, ...forcedEnv } });
  assert.ok(dormantLanes.length > 0, 'expected at least one dormant impl lane in the real registry');
  // HIMMEL-2573: a path-probed lane's CLI (codex-wsl's `wsl`; codex-exec's
  // `codex`) can be genuinely absent here - wsl is Windows-only tooling and can
  // never resolve on Linux/macOS, and a CLI like codex may simply not be
  // installed on a given box or CI runner either. Neither is hardcoded to one
  // platform: derive both branches - CLI present (must render DORMANT) and CLI
  // absent (must appear in the loud skip list, and ONLY there) - from a fresh
  // probe right here, so the suite is correct on whichever host runs it instead
  // of only the one it happened to be written on.
  for (const l of dormantLanes) {
    if (l.probe?.kind !== 'path' || !l.probe.cli) continue;
    const reallyAbsent = !resolveCliDir(l.probe.cli);
    const flaggedAbsent = skippedPathProbes.some((s) => s.startsWith(`${l.id} (cli '${l.probe.cli}'`));
    assert.equal(flaggedAbsent, reallyAbsent,
      `lane '${l.id}': loud-skip flag (${flaggedAbsent}) disagrees with a fresh probe of '${l.probe.cli}' (absent=${reallyAbsent})`);
  }
  // A skipped lane is a real coverage gap, and it has to stay visible on a GREEN
  // run: the pre-HIMMEL-2573 assertion made it loud only by FAILING, and the
  // reconciliation above only speaks when the flag and a fresh probe disagree.
  // CI runs this suite as a bare `node --test` (.github/workflows/ci.yml), and
  // node's default reporter passes a test file's stderr through (spec on node
  // 24, tap on older ones - either way the line shows), so the gap is reported
  // on the host where nobody is watching. The
  // `dot` reporter in CLAUDE.md's local invocation prints only dots and
  // failures: it shows neither these lines nor t.diagnostic(). That is a
  // property of that reporter, not of this report.
  for (const skipped of skippedPathProbes) {
    process.stderr.write(`lanes/resolve: DORMANT render NOT exercised for ${skipped}\n`);
  }
  for (const lane of dormantLanes) {
    if (skippedPathProbes.some((s) => s.startsWith(`${lane.id} `))) continue; // CLI genuinely absent here - can't force-render
    assert.match(text, new RegExp(`\\[DORMANT: .*opt in: ${lane.dormant.optInEnv}=1\\]`), `lane '${lane.id}' missing DORMANT annotation`);
  }
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
test('context annotations derive from structured window + overflow (no prose drift)', () => {
  assert.equal(formatContextAnnotation({ windowTokens: 1000000, overflow: 'hard-limit' }), '[ctx: 1M; hard limit]');
  assert.equal(
    formatContextAnnotation({ windowTokens: 272000, overflow: 'compact-continue' }),
    '[ctx: 272k; compacts+continues past window (cost penalty)]',
  );
  assert.equal(formatContextAnnotation(undefined), '');
});
test('every structured context in the registry is valid and carries no legacy descriptor', () => {
  for (const l of REG.lanes) {
    assert.equal(l.contextWindow, undefined, `${l.id} must not carry legacy contextWindow prose-adjacent data`);
    if (l.context === undefined) continue;
    assert.ok(Number.isInteger(l.context.windowTokens) && l.context.windowTokens > 0,
      `${l.id} context.windowTokens must be a positive integer`);
    assert.ok(['hard-limit', 'compact-continue'].includes(l.context.overflow),
      `${l.id} context.overflow must be explicit`);
  }
  assert.equal(REG.lanes.find((l) => l.id === 'glm').context.windowTokens, 1000000);
  for (const id of ['claudex', 'codex', 'codex-exec', 'codex-wsl', 'hermes-oneshot']) {
    assert.deepEqual(REG.lanes.find((l) => l.id === id).context, { windowTokens: 900000, overflow: 'compact-continue' });
  }
});

test('quota annotation names active access, existing windows, and the binding constraint', () => {
  const claude = { accessPaths: [{ kind: 'subscription', windows: ['5h', 'weekly'] }], activeAccessPath: 0 };
  assert.equal(
    formatQuotaAnnotation(claude, { detail: 'measured 5h used=4% free=96%; weekly used=96% free=4%' }),
    '[access: subscription; windows: 5h+weekly; binds: weekly]',
  );
  const codex = { accessPaths: [{ kind: 'subscription', windows: ['weekly'] }], activeAccessPath: 0 };
  assert.equal(formatQuotaAnnotation(codex, { detail: 'unmeasurable reason="cold"' }),
    '[access: subscription; windows: weekly; binds: unknown]');
  const glm = { accessPaths: [
    { kind: 'subscription', windows: ['5h', 'weekly'] },
    { kind: 'metered-api-key', provider: 'z.ai', windows: [] },
  ], activeAccessPath: 0 };
  assert.equal(
    formatQuotaAnnotation(glm, { detail: 'measured 5h used=25% free=75%; weekly used=50% free=50%' }),
    '[access: subscription; windows: 5h+weekly; binds: weekly; alternative: metered API key (z.ai)]',
  );
});

test('every quota access path has an explicit type and window structure', () => {
  for (const l of REG.lanes.filter((lane) => lane.quota)) {
    assert.ok(Array.isArray(l.quota.accessPaths) && l.quota.accessPaths.length > 0, `${l.id} missing quota.accessPaths`);
    assert.ok(Number.isInteger(l.quota.activeAccessPath), `${l.id} missing quota.activeAccessPath`);
    assert.ok(l.quota.accessPaths[l.quota.activeAccessPath], `${l.id} activeAccessPath is out of range`);
    for (const path of l.quota.accessPaths) {
      assert.ok(['subscription', 'metered-api-key'].includes(path.kind), `${l.id} has unknown access path kind`);
      assert.ok(Array.isArray(path.windows), `${l.id} access path windows must be an array`);
    }
  }
});

// HIMMEL-1913 — unknown per-lane overlay keys must not fail silently.
test('unknownOverlayKeys: reports drop as unknown', () => {
  const base = { lanes: [{ id: 'glm', probe: { kind: 'env', name: 'ZAI_API_KEY' } }] };
  const local = { lanes: [{ id: 'glm', drop: true }] };
  assert.deepEqual(unknownOverlayKeys(base, local), [{ id: 'glm', keys: ['drop'] }]);
});
test('unknownOverlayKeys: accepts delta keys present on any base lane', () => {
  const base = { lanes: [
    { id: 'a', probe: { kind: 'always' } },
    { id: 'b', effort: 'low', probe: { kind: 'never' } },
  ] };
  const local = { lanes: [
    { id: 'a', probe: { kind: 'never' } },
    { id: 'a', effort: 'high' },
  ] };
  assert.deepEqual(unknownOverlayKeys(base, local), []);
});
test('unknownOverlayKeys: checks overlay-only lanes against the shared schema', () => {
  const base = { lanes: [{ id: 'a', probe: { kind: 'always' } }] };
  const local = { lanes: [{ id: 'custom', probe: { kind: 'always' }, typoedField: true }] };
  assert.deepEqual(unknownOverlayKeys(base, local), [{ id: 'custom', keys: ['typoedField'] }]);
});
test('unknownOverlayKeys: derives known keys from base lane data', () => {
  const base = { lanes: [{ id: 'a', novelField: 'base value' }] };
  const local = { lanes: [{ id: 'custom', novelField: 'local value' }] };
  assert.deepEqual(unknownOverlayKeys(base, local), []);
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
test('mergeLocalOverlay: drop stays an inert merged field and does not remove the lane', () => {
  const base = { lanes: [{ id: 'glm', probe: { kind: 'always' } }] };
  const local = { lanes: [{ id: 'glm', drop: true }] };
  const merged = mergeLocalOverlay(base, local);
  assert.deepEqual(merged.lanes, [{ id: 'glm', probe: { kind: 'always' }, drop: true }]);
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
