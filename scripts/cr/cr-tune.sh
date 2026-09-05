#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes in node -e intentional (shell vars set via env)
# scripts/cr/cr-tune.sh — CR self-evolution ledger miner (HIMMEL-978)
# Mechanically mines the CR ledger for the signals the /cr-tune runbook turns
# into tuning proposals: per-model verdict stats, per-(model,severity)
# calibration flags, disproved clusters with row citations, and re-litigation
# (CR-round-marker) signals. READ-ONLY on the ledger; the judgment layer
# (taxonomy + proposals) lives in .claude/commands/cr-tune.md.
# Usage: cr-tune.sh [--window N] [--min-cite N] [--json]
# Reads CR_LEDGER (default: $(git rev-parse --git-common-dir)/cr-critic-scores.jsonl)
# Exit: 0 success (incl. empty ledger), 2 usage error.
set -uo pipefail

WINDOW=0      # last-N-heads window; 0 = all heads
MIN_CITE=3    # min disproved rows for a cluster / calibration flag
JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --window)   [ $# -ge 2 ] || { echo "cr-tune.sh: --window requires an argument" >&2; exit 2; }; case "$2" in ''|*[!0-9]*) echo "cr-tune.sh: --window requires a non-negative integer" >&2; exit 2;; esac; WINDOW="$2"; shift 2;;
    --min-cite) [ $# -ge 2 ] || { echo "cr-tune.sh: --min-cite requires an argument" >&2; exit 2; }; case "$2" in ''|*[!0-9]*) echo "cr-tune.sh: --min-cite requires a non-negative integer" >&2; exit 2;; esac; MIN_CITE="$2"; shift 2;;
    --json)     JSON=1; shift;;
    *) echo "cr-tune.sh: unknown option $1" >&2; exit 2;;
  esac
done

ledger="${CR_LEDGER:-$(git rev-parse --git-common-dir 2>/dev/null)/cr-critic-scores.jsonl}"
if [ ! -f "$ledger" ] || [ ! -s "$ledger" ]; then
  echo "no critic scores recorded yet (ledger: $ledger)"
  exit 0
fi

WINDOW="$WINDOW" MIN_CITE="$MIN_CITE" JSON="$JSON" LEDGER="$ledger" node -e '
const fs = require("fs");
const WINDOW_N  = Number(process.env.WINDOW);
const MIN_CITE  = Number(process.env.MIN_CITE);
const JSON_OUT  = process.env.JSON === "1";
const ledger    = process.env.LEDGER;

const records = [];
for (const l of fs.readFileSync(ledger, "utf8").split("\n").filter(Boolean)) {
  try { records.push(JSON.parse(l)); } catch (_) { /* skip malformed */ }
}

// Optional last-N-heads window (same computation as cr-scores.sh).
let recs = records;
if (WINDOW_N > 0) {
  const headTs = {};
  for (const r of records) {
    if (!r.head) continue;
    if (!headTs[r.head] || r.ts < headTs[r.head]) headTs[r.head] = r.ts;
  }
  const allHeads = Object.entries(headTs).sort((a,b)=>a[1]<b[1]?-1:1).map(e=>e[0]);
  const win = new Set(allHeads.slice(-WINDOW_N));
  recs = records.filter(r => !r.head || win.has(r.head));
}

const findings = recs.filter(r => r.kind === "finding");
const avails   = recs.filter(r => r.kind === "avail");

// ── per-model verdict stats ──
const VALID_VERDICTS = new Set(["agreed","disproved","conflict","unaddressed"]);
const models = {};
for (const f of findings) {
  const m = models[f.model] = models[f.model] || { model: f.model, n: 0, agreed: 0, disproved: 0, conflict: 0, unaddressed: 0, avail_ok: 0, avail_n: 0 };
  m.n++;
  if (VALID_VERDICTS.has(f.verdict)) m[f.verdict]++;
}
for (const a of avails) {
  const m = models[a.model] = models[a.model] || { model: a.model, n: 0, agreed: 0, disproved: 0, conflict: 0, unaddressed: 0, avail_ok: 0, avail_n: 0 };
  m.avail_n++;
  if (a.status === "ok") m.avail_ok++;
}
const modelRows = Object.values(models).sort((a,b)=>b.n-a.n);

