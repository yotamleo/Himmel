// scripts/lanes/profile-context-probe.mjs
// HIMMEL-2189 — measured half of the profile context-budget architecture
// tests. Spawns REAL `claude` calls (billed, subject to the 5h/weekly bank —
// see scripts/lib/bank-preflight.sh), so this file is NEVER part of the CI
// node --test glob. It exists to (a) prove plugin injection actually landed
// (init event `plugins[].source` == the resolved enabled set) and (b) catch
// context-footprint regressions against each profile's registry contextBudget.
// The companion scripts/lanes/tests/profile-context-probe.test.mjs exercises
// only the PURE functions below (parse/extract/evaluate/format) against a
// checked-in fixture — no live spawn there.
//
// node scripts/lanes/profile-context-probe.mjs [--profile <name>] [--ledger live|<path>] [--no-ledger]
//
// Exit codes: 0 all profiles pass, 1 any profile fails, 3 bank-preflight skip.
//
// Ledger default (HIMMEL-2189 corrective, 2026-08-28): a casual/dev invocation
// of this script must NEVER write to the live flow-runs ledger — a FAILED row
// there pages the operator (HimmelFlowRunError), and a red row from local
// iteration/debugging is not an incident. So the DEFAULT is no ledger write at
// all, the inverse of verify-return.mjs's opt-OUT (--no-ledger) convention.
// Opt IN explicitly, mirroring verify-return.mjs's flag shape:
//   --ledger live       write to the real production path (ledgerPath()) —
//                       this is what the readiness cadence should pass so its
//                       runs DO count.
//   --ledger <path>     write to an explicit scratch path (dev/measurement —
//                       equivalently, export HIMMEL_FLOW_RUNS_LEDGER).
//   HIMMEL_FLOW_RUNS_LEDGER env var — an explicit opt-in same as verify-
//                       return.mjs's ledgerPath() override; also honored with
//                       no CLI flag at all.
//   (nothing set)        no ledger write — the safe default.
import { spawnSync } from 'node:child_process';
import { writeFileSync, unlinkSync, appendFileSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isMain } from '../lib/is-main.mjs';
import { createRequire } from 'node:module';
import { loadRegistry, resolveProfileByName, readEnabledPluginIds, loadListingLib } from './plugin-profiles.mjs';
import { ledgerPath } from './verify-return.mjs';
import { ROLE_REQUIRES } from './role-requires.mjs';
import { scanSkillCosts, pluginCacheOf } from './skill-cost.mjs';

// The SAME interpreter resolution the wired hooks get. On Windows an unresolved
// shell can be the WSL launcher or a 0-byte WindowsApps alias, so we need the
// resolved one to reliably run bank-preflight.sh (HIMMEL-2257).
const { resolveBash } = createRequire(import.meta.url)('../hooks/run-hook-with-bash.js');

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(SCRIPT_DIR, '..', '..');
const CLAUDE_TIMEOUT_MS = 120_000;
const BASELINE_PROMPT = 'reply with the single word ok';

// ── pure helpers (exercised by the CI-safe companion test, no spawning) ────

// Split raw `--output-format stream-json` stdout into parsed event objects.
// A blank trailing line (or a lone stray newline) is common and silently
// skipped; any OTHER unparseable line is a real protocol surprise and throws
// — swallowing it would let a truncated/garbled stream masquerade as "no
// events found" instead of a loud parse failure.
export function parseStreamJsonLines(text) {
  return text.split('\n').filter((line) => line.trim() !== '').map((line) => JSON.parse(line));
}

export function findInitEvent(events) {
  return events.find((e) => e?.type === 'system' && e?.subtype === 'init') ?? null;
}

export function findResultEvent(events) {
  return events.find((e) => e?.type === 'result') ?? null;
}

