'use strict';
// scripts/himmelctl/lib/contributor-profile.js — contributor-dev reporting for
// `himmelctl install` (HIMMEL-1423). setup.sh/setup.ps1 remains the one
// idempotent mutation primitive; this module only reads actual state after (or
// before, for --dry-run) that primitive. It composes the existing manifest
// probe engine, version-aware deps engine, and adopter profile's canonical
// lane resolver rather than introducing parallel detection logic.

const fs = require('fs');
const path = require('path');
const probesLib = require('./probes.js');
const depsEngineLib = require('./deps-engine.js');
const adopterProfileLib = require('./adopter-profile.js');

const PROFILE_ITEMS = [
  { id: 'doc-guard-map', label: 'contributor checkout' },
  { id: 'pre-commit-hooks', label: 'pre-commit gates' },
  { id: 'jira-cli-dist-build', label: 'Jira CLI dist' },
  { id: 'handover-wiring', label: 'handover state' },
];

const SHELL_TEST_DEPS = [
  'node',
  'bun',
  'jq',
  'python3',
  'git',
  'pre-commit',
  'shellcheck',
  'gitleaks',
];

const SHELL_TEST_PROBES = [
  { id: 'bash', label: 'bash', probe: { type: 'dep', cmd: 'bash' } },
  { id: 'npm-less-node', label: 'npm', probe: { type: 'dep', cmd: 'npm' } },
  { id: 'gh', label: 'gh', probe: { type: 'dep', cmd: 'gh' } },
  { id: 'mktemp', label: 'mktemp', probe: { type: 'dep', cmd: 'mktemp' } },
];

function loadManifest(repoRoot) {
  return JSON.parse(fs.readFileSync(path.join(repoRoot, 'scripts', 'install', 'manifest.json'), 'utf8'));
}

function manifestItem(manifest, id) {
  const item = manifest.items.find((candidate) => candidate.id === id);
  if (!item) throw new Error(`contributor profile item missing from manifest.json: ${id}`);
  return item;
}

function probeManifestItem(manifest, spec, ctx) {
  const item = manifestItem(manifest, spec.id);
  return Object.assign({ id: spec.id, label: spec.label }, probesLib.runProbe(item, ctx));
}

function probeShellTools(repoRoot, ctx) {
  const declared = depsEngineLib.loadDeps(repoRoot);
  const byId = new Map(declared.map((dep) => [dep.id, dep]));
  const rows = SHELL_TEST_PROBES.map((item) => Object.assign(
    { id: item.id, label: item.label },
    probesLib.runProbe(item, ctx),
  ));
  for (const id of SHELL_TEST_DEPS) {
    const dep = byId.get(id);
    if (!dep) throw new Error(`contributor shell-test dependency missing from deps.json: ${id}`);
    const status = depsEngineLib.depStatus(dep, { repoRoot, env: ctx.env });
    rows.push({
      id,
      label: id,
      actual: status.severity === 'green' ? 'present' : status.severity === 'red' ? 'absent' : 'degraded',
      detail: status.detail,
    });
  }
  return rows;
}

async function buildReport(opts) {
  const repoRoot = opts.repoRoot;
  const env = opts.env || process.env;
  const platform = opts.platform || process.platform;
  const manifest = loadManifest(repoRoot);
  const ctx = { repoRoot, targetPath: repoRoot, scope: 'user', env, platform };
  const items = PROFILE_ITEMS.map((spec) => probeManifestItem(manifest, spec, ctx));
  const shellTools = probeShellTools(repoRoot, ctx);
  const laneProbe = await adopterProfileLib.loadLaneProbe(repoRoot, env);
  const lanes = adopterProfileLib.probeSelection(['codex', 'hermes'], {
    repoRoot,
    env,
    platform,
    laneProbe,
  }).filter((row) => row.selected);

  // The lane resolver answers whether Hermes can be dispatched. A contributor
  // also needs the upstream checkout that setup wires, so deepen that verdict
  // with the manifest's existing provenance and runtime probes. Codex already
  // gets the same richer readiness treatment through adopter-profile.js.
  const hermes = lanes.find((row) => row.id === 'hermes');
  const hermesCheckout = probesLib.runProbe(manifestItem(manifest, 'hermes-checkout'), ctx);
  const hermesRuntime = probesLib.runProbe(manifestItem(manifest, 'hermes-lanes'), ctx);
  if (hermes && hermesCheckout.actual === 'absent') {
    hermes.state = 'absent';
    hermes.detail = hermesCheckout.detail;
    hermes.setupState = 'incomplete';
    hermes.setupDetail = hermesRuntime.detail;
  } else if (hermes && hermesCheckout.actual === 'degraded') {
    hermes.state = 'unknown';
    hermes.detail = hermesCheckout.detail;
    hermes.setupState = 'unverified';
    hermes.setupDetail = hermesRuntime.detail;
  } else if (hermes && hermes.state === 'present') {
    hermes.setupState = hermesRuntime.actual === 'present' ? 'ready' : 'incomplete';
    hermes.setupDetail = hermesRuntime.detail;
  }

  return { platform, items, shellTools, lanes };
}