// ── per-(model,severity) calibration flags ──
const calibMap = {};
for (const f of findings) {
  const k = f.model + " " + (f.severity || "?");
  const c = calibMap[k] = calibMap[k] || { model: f.model, severity: f.severity || "?", n: 0, disproved: 0 };
  c.n++;
  if (f.verdict === "disproved") c.disproved++;
}
const calibration = Object.values(calibMap)
  .filter(c => c.n >= MIN_CITE && c.disproved / c.n >= 0.8)
  .sort((a,b)=>b.disproved-a.disproved);

// ── disproved clusters by (model, path bucket) ──
const bucketOf = (file) => {
  const base = (file || "").split("/").pop() || "";
  if (/^test-|[-_.]test\./.test(base)) return "test-fixture";
  const segs = (file || "").split("/");
  return segs.slice(0, Math.min(2, Math.max(1, segs.length - 1))).join("/") || "(root)";
};
const clusterMap = {};
for (const f of findings) {
  if (f.verdict !== "disproved") continue;
  const k = f.model + " " + bucketOf(f.file);
  const c = clusterMap[k] = clusterMap[k] || { model: f.model, bucket: bucketOf(f.file), n: 0, citations: [] };
  c.n++;
  c.citations.push({ ts: f.ts, head: f.head, id: f.finding_id, file: f.file, line: f.line });
}
const clusters = Object.values(clusterMap).filter(c => c.n >= MIN_CITE).sort((a,b)=>b.n-a.n);

// ── re-litigation: round-marker finding_ids (…-r2-…, -r10-…) ──
const relitMap = {};
for (const f of findings) {
  if (!/-r(?:[2-9]|[1-9][0-9]+)-/.test(f.finding_id || "")) continue;
  const m = relitMap[f.model] = relitMap[f.model] || { model: f.model, n: 0, disproved: 0, citations: [] };
  m.n++;
  if (f.verdict === "disproved") m.disproved++;
  m.citations.push({ ts: f.ts, head: f.head, id: f.finding_id, file: f.file, line: f.line, verdict: f.verdict });
}
const relitigation = Object.values(relitMap).sort((a,b)=>b.n-a.n);

const out = { models: modelRows, calibration, clusters, relitigation };
if (JSON_OUT) { console.log(JSON.stringify(out, null, 2)); process.exit(0); }

const pct = (a,b) => b ? Math.round(100*a/b) + "%" : "-";
console.log("== per-model verdicts ==");
for (const m of modelRows) {
  console.log(`${m.model}: n=${m.n} agreed=${m.agreed} (${pct(m.agreed,m.n)}) disproved=${m.disproved} (${pct(m.disproved,m.n)}) conflict=${m.conflict} unaddressed=${m.unaddressed} avail=${m.avail_ok}/${m.avail_n} ok`);
}
console.log("");
console.log("== severity calibration flags (n>=" + MIN_CITE + ", disproved>=80%) ==");
if (!calibration.length) console.log("(none)");
for (const c of calibration) {
  console.log(`${c.model} ${c.severity}: ${c.disproved}/${c.n} disproved (${pct(c.disproved,c.n)})`);
}
console.log("");
console.log("== disproved clusters (n>=" + MIN_CITE + ") ==");
if (!clusters.length) console.log("(none)");
for (const c of clusters) {
  console.log(`${c.model} ${c.bucket}: ${c.n} disproved`);
  for (const t of c.citations) console.log(`  - ${t.ts} ${t.head} ${t.id} ${t.file}:${t.line}`);
}
console.log("");
console.log("== re-litigation signals (finding_id round markers -rN-) ==");
if (!relitigation.length) console.log("(none)");
for (const r of relitigation) {
  console.log(`${r.model}: ${r.n} round-marker findings, ${r.disproved} disproved`);
  for (const t of r.citations) console.log(`  - ${t.ts} ${t.head} ${t.id} ${t.file}:${t.line} ${t.verdict}`);
}
'