// First-turn context tokens per the measured schema (HIMMEL-2189 discovery):
// input + cache_creation + cache_read. Returns null when the result event or
// its usage block is missing (spawn failure / timeout / unexpected shape).
export function firstTurnTokens(resultEvent) {
  const u = resultEvent?.usage;
  if (!u || typeof u !== 'object') return null;
  const { input_tokens, cache_creation_input_tokens, cache_read_input_tokens } = u;
  if (![input_tokens, cache_creation_input_tokens, cache_read_input_tokens].every((n) => typeof n === 'number' && Number.isFinite(n))) return null;
  return input_tokens + cache_creation_input_tokens + cache_read_input_tokens;
}

// The plugin@marketplace id -> bare plugin `name` (the namespace prefix a
// skill/slash_command/`plugin:<name>:` MCP server is keyed by — see the
// init-event schema note in the HIMMEL-2189 discovery probe). Not unique
// across marketplaces (two catalog entries can share a name), which is fine
// here: this is a membership check, not an identity check.
function pluginName(id) {
  return id.split('@')[0];
}

// initEvent.plugins[].source EXACT-diffed against the resolved enabled-true
// id set. extra = bloat (something loaded that shouldn't be); missing =
// injection failure (a plugin the resolver enabled never actually loaded).
export function pluginSourceDiff(initEvent, enabledIds) {
  const actual = new Set((initEvent?.plugins ?? []).map((p) => p.source));
  const expected = new Set(enabledIds);
  return {
    extra: [...actual].filter((id) => !expected.has(id)).sort(),
    missing: [...expected].filter((id) => !actual.has(id)).sort(),
  };
}

// Namespaced skills/slash_commands (`plugin:entry`) and plugin MCP servers
// (`plugin:<name>:<server>`) whose namespace does not map to an enabled
// plugin. UN-namespaced entries (no ':', or the un-namespaced user/project
// tiers) are not this check's concern — they load regardless of profile.
export function namespaceExtras(initEvent, enabledIds) {
  const names = new Set(enabledIds.map(pluginName));
  const extras = [];
  for (const skill of initEvent?.skills ?? []) {
    const m = /^([^:]+):/.exec(skill);
    if (m && !names.has(m[1])) extras.push(`skill:${skill}`);
  }
  for (const cmd of initEvent?.slash_commands ?? []) {
    const m = /^([^:]+):/.exec(cmd);
    if (m && !names.has(m[1])) extras.push(`slash_command:${cmd}`);
  }
  for (const srv of initEvent?.mcp_servers ?? []) {
    const m = /^plugin:([^:]+):/.exec(srv?.name ?? '');
    if (m && !names.has(m[1])) extras.push(`mcp:${srv.name}`);
  }
  return extras;
}

// HIMMEL-4012: an enabled plugin that fails to load still shows in the
// resolved set, so "enabled" proves nothing. Each role-required plugin must
// expose at least one skill, slash command or agent namespaced `<name>:` in the
// init event. Returns one problem string per plugin that exposes nothing.
export function roleCoverageProblems(initEvent, requiredIds) {
  const exposed = new Set();
  for (const entry of [...(initEvent?.skills ?? []), ...(initEvent?.slash_commands ?? []), ...(initEvent?.agents ?? [])]) {
    const m = /^([^:]+):/.exec(typeof entry === 'string' ? entry : entry?.name ?? '');
    if (m) exposed.add(m[1]);
  }
  return requiredIds.filter((id) => !exposed.has(pluginName(id))).map((id) => `role-required plugin ${id} exposes no skill, command or agent (enabled but not loaded)`);
}

// HIMMEL-4036: `claude -p /context` replies with an assistant event carrying
// context_usage, whose skills[] is the POST-cap listing (what the model is sent).
export function findContextUsage(events) {
  const e = events.find((x) => x?.type === 'assistant' && (x.context_usage || x.message?.context_usage));
  return e ? (e.context_usage ?? e.message.context_usage) : null;
}