function stateLine(row) {
  const label = row.label.padEnd(20);
  if (row.actual === 'present') return `  ok ${label} ready — ${row.detail}`;
  if (row.actual === 'degraded') return `  ~~ ${label} DEGRADED — ${row.detail}`;
  return `  !! ${label} MISSING — ${row.detail}`;
}

function laneLine(row) {
  if (row.state === 'present' && row.setupState === 'ready') {
    return `  ok ${row.id.padEnd(9)} ready — ${row.detail}; ${row.setupDetail}`;
  }
  if (row.state === 'present') {
    const setup = row.setupState === 'incomplete' ? `setup INCOMPLETE — ${row.setupDetail}` : 'setup not verified';
    return `  ~~ ${row.id.padEnd(9)} binary present — ${row.detail}; ${setup}`;
  }
  if (row.state === 'disabled') return `  -- ${row.id.padEnd(9)} DISABLED — ${row.detail}`;
  if (row.state === 'misconfigured') return `  XX ${row.id.padEnd(9)} MISCONFIGURED — ${row.detail}`;
  if (row.state === 'absent') return `  !! ${row.id.padEnd(9)} MISSING — ${row.detail}`;
  return `  ?? ${row.id.padEnd(9)} UNKNOWN — ${row.detail}`;
}

function laneGuidance(row) {
  const steps = [];
  if (row.state !== 'present' && row.hint) steps.push(row.hint);
  if (row.setupState !== 'ready' && row.note) steps.push(row.note);
  if (steps.length === 0) return null;
  return `  - ${row.id}: ${steps.join('; ')}`;
}

function reportLines(report, opts) {
  const dryRun = Boolean(opts && opts.dryRun);
  const derived = opts && opts.derived ? opts.derived : 'the contributor setup primitive';
  const lines = ['', '── contributor dev profile (PROBED actual state) ──'];
  for (const row of report.items) lines.push(stateLine(row));

  lines.push('', '── shell-test toolchain (shared dependency probes) ──');
  for (const row of report.shellTools) lines.push(stateLine(row));

  lines.push('', '── contributor lanes (canonical registry/resolver) ──');
  for (const row of report.lanes) lines.push(laneLine(row));

  lines.push('', '── contributor next steps ──');
  const handover = report.items.find((row) => row.id === 'handover-wiring');
  if (!handover || handover.actual !== 'present') {
    lines.push('  - handover state: run /handover-setup to register or initialize the state repo; himmelctl only wires an explicit external HANDOVER_DIR non-interactively.');
  }
  const missingTools = report.shellTools.filter((row) => row.actual !== 'present').map((row) => row.id);
  if (missingTools.length > 0) {
    lines.push(`  - shell-test toolchain: install or upgrade ${missingTools.join(', ')}, then re-run; declared tools can also be converged with himmelctl deps ensure.`);
  }
  for (const row of report.lanes) {
    const guidance = laneGuidance(row);
    if (guidance) lines.push(guidance);
  }
  // HIMMEL-2308: alwaysOn is asked universally now (the dev overlay is an
  // orthogonal layer on top of a profile install, not its own flow) — the
  // universal epilogue (bin.js's printAdopterEpilogue, printed alongside this
  // report on every run) already reports the honest hardening state, so this
  // report no longer duplicates/shadows it with a hardcoded "not asked" line.
  lines.push(dryRun
    ? `  - would run the idempotent contributor setup primitive via ${derived}; NOTHING above was mutated`
    : '  - setup primitive completed; post-install probes above are authoritative');
  return lines;
}

module.exports = { buildReport, reportLines, SHELL_TEST_DEPS, SHELL_TEST_PROBES };
