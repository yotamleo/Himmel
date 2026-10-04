'use strict';
// scripts/himmelctl/lib/config-feed.js — HIMMEL-4254 P2: the feed behind
// `himmelctl report --json`, the config UI's one data source (spec §4).
//
// Read-only: composes the existing status engine (status-report.js, in-process),
// `himmel-doctor.sh --json` (P1), the doctor-cadence state, the cadence scripts'
// `status`, `plugin-profile.sh list --json`, the lane registry, the initiative
// legs, the flag registry and the secrets manifest into ONE row grammar. It
// writes nothing and calls no mutating verb. Every string passes redact.js on
// the way out (spec A14b).
//
// Test seams (same class as HIMMELCTL_CACHE_DIR):
//   HIMMEL_REPORT_DOCTOR        path of the doctor script to run
//   HIMMEL_REPORT_CADENCE_ROOT  tree holding the cadence scripts and
//                               plugin-profile.sh (default: the checkout)
//   HIMMEL_REPORT_NO_REDACT=1   disables redaction (the RED control only)

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const statusReportLib = require('./status-report.js');
const probesLib = require('./probes.js');
const redactLib = require('./redact.js');
const { resolveBash } = require('../../hooks/run-hook-with-bash.js');

const SCHEMA = 'himmel-config-feed/1';

// Budget for one doctor run (full or a re-probe of a doctor row). Measured
// 2026-10-04 on the operator station, read-only: see the PR body's Results.
const REPROBE_BUDGET_MS = 240000; // full doctor run measured 120s x2
const CADENCE_STATUS_TIMEOUT_MS = 15000;

// Mirrors bin.js INITIATIVE_LEGS (bin.js is not require()-able without side
// effects). merge and public widen agent autonomy to merging and public pushes:
// guard-class, display-only (spec §5.2 "removed from the table").
const INITIATIVE_LEGS = ['execute', 'prcheck', 'pr', 'ticket', 'merge', 'public', 'handover'];
const INITIATIVE_GUARD = new Set(['merge', 'public']);

// The five cadences P2 reports (spec §5.2 target list). evidence = what proves
// the component itself ran (A9): doctor-cadence's last.tsv on every OS; the
// runner .log on Windows only (cron keeps no run log on Linux/macOS).
const CADENCES = [
  { name: 'pipeline', script: 'scripts/luna/pipeline-cadence.sh', evidence: 'log', cost: 'runs Claude-backed harvest/synthesize and draws the subscription bank' },
  { name: 'qmd', script: 'scripts/luna/qmd-cadence.sh', evidence: 'log', cost: 'none (local qmd reindex)' },
  { name: 'graphmap', script: 'scripts/luna/graphmap-cadence.sh', evidence: 'log', cost: 'weekly claude-cli extraction; draws the subscription bank' },
  { name: 'codex-sweep', script: 'scripts/cleanup/codex-sweep-cadence.sh', evidence: 'log', windowsOnly: true, cost: 'none' },
  { name: 'doctor', script: 'scripts/doctor-cadence.sh', evidence: 'doctor-last', cost: 'none' },
];

function repoRoot() {
  return process.env.HIMMELCTL_REPO_ROOT || path.resolve(__dirname, '..', '..', '..');
}
function scriptRoot() {
  return process.env.HIMMEL_REPORT_CADENCE_ROOT || repoRoot();
}
function homeDir() {
  return process.env.HOME || os.homedir();
}

// The himmel checkout whose doctor to run: the primary behind a worktree
// (git-common-dir), else the root itself. A release-tarball install has no
// .git and uses its own tree.
function doctorPath() {
  if (process.env.HIMMEL_REPORT_DOCTOR) return process.env.HIMMEL_REPORT_DOCTOR;
  const root = repoRoot();
  let base = root;
  if (fs.existsSync(path.join(root, '.git'))) {
    const r = spawnSync('git', ['-C', root, 'rev-parse', '--path-format=absolute', '--git-common-dir'], { encoding: 'utf8', timeout: 5000 });
    const common = r.status === 0 ? r.stdout.trim() : '';
    if (common && path.basename(common) === '.git') base = path.dirname(common);
  }
  const p = path.join(base, 'scripts', 'himmel-doctor.sh');
  return fs.existsSync(p) ? p : path.join(root, 'scripts', 'himmel-doctor.sh');
}