// Past the 1% listing budget Claude Code keeps every skill NAME and drops the
// description, so a name-only entry costs about name-length/3 tokens. Heuristic
// (measured: bare entries 2-13 tok, described ones far above).
export function isNameOnlySkill(skill) {
  return (skill?.tokens ?? 0) <= Math.ceil(String(skill?.name ?? '').length / 3) + 2;
}

const pluginSkills = (contextUsage, id) => (contextUsage?.skills ?? []).filter((s) => s.plugin_name === pluginName(id));

// Per required plugin: how many skills reached the listing, how many are
// name-only, and their summed tokens.
export function listingReport(contextUsage, requiredIds) {
  return requiredIds.map((id) => {
    const skills = pluginSkills(contextUsage, id);
    return { plugin: pluginName(id), skills: skills.length, nameOnly: skills.filter(isNameOnlySkill).length, tokens: skills.reduce((a, s) => a + (s.tokens ?? 0), 0) };
  });
}

// The listing budget (a fraction of the context window) at which every
// role-required skill keeps its description while all other skills sit
// name-only: current listing tokens plus the uncapped cost of each name-only
// required skill's description, over raw_max_tokens. costEntries come from
// skill-cost.mjs's scan, matched by skill name under a `/<plugin>/` path (the
// plugin cache); chars/4 is the estimate. Feeds HIMMEL-4038's skillOverrides +
// skillListingBudgetFraction. null when the window size is unknown.
export function requiredBudget(contextUsage, requiredIds, costEntries) {
  const rawMax = contextUsage?.raw_max_tokens;
  if (!Number.isFinite(rawMax) || rawMax <= 0) return null;
  const listingTokens = (contextUsage.skills ?? []).reduce((a, s) => a + (s.tokens ?? 0), 0);
  let extraTokens = 0;
  let unmatched = 0;
  for (const id of requiredIds) {
    const plugin = pluginName(id);
    for (const s of pluginSkills(contextUsage, id).filter(isNameOnlySkill)) {
      const bare = s.name.slice(plugin.length + 1);
      // several cached versions of one plugin can match: take the largest
      const matches = costEntries.filter((e) => e.name === bare && pluginCacheOf(e.path)?.plugin === plugin);
      if (!matches.length) unmatched += 1;
      const chars = Math.max(0, ...matches.map((e) => e.chars));
      extraTokens += Math.max(0, Math.ceil((chars + plugin.length + 1) / 4) - s.tokens);
    }
  }
  return { listingTokens, extraTokens, unmatched, fraction: Math.ceil(((listingTokens + extraTokens) / rawMax) * 1000) / 1000 };
}

// EVERY skill of a required plugin must reach the model DESCRIBED (HIMMEL-4038).
// skillPlugins (names of plugins that expose skills in the init event) lets an
// agent-only plugin skip the check; omitted = every required plugin has skills.
// The skills a required plugin should expose: `<plugin>:<name>` for every scanned
// skill under the plugin's LATEST cached version (an older cached version can
// carry skills the current one dropped). Matches the plugin-cache directory
// component, not a path substring (HIMMEL-4060).
export function expectedSkillNames(costEntries, requiredIds) {
  const names = new Set();
  for (const id of requiredIds) {
    const plugin = pluginName(id);
    const mine = costEntries.filter((e) => e.scope === 'plugin-skills').map((e) => ({ e, c: pluginCacheOf(e.path) })).filter((x) => x.c?.plugin === plugin);
    const latest = mine.map((x) => x.c.version).sort((a, b) => a.localeCompare(b, undefined, { numeric: true })).at(-1);
    for (const x of mine) if (x.c.version === latest) names.add(`${plugin}:${x.e.name}`);
  }
  return names;
}

