'use strict';
// scripts/himmelctl/lib/probes.js — the himmelctl probe engine (HIMMEL-756
// T1.4, extended HIMMEL-1093 and HIMMEL-1100): one function per probe.type,
// EXACTLY the vocabulary in scripts/install/manifest-lint.mjs's PROBE_TYPES
// (the original eight; cmd:has_hermes / cmd:is_himmel_dev / telegram-access
// added by HIMMEL-1093 to kill three false-greens/tautologies; cmd:codex_
// provisioned / cmd:cadence_armed / cmd:guardrail_block_status /
// cmd:hermes_checkout (round 3) added by HIMMEL-1100 for subsystems the
// harness actively installs/updates that the manifest had never heard of).
// Every probe is a PURE READ (no writes, no prompts, no env mutation)
// returning `{ actual: "present"|"absent"|"degraded", detail: "<string>" }`.
//
// Export: runProbe(item, ctx) where ctx = { repoRoot, targetPath, scope, env }.
// `env` is forwarded (not process.env directly) to every spawned child
// process (cmd:has_qmd, qmd-index, handover-dir, cmd:has_hermes,
// cmd:is_himmel_dev, cmd:cadence_armed, cmd:guardrail_block_status all shell
// out to bash or node), so a hermetic test can hand a fully-controlled env
// object without mutating the real process.env; falls back to process.env
// when ctx.env is omitted. The `dep` probe is the one exception — see its
// function below.
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
// here too for a single self-contained source of truth).
//
// doc-guard-map USED TO be here too (HIMMEL-756), forcing scripts/lib/
// doc-guard-map.sh to always resolve against repoRoot — but that script is
// git-TRACKED, so the probe was tautologically 'present' for every himmel
// checkout regardless of target, detecting nothing (HIMMEL-1093). It now
// uses probe type 'cmd:is_himmel_dev' (below) instead, which checks the
// thing that actually varies: whether the untracked .himmel-dev marker
// (contributor opt-in) is present.
const REPO_ROOT_FILE_EXISTS_IDS = new Set(['jira-cli-dist-build', 'bitbucket-cli-build']);