function readJson(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; }
}
function readDotEnv() {
  try { return fs.readFileSync(path.join(repoRoot(), '.env'), 'utf8'); } catch { return ''; }
}
function mtimeIso(p) {
  try { return fs.statSync(p).mtime.toISOString(); } catch { return null; }
}

function mkRow(o) {
  return {
    id: o.id,
    source: o.source,
    group: o.group,
    title: o.title || o.id,
    declared: o.declared,
    installed: o.installed,
    fires: o.fires || { state: 'unverified', evidence: null, at: null },
    health: o.health,
    fix: o.fix || { remedy: '', owner: 'user' },
    probedAt: o.probedAt,
    control: o.control || { class: 'display-only' },
    sensitive: o.sensitive === true,
  };
}

// ── item rows (status engine) ────────────────────────────────────────────
const SEVERITY_HEALTH = { green: 'ok', degraded: 'warn', red: 'fail', 'n/a': 'off' };
const SEVERITY_INSTALLED = { green: 'present', degraded: 'degraded', red: 'absent', 'n/a': 'n/a' };

function itemGroup(item) {
  if (item.kind === 'scheduler') return 'cadence';
  if (item.kind === 'vault') return 'vault';
  if (item.kind === 'wiring' || item.kind === 'hook') return 'guard';
  if (item.kind === 'lane') return /^(bridge|telegram)/.test(item.id) ? 'bridge' : 'lane';
  return 'core';
}

// Best-effort: the copy-paste command buried in a status detail, e.g.
// "… — opt-in (bash scripts/luna/graphmap-cadence.sh arm)". status --json is
// golden-tested and unchanged; the parse lives here only (critic F9).
function remedyFromDetail(detail) {
  const m = /\((?:[^()]*?(?:with|run):\s*)?((?:bash|npm|node|cd|himmelctl|git|bun|brew|pip3?)\s[^)]*)\)/.exec(String(detail || ''));
  return m ? m[1].trim() : '';
}

function itemRows(ctx) {
  const { manifest, scope, targetPath, answers, itemIds, probedAt, foldedIds } = ctx;
  if (!answers) return [];
  const known = new Set(manifest.items.map((i) => i.id));
  const wanted = itemIds ? itemIds.filter((i) => known.has(i) && !foldedIds.has(i)) : null;
  if (wanted && wanted.length === 0) return [];
  const report = statusReportLib.statusReport({ manifest, scope, targetPath, answers, itemIds: wanted || undefined });
  const byId = new Map(manifest.items.map((i) => [i.id, i]));
  return report.items.filter((r) => !foldedIds.has(r.id)).map((r) => {
    const m = byId.get(r.id) || {};
    return mkRow({
      id: r.id,
      source: 'item',
      group: itemGroup({ kind: r.kind, id: r.id }),
      declared: { where: `scripts/install/manifest.json#${r.id}`, desired: r.desired === true ? 'wanted' : 'not wanted', profile: (m.profiles || []).join(',') },
      installed: { state: SEVERITY_INSTALLED[r.severity] || 'n/a', detail: r.detail || '' },
      health: SEVERITY_HEALTH[r.severity] || 'info',
      fix: { remedy: remedyFromDetail(r.detail), owner: 'user' },
      probedAt,
    });
  });
}

// ── doctor rows (P1: himmel-doctor.sh --json) ────────────────────────────
const DOCTOR_HEALTH = { FAIL: 'fail', WARN: 'warn', INFO: 'info', OK: 'ok' };

