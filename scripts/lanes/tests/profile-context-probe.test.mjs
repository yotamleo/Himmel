// scripts/lanes/tests/profile-context-probe.test.mjs
// HIMMEL-2189 — CI-safe companion to profile-context-probe.mjs. Exercises only
// the PURE functions it exports (parse/extract/evaluate/format) against a
// checked-in fixture derived from a real `claude --output-format stream-json`
// run (session ids/paths sanitized). NO live spawns here — the probe itself
// is excluded from the CI node --test glob because it bills real usage.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  parseStreamJsonLines, findInitEvent, findResultEvent, firstTurnTokens,
  pluginSourceDiff, namespaceExtras, evaluateProfile, formatNote,
  parseProbeArgs, resolveLedgerTarget, buildLedgerRow,
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
