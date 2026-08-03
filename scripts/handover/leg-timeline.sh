#!/usr/bin/env bash
# scripts/handover/leg-timeline.sh — HIMMEL-1485
#
# Reconstruct a per-leg critical-path timeline from data that already exists:
#   - worker dispatches : ~/.claude/handover/bridge/{glm,claudex}-sessions/*/meta.json
#                         (started_at = dispatch; meta.json mtime = exit/land stamp,
#                          since NO meta.json carries an explicit end timestamp —
#                          verified across every session; the file's mtime is the
#                          instant status flipped to a terminal value).
#   - gate renders      : <primary-checkout>/.git/cr-critic-scores.jsonl
#                         (CR ledger; avail/finding rows carry ts + head + model).
#   - chain-ledger stamps: the operator's luna chain-ledger markdown (some lines
#                          carry an ISO timestamp + an event tag).
#
# All three sources are READ-ONLY. This script never writes any of them.
#
# Usage:
#   scripts/handover/leg-timeline.sh <since-ts>
#     <since-ts>  ISO-8601 lower bound. UTC is assumed when no offset is given,
#                 so '2026-08-03T00:00' == '2026-08-03T00:00Z'. Events at or after
#                 this instant are shown.
#
# Output:
#   - A table, one row per event sorted by ts: ts · source · leg/branch · event ·
#     delta-from-previous.
#   - A summary block: total span, per-worker dispatch→land, gate-wait vs
#     gate-run where derivable, and a one-line wall-clock summary
#     (total leg time + % waiting).
#
# Source paths are env-overridable (see test-leg-timeline.sh):
#   LEG_TIMELINE_WORKER_GLM, LEG_TIMELINE_WORKER_CLAUDEX,
#   LEG_TIMELINE_CR_LEDGER, LEG_TIMELINE_CHAIN_LEDGER.
#
# Tooling: jq (JSONL field extraction) + node. node is the ONLY portable
# ISO-8601-with-offset / sub-second / file-mtime reader across Git Bash (GNU
# date) and macOS bash 3.2 (BSD date): `date -d` is GNU-only, `date -r` means
# different things on GNU vs BSD, `stat -c/-f` flags differ, and jq's fromdate
# rejects `+0200` offsets and sub-seconds. node is a hard repo dependency
# (the Jira CLI, lanes, etc.), so leaning on it costs no new assumption.
#
# bash 3.2-safe (macOS ships 3.2): no mapfile, no associative arrays.
set -uo pipefail

# ---------------------------------------------------------------------------
# Defaults. $HOME is MSYS form (/c/Users/...) under Git Bash; the node helpers
# normalize MSYS paths to Windows form because Node's fs rejects '/c/...'.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/load-dotenv.sh"
# shellcheck source=../lib/user-slug.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/user-slug.sh"
# shellcheck source=../lib/handover-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/handover-path.sh"
load_dotenv HANDOVER_DIR USER_SLUG

glm_dir="${LEG_TIMELINE_WORKER_GLM:-$HOME/.claude/handover/bridge/glm-sessions}"
claudex_dir="${LEG_TIMELINE_WORKER_CLAUDEX:-$HOME/.claude/handover/bridge/claudex-sessions}"
if [ -n "${LEG_TIMELINE_CHAIN_LEDGER:-}" ]; then
  chain_ledger="$LEG_TIMELINE_CHAIN_LEDGER"
elif handover_base=$(handover_root 2>/dev/null) && handover_slug=$(user_slug 2>/dev/null); then
  chain_ledger="$handover_base/$handover_slug/himmel/specs/plan/2026-07-28-chain-ledger.md"
else
  chain_ledger=""
fi

