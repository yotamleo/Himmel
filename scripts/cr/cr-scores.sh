#!/usr/bin/env bash
# scripts/cr/cr-scores.sh — per-critic agreed/availability scorecard (HIMMEL-415)
# Usage: cr-scores.sh [--window N] [--artifact kind] [--perspective on|off]
# Reads CR_LEDGER (default: $(git rev-parse --git-common-dir)/cr-critic-scores.jsonl)
# and prints a per-model table plus drop advice.
set -uo pipefail

# ── Named threshold constants (referenced by test-cr-scores.sh) ────────────
CR_SCORES_DROP_BELOW="${CR_SCORES_DROP_BELOW:-40}"
CR_SCORES_MIN_N="${CR_SCORES_MIN_N:-10}"
WINDOW=20
FILTER_ARTIFACT=""
FILTER_PERSPECTIVE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --window) [ $# -ge 2 ] || { echo "cr-scores.sh: --window requires an argument" >&2; exit 2; }; WINDOW="$2"; shift 2;;
    --artifact) [ $# -ge 2 ] || { echo "cr-scores.sh: --artifact requires an argument" >&2; exit 2; }; FILTER_ARTIFACT="$2"; shift 2;;
    --perspective) [ $# -ge 2 ] || { echo "cr-scores.sh: --perspective requires an argument" >&2; exit 2; }; FILTER_PERSPECTIVE="$2"; shift 2;;
    *) echo "cr-scores.sh: unknown option $1" >&2; exit 2;;
  esac
done

ledger="${CR_LEDGER:-$(git rev-parse --git-common-dir 2>/dev/null)/cr-critic-scores.jsonl}"

if [ ! -f "$ledger" ] || [ ! -s "$ledger" ]; then
  echo "no critic scores recorded yet (ledger: $ledger)"
  exit 0
fi

# shellcheck disable=SC2016  # $-refs below are inside the single-quoted node script (JS), not shell (HIMMEL-1176 surfaced this latent finding by extending the block)
DROP_BELOW="$CR_SCORES_DROP_BELOW" MIN_N="$CR_SCORES_MIN_N" WINDOW="$WINDOW" LEDGER="$ledger" FILTER_ARTIFACT="$FILTER_ARTIFACT" FILTER_PERSPECTIVE="$FILTER_PERSPECTIVE" node -e '
const fs = require("fs");
const DROP_BELOW = Number(process.env.DROP_BELOW);
const MIN_N      = Number(process.env.MIN_N);
const WINDOW_N   = Number(process.env.WINDOW);
const ledger     = process.env.LEDGER;
const filterArtifact    = process.env.FILTER_ARTIFACT || "";
const filterPerspective = process.env.FILTER_PERSPECTIVE || "";

const lines = fs.readFileSync(ledger, "utf8").split("\n").filter(Boolean);
if (!lines.length) { console.log("no critic scores recorded yet"); process.exit(0); }

const records = [];
for (const l of lines) {
  try { records.push(JSON.parse(l)); } catch (_) { /* skip malformed */ }
}
const filteredRecords = records.filter(r => {
  if (filterArtifact && (r.artifact || "diff") !== filterArtifact) return false;
  if (filterPerspective && (r.perspective || "off") !== filterPerspective) return false;
  return true;
});

