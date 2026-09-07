#!/usr/bin/env node
// LUNA-131 Task 9c (acceptance 2 / D16). The owner of acceptance 2's
// statistic -- nothing else in the plan computes it. Correlates
// foreground-window-change timestamps (focus.jsonl, written by
// foreground-window-log.ps1) against the vault sweeper's tick_start times
// (sync.log, written by the sweeper Task 5 built) and prints a single
// PASS/FAIL verdict for whether the sweeper coincides with focus loss more
// than chance predicts over the soak.
//
// Usage:
//   node focus-tick-correlate.mjs <focus.jsonl> <sync.log> [--seed N]
//
// Method (frozen by the plan -- do not re-derive):
//   - Coincidence = a focus-change `ts` within +/-3s of a `tick_start`.
//   - Surrogates: 100 synthetic tick sets, each produced by shifting EVERY
//     real tick time by ONE SHARED uniform random offset in [0, 600)s --
//     this preserves the 10-minute structure. Ticks are never jittered
//     independently; that would destroy the null model the surrogate test
//     depends on.
//   - PASS = real_count <= the 95th percentile of the 100 surrogate counts.
//   - Prints exactly one line: {"real_count":N,"surrogate_p95":M,"verdict":"PASS|FAIL"}

import fs from 'node:fs';

const WINDOW_MS = 3000;
const SURROGATE_COUNT = 100;
const SHIFT_RANGE_MS = 600 * 1000;

function fail(message) {
  console.error(`ERROR: ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const positional = [];
  let seed = 42;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--seed') {
      const raw = argv[++i];
      const parsed = Number(raw);
      seed = Number.isFinite(parsed) ? parsed : 42;
    } else {
      positional.push(arg);
    }
  }
  return { focusPath: positional[0], syncLogPath: positional[1], seed };
}

function readLines(path, label) {
  let content;
  try {
    content = fs.readFileSync(path, 'utf8');
  } catch (err) {
    fail(`cannot read ${label} at ${path}: ${err.message}`);
  }
  return content.split(/\r?\n/).filter((line) => line.trim().length > 0);
}

// Both parsers skip unparseable lines rather than aborting -- a single corrupt
// record must not destroy a 3-day soak. But a SILENT skip would remove the only
// signal that the evidence log is systematically corrupt (e.g. a half-rotated
// sync.log, or a BOM-prefixed first record), and this artifact's whole job is to
// be trusted evidence for a ship/no-ship decision. So each parser reports how
// many lines it dropped, on STDERR -- stdout stays exactly one verdict line.
function reportSkips(label, skipped, total) {
  if (skipped > 0) {
    process.stderr.write(`WARN: skipped ${skipped} of ${total} unparseable ${label} line(s)\n`);
  }
}

function parseFocusTimestamps(lines) {
  const times = [];
  let skipped = 0;
  for (const line of lines) {
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      skipped++;
      continue; // malformed line -- skip, not fatal on its own
    }
    if (typeof obj.ts !== 'string') {
      skipped++;
      continue;
    }
    const ms = Date.parse(obj.ts);
    if (Number.isNaN(ms)) {
      skipped++;
      continue;
    }
    times.push(ms);
  }
  reportSkips('focus', skipped, lines.length);
  return times;
}

function parseTickStarts(lines) {
  const times = [];
  const re = /tick_start=(\S+)/;
  let skipped = 0;
  for (const line of lines) {
    const m = line.match(re);
    if (!m) {
      skipped++;
      continue;
    }
    const ms = Date.parse(m[1]);
    if (Number.isNaN(ms)) {
      skipped++;
      continue;
    }
    times.push(ms);
  }
  reportSkips('sync.log', skipped, lines.length);
  return times;
}

// Deterministic PRNG (mulberry32) so --seed reproduces the same surrogate
// distribution across runs (C4).
function mulberry32(seed) {
  let a = seed >>> 0;
  return function next() {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Counts how many `focus` timestamps have at least one `ticks` timestamp
// within +/-WINDOW_MS. `ticks` is sorted first so the scan can stop early.
function coincidenceCount(focus, ticks) {
  const sorted = [...ticks].sort((a, b) => a - b);
  let count = 0;
  for (const f of focus) {
    for (const t of sorted) {
      if (Math.abs(f - t) <= WINDOW_MS) {
        count++;
        break;
      }
      if (t > f + WINDOW_MS) break;
    }
  }
  return count;
}

function percentile95(sortedAscending) {
  const idx = Math.min(sortedAscending.length - 1, Math.ceil(0.95 * sortedAscending.length) - 1);
  return sortedAscending[idx];
}

function main() {
  const { focusPath, syncLogPath, seed } = parseArgs(process.argv.slice(2));
  if (!focusPath || !syncLogPath) {
    fail('usage: focus-tick-correlate.mjs <focus.jsonl> <sync.log> [--seed N]');
  }

  const focusLines = readLines(focusPath, 'focus log');
  const syncLines = readLines(syncLogPath, 'sync log');

  const focusTimes = parseFocusTimestamps(focusLines);
  const tickTimes = parseTickStarts(syncLines);

  if (focusTimes.length === 0) fail(`no valid focus-change timestamps found in ${focusPath}`);
  if (tickTimes.length === 0) fail(`no valid tick_start values found in ${syncLogPath}`);

  const realCount = coincidenceCount(focusTimes, tickTimes);

  // Surrogates: shift EVERY tick by ONE SHARED offset (never per-tick jitter --
  // that would destroy the 10-minute structure the null model depends on).
  // The shift is CIRCULAR within the tick series' own span: a plain `t + shift`
  // walks the late ticks past the end of the observation window, where there is
  // no focus data to coincide with, so those surrogates score artificially low,
  // depressing surrogate_p95 and biasing the verdict toward FAIL. Wrapping keeps
  // every surrogate the same size as the real measurement.
  const tickMin = Math.min(...tickTimes);
  const tickMax = Math.max(...tickTimes);
  const span = tickMax - tickMin + SHIFT_RANGE_MS; // +1 period: ticks are a lattice
  const rand = mulberry32(seed);
  const surrogateCounts = [];
  for (let i = 0; i < SURROGATE_COUNT; i++) {
    const shift = rand() * SHIFT_RANGE_MS;
    const shiftedTicks = tickTimes.map((t) => tickMin + (((t - tickMin + shift) % span) + span) % span);
    surrogateCounts.push(coincidenceCount(focusTimes, shiftedTicks));
  }
  surrogateCounts.sort((a, b) => a - b);
  const surrogateP95 = percentile95(surrogateCounts);

  const verdict = realCount <= surrogateP95 ? 'PASS' : 'FAIL';
  console.log(JSON.stringify({ real_count: realCount, surrogate_p95: surrogateP95, verdict }));
}

main();
