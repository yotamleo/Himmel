// scripts/lanes/tests/profile-context-probe.test.mjs
// HIMMEL-2189 — CI-safe companion to profile-context-probe.mjs. Exercises only
// the PURE functions it exports (parse/extract/evaluate/format) against a
// checked-in fixture derived from a real `claude --output-format stream-json`
// run (session ids/paths sanitized). NO live spawns here — the probe itself
// is excluded from the CI node --test glob because it bills real usage.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync, rmSync, symlinkSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  parseStreamJsonLines, findInitEvent, findResultEvent, firstTurnTokens,
  pluginSourceDiff, namespaceExtras, evaluateProfile, formatNote, roleCoverageProblems, countLoadedSkills,
  parseProbeArgs, resolveLedgerTarget, buildLedgerRow,
  findContextUsage, userScopeSkillDirs, isNameOnlySkill, listingProblems, expectedSkillNames, installedVersionsOf, listingReport, requiredBudget, runtimeNamesOf,
} from '../profile-context-probe.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const SAMPLE = readFileSync(join(HERE, 'fixtures', 'profile-context-probe-sample.jsonl'), 'utf8');
const ENABLED = ['qmd@himmel', 'handover@himmel', 'himmel-ops@himmel']; // matches the fixture's plugins[].source, i.e. the "bare" shape

test('parseStreamJsonLines parses the fixture into events, skipping blank lines', () => {
  const events = parseStreamJsonLines(SAMPLE + '\n\n');
  assert.equal(events.length, 2);
  assert.equal(events[0].type, 'system');
  assert.equal(events[1].type, 'result');
});

test('parseStreamJsonLines throws on a genuinely unparseable line (not silently swallowed)', () => {
  assert.throws(() => parseStreamJsonLines('{"type":"system"}\nnot json\n'));
});

test('findInitEvent / findResultEvent locate the right lines regardless of position', () => {
  const events = parseStreamJsonLines(SAMPLE);
  assert.equal(findInitEvent(events).subtype, 'init');
  assert.equal(findResultEvent(events).type, 'result');
  assert.equal(findInitEvent([]), null);
  assert.equal(findResultEvent([{ type: 'system', subtype: 'init' }]), null);
});

test('firstTurnTokens sums input + cache_creation + cache_read (measured HIMMEL-2189 schema)', () => {
  const events = parseStreamJsonLines(SAMPLE);
  const tokens = firstTurnTokens(findResultEvent(events));
  assert.equal(tokens, 10 + 12960 + 22128); // == 35098, matching the measured bare baseline
});

test('firstTurnTokens returns null on a missing/malformed usage block', () => {
  assert.equal(firstTurnTokens(null), null);
  assert.equal(firstTurnTokens({ usage: {} }), null);
  assert.equal(firstTurnTokens({ usage: { input_tokens: 1, cache_creation_input_tokens: 'x', cache_read_input_tokens: 2 } }), null);
});

test('pluginSourceDiff: fixture plugins[] exactly match the expected enabled set -> no extra/missing', () => {
  const events = parseStreamJsonLines(SAMPLE);
  const { extra, missing } = pluginSourceDiff(findInitEvent(events), ENABLED);
  assert.deepEqual(extra, []);
  assert.deepEqual(missing, []);
});

test('pluginSourceDiff catches bloat (an unexpected plugin loaded) and injection failure (an expected one missing)', () => {
  const events = parseStreamJsonLines(SAMPLE);
  const init = findInitEvent(events);
  const { extra } = pluginSourceDiff(init, ['qmd@himmel']); // fewer expected than actually loaded
  assert.deepEqual(extra, ['handover@himmel', 'himmel-ops@himmel']);
  const { missing } = pluginSourceDiff(init, [...ENABLED, 'never-loaded@himmel']);
  assert.deepEqual(missing, ['never-loaded@himmel']);
});

test('namespaceExtras: fixture skills/slash_commands/mcp_servers all map to an enabled plugin name', () => {
  const events = parseStreamJsonLines(SAMPLE);
  assert.deepEqual(namespaceExtras(findInitEvent(events), ENABLED), []);
});

