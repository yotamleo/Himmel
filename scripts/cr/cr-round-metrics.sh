#!/usr/bin/env bash
# scripts/cr/cr-round-metrics.sh — review-round and repeat-finding baseline (HIMMEL-5059)
# Usage: cr-round-metrics.sh [--days N] [--now ISO-8601] [--known <known-findings.json>]
#                            [--groups <file of branch<TAB>group>]
# Reads CR_LEDGER (default: $(git rev-parse --git-common-dir)/cr-critic-scores.jsonl),
# read-only and repeatable. Prints one JSON line, then one `cr-round-metrics:` summary line.
#
# Same ledger semantics as cr-scores.sh: a finding row's verdict is empty until a later
# `amend` record sets it, so verdicts are amend-merged keyed on (target_head, finding_id,
# artifact, perspective). A "PR" is a ledger branch; its rounds are the highest `round`
# stamped on its finding rows (distinct heads when no row carries a round). The review
# cap is three rounds (review-round.sh), so a cap hit is a branch that reached round 4+.
# A finding is a REPEAT when its class already appeared on an earlier branch (by first
# finding ts, history before the window counts); a class repeating inside one branch is
# the fix-and-re-review loop and is not counted. known_findings.matched counts findings
# whose text matches a known-findings.json class `learning_match`: the list already names
# them, so a match is a finding the panel was told about and raised anyway.
#
# ponytail: classes come from the keyword table below, not a model, ceiling = text that
# names none of them lands in `other`; upgrade path = grow the table from by_class.other.
set -uo pipefail
# git-env-ok: the only git call is `rev-parse --git-common-dir` to locate the ledger; a caller's GIT_DIR is the intended repo
# Read-only report, not a gate: no anchor hand-off, it reads whatever copy it ships in.
case "${BASH_SOURCE[0]}" in */*) _ah_d="${BASH_SOURCE[0]%/*}" ;; *) _ah_d=. ;; esac

DAYS=30
NOW=""
KNOWN="$_ah_d/known-findings.json"
GROUPS_FILE=""
KNOWN_EXPLICIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --days) [ $# -ge 2 ] || { echo "cr-round-metrics.sh: --days requires an argument" >&2; exit 2; }; DAYS="$2"; shift 2;;
    --now) [ $# -ge 2 ] || { echo "cr-round-metrics.sh: --now requires an argument" >&2; exit 2; }; NOW="$2"; shift 2;;
    --groups) [ $# -ge 2 ] || { echo "cr-round-metrics.sh: --groups requires an argument" >&2; exit 2; }; GROUPS_FILE="$2"; shift 2;;
    --known) [ $# -ge 2 ] || { echo "cr-round-metrics.sh: --known requires an argument" >&2; exit 2; }; KNOWN="$2"; KNOWN_EXPLICIT=1; shift 2;;
    *) echo "cr-round-metrics.sh: unknown option $1" >&2; exit 2;;
  esac
done
case "$DAYS" in ''|*[!0-9]*) echo "cr-round-metrics.sh: --days must be a number" >&2; exit 2;; esac

if [ -n "${CR_LEDGER:-}" ]; then
  ledger="$CR_LEDGER"
elif gcd="$(git rev-parse --git-common-dir 2>/dev/null)" && [ -n "$gcd" ]; then
  ledger="$gcd/cr-critic-scores.jsonl"
else
  echo "cr-round-metrics.sh: not inside a git repo and CR_LEDGER is unset - no ledger to read" >&2; exit 2
fi

# shellcheck disable=SC2016  # $-refs below are inside the single-quoted node script (JS), not shell
LEDGER="$ledger" DAYS="$DAYS" NOW="$NOW" KNOWN="$KNOWN" KNOWN_EXPLICIT="$KNOWN_EXPLICIT" GROUPS_FILE="$GROUPS_FILE" node -e '
const fs = require("fs");
const e = process.env;
const now = e.NOW ? Date.parse(e.NOW) : Date.now();
if (!Number.isFinite(now)) { console.error("cr-round-metrics.sh: --now is not a valid timestamp"); process.exit(2); }
const since = now - Number(e.DAYS) * 86400000;
if (!Number.isFinite(since) || Number.isNaN(new Date(since).getTime())) { console.error("cr-round-metrics.sh: --days is out of range"); process.exit(2); }

// An empty ledger is a valid zero-result report; a missing or unreadable one is an error, never a zero.
let raw = "";
try { raw = fs.readFileSync(e.LEDGER, "utf8"); } catch (err) {
  console.error("cr-round-metrics.sh: cannot read ledger " + e.LEDGER + ": " + (err && err.code));
  process.exit(2);
}
const records = [];
let skippedLines = 0;
const lines = raw.split("\n").filter(Boolean);
for (const l of lines) {
  try { const r = JSON.parse(l); if (r && typeof r === "object") records.push(r); else skippedLines++; } catch (_) { skippedLines++; }
}
if (skippedLines > 0) console.error("cr-round-metrics.sh: skipped " + skippedLines + " of " + lines.length + " ledger lines (not JSON objects)");
if (lines.length > 0 && records.length === 0) {
  console.error("cr-round-metrics.sh: ledger " + e.LEDGER + " has " + lines.length + " lines and none is a record - refusing to report zero");
  process.exit(2);
}

// Keyword classes, first match wins. Order puts the specific shapes before the broad ones.
const CLASSES = [
  ["nul-delimited",       /\bNUL\b|null[- ]delimit|-print0|-z\b|xargs -0|\\0/i],
  ["rm-rf-cleanup",       /rm -rf|rm -fr|recursive(ly)? (delete|remov)|cleanup (of|on) |trap .*rm\b/i],
  ["vacuous-test",        /vacuous|cannot fail|can.?t fail|always passes|never fails|tautolog|assertion .*(no[- ]?op|pass(es)? (regardless|either))/i],
  ["fail-open",           /fail[- ]open|fails open|fail[- ]closed|fails closed|swallow(s|ed)? (the )?(error|failure)|on parse error|unparsable|malformed .* (allow|pass)/i],
  ["timeout",             /\btime-?outs?\b|\bhangs?\b|\bhung\b|unbounded (wait|loop|retry)|no (deadline|bound)/i],
  ["quoting-tokenization",/unquoted|quoting|quote[sd]? |word[- ]split|tokeni[sz]|glob(bing)?|\beval\b|shell[- ]inject|splits? on (space|whitespace)|IFS/i],
  ["portability",         /bash 3\.2|macos|bsd|\bgnu\b|busybox|portab|powershell|\.ps1|windows|crlf/i],
  ["docs-drift",          /\bdocs?\b.*(stale|out of date|drift|disagree)|stale (doc|comment|reference)|readme|comment (says|claims)/i],
  ["race-lock",           /\brace\b|toctou|concurren|\batomic(ally)?\b|\bflock\b|lock (contention|file race)/i],
];
function classify(text) {
  for (const [name, re] of CLASSES) if (re.test(text)) return name;
  return "other";
}

// The default known-findings file may be absent (matched stays 0); an explicit --known must load.
let knownRes = [];
try {
  const k = JSON.parse(fs.readFileSync(e.KNOWN, "utf8"));
  for (const c of (k.classes || [])) {
    if (!c.learning_match) continue;
    try { knownRes.push(new RegExp(c.learning_match, "i")); } catch (_) { /* skip a bad pattern */ }
  }
} catch (err) {
  if (e.KNOWN_EXPLICIT) { console.error("cr-round-metrics.sh: cannot load --known " + e.KNOWN + ": " + (err && err.code || "unparsable")); process.exit(2); }
}