// expectedSkills (a Set of `<plugin>:<name>` from expectedSkillNames) additionally
// flags a required skill that never reached the listing at all (HIMMEL-4060).
export function listingProblems(contextUsage, requiredIds, { skillPlugins, expectedSkills } = {}) {
  if (!requiredIds.length) return [];
  if (!contextUsage) return ['no context_usage in /context output (cannot verify the post-cap skill listing)'];
  const problems = [];
  for (const id of requiredIds) {
    const skills = pluginSkills(contextUsage, id);
    if (!skills.length) {
      if (!skillPlugins || skillPlugins.has(pluginName(id))) problems.push(`role-required plugin ${id} is missing from the post-cap skill listing`);
    } else {
      const bare = skills.filter(isNameOnlySkill);
      if (bare.length) problems.push(`role-required plugin ${id} has ${bare.length} of ${skills.length} skill(s) name-only in the post-cap listing (descriptions dropped by the listing budget): ${bare.map((s) => s.name).join(', ')}`);
      const listed = new Set(skills.map((s) => s.name));
      const absent = [...(expectedSkills ?? [])].filter((n) => n.startsWith(`${pluginName(id)}:`) && !listed.has(n));
      if (absent.length) problems.push(`role-required plugin ${id} has ${absent.length} expected skill(s) absent from the post-cap listing: ${absent.sort().join(', ')}`);
    }
  }
  return problems;
}

export function countLoadedSkills(initEvent) {
  return (initEvent?.skills?.length ?? 0) + (initEvent?.slash_commands?.length ?? 0);
}

// The full per-profile verdict: plugin injection correctness + the
// contextBudget ceiling. Returns { pass, problems } — problems is [] iff pass.
export function evaluateProfile({ enabledIds, requiredIds = [], initEvent, resultEvent, measuredTokens, budget, contextUsage, expectedSkills }) {
  const problems = [];
  if (!initEvent) {
    problems.push('no init event in probe output (spawn failure, timeout, or unexpected stream shape)');
    return { pass: false, problems };
  }
  problems.push(...roleCoverageProblems(initEvent, requiredIds));
  if (contextUsage !== undefined) {
    const skillPlugins = new Set((initEvent.skills ?? []).map((x) => /^([^:]+):/.exec(x)?.[1]).filter(Boolean));
    problems.push(...listingProblems(contextUsage, requiredIds, { skillPlugins, expectedSkills }));
  }
  const { extra, missing } = pluginSourceDiff(initEvent, enabledIds);
  if (extra.length) problems.push(`extra plugin(s) loaded (bloat): ${extra.join(', ')}`);
  if (missing.length) problems.push(`expected plugin(s) did not load: ${missing.join(', ')}`);
  const nsExtras = namespaceExtras(initEvent, enabledIds);
  if (nsExtras.length) problems.push(`namespaced entries from a disabled/unknown plugin: ${nsExtras.join(', ')}`);
  // An errored turn can still carry a usage block (tokens were spent before the
  // failure), which would otherwise let a crashed/refused claude call PASS on
  // token count alone. subtype !== 'success' catches non-is_error failure
  // shapes too (e.g. error_max_turns).
  if (resultEvent && (resultEvent.is_error || resultEvent.subtype !== 'success')) {
    problems.push(`result event reported failure (subtype=${resultEvent.subtype ?? 'unknown'}, is_error=${!!resultEvent.is_error})`);
  }
  if (!Number.isInteger(budget) || budget <= 0) problems.push('profile has no valid contextBudget (hard fail — set one before measuring)');
  else if (measuredTokens === null) problems.push('could not measure first-turn tokens (no result event / missing usage)');
  else if (measuredTokens > budget) problems.push(`first-turn tokens ${measuredTokens} exceed contextBudget ${budget}`);
  return { pass: problems.length === 0, problems };
}

const fmtNum = (n) => (typeof n === 'number' && Number.isFinite(n) ? String(n) : 'n/a');

// `<PASS|FAILED> <profile> measured=<n> budget=<n> baseline=<n> delta=<n>`
export function formatNote(profileName, { pass, measured, budget, baseline }) {
  const delta = typeof measured === 'number' && typeof baseline === 'number' ? measured - baseline : null;
  return `${pass ? 'PASS' : 'FAILED'} ${profileName} measured=${fmtNum(measured)} budget=${fmtNum(budget)} baseline=${fmtNum(baseline)} delta=${fmtNum(delta)}`;
}