test('namespaceExtras flags a namespaced entry whose plugin is not enabled', () => {
  const events = parseStreamJsonLines(SAMPLE);
  // drop himmel-ops from the enabled set -> its skill/slash_command/mcp entries become extras
  const extras = namespaceExtras(findInitEvent(events), ['qmd@himmel', 'handover@himmel']);
  assert.ok(extras.includes('skill:himmel-ops:minerva'));
  assert.ok(extras.includes('slash_command:himmel-ops:minerva'));
});

test('evaluateProfile: happy path passes when injection is clean and tokens are under budget', () => {
  const events = parseStreamJsonLines(SAMPLE);
  const { pass, problems } = evaluateProfile({ enabledIds: ENABLED, initEvent: findInitEvent(events), measuredTokens: 35098, budget: 40000 });
  assert.equal(pass, true);
  assert.deepEqual(problems, []);
});

test('evaluateProfile: no init event is a hard fail', () => {
  const { pass, problems } = evaluateProfile({ enabledIds: ENABLED, initEvent: null, measuredTokens: 100, budget: 40000 });
  assert.equal(pass, false);
  assert.ok(problems.some((p) => /no init event/.test(p)));
});

test('evaluateProfile: an invalid/missing contextBudget is a hard fail (placeholder-budget guard)', () => {
  const events = parseStreamJsonLines(SAMPLE);
  for (const bad of [undefined, 0, -1, 1.5]) {
    const { pass, problems } = evaluateProfile({ enabledIds: ENABLED, initEvent: findInitEvent(events), measuredTokens: 100, budget: bad });
    assert.equal(pass, false);
    assert.ok(problems.some((p) => /no valid contextBudget/.test(p)), `budget=${bad} must fail with the placeholder-budget message`);
  }
});

test('evaluateProfile: measured tokens over budget fails with the exact numbers named', () => {
  const events = parseStreamJsonLines(SAMPLE);
  const { pass, problems } = evaluateProfile({ enabledIds: ENABLED, initEvent: findInitEvent(events), measuredTokens: 50000, budget: 40000 });
  assert.equal(pass, false);
  assert.ok(problems.some((p) => p.includes('50000') && p.includes('40000')));
});

test('evaluateProfile: a real success result event (fixture, resultEvent passed explicitly) still passes', () => {
  const events = parseStreamJsonLines(SAMPLE);
  const { pass, problems } = evaluateProfile({ enabledIds: ENABLED, initEvent: findInitEvent(events), resultEvent: findResultEvent(events), measuredTokens: 35098, budget: 40000 });
  assert.equal(pass, true);
  assert.deepEqual(problems, []);
});

test('evaluateProfile: is_error:true on the result event fails even with valid usage/budget (an errored turn can still report tokens)', () => {
  const events = parseStreamJsonLines(SAMPLE);
  const resultEvent = { ...findResultEvent(events), is_error: true };
  const { pass, problems } = evaluateProfile({ enabledIds: ENABLED, initEvent: findInitEvent(events), resultEvent, measuredTokens: 35098, budget: 40000 });
  assert.equal(pass, false);
  assert.ok(problems.some((p) => /result event reported failure/.test(p) && p.includes('is_error=true')));
});

test('evaluateProfile: subtype !== "success" fails even when is_error is false', () => {
  const events = parseStreamJsonLines(SAMPLE);
  const resultEvent = { ...findResultEvent(events), subtype: 'error_max_turns' };
  const { pass, problems } = evaluateProfile({ enabledIds: ENABLED, initEvent: findInitEvent(events), resultEvent, measuredTokens: 35098, budget: 40000 });
  assert.equal(pass, false);
  assert.ok(problems.some((p) => p.includes('subtype=error_max_turns')));
});

test('formatNote: PASS/FAILED line shape, including delta = measured - baseline', () => {
  assert.equal(formatNote('bare', { pass: true, measured: 35000, budget: 40000, baseline: 30000 }), 'PASS bare measured=35000 budget=40000 baseline=30000 delta=5000');
  assert.equal(formatNote('bare', { pass: false, measured: 45000, budget: 40000, baseline: 30000 }), 'FAILED bare measured=45000 budget=40000 baseline=30000 delta=15000');
});

test('formatNote: missing measured/baseline renders n/a rather than throwing', () => {
  assert.equal(formatNote('bare', { pass: false, measured: null, budget: 40000, baseline: null }), 'FAILED bare measured=n/a budget=40000 baseline=n/a delta=n/a');
});

