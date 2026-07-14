'use strict';
// scripts/himmelctl/lib/probes.js — the himmelctl probe engine (HIMMEL-756
// T1.4): one function per probe.type, EXACTLY the eight in
// scripts/install/manifest-lint.mjs's PROBE_TYPES vocabulary. Every probe is
// a PURE READ (no writes, no prompts, no env mutation) returning
// `{ actual: "present"|"absent"|"degraded", detail: "<string>" }`.
//
// Export: runProbe(item, ctx) where ctx = { repoRoot, targetPath, scope, env }.
// `env` is forwarded (not process.env directly) to every spawned child
// process (cmd:has_qmd, qmd-index, handover-dir all shell out to bash), so a
// hermetic test can hand a fully-controlled env object without mutating the
// real process.env; falls back to process.env when ctx.env is omitted. The
// `dep` probe is the one exception — see its function below.
//
// ── Design calls made resolving ambiguity in the T1.3 brief's shorthand ────
//
// "file-exists → fs.existsSync(resolve(repoRoot/targetPath, descriptor.path))"
// undersells a real split in the manifest: most file-exists items check
// something adopt.sh's PORTABLE_FILES actually copies into the ADOPTED
// project (pre-commit-hooks' .pre-commit-config.yaml, guardrail-scope's
// scripts/guardrails/lib.sh) — those resolve against ctx.targetPath. A
// handful check himmel's OWN repo-only build/tooling artifacts that are
// NEVER copied into any target (jira-cli-dist-build, bitbucket-cli-build,
// doc-guard-map — the latter is kind:"wiring" like guardrail-scope, so kind
// alone doesn't separate them) — those always resolve against ctx.repoRoot,
// regardless of scope. REPO_ROOT_FILE_EXISTS_IDS below is the explicit,
// commented exception list; a new file-exists item added to the manifest
// defaults to targetPath-relative for scope=project, repoRoot-relative for
// scope=user, and needs a look here if it's actually a repo-only artifact.
//
// "settings-key → parse the scope-appropriate settings.json" is similarly
// shorthand: descriptor.file is generic (".claude/settings.json" for the
// wiring/plugin items, ".env" for jira-env-keys) — resolveConfigFile() below
// resolves ".env" against ctx.repoRoot ALWAYS (both scopes), per the
// documented convention (CLAUDE.md: jira CLI always invoked by absolute path
// from the primary checkout; adopt.sh's fill_env_core comment: "adopt copies
// only portable hooks -- never the Jira CLI -- so an adopted repo always
// invokes node $HIMMEL_ROOT/scripts/jira/..., whose repoRoot() reads
// $HIMMEL_ROOT/.env"), and every other file against the scope-appropriate
// base (project: ctx.targetPath; user: $HOME), matching bin.js's own
// settingsPathForScope().
//
// "settings-hooks → contains the himmel marker(s) named in the descriptor" —
// the settings-hooks descriptor shape (manifest-lint.mjs) carries no markers
// field; PRETOOLUSE_MARKERS below is the actual himmel PreToolUse hook
// trio, sourced from wire-pretooluse-hooks.sh's own dedup regex
// (scripts/hooks/(auto-approve-safe-bash|block-edit-on-main|
// block-read-secrets)[.]sh) — the single other place this trio is
// enumerated. Keep both lists in sync if that trio ever changes.
//
// "qmd-index → qmd data/collections dir present + non-empty" — qmd's actual
// on-disk data-dir layout has no stable, documented path anywhere in this
// repo (grepped scripts/lib/qmd-bin.sh and its test suite — confirmed absent
// before writing this). Per the brief's own fallback instruction, this adds
// a thin `has_index` predicate to scripts/lib/qmd-bin.sh (checks `qmd
// collection list` succeeds and is non-empty) and the probe here goes one
// step further, matching the specific collection NAMES the descriptor lists
// against that same `collection list` output (mirroring
// qmd_register_collection's own `^${name}\b` idempotency check) so the
// result is precise instead of a single yes/no.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { which } = require('./helpers.js');

// ── file-exists ──────────────────────────────────────────────────────────

