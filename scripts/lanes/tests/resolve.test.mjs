// scripts/lanes/tests/resolve.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { resolveLanes, formatCodexHealth, buildCtx } from '../resolve.mjs';

const REG = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'lanes.json'), 'utf8'));
const ctx = (o = {}) => ({ env: o.env ?? {}, pathHas: (c) => (o.paths ?? []).includes(c), installed: o.installed ?? {} });

test('bare machine (no keys, no optional CLIs) → only the 4 Claude tiers', () => {
  const ids = resolveLanes(REG, ctx()).map((l) => l.id);
  assert.deepEqual(ids, ['haiku', 'sonnet', 'opus', 'fable']);
});
test('GLM lane appears with ZAI_API_KEY set', () => {
  assert.ok(resolveLanes(REG, ctx({ env: { ZAI_API_KEY: 'k' } })).some((l) => l.id === 'glm'));
  assert.ok(!resolveLanes(REG, ctx()).some((l) => l.id === 'glm'));
});
test('glm-subagent lane (inline Agent-tool dispatch) keys off ZAI_API_KEY too', () => {
  assert.ok(resolveLanes(REG, ctx({ env: { ZAI_API_KEY: 'k' } })).some((l) => l.id === 'glm-subagent'));
  assert.ok(!resolveLanes(REG, ctx()).some((l) => l.id === 'glm-subagent'));
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
