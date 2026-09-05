'use strict';
// scripts/himmelctl/lib/probes.js — the himmelctl probe engine (HIMMEL-756
// T1.4, extended HIMMEL-1093 and HIMMEL-1100): one function per probe.type,
// EXACTLY the vocabulary in scripts/install/manifest-lint.mjs's PROBE_TYPES
// (the original eight; cmd:has_hermes / cmd:is_himmel_dev / telegram-access
// added by HIMMEL-1093 to kill three false-greens/tautologies; cmd:codex_
// provisioned / cmd:cadence_armed / cmd:guardrail_block_status /
// cmd:hermes_checkout (round 3) added by HIMMEL-1100 for subsystems the
// harness actively installs/updates that the manifest had never heard of;
// cmd:telegram_getme / cmd:whisper_ready / cmd:python_interpreter /
// distinct-tokens / luna-sources added by HIMMEL-2176 Task 6 — externalization
// Stage 1's bridge + toolchain probes: a token that doesn't authenticate, a
// missing voice-transcription binary/model, an interpreter-stub class, two
// bots sharing one token, and a broken luna clip-source all used to be
// invisible until first live use. telegram-access ALSO grew a formal
// JSON-schema check on access.json in this same ticket — see
// telegram-access.schema.json beside this file and the extension at
// probeTelegramAccess below — without a new probe.type (it deepens the
// EXISTING one, per the ticket's own "extend, don't replace" instruction).
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
const { pathToFileURL } = require('url');
const { spawnSync } = require('child_process');
const { which, resolvePowershell } = require('./helpers.js');
// HIMMEL-2289: the SAME bash resolver scripts/hooks/run-hook-with-bash.js's
// launcher uses to pick a genuinely usable Git Bash — reused here (mirroring
// deps-engine.js's and install-engine.js's own requires of it) rather than
// re-deriving a third bash-selection policy. See spawnProbeSync().
const { resolveBash: resolveHookBash } = require('../../hooks/run-hook-with-bash.js');
// HIMMEL-2176 Task 7: the composite probes below (cadence-coherence,
// phi-coherence, engine-allowlist, bridge-health) read the adopter's shared
// config document directly (luna.cadence.enabled/schedules, bridge.enabled,
// luna.vaultPath) — the SAME module status-report.js uses for its desired-
// state override (see that file's module header). load()/configPath() only
// honor HIMMEL_LUNA_CONFIG_PATH via the real process.env (no env parameter
// of their own) — every caller here that needs it ctx-scoped routes through
// scopeConfigPathToCtx (retask stage1-build-6d2e), which stands in for that
// missing seam rather than reading the ambient environment unscoped.
const lunaConfig = require('./luna-config.js');
// HIMMEL-2176 Stage-1 PR-C, status item S6: the pinned persistence artifact
// names/helpers (SYSTEMD_UNIT_NAME, WINDOWS_LOGON_TASK_NAME,
// lingerEnabled(), systemdUnitInstalled()) are owned by bridge-persistence.js
// — imported here, never redeclared (that module's own header comment: "a
// sibling status item (S6) registers against these constants").
const bridgePersistence = require('./bridge-persistence.js');

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

// ── git-hooks ────────────────────────────────────────────────────────────

// Read a checkout's LOCAL core.hooksPath — the override that points git at a
// non-default hooks dir (e.g. `git config core.hooksPath scripts/hooks`, the
// legitimate in-repo layout check-commit-msg.ps1 documents and check-hookspath
// validates). LOCAL scope only: the status-probe fixtures below resolve hooks
// by pure-fs .git/gitdir/commondir traversal and carry no local config, so
// `--local` returns '' for them and leaves that path unchanged; a GLOBAL
// core.hooksPath is check-hookspath's authoritative concern, not this probe's
// (HIMMEL-1470).
//
// HIMMEL-2298 (enumerating the spawn family): this was the ONE process-spawning
// probe site with no budget at all — a bare spawnSync, so a wedged git (a
// network-backed config include, a hung filesystem) blocked `status` forever
// rather than for a bounded time. Routed through spawnProbeSync for the same
// PROBE_TIMEOUT_MS + SIGKILL guard every other site gets. A timeout lands in
// the existing '' return, which callers already treat as "no override
// configured" — the pre-existing behaviour for any git failure here.
function configuredHooksPath(targetPath) {
  try {
    const r = spawnProbeSync('git', ['-C', targetPath, 'config', '--local', '--get', 'core.hooksPath'], { encoding: 'utf8' });
    if (r.status === 0) return (r.stdout || '').trim();
  } catch (_e) {}
  return '';
}

// Resolve a checkout's effective hooks directory. A core.hooksPath override
// wins; otherwise a normal clone stores hooks at .git/hooks, and a linked
// worktree's .git points to .git/worktrees/<name> whose `commondir` points back
// at the shared repository metadata whose hooks/ is authoritative.
function gitHooksDir(targetPath) {
  const configured = configuredHooksPath(targetPath);
  if (configured) {
    return path.isAbsolute(configured) ? path.resolve(configured) : path.resolve(targetPath, configured);
  }
  const dotGit = path.join(targetPath, '.git');
  let st;
  try {
    st = fs.statSync(dotGit);
  } catch (_e) {
    return null;
  }
  if (st.isDirectory()) return path.join(dotGit, 'hooks');
  if (!st.isFile()) return null;

  let raw;
  try {
    raw = fs.readFileSync(dotGit, 'utf8').trim();
  } catch (_e) {
    return null;
  }
  const m = raw.match(/^gitdir:\s*(.+)$/i);
  if (!m) return null;
  const gitDir = path.resolve(targetPath, m[1]);
  try {
    const common = fs.readFileSync(path.join(gitDir, 'commondir'), 'utf8').trim();
    if (common) return path.join(path.resolve(gitDir, common), 'hooks');
  } catch (_e) {
    // A gitlink without commondir uses its own metadata directory.
  }
  return path.join(gitDir, 'hooks');
}

function installedHook(p, platform) {
  let st;
  try {
    st = fs.statSync(p);
  } catch (_e) {
    return false;
  }
  if (!st.isFile()) return false;
  if (platform === 'win32') return true;
  try {
    fs.accessSync(p, fs.constants.X_OK);
    return true;
  } catch (_e) {
    return false;
  }
}

