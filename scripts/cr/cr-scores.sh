#!/usr/bin/env bash
# scripts/cr/cr-scores.sh — per-critic agreed/availability scorecard (HIMMEL-415)
# Usage: cr-scores.sh [--window N]
# Reads CR_LEDGER (default: $(git rev-parse --git-common-dir)/cr-critic-scores.jsonl)
# and prints a per-model table plus drop advice.
set -uo pipefail

# ── Named threshold constants (referenced by test-cr-scores.sh) ────────────
CR_SCORES_DROP_BELOW="${CR_SCORES_DROP_BELOW:-40}"
CR_SCORES_MIN_N="${CR_SCORES_MIN_N:-10}"
WINDOW=20

while [ $# -gt 0 ]; do
  case "$1" in
    --window) [ $# -ge 2 ] || { echo "cr-scores.sh: --window requires an argument" >&2; exit 2; }; WINDOW="$2"; shift 2;;
    *) echo "cr-scores.sh: unknown option $1" >&2; exit 2;;
  esac
done

ledger="${CR_LEDGER:-$(git rev-parse --git-common-dir 2>/dev/null)/cr-critic-scores.jsonl}"

if [ ! -f "$ledger" ] || [ ! -s "$ledger" ]; then
  echo "no critic scores recorded yet (ledger: $ledger)"
  exit 0
fi

DROP_BELOW="$CR_SCORES_DROP_BELOW" MIN_N="$CR_SCORES_MIN_N" WINDOW="$WINDOW" LEDGER="$ledger" node -e '
const fs = require("fs");
const DROP_BELOW = Number(process.env.DROP_BELOW);
const MIN_N      = Number(process.env.MIN_N);
const WINDOW_N   = Number(process.env.WINDOW);
const ledger     = process.env.LEDGER;

const lines = fs.readFileSync(ledger, "utf8").split("\n").filter(Boolean);
if (!lines.length) { console.log("no critic scores recorded yet"); process.exit(0); }

const records = [];
for (const l of lines) {
  try { records.push(JSON.parse(l)); } catch (_) { /* skip malformed */ }
}

// Collect all distinct heads sorted by earliest ts, to compute last-N window.
const headTs = {};
for (const r of records) {
  if (!r.head) continue;
  if (!headTs[r.head] || r.ts < headTs[r.head]) headTs[r.head] = r.ts;
}
const allHeads = Object.entries(headTs).sort((a,b)=>a[1]<b[1]?-1:1).map(e=>e[0]);
const windowHeads = new Set(allHeads.slice(-WINDOW_N));

// Aggregate per model, all-time + windowed.
function emptyStats() {
  return { total:0, agreed:0, disproved:0, conflict:0, unaddressed:0, avail_ok:0, avail_total:0 };
}
const all = {}, win = {};
for (const r of records) {
  if (!r.model) continue;
  if (!all[r.model]) all[r.model] = emptyStats();
  if (!win[r.model]) win[r.model] = emptyStats();
  const inWin = windowHeads.has(r.head);
  if (r.kind === "finding") {
    all[r.model].total++;
    all[r.model][r.verdict] = (all[r.model][r.verdict] || 0) + 1;
    if (inWin) {
      win[r.model].total++;
      win[r.model][r.verdict] = (win[r.model][r.verdict] || 0) + 1;
    }
  } else if (r.kind === "avail") {
    all[r.model].avail_total++;
    if (r.status === "ok") all[r.model].avail_ok++;
    if (inWin) {
      win[r.model].avail_total++;
      if (r.status === "ok") win[r.model].avail_ok++;
    }
  }
}

function pct(n, d) { return d === 0 ? "n/a" : Math.round(n * 100 / d) + "%"; }

const models = Object.keys(all).sort();
if (!models.length) { console.log("no critic scores recorded yet"); process.exit(0); }

// ── Table ──────────────────────────────────────────────────────────────────
const cols = ["model","total","agreed%","dispr%","conflict","unadd","avail%"];
const W    = [22,     7,      8,        7,       9,        6,      7];
function row(cells) {
  return cells.map((c,i)=>String(c).padEnd(W[i])).join("  ");
}
const sep = cols.map((_,i)=>"-".repeat(W[i])).join("  ");

function tableFor(stats, label) {
  console.log("\n" + label);
  console.log(row(cols));
  console.log(sep);
  for (const m of models) {
    const s = stats[m] || emptyStats();
    console.log(row([
      m,
      s.total,
      pct(s.agreed || 0, s.total),
      pct(s.disproved || 0, s.total),
      s.conflict || 0,
      s.unaddressed || 0,
      pct(s.avail_ok, s.avail_total),
    ]));
  }
}

tableFor(all, "=== All-time ===");
tableFor(win, "=== Last-" + WINDOW_N + "-PRs (window) ===");

// ── Drop advice ────────────────────────────────────────────────────────────
const drops = [];
for (const m of models) {
  const s = all[m];
  const agreedPct = s.total > 0 ? (s.agreed || 0) * 100 / s.total : 100;
  if (s.total >= MIN_N && agreedPct < DROP_BELOW) {
    drops.push({ model: m, agreedPct: Math.round(agreedPct), total: s.total });
  }
}
if (drops.length) {
  console.log("\n=== Drop advice ===");
  console.log("(agreed% < " + DROP_BELOW + " over >= " + MIN_N + " findings)");
  for (const d of drops) {
    console.log("  consider dropping " + d.model + " (" + d.agreedPct + "% agreed over " + d.total + " findings)");
  }
} else {
  console.log("\n=== Drop advice ===");
  console.log("  no models below threshold");
}
'
