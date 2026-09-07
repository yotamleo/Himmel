#!/usr/bin/env node
// scripts/install/capture-operator-profile.mjs — HIMMEL-2307.
//
// Captures THIS machine's live state into the v2 install-profile shape
// (schemaVersion 2 — see docs/setup/profiles/README.md) plus a "delta"
// object naming everything the wizard cannot yet ask about. Read-only:
// no arm/disarm, no writes to ~/.claude, no scheduled-task mutation.
//
// SECRETS: captures key NAMES and boolean presence only, never values. A
// scrub pass replaces the real home directory / username with placeholder
// tokens before any emission, then a self-test asserts none of that leaked
// through (fails loudly if it did — gitleaks discipline).
//
// Determinism: two consecutive runs on an unchanged machine emit
// byte-identical profile + delta — every object's keys are sorted, every
// array of ids is sorted, and nothing carries a timestamp.
//
// Modes:
//   --json                    print {profile, delta} JSON to stdout
//   --profile-out <path>      write ONLY the scrubbed v2 profile object
//                             (pretty JSON + trailing newline)
//   --delta-out <path>        write ONLY the delta object (same format)
//   --check <profile-path>    fresh capture vs. a committed profile file;
//                             prints a field-level diff on drift
//   (no args)                 human-readable summary
//
// Exit codes:
//   0 — success (every mode), or --check found no drift
//   1 — --check found drift (diff printed to stdout)
//   2 — usage/runtime error
//
// Test overrides (see test-capture-operator-profile.sh):
//   HOME / USERPROFILE, CLAUDE_CONFIG_DIR, HIMMEL_OBSERVABILITY_CONFIG,
//   LANES_REGISTRY, HIMMEL_CAPTURE_SCHTASKS_CMD (stub schtasks binary),
//   WHISPER_DIR / WHISPER_MODEL.

import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir, userInfo } from 'node:os';
import { basename, dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
// HIMMEL_CAPTURE_REPO_ROOT overrides the repo root the capture reads
// everything REPO_ROOT-relative from (.env.example, docs/setup/
// settings-template.json, scripts/lanes/*, scripts/himmelctl/lib/
// adopter-profile.js, scripts/guardrails/lib.sh, and — via
// primaryCheckoutRoot() — the primary checkout's .env). Same idiom as
// scripts/lib/load-dotenv.sh's own `--root` override: the test suite points
// this at a fixture tree instead of copying the script itself.
const REPO_ROOT = process.env.HIMMEL_CAPTURE_REPO_ROOT ? resolve(process.env.HIMMEL_CAPTURE_REPO_ROOT) : resolve(SCRIPT_DIR, '..', '..');
const require = createRequire(import.meta.url);

// ── generic helpers ─────────────────────────────────────────────────────
function readJsonSafe(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return null; }
}
function sortKeysDeep(v) {
  if (Array.isArray(v)) return v.map(sortKeysDeep);
  if (v && typeof v === 'object') {
    const out = {};
    for (const k of Object.keys(v).sort()) out[k] = sortKeysDeep(v[k]);
    return out;
  }
  return v;
}