// ── HIMMEL-2189 corrective (2026-08-28): ledger safe-default + --profile ───

test('parseProbeArgs: no flags -> all defaults', () => {
  assert.deepEqual(parseProbeArgs([]), { profile: null, ledgerFlag: undefined, noLedger: false });
});

test('parseProbeArgs: --profile, --ledger, --no-ledger parse correctly', () => {
  assert.deepEqual(parseProbeArgs(['--profile', 'bare']), { profile: 'bare', ledgerFlag: undefined, noLedger: false });
  assert.deepEqual(parseProbeArgs(['--ledger', 'live']), { profile: null, ledgerFlag: 'live', noLedger: false });
  assert.deepEqual(parseProbeArgs(['--ledger', '/tmp/x.jsonl']), { profile: null, ledgerFlag: '/tmp/x.jsonl', noLedger: false });
  assert.deepEqual(parseProbeArgs(['--no-ledger']), { profile: null, ledgerFlag: undefined, noLedger: true });
});

test('parseProbeArgs: malformed/unknown/conflicting flags throw', () => {
  assert.throws(() => parseProbeArgs(['--ledger']), /--ledger requires a value/);
  assert.throws(() => parseProbeArgs(['--profile']), /--profile requires a value/);
  assert.throws(() => parseProbeArgs(['--bogus']), /unknown argument "--bogus"/);
  assert.throws(() => parseProbeArgs(['--ledger', 'live', '--no-ledger']), /mutually exclusive/);
});

test('resolveLedgerTarget: the safe default is NO ledger write (HIMMEL-2189 corrective — a casual/dev run must never page the operator)', () => {
  assert.equal(resolveLedgerTarget({ ledgerFlag: undefined, noLedger: false }, {}), null);
});

test('resolveLedgerTarget: --no-ledger always wins, even over an env opt-in', () => {
  assert.equal(resolveLedgerTarget({ ledgerFlag: undefined, noLedger: true }, { HIMMEL_FLOW_RUNS_LEDGER: '/x.jsonl' }), null);
});

test('resolveLedgerTarget: --ledger live resolves to the real production ledgerPath()', () => {
  assert.equal(resolveLedgerTarget({ ledgerFlag: 'live', noLedger: false }, { HOME: '/home/x' }), join('/home/x', '.himmel', 'flow-runs.jsonl'));
});

test('resolveLedgerTarget: --ledger <path> is used verbatim', () => {
  assert.equal(resolveLedgerTarget({ ledgerFlag: '/scratch/ledger.jsonl', noLedger: false }, {}), '/scratch/ledger.jsonl');
});

test('resolveLedgerTarget: HIMMEL_FLOW_RUNS_LEDGER env var is an explicit opt-in even with no CLI flag', () => {
  assert.equal(resolveLedgerTarget({ ledgerFlag: undefined, noLedger: false }, { HIMMEL_FLOW_RUNS_LEDGER: '/scratch/env-ledger.jsonl' }), '/scratch/env-ledger.jsonl');
});

test('buildLedgerRow: run_id includes the profile name, so two profiles measured in the same minute/pid do not collide', () => {
  const now = new Date('2026-08-28T12:34:56.000Z');
  const rowA = JSON.parse(buildLedgerRow('bare', 'PASS bare', 0, { now, pid: 123 }));
  const rowB = JSON.parse(buildLedgerRow('lane-full', 'PASS lane-full', 0, { now, pid: 123 }));
  assert.notEqual(rowA.run_id, rowB.run_id);
  assert.match(rowA.run_id, /^profile-context-bare-\d{8}T\d{4}-123$/);
  assert.match(rowB.run_id, /^profile-context-lane-full-\d{8}T\d{4}-123$/);
});

// HIMMEL-4012: an enabled plugin that fails to load must FAIL the probe.
const LOADED = {
  type: 'system', subtype: 'init',
  plugins: [{ source: 'impeccable@himmel' }, { source: 'frontend-design@claude-plugins-official' }],
  skills: ['impeccable:impeccable', 'frontend-design:frontend-design'],
  slash_commands: [], agents: [], mcp_servers: [],
};