// Collect all distinct heads sorted by earliest ts, to compute last-N window.
const headTs = {};
for (const r of filteredRecords) {
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
// usage: per-model ESTIMATED token tallies (HIMMEL-485). Separate from all/win
// so the finding/avail tables are untouched when no usage records exist.
const usage = {};
function emptyUsage() { return { est_prompt:0, est_completion:0, est_total:0, n:0 }; }
for (const r of filteredRecords) {
  if (!r.model) continue;
  const inWin = windowHeads.has(r.head);
  // Only finding/avail kinds seed the score tables. A model that appears ONLY in
  // usage records (e.g. a paid critic logged for cost) must NOT show as a phantom
  // zero row in the finding/avail tables — usage is tracked in its own map below.
  if (r.kind === "finding" || r.kind === "avail") {
    if (!all[r.model]) all[r.model] = emptyStats();
    if (!win[r.model]) win[r.model] = emptyStats();
  }
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
  } else if (r.kind === "usage") {
    if (!usage[r.model]) usage[r.model] = emptyUsage();
    usage[r.model].est_prompt     += Number(r.est_prompt_tokens)     || 0;
    usage[r.model].est_completion += Number(r.est_completion_tokens) || 0;
    usage[r.model].est_total      += Number(r.est_total_tokens)      || 0;
    usage[r.model].n++;
  }
}

function pct(n, d) { return d === 0 ? "n/a" : Math.round(n * 100 / d) + "%"; }

const models = Object.keys(all).sort();
const usageModels = Object.keys(usage).sort();
// Exit only when there is nothing of ANY kind to show. A ledger holding ONLY
// usage records (no finding/avail) must still render the usage section.
if (!models.length && !usageModels.length) { console.log("no critic scores recorded yet"); process.exit(0); }

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

// Score tables + drop advice only when there are finding/avail records. A
// usage-only ledger skips straight to the Usage section below.
if (models.length) {
  tableFor(all, "=== All-time ===");
  tableFor(win, "=== Last-" + WINDOW_N + "-PRs (window) ===");

  // ── Drop advice ──────────────────────────────────────────────────────────
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
}

// ── Usage (estimated tokens) ─────────────────────────────────────────────────
// chars/4 estimate (HIMMEL-485) — NOT a billed figure (hermes does not expose
// real usage through the one-shot chokepoint). Shown only when usage records
// exist so the finding/avail output is byte-identical without them.
if (usageModels.length) {
  const uCols = ["model","est_prompt","est_compl","est_total","records"];
  const UW    = [22,      11,          10,          11,         8];
  const uRow  = cells => cells.map((c,i)=>String(c).padEnd(UW[i])).join("  ");
  console.log("\n=== Usage (estimated tokens — chars/4, NOT billed) ===");
  console.log(uRow(uCols));
  console.log(uCols.map((_,i)=>"-".repeat(UW[i])).join("  "));
  let cumTotal = 0, cumN = 0;
  for (const m of usageModels) {
    const u = usage[m];
    console.log(uRow([m, u.est_prompt, u.est_completion, u.est_total, u.n]));
    cumTotal += u.est_total; cumN += u.n;
  }
  console.log("cumulative: est_total=" + cumTotal + " over " + cumN + " critic call(s)");
}

// ── Unavailability breakdown (HIMMEL-1176) ──────────────────────────────────
// Per-model x reason counts, from `avail` records carrying a `reason` field
// (only present when the emitting script recorded a failure classification —
// additive capture, HIMMEL-1176). Rendered ONLY when >=1 such record exists,
// so a reason-less ledger keeps BYTE-IDENTICAL output (same precedent as the
// Usage section above).
const reasonCounts = {}; // "model\treason" -> count
let hasReasons = false;
for (const r of filteredRecords) {
  if (r.kind === "avail" && r.model && r.reason) {
    hasReasons = true;
    const key = r.model + "\t" + r.reason;
    reasonCounts[key] = (reasonCounts[key] || 0) + 1;
  }
}
if (hasReasons) {
  const rCols = ["model","reason","count"];
  const RW    = [22,     16,      6];
  const rRow  = cells => cells.map((c,i)=>String(c).padEnd(RW[i])).join("  ");
  console.log("\n=== Unavailability breakdown ===");
  console.log(rRow(rCols));
  console.log(rCols.map((_,i)=>"-".repeat(RW[i])).join("  "));
  for (const key of Object.keys(reasonCounts).sort()) {
    const [m, reason] = key.split("\t");
    console.log(rRow([m, reason, reasonCounts[key]]));
  }
}
'