// ── ledger (best-effort, mirrors verify-return.mjs's end-row shape) ────────
const jsonStr = (s) => JSON.stringify(String(s));
// profileName is part of the run_id (not just note/timestamp): two profiles
// measured in the same minute under the same pid would otherwise collide on
// one run_id, letting one profile's outcome overwrite/conflict with the
// other's under a shared identity.
export function buildLedgerRow(profileName, note, exitCode, { now = new Date(), pid = process.pid } = {}) {
  const iso = now.toISOString().replace(/\.\d{3}Z$/, 'Z');
  const compact = iso.slice(0, 16).replace(/[-:]/g, '');
  const outcome = exitCode === 0 ? 'complete' : 'error';
  return `{"v":1,"ev":"end","flow":"profile-context","run_id":${jsonStr(`profile-context-${profileName}-${compact}-${pid}`)},` +
    `"ended_at":${jsonStr(iso)},"exit_code":${exitCode},"outcome":${jsonStr(outcome)},` +
    `"items_processed":null,"note":${jsonStr(note)}}`;
}
// null targetPath = ledger disabled (the default) — a deliberate no-op, not
// an error, so it prints nothing.
function appendLedger(profileName, note, exitCode, targetPath) {
  if (!targetPath) return;
  try {
    mkdirSync(dirname(targetPath), { recursive: true });
    appendFileSync(targetPath, buildLedgerRow(profileName, note, exitCode) + '\n');
  } catch (e) {
    process.stderr.write(`profile-context-probe: ledger append failed (verdict unaffected): ${e.message}\n`);
  }
}

// CLI arg parsing, pure so it's unit-testable without touching argv/env
// globals. Throws on an unknown/malformed flag (fail loud, not silently
// ignored — same reasoning as plugin-profiles.mjs's CLI parse).
export function parseProbeArgs(argv) {
  let profile = null, ledgerFlag, noLedger = false;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--no-ledger') { noLedger = true; continue; }
    if (a === '--ledger') {
      ledgerFlag = argv[++i];
      if (!ledgerFlag) throw new Error('--ledger requires a value ("live" or a path)');
      continue;
    }
    if (a === '--profile') {
      profile = argv[++i];
      if (!profile) throw new Error('--profile requires a value');
      continue;
    }
    throw new Error(`unknown argument "${a}"`);
  }
  if (noLedger && ledgerFlag) throw new Error('--no-ledger and --ledger are mutually exclusive');
  return { profile, ledgerFlag, noLedger };
}

// The safe-default resolution described in the file header above. `env` is
// injected so this is testable without mutating process.env.
export function resolveLedgerTarget({ ledgerFlag, noLedger }, env) {
  if (noLedger) return null;
  if (ledgerFlag === 'live') return ledgerPath(env);
  if (ledgerFlag) return ledgerFlag;
  if (env.HIMMEL_FLOW_RUNS_LEDGER) return ledgerPath(env); // explicit env opt-in
  return null; // safe default — no ledger write
}

// ── live spawn (never imported by the CI-safe test) ────────────────────────

// Spawned directly — no shell wrapper: the `claude` this repo
// targets is the native installer binary (not an npm .cmd shim), so win32
// PATH resolution finds it without cmd.exe in the loop.
function spawnClaude(extraArgs, prompt) {
  const args = ['-p', '--model', 'haiku', '--max-turns', '1', '--permission-mode', 'dontAsk',
    '--output-format', 'stream-json', '--verbose', ...extraArgs, prompt];
  // headless-claude-ok: HIMMEL-2189 measured profile probe
  // launch-profile-ok: the probe passes the profile under test via extraArgs (--settings per run)
  return spawnSync('claude', args, {
    cwd: REPO_ROOT,
    encoding: 'utf8',
    timeout: CLAUDE_TIMEOUT_MS,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, MSYS_NO_PATHCONV: '1' },
  });
}