test('roleCoverageProblems: passes when every required plugin exposes a skill, command or agent', () => {
  assert.deepEqual(roleCoverageProblems(LOADED, ['impeccable@himmel', 'frontend-design@claude-plugins-official']), []);
});

test('roleCoverageProblems: an enabled plugin that exposes nothing is reported', () => {
  const init = { ...LOADED, skills: ['frontend-design:frontend-design'] };
  const p = roleCoverageProblems(init, ['impeccable@himmel', 'frontend-design@claude-plugins-official']);
  assert.equal(p.length, 1);
  assert.match(p[0], /impeccable@himmel/);
});

test('roleCoverageProblems: an agent-only plugin counts as loaded', () => {
  const init = { ...LOADED, skills: [], agents: ['impeccable:finish-reviewer'] };
  assert.deepEqual(roleCoverageProblems(init, ['impeccable@himmel']), []);
});

test('roleCoverageProblems: an MCP-only plugin counts as loaded (HIMMEL-4067), needs-auth included', () => {
  const init = { ...LOADED, skills: [], mcp_servers: [{ name: 'plugin:shadcn-mcp:shadcn', status: 'connected' }, { name: 'plugin:context7:context7', status: 'needs-auth' }] };
  assert.deepEqual(roleCoverageProblems(init, ['shadcn-mcp@himmel', 'context7@claude-plugins-official']), []);
});

test('roleCoverageProblems: an un-namespaced user MCP server does not count for a plugin (HIMMEL-4067)', () => {
  const init = { ...LOADED, skills: [], mcp_servers: [{ name: 'context7', status: 'connected' }] };
  assert.equal(roleCoverageProblems(init, ['context7@claude-plugins-official']).length, 1);
});

test('evaluateProfile: a missing role-required skill fails the profile', () => {
  const init = { ...LOADED, skills: [] };
  const { pass, problems } = evaluateProfile({
    enabledIds: ['impeccable@himmel', 'frontend-design@claude-plugins-official'], requiredIds: ['impeccable@himmel'],
    initEvent: init, measuredTokens: 100, budget: 40000,
  });
  assert.equal(pass, false);
  assert.ok(problems.some((x) => /role-required/.test(x)));
});

test('countLoadedSkills counts skills plus slash_commands', () => {
  assert.equal(countLoadedSkills({ skills: ['a:b', 'c'], slash_commands: ['d'] }), 3);
  assert.equal(countLoadedSkills(null), 0);
});

// HIMMEL-4036: the post-cap skill listing. Claude Code keeps every skill NAME but
// drops descriptions past the 1% listing budget, so "loaded" can mean "a bare name".
const CTX = (skills) => ({ skills });
const NAME_ONLY = { name: 'impeccable:impeccable', source: 'plugin', plugin_name: 'impeccable', tokens: 6 };
const FULL = { name: 'impeccable:impeccable', source: 'plugin', plugin_name: 'impeccable', tokens: 74 };

test('findContextUsage reads context_usage off the assistant event', () => {
  const ev = [{ type: 'system' }, { type: 'assistant', context_usage: { skills: [] } }];
  assert.deepEqual(findContextUsage(ev), { skills: [] });
  assert.equal(findContextUsage([{ type: 'system' }]), null);
});

test('isNameOnlySkill: a name-sized entry is name-only, a described one is not', () => {
  assert.equal(isNameOnlySkill(NAME_ONLY), true);
  assert.equal(isNameOnlySkill(FULL), false);
});

test('listingProblems: a required plugin whose skills are name-only FAILS (descriptions dropped)', () => {
  const p = listingProblems(CTX([NAME_ONLY]), ['impeccable@himmel']);
  assert.equal(p.length, 1);
  assert.match(p[0], /impeccable@himmel.*name-only/);
});

// HIMMEL-4038: EVERY required skill must be described, not just one per plugin.
test('listingProblems: all described skills pass', () => {
  assert.deepEqual(listingProblems(CTX([FULL, { ...FULL, name: 'impeccable:other' }]), ['impeccable@himmel']), []);
});

test('listingProblems: one name-only skill among described ones FAILS and is named', () => {
  const p = listingProblems(CTX([NAME_ONLY, FULL]), ['impeccable@himmel']);
  assert.equal(p.length, 1);
  assert.match(p[0], /impeccable@himmel.*1 of 2.*name-only.*impeccable:impeccable/s);
});