// Amend-merged verdicts, same keying as cr-scores.sh.
const SEP = String.fromCharCode(31);
const amends = new Map();
for (const r of records) {
  if (r.kind !== "amend" || !r.set || typeof r.set !== "object") continue;
  const at = Date.parse(r.ts);
  if (Number.isFinite(at) && at > now) continue;   // an amend after --now is not yet known
  const k = [r.target_head, r.finding_id, r.artifact || "diff", r.perspective || "off"].join(SEP);
  amends.set(k, Object.assign({}, amends.get(k) || {}, r.set));
}

// Per-branch accumulation over ALL history (the repeat rate needs pre-window branches).
const branches = new Map();
for (const r of records) {
  if (r.kind !== "finding" || !r.branch) continue;
  const k = [r.head, r.finding_id, r.artifact || "diff", r.perspective || "off"].join(SEP);
  const eff = amends.has(k) ? Object.assign({}, r, amends.get(k)) : r;
  const ts = Date.parse(r.ts);
  if (!Number.isFinite(ts) || ts > now) continue;   // --now bounds every row, not just the first row of a branch
  let b = branches.get(r.branch);
  if (!b) { b = { name: r.branch, first: ts, heads: new Set(), maxRound: 0, rows: [] }; branches.set(r.branch, b); }
  if (ts < b.first) b.first = ts;
  b.heads.add(r.head);
  const round = /^[1-9][0-9]*$/.test(String(r.round)) ? Number(r.round) : 0;
  if (round > b.maxRound) b.maxRound = round;
  const sev = ({ critical: "crit", important: "imp", major: "imp", minor: "sug", suggestion: "sug" })[r.severity] || r.severity || "unknown";
  b.rows.push({ ts, round, sev, cls: classify(String(r.text || "")), verdict: (typeof eff.verdict === "string" && eff.verdict.trim()) || "none", text: String(r.text || "") });
}