// Himmel-repo-only file-exists items: their descriptor.path is a build/
// tooling artifact adopt.sh's PORTABLE_FILES never copies into any adopted
// target, so it must resolve against ctx.repoRoot even for scope:"project"
// items (jira-cli-dist-build, bitbucket-cli-build are also kind:"dep" — see
// the DEFAULT_DEP_REPO_ROOT rule below, which already covers them; listed
// here too for a single self-contained source of truth). doc-guard-map is
// kind:"wiring" (like guardrail-scope, which IS targetPath-relative), so
// kind alone can't separate them — this is the one genuine exception.
const REPO_ROOT_FILE_EXISTS_IDS = new Set(['jira-cli-dist-build', 'bitbucket-cli-build', 'doc-guard-map']);

function probeFileExists(item, ctx) {
  const raw = item.probe.path;
  if (raw.indexOf('{vaultPath}') !== -1) {
    if (!ctx.targetPath) {
      return { actual: 'absent', detail: 'vaultPath placeholder unresolved: ctx.targetPath is empty' };
    }
    const resolved = path.resolve(raw.replace('{vaultPath}', ctx.targetPath));
    return { actual: fs.existsSync(resolved) ? 'present' : 'absent', detail: resolved };
  }
  const base = (ctx.scope === 'user' || REPO_ROOT_FILE_EXISTS_IDS.has(item.id)) ? ctx.repoRoot : ctx.targetPath;
  const resolved = path.resolve(base, raw);
  return { actual: fs.existsSync(resolved) ? 'present' : 'absent', detail: resolved };
}

// ── settings-key / settings-hooks shared file resolution ────────────────

// Resolve a settings-key/settings-hooks descriptor's `file` against the
// scope-appropriate base. ".env" is special-cased to ALWAYS resolve against
// ctx.repoRoot (both scopes) — see the module header comment. Every other
// file resolves against ctx.targetPath (project scope) or $HOME (user
// scope), matching bin.js's settingsPathForScope().
function resolveConfigFile(file, ctx) {
  if (file === '.env') return path.join(ctx.repoRoot, '.env');
  const home = (ctx.env && ctx.env.HOME) || os.homedir();
  const base = ctx.scope === 'user' ? home : ctx.targetPath;
  return path.join(base, file);
}

function getDotPath(obj, dotPath) {
  return dotPath.split('.').reduce((acc, k) => (acc && typeof acc === 'object' ? acc[k] : undefined), obj);
}

function nonEmpty(v) {
  if (v === undefined || v === null || v === '') return false;
  if (Array.isArray(v)) return v.length > 0;
  if (typeof v === 'object') return Object.keys(v).length > 0;
  return true;
}

// Minimal KEY=VALUE .env parser: skips blank lines/comments, strips a single
// layer of matching quotes. Good enough for the jira-env-keys probe's
// presence check — this never writes or reinterprets the file.
function parseDotEnv(raw) {
  const out = {};
  for (const line of raw.split(/\r?\n/)) {
    const t = line.trim();
    if (!t || t.charAt(0) === '#') continue;
    const eq = t.indexOf('=');
    if (eq === -1) continue;
    const k = t.slice(0, eq).trim();
    let v = t.slice(eq + 1).trim();
    if (v.length >= 2 && ((v[0] === '"' && v[v.length - 1] === '"') || (v[0] === "'" && v[v.length - 1] === "'"))) {
      v = v.slice(1, -1);
    }
    out[k] = v;
  }
  return out;
}

// ── settings-key ─────────────────────────────────────────────────────────

function probeSettingsKey(item, ctx) {
  const filePath = resolveConfigFile(item.probe.file, ctx);
  let raw;
  try {
    raw = fs.readFileSync(filePath, 'utf8');
  } catch (_e) {
    return { actual: 'absent', detail: `cannot read ${filePath}` };
  }
  let data;
  try {
    data = item.probe.file === '.env' ? parseDotEnv(raw) : JSON.parse(raw);
  } catch (_e) {
    return { actual: 'absent', detail: `cannot parse ${filePath}` };
  }
  const keys = item.probe.keys || [item.probe.key];
  const getVal = item.probe.file === '.env' ? (k) => data[k] : (k) => getDotPath(data, k);
  const missing = keys.filter((k) => !nonEmpty(getVal(k)));
  if (missing.length === 0) return { actual: 'present', detail: filePath };
  return { actual: 'absent', detail: `missing/empty key(s) in ${filePath}: ${missing.join(', ')}` };
}