test('listingProblems: an expected-skills inventory defeats the agent-only exemption', () => {
  const p = listingProblems(CTX([]), ['impeccable@himmel'], { skillPlugins: new Set(), expectedSkills: new Set(['impeccable:audit']) });
  assert.match(p[0], /missing from the post-cap skill listing/);
});

test('listingProblems: a required plugin absent from the listing fails, unless it has no skills (agent-only)', () => {
  assert.match(listingProblems(CTX([]), ['impeccable@himmel'], { skillPlugins: new Set(['impeccable']) })[0], /missing from the post-cap skill listing/);
  assert.deepEqual(listingProblems(CTX([]), ['impeccable@himmel'], { skillPlugins: new Set() }), []);
});

// HIMMEL-4060 item 2: the listing is compared against the expected inventory.
const scanned = (plugin, name, version = '1.0') => ({ scope: 'plugin-skills', name, chars: 100, path: `/h/.claude/plugins/cache/himmel/${plugin}/${version}/skills/${name}/SKILL.md` });

test('expectedSkillNames: skills of the required plugin only, latest cached version only, by cache component', () => {
  const entries = [scanned('impeccable', 'impeccable'), scanned('impeccable', 'audit'), scanned('impeccable', 'old', '0.9'),
    scanned('other', 'x'), { ...scanned('other', 'impeccable'), path: '/h/.claude/plugins/cache/himmel/other/1.0/skills/impeccable/SKILL.md' }];
  assert.deepEqual([...expectedSkillNames(entries, ['impeccable@himmel'])].sort(), ['impeccable:audit', 'impeccable:impeccable']);
});

test('expectedSkillNames: the installed version wins over a newer cached one, even when it has zero skills; no installed set falls back to latest', () => {
  const entries = [scanned('impeccable', 'old-only', '0.9'), scanned('impeccable', 'new-only', '2.0')];
  assert.deepEqual([...expectedSkillNames(entries, ['impeccable@himmel'], new Map([['impeccable@himmel', new Set(['0.9'])]]))], ['impeccable:old-only']);
  // HIMMEL-4064: installed 9.9 has no SKILL.md, the session loads none; do not borrow another version's
  assert.deepEqual([...expectedSkillNames(entries, ['impeccable@himmel'], new Map([['impeccable@himmel', new Set(['9.9'])]]))], []);
  assert.deepEqual([...expectedSkillNames(entries, ['impeccable@himmel'], new Map())], ['impeccable:new-only']);
});

test('expectedSkillNames: a same-named plugin from another marketplace is not counted', () => {
  const entries = [scanned('impeccable', 'mine'), { ...scanned('impeccable', 'theirs'), path: '/h/.claude/plugins/cache/other-mkt/impeccable/1.0/skills/theirs/SKILL.md' }];
  assert.deepEqual([...expectedSkillNames(entries, ['impeccable@himmel'])], ['impeccable:mine']);
});

