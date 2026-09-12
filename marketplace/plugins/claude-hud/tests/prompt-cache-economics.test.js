import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import { renderPromptCacheEconomicsLine } from '../dist/render/lines/prompt-cache-economics.js';
import { formatCacheTokens, getAllSessionsCacheEconomics } from '../dist/cache-economics.js';

function stripAnsi(str) {
  // eslint-disable-next-line no-control-regex
  return str.replace(/\x1b\[[0-9;]*m/g, '');
}

function baseContext() {
  return {
    stdin: { model: { display_name: 'Claude Sonnet 4.5' } },
    transcript: { tools: [], agents: [], todos: [] },
    claudeMdCount: 0,
    rulesCount: 0,
    mcpCount: 0,
    hooksCount: 0,
    sessionDuration: '',
    gitStatus: null,
    usageData: null,
    memoryUsage: null,
    config: {
      display: { showPromptCacheEconomics: true },
      colors: {},
    },
    extraLabel: null,
  };
}

function mkTmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'cache-econ-test-'));
}

// (a) gate off (default config) -> line is null.
test('renderPromptCacheEconomicsLine is hidden when the gate is off', () => {
  const ctx = baseContext();
  ctx.config.display.showPromptCacheEconomics = false;
  ctx.transcript.sessionTokens = {
    inputTokens: 10_000,
    outputTokens: 0,
    cacheCreationTokens: 200_000,
    cacheReadTokens: 1_000_000,
  };
  assert.equal(renderPromptCacheEconomicsLine(ctx), null);
});

// (b) gate on + known cache token totals -> session row matches a hand
// calculation for "Claude Sonnet 4.5" pricing (src/cost.ts MODEL_PRICING,
// "sonnet 4" row: input $3/MTok, output $15/MTok; cache read/write are not
// set explicitly on that entry, so cost.ts's own defaults apply:
// cacheRead = input * CACHE_READ_MULTIPLIER (0.1) = $0.30/MTok,
// cacheWrite = input * CACHE_WRITE_MULTIPLIER (1.25) = $3.75/MTok).
//
// read_savings_rate   = (3.00 - 0.30) / 1e6   = 0.0000027
// write_overhead_rate = (3.75 - 3.00) / 1e6   = 0.00000075
// reads = 1,000,000  writes = 200,000  inputs = 10,000
// net = 1,000,000 * 0.0000027 - 200,000 * 0.00000075
//     = 2.7 - 0.15 = 2.55  -> "+$2.5500"
// hit% = floor(1,000,000 * 100 / (10,000 + 1,000,000)) = floor(99.0099..) = 99
// r_fmt = formatCacheTokens(1_000_000) = "1.0M"; w_fmt = formatCacheTokens(200_000) = "200k"
// cost: native stdin.cost.total_cost_usd = 0.04 -> formatUsd(0.04) = "$0.0400"
test('renderPromptCacheEconomicsLine renders the session row from hand-computed values', () => {
  const ctx = baseContext();
  ctx.stdin.cost = { total_cost_usd: 0.04 };
  ctx.transcript.sessionTokens = {
    inputTokens: 10_000,
    outputTokens: 5_000,
    cacheCreationTokens: 200_000,
    cacheReadTokens: 1_000_000,
  };

  const line = stripAnsi(renderPromptCacheEconomicsLine(ctx) ?? '');
  const sessionRow = line.split('\n')[0];
  assert.equal(sessionRow, 'session r:1.0M w:200k hit:99% net +$2.5500  cost $0.0400');
});

// (c) format_tokens port, pinned against the legacy bash implementation via
// `bash -c 'source scripts/statusline/bin/statusline.sh; format_tokens N'`:
// 999 -> "999", 1000 -> "1k", 45321 -> "45k", 1234567 -> "1.2M".
test('formatCacheTokens matches the legacy bash format_tokens output', () => {
  assert.equal(formatCacheTokens(999), '999');
  assert.equal(formatCacheTokens(1000), '1k');
  assert.equal(formatCacheTokens(45321), '45k');
  assert.equal(formatCacheTokens(1_234_567), '1.2M');
});

// (d) the "all" row aggregates every historical transcript under
// ~/.claude/projects/**/*.jsonl, and a second call within the 30s window is
// served from the on-disk cache (a mutated fixture file must NOT change the
// result until the cache goes stale).
test('getAllSessionsCacheEconomics sums fixtures and caches for 30s', async () => {
  const home = mkTmpDir();
  const proj1 = path.join(home, '.claude', 'projects', 'proj1');
  const proj2 = path.join(home, '.claude', 'projects', 'proj2');
  fs.mkdirSync(proj1, { recursive: true });
  fs.mkdirSync(proj2, { recursive: true });

  const usageLine = (u) => JSON.stringify({ type: 'assistant', message: { usage: u } }) + '\n';

  const file1 = path.join(proj1, 'session1.jsonl');
  const file2 = path.join(proj2, 'session2.jsonl');
  fs.writeFileSync(file1, usageLine({
    input_tokens: 10, output_tokens: 5, cache_creation_input_tokens: 50, cache_read_input_tokens: 100,
  }));
  fs.writeFileSync(file2, usageLine({
    input_tokens: 20, output_tokens: 10, cache_creation_input_tokens: 150, cache_read_input_tokens: 200,
  }));

  let now = 1_000_000;
  const deps = { homeDir: () => home, now: () => now };

  const first = await getAllSessionsCacheEconomics(deps);
  assert.deepEqual(first, { reads: 300, writes: 200, inputs: 30 });

  const cachePath = path.join(home, '.claude', 'plugins', 'claude-hud', 'cache-economics-all.json');
  assert.equal(fs.existsSync(cachePath), true);

  // Mutate file1 to double its reads, then re-call within the 30s window.
  fs.writeFileSync(file1, usageLine({
    input_tokens: 10, output_tokens: 5, cache_creation_input_tokens: 50, cache_read_input_tokens: 999_999,
  }));
  now += 10_000; // +10s, still within the 30s TTL
  const second = await getAllSessionsCacheEconomics(deps);
  assert.deepEqual(second, first, 'a mutated fixture must not be re-read before the cache goes stale');

  // Advance past the TTL: the mutated file is now picked up.
  now += 25_000; // total +35s
  const third = await getAllSessionsCacheEconomics(deps);
  assert.equal(third.reads, 999_999 + 200);
});

// (e) a model with no pricing entry -> net and cost both render as an
// em dash placeholder, and rendering must not throw.
test('renderPromptCacheEconomicsLine falls back to a placeholder for unknown model pricing', () => {
  const ctx = baseContext();
  ctx.stdin.model = { display_name: 'some-unlisted-model' };
  ctx.transcript.sessionTokens = {
    inputTokens: 10_000,
    outputTokens: 0,
    cacheCreationTokens: 200_000,
    cacheReadTokens: 1_000_000,
  };

  let line;
  assert.doesNotThrow(() => {
    line = stripAnsi(renderPromptCacheEconomicsLine(ctx) ?? '');
  });
  const sessionRow = line.split('\n')[0];
  assert.match(sessionRow, /net —/);
  assert.match(sessionRow, /cost —/);
});