function doctorRows(ctx) {
  const { probedAt } = ctx;
  const doc = doctorPath();
  const r = spawnSync(resolveBash({ env: process.env }), [doc, '--json', '--no-color'], { encoding: 'utf8', timeout: REPROBE_BUDGET_MS, maxBuffer: 32 * 1024 * 1024 });
  // A check row proves nothing about a schedule firing (A9): only the
  // doctor-cadence row reads last.tsv.
  const fires = { state: 'unverified', evidence: null, at: null };
  const rows = [];
  for (const line of String(r.stdout || '').split('\n')) {
    if (!line.trim()) continue;
    let o;
    try { o = JSON.parse(line); } catch { continue; }
    if (!o || typeof o.id !== 'string') continue;
    rows.push(mkRow({
      id: `doctor:${o.id}`,
      source: 'doctor',
      group: 'core',
      title: o.msg || o.id,
      declared: { where: `scripts/himmel-doctor.sh#${o.id}`, desired: 'check', profile: 'all' },
      installed: { state: 'n/a', detail: o.msg || '' },
      fires,
      health: DOCTOR_HEALTH[o.sev] || 'info',
      fix: { remedy: o.remedy || '', owner: 'user' },
      probedAt,
    }));
  }
  // No rows, or the run died part-way (timeout / signal / spawn error): a
  // partial report must not read as a complete one. A plain non-zero exit is
  // the doctor reporting FAIL rows and is not an error here.
  if (rows.length === 0 || r.error || r.signal) {
    rows.push(mkRow({
      id: 'doctor:run',
      source: 'doctor',
      group: 'core',
      title: 'himmel-doctor did not produce a report',
      declared: { where: 'scripts/himmel-doctor.sh', desired: 'check', profile: 'all' },
      installed: { state: 'degraded', detail: r.error ? String(r.error.message) : (r.signal ? `killed by ${r.signal}` : `exit ${r.status}`) },
      health: 'warn',
      fix: { remedy: 'bash scripts/himmel-doctor.sh', owner: 'user' },
      probedAt,
    }));
  }
  return rows;
}

// ── cadence rows ─────────────────────────────────────────────────────────
function cadenceRow(c, ctx) {
  const { probedAt, manifest } = ctx;
  const id = `${c.name}-cadence`;
  const item = manifest.items.find((i) => i.id === id);
  const declared = {
    where: item ? `scripts/install/manifest.json#${id}` : c.script,
    desired: 'opt-in',
    profile: item ? (item.profiles || []).join(',') : 'all',
  };
  if (c.windowsOnly && process.platform !== 'win32') {
    return mkRow({
      id, source: 'cadence', group: 'cadence', title: `${c.name} cadence`, declared,
      installed: { state: 'n/a', detail: 'Windows only' },
      health: 'off',
      fix: { remedy: '', owner: 'user' },
      probedAt,
      control: { class: 'display-only', reason: 'Windows only' },
    });
  }
  const script = path.join(scriptRoot(), c.script);
  const r = spawnSync(resolveBash({ env: process.env }), [script, 'status'], { encoding: 'utf8', timeout: CADENCE_STATUS_TIMEOUT_MS });
  const out = String(r.stdout || '');
  const armed = /^ARMED\b/m.test(out);
  const broken = r.error || (r.status !== 0 && !armed && !/^not armed\b/m.test(out));
  let fires = { state: 'unverified', evidence: null, at: null };
  if (c.evidence === 'doctor-last') {
    const at = mtimeIso(path.join(homeDir(), '.himmel', 'state', 'doctor-cadence', 'last.tsv'));
    if (at) fires = { state: 'yes', evidence: 'doctor-cadence last.tsv mtime', at };
  } else if (process.platform === 'win32') {
    const m = /run log\s+(\S+\.log)\b/.exec(out);
    const at = m ? mtimeIso(m[1]) : null;
    if (at) fires = { state: 'yes', evidence: `runner log ${path.basename(m[1])}`, at };
  }
  const state = broken ? 'n/a' : armed ? 'present' : 'absent';
  return mkRow({
    id, source: 'cadence', group: 'cadence', title: `${c.name} cadence`, declared,
    installed: { state, detail: broken ? (String(r.stderr || out).split('\n')[0] || 'status failed') : out.split('\n')[0] },
    fires,
    health: broken ? 'warn' : armed ? 'ok' : 'off',
    fix: { remedy: armed || broken ? '' : `bash ${c.script} arm`, owner: 'user' },
    probedAt,
    control: { class: 'toggle', action: armed ? 'cadence.disarm' : 'cadence.arm', target: c.name, consent: 'typed', cost: c.cost },
  });
}

