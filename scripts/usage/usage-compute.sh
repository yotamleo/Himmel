#!/usr/bin/env bash
# scripts/usage/usage-compute.sh -- per-ticket usage records, computed once,
# append-only (HIMMEL-3994). Joins four computations that used to live apart:
#   1. per-session tokens   -- scripts/lib/bank-attribution.sh output (HIMMEL-2764)
#   2. CR rounds / verdicts -- the CR critic ledger (scripts/cr/ledger-append.sh)
#   3. PR + merge time      -- gh pr list
#   4. CI wall time         -- gh run list
# into ONE record per ticket (schema: docs/internals/usage-records.md).
#
# Usage:
#   usage-compute.sh [--projects <dir>] [--ledger <file>] [--store <dir>]
#                    [--gh <cmd>] [--range KEY-a..KEY-b | --tickets K1,K2]
#                    [--since <iso>] [--print]
#
# Default appends changed records to <store>/records.jsonl; --print writes the
# records to stdout and touches no store. A record carries ids and numbers
# only -- never message text -- and no compute timestamp, so a rerun on the
# same inputs is byte-identical and an unchanged record is not re-appended.
#
# Platform guard (gitbash-only): pure bash 3.2-safe + jq (+ gh for PR/CI, which
# degrade to null when it is unavailable); no .ps1 twin needed.
set -euo pipefail

die() { echo "usage-compute: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BANK="$HERE/../lib/bank-attribution.sh"

PROJECTS="${HOME}/.claude/projects"
LEDGER=""
STORE="${HIMMEL_USAGE_STORE:-${HOME}/.himmel/state/usage}"
GH="gh"
RANGE=""
TICKETS=""
SINCE=""
PRINT=0
PROJECTS_SET=0
GH_SET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --projects) PROJECTS="${2:-}"; PROJECTS_SET=1; shift 2 ;;
    --ledger)   LEDGER="${2:-}"; shift 2 ;;
    --store)    STORE="${2:-}"; shift 2 ;;
    --gh)       GH="${2:-}"; GH_SET=1; shift 2 ;;
    --range)    RANGE="${2:-}"; shift 2 ;;
    --tickets)  TICKETS="${2:-}"; shift 2 ;;
    --since)    SINCE="${2:-}"; shift 2 ;;
    --print)    PRINT=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

# An explicit input that is missing or unreadable fails closed before anything
# is written; a default may be absent (noted, treated as empty).
if [ "$PROJECTS_SET" = 1 ]; then
  [ -d "$PROJECTS" ] && [ -r "$PROJECTS" ] || die "--projects is not a readable directory: $PROJECTS"
elif [ ! -d "$PROJECTS" ]; then
  echo "usage-compute: note: default projects dir absent ($PROJECTS); no sessions" >&2
  PROJECTS=""
fi
if [ -n "$LEDGER" ]; then
  [ -f "$LEDGER" ] && [ -r "$LEDGER" ] || die "--ledger is not a readable file: $LEDGER"
else
  LEDGER="$(git rev-parse --git-common-dir 2>/dev/null || true)/cr-critic-scores.jsonl"
  [ -f "$LEDGER" ] || echo "usage-compute: note: default CR ledger absent ($LEDGER); no CR data" >&2
fi
if [ "$GH_SET" = 1 ]; then
  command -v "$GH" >/dev/null 2>&1 || die "--gh is not an executable: $GH"
fi

# Ticket selector -> {prefix, lo, hi} or {list} or {} (all).
SEL='{}'
if [ -n "$RANGE" ]; then
  if ! [[ "$RANGE" =~ ^([A-Z][A-Z0-9]*)-([0-9]+)\.\.([A-Z][A-Z0-9]*)-([0-9]+)$ ]] \
    || [ "${BASH_REMATCH[1]}" != "${BASH_REMATCH[3]}" ]; then
    die "--range must be KEY-a..KEY-b with one key prefix: $RANGE"
  fi
  SEL="$(jq -nc --arg p "${BASH_REMATCH[1]}" --argjson lo "${BASH_REMATCH[2]}" --argjson hi "${BASH_REMATCH[4]}" '{prefix:$p,lo:$lo,hi:$hi}')"
elif [ -n "$TICKETS" ]; then
  SEL="$(jq -nc --arg l "$TICKETS" '{list: ($l | split(","))}')"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/usage-compute.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
[ -n "$PROJECTS" ] || { PROJECTS="$WORK/noprojects"; mkdir "$PROJECTS"; }

# Serialize the whole compute-then-append (mkdir is atomic), so an older
# snapshot can never publish after a newer one. --print touches no store.
if [ "$PRINT" != 1 ]; then
  mkdir -p "$STORE"
  LOCK="$STORE/.lock"; n=0
  until mkdir "$LOCK" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -lt 600 ] || die "store locked: $LOCK (remove it if no run is active)"
    sleep 0.5
  done
  trap 'rmdir "$LOCK" 2>/dev/null; rm -rf "$WORK"' EXIT