# The CR ledger lives under the PRIMARY checkout's .git, not the worktree's
# (worktrees share the primary's .git via the common dir). An explicit env value
# always wins.
if [ -z "${LEG_TIMELINE_CR_LEDGER:-}" ]; then
  common_dir=$(git rev-parse --git-common-dir 2>/dev/null || printf '.git')
  # Treat both POSIX-absolute (/c/...) and Windows-drive-absolute (C:/...) as
  # already absolute; git-common-dir returns the latter under Git for Windows.
  case "$common_dir" in
    /* | [A-Za-z]:/*) : ;;
    *) common_dir="$PWD/$common_dir" ;;
  esac
  cr_ledger="$common_dir/cr-critic-scores.jsonl"
else
  cr_ledger="$LEG_TIMELINE_CR_LEDGER"
fi

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<EOF
Usage: $0 <since-ts>

Reconstruct a per-leg critical-path timeline (HIMMEL-1485).
  <since-ts>  ISO-8601 lower bound (UTC assumed when no offset), e.g.
              '2026-08-03T00:00'.

Env overrides: LEG_TIMELINE_WORKER_GLM, LEG_TIMELINE_WORKER_CLAUDEX,
               LEG_TIMELINE_CR_LEDGER, LEG_TIMELINE_CHAIN_LEDGER.
EOF
}

if [ "$#" -ne 1 ]; then
  usage
  exit 1
fi
since_raw="$1"

# ---------------------------------------------------------------------------
# since-epoch: parse the lower bound once. Date-only input means UTC midnight;
# append 'Z' to offset-less date-times so V8 does not read them as local time
# (measured 4h off on an EDT host). Empty result => unparseable since-ts.
# ---------------------------------------------------------------------------
since_epoch=$(printf '%s' "$since_raw" | node -e '
  const s = require("fs").readFileSync(0, "utf8").trim();
  const dateOnly = /^\d{4}-\d{2}-\d{2}$/.test(s);
  const hasOffset = /[Zz]$|[+-]\d{2}:?\d{2}$/.test(s);
  const normalized = dateOnly ? s + "T00:00:00Z" : (hasOffset ? s : s + "Z");
  const ms = Date.parse(normalized);
  process.stdout.write(Number.isNaN(ms) ? "" : String(ms));
')
if [ -z "$since_epoch" ]; then
  printf 'ERROR: could not parse since-ts [%s] as ISO-8601.\n' "$since_raw" >&2
  usage
  exit 1
fi

# Validate mktemp before using $tmp: `set` has no -e, so a failed mktemp -d
# would leave $tmp empty (or a non-dir) and execution would continue into
# "/raw.tsv". Fail loudly, and arm the cleanup trap only once $tmp is real.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/leg-timeline.XXXXXX") || tmp=""
if [ -z "$tmp" ] || [ ! -d "$tmp" ]; then
  printf 'ERROR: mktemp -d failed (no temp dir created); aborting.\n' >&2
  exit 1
fi
trap 'rm -rf "$tmp"' EXIT
raw="$tmp/raw.tsv"          # all events, col1 = ISO ts (unsorted, unfiltered)
allnorm="$tmp/allnorm.tsv"  # normalized ALL events (unfiltered) for summary pairing
events="$tmp/events.tsv"    # normalized + since-filtered: the displayed table rows

# ---------------------------------------------------------------------------
# Collect raw events into $raw. Col layout: <iso-ts>\t<source>\t<leg>\t<event>.
# Each source degrades gracefully: a missing/unreadable path is reported and
# skipped, never fatal.
# ---------------------------------------------------------------------------
: > "$raw"

# --- source 1: worker dispatches (node; needs meta.json parse + file mtime) ---
# Emits a dispatch row per session (started_at) and, for terminal statuses, a
# land row whose ts is the meta.json mtime (the status-flip instant). Paths are
# MSYS-normalized because Git Bash hands node '/c/...' which Node fs rejects.
gather_workers() {
  node -e '
    const fs = require("fs");
    // win(): coerce any path form Git Bash may hand us into forward-slash Windows
    // form, the one Node fs reliably accepts on Windows: MSYS '/c/...' -> 'C:/...',
    // backslashes -> forward slashes, already-Windows passes through. Node fs
    // rejects MSYS paths outright, so this normalization is load-bearing.
    function win(p){
      let q = p.replace(/\\/g, "/");
      const m = q.match(/^\/([a-zA-Z])\/(.*)$/);
      return m ? (m[1].toUpperCase() + ":/" + m[2]) : q;
    }
    // "blocked" is a real terminal status (content-filter) emitted by
    // spawn-glm.ts finalMeta alongside done/timeout/failed/capped; without it a
    // blocked session never gets a land row. "aborted" is NOT a finalMeta status.
    const TERM = new Set(["done","timeout","failed","capped","blocked"]);
    const dirs = process.argv.slice(1).map(win);
    for (const d of dirs){
      let names = [];
      try { names = fs.readdirSync(d); } catch (e) { continue; }   // missing dir -> skip
      for (const n of names){
        const p = d.replace(/\/$/, "") + "/" + n + "/meta.json";
        let j;
        try { j = JSON.parse(fs.readFileSync(p, "utf8")); } catch (e) { continue; }  // bad json -> skip
        if (!j.started_at) continue;
        const leg = j.shared_branch || j.task_name || n;
        const lane = j.lane || "?";
        const st = j.status || "?";
        process.stdout.write(j.started_at + "\tworker\t" + leg + "\tdispatch " + lane + " " + st + "\t" + n + "\n");
        if (TERM.has(st)){
          let iso;
          try { iso = fs.statSync(p).mtime.toISOString(); } catch (e) { iso = ""; }
          if (iso){
            const rc = ("exit_code" in j) ? (" rc=" + j.exit_code) : "";
            process.stdout.write(iso + "\tworker\t" + leg + "\tland " + st + rc + "\t" + n + "\n");
          }
        }
      }
    }
  ' -- "$glm_dir" "$claudex_dir"
}

# --- source 2: gate renders (jq over the CR ledger JSONL) ---
# One row per ledger record that carries a ts. leg/branch = branch@head; event
# encodes kind + model (+ severity for findings) so the table is self-describing.
gather_gate() {
  [ -f "$cr_ledger" ] || return 0
  jq -Rr '
    fromjson? |
    select(type == "object" and .ts) |
    "\(.ts)\tgate\t\((.branch//"chain") + "@" + ((.head//"-")[0:7]))\t" +
    ( if .kind == "avail"   then "avail "   + (.model//"")
      elif .kind == "finding" then "finding " + (.model//"") + " " + (.severity//"")
      elif .kind == "usage"  then "usage "   + (.model//"")
      else                             (.kind//"?") + " " + (.model//"") end ) + "\t-"
  ' "$cr_ledger" 2>/dev/null
}

# --- source 3: chain-ledger stamps (node; binary-tolerant, regex extraction) ---
# The ledger is append-only markdown with non-UTF8 bytes; read as a buffer.
# Only lines carrying an ISO timestamp become events; the event is the text
# before the timestamp (the tag), whitespace-collapsed and capped.
gather_ledger() {
  [ -f "$chain_ledger" ] || return 0
  node -e '
    const fs = require("fs");
    function win(p){
      let q = p.replace(/\\/g, "/");
      const m = q.match(/^\/([a-zA-Z])\/(.*)$/);
      return m ? (m[1].toUpperCase() + ":/" + m[2]) : q;
    }
    const p = win(process.argv[1]);
    let buf;
    try { buf = fs.readFileSync(p); } catch (e) { process.exit(0); }   // missing -> skip
    const text = buf.toString("utf8");                 // bad bytes -> replacement chars, ignored
    // optional fractional seconds then an optional offset; without the
    // (?:\.\d+)? clause a stamp like T13:40:00.5+02:00 captures truncated
    // before ".5+02:00", silently stripping the offset (HIMMEL-1485 r7).
    const RE = /(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)/;
    for (const line of text.split(/\r?\n/)){
      const m = line.match(RE);
      if (!m) continue;
      let prefix = line.slice(0, m.index).trim().replace(/\s+/g, " ");
      if (prefix.length > 40) prefix = prefix.slice(0, 37) + "...";
      process.stdout.write(m[1] + "\tledger\tchain\t" + prefix + "\t-\n");
    }
  ' "$chain_ledger"
}

# Track which sources contributed (for the summary's gap report).
w_glm=0; w_claudex=0; w_gate=0; w_ledger=0; w_gate_malformed=0
[ -d "$glm_dir" ]     && w_glm=1
[ -d "$claudex_dir" ] && w_claudex=1
[ -f "$cr_ledger" ]   && w_gate=1
[ -f "$chain_ledger" ] && w_ledger=1

{ gather_workers; gather_gate; gather_ledger; } >> "$raw" 2>/dev/null
if [ "$w_gate" -eq 1 ]; then
  w_gate_malformed=$(jq -Rn '
    reduce inputs as $line (0;
      if $line == "" then .
      else (try ($line | fromjson) catch null) as $row |
        if $row == null or ($row | type) != "object" then . + 1 else . end
      end)
  ' "$cr_ledger" 2>/dev/null) || w_gate_malformed=0
fi

# ---------------------------------------------------------------------------
# Normalize ALL events -> $allnorm (UNFILTERED): parse col1 ISO ts -> epoch ms,
# drop rows that fail to parse, re-emit as epoch \t source \t leg \t event \t
# session-id \t iso(seconds). Sorted numerically by epoch ascending. The since-ts
# filter is applied separately (next block) to the DISPLAYED table rows only, so
# the summary pairing below still sees dispatches that predate the window but
# land inside it (HIMMEL-1485 r5 #1). One node pass over the whole file.
# A trailing lowercase "z" is a valid offset designator (V8 accepts it; since_ts
# does too): recognize z/Z case-insensitively so it is not re-suffixed into an
# invalid "zZ" that Date.parse drops (HIMMEL-1485 r5 #2).
# ---------------------------------------------------------------------------
node -e '
  const fs = require("fs");
  const rows = [];
  for (const line of fs.readFileSync(0, "utf8").split(/\r?\n/)){
    if (line === "") continue;
    const c = line.split("\t");
    if (c.length < 5) continue;
    // Offset-less stamps parse as HOST-local while since_epoch normalizes
    // offset-less input to UTC — append Z so filtering and output agree. A
    // trailing z/Z (case-insensitive) or numeric offset is an existing designator.
    const ts = /[Zz]$|[+-]\d\d:?\d\d$/.test(c[0]) ? c[0] : c[0] + "Z";
    const ms = Date.parse(ts);
    if (Number.isNaN(ms)) continue;
    const iso = new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
    rows.push([ms, c[1], c[2], c[3], c[4], iso]);
  }
  rows.sort((a, b) => (a[0] - b[0]) || (a[1] < b[1] ? -1 : (a[1] > b[1] ? 1 : 0)));
  for (const r of rows) process.stdout.write(r.join("\t") + "\n");
' < "$raw" > "$allnorm"

# Displayed table rows: events at/after since-ts only. $events is the table's
# display contract (unchanged); the summary pairs over the unfiltered $allnorm.
node -e '
  const since = parseInt(process.argv[1], 10);   // epoch ms or NaN
  for (const line of require("fs").readFileSync(0, "utf8").split(/\r?\n/)){
    if (line === "") continue;
    const ep = Number(line.split("\t")[0]);
    if (Number.isNaN(since) || ep >= since) process.stdout.write(line + "\n");
  }
' "$since_epoch" < "$allnorm" > "$events"

# ---------------------------------------------------------------------------
# Helpers for the table + summary.
# ---------------------------------------------------------------------------

# fmtdur <ms> -> "+1h02m" / "+3m04s" / "+12s" / "+0s" (never negative in table).
fmtdur() {
  local ms=${1:-0}
  [ "$ms" -lt 0 ] && ms=0
  local s=$(( ms / 1000 ))
  local h=$(( s / 3600 ))
  local m=$(( (s % 3600) / 60 ))
  local sec=$(( s % 60 ))
  if [ "$h" -gt 0 ]; then printf '+%dh%02dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '+%dm%02ds' "$m" "$sec"
  else printf '+%ds' "$sec"; fi
}

# compacts an ISO 'YYYY-MM-DDTHH:MM:SSZ' to 'MM-DD HH:MM:SS' for the table.
compact_ts() { printf '%s' "${1#????-}" | sed 's/T/ /; s/Z$//'; }

# truncate a field to width, adding an ellipsis.
trunc() { local s="$1" w="${2:-28}"; local n=${#s}; if [ "$n" -gt "$w" ]; then printf '%s' "${s:0:$((w-1))}…"; else printf '%s' "$s"; fi; }

# ---------------------------------------------------------------------------
# Table.
# ---------------------------------------------------------------------------
event_count=$(wc -l < "$events" | tr -d ' ')

echo
echo "=== Leg timeline (since $(node -e 'process.stdout.write(new Date(Number(process.argv[1])).toISOString())' "$since_epoch")) ==="
echo "events: $event_count"
echo
if [ "$event_count" -gt 0 ]; then
  printf '%-15s  %-6s  %-28s  %-9s  %s\n' "TS(UTC)" "SOURCE" "LEG/BRANCH" "DELTA" "EVENT"
  printf '%-15s  %-6s  %-28s  %-9s  %s\n' "-------" "------" "----------" "-----" "-----"
  prev=""
  while IFS=$'\t' read -r ep src leg ev _ ts; do
    if [ -z "$prev" ]; then delta="-"; else delta=$(fmtdur $(( ep - prev ))); fi
    printf '%-15s  %-6s  %-28s  %-9s  %s\n' "$(compact_ts "$ts")" "$src" "$(trunc "$leg" 28)" "$delta" "$(trunc "$ev" 60)"
    prev="$ep"
  done < "$events"
else
  echo "(no events in window)"
fi

# ---------------------------------------------------------------------------
# Summary block. Computed in one node pass over $events (it does the pairing
# and interval-union arithmetic that bash 3.2 cannot do without awk).
# ---------------------------------------------------------------------------
echo
echo "=== Summary ==="

# Source-gap report: which configured sources were missing.
gap=""
[ "$w_glm" -eq 0 ]     && gap="${gap}  - worker(glm) dir missing: $glm_dir"$'\n'
[ "$w_claudex" -eq 0 ] && gap="${gap}  - worker(claudex) dir missing: $claudex_dir"$'\n'
[ "$w_gate" -eq 0 ]    && gap="${gap}  - CR ledger missing: $cr_ledger"$'\n'
[ "$w_gate_malformed" -gt 0 ] && gap="${gap}  - CR ledger malformed rows skipped: $w_gate_malformed"$'\n'
if [ "$w_ledger" -eq 0 ]; then
  if [ -n "$chain_ledger" ]; then
    gap="${gap}  - chain ledger missing: $chain_ledger"$'\n'
  else
    gap="${gap}  - chain ledger unresolved via handover_root"$'\n'
  fi
fi
if [ -n "$gap" ]; then
  echo "sources:"
  printf '%s' "$gap"
fi

# SC2016: the single-quoted JS body uses template literals (${...}); bash must
# NOT expand them — node receives them verbatim. Intentional, hence disabled.
# shellcheck disable=SC2016
node -e '
  const fs = require("fs");
  const since = parseInt(process.argv[1], 10);   // epoch ms (window lower bound)
  const inWin = (ms) => Number.isNaN(since) || ms >= since;
  // branch name = label with the appended "@<head>" suffix stripped. Split on
  // the LAST '@' (the head is the trailing hex token) so a branch name that
  // itself contains '@' is not truncated (HIMMEL-1485 r7).
  const branch = (leg) => { const i = leg.lastIndexOf("@"); return i < 0 ? leg : leg.slice(0, i); };
  const rows = [];
  for (const line of fs.readFileSync(0, "utf8").split(/\r?\n/)){
    if (line === "") continue;
    const c = line.split("\t");
    if (c.length < 6) continue;
    rows.push({ ms: Number(c[0]), src: c[1], leg: c[2], ev: c[3], session: c[4], iso: c[5] });
  }
  const fmt = (ms) => {
    let s = Math.floor(ms/1000), neg = s < 0; if (neg) s = -s;
    const h = Math.floor(s/3600), m = Math.floor((s%3600)/60), sec = s%60;
    let out = h>0 ? `${h}h${String(m).padStart(2,"0")}m` : (m>0 ? `${m}m${String(sec).padStart(2,"0")}s` : `${sec}s`);
    return (neg?"-":"") + out;
  };
  // Window bounds come from IN-WINDOW rows (the displayed table). Pairing reads
  // the unfiltered set so a pre-window dispatch that lands in-window is no longer
  // dropped (HIMMEL-1485 r5 #1).
  const win = rows.filter(r => inWin(r.ms));
  if (win.length === 0){ process.stdout.write("(no events — nothing to summarize)\n"); process.exit(0); }

  const min = win[0].ms, max = win[win.length-1].ms;
  const span = max - min;

  // Per-worker dispatch→land: pair by bridge session, never by shared branch.
  const sessions = new Map();   // session -> { leg, disp:{ms,ev}, land:{ms,ev} }
  for (const r of rows){
    if (r.src !== "worker") continue;
    const isDisp = r.ev.startsWith("dispatch");
    const isLand = r.ev.startsWith("land");
    if (!isDisp && !isLand) continue;
    if (!sessions.has(r.session)) sessions.set(r.session, { leg: r.leg });
    const o = sessions.get(r.session);
    if (isDisp && !o.disp) o.disp = r;
    if (isLand) o.land = r;
  }

  // Worker busy UNION (merge overlapping dispatch→land intervals) for % waiting.
  // A pair contributes only when it LANDS in-window; its interval is clamped to
  // the window so a pre-window dispatch counts only its in-window busy time.
  const iv = [];
  for (const o of sessions.values()){
    if (!(o.disp && o.land && inWin(o.land.ms))) continue;
    const a = Math.max(Math.min(o.disp.ms, o.land.ms), since);
    const b = Math.min(Math.max(o.disp.ms, o.land.ms), max);
    if (b >= a) iv.push([a, b]);
  }
  iv.sort((x,y) => x[0]-y[0]);
  let union = 0;
  if (iv.length){
    let [lo, hi] = iv[0];
    for (let i = 1; i < iv.length; i++){
      const [a, b] = iv[i];
      if (a <= hi) hi = Math.max(hi, b);
      else { union += hi - lo; lo = a; hi = b; }
    }
    union += hi - lo;
  }

  // Per-branch gate run (last-first ts) + gate wait (first gate - dispatch of
  // the same leg, when a worker dispatched that branch).
  const gate = new Map();   // branch -> [firstMs, lastMs]
  for (const r of rows){
    if (r.src !== "gate" || !inWin(r.ms)) continue;
    const br = branch(r.leg);
    if (!gate.has(br)) gate.set(br, [r.ms, r.ms]);
    else { const g = gate.get(br); g[0] = Math.min(g[0], r.ms); g[1] = Math.max(g[1], r.ms); }
  }

  // total span (event count = in-window rows, matching the displayed table)
  process.stdout.write(`total span: ${fmt(span)}  (${win.length} events, ${min}..${max})\n`);

  // per-worker dispatch->land. A session is shown when it lands in-window (its
  // dispatch may predate the window — marked "dispatched pre-window") or was
  // dispatched in-window and has not landed yet (still running).
  process.stdout.write("\nworker dispatch→land:\n");
  let anyWorker = false;
  for (const [session, o] of sessions){
    if (!o.disp) continue;
    const landInWin = o.land && inWin(o.land.ms);
    if (!landInWin && !inWin(o.disp.ms)) continue;   // nothing in-window for this session
    anyWorker = true;
    const tag = (o.disp.ms < since) ? " (dispatched pre-window)" : "";
    const land = o.land ? `${fmt(o.land.ms - o.disp.ms)} (land ${o.land.ev.replace(/^land /,"")})${tag}` : "(never landed — still running or aborted)";
    const label = `${o.leg} [${session}]`;
    const name = label.length > 34 ? label.slice(0,33)+"…" : label;
    process.stdout.write(`  ${name.padEnd(34)} ${land}\n`);
  }
  if (!anyWorker) process.stdout.write("  (no worker dispatches in window)\n");

  // gate run per branch + derivable wait
  process.stdout.write("\ngate run per branch (first→last critic event):\n");
  if (gate.size === 0){
    process.stdout.write("  (no gate events in window)\n");
  } else {
    // order branches by first-gate ts
    const order = [...gate.entries()].sort((x,y) => x[1][0]-y[1][0]);
    for (const [br, g] of order){
      const run = fmt(g[1] - g[0]);
      // wait = first gate - earliest worker dispatch of that same branch
      let waitStr = "n/a";
      let best = null;
      for (const o of sessions.values()) if (o.disp && branch(o.leg) === br && (!best || o.disp.ms < best)) best = o.disp.ms;
      if (best !== null) waitStr = fmt(g[0] - best);
      const name = br.length > 34 ? br.slice(0,33)+"…" : br;
      process.stdout.write(`  ${name.padEnd(34)} run=${run.padEnd(8)} wait-to-first=${waitStr}\n`);
    }
  }

  // one-line wall-clock summary
  const pctWaiting = span > 0 ? Math.max(0, Math.min(100, ((span - union) / span) * 100)) : 0;
  process.stdout.write(`\nwall-clock: total ${fmt(span)}, worker-active ${fmt(union)} (${(100-pctWaiting).toFixed(0)}% of span), waiting ${pctWaiting.toFixed(0)}%\n`);
' "$since_epoch" < "$allnorm"

exit 0