test('installedVersionsOf: reads installed_plugins.json, null when unreadable', () => {
  const dir = mkdtempSync(join(tmpdir(), 'inst-'));
  try {
    assert.equal(installedVersionsOf(dir), null);
    mkdirSync(join(dir, 'plugins'), { recursive: true });
    writeFileSync(join(dir, 'plugins', 'installed_plugins.json'), JSON.stringify({ plugins: { 'impeccable@himmel': [
      { scope: 'user', version: '1.0' },
      { scope: 'project', projectPath: '/work/here', version: '0.9' },
      { scope: 'project', projectPath: '/work/elsewhere', version: '0.5' },
    ] } }));
    for (const v of ['1.0', '0.9', '0.5']) mkdirSync(join(dir, 'plugins', 'cache', 'himmel', 'impeccable', v), { recursive: true });
    assert.deepEqual([...installedVersionsOf(dir, '/work/here').get('impeccable@himmel')].sort(), ['0.9', '1.0']);
    assert.deepEqual([...installedVersionsOf(dir, '/work/other').get('impeccable@himmel')], ['1.0']);
    // HIMMEL-4064: a version whose cache dir is ABSENT is not installed for our purposes (falls back)
    rmSync(join(dir, 'plugins', 'cache', 'himmel', 'impeccable', '0.9'), { recursive: true });
    assert.deepEqual([...installedVersionsOf(dir, '/work/here').get('impeccable@himmel')], ['1.0']);
    rmSync(join(dir, 'plugins', 'cache', 'himmel', 'impeccable', '1.0'), { recursive: true });
    assert.equal(installedVersionsOf(dir, '/work/other').has('impeccable@himmel'), false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('listingProblems: a required skill absent from a non-empty listing is flagged by name', () => {
  const p = listingProblems(CTX([FULL]), ['impeccable@himmel'], { expectedSkills: new Set(['impeccable:impeccable', 'impeccable:audit']) });
  assert.equal(p.length, 1);
  assert.match(p[0], /impeccable@himmel.*absent.*impeccable:audit/s);
});

test('listingProblems: every expected skill present passes', () => {
  assert.deepEqual(listingProblems(CTX([FULL]), ['impeccable@himmel'], { expectedSkills: new Set(['impeccable:impeccable']) }), []);
});

test('listingProblems: no context_usage is a problem when plugins are required', () => {
  assert.match(listingProblems(null, ['impeccable@himmel'])[0], /no context_usage/);
  assert.deepEqual(listingProblems(null, []), []);
});

test('listingReport: per-plugin measured tokens and name-only count', () => {
  assert.deepEqual(listingReport(CTX([NAME_ONLY, FULL, { ...FULL, plugin_name: 'x', name: 'x:y' }]), ['impeccable@himmel']),
    [{ plugin: 'impeccable', skills: 2, nameOnly: 1, tokens: 80 }]);
});

// HIMMEL-4038 feed: the listing budget that would let the required set keep
// descriptions (all other skills name-only), estimated from the uncapped scan.
test('requiredBudget: adds the uncapped description cost of name-only required skills to the current listing', () => {
  const ctx = { raw_max_tokens: 10000, skills: [NAME_ONLY, { name: 'other:x', plugin_name: 'other', tokens: 94 }] };
  const entries = [{ name: 'impeccable', chars: 400, path: '/h/.claude/plugins/cache/himmel/impeccable/1.0/skills/impeccable/SKILL.md' }];
  assert.deepEqual(requiredBudget(ctx, ['impeccable@himmel'], entries), { listingTokens: 100, extraTokens: 97, unmatched: 0, fraction: 0.02 });
});

test('requiredBudget: a name-only required skill missing from the scan is counted, not silently free', () => {
  assert.equal(requiredBudget({ raw_max_tokens: 1000, skills: [NAME_ONLY] }, ['impeccable@himmel'], []).unmatched, 1);
});

test('evaluateProfile: a null contextUsage (failed /context spawn) fails a profile with required plugins', () => {
  const { pass, problems } = evaluateProfile({
    enabledIds: ['impeccable@himmel'], requiredIds: ['impeccable@himmel'],
    initEvent: { ...LOADED, skills: ['impeccable:impeccable'] }, measuredTokens: 100, budget: 40000, contextUsage: null,
  });
  assert.equal(pass, false);
  assert.ok(problems.some((x) => /no context_usage/.test(x)));
});

test('requiredBudget: null when the window size is unknown; already-described skills add nothing', () => {
  assert.equal(requiredBudget({ skills: [NAME_ONLY] }, ['impeccable@himmel'], []), null);
  assert.equal(requiredBudget({ raw_max_tokens: 1000, skills: [FULL] }, ['impeccable@himmel'], []).extraTokens, 0);
});

// HIMMEL-4068: under strict:true Claude Code namespaces by the upstream plugin.json
// `name`, not the marketplace entry name (taste-skill-core -> taste-skill).
test('runtimeNamesOf: resolves the namespace from the installed plugin.json name, not the entry name', () => {
  const dir = mkdtempSync(join(tmpdir(), 'rtnames-'));
  try {
    const ip = join(dir, 'ip');
    mkdirSync(join(ip, '.claude-plugin'), { recursive: true });
    writeFileSync(join(ip, '.claude-plugin', 'plugin.json'), JSON.stringify({ name: 'taste-skill' }));
    mkdirSync(join(dir, 'plugins'), { recursive: true });
    writeFileSync(join(dir, 'plugins', 'installed_plugins.json'), JSON.stringify({ plugins: {
      'taste-skill-core@himmel': [{ scope: 'user', installPath: ip }],
      'plain@himmel': [{ scope: 'user', installPath: join(dir, 'none') }],
    } }));
    const names = runtimeNamesOf(dir);
    assert.equal(names.get('taste-skill-core@himmel'), 'taste-skill');
    assert.equal(names.has('plain@himmel'), false);
    assert.equal(runtimeNamesOf(join(dir, 'missing')).size, 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('manifest name != entry name: coverage, namespace extras and listing use the runtime name', () => {
  const names = new Map([['taste-skill-core@himmel', 'taste-skill']]);
  const init = { ...LOADED, skills: ['taste-skill:minimalist'] };
  assert.deepEqual(roleCoverageProblems(init, ['taste-skill-core@himmel'], names), []);
  assert.equal(roleCoverageProblems(init, ['taste-skill-core@himmel']).length, 1); // fails without the map
  assert.deepEqual(namespaceExtras(init, ['taste-skill-core@himmel'], names), []);
  assert.equal(namespaceExtras(init, ['taste-skill-core@himmel']).length, 1);
  const ctx = { raw_max_tokens: 1000, skills: [{ name: 'taste-skill:minimalist', plugin_name: 'taste-skill', tokens: 50 }] };
  assert.equal(listingReport(ctx, ['taste-skill-core@himmel'], names)[0].skills, 1);
  assert.deepEqual(listingProblems(ctx, ['taste-skill-core@himmel'], { names }), []);
});

// HIMMEL-4072: builtin / account-synced / skills-dir plugins are environment —
// a --settings profile cannot disable them — so they are reported, never failed.
const baseInit = findInitEvent(parseStreamJsonLines(SAMPLE));
const ENV_PLUGINS = [
  { name: 'cc-plugin-agents-md', source: 'cc-plugin-agents-md@builtin' },
  { name: 'cowork-plugin-management', source: 'cowork-plugin-management@synced' },
];
const SKILLS_DIR_PLUGIN = { name: 'obsidian-second-brain', source: 'obsidian-second-brain@skills-dir' };
const withEnv = () => ({
  ...baseInit,
  plugins: [...baseInit.plugins, ...ENV_PLUGINS],
  skills: [...baseInit.skills, 'anthropic-skills:docx', 'cowork-plugin-management:create-cowork-plugin'],
  slash_commands: [...baseInit.slash_commands, 'anthropic-skills:docx'],
});

test('evaluateProfile: @builtin/@synced plugins and their namespaces pass and are reported as environment', () => {
  const { pass, problems, environment } = evaluateProfile({ enabledIds: ENABLED, initEvent: withEnv(), measuredTokens: 35098, budget: 40000 });
  assert.deepEqual(problems, []);
  assert.equal(pass, true);
  for (const { source } of ENV_PLUGINS) assert.ok(environment.includes(source), `environment lists ${source}`);
});

test('evaluateProfile: an unrequested @himmel plugin still fails as bloat even beside environment plugins', () => {
  const init = withEnv();
  init.plugins = [...init.plugins, { name: 'stray', source: 'stray@himmel' }];
  const { pass, problems } = evaluateProfile({ enabledIds: ENABLED, initEvent: init, measuredTokens: 35098, budget: 40000 });
  assert.equal(pass, false);
  assert.ok(problems.some((p) => /extra plugin/.test(p) && p.includes('stray@himmel') && !p.includes('@synced')));
});

test('evaluateProfile: a namespace from a non-environment, non-enabled plugin still fails', () => {
  const init = withEnv();
  init.skills = [...init.skills, 'rogue:thing'];
  const { pass, problems } = evaluateProfile({ enabledIds: ENABLED, initEvent: init, measuredTokens: 35098, budget: 40000 });
  assert.equal(pass, false);
  assert.ok(problems.some((p) => p.includes('skill:rogue:thing')));
});

// HIMMEL-4018: a user-scope skill (~/.claude/skills) ignores enabledPlugins and
// loads in every session, so a profile cannot control it: the probe FAILS on one.
test('evaluateProfile: a @skills-dir plugin (user-scope skill) fails the profile', () => {
  const init = withEnv();
  init.plugins = [...init.plugins, SKILLS_DIR_PLUGIN];
  init.skills = [...init.skills, 'obsidian-second-brain:obsidian-save'];
  const { pass, problems } = evaluateProfile({ enabledIds: ENABLED, initEvent: init, measuredTokens: 35098, budget: 40000 });
  assert.equal(pass, false);
  assert.equal(problems.length, 1, problems.join('; '));
  assert.ok(/user-scope skill/.test(problems[0]) && problems[0].includes('obsidian-second-brain@skills-dir'));
});

test('evaluateProfile: a plugin-controlled obsidian-second-brain@himmel is not a user-scope skill', () => {
  const ids = [...ENABLED, 'obsidian-second-brain@himmel'];
  const init = withEnv();
  init.plugins = [...init.plugins, { name: 'obsidian-second-brain', source: 'obsidian-second-brain@himmel' }];
  init.skills = [...init.skills, 'obsidian-second-brain:obsidian-save'];
  const { pass, problems } = evaluateProfile({ enabledIds: ids, initEvent: init, measuredTokens: 35098, budget: 40000 });
  assert.deepEqual(problems, []);
  assert.equal(pass, true);
});

test('userScopeSkillDirs lists the skill dirs under <configDir>/skills, ignoring dotdirs and files; absent dir is empty', () => {
  const dir = mkdtempSync(join(tmpdir(), 'uss-'));
  try {
    assert.deepEqual(userScopeSkillDirs(dir), []);
    mkdirSync(join(dir, 'skills', 'find-docs'), { recursive: true });
    mkdirSync(join(dir, 'skills', 'graphify'), { recursive: true });
    mkdirSync(join(dir, 'skills', '.trash'), { recursive: true });
    mkdirSync(join(dir, 'skills', 'synced'), { recursive: true }); // Claude Code's account-sync cache, not a user skill
    writeFileSync(join(dir, 'skills', 'README.md'), 'x');
    assert.deepEqual(userScopeSkillDirs(dir), ['find-docs', 'graphify']);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('userScopeSkillDirs follows symlinks to skill dirs (manual links load too); a dangling link or a link to a file is ignored', () => {
  const dir = mkdtempSync(join(tmpdir(), 'uss-'));
  try {
    mkdirSync(join(dir, 'elsewhere', 'linked-skill'), { recursive: true });
    writeFileSync(join(dir, 'elsewhere', 'a-file'), 'x');
    mkdirSync(join(dir, 'skills'), { recursive: true });
    symlinkSync(join(dir, 'elsewhere', 'linked-skill'), join(dir, 'skills', 'linked-skill'));
    symlinkSync(join(dir, 'elsewhere', 'gone'), join(dir, 'skills', 'dangling'));
    symlinkSync(join(dir, 'elsewhere', 'a-file'), join(dir, 'skills', 'file-link'));
    assert.deepEqual(userScopeSkillDirs(dir), ['linked-skill']);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('userScopeSkillDirs propagates a non-ENOENT stat error on a symlinked skill dir instead of passing clean', { skip: process.getuid?.() === 0 }, () => {
  const dir = mkdtempSync(join(tmpdir(), 'uss-'));
  const locked = join(dir, 'locked');
  try {
    mkdirSync(join(locked, 'skill'), { recursive: true });
    mkdirSync(join(dir, 'skills'), { recursive: true });
    symlinkSync(join(locked, 'skill'), join(dir, 'skills', 'hidden-skill'));
    chmodSync(locked, 0o000);
    assert.throws(() => userScopeSkillDirs(dir), (e) => e.code === 'EACCES');
  } finally { chmodSync(locked, 0o755); rmSync(dir, { recursive: true, force: true }); }
});

test('evaluateProfile: user-scope skill dirs on disk fail the profile; none passes', () => {
  const base = { enabledIds: ENABLED, initEvent: withEnv(), measuredTokens: 35098, budget: 40000 };
  const bad = evaluateProfile({ ...base, userScopeDirs: ['find-docs', 'graphify'] });
  assert.equal(bad.pass, false);
  assert.ok(bad.problems.some((p) => /user-scope skill/.test(p) && p.includes('find-docs') && p.includes('graphify')));
  assert.equal(evaluateProfile({ ...base, userScopeDirs: [] }).pass, true);
});