const ordered = Array.from(branches.values()).sort((a, b) => a.first - b.first);
// class -> Map(branch -> earliest row ts of that class on it); a row is a repeat when ANOTHER
// branch raised the class strictly before this row (not merely started earlier).
const classBranchFirst = new Map();
for (const b of ordered) for (const row of b.rows) {
  let m = classBranchFirst.get(row.cls);
  if (!m) { m = new Map(); classBranchFirst.set(row.cls, m); }
  if (!(m.get(b.name) <= row.ts)) m.set(b.name, row.ts);
}
function raisedElsewhereBefore(cls, branch, ts) {
  for (const [name, first] of classBranchFirst.get(cls)) if (name !== branch && first < ts) return true;
  return false;
}
const inWindow = [];
const bySev = Object.create(null), byClass = Object.create(null), byVerdict = Object.create(null);
let total = 0, repeats = 0, knownHit = 0;
const classStats = Object.create(null);          // class -> {findings, roundsCaused: Set, repeats}
for (const b of ordered) {
  const win = b.first >= since && b.first <= now;
  if (win) inWindow.push(b);
  for (const row of b.rows) {
    if (win) {
      total++;
      bySev[row.sev] = (bySev[row.sev] || 0) + 1;
      byClass[row.cls] = (byClass[row.cls] || 0) + 1;
      byVerdict[row.verdict] = (byVerdict[row.verdict] || 0) + 1;
      const s = classStats[row.cls] || (classStats[row.cls] = { findings: 0, rounds: new Set(), repeats: 0 });
      s.findings++;
      if (row.round >= 2) s.rounds.add(b.name + "#" + row.round);
      if (row.cls !== "other" && raisedElsewhereBefore(row.cls, b.name, row.ts)) { repeats++; s.repeats++; b.repeats = (b.repeats || 0) + 1; }
      if (knownRes.some(re => re.test(row.text))) knownHit++;
    }
  }
}

function rounds(b) { return b.maxRound || b.heads.size; }
const vals = inWindow.map(rounds).sort((x, y) => x - y);
function pctile(p) { return vals.length ? vals[Math.max(0, Math.ceil(p * vals.length) - 1)] : 0; }
const capBranches = inWindow.filter(b => rounds(b) >= 4).map(b => b.name).sort();
const rate = (n, d) => d ? Math.round(n * 1000 / d) / 1000 : 0;

const top = Object.keys(classStats).filter(c => c !== "other").map(c => ({
  class: c, findings: classStats[c].findings, rounds_caused: classStats[c].rounds.size,
  repeats: classStats[c].repeats, score: classStats[c].findings * classStats[c].rounds.size,
})).sort((x, y) => y.score - x.score || y.findings - x.findings || (x.class < y.class ? -1 : 1));

// --groups <file>: lines of `branch<TAB>group` (a PR label or body marker resolved by the
// caller, e.g. from `gh pr list --state all --json headRefName,labels,body`), so gated and
// ungated PRs can be compared. A branch not listed falls in the group `ungrouped`.
let groups;
if (e.GROUPS_FILE) {
  const map = new Map();
  let gtxt;
  try { gtxt = fs.readFileSync(e.GROUPS_FILE, "utf8"); } catch (err) {
    console.error("cr-round-metrics.sh: cannot read --groups " + e.GROUPS_FILE + ": " + (err && err.code));
    process.exit(2);
  }
  for (const l of gtxt.split("\n")) {
    const i = l.indexOf("\t");
    if (i > 0) map.set(l.slice(0, i).trim(), l.slice(i + 1).trim());
  }
  const acc = Object.create(null);
  for (const b of inWindow) {
    const g = map.get(b.name) || "ungrouped";
    const a = acc[g] || (acc[g] = { rs: [], findings: 0, repeats: 0 });
    a.rs.push(rounds(b)); a.findings += b.rows.length; a.repeats += b.repeats || 0;
  }
  groups = Object.create(null);
  for (const g of Object.keys(acc).sort()) {
    const v = acc[g].rs.sort((x, y) => x - y);
    const p = q => v[Math.max(0, Math.ceil(q * v.length) - 1)];
    groups[g] = { branches: v.length, p50: p(0.5), p90: p(0.9), cap_hits: v.filter(r => r >= 4).length,
                  findings: acc[g].findings, repeat_rate: rate(acc[g].repeats, acc[g].findings) };
  }
}

const out = {
  window_days: Number(e.DAYS),
  ledger_lines_skipped: skippedLines,
  since: new Date(since).toISOString(),
  branches: inWindow.length,
  rounds: { p50: pctile(0.5), p90: pctile(0.9), max: vals.length ? vals[vals.length - 1] : 0},
  cap_hits: { count: capBranches.length, branches: capBranches },
  findings: { total, per_round: total && inWindow.length ? Math.round(total * 100 / inWindow.reduce((s, b) => s + rounds(b), 0)) / 100 : 0,
              by_severity: bySev, by_class: byClass, by_verdict: byVerdict },
  repeat: {
    vs_earlier_prs: { count: repeats, rate: rate(repeats, total) },
    known_findings: { matched: knownHit, rate: rate(knownHit, total) },
  },
  top_classes: top,
};
if (groups) out.groups = groups;
console.log(JSON.stringify(out));
console.log("cr-round-metrics: last " + e.DAYS + "d: " + out.branches + " PRs, rounds p50=" + out.rounds.p50 + " p90=" + out.rounds.p90
  + ", cap hits=" + out.cap_hits.count + ", " + total + " findings (crit " + (bySev.crit || 0) + " imp " + (bySev.imp || 0) + " sug " + (bySev.sug || 0)
  + "), repeat vs earlier PRs " + Math.round(out.repeat.vs_earlier_prs.rate * 100) + "%, known-findings re-raised " + knownHit
  + ", top class " + (top[0] ? top[0].class : "none"));
'