function cadenceRows(ctx) {
  const want = ctx.itemIds;
  return CADENCES.filter((c) => !want || want.includes(`${c.name}-cadence`)).map((c) => cadenceRow(c, ctx));
}

// ── plugins, lanes, initiative ───────────────────────────────────────────
function pluginRows(ctx) {
  const script = path.join(scriptRoot(), 'scripts', 'machine-setup', 'plugin-profile.sh');
  if (!fs.existsSync(script)) return [];
  const r = spawnSync(resolveBash({ env: process.env }), [script, 'list', '--json'], { encoding: 'utf8', timeout: 30000 });
  let data;
  try { data = JSON.parse(r.stdout); } catch { return []; }
  return (data.onDemand || []).map((p) => mkRow({
    id: `plugin:${p.spec}`, source: 'plugin', group: 'core', title: p.spec,
    declared: { where: 'scripts/lanes/plugin-profiles.json (onDemand)', desired: 'opt-in', profile: 'all' },
    installed: { state: p.state === 'enabled' ? 'present' : 'absent', detail: p.neededBy || '' },
    health: p.state === 'enabled' ? 'ok' : 'off',
    fix: { remedy: `himmelctl profile ${p.state === 'enabled' ? 'disable' : 'enable'} ${p.spec}`, owner: 'user' },
    probedAt: ctx.probedAt,
    control: { class: 'toggle', action: p.state === 'enabled' ? 'plugin.disable' : 'plugin.enable', target: p.spec, consent: 'plain' },
  }));
}

function laneRows(ctx) {
  const base = readJson(path.join(repoRoot(), 'scripts', 'lanes', 'lanes.json'));
  if (!base || !Array.isArray(base.lanes)) return [];
  const local = readJson(path.join(repoRoot(), 'scripts', 'lanes', 'lanes.local.json'));
  const overridden = new Set(((local && local.lanes) || []).map((l) => l && l.id).filter(Boolean));
  return base.lanes.filter((l) => l && l.id).map((l) => mkRow({
    id: `lane:${l.id}`, source: 'lane', group: 'lane', title: l.label || l.id,
    declared: { where: `scripts/lanes/lanes.json#${l.id}`, desired: 'registered', profile: 'all' },
    installed: { state: 'present', detail: overridden.has(l.id) ? 'local override in lanes.local.json' : 'registry default' },
    health: 'info',
    fix: { remedy: `himmelctl config get lanes.${l.id}`, owner: 'user' },
    probedAt: ctx.probedAt,
    control: { class: 'toggle', action: 'config.lanes', target: l.id, consent: 'plain' },
  }));
}

function initiativeRows(ctx) {
  const env = probesLib.parseDotEnv(readDotEnv());
  const active = new Set(String(env.HIMMEL_INITIATIVE || '').split(',').map((s) => s.trim()).filter(Boolean));
  return INITIATIVE_LEGS.map((leg) => {
    const on = active.has(leg);
    const guard = INITIATIVE_GUARD.has(leg);
    return mkRow({
      id: `initiative:${leg}`, source: 'initiative', group: 'core', title: `initiative.${leg}`,
      declared: { where: '.env#HIMMEL_INITIATIVE', desired: 'opt-in', profile: 'all' },
      installed: { state: on ? 'present' : 'absent', detail: on ? 'on' : 'off' },
      health: on ? 'ok' : 'off',
      fix: { remedy: `himmelctl config set initiative.${leg} ${on ? 'off' : 'on'}`, owner: 'user' },
      probedAt: ctx.probedAt,
      control: guard
        ? { class: 'display-only', reason: 'widens agent autonomy (guard-class)' }
        : { class: 'toggle', action: 'config.initiative', target: leg, consent: 'plain' },
    });
  });
}