// A run's { initEvent, resultEvent, measured } — or an all-null shape on any
// launch/parse failure (spawn error, timeout, non-JSONL output). Never throws:
// a probe run failing to produce events IS a result (evaluateProfile turns
// the null initEvent into a FAILED verdict), not a crash.
//
// ONE retry on ETIMEDOUT (HIMMEL-2189 debugging finding, 2026-08-28): a
// sequential multi-profile run occasionally hit a single ETIMEDOUT spawn
// (reproduced twice, always position 3, while the account's own 7-day bank
// utilization sat near 84% — the API's own near-cap latency, not this
// profile's content: the SAME profile re-run standalone, seconds later,
// measured cleanly). Retrying once turns that ordinary API-latency noise
// into a real regression signal instead of a coin-flip FAILED row.
function runClaude(extraArgs, prompt = BASELINE_PROMPT, retriesLeft = 1) {
  const r = spawnClaude(extraArgs, prompt);
  if (r.error?.code === 'ETIMEDOUT' && retriesLeft > 0) {
    process.stderr.write('profile-context-probe: spawn timed out — retrying once\n');
    return runClaude(extraArgs, prompt, retriesLeft - 1);
  }
  if (r.error || typeof r.stdout !== 'string') {
    process.stderr.write(`profile-context-probe: spawn failed: ${r.error?.message ?? `signal ${r.signal}`}\n`);
    return { initEvent: null, resultEvent: null, measured: null };
  }
  let events;
  try { events = parseStreamJsonLines(r.stdout); }
  catch (e) {
    process.stderr.write(`profile-context-probe: could not parse stream-json output: ${e.message}\n`);
    return { initEvent: null, resultEvent: null, measured: null };
  }
  const resultEvent = findResultEvent(events);
  return { initEvent: findInitEvent(events), resultEvent, measured: firstTurnTokens(resultEvent), contextUsage: findContextUsage(events) };
}