fi
# a signal exits through the EXIT trap, so the lock never outlives the run
trap 'exit 130' INT TERM HUP

# --- 1. per-session tokens (reuse bank-attribution, do not re-parse JSONL) --
BA_ARGS=("$PROJECTS")
[ -z "$SINCE" ] || BA_ARGS+=(--since "$SINCE")
bash "$BANK" "${BA_ARGS[@]}" > "$WORK/bank.md" || die "bank-attribution failed (incomplete totals refused)"

: > "$WORK/ledger.jsonl"
[ ! -f "$LEDGER" ] || cp "$LEDGER" "$WORK/ledger.jsonl" || die "cannot read ledger: $LEDGER"

# --- 2. join: sessions + CR ledger -> base records (no gh yet) --------------
# shellcheck disable=SC2016  # jq's own $vars
BASE_PROGRAM='
def tk($s): ($s // "" | ascii_upcase | [match("[A-Z][A-Z0-9]*-[0-9]+"; "g").string][0]);
def keyof($s): ([$s | capture("^(?<k>[A-Z][A-Z0-9]*-[0-9]+)").k] | .[0]);
def num($k): ($k | capture("-(?<n>[0-9]+)$").n | tonumber);
def selected($k):
  if $sel.list then ($sel.list | index($k)) != null
  elif $sel.prefix then ($k | startswith($sel.prefix + "-")) and (num($k) >= $sel.lo) and (num($k) <= $sel.hi)
  else true end;
def zero: {turns:0,input:0,cache_read:0,cache_create:0,output:0,sub_turns:0,sub_input:0,sub_cache_read:0,sub_cache_create:0,sub_output:0};
def addz($a; $b): reduce (zero | keys[]) as $f ($a; .[$f] += ($b[$f] // 0));

# sessions: parse the table, merge each "(subagents)" row into its session
( [ $table | split("\n")[]
    | select(startswith("| ") and (startswith("| session |") | not) and (startswith("| **total") | not))
    | .[2:-2] | split(" | ")
    | { name: .[0], n: (.[3]|tonumber), i: (.[4]|tonumber), cr: (.[5]|tonumber), cc: (.[6]|tonumber), o: (.[7]|tonumber) } ]
  | reduce .[] as $r ({};
      ($r.name | endswith(" (subagents)")) as $sub
      | ($r.name | sub(" \\(subagents\\)$"; "")) as $nm
      | .[$nm] = ((.[$nm] // zero)
          | if $sub then (.sub_turns += $r.n | .sub_input += $r.i | .sub_cache_read += $r.cr | .sub_cache_create += $r.cc | .sub_output += $r.o)
            else (.turns += $r.n | .input += $r.i | .cache_read += $r.cr | .cache_create += $r.cc | .output += $r.o) end))
  | to_entries
  | map(. as $e | $e.key as $name
        | (if ($name | test("console"; "i")) then "console" elif ($name | test("judge"; "i")) then "judge" else "leg" end) as $kind
        | (keyof($name)) as $k
        | ({name: $name, kind: $kind, ticket: (if $k != null then $k elif $kind == "console" then "_console" else "_unattributed" end)} + $e.value))
) as $sessions

# CR ledger: findings (dedup head+id, amends applied), rounds, est tokens
| ( [ $ledger[] ] ) as $L
| ( reduce ($L[] | select(.kind == "finding")) as $f ({};
      ($f.head + "|" + $f.finding_id) as $key
      | if has($key) then . else .[$key] = {ticket: tk($f.branch), verdict: ($f.verdict // "")} end) ) as $f0
| ( reduce ($L[] | select(.kind == "amend")) as $a ($f0;
      ($a.target_head + "|" + $a.finding_id) as $key
      | if has($key) and ($a.set.verdict != null) then .[$key].verdict = $a.set.verdict else . end) ) as $fin
| ( [ $L[] | select(.kind == "finding" or .kind == "avail" or .kind == "score" or .kind == "usage")
      | select(.kind != "avail" or .status == "ok")
      | select(tk(.branch) != null) | {t: tk(.branch), head: .head, est: (if .kind == "usage" then (.est_total_tokens // 0) else 0 end)} ]
    | group_by(.t) | map({key: .[0].t, value: {rounds: ([.[].head] | unique | length), est_tokens: ([.[].est] | add)}}) | from_entries ) as $crt

| ( ([$sessions[] | select(.ticket | startswith("_") | not) | .ticket] + [$crt | keys[]]) | unique | map(select(selected(.))) ) as $tickets
| ( $tickets + ["_console", "_unattributed"] ) as $all
| [ $all[] as $t
    | ($sessions | map(select(.ticket == $t)) | sort_by(.name)) as $ss
    | select(($ss | length) > 0 or ($crt[$t] != null))
    | def tot($kind): reduce ($ss[] | select(.kind == $kind)) as $s (zero; addz(.; $s));
      ( [ $fin | to_entries[] | select(.value.ticket == $t) | (if .value.verdict == "" then "open" else .value.verdict end) ]
        | group_by(.) | map({key: .[0], value: length}) | from_entries ) as $fc
      | { schema: 1, ticket: $t,
          legs: ($ss | map(del(.ticket))),
          totals: {leg: tot("leg"), console: tot("console"), judge: tot("judge")},
          cr: {rounds: ($crt[$t].rounds // 0), findings: $fc, est_tokens: ($crt[$t].est_tokens // 0)} } ]
'
jq -n -S --rawfile table "$WORK/bank.md" --slurpfile ledger "$WORK/ledger.jsonl" --argjson sel "$SEL" \
  "$BASE_PROGRAM" > "$WORK/base.json"

# --- 3/4. PR + CI per ticket (gh; null when unavailable) --------------------
PRCI='{}'
for t in $(jq -r '.[].ticket | select(startswith("_") | not)' "$WORK/base.json"); do
  if prs="$($GH pr list --state all --search "$t in:title" --json number,title,headRefName,createdAt,mergedAt,state --limit 50 2>/dev/null)" \
      && printf '%s' "$prs" | jq -e 'type == "array"' >/dev/null 2>&1; then
    prs="$(printf '%s' "$prs" | jq -c --arg t "$t" '[.[] | select(.title | test("(^|[^A-Za-z0-9-])" + $t + "([^0-9]|$)"))]')"
    # CI comes from ONE PR: the highest-numbered match (its head branch).
    runs='[]'; cifail=0
    b="$(printf '%s' "$prs" | jq -r 'max_by(.number) | .headRefName // empty')"
    if [ -n "$b" ]; then
      r="$($GH run list --branch "$b" --json startedAt,updatedAt --limit 200 2>/dev/null)" || { cifail=1; r='[]'; }
      printf '%s' "$r" | jq -e 'type == "array"' >/dev/null 2>&1 || { cifail=1; r='[]'; }
      runs="$r"
    fi
    one="$(jq -nc --argjson prs "$prs" --argjson runs "$runs" --argjson cifail "$cifail" '
      def ts: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
      { pr: { numbers: ([$prs[].number] | sort),
              created: ([$prs[].createdAt] | min),
              merged: ([$prs[].mergedAt | select(. != null)] | max),
              outcome: (if ($prs | length) == 0 then null
                        elif any($prs[]; .state == "MERGED") then "MERGED"
                        elif any($prs[]; .state == "OPEN") then "OPEN" else "CLOSED" end) },
        ci: (([$runs[] | select(.startedAt != null and .updatedAt != null)
                       | (try ((.updatedAt | ts) - (.startedAt | ts)) catch null)]) as $d
             | if $cifail == 1 or any($d[]; . == null) then null
               else { runs: ($d | length), secs: ($d | add // 0) } end) }')"
  else
    one='{"pr":null,"ci":null}'
  fi
  PRCI="$(jq -nc --argjson m "$PRCI" --arg t "$t" --argjson o "$one" '$m + {($t): $o}')"
done

# --- assemble final records + digest ----------------------------------------
: > "$WORK/records.jsonl"
for t in $(jq -r '.[].ticket' "$WORK/base.json"); do
  rec="$(jq -cS --arg t "$t" --argjson m "$PRCI" '.[] | select(.ticket == $t) | . + ($m[$t] // {pr: null, ci: null})' "$WORK/base.json")"
  if command -v sha256sum >/dev/null 2>&1; then dg="$(printf '%s' "$rec" | sha256sum | cut -d' ' -f1)"
  else dg="$(printf '%s' "$rec" | shasum -a 256 | cut -d' ' -f1)"; fi
  printf '%s' "$rec" | jq -cS --arg d "$dg" '. + {digest: $d}' >> "$WORK/records.jsonl"
done

if [ "$PRINT" = 1 ]; then
  cat "$WORK/records.jsonl"
  exit 0
fi

# --- append-only store: add a line only when the ticket's digest changed ----
mkdir -p "$STORE"
FILE="$STORE/records.jsonl"
touch "$FILE"
added=0; kept=0
while IFS= read -r line; do
  t="$(printf '%s' "$line" | jq -r .ticket)"
  d="$(printf '%s' "$line" | jq -r .digest)"
  last="$(jq -r --arg t "$t" 'select(.ticket == $t) | .digest' "$FILE" | tail -n 1)"
  if [ "$last" = "$d" ]; then kept=$((kept + 1)); else printf '%s\n' "$line" >> "$FILE"; added=$((added + 1)); fi
done < "$WORK/records.jsonl"
echo "usage-compute: appended $added, unchanged $kept ($FILE)"