// ── settings-hooks ───────────────────────────────────────────────────────

// The himmel PreToolUse hook trio — see the module header comment for where
// this is otherwise enumerated (wire-pretooluse-hooks.sh's dedup regex).
const PRETOOLUSE_MARKERS = ['auto-approve-safe-bash', 'block-edit-on-main', 'block-read-secrets'];

function collectHookCommands(hooksArray) {
  const commands = [];
  if (!Array.isArray(hooksArray)) return commands;
  for (const stanza of hooksArray) {
    if (stanza && Array.isArray(stanza.hooks)) {
      for (const h of stanza.hooks) {
        if (h && typeof h.command === 'string') commands.push(h.command);
      }
    }
  }
  return commands;
}

function probeSettingsHooks(item, ctx) {
  const filePath = resolveConfigFile(item.probe.file, ctx);
  let data;
  try {
    data = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (_e) {
    return { actual: 'absent', detail: `cannot read/parse ${filePath}` };
  }
  const commands = collectHookCommands(getDotPath(data, item.probe.key));
  const found = PRETOOLUSE_MARKERS.filter((m) => commands.some((c) => c.indexOf(m) !== -1));
  if (found.length === PRETOOLUSE_MARKERS.length) {
    return { actual: 'present', detail: filePath };
  }
  if (found.length === 0) {
    return { actual: 'absent', detail: `no himmel PreToolUse markers found in ${filePath}` };
  }
  const missing = PRETOOLUSE_MARKERS.filter((m) => found.indexOf(m) === -1);
  return { actual: 'degraded', detail: `${found.length}/${PRETOOLUSE_MARKERS.length} himmel PreToolUse markers found in ${filePath} (missing: ${missing.join(', ')})` };
}

// ── shared spawn helper (probe hang guard) ──────────────────────────────

// Bound every spawnSync-based probe (cmd:has_qmd, qmd-index, handover-dir —
// each shells out to bash, which can hang if the sourced resolver script or
// a downstream binary (qmd, bun) wedges): 10s timeout + SIGKILL so a hung
// child can't block `status` forever. r.timedOut is set so callers can
// surface a hang as actual:"degraded" instead of misreading it as a plain
// negative ("absent") probe result.
function spawnProbeSync(cmd, args, opts) {
  const r = spawnSync(cmd, args, Object.assign({ timeout: 10000, killSignal: 'SIGKILL' }, opts));
  r.timedOut = Boolean((r.error && r.error.code === 'ETIMEDOUT') || r.signal);
  return r;
}

// ── cmd:has_qmd ──────────────────────────────────────────────────────────

function probeCmdHasQmd(item, ctx) {
  const resolverPath = path.resolve(ctx.repoRoot, item.probe.resolver);
  const r = spawnProbeSync('bash', ['-c', `. "${resolverPath}" && has_qmd`], { env: ctx.env || process.env });
  if (r.timedOut) return { actual: 'degraded', detail: 'cmd:has_qmd probe timed out after 10s' };
  if (r.error) return { actual: 'absent', detail: `spawn error: ${r.error.message}` };
  return r.status === 0
    ? { actual: 'present', detail: 'has_qmd rc=0' }
    : { actual: 'absent', detail: `has_qmd rc=${r.status}` };
}

// ── qmd-index ────────────────────────────────────────────────────────────

function probeQmdIndex(item, ctx) {
  const resolverPath = path.resolve(ctx.repoRoot, 'scripts/lib/qmd-bin.sh');
  const collections = item.probe.collections;
  const r = spawnProbeSync('bash', ['-c', `. "${resolverPath}" && has_qmd && qmd_cmd collection list`],
    { env: ctx.env || process.env, encoding: 'utf8' });
  if (r.timedOut) return { actual: 'degraded', detail: 'qmd-index probe timed out after 10s' };
  if (r.error || r.status !== 0) {
    return { actual: 'absent', detail: 'qmd absent or collection list failed' };
  }
  const listed = (r.stdout || '').split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  const isListed = (name) => listed.some((l) => l === name || l.indexOf(`${name} `) === 0 || l.indexOf(`${name}\t`) === 0);
  const present = collections.filter(isListed);
  if (present.length === collections.length) {
    return { actual: 'present', detail: `all collections registered: ${collections.join(', ')}` };
  }
  if (present.length === 0) {
    return { actual: 'absent', detail: 'no expected collections registered' };
  }
  const missing = collections.filter((c) => !isListed(c));
  return { actual: 'degraded', detail: `${present.length}/${collections.length} collections registered (missing: ${missing.join(', ')})` };
}

// ── mcp-registered ───────────────────────────────────────────────────────

function probeMcpRegistered(item, ctx) {
  const filePath = path.join((ctx.env && ctx.env.HOME) || os.homedir(), '.claude.json');
  let data;
  try {
    data = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (_e) {
    return { actual: 'absent', detail: `cannot read/parse ${filePath}` };
  }
  // A valid-JSON but non-object root (null, array, string) has no mcpServers —
  // guard before dereferencing so a malformed ~/.claude.json reads absent
  // rather than throwing out of the whole status sweep.
  if (data === null || typeof data !== 'object' || Array.isArray(data)) {
    return { actual: 'absent', detail: `unexpected JSON shape in ${filePath}` };
  }
  const server = item.probe.server;
  if (data.mcpServers && Object.prototype.hasOwnProperty.call(data.mcpServers, server)) {
    return { actual: 'present', detail: filePath };
  }
  return { actual: 'absent', detail: `server '${server}' not registered in ${filePath}` };
}

// ── handover-dir ─────────────────────────────────────────────────────────

function probeHandoverDir(item, ctx) {
  const resolverPath = path.resolve(ctx.repoRoot, item.probe.resolver);
  const cwd = ctx.targetPath || ctx.repoRoot;
  const r = spawnProbeSync('bash', ['-c', `. "${resolverPath}" && handover_root`],
    { env: ctx.env || process.env, cwd, encoding: 'utf8' });
  if (r.timedOut) return { actual: 'degraded', detail: 'handover-dir probe timed out after 10s' };
  if (!r.error && r.status === 0 && r.stdout && r.stdout.trim()) {
    return { actual: 'present', detail: r.stdout.trim() };
  }
  return { actual: 'absent', detail: (r.stderr || '').trim() || 'handover_root did not resolve' };
}

// ── dep ──────────────────────────────────────────────────────────────────

// which() (lib/helpers.js) reads process.env.PATH directly — a hermetic test
// exercises this probe by setting PATH on the OUTER shell invocation (the
// same convention as helpers.js itself and every sibling test-wizard-*.sh
// suite), not by threading ctx.env through.
function probeDep(item, ctx) {
  const cmd = item.probe.cmd || (process.platform === 'win32' ? item.probe.win32 : item.probe.posix);
  const found = which(cmd);
  return found
    ? { actual: 'present', detail: found }
    : { actual: 'absent', detail: `'${cmd}' not found on PATH` };
}

// ── dispatch ─────────────────────────────────────────────────────────────

const PROBES = {
  'file-exists': probeFileExists,
  'settings-key': probeSettingsKey,
  'settings-hooks': probeSettingsHooks,
  'cmd:has_qmd': probeCmdHasQmd,
  'qmd-index': probeQmdIndex,
  'mcp-registered': probeMcpRegistered,
  'handover-dir': probeHandoverDir,
  dep: probeDep,
};

// Run the probe for one manifest item. ctx = { repoRoot, targetPath, scope,
// env }. An unrecognized probe.type (should never happen — manifest-lint.mjs
// gates the manifest itself) reads absent rather than throwing, so a single
// bad item can't abort a whole probe sweep.
function runProbe(item, ctx) {
  const type = item.probe && item.probe.type;
  const fn = PROBES[type];
  if (!fn) return { actual: 'absent', detail: `unknown probe type '${type}'` };
  return fn(item, ctx);
}

module.exports = { runProbe };