function main() {
  let opts;
  try { opts = parseProbeArgs(process.argv.slice(2)); }
  catch (e) { process.stderr.write(`profile-context-probe: ${e.message}\n`); process.exitCode = 2; return; }
  const ledgerTarget = resolveLedgerTarget(opts, process.env);

  // 30s timeout, mirroring the claude spawn's own CLAUDE_TIMEOUT_MS bound: a
  // hung/slow preflight must degrade to a skip (exit 3), never hang or crash
  // this probe.
  const bash = resolveBash();
  if (!bash) {
    process.stdout.write(`profile-context-probe: skipped — no usable bash found to run bank-preflight\n`);
    process.exitCode = 3;
    return;
  }
  const preflight = spawnSync(bash, ['scripts/lib/bank-preflight.sh'], { cwd: REPO_ROOT, encoding: 'utf8', timeout: 30_000 });
  if (preflight.error) {
    process.stdout.write(`profile-context-probe: skipped — bank-preflight failed to run (${preflight.error.message})\n`);
    process.exitCode = 3;
    return;
  }
  const token = (preflight.stdout ?? '').trim();
  if (token !== 'PROCEED') {
    process.stdout.write(`profile-context-probe: skipped — bank-preflight verdict ${token || '(none)'}\n`);
    process.exitCode = 3;
    return;
  }

  process.stdout.write('profile-context-probe: measuring baseline (no --settings)…\n');
  const baselineRun = runClaude([]);
  if (baselineRun.measured === null) process.stderr.write('profile-context-probe: baseline measurement failed — deltas will read n/a\n');
  const baseline = baselineRun.measured;

  // registry/settings-layer reads: a corrupted registry or an unparseable
  // settings file must exit cleanly (2), not crash with a raw stack trace.
  let registry, profileNames, installed;
  try {
    registry = loadRegistry();
    profileNames = Object.keys(registry.profiles ?? {}).filter((name) => name !== 'operator');
    installed = readEnabledPluginIds(homedir(), REPO_ROOT, process.env.CLAUDE_CONFIG_DIR);
  } catch (e) {
    process.stderr.write(`profile-context-probe: ${e.message}\n`);
    process.exitCode = 2;
    return;
  }
  if (opts.profile) {
    if (!profileNames.includes(opts.profile)) { process.stderr.write(`profile-context-probe: unknown profile "${opts.profile}" (known: ${profileNames.join(', ')})\n`); process.exitCode = 2; return; }
    profileNames = [opts.profile];
  }

  let scanned;
  const configDir = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude');
  const costEntries = () => (scanned ??= scanSkillCosts({ cwd: REPO_ROOT, configDir }).entries);
  let anyFailed = false;
  // Private per-run tmpdir (mkdtempSync is exclusive/unpredictable), not a
  // shared predictable path — a predictable path + non-exclusive writeFileSync
  // is a symlink/race target.
  const settingsDir = mkdtempSync(join(tmpdir(), 'profile-context-'));
  try {
    for (const name of profileNames) {
      let settings;
      try {
        settings = resolveProfileByName(name, { installed, skillEntries: costEntries(), configDir });
      } catch (e) {
        process.stderr.write(`profile-context-probe: ${e.message}\n`);
        process.exitCode = 2;
        return;
      }
      const enabledIds = Object.entries(settings.enabledPlugins).filter(([, on]) => on).map(([id]) => id);
      const budget = registry.profiles[name].contextBudget;

      const settingsPath = join(settingsDir, `${name}.json`).replace(/\\/g, '/');
      writeFileSync(settingsPath, JSON.stringify(settings));
      let run, ctxRun;
      try {
        run = runClaude(['--settings', settingsPath]);
        // /context is answered locally by Claude Code (no model turn) and reports
        // the post-cap skill listing the model actually receives (HIMMEL-4036).
        ctxRun = runClaude(['--settings', settingsPath], '/context');
      } finally {
        try { unlinkSync(settingsPath); } catch { /* best-effort cleanup */ }
      }

      const requiredIds = ROLE_REQUIRES[name] ?? [];
      const { pass, problems } = evaluateProfile({ enabledIds, requiredIds, initEvent: run.initEvent, resultEvent: run.resultEvent, measuredTokens: run.measured, budget, contextUsage: ctxRun.contextUsage ?? null, expectedSkills: expectedSkillNames(costEntries(), requiredIds) });
      const note = `${formatNote(name, { pass, measured: run.measured, budget, baseline })} skills=${countLoadedSkills(run.initEvent)} required=${requiredIds.length}`;
      process.stdout.write(note + '\n');
      const need = requiredBudget(ctxRun.contextUsage, requiredIds, costEntries());
      if (need) process.stdout.write(`  budget to fit required set: skillListingBudgetFraction >= ${need.fraction} (listing ${need.listingTokens} tok + ${need.extraTokens} tok of descriptions${need.unmatched ? `; ${need.unmatched} name-only skill(s) not in the skill-cost scan, so this is a lower bound` : ''})\n`);
      for (const r of listingReport(ctxRun.contextUsage, requiredIds)) process.stdout.write(`  listing ${r.plugin}: ${r.skills} skill(s), ${r.nameOnly} name-only, ${r.tokens} tok\n`);
      for (const p of problems) process.stdout.write(`  - ${p}\n`);
      appendLedger(name, note, pass ? 0 : 1, ledgerTarget);
      if (!pass) anyFailed = true;
    }
  } finally {
    try { rmSync(settingsDir, { recursive: true, force: true }); } catch { /* best-effort cleanup */ }
  }

  process.stdout.write(anyFailed ? 'profile-context-probe: FAILED — one or more profiles regressed\n' : 'profile-context-probe: PASS — all profiles within budget\n');
  process.exitCode = anyFailed ? 1 : 0;
}

if (isMain(import.meta.url)) {
  await loadListingLib();
  main();
}