// ── scrub pass (never emit a real path/username) ───────────────────────
// Each regex carries a safe LABEL (never the regex source, never the
// matched text) — assertScrubbed's failure message names only the label
// and the JSON path of the offending field, since the regex source IS the
// escaped real home path/username and must never itself reach stderr.
function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
function resolveUser() {
  try { return userInfo().username || ''; } catch { return process.env.USERNAME || process.env.USER || ''; }
}
function buildScrubRegexes(home, user) {
  const variants = new Set();
  if (home) {
    variants.add(home);
    variants.add(home.replace(/\\/g, '/'));
    // Under Git Bash, HOME/USERPROFILE reach node MSYS-translated to
    // forward-slash form ("C:/Users/x"), so homedir() itself is
    // forward-slash — but OS-native strings this fix's scrubText() now also
    // scrubs (fs error messages, path.join output) always use backslash on
    // win32. Without this reverse variant, only a home path's USERNAME
    // segment would get redacted out of such a message, not the full path.
    variants.add(home.replace(/\//g, '\\'));
    // assertScrubbed tests JSON.stringify(obj) output, which doubles every
    // backslash — a raw single-backslash home regex can silently fail to
    // match its own doubled-up form there (codex-5). Add that form too, for
    // every backslash-bearing variant above.
    for (const v of [...variants]) if (v.includes('\\')) variants.add(v.replace(/\\/g, '\\\\'));
  }
  const regexes = [...variants].filter(Boolean).map((v) => ({ re: new RegExp(escapeRe(v), 'gi'), label: 'home-directory path' }));
  if (user && user.length >= 3) regexes.push({ re: new RegExp(`\\b${escapeRe(user)}\\b`, 'gi'), label: 'username' });
  return regexes;
}
function scrubDeep(v, regexes) {
  if (Array.isArray(v)) return v.map((x) => scrubDeep(x, regexes));
  if (v && typeof v === 'object') {
    const out = {};
    for (const [k, val] of Object.entries(v)) out[k] = scrubDeep(val, regexes);
    return out;
  }
  if (typeof v === 'string') {
    let s = v;
    for (const { re } of regexes) s = s.replace(re, '<HOME>');
    return s;
  }
  return v;
}
// scrubText(s) — the single scrubbed-emit boundary for every human-facing
// stdout/stderr string that isn't already covered by the machine JSON emit
// paths (--profile-out/--delta-out/--json go through scrubDeep+assertScrubbed
// structurally, as before). Every --check/drift/error/diagnostic string must
// route through this before it reaches process.stdout/stderr.
function scrubText(s) {
  if (typeof s !== 'string') return s;
  return scrubDeep(s, buildScrubRegexes(homedir(), resolveUser()));
}

// findLeaks() walks the (already-scrubbed, but still-failing) object to name
// WHERE a leak lives — a JSON path plus a label — never the matched text. The
// object KEY itself can carry a leak (codex-4) — scrub it before it's
// interpolated into the reported path, since that path is exactly what the
// caller sees on the failure it's meant to protect against.
function findLeaks(v, regexes, path, out) {
  if (Array.isArray(v)) {
    v.forEach((x, i) => findLeaks(x, regexes, path ? `${path}[${i}]` : `[${i}]`, out));
    return;
  }
  if (v && typeof v === 'object') {
    for (const [k, val] of Object.entries(v)) {
      // Scrub with the SAME regexes the caller passed in — those define what
      // counts as a leak for this call; scrubText()'s own (real-machine)
      // regexes would be the wrong criteria for a caller checking against a
      // different home/user (e.g. a test fixture identity).
      const safeKey = scrubDeep(k, regexes);
      for (const { re, label } of regexes) {
        re.lastIndex = 0;
        if (re.test(k)) out.push(`${label} in a key at ${path ? `${path}.${safeKey}` : safeKey}`);
      }
      findLeaks(val, regexes, path ? `${path}.${safeKey}` : safeKey, out);
    }
    return;
  }
  if (typeof v === 'string') {
    for (const { re, label } of regexes) {
      re.lastIndex = 0;
      if (re.test(v)) out.push(`${label} at ${path || '(root)'}`);
    }
  }
}
function assertScrubbed(obj, regexes) {
  const s = JSON.stringify(obj);
  const leaked = regexes.filter(({ re }) => { re.lastIndex = 0; return re.test(s); });
  if (leaked.length === 0) return;
  const locations = [];
  findLeaks(obj, leaked, '', locations);
  const detail = locations.length > 0 ? [...new Set(locations)].join('; ') : leaked.map((l) => l.label).join(', ');
  throw new Error(`capture-operator-profile: SCRUB FAILED — unscrubbed ${detail} — refusing to emit (this is a bug, not a warning)`);
}

// ── .env helpers ─────────────────────────────────────────────────────────
// normalizeDotenvValue(raw) — the single accepted-grammar parser for a
// dotenv line's raw right-hand-side text (everything after the first '='),
// used by both parseDotenv (repo/primary .env) and captureBridge (the
// bridge .env's TELEGRAM_BOT_TOKEN line) so every dotenv value-grammar
// corner (quoted-empty, quoted-whitespace, inline '#' comment, a bare
// '#...' value, '= # unset') is handled exactly once instead of drifting
// per call site across CR rounds. Order: (a) trim; (b) a matching quote
// pair (single OR double) spanning to a closing quote takes the quoted
// CONTENT verbatim — no inline-comment stripping inside quotes, and
// anything after the closing quote (e.g. a trailing ' #...' comment) is
// discarded; (c) otherwise (unquoted), strip from the first whitespace+'#'
// to end of line, and a value that IS just '#...' is empty; (d) final
// trim. Returns '' for "unset".
function normalizeDotenvValue(raw) {
  const s = String(raw ?? '').trim(); // (a)
  const quote = s[0];
  if (quote === '"' || quote === "'") {
    const closeIdx = s.indexOf(quote, 1);
    if (closeIdx !== -1) return s.slice(1, closeIdx).trim(); // (b) + (d)
  }
  if (s.startsWith('#')) return ''; // (c) bare-comment value
  const commentIdx = s.search(/\s#/);
  const stripped = commentIdx === -1 ? s : s.slice(0, commentIdx);
  return stripped.trim(); // (c) + (d)
}
function primaryCheckoutRoot(repoRoot) {
  try {
    const out = execFileSync('git', ['-C', repoRoot, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    return out ? dirname(out) : repoRoot;
  } catch { return repoRoot; }
}
function parseDotenv(file) {
  const map = {};
  if (!existsSync(file)) return map;
  for (const line of readFileSync(file, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (m) map[m[1]] = normalizeDotenvValue(m[2]);
  }
  return map;
}

// ── plugins (delta only — profile carries pluginSet:"lean") ────────────
function capturePlugins(configDir, repoRoot) {
  const base = readJsonSafe(join(configDir, 'settings.json'))?.enabledPlugins;
  const local = readJsonSafe(join(configDir, 'settings.local.json'))?.enabledPlugins;
  const effective = {
    ...(base && typeof base === 'object' && !Array.isArray(base) ? base : {}),
    ...(local && typeof local === 'object' && !Array.isArray(local) ? local : {}),
  };
  const templateJson = readJsonSafe(join(repoRoot, 'docs', 'setup', 'settings-template.json'));
  // readJsonSafe returns null for missing/corrupt JSON — distinct from a
  // validly-parsed template that simply has no enabledPlugins. Only the
  // former is a read failure; don't silently render it as "nothing beyond
  // template" (a false-clean diff).
  const templateReadFailed = templateJson === null;
  const template = (templateJson && typeof templateJson.enabledPlugins === 'object' && templateJson.enabledPlugins !== null && !Array.isArray(templateJson.enabledPlugins))
    ? templateJson.enabledPlugins : {};
  const enabledBeyondTemplate = templateReadFailed ? null : Object.keys(effective).filter((k) => effective[k] === true && template[k] !== true).sort();
  const templateTrueButDisabled = templateReadFailed ? null : Object.keys(template).filter((k) => template[k] === true && effective[k] !== true).sort();
  return { delta: { enabledBeyondTemplate, templateTrueButDisabled, templateReadFailed } };
}

// ── cadences (scheduled tasks / cron) ───────────────────────────────────
const CADENCE_TASK_GROUPS = {
  pipeline: ['HIMMEL-Pipeline-FetchHealth', 'HIMMEL-Pipeline-Harvest', 'HIMMEL-Pipeline-Synthesize', 'HIMMEL-Pipeline-Health'],
  graphmap: { prefix: 'HIMMEL-GraphMap-' },
  qmd: { prefix: 'HIMMEL-Qmd-' },
  'drift-fix': ['HIMMEL-DriftFix'],
  'codex-sweep': ['HIMMEL-CodexOrphanSweep'],
  ggs: ['HIMMEL-Graphify-GgsUpdate'],
  'repo-sync': ['HIMMEL-RepoSync'],
};
// Known scheduled tasks that exist but are not covered by any of the 7
// cadence ids above — surfaced in delta only (HIMMEL-2302 territory: the
// wizard's binary luna-cadence question cannot select/report these).
const EXTRA_KNOWN_TASKS = ['HIMMEL-ForkResync', 'HIMMEL-BootPreflight', 'HimmelTelegramBridge'];

// isHimmelRelevantTask(name) — check if a task name belongs to CADENCE_TASK_GROUPS
// or EXTRA_KNOWN_TASKS. Used to scope statusUnrecognized to only himmel-relevant
// names, preventing unrelated third-party task names from polluting the delta.
function isHimmelRelevantTask(name) {
  // Check exact matches in any CADENCE_TASK_GROUPS fixed-name list
  for (const spec of Object.values(CADENCE_TASK_GROUPS)) {
    if (Array.isArray(spec) && spec.includes(name)) return true;
  }
  // Check prefix matches in any CADENCE_TASK_GROUPS prefix spec
  for (const spec of Object.values(CADENCE_TASK_GROUPS)) {
    if (spec && typeof spec === 'object' && spec.prefix && name.startsWith(spec.prefix)) return true;
  }
  // Check EXTRA_KNOWN_TASKS
  if (EXTRA_KNOWN_TASKS.includes(name)) return true;
  return false;
}

// ── cadence-registry schema boundary ────────────────────────────────────
// HIMMEL-2307 follow-up schema ruling (locked, console-approved): the v2
// profile's `cadences` section carries ONLY ids from
// scripts/himmelctl/lib/cadence-registry.json (pipeline|qmd|graphmap|
// codex-sweep today, but read from the file — never hardcoded — since
// himmelctl's loadProfile validates a committed profile against that same
// registry). Every other known/armed cadence (drift-fix, ggs, repo-sync, ...)
// belongs in delta.cadences.nonRegistryCadences instead — the delta object
// exists precisely for what the wizard cannot yet ask about.
function readCadenceRegistryIds(repoRoot) {
  const registry = readJsonSafe(join(repoRoot, 'scripts', 'himmelctl', 'lib', 'cadence-registry.json'));
  if (!registry || !Array.isArray(registry.cadences)) return null; // read/shape failure
  return new Set(registry.cadences.map((c) => c?.id).filter((id) => typeof id === 'string'));
}

// splitCadencesByRegistry(cadences, registryIds) -> { registryCadences, nonRegistryCadences }
// Pure (no I/O) so it's unit-testable. registryIds === null means the
// registry itself couldn't be read/parsed — both outputs collapse to null
// rather than guessing a split (same never-fabricate convention as
// templateReadFailed/registryReadFailed elsewhere in this file).
function splitCadencesByRegistry(cadences, registryIds) {
  if (!registryIds) return { registryCadences: null, nonRegistryCadences: null };
  const registryCadences = {};
  const nonRegistryCadences = {};
  for (const [id, state] of Object.entries(cadences)) {
    if (registryIds.has(id)) registryCadences[id] = state;
    else nonRegistryCadences[id] = state;
  }
  return { registryCadences, nonRegistryCadences };
}

// HIMMEL_CAPTURE_SCHTASKS_CMD may be a bare binary ("schtasks") or a
// space-separated command ("node C:/path/to/stub.mjs") — the latter is what
// the test suite uses, since a bare .cmd/.bat stub cannot be exec'd directly
// on Windows without shell:true (verified: EINVAL), while a "node <script>"
// prefix runs everywhere execFileSync already trusts a bare PATH lookup
// (same idiom as this repo's own execFileSync('bun', ...) / ('git', ...)).
function schtasksCommand() {
  const override = process.env.HIMMEL_CAPTURE_SCHTASKS_CMD;
  if (!override) return ['schtasks'];
  return override.split(/\s+/).filter(Boolean);
}

// listScheduledTaskNames() -> { ok:true, names:Set<string>, statusUnrecognized:string[] } | { ok:false, reason }
// MSYS_NO_PATHCONV=1 mirrors scripts/luna/pipeline-cadence.sh's run_schtasks —
// without it Git-Bash mangles /query into a Windows-rooted path.
//
// CSV columns (no /s): "TaskName","Next Run Time","Status". A present task
// whose Status is Disabled must NOT count as armed (codex-1) — previously
// only the name column was parsed, so a disabled task read as armed. Only
// the known English "Ready"/"Running" strings are trusted as armed; a
// non-English/unexpected Status string (localized Windows) fails toward
// still counting the task as armed, but is named in statusUnrecognized so
// the delta can flag it rather than silently trusting an unknown string.
//
// Uncertainty convention (HIMMEL-2307, adjudicated): a TOTAL probe failure
// (no data — devOverlay probe degraded, scheduler query failed) fails strict
// capture loudly (exit 2), never fabricates a boolean. A single-attribute
// AMBIGUITY on otherwise-good data (unrecognized/localized task status,
// unknown systemd unit state) resolves conservative-toward-armed WITH a
// visible delta flag (statusUnrecognized / bridgeUnitStateUnknown): for a
// migration-loss-prevention artifact, overstating an obligation is
// recoverable, silently dropping one is not.
const KNOWN_ARMED_STATUSES = new Set(['Ready', 'Running']);
function listScheduledTaskNames() {
  try {
    const [bin, ...prefixArgs] = schtasksCommand();
    const out = execFileSync(bin, [...prefixArgs, '/query', '/fo', 'CSV', '/nh'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, MSYS_NO_PATHCONV: '1' },
    });
    const names = new Set();
    const statusUnrecognized = [];
    for (const m of out.matchAll(/^"\\?([^"]+)","[^"]*","([^"]*)"/gm)) {
      const name = m[1];
      const status = m[2];
      if (status === 'Disabled') continue; // known-off — never counted as armed
      names.add(name);
      if (!KNOWN_ARMED_STATUSES.has(status) && isHimmelRelevantTask(name)) statusUnrecognized.push(name);
    }
    return { ok: true, names, statusUnrecognized: statusUnrecognized.sort() };
  } catch (e) {
    // Real schtasks: rc=1 with EMPTY stderr is the trusted "empty scheduler"
    // signature (mirrors pipeline-cadence.sh's list_existing). Anything else
    // is a genuine query failure — report it, don't guess "no tasks".
    if (e && e.status === 1 && !(e.stderr && String(e.stderr).trim())) return { ok: true, names: new Set(), statusUnrecognized: [] };
    return { ok: false, reason: `schtasks query failed (rc=${e?.status ?? 'spawn error'})` };
  }
}

// classifyCrontabError(e) -> { ok:true, text:'' } | { ok:false, reason }
// Distinguishes a genuinely empty POSIX scheduler (rc=1 with empty stderr,
// or the well-known "no crontab for <user>" message — the same trusted
// signature scripts/luna/pipeline-cadence.sh's cron_read() already uses)
// from every other failure (binary missing, spawn error, unexpected
// rc/stderr), which must be reported as queryFailed rather than silently
// rendered as "off" — the same honesty contract listScheduledTaskNames()
// already applies to schtasks. Exported (pure, no spawn) so the test suite
// can exercise it without spawning a real crontab binary — a bare-name PATH
// stub can't be exec'd on Windows without shell:true (verified ENOENT; see
// HIMMEL_CAPTURE_SCHTASKS_CMD's own comment above for the same gotcha).
function classifyCrontabError(e) {
  const stderr = e && e.stderr ? String(e.stderr).trim() : '';
  if (e && e.status === 1 && (!stderr || /no crontab/i.test(stderr))) return { ok: true, text: '' };
  const reason = e && e.code === 'ENOENT' ? 'crontab binary not found' : `crontab -l failed (rc=${e?.status ?? 'spawn error'})`;
  return { ok: false, reason };
}
function crontabResult() {
  try {
    const text = execFileSync('crontab', ['-l'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    return { ok: true, text };
  } catch (e) {
    return classifyCrontabError(e);
  }
}

// computeCadences() -> { cadences, taskDetail, extraArmedTasks, queryFailed, scheduledTaskNames }
// cadences is null (not an empty map) when the query itself failed, so the
// caller can omit the whole optional `cadences` profile field rather than
// fabricate an "off" map from a query that never ran.
function computeCadences() {
  const useSchtasks = process.platform === 'win32' || Boolean(process.env.HIMMEL_CAPTURE_SCHTASKS_CMD);
  if (useSchtasks) {
    const snap = listScheduledTaskNames();
    if (!snap.ok) return { cadences: null, taskDetail: {}, extraArmedTasks: [], queryFailed: snap.reason, scheduledTaskNames: null, statusUnrecognized: [] };
    const names = snap.names;
    const cadences = {};
    const taskDetail = {};
    for (const [id, spec] of Object.entries(CADENCE_TASK_GROUPS)) {
      const found = Array.isArray(spec)
        ? spec.filter((n) => names.has(n)).sort()
        : [...names].filter((n) => n.startsWith(spec.prefix)).sort();
      cadences[id] = found.length > 0 ? 'armed' : 'off';
      taskDetail[id] = found;
    }
    const extraArmedTasks = EXTRA_KNOWN_TASKS.filter((n) => names.has(n)).sort();
    return { cadences, taskDetail, extraArmedTasks, queryFailed: null, scheduledTaskNames: names, statusUnrecognized: snap.statusUnrecognized };
  }
  // POSIX best-effort: crontab has no discrete task "names". Fixed-name
  // groups match by substring; prefix-based groups (graphmap/qmd) match any
  // crontab line carrying the prefix, extracting just the prefixed token
  // (up to the next whitespace) — never a full cron line — into taskDetail.
  const crontab = crontabResult();
  if (!crontab.ok) return { cadences: null, taskDetail: {}, extraArmedTasks: [], queryFailed: crontab.reason, scheduledTaskNames: null, statusUnrecognized: [] };
  const { cadences, taskDetail } = matchCadenceGroups(crontab.text);
  const activeLines = filterCommentedLines(crontab.text);
  const extraArmedTasks = EXTRA_KNOWN_TASKS.filter((n) => activeLines.some((line) => line.includes(n))).sort();
  return { cadences, taskDetail, extraArmedTasks, queryFailed: null, scheduledTaskNames: null, statusUnrecognized: [] };
}

// filterCommentedLines(text) -> string[] — splits text into lines and filters
// out commented-out lines (first non-whitespace char is '#'). Used to skip
// whole-text substring matches that would otherwise count a commented-out
// cron/crontab line as armed. Extracted as a reusable helper for both
// matchCadenceGroups and extraArmedTasks computation.
function filterCommentedLines(text) {
  return text.split(/\r?\n/).filter((line) => !/^\s*#/.test(line));
}

// matchCadenceGroups(text) -> { cadences, taskDetail } — the POSIX crontab
// matcher: fixed-name groups match by substring; prefix-based groups
// (graphmap/qmd) match any line carrying the prefix, extracting just the
// prefixed token (up to the next whitespace) into taskDetail — never a full
// cron line. Pulled out (pure, no spawn) so the test suite can unit-test it
// on synthetic crontab text without spawning a real crontab binary (same
// rationale as classifyCrontabError above).
function matchCadenceGroups(text) {
  // Per-line, skipping commented-out lines (first non-whitespace char '#') —
  // a whole-text substring/regex match previously counted a commented-out
  // cron line as armed (codex-2).
  const activeLines = filterCommentedLines(text);
  const activeText = activeLines.join('\n');
  const cadences = {};
  const taskDetail = {};
  for (const [id, spec] of Object.entries(CADENCE_TASK_GROUPS)) {
    let found;
    if (Array.isArray(spec)) {
      found = spec.filter((n) => activeLines.some((line) => line.includes(n))).sort();
    } else {
      const re = new RegExp(`${escapeRe(spec.prefix)}\\S*`, 'g');
      found = [...new Set([...activeText.matchAll(re)].map((m) => m[0]))].sort();
    }
    cadences[id] = found.length > 0 ? 'armed' : 'off';
    taskDetail[id] = found;
  }
  return { cadences, taskDetail };
}

// ── devOverlay: reuse scripts/guardrails/lib.sh's is_himmel_dev_repo() ──
// (worktree-aware — resolves to the PRIMARY checkout's .himmel-dev marker),
// the same probe scripts/himmelctl/lib/probes.js's cmd:is_himmel_dev uses.
function resolveBash() {
  if (process.platform !== 'win32') return '/bin/bash';
  const cands = [process.env.GUARDRAIL_BASH, 'C:/Program Files/Git/bin/bash.exe', 'C:/Program Files/Git/usr/bin/bash.exe'].filter(Boolean);
  return cands.find((b) => existsSync(b)) || 'bash';
}
function detectDevOverlay(repoRoot) {
  try {
    const bash = resolveBash();
    execFileSync(bash, ['-c', '. "$HIMMEL_PROBE_RESOLVER" || exit 3; is_himmel_dev_repo'], {
      cwd: repoRoot,
      env: { ...process.env, HIMMEL_PROBE_RESOLVER: resolve(repoRoot, 'scripts', 'guardrails', 'lib.sh') },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    return true; // rc 0 — marker present
  } catch (e) {
    if (e && e.status === 1) return false; // clean "not a dev checkout"
    return null; // degraded/unknown (wiring problem) — never fabricate a yes/no
  }
}

// ── lanes ────────────────────────────────────────────────────────────────
function captureLanes(repoRoot) {
  let liveIds = null;
  try {
    const out = execFileSync(process.execPath, [join(repoRoot, 'scripts', 'lanes', 'resolve.mjs'), '--json'], {
      encoding: 'utf8', cwd: repoRoot, stdio: ['ignore', 'pipe', 'pipe'],
    });
    liveIds = JSON.parse(out).map((l) => l?.id).filter((id) => typeof id === 'string').sort();
  } catch { liveIds = null; }

  // Wizard-askable registry ids, AND a registryId->short-id map — read-only
  // require of adopter-profile.js (V1_LANES), the same table the himmelctl
  // v1 lane question offers (rows carry both `id` short and `registryId`).
  // HIMMEL-2308 schema ruling (2026-08-31, locked): install-profile `lanes`
  // carries SHORT canonical ids, not registry ids; delta.liveLaneIds/
  // wizardAskableIds stay REGISTRY ids (delta is diagnostics, not schema).
  // HIMMEL-2352 (ruling 34): V1_LANES — and therefore askableIds/
  // registryToShort below — is codex/hermes ONLY as of this ticket; ollama
  // and copilot are no longer wizard-askable, so a live ollama-local/
  // copilot-cli lane now falls into delta.unmappedLiveLanes rather than
  // profile.lanes, same as any other registry lane this wizard never offers.
  let askableIds = [];
  let registryToShort = new Map();
  let askableReadFailed = false;
  try {
    const adopterProfile = require(join(repoRoot, 'scripts', 'himmelctl', 'lib', 'adopter-profile.js'));
    askableIds = [...new Set(adopterProfile.V1_LANES.map((l) => l.registryId))].sort();
    registryToShort = new Map(adopterProfile.V1_LANES.map((l) => [l.registryId, l.id]));
  } catch { askableIds = []; askableReadFailed = true; }

  const registryPath = process.env.LANES_REGISTRY || join(repoRoot, 'scripts', 'lanes', 'lanes.json');
  const registry = readJsonSafe(registryPath);
  // readJsonSafe returns null for missing/corrupt JSON — a genuine read
  // failure, distinct from a validly-parsed registry with no lanes.
  const registryReadFailed = registry === null;
  const registryLanes = Array.isArray(registry?.lanes) ? registry.lanes : [];
  const dormantLanes = registryReadFailed ? null : registryLanes.filter((l) => l && l.dormant)
    .map((l) => ({ id: l.id, optInEnv: l.dormant.optInEnv || null }))
    .sort((a, b) => a.id.localeCompare(b.id));
  const readinessGates = registryReadFailed ? null : registryLanes.filter((l) => l && l.readiness)
    .map((l) => ({ id: l.id, passesRequired: l.readiness.passesRequired ?? null }))
    .sort((a, b) => a.id.localeCompare(b.id));

  // A live lane with no short mapping must NOT silently vanish nor leak into
  // profile.lanes — it goes to delta.lanes.unmappedLiveLanes; rc stays 0
  // (has-it-or-not, absence representable — no exit 2).
  const unmappedLiveLanes = liveIds ? liveIds.filter((id) => !registryToShort.has(id)).sort() : [];
  const profileLanes = liveIds
    ? [...new Set(liveIds.filter((id) => registryToShort.has(id)).map((id) => registryToShort.get(id)))].sort()
    : [];
  return {
    profileLanes,
    meaningful: liveIds !== null,
    askableReadFailed,
    delta: {
      liveLaneIds: liveIds || [],
      wizardAskableIds: askableIds,
      unmappedLiveLanes,
      dormantLanes,
      readinessGates,
      probeFailed: liveIds === null,
      registryReadFailed,
      askableReadFailed,
    },
  };
}

// ── handover ─────────────────────────────────────────────────────────────
function captureHandover(primaryEnv, configDir) {
  const dirVal = (process.env.HANDOVER_DIR && process.env.HANDOVER_DIR.trim())
    || (primaryEnv.HANDOVER_DIR && primaryEnv.HANDOVER_DIR.trim()) || '';
  const mode = dirVal ? 'external' : 'inline';
  const registryPath = join(configDir, 'handover', 'registry.json');
  const registry = readJsonSafe(registryPath);
  // readJsonSafe returns null for missing/corrupt JSON — a genuine read
  // failure, distinct from a validly-parsed registry with zero repos (same
  // pattern as capturePlugins' templateReadFailed).
  const registryReadFailed = registry === null;
  const repoNames = registryReadFailed ? null : (registry.repos && typeof registry.repos === 'object' && !Array.isArray(registry.repos)
    ? Object.keys(registry.repos).sort() : []);
  return {
    profile: mode === 'external' ? { mode, path: '<HANDOVER_DIR>' } : { mode: 'inline' },
    delta: {
      registryPresent: existsSync(registryPath),
      registryEntryNames: repoNames,
      registryEntryCount: registryReadFailed ? null : repoNames.length,
      registryReadFailed,
    },
  };
}

// ── vault ────────────────────────────────────────────────────────────────
function captureVault(primaryEnv) {
  const val = (process.env.LUNA_VAULT_PATH && process.env.LUNA_VAULT_PATH.trim())
    || (primaryEnv.LUNA_VAULT_PATH && primaryEnv.LUNA_VAULT_PATH.trim()) || '';
  return val ? { mode: 'existing', path: '<LUNA_VAULT_PATH>' } : { mode: 'none' };
}

// ── env-key NAMES vs. the generated secrets-manifest block + SESSION-ONLY section ──
function sliceBetween(text, startMarker, endMarker) {
  const s = text.indexOf(startMarker);
  if (s === -1) return '';
  const e = text.indexOf(endMarker, s);
  return e === -1 ? text.slice(s) : text.slice(s, e);
}
function extractManifestNames(section) {
  const names = new Set();
  for (const m of section.matchAll(/^# ([A-Z][A-Z0-9_]*) \((?:required|optional)\)/gm)) names.add(m[1]);
  return names;
}
function extractSessionOnlyNames(section) {
  const names = new Set();
  // Real entries are tabular: NAME[=value] then 2+ spaces before a
  // description ("EDIT_ON_MAIN_OK=1            allow Edit/Write ...",
  // "AUTO_ARM_THRESHOLD           utilization % ..."). Requiring the
  // trailing 2+ spaces excludes prose CONTINUATION lines that merely start
  // (after wrapping indent) with an uppercase word followed by a single
  // space, e.g. "...already\n#                                PENDING elsewhere\"".
  for (const m of section.matchAll(/^#\s{2,}([A-Z][A-Z0-9_]{2,})(?:=\S*)?\s{2,}\S/gm)) names.add(m[1]);
  return names;
}
function captureEnvKeys(repoRoot, primaryEnvKeys) {
  const exampleText = readFileSync(join(repoRoot, '.env.example'), 'utf8');
  const generatedSection = sliceBetween(exampleText, '=== GENERATED: secrets manifest', '=== GENERATED: secrets manifest -- END ===');
  const sessionSection = sliceBetween(exampleText, '=== SECTION: SESSION-ONLY ===', '=== SECTION: EXTERNAL-TOOLS ===');
  const generatedNames = extractManifestNames(generatedSection);
  const sessionOnlyNames = extractSessionOnlyNames(sessionSection);
  const known = new Set([...generatedNames, ...sessionOnlyNames]);
  const keysBeyondGeneratedBlock = [...primaryEnvKeys].filter((k) => !known.has(k)).sort();
  // Guardrail env posture: presence only, never values — and shell-dependent
  // (whatever launched THIS process), noted in the delta doc.
  const guardrailEnvPosture = {};
  for (const name of [...sessionOnlyNames].sort()) {
    guardrailEnvPosture[name] = Boolean(process.env[name] && process.env[name].trim() !== '');
  }
  return { delta: { keysBeyondGeneratedBlock, guardrailEnvPosture } };
}

// ── HUD ──────────────────────────────────────────────────────────────────
function captureHud(configDir) {
  const hudPath = join(configDir, 'claude-hud.json');
  const present = existsSync(hudPath);
  const cfg = present ? readJsonSafe(hudPath) : null;
  // readJsonSafe returns null for missing/corrupt JSON — file-absent stays
  // represented as empty; present-but-unparseable is a genuine read failure
  // (same convention as templateReadFailed/registryReadFailed/observabilityReadFailed).
  const hudReadFailed = present && cfg === null;
  const settings = readJsonSafe(join(configDir, 'settings.json'));
  const statusLineReferencesHud = typeof settings?.statusLine?.command === 'string'
    && settings.statusLine.command.includes('claude-hud');
  return {
    delta: {
      hudConfigPresent: present,
      hudReadFailed,
      hudConfigTopLevelKeys: hudReadFailed ? null : (cfg && typeof cfg === 'object' && !Array.isArray(cfg) ? Object.keys(cfg).sort() : []),
      statusLineReferencesHud,
    },
  };
}

// ── observability ────────────────────────────────────────────────────────
function captureObservability() {
  const path = process.env.HIMMEL_OBSERVABILITY_CONFIG || join(homedir(), '.himmel', 'observability.json');
  const present = existsSync(path);
  const cfg = present ? readJsonSafe(path) : null;
  // readJsonSafe returns null for missing/corrupt JSON — file-absent (not
  // installed) is legitimate and stays represented as empty; present-but-
  // unparseable is a genuine read failure and must not silently read the
  // same as empty (same convention as templateReadFailed/registryReadFailed).
  const observabilityReadFailed = present && cfg === null;
  // Names only — never the whole flow object (it can carry fields like a
  // scriptPath that have no business leaving this machine).
  const flowNames = observabilityReadFailed ? null : (Array.isArray(cfg?.flows)
    ? [...new Set(cfg.flows.map((f) => f?.name).filter((n) => typeof n === 'string'))].sort()
    : []);
  // Names-only contract: a non-string entry (e.g. an accidental object) must
  // never leak its nested fields into output — drop it and count it instead.
  const stringEntries = (arr) => {
    if (!Array.isArray(arr)) return { values: [], dropped: 0 };
    const values = arr.filter((v) => typeof v === 'string').sort();
    return { values, dropped: arr.length - values.length };
  };
  const expectedTasks = observabilityReadFailed ? { values: null, dropped: 0 } : stringEntries(cfg?.expected_tasks);
  const expectedDisabledTasks = observabilityReadFailed ? { values: null, dropped: 0 } : stringEntries(cfg?.expected_disabled_tasks);
  return {
    delta: {
      configPresent: present,
      observabilityReadFailed,
      flowNames,
      expectedTasks: expectedTasks.values,
      expectedDisabledTasks: expectedDisabledTasks.values,
      nonStringEntriesDropped: observabilityReadFailed ? null : (expectedTasks.dropped + expectedDisabledTasks.dropped),
      processLivenessNote: 'process liveness is OUT of scope for a static capture (unmeasurable without a live probe)',
    },
  };
}

// ── bridge (Telegram) ────────────────────────────────────────────────────
// checkSystemdUnitEnabled() -> 'enabled' | 'disabled' | 'unknown' — read-only
// probe (never installs/uninstalls). Mirrors scripts/himmelctl/lib/
// bridge-persistence.js's systemdUnitInstalled() is-enabled semantics (exit
// 0=enabled, exit 1=disabled, anything else=unknown), reimplemented here
// (not imported) to keep this script's dependency surface flat. systemctl
// missing on PATH throws ENOENT, which also collapses to 'unknown'.
function checkSystemdUnitEnabled() {
  try {
    execFileSync('systemctl', ['--user', 'is-enabled', 'telegram-bridge.service'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
    });
    return 'enabled';
  } catch (e) {
    if (e && e.status === 1) return 'disabled';
    return 'unknown'; // systemctl absent, or an unexpected exit code
  }
}

// decideBridgePersistence(fileExists, unitState) — pure decision function
// (no spawn) for the POSIX branch, so it can be unit-tested on synthetic
// inputs (same pattern as classifyCrontabError). unit-file existence alone
// used to mark installPersistence true even when the unit was disabled
// (codex-1) — now installPersistence requires BOTH fileExists AND enabled;
// fileExists-but-disabled is surfaced via bridgeUnitDisabled instead of
// silently reading as persisted. When systemctl can't answer definitively
// (absent or an unrecognized exit code), this fails toward the OLD
// file-exists-only behavior (never a false negative) but flags
// bridgeUnitStateUnknown so the delta can say so.
// (See uncertainty convention comment near statusUnrecognized.)
function decideBridgePersistence(fileExists, unitState) {
  if (unitState === 'unknown') {
    return { installPersistence: fileExists, bridgeUnitDisabled: false, bridgeUnitStateUnknown: true };
  }
  const enabled = unitState === 'enabled';
  return { installPersistence: fileExists && enabled, bridgeUnitDisabled: fileExists && !enabled, bridgeUnitStateUnknown: false };
}

function captureBridge(configDir, scheduledTaskNames, usesCustomConfigDir) {
  const envFile = join(configDir, 'channels', 'telegram', '.env');
  let enabled = false;
  if (existsSync(envFile)) {
    const content = readFileSync(envFile, 'utf8');
    // Key presence via regex on the line — the captured value is used only
    // to test non-emptiness through normalizeDotenvValue's shared dotenv
    // grammar; it is NEVER stored, logged, or included in output. Capture
    // the WHOLE rest of the line after '=' (not just the first \S+
    // fragment) so a quoted-whitespace or inline-comment value normalizes
    // correctly instead of being truncated before normalization runs.
    const m = content.match(/^TELEGRAM_BOT_TOKEN\s*=(.*)$/m);
    enabled = m ? normalizeDotenvValue(m[1]).length > 0 : false;
  }
  const whisperDir = process.env.WHISPER_DIR || join(homedir(), '.himmel', 'whisper');
  const modelFile = process.env.WHISPER_MODEL || join(whisperDir, 'ggml-small.bin');
  const modelPresent = existsSync(modelFile);
  const cliFile = join(whisperDir, process.platform === 'win32' ? 'whisper-cli.exe' : 'whisper-cli');
  const cliPresent = existsSync(cliFile);
  let installPersistence;
  let bridgeUnitDisabled = false;
  let bridgeUnitStateUnknown = false;
  if (process.platform === 'win32') {
    installPersistence = Boolean(scheduledTaskNames && scheduledTaskNames.has('HimmelTelegramBridge'));
  } else {
    const unitFileExists = existsSync(join(homedir(), '.config', 'systemd', 'user', 'telegram-bridge.service'));
    ({ installPersistence, bridgeUnitDisabled, bridgeUnitStateUnknown } = decideBridgePersistence(unitFileExists, checkSystemdUnitEnabled()));
  }
  // The state above is read under CLAUDE_CONFIG_DIR (configDir) — when that
  // differs from the default ~/.claude, the emitted path must say so (codex-4),
  // still as a non-personal placeholder token, never the real resolved path.
  const envPath = usesCustomConfigDir ? '<CLAUDE_CONFIG_DIR>/channels/telegram/.env' : '~/.claude/channels/telegram/.env';
  return {
    profile: {
      enabled,
      envPath,
      whisperCli: cliPresent ? '<WHISPER_CLI>' : '',
      whisperModel: modelPresent ? basename(modelFile) : '',
      installPersistence,
    },
    delta: { whisperModelFound: modelPresent, whisperCliFound: cliPresent, bridgeUnitDisabled, bridgeUnitStateUnknown },
  };
}

// ── main capture ─────────────────────────────────────────────────────────
// strict (default true) governs devOverlay/alwaysOn: when their underlying
// probe is degraded/unknown, strict mode throws (the caller's mode is one
// that EMITS the profile — --profile-out, --check's fresh capture, --json —
// and a fabricated false there would be a lie a committed/consumed file
// carries forward). Non-strict callers (the human summary, --delta-out,
// which never touch these two profile fields) keep the old collapse-to-false
// display behavior.
function capture(strict = true) {
  const home = homedir();
  const user = resolveUser();
  const configDir = process.env.CLAUDE_CONFIG_DIR || join(home, '.claude');
  const usesCustomConfigDir = Boolean(process.env.CLAUDE_CONFIG_DIR) && resolve(process.env.CLAUDE_CONFIG_DIR) !== resolve(join(home, '.claude'));

  const cadenceInfo = computeCadences();
  const cadenceRegistryIds = readCadenceRegistryIds(REPO_ROOT);
  const { registryCadences, nonRegistryCadences } = cadenceInfo.cadences
    ? splitCadencesByRegistry(cadenceInfo.cadences, cadenceRegistryIds)
    : { registryCadences: null, nonRegistryCadences: null };
  const devOverlay = detectDevOverlay(REPO_ROOT);
  if (strict && devOverlay === null) {
    throw new Error('capture-operator-profile: cannot capture devOverlay: probe degraded (is_himmel_dev_repo wiring failed) — refusing to fabricate a boolean');
  }

  const primaryRoot = primaryCheckoutRoot(REPO_ROOT);
  const primaryEnv = parseDotenv(join(primaryRoot, '.env'));
  const primaryEnvKeys = new Set(Object.keys(primaryEnv));

  const plugins = capturePlugins(configDir, REPO_ROOT);
  const lanes = captureLanes(REPO_ROOT);
  if (strict && lanes.askableReadFailed) {
    throw new Error('capture-operator-profile: cannot capture lanes: askableIds read failed (scripts/himmelctl/lib/adopter-profile.js) — refusing to fabricate an empty lanes list');
  }
  if (strict && cadenceRegistryIds === null) {
    throw new Error('capture-operator-profile: cannot capture cadences: cadence-registry.json read failed (scripts/himmelctl/lib/cadence-registry.json) — refusing to fabricate the registry-scoped profile.cadences filter');
  }
  const handover = captureHandover(primaryEnv, configDir);
  const vault = captureVault(primaryEnv);
  const envKeys = captureEnvKeys(REPO_ROOT, primaryEnvKeys);
  const hud = captureHud(configDir);
  const observability = captureObservability();
  const bridge = captureBridge(configDir, cadenceInfo.scheduledTaskNames, usesCustomConfigDir);

  // A failed scheduler query must not read as alwaysOn:false — unless bridge
  // persistence alone already proves it true (that proof stands on its own).
  const alwaysOnUnknown = Boolean(cadenceInfo.queryFailed) && !bridge.profile.installPersistence;
  if (strict && alwaysOnUnknown) {
    throw new Error(`capture-operator-profile: cannot capture alwaysOn: scheduler query failed (${cadenceInfo.queryFailed}) and bridge persistence not detected — refusing to fabricate a boolean`);
  }
  const alwaysOn = alwaysOnUnknown ? false : Boolean(
    (cadenceInfo.cadences && Object.values(cadenceInfo.cadences).some((v) => v === 'armed'))
    || cadenceInfo.extraArmedTasks.length > 0
    || bridge.profile.installPersistence,
  );

  const profile = {
    schemaVersion: 2,
    profile: 'operator',
    devOverlay: devOverlay === true,
    scope: 'user',
    vault,
    handover: handover.profile,
    pluginSet: 'lean',
    lanes: lanes.profileLanes,
    lanesMeaningful: lanes.meaningful,
    alwaysOn,
    bridge: bridge.profile,
    ...(registryCadences ? { cadences: registryCadences } : {}),
  };

  const delta = {
    plugins: plugins.delta,
    cadences: {
      taskDetail: cadenceInfo.taskDetail,
      extraArmedTasks: cadenceInfo.extraArmedTasks,
      queryFailed: cadenceInfo.queryFailed,
      statusUnrecognized: cadenceInfo.statusUnrecognized,
      nonRegistryCadences,
      registryReadFailed: cadenceRegistryIds === null,
    },
    lanes: lanes.delta,
    handover: handover.delta,
    envKeys: envKeys.delta,
    hud: hud.delta,
    observability: observability.delta,
    bridge: bridge.delta,
    devOverlayDetection: devOverlay === null ? 'degraded — could not determine via is_himmel_dev_repo probe wiring' : 'ok',
    alwaysOnInferred: true, // heuristic (any cadence/bridge-persistence armed), never asked
  };

  const regexes = buildScrubRegexes(home, user);
  const scrubbedProfile = sortKeysDeep(scrubDeep(profile, regexes));
  const scrubbedDelta = sortKeysDeep(scrubDeep(delta, regexes));
  assertScrubbed(scrubbedProfile, regexes);
  assertScrubbed(scrubbedDelta, regexes);
  return { profile: scrubbedProfile, delta: scrubbedDelta };
}

// ── diff (for --check) ──────────────────────────────────────────────────
function diffPaths(a, b, path, out) {
  const p = path || '(root)';
  const aIsObj = a !== null && typeof a === 'object';
  const bIsObj = b !== null && typeof b === 'object';
  if (aIsObj && bIsObj) {
    const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
    for (const k of [...keys].sort()) diffPaths(a[k], b[k], path ? `${path}.${k}` : k, out);
    return;
  }
  if (JSON.stringify(a) !== JSON.stringify(b)) out.push(`${p}: ${JSON.stringify(a)} -> ${JSON.stringify(b)}`);
}

// displayPath(p) — the caller-supplied --check path must never be echoed
// unscrubbed (codex-6): repo-relative when it's under REPO_ROOT (the common
// case — e.g. docs/setup/profiles/operator.install-profile.json), otherwise
// scrubbed through the same home/user regexes as the rest of the output.
function displayPath(p) {
  const abs = resolve(p);
  const rel = relative(REPO_ROOT, abs);
  if (rel && !rel.startsWith('..') && !isAbsolute(rel)) return rel.replaceAll('\\', '/');
  return scrubText(abs);
}

// ── CLI ──────────────────────────────────────────────────────────────────
function usage() {
  return [
    'usage: capture-operator-profile.mjs [--json | --profile-out <path> | --delta-out <path> | --check <committed-profile-path>]',
    '  (no args)              human-readable summary',
    '  --json                 print {profile, delta} to stdout',
    '  --profile-out <path>   write ONLY the scrubbed v2 profile object',
    '  --delta-out <path>     write ONLY the delta object',
    '  --check <path>         fresh capture vs. a committed profile; diff on drift',
    '',
    'exit codes: 0 ok / no drift, 1 --check found drift, 2 usage/runtime error',
  ].join('\n');
}

function renderSummary(profile, delta) {
  const lines = [];
  // capture(false) (non-strict) never throws on a degraded probe, but it
  // still collapses profile.devOverlay/alwaysOn to a fabricated `false` —
  // the delta signals (unaffected by strict) are the only honest source for
  // the human summary, which must show "unknown" rather than repeat that lie.
  const devOverlayUnknown = delta.devOverlayDetection !== 'ok';
  const alwaysOnUnknown = Boolean(delta.cadences.queryFailed) && !profile.bridge.installPersistence;
  const devOverlayDisplay = devOverlayUnknown ? 'unknown (probe degraded)' : profile.devOverlay;
  const alwaysOnDisplay = alwaysOnUnknown ? 'unknown (probe degraded)' : profile.alwaysOn;
  lines.push(`operator profile capture (schemaVersion ${profile.schemaVersion})`);
  lines.push(`  profile=${profile.profile} devOverlay=${devOverlayDisplay} scope=${profile.scope} alwaysOn=${alwaysOnDisplay}`);
  lines.push(`  vault=${profile.vault.mode} handover=${profile.handover.mode} pluginSet=${profile.pluginSet}`);
  lines.push(`  lanes (${profile.lanes.length}): ${profile.lanes.join(', ') || '(none)'}`);
  if (profile.cadences) {
    const armed = Object.entries(profile.cadences).filter(([, v]) => v === 'armed').map(([k]) => k);
    lines.push(`  cadences armed (${armed.length}/${Object.keys(profile.cadences).length}): ${armed.join(', ') || '(none)'}`);
  } else {
    lines.push(`  cadences: could not query (${delta.cadences.queryFailed})`);
  }
  lines.push(`  bridge enabled=${profile.bridge.enabled} installPersistence=${profile.bridge.installPersistence}`);
  lines.push('');
  lines.push('delta highlights (wizard cannot ask these yet):');
  lines.push(`  plugins enabled-beyond-template: ${delta.plugins.templateReadFailed ? 'unknown (template read failed)' : delta.plugins.enabledBeyondTemplate.length}`);
  lines.push(`  env keys beyond generated block: ${delta.envKeys.keysBeyondGeneratedBlock.length}`);
  lines.push(`  dormant lanes: ${delta.lanes.registryReadFailed ? 'unknown (registry read failed)' : delta.lanes.dormantLanes.length}`);
  lines.push(`  handover registry entries: ${delta.handover.registryEntryCount}`);
  lines.push(`  extra armed scheduled tasks (outside the 7 cadence ids): ${delta.cadences.extraArmedTasks.join(', ') || '(none)'}`);
  return lines.join('\n');
}

function main(argv) {
  const mode = argv[0];
  if (mode === undefined) {
    const { profile, delta } = capture(false);
    process.stdout.write(renderSummary(profile, delta) + '\n');
    return 0;
  }
  if (mode === '--json') {
    if (argv.length !== 1) { process.stderr.write(usage() + '\n'); return 2; }
    const { profile, delta } = capture();
    process.stdout.write(JSON.stringify({ profile, delta }, null, 2) + '\n');
    return 0;
  }
  if (mode === '--profile-out') {
    const out = argv[1];
    if (!out || argv.length !== 2) { process.stderr.write(usage() + '\n'); return 2; }
    const { profile } = capture();
    writeFileSync(out, JSON.stringify(profile, null, 2) + '\n');
    return 0;
  }
  if (mode === '--delta-out') {
    const out = argv[1];
    if (!out || argv.length !== 2) { process.stderr.write(usage() + '\n'); return 2; }
    const { delta } = capture(false); // delta never carries profile.devOverlay/alwaysOn — no need to be strict
    writeFileSync(out, JSON.stringify(delta, null, 2) + '\n');
    return 0;
  }
  if (mode === '--check') {
    const committedPath = argv[1];
    if (!committedPath || argv.length !== 2) { process.stderr.write(usage() + '\n'); return 2; }
    let committed;
    try { committed = JSON.parse(readFileSync(committedPath, 'utf8')); }
    catch (e) { process.stderr.write(`capture-operator-profile: cannot read/parse ${displayPath(committedPath)}: ${scrubText(e.message)}\n`); return 2; }
    const { profile } = capture();
    const diffs = [];
    diffPaths(sortKeysDeep(committed), profile, '', diffs);
    if (diffs.length === 0) return 0;
    process.stdout.write(`capture-operator-profile: DRIFT — ${displayPath(committedPath)} is stale (${diffs.length} field(s) changed):\n`);
    for (const line of diffs) process.stdout.write(`  ${scrubText(line)}\n`);
    process.stdout.write(`fix: node ${fileURLToPath(import.meta.url)} --profile-out ${displayPath(committedPath)}, then commit\n`);
    return 1;
  }
  process.stderr.write(usage() + '\n');
  return 2;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(`capture-operator-profile: ${scrubText(String(e?.message ?? e))}\n`);
    process.exitCode = 2;
  }
}

export { capture, sortKeysDeep, diffPaths, buildScrubRegexes, scrubDeep, scrubText, assertScrubbed, classifyCrontabError, matchCadenceGroups, filterCommentedLines, displayPath, EXTRA_KNOWN_TASKS, isHimmelRelevantTask, decideBridgePersistence, normalizeDotenvValue, splitCadencesByRegistry };