function probeFileExists(item, ctx) {
  const raw = item.probe.path;
  if (raw.indexOf('{vaultPath}') !== -1) {
    if (!ctx.targetPath) {
      return { actual: 'absent', detail: 'vaultPath placeholder unresolved: ctx.targetPath is empty' };
    }
    const resolved = path.resolve(raw.replace('{vaultPath}', ctx.targetPath));
    return { actual: fs.existsSync(resolved) ? 'present' : 'absent', detail: resolved };
  }
  // {homePath} (HIMMEL-1100): mirrors {vaultPath} for a fixed, known location
  // that is neither repoRoot nor targetPath — a manually-cloned plugin under
  // $HOME (e.g. obsidian-second-brain, cloned by hand per docs/setup/
  // new-machine.md, never copied/scaffolded by any himmel script). Resolves
  // the same way mcpConfigPath()/resolveConfigFile() already do elsewhere in
  // this file: ctx.env.HOME first, else os.homedir().
  if (raw.indexOf('{homePath}') !== -1) {
    const home = (ctx.env && ctx.env.HOME) || os.homedir();
    const resolved = path.resolve(raw.replace('{homePath}', home));
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

// ── telegram-access ──────────────────────────────────────────────────────

// HIMMEL-1093 round 3 (codex-adv-3): telegram-bridge used to be a plain
// settings-key check on TELEGRAM_BOT_TOKEN — green for a bridge that would
// reject every DM/group. scripts/telegram/gate.ts's isAllowed()/
// isAllowedGroup() fail CLOSED: a missing/empty allowFrom AND no groups
// entries means every incoming message is gated out, token notwithstanding.
// This probe deepens the check into its OWN dedicated type (rather than
// bolting Telegram-specific "usable allow rule" semantics onto the generic
// settings-key shape, which has no content-validation concept beyond
// key-presence) — token absent -> 'absent' (unchanged); token present but
// access.json missing/unparseable/with no usable allow rule -> 'degraded'
// (registered but would gate out everything); both satisfied -> 'present'.
function probeTelegramAccess(item, ctx) {
  const envFilePath = resolveConfigFile(item.probe.envFile, ctx);
  let envRaw;
  try {
    envRaw = fs.readFileSync(envFilePath, 'utf8');
  } catch (_e) {
    return { actual: 'absent', detail: `cannot read ${envFilePath}` };
  }
  const env = parseDotEnv(envRaw);
  const token = env[item.probe.tokenKey];
  if (!nonEmpty(token)) {
    return { actual: 'absent', detail: `missing/empty key '${item.probe.tokenKey}' in ${envFilePath}` };
  }

  const accessFilePath = resolveConfigFile(item.probe.accessFile, ctx);
  let accessRaw;
  try {
    accessRaw = fs.readFileSync(accessFilePath, 'utf8');
  } catch (_e) {
    return { actual: 'degraded', detail: `${item.probe.tokenKey} present in ${envFilePath}, but ${accessFilePath} is missing — every DM/group would be gated out` };
  }
  let access;
  try {
    access = JSON.parse(accessRaw);
  } catch (_e) {
    return { actual: 'degraded', detail: `${item.probe.tokenKey} present in ${envFilePath}, but ${accessFilePath} is unparseable — every DM/group would be gated out` };
  }
  const allowFrom = access && typeof access === 'object' && Array.isArray(access.allowFrom) ? access.allowFrom : [];
  const groups = access && typeof access === 'object' && access.groups && typeof access.groups === 'object' && !Array.isArray(access.groups)
    ? access.groups : {};
  const hasAllowFrom = allowFrom.length > 0;
  const hasGroups = Object.keys(groups).length > 0;
  if (!hasAllowFrom && !hasGroups) {
    return { actual: 'degraded', detail: `${item.probe.tokenKey} present in ${envFilePath}, but ${accessFilePath} has no usable allow rule (empty allowFrom and no groups) — every DM/group would be gated out` };
  }
  return { actual: 'present', detail: `${envFilePath} (token) + ${accessFilePath} (${hasAllowFrom ? `${allowFrom.length} allowFrom` : ''}${hasAllowFrom && hasGroups ? ', ' : ''}${hasGroups ? `${Object.keys(groups).length} group(s)` : ''})` };
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

// CR fix (HIMMEL-1017 CR round): SCOPE-AWARE file resolution. Claude Code's
// own `claude mcp add -s <scope>` writes to a DIFFERENT config file per
// scope (graphify-bin.sh's graphify_register_mcp() comment + docs/setup/
// new-machine.md: project scope -> a COMMITTED <target>/.mcp.json;
// user/local scope -> the personal ~/.claude.json) — this probe used to read
// ~/.claude.json UNCONDITIONALLY, so a correctly-registered project-scope
// server (graphify-mcp AND tokensave-mcp both carry scopes:["project",
// "user"]) always read absent. Both files share the same
// `{"mcpServers": {...}}` shape, so the parse/lookup logic below is scope-
// agnostic; only the path differs.
function mcpConfigPath(ctx) {
  if (ctx.scope === 'project') return path.join(ctx.targetPath, '.mcp.json');
  return path.join((ctx.env && ctx.env.HOME) || os.homedir(), '.claude.json');
}

// registeredCommandCheck(command, ctx) -> { ok, reason? } — does a registered
// MCP entry's `command` actually resolve TO SOMETHING EXECUTABLE? A bare name
// goes through which() (PATH-aware, ctx.env-threaded). An absolute path used
// to be fs.existsSync-only (CR fix, HIMMEL-1093 round 5, codex-2): a
// present-but-non-executable file (wrong permissions, a stray non-binary
// dropped at that path) read as usable. POSIX distinguishes the two cases via
// fs.accessSync(path, X_OK) — ENOENT (doesn't exist) vs any other failure
// (typically EACCES, exists but not executable) get different reasons.
// win32 has no exec bit to check (NTFS/ACL "executable" isn't a stat mode
// concept the way POSIX X_OK is) — existsSync is the same signal which()'s
// own win32 extension scan (.exe/.cmd/.bat) already relies on elsewhere in
// this file, so this stays existsSync-only there, unchanged from round 3.
function registeredCommandCheck(command, ctx) {
  if (!path.isAbsolute(command)) {
    return which(command, ctx.env) ? { ok: true } : { ok: false, reason: 'does not resolve' };
  }
  if (process.platform === 'win32') {
    return fs.existsSync(command) ? { ok: true } : { ok: false, reason: 'does not resolve' };
  }
  try {
    fs.accessSync(command, fs.constants.X_OK);
    return { ok: true };
  } catch (e) {
    return e && e.code === 'ENOENT'
      ? { ok: false, reason: 'does not resolve' }
      : { ok: false, reason: 'exists but is not executable' };
  }
}

function probeMcpRegistered(item, ctx) {
  const filePath = mcpConfigPath(ctx);
  let data;
  try {
    data = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (e) {
    // configError: true (CR fix, HIMMEL-1017 round) marks a genuinely BROKEN
    // config — unreadable for a reason other than "it doesn't exist yet", or
    // present-but-unparseable — as opposed to a clean, expected absence. A
    // MISSING file (ENOENT) is the ordinary, common case for project-scope
    // .mcp.json specifically (a committed file that only exists once
    // SOMETHING has been registered at project scope — most projects never
    // have one) — that is exactly "never opted in", not an error, so it does
    // NOT get configError. Any other read failure (permission denied) or a
    // present-but-unparseable file DOES: a consumer that wants to treat
    // "genuinely never opted in" differently from "the config is broken"
    // (status-report.js's graphify-mcp opt-in downgrade) needs this signal;
    // every other existing caller ignores the extra field (additive, not a
    // breaking change to the {actual, detail} contract).
    if (e && e.code === 'ENOENT') {
      return { actual: 'absent', detail: `${filePath} does not exist` };
    }
    return { actual: 'absent', detail: `cannot read/parse ${filePath}`, configError: true };
  }
  // A valid-JSON but non-object root (null, array, string) has no mcpServers —
  // guard before dereferencing so a malformed config reads absent rather
  // than throwing out of the whole status sweep.
  if (data === null || typeof data !== 'object' || Array.isArray(data)) {
    return { actual: 'absent', detail: `unexpected JSON shape in ${filePath}`, configError: true };
  }
  const server = item.probe.server;
  if (!(data.mcpServers && Object.prototype.hasOwnProperty.call(data.mcpServers, server))) {
    return { actual: 'absent', detail: `server '${server}' not registered in ${filePath}` };
  }
  const registered = data.mcpServers[server];
  const problems = [];
  // CR fix (HIMMEL-1093 round 3, codex-adv-1): validate the REGISTERED
  // entry's OWN `command` resolves — not just a descriptor-named `bin`
  // guess, which can name the wrong binary entirely (found live: graphify's
  // registered command is the MCP entrypoint graphify-mcp[.exe], not the
  // bare `graphify` CLI a stale descriptor checked). This runs
  // unconditionally (registration always implies SOME configured command;
  // there's no opt-out) — see registeredCommandCheck() above for the exact
  // resolution rule per platform (absolute path: POSIX checks X_OK, not just
  // existence — round 5, codex-2; win32 stays existsSync-only; bare name:
  // which() against ctx.env, same PATH-aware resolution `bin` uses).
  const command = registered && typeof registered === 'object' ? registered.command : undefined;
  if (!command || typeof command !== 'string') {
    problems.push('registered entry carries no usable command');
  } else {
    const check = registeredCommandCheck(command, ctx);
    if (!check.ok) problems.push(`registered command '${command}' ${check.reason}`);
  }
  // HIMMEL-1093: registration alone is not proof the server works — a
  // registered-but-broken MCP entry (pointed at a project that was never
  // initialized) used to read the same 'present' as a genuinely working
  // one. `initMarker` — a path, relative to ctx.targetPath, that must
  // exist, proving the CONSUMING project is actually initialized (e.g.
  // tokensave-mcp is registered-but-useless without a `.tokensave/` project
  // graph) — is an OPTIONAL descriptor field, opt-in per item; a probe
  // naming none keeps the registered-command check as the only deepening.
  // `bin` (a descriptor-named binary that must resolve on PATH, independent
  // of what's actually registered) is ALSO still supported for an item
  // where it adds real signal beyond the registered-command check (e.g.
  // tokensave-mcp — its registered command already happens to be the same
  // tokensave binary, but `bin` catches a PATH-vs-registered-path mismatch
  // the registered-command check alone wouldn't); graphify-mcp's `bin` was
  // dropped from the manifest in this same round precisely because it was
  // checking the WRONG (unrelated) binary and the registered-command check
  // now covers it correctly — see manifest.json's graphify-mcp comment.
  // Any gap downgrades to 'degraded' — registered, but not actually usable
  // — never silently 'present'.
  if (item.probe.bin && !which(item.probe.bin, ctx.env)) {
    problems.push(`binary '${item.probe.bin}' not resolvable on PATH`);
  }
  if (item.probe.initMarker) {
    const markerPath = ctx.targetPath ? path.resolve(ctx.targetPath, item.probe.initMarker) : null;
    if (!markerPath || !fs.existsSync(markerPath)) {
      problems.push(`project not initialized: '${item.probe.initMarker}' not found` + (ctx.targetPath ? ` under ${ctx.targetPath}` : ''));
    }
  }
  if (problems.length > 0) {
    return { actual: 'degraded', detail: `registered in ${filePath}, but ${problems.join('; ')}` };
  }
  return { actual: 'present', detail: filePath };
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

// ── cmd:has_hermes ───────────────────────────────────────────────────────

// HIMMEL-1093: hermes-lanes used to be a file-exists probe on scripts/lanes/
// lanes.json — a git-TRACKED registry file, so it read 'present' on every
// himmel checkout regardless of whether hermes is actually installed on the
// machine, detecting nothing. hermes is a venv-based install with no bare
// binary on PATH (docs/hermes-runbook.md); scripts/lib/resolve-hermes-py.sh
// is the ONE canonical resolver (HIMMEL-613) — source it and call
// resolve_hermes_py, mirroring probeCmdHasQmd's exact shape.
//
// CR fix (HIMMEL-1093 round 4): this branch INTRODUCED the probe, so it
// ships with the same fix probeCmdIsHimmelDev already got in round 2 rather
// than repeating the bug — a genuine probe-WIRING failure must never
// collapse into 'absent' (this manifest item has no opt-in n/a downgrade
// today, but conflating "hermes isn't installed" with "the probe itself is
// broken" is misleading regardless, and a future downgrade — mirroring
// graphify-mcp/doc-guard-map's pattern — would inherit the same hole if
// added later). Mirrors probeCmdIsHimmelDev exactly: spawn error ->
// 'degraded', not 'absent'; `. resolver || exit 3; resolve_hermes_py`
// disambiguates rc 3 (resolver failed to SOURCE — missing/unreadable
// resolve-hermes-py.sh, probe wiring broken) -> 'degraded' from
// resolve_hermes_py's own nonzero (sourced fine, hermes genuinely not
// installed — the ordinary case) -> 'absent'.
//
// CR fix (HIMMEL-1093 round 6, codex-1): the resolver PATH used to be
// STRING-INTERPOLATED into the `bash -c` command (`. "${resolverPath}" ||
// ...`) — a checkout path containing a double quote breaks out of the
// quoting entirely. Fixed structurally, not by escaping: the path travels
// via the spawned process's OWN env (HIMMEL_PROBE_RESOLVER), and the `-c`
// command is now a CONSTANT string that only ever references it through a
// shell variable expansion, which bash itself quotes safely regardless of
// what the path contains.
//
// CR fix (HIMMEL-1093 round 6, codex-2): rc mapping now covers EVERY status,
// not just the three named ones — an UNEXPECTED rc (e.g. 127, the resolver
// sourced fine but doesn't define resolve_hermes_py — a stale/mismatched
// resolver) used to fall into the same 'absent' as resolve_hermes_py's own
// clean "not installed" answer (rc 1). An unexpected rc is a WIRING signal,
// never a clean no, so it now reads 'degraded' with the rc named.
function probeCmdHasHermes(item, ctx) {
  const resolverPath = path.resolve(ctx.repoRoot, item.probe.resolver);
  const env = Object.assign({}, ctx.env || process.env, { HIMMEL_PROBE_RESOLVER: resolverPath });
  const r = spawnProbeSync('bash', ['-c', '. "$HIMMEL_PROBE_RESOLVER" || exit 3; resolve_hermes_py >/dev/null'], { env });
  if (r.timedOut) return { actual: 'degraded', detail: 'cmd:has_hermes probe timed out after 10s' };
  if (r.error) return { actual: 'degraded', detail: `spawn error: ${r.error.message}` };
  if (r.status === 0) return { actual: 'present', detail: 'hermes venv python resolved (resolve_hermes_py rc=0)' };
  if (r.status === 1) return { actual: 'absent', detail: 'resolve_hermes_py rc=1 — hermes not installed' };
  if (r.status === 3) return { actual: 'degraded', detail: `cannot source resolver ${resolverPath} — cmd:has_hermes probe wiring broken` };
  return { actual: 'degraded', detail: `resolve_hermes_py: unexpected rc=${r.status} (not the documented 0/1 — probe wiring likely broken, e.g. the resolver sourced but never defined resolve_hermes_py)` };
}

// ── cmd:is_himmel_dev ────────────────────────────────────────────────────

// HIMMEL-1093: doc-guard-map used to be a file-exists probe on scripts/lib/
// doc-guard-map.sh, forced to always resolve against repoRoot — but that
// script is git-TRACKED, so it read 'present' on every himmel checkout,
// tautologically, detecting nothing. The thing that actually varies is
// whether doc-guard is genuinely WIRED for this operator: it is gated
// end-to-end by the untracked, gitignored .himmel-dev marker (contributor
// opt-in — scripts/guardrails/lib.sh's is_himmel_dev_repo(), which is itself
// worktree-aware, resolving to the PRIMARY checkout's marker). Always probed
// against ctx.repoRoot (not ctx.targetPath) — this is a fact about the
// RUNNING himmel installation, same self-referential shape as
// jira-cli-dist-build/bitbucket-cli-build, not about whatever project is
// being adopted.
//
// CR fix (HIMMEL-1093 round 2, codex-1): a genuine probe-WIRING failure must
// never collapse into 'absent' — status-report.js's doc-guard-map handler
// downgrades a clean 'absent' to a friendly "opt-in, gate off" n/a, so a
// broken probe used to read as "gate off by choice" instead of surfacing a
// real problem. Two holes this closes:
//   (a) a spawn error (bash itself unresolvable) now reads 'degraded', not
//       'absent'.
//   (b) `. resolver && is_himmel_dev_repo` conflated "resolver failed to
//       source" (missing/unreadable lib.sh — rc from `.` itself) with
//       "sourced fine, marker genuinely absent" (is_himmel_dev_repo's own
//       rc 1) — both surfaced as the SAME rc 1. `. resolver || exit 3;
//       is_himmel_dev_repo` disambiguates: rc 3 = sourcing failed (probe
//       wiring broken) -> degraded; rc 1 = is_himmel_dev_repo's own "not a
//       dev checkout" -> absent (still the common, legitimate case,
//       downgraded to n/a by status-report.js's opt-in handling, same
//       pattern as graphify-mcp); rc 2 = is_himmel_dev_repo resolved but
//       could not resolve the repo root at all (a genuine problem) ->
//       degraded; rc 0 = marker present -> present.
//
// CR fix (HIMMEL-1093 round 6, codex-1): the resolver PATH used to be
// STRING-INTERPOLATED into the `bash -c` command — a checkout path
// containing a double quote breaks out of the quoting. Fixed structurally
// (not by escaping): the path travels via the spawned process's OWN env
// (HIMMEL_PROBE_RESOLVER), and the `-c` command is now a CONSTANT string
// that only ever references it through a shell variable expansion.
//
// CR fix (HIMMEL-1093 round 6, codex-2): rc mapping now covers EVERY
// status — an UNEXPECTED rc (e.g. 127, the resolver sourced fine but
// doesn't define is_himmel_dev_repo — a stale/mismatched resolver) used to
// fall into the same 'absent' as is_himmel_dev_repo's own clean "not a dev
// checkout" answer (rc 1), which status-report.js's opt-in handler then
// downgrades to a friendly n/a — exactly the false-quiet a wiring failure
// must never get. An unexpected rc is a WIRING signal, never a clean no, so
// it now reads 'degraded' with the rc named.
function probeCmdIsHimmelDev(item, ctx) {
  const resolverPath = path.resolve(ctx.repoRoot, item.probe.resolver);
  const env = Object.assign({}, ctx.env || process.env, { HIMMEL_PROBE_RESOLVER: resolverPath });
  const r = spawnProbeSync('bash', ['-c', '. "$HIMMEL_PROBE_RESOLVER" || exit 3; is_himmel_dev_repo'], { env, cwd: ctx.repoRoot });
  if (r.timedOut) return { actual: 'degraded', detail: 'cmd:is_himmel_dev probe timed out after 10s' };
  if (r.error) return { actual: 'degraded', detail: `spawn error: ${r.error.message}` };
  if (r.status === 0) return { actual: 'present', detail: '.himmel-dev marker present — doc-guard gate active' };
  if (r.status === 1) return { actual: 'absent', detail: 'not a himmel-dev checkout (.himmel-dev marker absent) — doc-guard gate off' };
  if (r.status === 2) return { actual: 'degraded', detail: 'is_himmel_dev_repo: cannot resolve repo root' };
  if (r.status === 3) return { actual: 'degraded', detail: `cannot source resolver ${resolverPath} — doc-guard probe wiring broken` };
  return { actual: 'degraded', detail: `is_himmel_dev_repo: unexpected rc=${r.status} (not the documented 0/1/2 — probe wiring likely broken, e.g. the resolver sourced but never defined is_himmel_dev_repo)` };
}

// ── cmd:codex_provisioned ────────────────────────────────────────────────

// HIMMEL-1100: codex CLI + companion — a "fully automated subsystem" per
// himmel-update.sh's update_codex() (re-syncs plugins + sanitizes hooks.json
// on EVERY /himmel-update) had ZERO manifest presence at all. Pure JS, no
// spawn: mirrors update_codex()'s/install-himmel-codex.sh's own resolve_codex()
// precedence EXACTLY — CODEX_BIN override (hard error if set-but-unusable, no
// silent PATH fallback) else bare `codex` on PATH — reusing
// registeredCommandCheck() (HIMMEL-1093 round 5) for the same executable-aware
// resolution the mcp-registered command check already gets. Binary resolvable
// is NOT the same as "provisioned" (same false-green class HIMMEL-1093 killed
// for tokensave-mcp): update_codex() itself treats a binary with no
// `$CODEX_HOME/plugins/cache` dir as "never provisioned, skip" — so this probe
// checks BOTH and downgrades to 'degraded' (not silently 'present') when the
// binary resolves but the cache doesn't exist, naming the install command.
function probeCmdCodexProvisioned(item, ctx) {
  const env = ctx.env || process.env;
  const command = env.CODEX_BIN || 'codex';
  const check = registeredCommandCheck(command, ctx);
  if (!check.ok) {
    return {
      actual: 'absent',
      detail: env.CODEX_BIN
        ? `CODEX_BIN set but ${check.reason}: ${command}`
        : `'codex' ${check.reason} on PATH`,
    };
  }
  // CR fix (HIMMEL-1100 round 2, codex-1): resolve HOME/CODEX_HOME from
  // ctx.env, not the real process (os.homedir()) — a hermetic/user-targeted
  // caller with a fully-controlled ctx.env otherwise got the WRONG home
  // (same hermeticity class as which()'s HIMMEL-1093 round-5 fix). Key
  // PRESENCE, not truthiness, decides the source (mirrors which()'s own
  // `'PATH' in e` discipline): env.CODEX_HOME wins whenever the key is
  // present at all (an operator-set empty string is still a deliberate
  // value, not "unset"); only a genuinely ABSENT key falls through to
  // env.HOME, and only an absent HOME falls through to the real
  // os.homedir() (the last-resort default when no env carries either).
  const home = ('HOME' in env) ? env.HOME : os.homedir();
  const codexHome = ('CODEX_HOME' in env) ? env.CODEX_HOME : path.join(home, '.codex');
  // CodeRabbit fix (HIMMEL-1100 round 6, coderabbit-1): an empty-string
  // env.HOME/env.CODEX_HOME (key PRESENT, value '' — a real shape, not just
  // a test artifact: some shells export a var empty rather than unsetting
  // it) makes codexHome a RELATIVE path via path.join('', ...) — existsSync
  // would then resolve it against the CURRENT PROCESS's cwd, an entirely
  // wrong and non-hermetic answer. Guard explicitly rather than let a
  // relative path silently probe the wrong location.
  if (!path.isAbsolute(codexHome)) {
    return { actual: 'degraded', detail: `codex CLI resolved (${command}), but CODEX_HOME resolved to a non-absolute path ('${codexHome}') — cannot locate the plugin cache` };
  }
  const cacheDir = path.join(codexHome, 'plugins', 'cache');
  if (!fs.existsSync(cacheDir)) {
    return {
      actual: 'degraded',
      detail: `codex CLI resolved (${command}) but never provisioned — no plugin cache at ${cacheDir} (run scripts/codex/install-himmel-codex.sh)`,
    };
  }
  // CR fix (HIMMEL-1100 round 3, codex-adv-2): ANY plugins/cache dir —
  // even an empty one, which codex itself can create lazily on first launch
  // regardless of whether ANY himmel plugin was ever registered — used to
  // read 'present'. The genuine himmel-specific marker is a cache entry for
  // the HIMMEL marketplace itself: install-himmel-codex.sh registers it
  // under the fixed name `MARKET="himmel"` (`codex plugin marketplace add
  // "$MARKET_PATH"`), and every enabled plugin caches under
  // `<cache>/himmel/<plugin>/<version>` — verified live on this machine
  // (~/.codex/plugins/cache/himmel/{handover,himmel-ops,...}). A cache dir
  // with entries for OTHER marketplaces only (openai-bundled,
  // claude-plugins-official, ...) but no `himmel/` subdir, or an empty
  // `himmel/` subdir, means codex itself is used but the himmel companion
  // specifically was never provisioned — 'degraded', not 'present'.
  const himmelCacheDir = path.join(cacheDir, 'himmel');
  let himmelEntries;
  try {
    himmelEntries = fs.readdirSync(himmelCacheDir);
  } catch (_e) {
    himmelEntries = [];
  }
  if (himmelEntries.length === 0) {
    return {
      actual: 'degraded',
      detail: `codex present, but the himmel companion is not provisioned — no himmel-marketplace plugin cache at ${himmelCacheDir} (run scripts/codex/install-himmel-codex.sh)`,
    };
  }
  return { actual: 'present', detail: `${command} resolved; himmel plugin cache: ${himmelCacheDir} (${himmelEntries.length} plugin(s))` };
}

// ── cmd:hermes_checkout ──────────────────────────────────────────────────

// HIMMEL-1100 round 3 (codex-adv-3): hermes-checkout used to reuse
// cmd:has_hermes — that probe proves a USABLE venv python (and honors
// HERMES_PY), which is the right runtime-health check for hermes-lanes, but
// it is NOT the same fact update_hermes() (himmel-update.sh:114-186) cares
// about: whether the SOURCE CHECKOUT it git-pulls actually exists and is
// genuinely a NousResearch/hermes-agent clone (update_hermes() silently
// SKIPS any checkout that isn't, per its own remote-url grep). A checkout
// with a broken/rebuilt venv (cmd:has_hermes reads absent) can still be a
// perfectly valid checkout update_hermes will happily pull; conversely a
// working venv (cmd:has_hermes reads present) proves nothing about whether
// update_hermes will ever touch it. Pure fs, no git spawn (per the finding's
// own instruction): resolves the IDENTICAL root/src update_hermes() itself
// derives, then reads .git/config directly for the origin remote's url —
// the same information `git remote get-url origin` would report, without
// spawning git.
//
// Resolution mirrors update_hermes()'s bash `${VAR:-default}` (empty-OR-
// unset falls to the default) rather than the presence-only discipline used
// elsewhere in this file (HIMMEL-1100 round 2) — deliberately: the goal
// here is byte-for-byte PARITY with what update_hermes() itself resolves,
// not this probe's own ctx.env hermeticity, and bash's `:-` operator treats
// an empty override the same as an absent one.
function gitConfigOriginUrl(gitDir) {
  let raw;
  try {
    raw = fs.readFileSync(path.join(gitDir, 'config'), 'utf8');
  } catch (_e) {
    return null;
  }
  let inOrigin = false;
  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (/^\[remote "origin"\]$/i.test(trimmed)) { inOrigin = true; continue; }
    if (/^\[/.test(trimmed)) { inOrigin = false; continue; }
    if (inOrigin) {
      const m = trimmed.match(/^url\s*=\s*(.+)$/i);
      if (m) return m[1].trim();
    }
  }
  return null;
}

// CR fix (HIMMEL-1100 round 4, codex-1): the origin check used to be a bare
// substring match (`originUrl.indexOf('NousResearch/hermes-agent') !== -1`)
// — `git@github.com:evil/NousResearch-hermes-agent-mirror.git` contains that
// exact substring and would have false-greened. Extracts the OWNER/REPO
// path from either ssh (git@github.com:owner/repo[.git], also ssh://…) or
// https (https://github.com/owner/repo[.git]) forms and requires an EXACT
// (case-insensitive) match — a spoofed owner or repo name, even one that
// merely CONTAINS the real name, no longer matches.
// CodeRabbit fix (HIMMEL-1100 round 6, coderabbit-2): the single combined
// regex rejected a valid ssh URL carrying an explicit port
// (ssh://git@github.com:22/owner/repo.git — a normal, real-world form),
// false-degrading it. Split into three explicit forms so the port can be
// scoped to EXACTLY the one place it's syntactically valid: the ssh://
// (URL) form. The scp-like syntax (git@github.com:owner/repo) has no port
// syntax in real git usage, so it stays unchanged; https never carries a
// port for github.com. None of the three broadens HOST matching — every
// branch still requires the literal `github.com` hostname, never an ssh
// config alias.
function parseGitHubOwnerRepo(url) {
  if (typeof url !== 'string') return null;
  const trimmed = url.trim();
  let m = trimmed.match(/^ssh:\/\/(?:[^@/\s]+@)?github\.com(?::\d+)?\/([^/\s]+)\/([^/\s]+?)(?:\.git)?\/?$/i);
  if (m) return `${m[1]}/${m[2]}`;
  m = trimmed.match(/^https?:\/\/github\.com\/([^/\s]+)\/([^/\s]+?)(?:\.git)?\/?$/i);
  if (m) return `${m[1]}/${m[2]}`;
  m = trimmed.match(/^(?:[^@/\s]+@)?github\.com:([^/\s]+)\/([^/\s]+?)(?:\.git)?\/?$/i);
  if (m) return `${m[1]}/${m[2]}`;
  return null;
}

function isDirSync(p) {
  try {
    return fs.statSync(p).isDirectory();
  } catch (_e) {
    return false;
  }
}

// readWorktreeCommonOriginUrl(gitDir) — CR fix (HIMMEL-1100 round 5,
// codex-1): for a NORMAL linked worktree, the gitlink's resolved dir
// (.git/worktrees/<name>/) carries no remotes of its own — remotes live in
// the COMMON dir's config, which the worktree's OWN dir points to via a
// `commondir` file (a path, typically relative like `../..`). Without this,
// a worktree hermes checkout — a perfectly legitimate install shape — read
// falsely degraded. Bounded to ONE level of indirection (matches
// resolveGitConfigDir's own gitdir: bound): relative paths resolve against
// gitDir (per git's own commondir contract); a missing commondir file, an
// unresolvable target, or a target with no origin either all return null
// (the caller's existing "no origin" degraded path, unchanged).
function readWorktreeCommonOriginUrl(gitDir) {
  let raw;
  try {
    raw = fs.readFileSync(path.join(gitDir, 'commondir'), 'utf8');
  } catch (_e) {
    return null;
  }
  const commonDirRaw = raw.trim();
  if (!commonDirRaw) return null;
  const commonDir = path.isAbsolute(commonDirRaw) ? commonDirRaw : path.resolve(gitDir, commonDirRaw);
  if (!isDirSync(commonDir)) return null;
  return gitConfigOriginUrl(commonDir);
}

// hasDotGitEntry(dir) — true when <dir>/.git exists as EITHER a directory
// (a normal checkout) OR a file (CR fix, round 4, codex-2: a WORKTREE or
// SUBMODULE checkout, where .git is a "gitdir: <path>" pointer file, not a
// directory) — both count as "this looks like a git checkout" for the
// src-selection fallback below.
function hasDotGitEntry(dir) {
  try {
    fs.statSync(path.join(dir, '.git'));
    return true;
  } catch (_e) {
    return false;
  }
}

// resolveGitConfigDir(dotGitPath) — resolve the REAL directory containing
// `config` for a `.git` entry that may be a plain directory OR a gitlink
// FILE ("gitdir: <path>", worktrees/submodules — round 4, codex-2). Returns:
//   null              — no .git entry at all (caller reads this as absent).
//   { error: reason } — a .git entry EXISTS but the real git dir could not
//                       be resolved from it (unreadable gitlink, no
//                       `gitdir:` line, or the pointer target itself is
//                       missing) — bounded to ONE level of indirection,
//                       never crashes; caller reads this as degraded (a
//                       checkout genuinely IS there, just unverifiable).
//   { dir: path }     — resolved successfully; safe to read <dir>/config.
function resolveGitConfigDir(dotGitPath) {
  let st;
  try {
    st = fs.statSync(dotGitPath);
  } catch (_e) {
    return null;
  }
  if (st.isDirectory()) return { dir: dotGitPath };
  if (st.isFile()) {
    let content;
    try {
      content = fs.readFileSync(dotGitPath, 'utf8');
    } catch (_e) {
      return { error: `cannot read gitlink file ${dotGitPath}` };
    }
    const m = content.match(/^gitdir:\s*(.+?)\s*$/m);
    if (!m) return { error: `${dotGitPath} does not contain a gitdir: pointer` };
    let target = m[1].trim();
    if (!path.isAbsolute(target)) target = path.resolve(path.dirname(dotGitPath), target);
    if (!isDirSync(target)) return { error: `gitdir: pointer target does not exist: ${target}` };
    return { dir: target };
  }
  return { error: `${dotGitPath} is neither a directory nor a file` };
}

function probeCmdHermesCheckout(item, ctx) {
  const env = ctx.env || process.env;
  // Mirrors update_hermes()'s own root/src resolution EXACTLY
  // (himmel-update.sh:139-147): HERMES_HOME override, else
  // ${LOCALAPPDATA:-$HOME/AppData/Local}/hermes; src = root/hermes-agent,
  // falling back to root itself when THAT carries .git instead (tolerates
  // HERMES_HOME pointing straight at the checkout).
  const home = env.HOME || os.homedir();
  const localAppData = env.LOCALAPPDATA || path.join(home, 'AppData', 'Local');
  const root = env.HERMES_HOME || path.join(localAppData, 'hermes');
  let src = path.join(root, 'hermes-agent');
  if (!hasDotGitEntry(src) && hasDotGitEntry(root)) {
    src = root;
  }
  const dotGitPath = path.join(src, '.git');
  const resolved = resolveGitConfigDir(dotGitPath);
  if (!resolved) {
    return { actual: 'absent', detail: `hermes not installed as a git checkout (${src}) — see docs/hermes-runbook.md` };
  }
  if (resolved.error) {
    return { actual: 'degraded', detail: `${dotGitPath} exists but ${resolved.error} — cannot verify the checkout's origin` };
  }
  // CR fix (HIMMEL-1100 round 5, codex-1): try the resolved dir's own config
  // first; a NORMAL worktree's dir carries no remotes, so fall back to the
  // commondir-pointed dir (readWorktreeCommonOriginUrl) ONE level.
  const originUrl = gitConfigOriginUrl(resolved.dir) || readWorktreeCommonOriginUrl(resolved.dir);
  const parsed = parseGitHubOwnerRepo(originUrl);
  if (!parsed || parsed.toLowerCase() !== 'nousresearch/hermes-agent') {
    return {
      actual: 'degraded',
      detail: `${src} exists but is not a NousResearch/hermes-agent checkout (origin: ${originUrl || 'unreadable'}) — update_hermes() will silently skip it`,
    };
  }
  return { actual: 'present', detail: `${src} (origin: ${originUrl})` };
}

// ── cmd:cadence_armed ────────────────────────────────────────────────────

// HIMMEL-1100: the three scheduled cadence runners (pipeline-cadence,
// codex-sweep-cadence, graphmap-cadence) have dedicated staleness detection
// in himmel-update.sh (report_cadence_stale) but zero manifest presence — the
// manifest can't even say whether one is ARMED, let alone stale. This probe
// covers the armed-vs-not question only; staleness stays advisory (the
// himmel-update nudge), per the ticket's own scoping.
//
// Reuses scripts/lib/cadence-format.sh's cadence_runner_stamp() — the SAME
// function report_cadence_stale() itself calls — rather than re-deriving the
// armed/not-armed answer a second way. rc 0 = at least one runner present
// (armed); rc 1 = cadence_runner_stamp's own clean "no runners" (not armed —
// arming is always an explicit, one-time `arm` operator action, never part of
// setup.sh/adopt.sh's automatic install path).
//
// Structural env-passing (HIMMEL-1093 round 6, codex-1 lesson applied
// proactively): the resolver path, the override env-var NAME, and the
// default subdir all travel via the spawned process's OWN env — never
// interpolated into the `-c` command string, which is a CONSTANT. The
// override var name is resolved via bash indirect expansion (`${!VAR}`),
// not `eval`, so no part of the descriptor or the resolved value is ever
// re-parsed as shell syntax.
function probeCmdCadenceArmed(item, ctx) {
  const resolverPath = path.resolve(ctx.repoRoot, item.probe.resolver);
  const env = Object.assign({}, ctx.env || process.env, {
    HIMMEL_PROBE_RESOLVER: resolverPath,
    HIMMEL_CADENCE_ENV_VAR: item.probe.envVar,
    HIMMEL_CADENCE_DEFAULT_SUBDIR: item.probe.defaultSubdir,
  });
  // CodeRabbit fix (HIMMEL-1100 round 6, coderabbit-3): cadence_runner_stamp
  // itself returns rc 1 for BOTH "no runner armed" (the dir doesn't exist,
  // or exists and is empty of runners) AND "the dir exists but couldn't be
  // read" (its own `[ -f "$dir/$name.$ext" ]` checks fail silently on a
  // permission-denied dir, same as "not found") — the absent-vs-degraded
  // conflation again. A MISSING dir needs no special-casing here: every
  // `-f` check is already false against a nonexistent path, so
  // cadence_runner_stamp's natural rc 1 already means "genuinely unarmed"
  // (unchanged). Only an EXISTING-but-unreadable dir is pre-checked and
  // mapped to a DISTINCT exit code (4) below, kept out of cadence_runner_
  // stamp's own rc 0/1 vocabulary entirely.
  const cmd = '. "$HIMMEL_PROBE_RESOLVER" || exit 3; '
    + 'dir="${!HIMMEL_CADENCE_ENV_VAR:-$(cadence_user_home)/$HIMMEL_CADENCE_DEFAULT_SUBDIR}"; '
    + 'if [ -d "$dir" ] && [ ! -r "$dir" ]; then exit 4; fi; '
    + 'cadence_runner_stamp "$dir" >/dev/null';
  const r = spawnProbeSync('bash', ['-c', cmd], { env });
  if (r.timedOut) return { actual: 'degraded', detail: 'cmd:cadence_armed probe timed out after 10s' };
  if (r.error) return { actual: 'degraded', detail: `spawn error: ${r.error.message}` };
  if (r.status === 0) return { actual: 'present', detail: `armed (a runner is present under ${item.probe.envVar || 'the default cadence dir'})` };
  if (r.status === 1) return { actual: 'absent', detail: 'not armed — no runner files found (opt-in, arm to enable)' };
  if (r.status === 3) return { actual: 'degraded', detail: `cannot source resolver ${resolverPath} — cmd:cadence_armed probe wiring broken` };
  if (r.status === 4) return { actual: 'degraded', detail: 'cadence dir exists but is not readable — cannot determine whether it is armed' };
  return { actual: 'degraded', detail: `cadence_runner_stamp: unexpected rc=${r.status} (probe wiring likely broken)` };
}

// ── cmd:guardrail_block_status ───────────────────────────────────────────

// HIMMEL-1100: the user-scope guardrail block (scripts/hooks/
// guardrail-block.mjs — DISTINCT from the project-scope guardrail-scope item)
// has its own drift check in himmel-update.sh (report_guardrail_block) but
// zero manifest presence. Spawns node directly with an ARGV ARRAY (not
// `bash -c` + string command) — no shell involved at all, so there is no
// quoting/interpolation surface to get wrong in the first place. Parses the
// script's own `guardrail-mode=<mode> node-resolves=<yes|no>` stdout (the
// same status line report_guardrail_block already prints) rather than
// re-implementing detectMode()/nodeResolves() a second way.
//   mode=project              -> 'absent' (never armed globally — the
//                                ordinary default; global mode is an explicit
//                                `setup-hooks.sh --guardrail-mode global` opt-in,
//                                never part of the automatic install path).
//   mode=global, resolves=yes -> 'present'.
//   mode=global, resolves=no  -> 'degraded' (armed but the baked node path
//                                rotted — exactly the drift report_guardrail_
//                                block itself exists to catch).
//   anything else (nonzero exit, unparseable stdout) -> 'degraded'.
function probeGuardrailBlockStatus(item, ctx) {
  const scriptPath = path.resolve(ctx.repoRoot, item.probe.script);
  const r = spawnProbeSync(process.execPath, [scriptPath, 'status'], { env: ctx.env || process.env, encoding: 'utf8' });
  if (r.timedOut) return { actual: 'degraded', detail: 'cmd:guardrail_block_status probe timed out after 10s' };
  if (r.error) return { actual: 'degraded', detail: `spawn error: ${r.error.message}` };
  if (r.status !== 0) {
    const stderr = (r.stderr || '').trim();
    return { actual: 'degraded', detail: `guardrail-block.mjs status exited rc=${r.status}${stderr ? `: ${stderr}` : ''}` };
  }
  const out = (r.stdout || '').trim();
  const modeMatch = out.match(/guardrail-mode=(\S+)/);
  const resolvesMatch = out.match(/node-resolves=(\S+)/);
  if (!modeMatch) return { actual: 'degraded', detail: `guardrail-block.mjs status produced unparseable output: ${out || '(empty)'}` };
  const mode = modeMatch[1];
  if (mode !== 'global') return { actual: 'absent', detail: out };
  // CR fix (HIMMEL-1100 round 2, glm-3): a MISSING node-resolves field is
  // not proof of resolution — it used to fall through to 'present' (the
  // `resolves === 'no'` check is simply false for null). An absent field
  // means the script's output shape changed/broke, which is a wiring
  // problem, not a confirmed-working global-mode install.
  if (!resolvesMatch) return { actual: 'degraded', detail: `${out} — missing 'node-resolves' field in guardrail-block.mjs status output` };
  if (resolvesMatch[1] === 'no') return { actual: 'degraded', detail: `${out} — global mode armed but the baked node path no longer resolves` };
  // CR fix (HIMMEL-1100 round 3, codex-adv-1, bounded to status output
  // alone — no rewrite of guardrail-block.mjs, no reading settings.json
  // around it): guardrail-block.mjs's own `status` verb declares
  // mode=global whenever ANY owned hook exists at all (detectMode: `.some`
  // over every group — one hit is enough) and derives node-resolves from
  // ONLY the FIRST owned hook it iterates to (nodeResolves returns inside
  // its loop on first match). It never counts or enumerates the 3 expected
  // guardrail hooks (auto-approve-safe-bash.sh / block-edit-on-main.sh /
  // block-read-secrets.sh — GUARDRAILS in guardrail-block.mjs). So
  // "mode=global, node-resolves=yes" proves only "at least one guardrail
  // hook is wired and ITS OWN node path resolves" — a partial install (1 of
  // 3 wired, the other two missing or pointing at dead paths) is
  // INDISTINGUISHABLE from a complete one using this output alone; status
  // exposes no per-hook data to deepen against (self-verified: this file's
  // own tests construct exactly that 1-hook fixture and it read 'present'
  // before this fix). 'present' therefore claims MORE than status output
  // can honestly attest, so it is never reached from a real armed reading —
  // every mode=global case reads 'degraded' until guardrail-block.mjs grows
  // a richer verb (e.g. `status --json` enumerating each expected hook's
  // own resolution), which would let this branch trust a genuine "all 3
  // present and resolving" answer the way handover-dir/qmd-index already
  // trust THEIR CLI's own richer output. Filed as a follow-up rather than
  // built here (bounded scope for this round).
  return { actual: 'degraded', detail: `${out} — global mode armed, but guardrail-block.mjs's status verb cannot confirm all 3 guardrail hooks are wired (only that at least one is, and its own node path resolves); a richer status verb is needed to verify completeness` };
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
  'cmd:has_hermes': probeCmdHasHermes,
  'cmd:is_himmel_dev': probeCmdIsHimmelDev,
  'telegram-access': probeTelegramAccess,
  'cmd:codex_provisioned': probeCmdCodexProvisioned,
  'cmd:cadence_armed': probeCmdCadenceArmed,
  'cmd:guardrail_block_status': probeGuardrailBlockStatus,
  'cmd:hermes_checkout': probeCmdHermesCheckout,
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

// parseDotEnv is also exported for reuse (HIMMEL-755): install-engine.js's
// HIMMELCTL_SUDO_PASSWORD resolution reads the primary checkout's .env with
// this SAME minimal parser rather than writing a second one.
module.exports = { runProbe, parseDotEnv };