// ── flags, secrets ───────────────────────────────────────────────────────
function flagRows(ctx) {
  const reg = readJson(path.join(__dirname, 'bypass-flags.json'));
  return ((reg && reg.flags) || []).map((f) => mkRow({
    id: `flag:${f.name}`, source: 'flag', group: 'guard', title: f.name,
    declared: { where: (f.hooks || []).join(', '), desired: 'off', profile: 'all' },
    installed: { state: 'n/a', detail: f.bypasses },
    health: 'info',
    fix: { remedy: f.remedy, owner: 'operator-launch-shell' },
    probedAt: ctx.probedAt,
    control: { class: 'display-only', reason: 'launch-shell variable' },
  }));
}

function featureGroup(feature) {
  if (feature === 'cadence') return 'cadence';
  if (feature === 'bridge') return 'bridge';
  if (/^lane:/.test(feature)) return 'lane';
  return 'vault';
}

// Presence only (A7): the value is never read into a row — only whether the
// key is set (non-empty) in the checkout's .env or the environment.
function secretRows(ctx) {
  const man = readJson(path.join(__dirname, 'secrets-manifest.json'));
  const env = probesLib.parseDotEnv(readDotEnv());
  return ((man && man.secrets) || []).map((s) => {
    const present = Boolean(env[s.name]) || Boolean(process.env[s.name]);
    return mkRow({
      id: `secret:${s.name}`, source: 'secret', group: featureGroup(s.feature || ''), title: s.name,
      declared: { where: `scripts/himmelctl/lib/secrets-manifest.json#${s.name}`, desired: s.required, profile: s.feature || '' },
      installed: { state: present ? 'present' : 'absent', detail: present ? 'set' : 'not set' },
      health: present ? 'ok' : s.required === 'required' ? 'fail' : 'off',
      fix: { remedy: present ? '' : (s.obtain || ''), owner: 'user' },
      probedAt: ctx.probedAt,
      control: { class: 'display-only', reason: 'secrets are presence-only' },
      sensitive: true,
    });
  });
}

// ── composer ─────────────────────────────────────────────────────────────
// buildFeed({manifest, scope, targetPath, answers, items})
//   answers: the cached install profile, or null when none exists (item rows
//   are then skipped and the envelope says profileCache:false)
//   items:   optional row-id list (the --items re-probe); the doctor runs only
//   when a requested row comes from it.
function buildFeed({ manifest, scope, targetPath, answers, items }) {
  const probedAt = new Date().toISOString();
  const itemIds = items && items.length > 0 ? items : null;
  const foldedIds = new Set(CADENCES.map((c) => `${c.name}-cadence`));
  const ctx = { manifest, scope, targetPath, answers, itemIds, probedAt, foldedIds };
  const wants = (prefix) => !itemIds || itemIds.some((i) => i.startsWith(prefix));

  let rows = [];
  rows = rows.concat(itemRows(ctx));
  if (wants('doctor:')) rows = rows.concat(doctorRows(ctx));
  rows = rows.concat(cadenceRows(ctx));
  if (wants('plugin:')) rows = rows.concat(pluginRows(ctx));
  if (wants('lane:')) rows = rows.concat(laneRows(ctx));
  if (wants('initiative:')) rows = rows.concat(initiativeRows(ctx));
  if (wants('flag:')) rows = rows.concat(flagRows(ctx));
  if (wants('secret:')) rows = rows.concat(secretRows(ctx));
  if (itemIds) rows = rows.filter((r) => itemIds.includes(r.id));

  const summary = { total: rows.length, ok: 0, warn: 0, fail: 0, off: 0, info: 0 };
  for (const r of rows) summary[r.health] = (summary[r.health] || 0) + 1;

  const feed = {
    schema: SCHEMA,
    generatedAt: probedAt,
    target: { scope, path: targetPath },
    base: repoRoot(),
    profileCache: Boolean(answers),
    rows,
    summary,
  };
  if (process.env.HIMMEL_REPORT_NO_REDACT === '1') return feed;
  return redactLib.redactDeep(feed, { literals: redactLib.envValues(readDotEnv(), probesLib.parseDotEnv) });
}

module.exports = { buildFeed, SCHEMA, REPROBE_BUDGET_MS, CADENCES, INITIATIVE_LEGS, remedyFromDetail };