function probeGitHooks(item, ctx) {
  const hooksDir = gitHooksDir(ctx.targetPath || ctx.repoRoot);
  if (!hooksDir) {
    return { actual: 'absent', detail: `cannot resolve git hooks directory; missing hook type(s): ${item.probe.hooks.join(', ')}` };
  }
  const platform = ctx.platform || process.platform;
  const missing = item.probe.hooks.filter((hook) => !installedHook(path.join(hooksDir, hook), platform));
  if (missing.length === 0) {
    return { actual: 'present', detail: `installed hook type(s): ${item.probe.hooks.join(', ')} (${hooksDir})` };
  }
  const actual = missing.length === item.probe.hooks.length ? 'absent' : 'degraded';
  return { actual, detail: `missing hook type(s): ${missing.join(', ')} (${hooksDir})` };
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

// Expand a leading `~` against ctx.env.HOME (falling back to os.homedir()) —
// deliberately NOT status-report.js's own expandHome(), which reads
// process.env.HOME directly: resolveConfigFile() above already resolves a
// user-scope item's home via ctx.env.HOME (the hermetic seam every probe
// test drives), and a config-sourced path needs to land on that SAME home to
// stay consistent with it — reading process.env.HOME instead would silently
// diverge from a test's faked ctx.env.HOME and resolve against the REAL
// operator home (caught during Part C testing: this exact mismatch made the
// no-config-file case read the real ~/.claude/channels/telegram/.env).
function expandHomeForCtx(p, ctx) {
  if (typeof p !== 'string' || p === '') return p;
  const home = (ctx.env && ctx.env.HOME) || os.homedir();
  if (p === '~') return home;
  if (p.slice(0, 2) === '~/' || p.slice(0, 2) === '~\\') return path.join(home, p.slice(2));
  return p;
}

// HIMMEL-2176 Stage-1 PR-C, Part B: lunaConfig.load() itself returns the
// SAME schema-shaped default object whether or not ~/.himmel/config.json
// actually exists on disk (first-run convenience) — so file EXISTENCE, not
// the loaded VALUE, is the only way the two call sites below can tell "the
// adopter genuinely has a config" apart from "this is just the untouched
// in-memory default." That distinction matters here specifically because
// bridge.envPath's own default ('~/.claude/channels/telegram/.env') is a
// non-empty string — unlike bridge.enabled/luna.cadence.enabled (used
// elsewhere in this file), which default to `false` and so stay inert with
// no such gate needed. Skipping load() entirely for the common "no config
// file yet" case also means a probe never overrides its own pre-existing,
// scope/target-aware resolution (resolveConfigFile) with a home-relative
// config path that a project-scoped caller could never reproduce — caught
// during this ticket's own Part C testing, where the ungated version read
// the REAL operator's ~/.claude/channels/telegram/.env. Returns
// { config: <doc> } | { config: null } (no file) | { configError } (a file
// exists but load() threw — malformed JSON/schema).
//
// CR fix (retask stage1-build-6d2e): the third instance of this file's
// ctx.env-vs-process.env class (see expandHomeForCtx's HOME fix and the
// Windows scheduler-query fix earlier this round) — and, per the sweep this
// round asked for, NOT the only remaining one: probeCadenceCoherence,
// probePhiCoherence, probeBridgeHealth, and probeBridgePersistence all call
// lunaConfig.load() directly (never through loadConfigIfPresent, since they
// want its schema-defaulted return even with no config file — unlike this
// function's null-on-absent contract), and all four already thread
// `ctx.env` for their OTHER reads, making the same ambient-process.env leak.
// luna-config.js's own configPath()/load() read `process.env.
// HIMMEL_LUNA_CONFIG_PATH` directly — that module takes no env parameter
// and is outside this fix's file set — so scopeConfigPathToCtx below is the
// one shared seam every caller in this file now routes through: scope
// process.env.HIMMEL_LUNA_CONFIG_PATH to ctx.env for the duration of the
// call only (save/restore, restoring absence as absence, never a stray ''),
// mirroring how every other read in this file's ctx-taking probes already
// prefers `ctx.env` over the ambient environment.
function scopeConfigPathToCtx(ctx, fn) {
  const env = (ctx && ctx.env) || process.env;
  const hadOwn = Object.prototype.hasOwnProperty.call(process.env, 'HIMMEL_LUNA_CONFIG_PATH');
  const prev = process.env.HIMMEL_LUNA_CONFIG_PATH;
  if (nonEmpty(env.HIMMEL_LUNA_CONFIG_PATH)) {
    process.env.HIMMEL_LUNA_CONFIG_PATH = env.HIMMEL_LUNA_CONFIG_PATH;
  } else if (ctx && ctx.env) {
    // A genuinely scoped ctx.env that does NOT carry the override must not
    // silently inherit the ambient process-level one either — clearing it
    // for the duration of the call is what makes ctx.env authoritative in
    // both directions, not just when it happens to set the var.
    delete process.env.HIMMEL_LUNA_CONFIG_PATH;
  }
  try {
    return fn();
  } finally {
    if (hadOwn) process.env.HIMMEL_LUNA_CONFIG_PATH = prev;
    else delete process.env.HIMMEL_LUNA_CONFIG_PATH;
  }
}

function loadConfigIfPresent(ctx) {
  return scopeConfigPathToCtx(ctx, () => {
    if (!fs.existsSync(lunaConfig.configPath())) return { config: null };
    try {
      return { config: lunaConfig.load() };
    } catch (e) {
      return { configError: e };
    }
  });
}

// bridge.envPath was a documented config field nothing ever read — the
// wizard writes it, but every token-reading bridge probe (telegram-access,
// cmd:telegram_getme) only ever consulted the manifest's own hardcoded
// item.probe.envFile. Precedence, deliberately chosen (no existing
// three-way chain to copy): explicit process-env override (TELEGRAM_ENV —
// the SAME var poller.ts/session-status.ts already read:
// `process.env.TELEGRAM_ENV ?? join(homedir(), ".claude/channels/telegram/
// .env")`) wins, else the adopter's configured value, else the manifest's
// hardcoded default — matching this tree's established idiom that an
// explicit env var always wins (probeWhisperReady's WHISPER_DIR;
// luna-config.js's own HIMMEL_LUNA_CONFIG_PATH), with config filling in only
// when the env var is unset AND a config file genuinely exists (see
// loadConfigIfPresent above) — so "no config at all" behaves exactly as
// before this change (regression guard).
function resolveBridgeEnvFilePath(item, ctx) {
  const env = ctx.env || process.env;
  // CR fix (codex-3, retask stage1-build-6d2e round 9): the configured-value
  // branch below expands a leading `~` (expandHomeForCtx, which already
  // handles both `~/` and the HIMMEL-2263 `~\` backslash gap), but this
  // override branch used to return env.TELEGRAM_ENV verbatim — the HIGHEST-
  // priority input in the precedence chain was the one most likely to fail
  // for an adopter who set it the natural way (`TELEGRAM_ENV=~/...`).
  // Expanded the same way as the configured path for consistency.
  if (nonEmpty(env.TELEGRAM_ENV)) return { path: expandHomeForCtx(env.TELEGRAM_ENV, ctx) };
  const { config, configError } = loadConfigIfPresent(ctx);
  if (configError) return { configError };
  if (config && config.bridge && nonEmpty(config.bridge.envPath)) {
    return { path: expandHomeForCtx(config.bridge.envPath, ctx) };
  }
  return { path: resolveConfigFile(item.probe.envFile, ctx) };
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
  const getVal = item.probe.file === '.env' ? (k) => data[k] : (k) => getDotPath(data, k);
  // HIMMEL-2292: optional 'expect' asserts the SINGLE key's value equals it
  // exactly, not merely non-empty — existence != enablement. Without this, a
  // boolean-flag key (e.g. enabledPlugins["<spec>"]) set to `false` reads
  // 'present' below (nonEmpty(false) === true, since false is neither
  // undefined/null/'' nor an empty array/object) and a toggled-off plugin
  // would probe green forever. manifest-lint.mjs's shape check requires
  // 'expect' to pair with singular 'key' (not 'keys') — see its own comment
  // for why a multi-key expected-value map isn't supported.
  if (Object.prototype.hasOwnProperty.call(item.probe, 'expect')) {
    const val = getVal(item.probe.key);
    if (val === item.probe.expect) return { actual: 'present', detail: filePath };
    return { actual: 'absent', detail: `${item.probe.key} in ${filePath} is ${JSON.stringify(val)}, expected ${JSON.stringify(item.probe.expect)}` };
  }
  const keys = item.probe.keys || [item.probe.key];
  const missing = keys.filter((k) => !nonEmpty(getVal(k)));
  if (missing.length === 0) return { actual: 'present', detail: filePath };
  return { actual: 'absent', detail: `missing/empty key(s) in ${filePath}: ${missing.join(', ')}` };
}

// ── telegram-access — formal JSON-schema extension (HIMMEL-2176 Task 6) ───

// The inventory's "access.json gets zero validation" finding is stale by the
// time this ticket landed — the HIMMEL-1093 semantic check below (a usable
// allowFrom/groups shape) already existed. What was actually missing is
// FORMALITY: a machine-checkable schema document a later consumer (the gate
// layer, scripts/telegram/gate.ts, at load time) can import too, instead of
// every consumer growing its own ad hoc shape assumptions. The schema lives
// in its own sidecar file (telegram-access.schema.json, beside this file),
// not inline, so a non-Node consumer never has to require() probes.js just
// to read it. validateAgainstSchema is a small hand-rolled validator, not a
// dependency: this repo is zero-dep by convention (module header) and the
// schema surface actually needed — type/properties/items/additionalProperties
// as either a boolean or a nested schema — is a small, fixed subset of JSON
// Schema, not a case for pulling in a general validator library.
const ACCESS_SCHEMA = require('./telegram-access.schema.json');

function validateAgainstSchema(schema, value, label, errors) {
  if (!schema || typeof schema !== 'object') return;
  if (schema.type === 'object') {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) {
      errors.push(`${label} must be an object`);
      return;
    }
    const props = schema.properties || {};
    for (const key of Object.keys(value)) {
      if (Object.prototype.hasOwnProperty.call(props, key)) {
        validateAgainstSchema(props[key], value[key], `${label}.${key}`, errors);
      } else if (schema.additionalProperties && typeof schema.additionalProperties === 'object') {
        validateAgainstSchema(schema.additionalProperties, value[key], `${label}.${key}`, errors);
      } else if (schema.additionalProperties === false) {
        errors.push(`${label}.${key} is not a recognized field`);
      }
      // additionalProperties === true (or absent): deliberately open, see the
      // sidecar schema's own description — no check for this key.
    }
  } else if (schema.type === 'array') {
    if (!Array.isArray(value)) {
      errors.push(`${label} must be an array`);
      return;
    }
    if (schema.items) {
      value.forEach((v, i) => validateAgainstSchema(schema.items, v, `${label}[${i}]`, errors));
    }
  } else if (schema.type === 'string') {
    if (typeof value !== 'string') errors.push(`${label} must be a string`);
  } else if (schema.type === 'boolean') {
    if (typeof value !== 'boolean') errors.push(`${label} must be a boolean`);
  }
}

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
  const resolvedEnvFile = resolveBridgeEnvFilePath(item, ctx);
  if (resolvedEnvFile.configError) {
    return { actual: 'degraded', detail: `cannot read luna config: ${resolvedEnvFile.configError.message}` };
  }
  const envFilePath = resolvedEnvFile.path;
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
  // HIMMEL-2176 Task 6: formal schema check BEFORE the semantic (usable-
  // allow-rule) check below — a file that HAPPENS to carry a non-empty
  // allowFrom/groups but also carries a wrong-typed field elsewhere (e.g.
  // dmPolicy as a number, a per-group requireMention as a string) must not
  // silently read 'present' just because the one field this probe used to
  // look at happens to be shaped right.
  const schemaErrors = [];
  validateAgainstSchema(ACCESS_SCHEMA, access, 'access.json', schemaErrors);
  if (schemaErrors.length > 0) {
    return {
      actual: 'degraded',
      detail: `${item.probe.tokenKey} present in ${envFilePath}, but ${accessFilePath} fails its formal schema — ${schemaErrors.join('; ')}`,
    };
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
// a downstream binary (qmd, bun) wedges): timeout + SIGKILL so a hung child
// can't block `status` forever. r.timedOut is set so callers can surface a
// hang as actual:"degraded" instead of misreading it as a plain negative
// ("absent") probe result.
//
// PROBE_TIMEOUT_MS (HIMMEL-2298) is the FAMILY budget, 60s. It was 10s, which
// is not a hang budget on Windows — it is inside the range a HEALTHY probe
// legitimately occupies there, so it manufactured false DEGRADED rows on
// perfectly good machines. Measured on this dev box: the handover-dir probe
// takes 3.5-8.1s IDLE (one run of five at 8.1s — a 20% margin), and
// cadence-coherence 7.9-10.1s, because each probe launches at least one
// process and Windows process creation is slow and load-sensitive; the
// operator's ~4-session run pushed handover-dir over and it reported a
// DEGRADED timeout row against the old 10s budget on a healthy host.
// (Phrased without the literal message text on purpose: the suite's
// HIMMEL-2298 drift guard greps this file for a hardcoded timeout figure, and
// a comment quoting one trips it exactly like a real detail string would —
// reword the prose, never exempt the file.)
//
// HIMMEL-2289 raised ONE probe (cadence-coherence) to 60s and left its 14
// siblings at 10s — the sibling-branch defect family, and HIMMEL-2298 is the
// second report of it. The budget therefore lives HERE, as the default for
// every probe, instead of per call site.
//
// 60s stays a real hang guard: it is 6x the worst healthy time measured, and
// a genuinely wedged child is still SIGKILLed rather than blocking `status`
// forever. The cost of the raise is bounded and paid only by an actually-hung
// probe; the cost of 10s was paid by healthy machines, twice.
//
// r.timeoutMs carries the budget that was actually applied, so a caller's
// "timed out after Ns" message can never drift from the real number — the
// exact drift HIMMEL-2289 introduced when it changed one budget and left 15
// hardcoded "10s" strings behind.
const PROBE_TIMEOUT_MS = 60000;

// HIMMELCTL_PROBE_TIMEOUT_SECS overrides the family budget — the same env-seam
// class as HIMMELCTL_BASH / HIMMELCTL_POWERSHELL here, and the direct sibling
// of install-engine.js's own INSTALL_TIMEOUT_SECS. Two real users: an operator
// on a box slower than the one these numbers were measured on, and a hermetic
// test that needs a SMALL budget so proving the timeout path costs seconds
// rather than a minute (CR [codex-1]). Read from the SPAWN env, like the bash
// resolution above, so a probe threading a controlled ctx.env pins the budget
// that env implies. A non-numeric or non-positive value falls back to the
// default rather than failing — the same bad-value convention critic-panel.sh
// applies to CRITIC_TIMEOUT_SECS.
//
// CR round 2 [codex-1]: the validation is on the COMPUTED MILLISECONDS, not on
// the seconds value. `secs > 0` alone accepts a sub-millisecond override
// (0.0004), which rounds to 0 ms — and Node reads `timeout: 0` as NO TIMEOUT,
// silently disabling the very hang guard this constant exists to provide. A
// value too small to express a real budget is a BAD value, so it takes the
// same fallback as a non-numeric one: fail back to the default, never to
// "unbounded".
// CR round 3 [codex-1]: round 2 validated the computed ms with `ms >= 1`,
// which still let a huge-but-finite override through — `1e308 * 1000`
// overflows to Infinity, passes `>= 1`, and reaches spawnSync as an
// out-of-range timeout. One predicate closes the whole class instead of the
// two instances found so far: the milliseconds must be a SAFE INTEGER of at
// least 1. NaN, Infinity, sub-millisecond and absurd values all take the same
// fallback — the default budget, never "unbounded" and never a throw.
function probeTimeoutMs(env) {
  const raw = (env || process.env).HIMMELCTL_PROBE_TIMEOUT_SECS;
  const secs = Number(raw);
  if (!raw || !Number.isFinite(secs) || secs <= 0) return PROBE_TIMEOUT_MS;
  const ms = Math.round(secs * 1000);
  return Number.isSafeInteger(ms) && ms >= 1 ? ms : PROBE_TIMEOUT_MS;
}

function spawnProbeSync(cmd, args, opts) {
  const options = Object.assign({ timeout: probeTimeoutMs(opts && opts.env), killSignal: 'SIGKILL' }, opts);
  const r = spawnSync(cmd, args, options);
  r.timedOut = Boolean((r.error && r.error.code === 'ETIMEDOUT') || r.signal);
  r.timeoutMs = options.timeout;
  return r;
}

// probeTimeoutSecs(r) -> the budget r was run under, in seconds, for a
// "timed out after Ns" message. Falls back to the family default when a
// result carries no stamp (a synthetic result built by a caller).
//
// CR round 2 [codex-2]: does NOT round to whole seconds. This whole ticket is
// about a timeout message that disagreed with the budget behind it, so a
// message reporting a 1.5s budget as "2s" reintroduces the same defect in
// miniature. Whole seconds print bare (`60s`); a fractional budget keeps just
// enough precision to be true (`1.5s`).
function probeTimeoutSecs(r) {
  const secs = ((r && r.timeoutMs) || PROBE_TIMEOUT_MS) / 1000;
  return Number.isInteger(secs) ? String(secs) : String(Number(secs.toFixed(3)));
}

// resolveProbeBash(env) -> concrete bash executable, or null.
//
// HIMMEL-2289: every bash-backed probe in this file used to spawn the BARE
// name. On Windows that resolves through PATH to
// C:\WINDOWS\system32\bash.exe — the WSL launcher, which cannot read a
// Windows-form repo path at all — so on a fully healthy host the
// resolver-sourcing probes reported "cannot source resolver C:\...\lib.sh —
// probe wiring broken" (degraded) and "/bin/bash: line 1: C:\...\
// handover-path.sh: No such file or directory" (missing). deps-engine.js
// (HIMMEL-1992) and install-engine.js (HIMMEL-2176) already carried this
// rule; probes.js was the sibling that never got it.
//
// HIMMELCTL_BASH overrides the resolver (nonstandard install, or a hermetic
// test pinning — or deliberately UN-resolving — bash), the same env seam
// bin.js's own resolveBash() documents. Read from the SPAWN env, so a probe
// threading a fully-controlled ctx.env pins the interpreter that env implies
// rather than whatever the outer process happens to see.
function resolveProbeBash(env) {
  const e = env || process.env;
  return e.HIMMELCTL_BASH || resolveHookBash({ env: e });
}

// spawnBashProbe(args, opts) — spawnProbeSync against the RESOLVED bash.
// Every bash-backed probe below goes through here rather than naming the
// interpreter itself, so the resolution rule lives in one place instead of
// being re-remembered at 13 call sites.
//
// When nothing usable resolves, a SYNTHETIC spawn error is returned rather
// than falling back to the bare name — the WSL stub is precisely what this
// resolution exists to avoid, and every caller already branches on r.error
// (a spawn error reads 'degraded'/'absent' per that probe's own contract).
function spawnBashProbe(args, opts) {
  const options = Object.assign({ timeout: probeTimeoutMs(opts && opts.env), killSignal: 'SIGKILL' }, opts);
  const bin = resolveProbeBash(options.env);
  if (!bin) {
    return {
      error: new Error('no usable bash found — on Windows the PATH `bash` is the System32 WSL launcher, which cannot read repo paths; install Git Bash or set HIMMELCTL_BASH'),
      status: null,
      signal: null,
      stdout: '',
      stderr: '',
      timedOut: false,
      timeoutMs: options.timeout,
    };
  }
  return spawnProbeSync(bin, args, options);
}

// ── cmd:has_qmd ──────────────────────────────────────────────────────────

function probeCmdHasQmd(item, ctx) {
  const resolverPath = path.resolve(ctx.repoRoot, item.probe.resolver);
  const r = spawnBashProbe(['-c', `. "${resolverPath}" && has_qmd`], { env: ctx.env || process.env });
  if (r.timedOut) return { actual: 'degraded', detail: `cmd:has_qmd probe timed out after ${probeTimeoutSecs(r)}s` };
  if (r.error) return { actual: 'absent', detail: `spawn error: ${r.error.message}` };
  return r.status === 0
    ? { actual: 'present', detail: 'has_qmd rc=0' }
    : { actual: 'absent', detail: `has_qmd rc=${r.status}` };
}

// ── qmd-index ────────────────────────────────────────────────────────────

function probeQmdIndex(item, ctx) {
  const resolverPath = path.resolve(ctx.repoRoot, 'scripts/lib/qmd-bin.sh');
  const collections = item.probe.collections;
  const r = spawnBashProbe(['-c', `. "${resolverPath}" && has_qmd && qmd_cmd collection list`],
    { env: ctx.env || process.env, encoding: 'utf8' });
  if (r.timedOut) return { actual: 'degraded', detail: `qmd-index probe timed out after ${probeTimeoutSecs(r)}s` };
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
  const r = spawnBashProbe(['-c', `. "${resolverPath}" && handover_root`],
    { env: ctx.env || process.env, cwd, encoding: 'utf8' });
  if (r.timedOut) return { actual: 'degraded', detail: `handover-dir probe timed out after ${probeTimeoutSecs(r)}s` };
  if (!r.error && r.status === 0 && r.stdout && r.stdout.trim()) {
    return { actual: 'present', detail: r.stdout.trim() };
  }
  return { actual: 'absent', detail: (r.stderr || '').trim() || 'handover_root did not resolve' };
}

// ── dep ──────────────────────────────────────────────────────────────────

// which() (lib/helpers.js) reads process.env.PATH directly — a hermetic test
// exercises this probe by setting PATH on the OUTER shell invocation (the
// same convention as helpers.js itself and every sibling test-wizard-*.sh
// suite), not by threading ctx.env through. The `bash` dep is the ONE
// exception (HIMMEL-2289): it routes to probeBashDep, which resolves and
// EXERCISES the interpreter through ctx.env rather than asking which() to
// vouch for whatever name happens to sit on PATH.
function probeDep(item, ctx) {
  const cmd = item.probe.cmd || (process.platform === 'win32' ? item.probe.win32 : item.probe.posix);
  if (cmd === 'bash') return probeBashDep(ctx);
  const found = which(cmd);
  return found
    ? { actual: 'present', detail: found }
    : { actual: 'absent', detail: `'${cmd}' not found on PATH` };
}

// HIMMEL-2289: bash is the ONE hard-gate dep for which a which()-style
// presence answer is VACUOUS. On Windows, which('bash') happily returns
// C:\WINDOWS\system32\bash.exe and the toolchain row read "ok bash ready"
// while every bash-backed probe in this file was failing against that exact
// binary — existence is not enablement. Probe the bash the rest of himmel
// actually spawns (spawnProbeSync's resolution, HIMMELCTL_BASH included), and
// prove it by SOURCING a tracked repo script rather than by mere presence.
//
// The proof file is scripts/guardrails/lib.sh — the file the doc-guard probe
// failed to source in the field report. When it is absent (an adopter running
// himmelctl against a checkout that predates it, or a stripped fixture) the
// deep check is skipped rather than turned into a false "bash broken": a
// missing repo file is not a statement about the interpreter.
function probeBashDep(ctx) {
  const env = ctx.env || process.env;
  const bash = resolveProbeBash(env);
  if (!bash) {
    return { actual: 'absent', detail: 'no usable bash found — on Windows the PATH `bash` is the System32 WSL launcher, which cannot read repo paths; install Git Bash or set HIMMELCTL_BASH' };
  }
  const proofPath = path.resolve(ctx.repoRoot, 'scripts/guardrails/lib.sh');
  if (!fs.existsSync(proofPath)) return { actual: 'present', detail: `${bash} (presence only — ${proofPath} not in this checkout)` };
  const r = spawnProbeSync(bash, ['-c', '. "$HIMMEL_PROBE_RESOLVER"'],
    { env: Object.assign({}, env, { HIMMEL_PROBE_RESOLVER: proofPath }), encoding: 'utf8' });
  if (r.timedOut) return { actual: 'degraded', detail: `bash probe timed out after ${probeTimeoutSecs(r)}s` };
  if (r.error) return { actual: 'absent', detail: `spawn error: ${r.error.message}` };
  if (r.status !== 0) {
    return { actual: 'degraded', detail: `${bash} is on PATH but cannot source ${proofPath} (rc=${r.status}) — it cannot run repo scripts (a WSL bash handed a Windows-form path fails exactly this way)` };
  }
  return { actual: 'present', detail: bash };
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
  const r = spawnBashProbe(['-c', '. "$HIMMEL_PROBE_RESOLVER" || exit 3; resolve_hermes_py >/dev/null'], { env });
  if (r.timedOut) return { actual: 'degraded', detail: `cmd:has_hermes probe timed out after ${probeTimeoutSecs(r)}s` };
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
  const r = spawnBashProbe(['-c', '. "$HIMMEL_PROBE_RESOLVER" || exit 3; is_himmel_dev_repo'], { env, cwd: ctx.repoRoot });
  if (r.timedOut) return { actual: 'degraded', detail: `cmd:is_himmel_dev probe timed out after ${probeTimeoutSecs(r)}s` };
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
  // (himmel-update.sh:139-147): HERMES_HOME override, else — on Windows,
  // where LOCALAPPDATA is set — $LOCALAPPDATA/hermes, else (Linux/macOS)
  // $HOME/.hermes (upstream hermes' own default config home); src =
  // root/hermes-agent, falling back to root itself when THAT carries .git
  // instead (tolerates HERMES_HOME pointing straight at the checkout).
  // Branches on env.LOCALAPPDATA presence (not process.platform) so this
  // stays testable via ctx.env like its sibling probes.
  const home = env.HOME || os.homedir();
  const root = env.HERMES_HOME || (env.LOCALAPPDATA ? path.join(env.LOCALAPPDATA, 'hermes') : path.join(home, '.hermes'));
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
  const r = spawnBashProbe(['-c', cmd], { env });
  if (r.timedOut) return { actual: 'degraded', detail: `cmd:cadence_armed probe timed out after ${probeTimeoutSecs(r)}s` };
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
// quoting/interpolation surface to get wrong in the first place.
//
// HIMMEL-1418: uses the richer `status --json` verb (guardrail-block.mjs's
// statusDetail() contract) instead of the plain `guardrail-mode=<mode>
// node-resolves=<yes|no>` text line the probe used through HIMMEL-1100. The
// plain line only ever proves "at least one owned hook exists and ITS node
// path resolves" (detectMode()'s `.some()` over every group, nodeResolves()'s
// first-match return) — a 1-of-3 partial install (only one of the three
// GUARDRAILS wired, the other two missing or pointing at dead paths) was
// INDISTINGUISHABLE from a complete one, so every mode=global reading had to
// map to 'degraded' (round 3, codex-adv-1) — 'present' was structurally
// unreachable. `status --json` enumerates each expected hook's own presence,
// ACTUAL matcher, and bash/node/wrapper/script resolution (`complete` is
// true only when ALL of that holds for every hook), so this probe can now
// trust a genuine full install the way handover-dir/qmd-index already trust
// THEIR CLI's own richer output.
//
// CR fixes (same ticket, codex adversarial pass on 68c0b82c):
//   codex-adv-1: statusDetail() used to report each hook's EXPECTED matcher
//     (from GUARDRAILS) rather than the ACTUAL configured one — a settings.json
//     where all 3 owned hooks were moved into a single `Bash` matcher group
//     (so block-edit-on-main.sh never fires on Edit/Write, block-read-secrets
//     never fires on PowerShell/Read/Grep) still read complete:true. Fixed by
//     surfacing the actual matcher + an exact-match matcherMatches flag;
//     complete now requires matcherMatches on every hook too.
//   codex-adv-2: the baked GUARDRAIL_BASH path was parsed and then discarded
//     — a nonexistent bash executable (the wrapper fails closed on this at
//     runtime) still read complete:true, since only node/wrapper/script were
//     checked. Fixed by surfacing bashPath/bashResolves; complete now
//     requires bashResolves on every hook too.
//   codex-adv-3 (round 3): the *Resolves fields used fs.existsSync(), which
//     accepts a DIRECTORY (or, for node/bash, a non-executable file) as
//     "resolves" — reproduced complete:true with a baked path pointing at a
//     plain directory. Fixed in guardrail-block.mjs's isReadableFile()/
//     isRunnableExecutable() (isFile() + access() mode check); see that
//     file's contract comment for the Windows X_OK caveat.
//   codex-adv-4 (round 3): statusDetail() only ever looked at the FIRST
//     owned entry per basename — a second, dead-pathed duplicate (the exact
//     drift state installData()'s own dedup step exists to clean up) was
//     invisible, so a valid-plus-dead-duplicate pair still read
//     complete:true even though the duplicate can independently fire and
//     fail closed at runtime. Fixed by enumerating every owned entry
//     (entryCount, duplicates[]); complete now requires entryCount === 1.
//   codex-adv-5 (round 4): ownership was decided by substring-searching the
//     WHOLE command string for the guardrail's basename, while the parser
//     independently took the first three quoted args and ignored anything
//     after them — reproduced: a command whose real script arg is a decoy
//     (e.g. "claude-stub.sh") with the guardrail's basename sitting ONLY in
//     a trailing shell comment still read complete:true, while the real
//     protection was never wired. Fixed in guardrail-block.mjs by binding
//     ownership to the PARSED command's structure: the whole string must
//     match the exact generated shape (4 quoted segments, nothing
//     trailing) AND the parsed script arg's basename must equal the
//     guardrail's basename exactly (path.basename(), never a substring
//     check) — a decoy is now not owned by ANY guardrail at all (reads
//     present:false/entryCount:0, identical to "never wired"; see that
//     file's contract comment for why "not owned" was chosen over "owned
//     but flagged").
//   codex-adv-7 (companion finding "basename-only ownership lets a
//     same-named no-op file elsewhere pass", tracked as HIMMEL-1422): round
//     4's anchored GENERATED_COMMAND_RE correctly rejects a true decoy, but
//     it ALSO made an entry with the SAME wrapper/script identity plus a
//     trailing extra token invisible entirely — yet guardrail-skip-in-
//     himmel.js reads only process.argv[2] and ignores anything after it,
//     so Claude Code still executes such an entry identically to a
//     canonical one. A dead-pathed duplicate wired in this shape reopened
//     round 3's own blind spot (entryCount stayed 1, complete:true) through
//     a different command shape. Fixed via a bounded, NON-substring
//     structural test (referencesGuardrailIdentity(): every quoted
//     segment's path.basename() checked against WRAPPER/the guardrail's
//     basename, never String#includes over the whole string — a
//     comment-only mention still correctly reads as a decoy, no regression
//     on codex-adv-5) that surfaces this as its own
//     `nonCanonicalCount`/`nonCanonical` anomaly, distinct from both a
//     decoy (present:false) and a canonical duplicate (entryCount > 1);
//     complete now also requires nonCanonicalCount === 0.
//   HIMMEL-1422 (trust anchor, resolving codex-adv-7's own companion
//     finding above): basename-only ownership meant a settings.json
//     referencing a same-named file in a WRONG directory (a stale/moved
//     checkout, or an unrelated no-op stub with the right filename) still
//     read present:true/resolves:true — "present" attested wiring, not
//     that the wired file IS the real himmel copy. guardrail-block.mjs's
//     statusDetail() now realpath-compares the configured wrapper/script
//     paths against a resolved trust anchor (HIMMEL_REPO env, else the
//     running guardrail-block.mjs's own checkout) via
//     wrapperMatchesAnchor/scriptMatchesAnchor; a mismatch never flips
//     present:false (ownership stays basename-only, per codex-adv-5) but
//     DOES force complete:false, with anchorWrapperPath/anchorScriptPath
//     naming the anchor precisely. Separately, wrapperResolves/
//     scriptResolves now also require non-trivial content
//     (isSaneContentFile()) — a truncated/empty file at an otherwise-
//     correct, even anchor-matching, path no longer reads resolves:true
//     either. This probe's recompute (guardrailEntryIsFullyValid below) and
//     its `problems` naming were extended in lockstep — see both below.
//   SCOPE: this probe attests the FULL GENERATED COMMAND IDENTITY —
//     presence, resolution, matcher, uniqueness, shape, AND trust-anchor
//     identity — of the CONFIGURED wiring. It does not attempt deeper
//     runtime proof (executing the hook chain, node/bash version checks,
//     full content hashing beyond the cheap sanity floor, or semantic
//     equivalence of a differently-formed command); those belong to
//     follow-up tickets against the contract, not this probe.
//   mode=project    -> 'absent' (never armed globally — the ordinary
//                      default; global mode is an explicit `setup-hooks.sh
//                      --guardrail-mode global` opt-in, never part of the
//                      automatic install path).
//   mode=global,
//   complete=true   -> 'present' (every GUARDRAILS hook has EXACTLY ONE
//                      owned entry, no non-canonical duplicates reference
//                      its identity, its ACTUAL matcher exactly matches
//                      what it needs for full tool coverage, and its
//                      bash/node/wrapper/script paths are all usable).
//   mode=global,
//   complete=false  -> 'degraded', detail names exactly which hook(s) are
//                      missing, duplicated (canonical or non-canonical),
//                      matcher-mismatched, or have an unusable path
//                      (partial install, duplicate/anomalous wiring, a
//                      hand-edited matcher, or a genuinely fully-armed
//                      install that rotted).
//   anything else (nonzero exit, unparseable JSON, missing mode/hooks
//   fields) -> 'degraded'.
function probeGuardrailBlockStatus(item, ctx) {
  const scriptPath = path.resolve(ctx.repoRoot, item.probe.script);
  const r = spawnProbeSync(process.execPath, [scriptPath, 'status', '--json'], { env: ctx.env || process.env, encoding: 'utf8' });
  if (r.timedOut) return { actual: 'degraded', detail: `cmd:guardrail_block_status probe timed out after ${probeTimeoutSecs(r)}s` };
  if (r.error) return { actual: 'degraded', detail: `spawn error: ${r.error.message}` };
  if (r.status !== 0) {
    const stderr = (r.stderr || '').trim();
    return { actual: 'degraded', detail: `guardrail-block.mjs status --json exited rc=${r.status}${stderr ? `: ${stderr}` : ''}` };
  }
  const out = (r.stdout || '').trim();
  let parsed;
  try {
    parsed = JSON.parse(out);
  } catch (_e) {
    return { actual: 'degraded', detail: `guardrail-block.mjs status --json produced unparseable output: ${out || '(empty)'}` };
  }
  // CR fix (codex-1-r6, round 6): Array.isArray([]) is true — without a
  // non-empty check, a malformed/truncated {mode:"global",complete:true,
  // hooks:[]} would sail past this guard and straight into the
  // `complete === true` branch below, trusted as 'present' despite
  // attesting ZERO guardrails. `hooks.length > 0` is the strictest check
  // available without duplicating guardrail-block.mjs's own GUARDRAILS
  // count here: hardcoding "3" (or requiring the .mjs's ESM export into
  // this CommonJS file) would itself be a second, driftable copy of that
  // knowledge — a non-empty array is the honest floor a CONSUMER can assert
  // without owning the producer's vocabulary.
  if (!parsed || typeof parsed.mode !== 'string' || !Array.isArray(parsed.hooks) || parsed.hooks.length === 0) {
    return { actual: 'degraded', detail: `guardrail-block.mjs status --json missing expected 'mode'/'hooks' fields: ${out || '(empty)'}` };
  }
  if (parsed.mode !== 'global') return { actual: 'absent', detail: `guardrail-mode=${parsed.mode}` };
  // CR fix (codex-1-r7, round 7 — third raise of this shape check, each
  // stricter): round 6 closed the empty-array case, but a TRUNCATED payload
  // — complete:true with only 1 hook object, that one object itself fully
  // healthy — still sailed through on parsed.complete alone. RECOMPUTE
  // completeness from the entries themselves rather than trusting the
  // producer's own summary flag: every entry must independently satisfy the
  // same fields the contract defines completeness by (present, matcherMatches,
  // bashResolves, nodeResolves, wrapperResolves, scriptResolves, entryCount
  // === 1, nonCanonicalCount === 0). 'present' now requires parsed.complete
  // === true AND this recomputed value to AGREE — a payload whose entries
  // contradict its own complete flag is untrustworthy, not present.
  //
  // ACCEPTED FLOOR (documented, not fixed here — out of HIMMEL-1422's
  // trust-anchor scope, a distinct residual gap): this still cannot catch
  // an INTERNALLY CONSISTENT truncated array — e.g. complete:true with
  // exactly 1 well-formed, fully-healthy hook object, when the real
  // contract enumerates 3. Detecting "too few entries" requires knowing the
  // EXPECTED count, which only the producer (guardrail-block.mjs's own
  // GUARDRAILS array) owns; asserting a count here (hardcoded "3", or a
  // `>1` guess) would be exactly the kind of producer-vocabulary
  // duplication round 6 already rejected, and a real producer always emits
  // its full fixed-order set regardless — this probe takes the floor: a
  // non-empty, internally-self-consistent payload is trusted.
  //
  // HIMMEL-1422: also requires wrapperMatchesAnchor/scriptMatchesAnchor —
  // an entry whose configured wrapper/script paths do NOT match the trust
  // anchor's own scripts/hooks/ copies (a same-basename file wired from a
  // wrong/stale checkout) must not independently recompute as valid either,
  // even if every other field on it looks healthy.
  const guardrailEntryIsFullyValid = (h) => Boolean(h)
    && h.present === true
    && h.entryCount === 1
    && (h.nonCanonicalCount || 0) === 0
    && h.matcherMatches === true
    && h.bashResolves === true
    && h.nodeResolves === true
    && h.wrapperResolves === true
    && h.scriptResolves === true
    && h.wrapperMatchesAnchor === true
    && h.scriptMatchesAnchor === true;
  const recomputedComplete = parsed.hooks.every(guardrailEntryIsFullyValid);
  if (parsed.complete === true) {
    if (!recomputedComplete) {
      return { actual: 'degraded', detail: `guardrail-block.mjs status --json declares complete=true but its own hooks[] entries do not all independently support it — self-contradictory payload, not trusted: ${out}` };
    }
    // ── HIMMEL-1427 (attestation v2 binding, CR round 1; fail-closed in
    //    round 2 — codex-adv finding 1) ────────────────────────────────────
    // The legacy `complete` flag attests the GENERATED COMMAND IDENTITY
    // (presence, matcher, resolution, trust-anchor basename ownership —
    // recomputedComplete above). guardrail-block.mjs's statusDetail() grew a
    // SECOND, audit-independent layer atop it: a content-integrity hash of
    // each wired wrapper/script against its git:HEAD object (per-hook
    // wrapperIntegrity/scriptIntegrity, verdict 'healthy' | …) and a realpath
    // compare of the configured paths against an AUDIT anchor distinct from
    // the HIMMEL_REPO trust anchor (per-hook wrapperMatchesAuditAnchor/
    // scriptMatchesAuditAnchor + top-level anchorMatchesAudit), summarized as
    // contentIntegrityComplete / auditAnchorComplete / attestationComplete
    // (= complete && contentIntegrityComplete && auditAnchorComplete). A
    // content-tampered wrapper or a divergent audit anchor yields
    // attestationComplete:false while `complete` still reads true — so WITHOUT
    // this binding the attestation exists in the payload but never reaches the
    // health surface (doctor still reports the guardrails 'present').
    //
    // FAIL-CLOSED (CR round 2): this probe spawns the checkout's OWN
    // guardrail-block.mjs, so producer and consumer ship in lockstep — a
    // payload with NO v2 fields is either version skew (HIMMEL_REPO aimed at
    // an older checkout) or deliberately stripped/tampered output, and a
    // PARTIAL v2 payload (some fields present, the set not whole) is
    // self-contradictory/incomplete. Round 1's fail-OPEN back-compat
    // (v2-absent → 'present') let a stale OR stripped producer read green
    // with tamper-evidence silently absent — exactly the downgrade path the
    // attestation exists to close. A CONSUMER never owns the producer's
    // version; it detects v2 by the fields' PRESENCE, then fails CLOSED on
    // absence OR a partial set rather than silently downgrading to the v1
    // 'present' verdict.
    const v2SummaryPresent = typeof parsed.attestationComplete === 'boolean'
      || typeof parsed.contentIntegrityComplete === 'boolean'
      || typeof parsed.auditAnchorComplete === 'boolean'
      || typeof parsed.anchorMatchesAudit === 'boolean';
    const v2PerHookPresent = parsed.hooks.some((h) => h && (
      h.wrapperIntegrity !== undefined || h.scriptIntegrity !== undefined
      || h.wrapperMatchesAuditAnchor !== undefined || h.scriptMatchesAuditAnchor !== undefined));
    if (!(v2SummaryPresent || v2PerHookPresent)) {
      return { actual: 'degraded', detail: 'guardrail-mode=global, v1 complete, but producer emitted no attestation-v2 fields — stale checkout or stripped output; guardrail content integrity UNVERIFIED' };
    }
    // A COMPLETE v2 payload carries the whole fixed set (top-level
    // attestationComplete / contentIntegrityComplete / auditAnchorComplete /
    // anchorMatchesAudit, plus per-hook wrapperIntegrity / scriptIntegrity /
    // wrapperMatchesAuditAnchor / scriptMatchesAuditAnchor). A PARTIAL set —
    // per-hook integrity fields present but the summary booleans missing, or
    // anchorMatchesAudit absent while audit-anchor divergence is visible — is
    // self-contradictory/incomplete and must NOT silently fall back to a v1
    // classification: degraded, never 'present' (panel sug codex-1).
    const v2SummaryComplete = typeof parsed.attestationComplete === 'boolean'
      && typeof parsed.contentIntegrityComplete === 'boolean'
      && typeof parsed.auditAnchorComplete === 'boolean'
      && typeof parsed.anchorMatchesAudit === 'boolean';
    const v2PerHookComplete = parsed.hooks.every((h) => h && (
      h.wrapperIntegrity !== undefined
      && h.scriptIntegrity !== undefined
      && h.wrapperMatchesAuditAnchor !== undefined
      && h.scriptMatchesAuditAnchor !== undefined));
    if (!(v2SummaryComplete && v2PerHookComplete)) {
      return { actual: 'degraded', detail: `guardrail-mode=global, v1 complete, but attestation v2 payload is incomplete — some v2 fields present but the set is not whole (self-contradictory payload, not trusted): ${out}` };
    }
    // Same self-consistency posture as recomputedComplete: do NOT trust the
    // producer's own attestationComplete flag on its own — RECOMPUTE the v2
    // composite from the payload's own parts. The flag must AGREE with its
    // three summary parts (complete && contentIntegrityComplete &&
    // auditAnchorComplete), and those summaries must AGREE with the per-hook
    // integrity verdicts / audit-anchor matches that ground them. A payload
    // whose flags contradict their own evidence is untrustworthy, not present
    // (the same "self-contradictory, not trusted" stance as the v1 recompute
    // above — a CONSUMER recomputes; it does not rubber-stamp the producer).
    const healthyIntegrity = (i) => i && typeof i === 'object' && i.verdict === 'healthy';
    const recomputedContentIntegrity = parsed.hooks.every((h) => healthyIntegrity(h.wrapperIntegrity) && healthyIntegrity(h.scriptIntegrity));
    const recomputedAuditAnchor = parsed.anchorMatchesAudit === true
      && parsed.hooks.every((h) => h.wrapperMatchesAuditAnchor === true && h.scriptMatchesAuditAnchor === true);
    const recomputedAttestation = recomputedComplete && recomputedContentIntegrity && recomputedAuditAnchor;
    const summaryImplied = parsed.complete === true && parsed.contentIntegrityComplete === true && parsed.auditAnchorComplete === true;
    const flagsConsistent = parsed.attestationComplete === summaryImplied
      && parsed.contentIntegrityComplete === recomputedContentIntegrity
      && parsed.auditAnchorComplete === recomputedAuditAnchor;
    if (recomputedAttestation && parsed.attestationComplete === true && flagsConsistent) {
      return { actual: 'present', detail: `guardrail-mode=global — all ${parsed.hooks.length} guardrail hooks present, correctly matched, and resolving (attestation v2 complete: content-integrity + audit-anchor verified)` };
    }
    // v2 present but NOT satisfied: name the failing dimension(s), per hook —
    // content-integrity vs audit-anchor, wrapper vs script — mirroring the
    // `problems` builder below, so an operator (or himmelctl doctor) can act
    // on a specific broken attestation rather than a bare "incomplete".
    const v2Problems = [];
    if (!flagsConsistent) v2Problems.push('self-contradictory attestation v2 payload — summary flags disagree with their own parts, not trusted');
    if (parsed.anchorMatchesAudit === false) v2Problems.push('audit anchor diverges from self-checkout (anchor.repo does not match auditAnchor.repo)');
    for (const h of parsed.hooks) {
      const name = (h && h.basename) ? h.basename : '?';
      if (!healthyIntegrity(h && h.wrapperIntegrity)) v2Problems.push(`${name}: content integrity not verified — wrapper (${(h && h.wrapperIntegrity && h.wrapperIntegrity.reason) || 'unknown'})`);
      if (!healthyIntegrity(h && h.scriptIntegrity)) v2Problems.push(`${name}: content integrity not verified — script (${(h && h.scriptIntegrity && h.scriptIntegrity.reason) || 'unknown'})`);
      if (h && h.wrapperMatchesAuditAnchor === false) v2Problems.push(`${name}: does not match audit anchor — wrapper (expected ${h.auditWrapperPath})`);
      if (h && h.scriptMatchesAuditAnchor === false) v2Problems.push(`${name}: does not match audit anchor — script (expected ${h.auditScriptPath})`);
    }
    return { actual: 'degraded', detail: `guardrail-mode=global, v1 complete, but attestation v2 not satisfied — ${v2Problems.join('; ')}` };
  }
  // complete !== true: name exactly which hook(s) fall short, rather than
  // just saying "incomplete" — the whole point of the richer verb is to let
  // an operator (or `himmelctl doctor`) act on a specific broken hook.
  const problems = parsed.hooks
    .filter((h) => !(h && h.present && h.entryCount === 1 && (h.nonCanonicalCount || 0) === 0
      && h.matcherMatches && h.bashResolves && h.nodeResolves && h.wrapperResolves && h.scriptResolves
      && h.wrapperMatchesAnchor && h.scriptMatchesAnchor))
    .map((h) => {
      // CR fix (codex-adv-7): even a hook with NO canonical entry at all can
      // still have a runtime-relevant non-canonical one wired (same
      // wrapper/script identity, non-generated shape) — "missing" alone
      // would understate that, so it's named here too, not just below when
      // a canonical entry is also present.
      if (!h || !h.present) {
        const label = `${h && h.basename ? h.basename : '?'}: missing`;
        if (h && typeof h.nonCanonicalCount === 'number' && h.nonCanonicalCount > 0) {
          return `${label} (canonical entry absent, but ${h.nonCanonicalCount} non-canonical entr${h.nonCanonicalCount === 1 ? 'y' : 'ies'} referencing this guardrail's identity ${h.nonCanonicalCount === 1 ? 'is' : 'are'} still wired and runtime-relevant)`;
        }
        return label;
      }
      const reasons = [];
      // CR fix (codex-adv-4): a duplicate owned entry is a problem in its own
      // right, independent of whether the FIRST-FOUND one is fully valid — a
      // dead-pathed duplicate is still independently wired and can fail
      // closed at runtime, so it's named even when the primary entry alone
      // would otherwise pass every other check.
      if (typeof h.entryCount === 'number' && h.entryCount > 1) reasons.push(`${h.entryCount} duplicate entries wired (expected exactly 1)`);
      // CR fix (codex-adv-7): a non-canonical entry (same wrapper/script
      // identity, non-generated shape — e.g. a trailing extra token) is
      // still runtime-relevant (guardrail-skip-in-himmel.js only reads
      // argv[2]) even though it's excluded from entryCount, so it must be
      // named independently of whether the canonical entry alone is valid.
      if (typeof h.nonCanonicalCount === 'number' && h.nonCanonicalCount > 0) reasons.push(`${h.nonCanonicalCount} non-canonical entr${h.nonCanonicalCount === 1 ? 'y' : 'ies'} reference this guardrail's identity outside the generated shape (still runtime-relevant)`);
      if (!h.matcherMatches) reasons.push(`matcher mismatch (configured '${h.matcher}', expected '${h.expectedMatcher}')`);
      const broken = ['bash', 'node', 'wrapper', 'script'].filter((part) => !h[`${part}Resolves`]);
      if (broken.length > 0) reasons.push(`${broken.join('/')} path does not resolve`);
      // HIMMEL-1422: a wrapper/script that resolves but is NOT the trust
      // anchor's own copy (same basename, wrong/stale checkout) is a
      // distinct problem from "does not resolve" — name it with the exact
      // anchor path expected, so an operator can see precisely which
      // checkout the wiring should point at.
      const anchorMismatches = [];
      if (h.wrapperMatchesAnchor === false) anchorMismatches.push(`wrapper (expected ${h.anchorWrapperPath})`);
      if (h.scriptMatchesAnchor === false) anchorMismatches.push(`script (expected ${h.anchorScriptPath})`);
      if (anchorMismatches.length > 0) reasons.push(`does not match trust anchor: ${anchorMismatches.join(', ')}`);
      return `${h.basename}: ${reasons.join('; ')}`;
    });
  const summary = problems.length > 0 ? problems.join('; ') : 'guardrail-block.mjs status --json reports complete=false with no per-hook gap identified';
  return { actual: 'degraded', detail: `guardrail-mode=global but incomplete — ${summary}` };
}

// ── cmd:telegram_getme ───────────────────────────────────────────────────

// HIMMEL-2176 Task 6, A17: telegram-access (above) proves TELEGRAM_BOT_TOKEN
// is present and access.json's allow-rule shape is usable — neither proves
// the token actually AUTHENTICATES against Telegram (revoked, typo'd, or a
// deleted bot's token pasted from an old note). getMe() already exists at
// scripts/telegram/telegram-api.ts:39-46 (HIMMEL-1401's injectable-fetch
// signature) — reused here rather than a second HTTP client, but it's
// Bun/TypeScript and probes.js is zero-dep Node CommonJS, so there is no
// require()/import seam between them. The seam is the SAME one every other
// cmd:* probe in this file already uses to cross into a different runtime —
// the shared spawnProbeSync helper with a -c constant command, and every value
// the child needs (the api-module path, the token, the inline script text
// itself) traveling through the CHILD's OWN env, never string-interpolated
// into the -c command and never passed as an argv element (argv is visible
// to any other process on the box via `ps`/Task Manager; env is not) — just
// crossing into `bun -e` at the end instead of stopping at bash. The inline
// script dynamic-imports the checkout's own telegram-api.ts by absolute
// path and calls the REAL getMe(token) (the real global fetch — this IS a
// network call, so it only ever runs against a live bridge; the hermetic
// test suite stubs the `bun` EXECUTABLE itself, this file's own established
// testing convention, never the JS boundary), printing only "ok:<username>"
// or "fail" to stdout on the happy path.
//
// CR fix (HIMMEL-2176, retask stage1-build-6d2e): the happy path never
// echoed the token, but a FAILURE path could — getMe()'s request URL embeds
// the token in its own path (https://api.telegram.org/bot<TOKEN>/getMe), so
// any fetch failure or stack trace that includes that URL, folded into this
// probe's detail via the child's raw stderr below, printed the live bot
// token straight into `himmelctl status` output. Closed at both ends rather
// than just trusting one: the inline script below now catches its own
// error and strips the token from the message BEFORE it ever reaches
// stderr (the child never gets a chance to emit the raw value), and this
// function's own handling of the child's stdout/stderr/spawn-error text
// redacts the token again via redactToken() as an independent second layer
// — a probe that forwards a secret-bearing child's output can't assume the
// child redacted itself correctly.
//
// CR round 9 fix (HIMMEL-2176, retask stage1-build-6d2e): that same
// catch-and-redact wrapped BOTH the module import and the getMe() call in
// one try, so any failure — the probe's own plumbing (bun missing, the
// module failing to import) as much as a genuine network/Telegram-API
// failure the probe successfully observed — surfaced through the identical
// nonzero-exit path below as "probe wiring broken". That told an adopter
// with a perfectly fine himmel install, but no network reachability, to go
// look at their himmel install. The two failure kinds are now told apart at
// the source: the inline script tags its own stderr with `wiring:` (import
// failed — the probe couldn't even ATTEMPT the check) or `runtime:` (the
// getMe() call itself failed — the probe DID run, and observed a
// connectivity/API problem) before this same redaction step, and this
// function reads that tag to route the two into different detail text.
const RUNTIME_TAG = 'runtime:';
const WIRING_TAG = 'wiring:';
function redactToken(text, token) {
  if (!text || !token) return text;
  return text.split(token).join('[REDACTED]');
}

function probeTelegramGetMe(item, ctx) {
  const resolvedEnvFile = resolveBridgeEnvFilePath(item, ctx);
  if (resolvedEnvFile.configError) {
    return { actual: 'degraded', detail: `cannot read luna config: ${resolvedEnvFile.configError.message}` };
  }
  const envFilePath = resolvedEnvFile.path;
  let envRaw;
  try {
    envRaw = fs.readFileSync(envFilePath, 'utf8');
  } catch (_e) {
    return { actual: 'absent', detail: `cannot read ${envFilePath}` };
  }
  const token = parseDotEnv(envRaw)[item.probe.tokenKey];
  if (!nonEmpty(token)) {
    return { actual: 'absent', detail: `missing/empty key '${item.probe.tokenKey}' in ${envFilePath}` };
  }
  const apiPath = path.resolve(ctx.repoRoot, item.probe.apiModule);
  // CR fix (codex-5, retask stage1-build-6d2e): a native Windows path
  // (`C:\...`) handed to a dynamic `import()` is runtime-dependent as an ESM
  // specifier and can be rejected as an unsupported URL scheme — convert to
  // a `file://` URL first, which every runtime's import() accepts uniformly
  // regardless of platform.
  const apiUrl = pathToFileURL(apiPath).href;
  // Two SEPARATE try/catches, not one: the import is the probe's own
  // plumbing (a wiring failure if it throws — bun's fine, but the module
  // couldn't even be loaded), while getMe() is the actual check this probe
  // exists to run (a throw there is a runtime failure the probe DID
  // observe — network/DNS/timeout/HTTP-level, not a wiring gap). Each catch
  // tags its stderr line so probeTelegramGetMe below can tell them apart.
  const script = 'const token = process.env.HIMMEL_PROBE_TOKEN;'
    + 'let getMe;'
    + 'try {'
    + '  ({ getMe } = await import(process.env.HIMMEL_PROBE_TELEGRAM_API));'
    + '} catch (e) {'
    + '  console.error("wiring:" + String((e && e.stack) || e));'
    + '  process.exit(1);'
    + '}'
    + 'try {'
    + '  const u = await getMe(token);'
    + '  console.log(u ? `ok:${u}` : "fail");'
    + '} catch (e) {'
    + '  const msg = String((e && e.stack) || e).split(token).join("[REDACTED]");'
    + '  console.error("runtime:" + msg);'
    + '  process.exit(1);'
    + '}';
  const env = Object.assign({}, ctx.env || process.env, {
    HIMMEL_PROBE_TELEGRAM_API: apiUrl,
    HIMMEL_PROBE_TOKEN: token,
    HIMMEL_PROBE_BUN_SCRIPT: script,
  });
  const r = spawnBashProbe(['-c', 'bun -e "$HIMMEL_PROBE_BUN_SCRIPT"'], { env, encoding: 'utf8' });
  if (r.timedOut) return { actual: 'degraded', detail: `cmd:telegram_getme probe timed out after ${probeTimeoutSecs(r)}s` };
  if (r.error) return { actual: 'degraded', detail: `spawn error: ${redactToken(r.error.message, token)}` };
  if (r.status === 127) return { actual: 'degraded', detail: "'bun' not found on PATH — cmd:telegram_getme requires bun" };
  if (r.status !== 0) {
    const stderr = redactToken((r.stderr || '').trim(), token);
    if (stderr.indexOf(RUNTIME_TAG) === 0) {
      // The probe DID run getMe() and observed a failure — connectivity,
      // DNS, a proxy, or Telegram itself, not this probe's own wiring.
      return { actual: 'degraded', detail: `getMe network/API call failed (connectivity, not a probe wiring problem): ${stderr.slice(RUNTIME_TAG.length)}` };
    }
    const wiringDetail = stderr.indexOf(WIRING_TAG) === 0 ? stderr.slice(WIRING_TAG.length) : stderr;
    return { actual: 'degraded', detail: `bun getMe check exited rc=${r.status} — cmd:telegram_getme probe wiring broken${wiringDetail ? `: ${wiringDetail}` : ''}` };
  }
  const out = redactToken((r.stdout || '').trim(), token);
  if (out.indexOf('ok:') === 0) {
    return { actual: 'present', detail: `getMe ok (bot @${out.slice(3)})` };
  }
  return { actual: 'degraded', detail: `${item.probe.tokenKey} present in ${envFilePath}, but getMe rejected it (invalid/revoked token, or unreachable network)` };
}

// ── cmd:whisper_ready ────────────────────────────────────────────────────

// HIMMEL-2176 Task 6, A17: voice-note transcription's toolchain (a
// whisper.cpp binary + a real ggml model file) had no manifest presence at
// all — a bridge could be fully wired for text and silently unable to
// transcribe a single voice note. Pure fs, no spawn: mirrors
// scripts/telegram/transcribe.ts:15-25's own resolution (WHISPER_DIR
// override else ~/.himmel/whisper; WHISPER_CLI/WHISPER_MODEL override else
// <dir>/<default>), with ONE deliberate deviation — transcribe.ts's own
// default binary name is Windows-only (`whisper-cli.exe`; its own header
// comment tells POSIX operators to set WHISPER_CLI explicitly) — but a
// READINESS probe needs a sane default to check on EITHER platform, so the
// default name is platform-branched here (`ctx.platform || process.platform`,
// the same override precedent probeGitHooks already established above)
// rather than win32-only. Two-step degrade, not a single yes/no: a binary
// present but the model missing is a DIFFERENT, more specific problem
// (whisper-cli then fails per-invocation, not at bridge startup) —
// 'degraded', not 'absent'.
// CR fix (HIMMEL-2176, codex-2): bare fs.existsSync() accepts a DIRECTORY, a
// non-executable file, or a 0-byte file (a truncated download — the design's
// own model-download checklist item warns about exactly this) as "ready".
// isUsableFile() below mirrors guardrail-block.mjs's isReadableFile() (this
// file's own comments already cite it for the identical "it was a plain
// directory" bug class) plus a non-zero-size floor, rather than a third
// hand-rolled variant — kept local (not required cross-module) since that
// file is ESM and this one is CommonJS. Windows carries no meaningful
// executable-bit concept (fs.accessSync X_OK behaves like plain existence
// there — see registeredCommandCheck() above), so the exec check is
// POSIX-only and only ever applied to the binary, never the model.
//
// CR fix (HIMMEL-2176, retask stage1-build-6d2e): the POSIX/win32 branch
// used to read the real process.platform directly instead of the effective
// platform this file's own convention threads everywhere else (`ctx.platform
// || process.platform` — see probeWhisperReady/probeGitHooks above). A probe
// simulating win32 on an actual POSIX host inherited the host's own exec-bit
// check instead of the simulated one, so a win32-simulated `.exe` fixture
// with no exec bit set could read falsely absent — exactly the cross-
// platform coverage the whisper fixtures below exist to prove, undermined by
// reading the wrong platform signal. isUsableFile() now takes the effective
// platform as a parameter instead of reading process.platform itself.
function isUsableFile(p, { execCheck, platform } = {}) {
  let stat;
  try {
    stat = fs.statSync(p);
  } catch (_e) {
    return { ok: false, reason: 'not found' };
  }
  if (!stat.isFile()) return { ok: false, reason: 'is a directory, not a file' };
  if (stat.size === 0) return { ok: false, reason: 'is a 0-byte file (truncated download?)' };
  try {
    fs.accessSync(p, fs.constants.R_OK);
  } catch (_e) {
    return { ok: false, reason: 'exists but is not readable' };
  }
  if (execCheck && (platform || process.platform) !== 'win32') {
    try {
      fs.accessSync(p, fs.constants.X_OK);
    } catch (_e) {
      return { ok: false, reason: 'exists but is not executable' };
    }
  }
  return { ok: true };
}

// HIMMEL-2176 Stage-1 PR-C, Part B: bridge.whisper.{cli,model} used to be
// read by nothing — the wizard writes them, but this probe only ever
// consulted WHISPER_CLI/WHISPER_MODEL/the hardcoded default. Precedence
// (same deliberate choice as resolveBridgeEnvFilePath above): explicit
// process-env override (WHISPER_CLI/WHISPER_MODEL — already the documented
// seam transcribe.ts's own operators use) wins, else the adopter's
// configured value, else the hardcoded default. `model` is stored in
// ~/.himmel/config.json as a bare FILENAME (default 'ggml-small.bin' — one
// of several installable ggml sizes), joined with `dir` exactly like the
// hardcoded default already is, so an untouched (or entirely absent — load()
// returns that same default) config resolves to the IDENTICAL path as before
// this change. `cli`, in contrast, defaults to null (unset) and, when the
// adopter DOES set it, is a full path to a custom binary (the same shape
// WHISPER_CLI itself takes) — used as-is, never joined with `dir`.
//
// CR sweep (codex-3, retask stage1-build-6d2e round 9): unlike
// resolveBridgeEnvFilePath's TELEGRAM_ENV/envPath pair, NEITHER side here
// expands a leading `~` — env.WHISPER_CLI/WHISPER_MODEL/WHISPER_DIR never
// have (matches transcribe.ts's own pre-existing, unchanged-by-this-ticket
// resolution: `process.env.WHISPER_CLI ?? join(WHISPER_DIR, ...)`, a plain
// path.join with no tilde handling), and `configuredCli`/`configuredModel`
// below deliberately don't either — adding expansion to only one side would
// REINTRODUCE this exact class of bug in the other direction (config
// expands, override doesn't). Symmetric non-expansion on both sides is not
// an oversight; it is the correct, consistent choice here.
function probeWhisperReady(item, ctx) {
  const env = ctx.env || process.env;
  const home = env.HOME || os.homedir();
  const dir = env.WHISPER_DIR || path.join(home, '.himmel', 'whisper');
  const defaultBin = (ctx.platform || process.platform) === 'win32' ? 'whisper-cli.exe' : 'whisper-cli';
  const { config, configError } = loadConfigIfPresent(ctx);
  if (configError) return { actual: 'degraded', detail: `cannot read luna config: ${configError.message}` };
  const whisperConfig = (config && config.bridge && config.bridge.whisper) || {};
  const configuredCli = nonEmpty(whisperConfig.cli) ? whisperConfig.cli : null;
  const configuredModel = nonEmpty(whisperConfig.model) ? path.join(dir, whisperConfig.model) : null;
  const cli = env.WHISPER_CLI || configuredCli || path.join(dir, defaultBin);
  const model = env.WHISPER_MODEL || configuredModel || path.join(dir, 'ggml-small.bin');
  const cliCheck = isUsableFile(cli, { execCheck: true, platform: ctx.platform || process.platform });
  if (!cliCheck.ok) {
    return {
      actual: 'absent',
      detail: cliCheck.reason === 'not found'
        ? `whisper binary not found at ${cli}`
        : `whisper binary at ${cli} is unusable (${cliCheck.reason})`,
    };
  }
  const modelCheck = isUsableFile(model);
  if (!modelCheck.ok) {
    return {
      actual: 'degraded',
      detail: modelCheck.reason === 'not found'
        ? `whisper binary present (${cli}) but model missing at ${model}`
        : `whisper binary present (${cli}) but model at ${model} is unusable (${modelCheck.reason})`,
    };
  }
  return { actual: 'present', detail: `${cli} + ${model}` };
}

// ── cmd:python_interpreter ───────────────────────────────────────────────

// HIMMEL-2176 Task 6, A11: adopters genuinely hit "interpreter stub" classes
// — most visibly the Windows Store python.exe/python3.exe app-execution
// aliases, which resolve fine on PATH (which() would find them) but, run
// non-interactively, print a Store-install nudge and exit non-zero without
// ever running the given script; a stray WSL interop shim or a broken venv
// activation can produce the same shape on POSIX. PATH-resolution alone is
// necessary but not sufficient proof of a working interpreter — this probe
// actually SPAWNS the candidate with the caller's OWN environment (so a
// caller-set PYTHONHOME/PYTHONPATH is exercised, not just read) and asserts
// it runs a trivial script end to end and prints back a fixed marker, not
// just that something at that name exists. Routed through `bash -c` (the
// SAME cross-platform exec/PATH-resolution seam every other cmd:* probe in
// this file already uses) rather than spawning the candidate directly —
// bash's own generic "command not found" (rc 127) is then the ordinary,
// unambiguous "not installed" signal, exactly like probeDep's absent case,
// distinct from a resolved-but-broken stub (any other non-zero/wrong-output
// outcome).
function probePythonInterpreter(item, ctx) {
  const env = ctx.env || process.env;
  const cmd = item.probe.cmd || ((ctx.platform || process.platform) === 'win32' ? 'python' : 'python3');
  const marker = 'HIMMEL_PY_OK';
  const envForSpawn = Object.assign({}, env, {
    HIMMEL_PROBE_PY_CMD: cmd,
    HIMMEL_PROBE_PY_SCRIPT: `import sys; print(${JSON.stringify(marker)})`,
  });
  const r = spawnBashProbe(['-c', '"$HIMMEL_PROBE_PY_CMD" -c "$HIMMEL_PROBE_PY_SCRIPT"'], { env: envForSpawn, encoding: 'utf8' });
  if (r.timedOut) return { actual: 'degraded', detail: `'${cmd}' timed out after ${probeTimeoutSecs(r)}s — interpreter stub? (Windows Store alias, WSL shim)` };
  if (r.error) return { actual: 'degraded', detail: `spawn error: ${r.error.message}` };
  if (r.status === 127) return { actual: 'absent', detail: `'${cmd}' not found on PATH` };
  if (r.status !== 0 || (r.stdout || '').trim() !== marker) {
    return {
      actual: 'degraded',
      detail: `'${cmd}' resolved but did not run a real interpreter (rc=${r.status}, stdout=${JSON.stringify((r.stdout || '').trim())}) — likely a Windows Store alias or a broken stub`,
    };
  }
  return { actual: 'present', detail: `${cmd} runs (PYTHONHOME=${('PYTHONHOME' in env) ? env.PYTHONHOME : '(unset)'})` };
}

// ── distinct-tokens ──────────────────────────────────────────────────────

// HIMMEL-2176 Task 6: two DIFFERENT Telegram bots share this checkout — the
// interactive bridge (telegram-bridge, ~/.claude/channels/telegram/.env) and
// the HIMMEL_JIRA_NUDGE SessionEnd relay (repo-root .env — see poller.ts's
// loadBridgeEnv() comment on why TELEGRAM_BOT_TOKEN is deliberately
// FILE-ONLY there, precisely to prevent this class of mix-up). Pointing both
// at the SAME bot token means the bridge's long-poll getUpdates and the
// relay's one-shot send compete for the same offset — a silent, hard-to-
// diagnose failure with no error anywhere. Design-specified as a single
// severity, no escalation ladder: "validates the two differ" — either token
// being unconfigured is fine (nothing to collide with), and distinct values
// are fine; only an identical, non-empty pair is ever a problem.
function probeDistinctTokens(item, ctx) {
  const readToken = (fileField, tokenKey) => {
    const filePath = resolveConfigFile(fileField, ctx);
    let raw;
    try {
      raw = fs.readFileSync(filePath, 'utf8');
    } catch (_e) {
      return { value: undefined, filePath };
    }
    return { value: parseDotEnv(raw)[tokenKey], filePath };
  };
  const a = readToken(item.probe.envFileA, item.probe.tokenKeyA);
  const b = readToken(item.probe.envFileB, item.probe.tokenKeyB);
  if (!nonEmpty(a.value) || !nonEmpty(b.value)) {
    return { actual: 'present', detail: 'nothing to collide with — at least one of the two tokens is unconfigured' };
  }
  if (a.value === b.value) {
    return {
      actual: 'degraded',
      detail: `${item.probe.tokenKeyA} in ${a.filePath} is IDENTICAL to ${item.probe.tokenKeyB} in ${b.filePath} — two different bots must not share one token (competing getUpdates offsets)`,
    };
  }
  return { actual: 'present', detail: `${a.filePath} and ${b.filePath} carry distinct tokens` };
}

// ── luna-sources ─────────────────────────────────────────────────────────

// HIMMEL-2176 Task 6, A11: the wizard's luna-source health check used to have
// no manifest presence at all — an operator could finish onboarding with a
// configured clip-source (reddit, firecrawl, ...) silently broken (expired
// cookie, revoked API key) and no signal until the first live clip attempt
// failed. scripts/luna/fetch-health.py --probe <source> (shipped in PR-A, on
// main) already does the real health check — this probe is a thin fold:
// loop the profile's configured sources, shell out once per source, and
// reduce the per-source {status, reason} verdicts to ONE actual/detail
// (mirrors qmd-index's own N-collections-folded-to-one shape above).
//
// Several outcomes per source, not two: fetch-health.py's own STATUSES (ok /
// auth-or-cookie-expired / blocked-or-rate-limited / transport-fail) cover a
// RECOGNIZED source fetch-health.py knows how to check — including a source
// it knows but the adopter never CONFIGURED (no cookie file, no API key),
// which comes back as a normal status (e.g. auth-or-cookie-expired, reason
// "...key missing"). CR fix (codex-3): this used to fold into `problems`
// like any other unhealthy source — a fresh adopter who only set up ONE
// clip source then saw every other, deliberately-unconfigured source read as
// a failure. It is now kept in its OWN bucket (`unconfigured`, see
// UNCONFIGURED_REASON_RE below) — a source the adopter simply never set up
// is not the same problem as one that IS configured and broken (an expired
// cookie, a rejected token): the former is skippable and warns, the latter
// fails. A source name the PROFILE carries that fetch-health.py's OWN registry has
// since dropped, or never implemented, is a DIFFERENT, third case —
// run_single_probe raises ValueError for it, which parser.error() turns into
// argparse's own fixed exit code 2. That source isn't being monitored AT
// ALL, which is a configuration error, not a runtime one — HIMMEL-2176's own
// CR round found the original cut (fold it into a footnote and still report
// 'present') was a fail-open-silently shape (HIMMEL-1128's loud-degradation
// rule): a check that cannot evaluate something must say so at severity, so
// an unrecognized source now forces 'degraded' whenever at least one OTHER
// source was actually evaluated (see `unrecognized` below) — it is kept in
// its own bucket, separate from `problems`, so the detail can tell an
// operator "fix your profile" (unrecognized) apart from "fix your
// credentials" (problems). The one case left unescalated on purpose: when
// EVERY named source is unrecognized (evaluated === 0), there's nothing to
// call healthy in the first place, so it stays 'absent' — the pre-existing,
// honest "nothing was checked" signal, not a new degradation surface.
//
// rc 2 is argparse's fixed code for ANY usage error, not specifically "this
// source doesn't exist" — trusting the bare code would silently reclassify a
// future, unrelated usage error (e.g. a renamed flag) as "unrecognized
// source" too. Cheaply disambiguated instead: run_single_probe's ValueError
// is always worded "unknown probe source: '<name>' (valid sources: ...)",
// and parser.error() prints that verbatim to stderr — matching that literal
// substring is a two-line check against a message this same file's own
// source constructs, not a guess. An rc=2 that DOESN'T carry it is a
// different, unrecognized usage error and folds into `problems` (a wiring
// problem) instead of being silently treated as "this source doesn't exist".
// HIMMEL-2176 CR fix (codex-3): fetch-health.py's STATUSES vocabulary (ok /
// auth-or-cookie-expired / blocked-or-rate-limited / transport-fail) has no
// "unconfigured" state — so a source the adopter simply never set up (no
// reddit cookie file, no Firecrawl API key, ...) used to fold into
// `problems` exactly like a genuinely broken one, turning a fresh
// single-source adopter's every OTHER, deliberately-unused source into a
// wall of failures (the exact false-alarm this epic exists to eliminate;
// design assumption A15: "a skipped source reports unconfigured, not
// error"). fetch-health.py's REASON strings are distinctive when the
// credential/artifact is simply ABSENT — verified against that file's own
// probe_* functions: probe_reddit's "reddit cookie file missing",
// probe_gallery_dl's "<source> cookie file missing", probe_twitter_cli's
// "twitter CLI credentials missing", probe_youtube's "youtube Playwright
// storage state missing", probe_bitbucket's "Bitbucket credentials
// missing", probe_firecrawl's "Firecrawl API key missing" — every one of
// them carries status auth-or-cookie-expired AND ends in the literal word
// "missing", while every OTHER auth-or-cookie-expired reason (an expired/
// unreadable/no-match cookie, a 401/403, an unexpected response shape) does
// not. Matching text is sound here for the same reason the rc=2 "unknown
// probe source" match below is: this exact wording is this same file's own
// source, not a guess. (Status transport-fail carries its own "<tool>
// missing" reasons — e.g. probe_gallery_dl's "gallery-dl missing" — for a
// missing BINARY, an unrelated toolchain problem; the status check keeps
// those out of this bucket.)
const UNCONFIGURED_REASON_RE = /missing$/;

function probeLunaSources(item, ctx) {
  const env = ctx.env || process.env;
  const scriptPath = path.resolve(ctx.repoRoot, item.probe.script);
  const pythonCmd = item.probe.pythonCmd || ((ctx.platform || process.platform) === 'win32' ? 'python' : 'python3');
  const sources = item.probe.sources || [];
  if (sources.length === 0) {
    return { actual: 'absent', detail: 'no luna sources configured to probe' };
  }
  const problems = [];
  const unrecognized = [];
  const unconfigured = [];
  let evaluated = 0;
  for (const source of sources) {
    const envForSpawn = Object.assign({}, env, {
      HIMMEL_PROBE_PY_CMD: pythonCmd,
      HIMMEL_PROBE_LUNA_SCRIPT: scriptPath,
      HIMMEL_PROBE_LUNA_SOURCE: source,
    });
    const r = spawnBashProbe(['-c', '"$HIMMEL_PROBE_PY_CMD" "$HIMMEL_PROBE_LUNA_SCRIPT" --probe "$HIMMEL_PROBE_LUNA_SOURCE"'],
      { env: envForSpawn, cwd: ctx.repoRoot, encoding: 'utf8' });
    if (r.timedOut) { problems.push(`${source}: probe timed out after ${probeTimeoutSecs(r)}s`); continue; }
    if (r.error) { problems.push(`${source}: spawn error: ${r.error.message}`); continue; }
    if (r.status === 127) { problems.push(`${source}: '${pythonCmd}' not found on PATH`); continue; }
    if (r.status === 2) {
      const stderr = (r.stderr || '').trim();
      if (stderr.indexOf('unknown probe source') !== -1) {
        unrecognized.push(source);
      } else {
        problems.push(`${source}: unexpected usage error (rc=2, not the documented 'unknown probe source' shape): ${stderr || '(empty)'}`);
      }
      continue;
    }
    let parsed;
    try {
      parsed = JSON.parse((r.stdout || '').trim());
    } catch (_e) {
      problems.push(`${source}: unparseable probe output (rc=${r.status}): ${(r.stdout || '').trim() || '(empty)'}`);
      continue;
    }
    evaluated += 1;
    if (!parsed || parsed.status !== 'ok') {
      const status = parsed && parsed.status;
      const reason = parsed && parsed.reason;
      if (status === 'auth-or-cookie-expired' && UNCONFIGURED_REASON_RE.test(reason || '')) {
        unconfigured.push(`${source} (${reason})`);
      } else {
        problems.push(`${source}: ${status || 'unknown status'}${reason ? ` (${reason})` : ''}`);
      }
    }
  }
  // An unrecognized source only forces the SAME 'degraded' the problems list
  // already forces — no escalation ladder — but it must not disappear into a
  // footnote on an otherwise-green result: evaluated > 0 means at least one
  // configured source WAS meaningfully checked, so a result here can no
  // longer read 'present' while another configured source is invisible.
  if (problems.length > 0 || (unrecognized.length > 0 && evaluated > 0)) {
    const parts = [];
    if (problems.length > 0) parts.push(`${problems.length} unhealthy (fix credentials/config on the source itself): ${problems.join('; ')}`);
    if (unrecognized.length > 0) {
      parts.push(`${unrecognized.length} not recognized by fetch-health.py and NOT being monitored at all — check the profile for a typo or a source dropped upstream (fix the profile): ${unrecognized.join(', ')}`);
    }
    if (unconfigured.length > 0) {
      parts.push(`${unconfigured.length} not configured yet, skippable (fix by configuring credentials, or ignore if intentionally unused): ${unconfigured.join('; ')}`);
    }
    return { actual: 'degraded', detail: parts.join(' | ') };
  }
  // HIMMEL-2176 CR round 3 fix (retask stage1-build-6d2e): evaluated === 0
  // here (past the problems.length > 0 branch above, and unconfigured always
  // implies evaluated > 0) can ONLY mean every named source was unrecognized
  // by fetch-health.py — a profile that names nothing the probe script knows
  // about, i.e. nothing is being monitored at all. That is a configuration
  // error the adopter must fix, not a lesser signal than the "one bad entry
  // among healthy ones" case above — it must land on the SAME 'degraded'
  // (fail) tier, not 'absent' (warn). Genuinely-nothing-configured (no
  // sources at all, handled above the loop; or every named source merely
  // UNCONFIGURED, handled below) is a different, benign situation and stays
  // 'absent'/warn — the two must not share a verdict.
  if (evaluated === 0) {
    return {
      actual: 'degraded',
      detail: `${unrecognized.length} not recognized by fetch-health.py and NOT being monitored at all — check the profile for a typo or a source dropped upstream (fix the profile): ${unrecognized.join(', ')}`,
    };
  }
  // HIMMEL-2176 CR fix (codex-3): every evaluated source is either healthy or
  // simply UNCONFIGURED (no `problems`, checked above) — that must not read
  // the same as "a configured source is broken" (status-report.js's S2 remap
  // turns 'absent' into a warn, 'degraded' into a fail — see that file's
  // luna-sources block). Covers both "some configured, some not" and "every
  // named source unconfigured" — both benign, both warn.
  if (unconfigured.length > 0) {
    const healthy = evaluated - unconfigured.length;
    const healthyNote = healthy > 0 ? `; ${healthy} other configured source(s) healthy` : '';
    return {
      actual: 'absent',
      detail: `${unconfigured.length} not configured yet, skippable (fix by configuring credentials, or ignore if intentionally unused): ${unconfigured.join('; ')}${healthyNote}`,
    };
  }
  return { actual: 'present', detail: `all ${evaluated} configured luna source(s) healthy` };
}

// ── cadence-coherence / engine-allowlist shared helper ──────────────────

// Map a luna.cadence.schedules key (design §3.3/A9) to the runner basename
// pipeline-cadence.sh actually generates for it (pipeline-cadence.sh's own
// runner_for_name()) — the file this probe treats as "armed" evidence for
// that schedule. Kept here (not re-derived from cadence-format.sh, which has
// no such mapping) as the one small piece of domain knowledge these two
// probes share; the ARMED-OR-NOT signal itself is a plain fs.existsSync,
// same convention as the existing cmd:cadence_armed probe above (a generated
// runner file's presence, not a live schtasks/cron query).
const PIPELINE_RUNNER_BASE = {
  fetchHealth: 'pipeline-fetch-health',
  harvest: 'pipeline-harvest',
  synthesize: 'pipeline-synthesize',
  health: 'pipeline-health',
};

function resolvePipelineBatDir(item, ctx) {
  const env = ctx.env || process.env;
  const home = env.HOME || os.homedir();
  return env[item.probe.envVar] || path.join(home, item.probe.defaultSubdir);
}

// Which of `scheduleKeys` have a generated runner file present under
// `batDir` — the same present-vs-absent signal cmd:cadence_armed already
// uses, just per-schedule instead of "any runner at all".
function armedPipelineSchedules(scheduleKeys, batDir, platform) {
  const ext = platform === 'win32' ? 'bat' : 'sh';
  return scheduleKeys.filter((k) => {
    const base = PIPELINE_RUNNER_BASE[k];
    return Boolean(base) && fs.existsSync(path.join(batDir, `${base}.${ext}`));
  });
}

// ── cadence-coherence ────────────────────────────────────────────────────

// HIMMEL-2176 Task 7 (status item S1, design §3.5): luna.cadence.enabled
// (~/.himmel/config.json, luna-config.js) DECLARES the adopter's intent; a
// registered OS scheduler task is the EXECUTION-side evidence that intent
// actually took effect. Neither one alone proves the cadence is coherent:
// config can say enabled with nothing armed (never ran `arm`, or the tasks
// were deleted out-of-band), or tasks can survive after config flips back to
// disabled (an unmanaged leftover — `disarm` was never run).
//
// CR fix (HIMMEL-2176 CR round 10): this used to treat the mere EXISTENCE of
// a generated runner file (armedPipelineSchedules, a plain fs.existsSync)
// as proof a scheduler task is registered. It is not — a runner file
// persists on disk after its Task Scheduler entry or crontab line is
// deleted, or after an `arm` that failed partway, and S1 is the ONE status
// item whose whole job is catching exactly that "not actually armed" state
// (the silent-04:00-stall class this epic exists to surface). The design's
// own contract (§3.5) is a matching SCHEDULER TASK, not a runner file.
// scripts/luna/pipeline-cadence.sh already owns scheduler interrogation
// (schtasks on Windows, crontab on POSIX) via its `status` subcommand — this
// probe shells out to it and parses its stdout, the same "the script stays
// the single source of truth" posture engine-allowlist already applies to
// cadence-approve-engines.sh below, rather than re-deriving schtasks/cron
// queries here a second way.
//
// `cleanAbsence: true` marks the ordinary, common "never turned on" case
// (enabled:false, nothing armed) — status-report.js's opt-in downgrade for
// this item's id fires ONLY on that flag, never on the "enabled:true but
// nothing armed" genuine-fail case, which stays a loud red (HIMMEL-1128).
//
// Path to the one script this probe trusts for scheduler state — a fixed
// convention (like phi-coherence's phi-roots path above), not a manifest
// field: this item's shape doesn't vary per-install.
const PIPELINE_CADENCE_SCRIPT = 'scripts/luna/pipeline-cadence.sh';

// Map each schedule key to the exact scheduler task name pipeline-cadence.sh
// emits in `status` output (its own TASK_FETCH_HEALTH/TASK_HARVEST/
// TASK_SYNTH/TASK_HEALTH constants) — the scheduler-side counterpart to
// PIPELINE_RUNNER_BASE above, which keys the runner-FILE signal instead.
const PIPELINE_TASK_NAME = {
  fetchHealth: 'HIMMEL-Pipeline-FetchHealth',
  harvest: 'HIMMEL-Pipeline-Harvest',
  synthesize: 'HIMMEL-Pipeline-Synthesize',
  health: 'HIMMEL-Pipeline-Health',
};

// Parses `pipeline-cadence.sh status`'s stdout into the set of schedule keys
// the scheduler itself reports as registered. Both its Windows/schtasks path
// (cmd_status, via cadence-format.sh's shared cadence_registered_status) and
// its POSIX/crontab path (cron_status's own literal echo) print an
// "ARMED      <task-name> ..." / "not armed  <task-name> ..." line per task —
// a stable enough shape to scan by task name without a stricter parser.
// ARMED and UNHEALTHY (registered, but the Windows wscript runner fails its
// own preflight per cadence_registered_status) both count as "a matching
// scheduler task exists" — the design's own S1 wording — since UNHEALTHY is
// a narrower, distinct health signal an operator sees verbatim from `status`
// itself, not a registration question this probe is answering.
function schedulerRegisteredSchedules(stdout) {
  const registered = new Set();
  for (const key of Object.keys(PIPELINE_TASK_NAME)) {
    const re = new RegExp(`^(?:ARMED|UNHEALTHY)\\s+${PIPELINE_TASK_NAME[key]}\\b`, 'm');
    if (re.test(stdout)) registered.add(key);
  }
  return registered;
}

function probeCadenceCoherence(item, ctx) {
  let config;
  try {
    config = scopeConfigPathToCtx(ctx, () => lunaConfig.load());
  } catch (e) {
    return { actual: 'degraded', detail: `cannot read luna config: ${e.message}` };
  }
  const enabled = Boolean(config.luna && config.luna.cadence && config.luna.cadence.enabled);
  const scheduleKeys = Object.keys((config.luna && config.luna.cadence && config.luna.cadence.schedules) || {});
  const env = ctx.env || process.env;
  const scriptPath = path.resolve(ctx.repoRoot, PIPELINE_CADENCE_SCRIPT);
  // `pipeline-cadence.sh status` queries the scheduler once per configured
  // schedule, and on Windows every one of those is a fresh process launch —
  // measured at 8-18s end-to-end on a healthy dev box even with the scheduler
  // faked out, and 3 of 5 runs exceeded the old 10s budget. HIMMEL-2289 gave
  // THIS probe its own 60s constant; HIMMEL-2298 found the same false-DEGRADED
  // one probe over (handover-dir) and moved the budget to PROBE_TIMEOUT_MS, the
  // family default, so the local constant is gone rather than duplicated.
  const r = spawnBashProbe([scriptPath, 'status'], { env, encoding: 'utf8' });
  if (r.timedOut) return { actual: 'degraded', detail: `pipeline-cadence.sh status probe timed out after ${probeTimeoutSecs(r)}s` };
  if (r.error) return { actual: 'degraded', detail: `spawn error: ${r.error.message}` };
  // pipeline-cadence.sh's own status/query paths are fail-CLOSED: any
  // scheduler read it could not trust (schtasks/crontab access denied, the
  // binary missing from PATH, an unsupported platform) exits non-zero rather
  // than printing a clean answer. Reading that as absent-and-clean would be
  // exactly the false-green this fix exists to close, just moved one layer
  // down — this must be a LOUD degraded naming the limitation instead
  // (HIMMEL-1128), never a silent pass or an assumed-healthy default.
  if (r.status !== 0) {
    return {
      actual: 'degraded',
      detail: `pipeline-cadence.sh status could not verify scheduler state (rc=${r.status}): ${(r.stderr || '').trim() || 'no stderr captured'}`,
    };
  }
  const registered = schedulerRegisteredSchedules(r.stdout || '');
  const armed = scheduleKeys.filter((k) => registered.has(k));
  const unarmed = scheduleKeys.filter((k) => !registered.has(k));

  if (!enabled) {
    if (armed.length > 0) {
      return {
        actual: 'degraded',
        detail: `luna.cadence.enabled=false but ${armed.length} scheduler task(s) still registered (unmanaged leftovers — run scripts/luna/pipeline-cadence.sh disarm): ${armed.join(', ')}`,
      };
    }
    return { actual: 'absent', detail: 'luna.cadence.enabled=false and no scheduler tasks registered', cleanAbsence: true };
  }
  if (armed.length === 0) {
    return {
      actual: 'absent',
      detail: `luna.cadence.enabled=true but no scheduler task is registered for any of [${scheduleKeys.join(', ')}] — run scripts/luna/pipeline-cadence.sh arm`,
    };
  }
  if (unarmed.length > 0) {
    return {
      actual: 'degraded',
      detail: `luna.cadence.enabled=true but ${unarmed.length}/${scheduleKeys.length} schedule(s) have no matching REGISTERED scheduler task: ${unarmed.join(', ')}`,
    };
  }
  return { actual: 'present', detail: `all ${scheduleKeys.length} luna cadence schedule(s) have a matching registered scheduler task` };
}

// ── phi-coherence ────────────────────────────────────────────────────────

// HIMMEL-2176 Task 7 (status item S3, design §3.5): a luna vault marked PHI
// via a `.salus` ancestor marker (graph-refresh.sh's/refresh-graph-map.sh's
// `_salus_marked` convention) should also be registered in the operator's
// phi-roots list (~/.config/claude-glm/phi-roots, one path per line — the
// SAME file the egress fence itself consults), and vice versa. A mismatch
// means either the vault THINKS it's PHI-scoped but egress enforcement
// doesn't know it (a leak risk), or phi-roots names a vault carrying no
// local marker (a stale entry). READ-ONLY and INFORMATIONAL — it reports
// coherence, it never enforces anything; the fence's own matcher
// (graph-refresh.sh/refresh-graph-map.sh) stays the single enforcement
// surface, matching engine-allowlist's "the hook stays the single source"
// posture below. No fail tier by design (§3.5): pass when both markers
// agree (present or absent together), warn on a mismatch.
//
// ponytail: the phi-roots comparison below is a SIMPLIFIED prefix match
// (resolve + backslash-normalize + lowercase), not the fence's full
// CRLF/whitespace-tolerant matcher — good enough for a coherence hint, not
// a security boundary; upgrade to a shared matcher only if this probe's own
// false mismatches become a real complaint (avoids a second, driftable copy
// of security-relevant matching logic for a probe that enforces nothing).
function walkForSalusMarker(startDir) {
  let dir = path.resolve(startDir);
  for (;;) {
    if (fs.existsSync(path.join(dir, '.salus'))) return true;
    const parent = path.dirname(dir);
    if (parent === dir) return false;
    dir = parent;
  }
}

// CR fix (HIMMEL-2176, retask stage1-build-6d2e): this used to lowercase
// unconditionally, which is wrong on POSIX — Linux filesystems are
// case-sensitive, so e.g. /home/u/Salus and /home/u/salus are genuinely
// DIFFERENT paths there and must not compare equal. We fold case only on
// win32, whose filesystems default to case-insensitive; POSIX (including
// Linux) keeps its original case. macOS is nominally POSIX but its default
// filesystem (HFS+/APFS) is ALSO case-insensitive in practice — we don't
// special-case it here: detecting real filesystem case-sensitivity at
// runtime is out of scope for a coherence hint (this probe already disclaims
// full fence-matcher fidelity above), so the rule stays the simple
// platform-name check this file already uses elsewhere
// (`ctx.platform || process.platform`, per probeGitHooks/probeWhisperReady).
// CR fix (HIMMEL-2176, retask stage1-build-6d2e): a `~`-prefixed path (either
// side — vaultPath or a phi-roots entry) reached path.resolve() unexpanded,
// which resolves `~` against CWD, not $HOME — a wrong PHI coherence verdict.
// luna-config.js's schema accepts any string for vaultPath, and bridge.envPath's
// own default is itself `~`-prefixed, so this is a realistic shape, not a
// contrived one. Reuses status-report.js's expandHome() (lazy require: this
// module is itself required BY status-report.js, so a top-level require here
// would see a partially-initialized module — deferring the require into the
// call site, after both modules have finished loading, avoids that) rather
// than writing a third variant.
function normalizeForPhiMatch(p, platform) {
  const { expandHome } = require('./status-report.js');
  const normalized = path.resolve(expandHome(p)).replace(/\\/g, '/');
  return platform === 'win32' ? normalized.toLowerCase() : normalized;
}

function vaultListedInPhiRoots(vaultPath, phiRootsPath, platform) {
  let raw;
  try {
    raw = fs.readFileSync(phiRootsPath, 'utf8');
  } catch (_e) {
    return false;
  }
  const target = normalizeForPhiMatch(vaultPath, platform);
  return raw.split(/\r?\n/).some((line) => {
    const entry = line.trim();
    if (!entry || entry.charAt(0) === '#') return false;
    const normalized = normalizeForPhiMatch(entry, platform);
    return target === normalized || target.indexOf(`${normalized}/`) === 0;
  });
}

function probePhiCoherence(item, ctx) {
  const env = ctx.env || process.env;
  let config;
  try {
    config = scopeConfigPathToCtx(ctx, () => lunaConfig.load());
  } catch (e) {
    return { actual: 'degraded', detail: `cannot read luna config: ${e.message}` };
  }
  const rawVaultPath = config.luna && config.luna.vaultPath;
  if (!rawVaultPath) {
    return { actual: 'degraded', detail: 'luna.vaultPath is missing from the config document' };
  }
  // CR fix (HIMMEL-2176, retask stage1-build-6d2e): expand `~` before the
  // fs.existsSync/walkForSalusMarker check below — fs calls don't do tilde
  // expansion, so an unexpanded vaultPath read the marker as absent even
  // when it was present. normalizeForPhiMatch expands again for the
  // phi-roots comparison (a no-op here, since vaultPath is now absolute).
  const { expandHome } = require('./status-report.js');
  const vaultPath = expandHome(rawVaultPath);
  const home = env.HOME || os.homedir();
  const phiRootsPath = path.join(home, '.config', 'claude-glm', 'phi-roots');
  const platform = ctx.platform || process.platform;
  const hasMarker = fs.existsSync(vaultPath) && walkForSalusMarker(vaultPath);
  const listed = vaultListedInPhiRoots(vaultPath, phiRootsPath, platform);
  if (hasMarker === listed) {
    return {
      actual: 'present',
      detail: hasMarker
        ? `${vaultPath} carries a .salus marker and is listed in ${phiRootsPath}`
        : `${vaultPath} carries no .salus marker and is not listed in ${phiRootsPath}`,
    };
  }
  return {
    actual: 'degraded',
    detail: hasMarker
      ? `${vaultPath} carries a .salus marker but is NOT listed in ${phiRootsPath} — egress enforcement may not see it as PHI`
      : `${vaultPath} is listed in ${phiRootsPath} but carries no .salus marker — stale phi-roots entry?`,
  };
}

// ── engine-allowlist ─────────────────────────────────────────────────────

// HIMMEL-2176 Task 7 (status item S4, design §3.5, A18): a luna cadence leg
// (harvest, health, ...) runs an interactive claude session whose Bash tool
// calls are gated by scripts/hooks/cadence-approve-engines.sh's own
// ENGINE_LIST — an armed leg whose invoked engine script ISN'T on that
// allow-list stalls silently at its scheduled hour waiting for a permission
// prompt nobody is there to answer (the exact HIMMEL-1682 failure class this
// hook exists to prevent). `--print-engine-list` (A18, landed in PR-A) is
// the ONE sanctioned way to read the live list — this probe shells out to it
// rather than copying its values or re-deriving them with a JS regex over
// the hook's own source (the hook stays the single source of truth, per its
// own header comment). The leg-to-required-engine-suffix PAIRING itself
// (which schedule needs which engine) is NOT derivable from the live list
// output — it lives in this item's own manifest descriptor (`legs`),
// declarative data alongside the manifest, the same way qmd-index declares
// its own `collections` or luna-sources its own `sources`.
//
// `cleanAbsence: true` marks "no leg with a known engine requirement is
// currently armed" (nothing to check) — status-report.js downgrades that
// case to n/a; an armed leg actually missing a required suffix stays red.
function probeEngineAllowlist(item, ctx) {
  const env = ctx.env || process.env;
  const scriptPath = path.resolve(ctx.repoRoot, item.probe.script);
  const r = spawnBashProbe([scriptPath, '--print-engine-list'], { env, encoding: 'utf8' });
  if (r.timedOut) return { actual: 'degraded', detail: `engine-allowlist probe timed out after ${probeTimeoutSecs(r)}s` };
  if (r.error) return { actual: 'degraded', detail: `spawn error: ${r.error.message}` };
  if (r.status !== 0) return { actual: 'degraded', detail: `cadence-approve-engines.sh --print-engine-list exited rc=${r.status}` };
  const lines = (r.stdout || '').split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  const suffixes = new Set(lines.map((l) => l.slice(l.indexOf(':') + 1)));

  const batDir = resolvePipelineBatDir(item, ctx);
  const platform = ctx.platform || process.platform;
  const armedSchedules = armedPipelineSchedules(Object.keys(PIPELINE_RUNNER_BASE), batDir, platform);

  const legs = item.probe.legs || [];
  const armedLegs = legs.filter((leg) => armedSchedules.indexOf(leg.schedule) !== -1);
  if (armedLegs.length === 0) {
    return {
      actual: 'absent',
      detail: `no luna cadence leg with a known engine requirement is currently armed under ${batDir}`,
      cleanAbsence: true,
    };
  }
  const problems = [];
  for (const leg of armedLegs) {
    const missing = leg.requiredSuffixes.filter((s) => !suffixes.has(s));
    if (missing.length > 0) {
      problems.push(`${leg.schedule}: armed but missing from cadence-approve-engines.sh's allow-list (would silently stall waiting for approval): ${missing.join(', ')}`);
    }
  }
  if (problems.length > 0) {
    return { actual: 'absent', detail: problems.join(' | ') };
  }
  return {
    actual: 'present',
    detail: `every armed leg's required engine(s) are present in cadence-approve-engines.sh's allow-list (${armedLegs.map((l) => l.schedule).join(', ')})`,
  };
}

// ── bridge-health ────────────────────────────────────────────────────────

// HIMMEL-2176 Task 7 (status item S5, design §3.5) — process-identity design
// for "exactly one poller":
//   (1) The count is of poller.ts CONSUMER processes only, never the
//       combined supervisor-or-poller regex restart-bridge.ps1's own
//       Test-BridgeCoreProc uses for a DIFFERENT purpose (liveness, where a
//       supervisor+child pair legitimately coexist). A supervisor plus its
//       poller child is one healthy running bridge, not two — counting with
//       that liveness regex here would read 2 pollers on a correct install
//       and false-fail S5 every time.
//   (2) Platform posture: process identity is Windows-CIM-only today
//       (Get-CimInstance Win32_Process; Get-Process cannot read
//       CommandLine) and there is no JS/TS process-count helper anywhere in
//       this repo. Windows uses a real CIM count (probeBridgePollerCount
//       below); every other platform reads a LOUD 'degraded' naming the
//       limitation (HIMMEL-1128 — never a silent pass) rather than a cheap
//       portable POSIX count (e.g. a /proc scan), which would grow this
//       probe into a cross-platform process-inspection library — out of
//       scope for this Stage-1 pass.
function worstSeverity(a, b) {
  const rank = { absent: 2, degraded: 1, present: 0 };
  return (rank[a] || 0) >= (rank[b] || 0) ? a : b;
}

// Windows-only: count LIVE poller.ts processes via WMI (Get-CimInstance
// Win32_Process), the same primitive restart-bridge.ps1 uses to read a
// process's full CommandLine (Get-Process cannot). Matching on the literal
// substring 'poller.ts' is deliberate and sufficient for ruling (1) above:
// the supervisor's OWN command line never contains that string (it invokes
// supervisor.ts, which then SPAWNS a separate poller.ts child) — so a
// substring match on 'poller.ts' naturally counts only the leaf consumer
// process, with no need to parse out or exclude the supervisor's PID.
//
// CR fix (codex-4, retask stage1-build-6d2e): that substring match was NOT
// anchored to any particular checkout — on a machine with more than one
// himmel checkout/worktree (the normal state of this repo), a poller.ts
// process belonging to a DIFFERENT checkout was counted too, reading either
// a false healthy (a foreign poller mistaken for this one, with THIS
// checkout's own bridge not actually running) or a spurious duplicate-poller
// failure (a foreign, unrelated poller counted alongside this checkout's
// genuinely healthy one). Same class of bug cadence-approve-engines.sh's own
// ROOT ANCHOR closes (HIMMEL-1682 CR round 2, codex-1): a bare tail/substring
// match is never tied to a specific checkout.
// supervisor.ts spawns the real poller.ts process with a bare RELATIVE argv
// (`spawn(["bun","poller.ts"], {cwd: import.meta.dir})`) — restart-bridge.ps1's
// own Test-BridgeCoreProc comment is explicit that "the genuine command
// lines carry NO path" (verified against a live process table). A healthy
// poller from ANY checkout is therefore indistinguishable from this one by
// path alone in that shape — a genuine platform limit this fix does not
// (and per the retask, must not try to) close; a bare, unpathed token is
// still counted exactly as before. What IS closable: when a commandline
// DOES carry a path (an alternate/manual invocation, or a foreign checkout's
// own poller.ts happening to be invoked with one), it is now required to
// resolve to THIS checkout's own scripts/telegram/poller.ts to count — a
// path naming a different checkout is excluded rather than folded into the
// same bucket. Win32_Process's CommandLine has been observed with either
// path separator and NTFS is case-insensitive, so the comparison normalizes
// both sides (forward-slashed, lower-cased) rather than assuming one
// canonical form.
function normalizeForPollerAnchorMatch(p) {
  return p.replace(/\\/g, '/').toLowerCase();
}

// CR round 3 fix (HIMMEL-2176, retask stage1-build-6d2e): a path token was
// previously captured as the longest run of non-whitespace/non-quote chars
// ending in 'poller.ts' — [^\s"']* stops at the first space, so a checkout
// under a path WITH a space (e.g. 'C:\Users\John Doe\himmel\...\poller.ts',
// the same class of path install-engine.js's own positional-arg fix already
// treats as a supported reality here, not a hypothetical) truncated to a
// fragment ('Doe\himmel\...\poller.ts') that can never equal
// thisCheckoutAnchor — a healthy LOCAL poller then read as foreign, and
// bridge-health falsely reported zero pollers. Rather than fight whitespace
// inside a bare regex, this leans on the fact that a Win32_Process
// CommandLine (like any Windows/PowerShell command line) quotes an argument
// that itself contains a space — so a quoted 'poller.ts' path is tried
// FIRST, capturing everything between the quotes (spaces included); only
// when no quoted match exists does this fall back to the original bare-token
// shape, which still covers both an unquoted, space-free path
// ('C:/repo/scripts/telegram/poller.ts') and the bare, unpathed token
// ('poller.ts') supervisor.ts's own relative spawn produces — that bare
// shape carries no path to anchor against and keeps its original "counted,
// unattributable" behaviour unchanged.
const QUOTED_POLLER_TOKEN_RE = /["']([^"']*poller\.ts)["']/i;
const BARE_POLLER_TOKEN_RE = /(\S*poller\.ts)/i;

function extractPollerToken(line) {
  const quoted = line.match(QUOTED_POLLER_TOKEN_RE);
  if (quoted) return quoted[1];
  const bare = line.match(BARE_POLLER_TOKEN_RE);
  return bare ? bare[1] : null;
}

function pollerLineIsThisCheckout(line, thisCheckoutAnchor) {
  const token = extractPollerToken(line);
  if (!token) return false; // defensive: the line was already PowerShell-filtered on 'poller.ts'
  const sepIdx = Math.max(token.lastIndexOf('/'), token.lastIndexOf('\\'));
  if (sepIdx === -1) return true; // bare token, no path — the genuine, unattributable shape; counted, unchanged
  if (!thisCheckoutAnchor) return false; // a path IS present but there is no root to compare it against — fail-safe
  return normalizeForPollerAnchorMatch(token) === thisCheckoutAnchor;
}

function probeBridgePollerCount(ctx) {
  const platform = ctx.platform || process.platform;
  if (platform !== 'win32') {
    return {
      actual: 'degraded',
      detail: `poller-count check not implemented on '${platform}' — Windows-CIM-only today (HIMMEL-2176); process identity is UNVERIFIED here, not assumed healthy`,
    };
  }
  const env = ctx.env || process.env;
  // Routed through `bash -c` (the SAME cross-platform PATH-resolution seam
  // every other cmd:* probe in this file already uses — see e.g.
  // probeTelegramGetMe's `bun -e` call above) rather than spawning
  // `powershell` directly: this is what lets the hermetic test suite fake
  // it via a stub EXECUTABLE on a scrubbed PATH, consistent with this
  // file's own established testing convention (never a JS mock). Emits each
  // matching process's own CommandLine (one per line) rather than a bare
  // Count — the checkout anchor above needs the actual text to compare
  // against ctx.repoRoot, which a pre-reduced count would have thrown away.
  const cmd = "powershell -NoProfile -NonInteractive -Command "
    + "\"Get-CimInstance Win32_Process | Where-Object { \\$_.CommandLine -match 'poller\\.ts' } | ForEach-Object { \\$_.CommandLine }\"";
  const r = spawnBashProbe(['-c', cmd], { env, encoding: 'utf8' });
  if (r.timedOut) return { actual: 'degraded', detail: `poller-count probe timed out after ${probeTimeoutSecs(r)}s` };
  if (r.error) return { actual: 'degraded', detail: `spawn error: ${r.error.message}` };
  if (r.status !== 0) return { actual: 'degraded', detail: `Get-CimInstance poller-count query exited rc=${r.status}` };
  const lines = (r.stdout || '').split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  const thisCheckoutAnchor = ctx.repoRoot
    ? normalizeForPollerAnchorMatch(path.join(ctx.repoRoot, 'scripts', 'telegram', 'poller.ts'))
    : null;
  const n = lines.filter((line) => pollerLineIsThisCheckout(line, thisCheckoutAnchor)).length;
  if (n === 1) return { actual: 'present', detail: '1 poller.ts process running for this checkout (a supervisor parent, if any, is not counted)' };
  return { actual: 'absent', detail: `${n} poller.ts process(es) running for this checkout (expected exactly 1)` };
}

// probeBridgeHealth folds three independent AND-conditions (token getMe ok +
// access.json schema ok + exactly one poller) into ONE tri-state result,
// reusing probeTelegramAccess/probeTelegramGetMe UNCHANGED (their probe
// descriptors share the same envFile/tokenKey/accessFile/apiModule field
// names this item's descriptor also carries) — the same "fold existing
// per-source probes" shape luna-sources already established, applied here
// to a fixed 3-source set instead of a variable one.
//
// `cleanAbsence: true` (mirrors telegram-access's own absent-vs-degraded
// split) marks the ordinary "bridge never configured" case (token entirely
// missing) — short-circuited BEFORE the getMe/poller-count checks run at
// all (no live network call or process spawn for the common case of an
// adopter who never set up the bridge). status-report.js's opt-in downgrade
// fires ONLY on this flag; a PARTIALLY configured or genuinely broken
// bridge stays a loud red/degraded.
//
// CR fix (HIMMEL-2176 round 6): a missing token alone used to be enough for
// cleanAbsence — that's wrong for an adopter who set bridge.enabled: true in
// ~/.himmel/config.json (they explicitly asked for this subsystem; a missing
// token is a real failure, not "never opted in"). Consulting
// ~/.himmel/config.json here, the same way probeCadenceCoherence already
// does for cadence-armed (both read it directly via lunaConfig.load(),
// scoped to ctx.env through scopeConfigPathToCtx rather than reading the
// ambient process.env unscoped — retask stage1-build-6d2e), is what makes
// "cleanAbsence means genuinely not opted in" hold for this item the same
// way it already does for cadence-armed, instead of special-casing
// bridge.enabled at the status layer while the probe stays oblivious to it.
function probeBridgeHealth(item, ctx) {
  const accessResult = probeTelegramAccess(item, ctx);
  if (accessResult.actual === 'absent') {
    let config;
    try {
      config = scopeConfigPathToCtx(ctx, () => lunaConfig.load());
    } catch (e) {
      return { actual: 'degraded', detail: `cannot read luna config: ${e.message}` };
    }
    const bridgeEnabled = Boolean(config.bridge && config.bridge.enabled);
    if (!bridgeEnabled) {
      return { actual: 'absent', detail: accessResult.detail, cleanAbsence: true };
    }
    return {
      actual: 'absent',
      detail: `${accessResult.detail} (bridge.enabled=true in ~/.himmel/config.json — explicitly opted in, so this stays a genuine failure, not opt-in)`,
    };
  }
  const getMeResult = probeTelegramGetMe(item, ctx);
  const pollerResult = probeBridgePollerCount(ctx);
  const worst = worstSeverity(worstSeverity(accessResult.actual, getMeResult.actual), pollerResult.actual);
  if (worst === 'present') {
    return { actual: 'present', detail: `token getMe ok; access.json schema ok; ${pollerResult.detail}` };
  }
  const parts = [];
  if (accessResult.actual !== 'present') parts.push(`access.json: ${accessResult.detail}`);
  if (getMeResult.actual !== 'present') parts.push(`getMe: ${getMeResult.detail}`);
  if (pollerResult.actual !== 'present') parts.push(`poller-count: ${pollerResult.detail}`);
  return { actual: worst, detail: parts.join(' | ') };
}

// ── bridge-persistence (status item S6) ─────────────────────────────────

// HIMMEL-2176 Stage-1 PR-C, status item S6 (design §3.5): a logon task
// (win) / systemd unit + linger (linux) must exist whenever bridge.enabled —
// otherwise the bridge silently stops surviving a reboot/logout (the same
// silent-04:00-stall class S1 named for cadence). bridge.enabled:false is a
// clean opt-out, not a failure — mirrors cadence-armed/engine-allowlist/
// bridge-health's own additive `cleanAbsence` flag (status-report.js
// downgrades it to an n/a opt-in hint instead of red). Every OTHER failure/
// limitation reads 'degraded' (a loud warn) — this item's contract is
// pass/warn/opt-in, never a hard 'absent'/red once the adopter has opted in.
//
// Windows: registration must be verified by QUERYING THE SCHEDULER itself
// (schtasks), never inferred from any file on disk — a defect caught in the
// predecessor PR was exactly an S1 false-green (a runner FILE's presence
// mistaken for proof a scheduler task was registered). A query FAILURE
// (spawn error, timeout, an unrecognized exit code, OR a caught
// Get-ScheduledTask error that isn't the exact "no such task" identifier —
// e.g. the ScheduledTasks module unavailable, access denied, a WinRM/CIM
// problem) is reported as unknown, never absent and never present —
// probeWindowsSchedulerTaskState()'s `state` never resolves to anything but
// 'registered' on rc=0, and 'absent' only on a genuinely confirmed not-found.
//
// Linux: persistence = the systemd user unit installed+enabled AND linger
// enabled. Linger absent is reported as ITS OWN warn (never folded into a
// generic "unit missing") — a user unit without linger only runs while the
// operator is logged in, the exact failure spec A12/V5 calls out.
//
// macOS/other: launchd support is explicitly Stage 2 (A12) — this does NOT
// build a process/service-inspection library for it; it reads a LOUD
// degraded naming the limitation (HIMMEL-1128: never a silent pass), the
// same platform posture bridge-health's own Windows-CIM-only poller-count
// check already established.
// CR fix (codex-1, retask stage1-build-6d2e round 6, CRITICAL): rc=0 from
// `schtasks /query` only proves the task EXISTS — schtasks still exits 0 for
// a task that is registered but DISABLED, and a disabled task will not run
// at logon (the exact thing S6 exists to verify). Existence is not
// enablement — the same class as the predecessor's S1 false-green and this
// same ticket's own bridge-persistence.js round-3 uninstall gap. `/v`
// (verbose) is added so the query's own stdout carries the `Scheduled Task
// State` field; that field is parsed and only `Enabled` reads 'registered'.
function probeWindowsSchedulerTaskState(ctx) {
  const env = ctx.env || process.env;
  const taskName = bridgePersistence.WINDOWS_LOGON_TASK_NAME;
  // CR fix (codex-2, retask stage1-build-6d2e round 7): the round-6 fix
  // parsed schtasks' `/fo LIST /v` TEXT output for the literal label
  // "Scheduled Task State" and value "Enabled" — both are LOCALIZED by
  // Windows (German/Japanese/Spanish/... display strings), so on a
  // non-English install the label never matches and a perfectly healthy
  // enabled task silently degrades (safe direction, but still an
  // operator-environment assumption baked into adopter-facing code — the
  // exact class this whole PR exists to eliminate). Get-ScheduledTask's
  // `.State` is a genuine .NET enum (Microsoft.PowerShell.ScheduledTask's
  // TaskState) — `.ToString()` returns the symbolic member name
  // (Ready/Disabled/Running/Queued/Unknown), which is culture-invariant BY
  // CONSTRUCTION, unlike schtasks' display strings. Routed through `bash -c`
  // (this file's own established cross-platform seam — see
  // probeBridgePollerCount above) so a stub on PATH fakes this hermetically,
  // never a JS mock. `$_` is escaped as `\$_` for bash (same convention
  // probeBridgePollerCount's own Get-CimInstance call already uses) since
  // the whole command reaches bash inside literal double quotes.
  //
  // CR fix (codex-2, retask stage1-build-6d2e round 12): this used to
  // hardcode the literal binary name `powershell` — a machine with ONLY
  // PowerShell 7 (`pwsh`) and no Windows PowerShell would never resolve it,
  // reading persistence as unknown forever even though bridge-persistence.js
  // (the installer half of this same S6 feature) already resolves the
  // interpreter correctly via helpers.js's resolvePowershell() (prefers
  // `pwsh`, falls back to `powershell` with a stderr warning). Reusing that
  // SAME helper here — never a second, independent resolution path — is
  // what keeps the installer and the probe from disagreeing about which
  // interpreter exists on this machine. The resolved name/path is
  // double-quoted in the command string (which()'s own resolution can
  // return a full path, e.g. one containing "Program Files") — the same
  // quoting convention this file's other bash -c commands already use for
  // any interpolated path (see e.g. probeCmdHasQmd's `. "${resolverPath}"`).
  //
  // CR fix (retask stage1-build-6d2e, third face of the tri-state class this
  // round is fixing): `-ErrorAction SilentlyContinue` swallows EVERY error
  // into the same empty-stdout/rc=0 shape — a genuinely missing task AND a
  // real query failure (ScheduledTasks module unavailable, access denied,
  // WinRM/CIM trouble) both used to read 'absent'. Switched to
  // `-ErrorAction Stop` inside a try/catch so the two are told apart: on
  // success, stdout is `STATE:<enum>`; on a caught error, stdout is
  // `NOTFOUND` only when `$_.FullyQualifiedErrorId` matches the exact,
  // non-localized identifier PowerShell uses for "no such task"
  // (`CmdletizationQuery_NotFound_TaskName,Get-ScheduledTask` — confirmed
  // against a real Windows host: FullyQualifiedErrorId segments are stable
  // internal identifiers, never translated, unlike `.Exception.Message` or
  // even `.CategoryInfo.Category` — the latter reads the SAME
  // 'ObjectNotFound' for a missing task AND for the module itself being
  // unavailable (CommandNotFoundException), so it can't carry this
  // distinction on its own). Any other caught error emits `ERR:<FQEID>` —
  // read as unknown/degraded, never absent, the same fail-safe posture as
  // every other undetermined branch in this function.
  const psBin = resolvePowershell(env);
  const cmd = `"${psBin}" -NoProfile -NonInteractive -Command `
    + '"try { \\$t = Get-ScheduledTask -TaskName \'' + taskName + '\' -ErrorAction Stop; '
    + 'Write-Output (\'STATE:\' + \\$t.State.ToString()) } catch { '
    + 'if (\\$_.FullyQualifiedErrorId -like \'CmdletizationQuery_NotFound_TaskName*\') { Write-Output \'NOTFOUND\' } '
    + 'else { Write-Output (\'ERR:\' + \\$_.FullyQualifiedErrorId) } }"';
  const r = spawnBashProbe(['-c', cmd], { env, encoding: 'utf8' });
  if (r.timedOut) return { state: 'unknown', detail: `Get-ScheduledTask query for '${taskName}' timed out after ${probeTimeoutSecs(r)}s — registration status could not be determined` };
  if (r.error) return { state: 'unknown', detail: `Get-ScheduledTask query for '${taskName}' failed to spawn: ${r.error.message} — registration status could not be determined` };
  if (r.status !== 0) return { state: 'unknown', detail: `Get-ScheduledTask query for '${taskName}' exited rc=${r.status} — registration status could not be determined (treated as unknown, never present)` };
  const out = (r.stdout || '').trim();
  if (!out) return { state: 'unknown', detail: `Get-ScheduledTask query for '${taskName}' produced no output — registration status could not be determined (treated as unknown, never present)` };
  if (out === 'NOTFOUND') return { state: 'absent', detail: `Get-ScheduledTask reports no scheduled task named '${taskName}' registered with the Windows Task Scheduler` };
  if (out.startsWith('ERR:')) {
    return {
      state: 'unknown',
      detail: `Get-ScheduledTask query for '${taskName}' failed (${out.slice(4)}) — registration status could not be determined (treated as unknown, NOT assumed absent — e.g. ScheduledTasks module unavailable, access denied, or a WinRM/CIM problem)`,
    };
  }
  if (!out.startsWith('STATE:')) {
    return { state: 'unknown', detail: `Get-ScheduledTask query for '${taskName}' returned an unrecognized response '${out}' — registration status could not be determined (treated as unknown, never present)` };
  }
  const taskState = out.slice('STATE:'.length);
  // Ready/Running/Queued are all "will fire" states (Queued is a transient
  // in-flight state, not a disabled one) — Disabled is the one state S6
  // exists to catch. Any OTHER value (a future TaskState member this build
  // doesn't know about) reads unknown — fail-safe, never silently folded
  // into either bucket.
  if (taskState === 'Ready' || taskState === 'Running' || taskState === 'Queued') {
    return { state: 'registered', detail: `Get-ScheduledTask reports the scheduled task '${taskName}' is registered and ${taskState} (culture-invariant State enum)` };
  }
  if (taskState === 'Disabled') {
    return {
      state: 'disabled',
      detail: `Get-ScheduledTask reports the scheduled task '${taskName}' exists but its State is Disabled — it will NOT run at logon (fix: Enable-ScheduledTask -TaskName "${taskName}")`,
    };
  }
  return { state: 'unknown', detail: `Get-ScheduledTask reports the scheduled task '${taskName}' exists with an unrecognized State '${taskState}' — registration status could not be determined (treated as unknown, never present)` };
}

// CR fix (retask stage1-build-6d2e, final round): the SPAWN side of the same
// ctx.env class scopeConfigPathToCtx already fixed for the config-path read
// — one layer further out. bridgePersistence.systemdUnitInstalled()/
// lingerEnabled() take no parameters at all: they resolve `systemctl`/
// `loginctl` via which() with NO env argument (ambient process.env.PATH),
// and spawn them via spawnSync with no `env` option (the child inherits the
// WHOLE ambient process.env, not just PATH) — bridge-persistence.js is a
// sibling agent's file this round and is off limits, so there is no
// `{ env }` parameter to pass through even if we wanted one. The only seam
// reachable from here is the same one scopeConfigPathToCtx already uses:
// scope process.env itself for the duration of the call. Unlike that
// helper (which only needs to shadow ONE key), which()'s PATH lookup and
// the spawned child's inherited environment both depend on the ENTIRE
// env object, so this swaps all of it — save/restore is safe here because
// systemdUnitInstalled()/lingerEnabled() are fully synchronous (spawnSync),
// so nothing else can observe process.env mid-swap on Node's single
// threaded event loop.
//
// NOT reachable this way, and NOT fixed by this: systemdUnitInstalled()'s
// `unitInfo.fileExists`/`unitInfo.unitPath` are derived from
// SYSTEMD_USER_UNIT_DIR, a MODULE-LEVEL `const` in bridge-persistence.js
// evaluated ONCE at require() time from `process.env.
// HIMMELCTL_SYSTEMD_USER_UNIT_DIR` (falling back to `os.homedir()`) — by
// the time this probe runs, that value is frozen; no per-call env swap from
// probes.js can retroactively change it. Closing that gap needs an actual
// bridge-persistence.js signature change: systemdUnitInstalled(ctx) (or
// `{ env }`) computing the unit dir from the passed env at CALL time
// instead of a frozen module constant — see this function's own report for
// the exact routing note.
function scopeEnvToCtx(ctx, fn) {
  if (!ctx || !ctx.env || ctx.env === process.env) return fn();
  const prev = Object.assign({}, process.env);
  for (const k of Object.keys(process.env)) delete process.env[k];
  Object.assign(process.env, ctx.env);
  try {
    return fn();
  } finally {
    for (const k of Object.keys(process.env)) delete process.env[k];
    Object.assign(process.env, prev);
  }
}

// Best-effort username for the systemd `loginctl show-user`/`enable-linger`
// calls bridge-persistence.js's lingerEnabled() needs — env first (the
// documented seam a hermetic test drives), else os.userInfo() (some
// sandboxes carry no passwd entry — guarded, never thrown).
function bridgePersistenceUser(ctx) {
  const env = ctx.env || process.env;
  if (nonEmpty(env.USER)) return env.USER;
  if (nonEmpty(env.LOGNAME)) return env.LOGNAME;
  try {
    return os.userInfo().username;
  } catch (_e) {
    return null;
  }
}

function probeBridgePersistence(item, ctx) {
  let config;
  try {
    config = scopeConfigPathToCtx(ctx, () => lunaConfig.load());
  } catch (e) {
    return { actual: 'degraded', detail: `cannot read luna config: ${e.message}` };
  }
  const bridgeEnabled = Boolean(config.bridge && config.bridge.enabled);
  if (!bridgeEnabled) {
    return {
      actual: 'absent',
      detail: 'bridge.enabled is not true in ~/.himmel/config.json — persistence is not required',
      cleanAbsence: true,
    };
  }

  const platform = ctx.platform || process.platform;

  if (platform === 'win32') {
    const taskResult = probeWindowsSchedulerTaskState(ctx);
    if (taskResult.state === 'registered') {
      return { actual: 'present', detail: taskResult.detail };
    }
    return {
      actual: 'degraded',
      detail: `${taskResult.detail} (bridge.enabled=true) — the bridge will not restart automatically after a reboot/logon without it`,
    };
  }

  if (platform === 'linux') {
    const unitInfo = scopeEnvToCtx(ctx, () => bridgePersistence.systemdUnitInstalled());
    if (!unitInfo.fileExists) {
      return {
        actual: 'degraded',
        detail: `systemd user unit '${bridgePersistence.SYSTEMD_UNIT_NAME}' is not installed at ${unitInfo.unitPath} (bridge.enabled=true) — the bridge will not survive a reboot/logout without it`,
      };
    }
    // CR fix (round 6, retask stage1-build-6d2e): systemdUnitInstalled()'s
    // `enabled` is a genuine tri-state (true/false/null — see its own
    // comment in bridge-persistence.js) — null means UNDETERMINED (no
    // systemctl on this host, or `is-enabled` exited with a code other than
    // 0/1), not "confirmed not enabled". The old `enabled !== true` check
    // folded both into the same "is installed but not enabled" wording,
    // which tells an operator to `systemctl enable` a unit whose enablement
    // was never actually established — the wrong remediation when the real
    // problem is that systemctl couldn't be queried at all. Named separately
    // here, mirroring the Windows branch's own present/disabled/unknown
    // split above. The verdict stays 'degraded' in both cases.
    if (unitInfo.enabled === null) {
      return {
        actual: 'degraded',
        detail: `systemd user unit '${bridgePersistence.SYSTEMD_UNIT_NAME}' is installed at ${unitInfo.unitPath}, but whether it is enabled could not be determined (systemctl is unavailable, or 'systemctl --user is-enabled' exited with an unexpected code) (bridge.enabled=true) — verify manually: systemctl --user is-enabled ${bridgePersistence.SYSTEMD_UNIT_NAME}`,
      };
    }
    if (unitInfo.enabled === false) {
      return {
        actual: 'degraded',
        detail: `systemd user unit '${bridgePersistence.SYSTEMD_UNIT_NAME}' is installed but not enabled at ${unitInfo.unitPath} (bridge.enabled=true) — the bridge will not survive a reboot/logout without it`,
      };
    }
    const user = bridgePersistenceUser(ctx);
    const linger = scopeEnvToCtx(ctx, () => bridgePersistence.lingerEnabled({ user }));
    // Same tri-state shape as unitInfo.enabled above — lingerEnabled()
    // returns null when it is undetermined (no loginctl, or the query
    // failed), not when linger is confirmed off. Split for the same reason.
    if (linger === null) {
      return {
        actual: 'degraded',
        detail: `systemd user unit '${bridgePersistence.SYSTEMD_UNIT_NAME}' is installed and enabled, but whether linger is enabled for '${user || '(unknown user)'}' could not be determined (loginctl is unavailable, or the query failed) (bridge.enabled=true) — verify manually: loginctl show-user ${user || '<user>'} --property=Linger`,
      };
    }
    if (linger === false) {
      return {
        actual: 'degraded',
        detail: `systemd user unit '${bridgePersistence.SYSTEMD_UNIT_NAME}' is installed and enabled, but linger is NOT enabled for '${user || '(unknown user)'}' (bridge.enabled=true) — the unit only runs while logged in and stops at logout (fix: loginctl enable-linger ${user || '<user>'})`,
      };
    }
    return {
      actual: 'present',
      detail: `systemd user unit '${bridgePersistence.SYSTEMD_UNIT_NAME}' installed + enabled, linger on for '${user}'`,
    };
  }

  return {
    actual: 'degraded',
    detail: `bridge-persistence check not implemented on '${platform}' — launchd/macOS persistence is Stage 2 (HIMMEL-2176, A12); persistence is UNVERIFIED here, not assumed healthy (bridge.enabled=true)`,
  };
}

// ── observability-stack (HIMMEL-2326) ───────────────────────────────────
//
// The Phase A observability stack (HIMMEL-922: local Prometheus + Grafana +
// windows_exporter + the Bun flow-exporter) registers FOUR scheduled tasks
// at install time — restart-stack.sh's own hard allowlist (the
// authoritative task-name family, ~L190-216) is the single source of truth
// this list mirrors. Parity is TEST-ENFORCED, not asserted on faith
// (HIMMEL-2326 CR round 1, codex-2): this probe does NOT re-parse
// restart-stack.sh at runtime (extra file I/O + bash-parsing fragility on a
// probe that must stay fast/dependency-free) — instead
// scripts/install/test-observability-stack-manifest.sh's own drift case
// extracts both lists from source and asserts them equal, failing loudly if
// this array and restart-stack.sh's allowlist ever diverge:
const OBSERVABILITY_TASK_NAMES = [
  'himmel-observability-flow-exporter',
  'himmel-observability-grafana',
  'himmel-observability-prometheus',
  'himmel-observability-windows-exporter',
];

// No descriptor fields — the four names above are a fixed convention (same
// posture as cmd:codex_provisioned/phi-coherence/bridge-persistence), not
// per-item configuration.
//
// Phase A (HIMMEL-922) ships a Windows-only installer (install-stack.ps1,
// Register-LogonTask per exporter); install-stack.sh is an 11-line loud
// placeholder that exits 2 (cross-platform packaging is tracked as its own
// gap, HIMMEL-2333 — not something this probe assumes will land). On posix
// this is honest about that: it never spawns the doomed placeholder and
// never reports 'present' or a silent 'degraded' that would imply a
// repairable partial install — a plain 'absent' naming the reason.
//
// On win32, ONE Get-ScheduledTask query (wildcard 'himmel-observability-*',
// same -ErrorAction Stop / FullyQualifiedErrorId discipline as
// probeWindowsSchedulerTaskState above) folds the four tasks' live State
// into a tri-state verdict: all four Ready/Running/Queued -> present; a
// query-level failure (spawn error, timeout, nonzero exit, unparseable
// output, or a caught PowerShell error) -> degraded, never silently read as
// absent or present (same fail-safe posture as S6's bridge-persistence
// probe above); the query succeeding with zero matching tasks -> absent
// (the stack was never installed); anything in between (some tasks
// registered, some missing, or one Disabled) -> degraded, naming exactly
// which task(s) are the problem — the literal "Grafana up, exporters
// absent" honesty case HIMMEL-2326 asks for.
function probeObservabilityStack(item, ctx) {
  const env = ctx.env || process.env;
  const platform = ctx.platform || process.platform;
  if (platform !== 'win32') {
    return {
      actual: 'absent',
      detail: 'observability install-stack is Windows-only in Phase A (HIMMEL-922) — install-stack.sh is a loud placeholder that exits 2; cross-platform packaging is tracked as HIMMEL-2333, so this reads absent on every non-Windows host, never present or a repairable-looking degraded',
    };
  }
  const psBin = resolvePowershell(env);
  // The WILDCARD TaskName is load-bearing, and is why -ErrorAction Stop is safe
  // here: Get-ScheduledTask with a wildcard matching nothing returns an EMPTY
  // set — it does NOT throw — so a clean host falls through to the else-branch
  // and reports NONE -> 'absent'. A LITERAL TaskName that matches nothing DOES
  // throw; that asymmetry is what makes this look wrong at a glance, and CR
  // rounds 1 and 2 each raised it as a false 'degraded'. Verified live on
  // win32: `Get-ScheduledTask -TaskName 'himmel-nonexistent-pattern-*'
  // -ErrorAction Stop` returns count=0 without throwing. The catch below
  // therefore fires only on a REAL query failure (ScheduledTasks module
  // missing, access denied, CIM/WinRM fault) — correctly degraded, and
  // deliberately never 'absent', since an unanswerable query is not evidence
  // the stack is uninstalled.
  const cmd = `"${psBin}" -NoProfile -NonInteractive -Command `
    + '"try { \\$tasks = Get-ScheduledTask -TaskName \'himmel-observability-*\' -ErrorAction Stop; '
    + 'if (\\$tasks) { \\$tasks | ForEach-Object { Write-Output (\\$_.TaskName + \':\' + \\$_.State.ToString()) } } else { Write-Output \'NONE\' } '
    + '} catch { Write-Output (\'ERR:\' + \\$_.FullyQualifiedErrorId) }"';
  const r = spawnBashProbe(['-c', cmd], { env, encoding: 'utf8' });
  if (r.timedOut) return { actual: 'degraded', detail: `Get-ScheduledTask query for the himmel-observability-* family timed out after ${probeTimeoutSecs(r)}s — stack status could not be determined` };
  if (r.error) return { actual: 'degraded', detail: `Get-ScheduledTask query for the himmel-observability-* family failed to spawn: ${r.error.message} — stack status could not be determined` };
  if (r.status !== 0) return { actual: 'degraded', detail: `Get-ScheduledTask query for the himmel-observability-* family exited rc=${r.status} — stack status could not be determined` };
  const out = (r.stdout || '').trim();
  if (!out) return { actual: 'degraded', detail: 'Get-ScheduledTask query for the himmel-observability-* family produced no output — stack status could not be determined' };
  if (out.startsWith('ERR:')) {
    return {
      actual: 'degraded',
      detail: `Get-ScheduledTask query for the himmel-observability-* family failed (${out.slice(4)}) — stack status could not be determined (treated as unknown, never assumed absent — e.g. ScheduledTasks module unavailable, access denied, or a WinRM/CIM problem)`,
    };
  }
  if (out === 'NONE') {
    return { actual: 'absent', detail: 'no himmel-observability-* scheduled tasks are registered with the Windows Task Scheduler — the stack has not been installed' };
  }
  const states = new Map();
  for (const line of out.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const idx = trimmed.lastIndexOf(':');
    if (idx === -1) continue;
    states.set(trimmed.slice(0, idx), trimmed.slice(idx + 1));
  }
  const running = [];
  const problems = [];
  for (const name of OBSERVABILITY_TASK_NAMES) {
    const state = states.get(name);
    if (state === 'Ready' || state === 'Running' || state === 'Queued') {
      running.push(name);
    } else if (state === 'Disabled') {
      problems.push(`${name}: Disabled`);
    } else if (state === undefined) {
      problems.push(`${name}: not registered`);
    } else {
      problems.push(`${name}: unrecognized state '${state}'`);
    }
  }
  // CR round 3 (codex-1): 'running' here also covers 'Ready' (registered +
  // enabled, but NOT currently executing) and 'Queued' (a transient
  // in-flight state) — only the literal 'Running' state means actually
  // executing right now. A detail claiming "running" for a host where every
  // task is merely Ready overstates exactly what this probe exists to be
  // honest about. "registered and enabled" is what the states actually
  // prove, on both the present and degraded strings.
  if (running.length === OBSERVABILITY_TASK_NAMES.length) {
    return { actual: 'present', detail: `all ${OBSERVABILITY_TASK_NAMES.length} himmel-observability-* scheduled tasks registered and enabled` };
  }
  return {
    actual: 'degraded',
    detail: `partial install — ${running.length}/${OBSERVABILITY_TASK_NAMES.length} himmel-observability-* tasks registered and enabled; ${problems.join(', ')}`,
  };
}

// ── dispatch ─────────────────────────────────────────────────────────────

const PROBES = {
  'file-exists': probeFileExists,
  'git-hooks': probeGitHooks,
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
  'cmd:telegram_getme': probeTelegramGetMe,
  'cmd:whisper_ready': probeWhisperReady,
  'cmd:python_interpreter': probePythonInterpreter,
  'distinct-tokens': probeDistinctTokens,
  'luna-sources': probeLunaSources,
  'cadence-coherence': probeCadenceCoherence,
  'phi-coherence': probePhiCoherence,
  'engine-allowlist': probeEngineAllowlist,
  'bridge-health': probeBridgeHealth,
  'bridge-persistence': probeBridgePersistence,
  'observability-stack': probeObservabilityStack,
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
