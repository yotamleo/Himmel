#!/usr/bin/env bash
# scripts/usage/usage-compute.sh -- per-ticket usage records, computed once,
# append-only (HIMMEL-3994). Joins two computations that used to live apart:
#   1. per-session tokens   -- scripts/lib/bank-attribution.sh output (HIMMEL-2764)
#   2. CR rounds / verdicts -- the CR critic ledger (scripts/cr/ledger-append.sh)
# Both read local files and fail closed. A third, opt-in join (HIMMEL-4030)
# adds PR/CI facts from gh when --repo is given; it fails closed too: any gh
# failure aborts the WHOLE run before anything is appended, and a record never
# stores null for an unknown fact.
# into ONE record per ticket (schema: docs/internals/usage-records.md).
#
# Usage:
#   usage-compute.sh [--projects <dir>] [--ledger <file>] [--store <dir>]
#                    [--range KEY-a..KEY-b | --tickets K1,K2]
#                    [--since <iso>] [--repo OWNER/NAME [--gh <executable>]]
#                    [--print]
#
# Default appends changed records to <store>/records.jsonl; --print writes the
# records to stdout and touches no store. A record carries ids and numbers
# only -- never message text -- and no compute timestamp, so a rerun on the
# same inputs is byte-identical and an unchanged record is not re-appended.
#
# Platform guard (gitbash-only): pure bash 3.2-safe + jq; no .ps1 twin needed.
set -euo pipefail

die() { echo "usage-compute: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BANK="$HERE/../lib/bank-attribution.sh"

PROJECTS="${HOME}/.claude/projects"
LEDGER=""
STORE="${HIMMEL_USAGE_STORE:-${HOME}/.himmel/state/usage}"
RANGE=""
TICKETS=""
SINCE=""
PRINT=0
PROJECTS_SET=0
REPO=""
GH=""

# one shared check: a value-taking flag must be followed by a non-empty value
need_val() { [ -n "${2:-}" ] || die "$1 needs a non-empty value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --projects) need_val "$@"; PROJECTS="$2"; PROJECTS_SET=1; shift 2 ;;
    --ledger)   need_val "$@"; LEDGER="$2"; shift 2 ;;
    --store)    need_val "$@"; STORE="$2"; shift 2 ;;
    --range)    need_val "$@"; RANGE="$2"; shift 2 ;;
    --tickets)  need_val "$@"; TICKETS="$2"; shift 2 ;;
    --since)    need_val "$@"; SINCE="$2"; shift 2 ;;
    --repo)     need_val "$@"; REPO="$2"; shift 2 ;;
    --gh)       need_val "$@"; GH="$2"; shift 2 ;;
    --print)    PRINT=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

# The gh join needs an explicit repo (never inferred from the cwd) and a gh
# that is ONE executable path (a path with a space is fine; arguments are not).
if [ -n "$GH" ] && [ -z "$REPO" ]; then die "--gh needs --repo"; fi
if [ -n "$REPO" ]; then
  [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--repo must be OWNER/NAME: $REPO"
  [ -n "$GH" ] || GH="gh"
  command -v "$GH" >/dev/null 2>&1 || die "gh not found or not executable (one path, no arguments): $GH"
fi

# An explicit input that is missing or unreadable fails closed before anything
# is written; a default may be absent (noted, treated as empty).
if [ "$PROJECTS_SET" = 1 ]; then
  if [ ! -d "$PROJECTS" ] || [ ! -r "$PROJECTS" ]; then die "--projects is not a readable directory: $PROJECTS"; fi
elif [ ! -d "$PROJECTS" ]; then
  echo "usage-compute: note: default projects dir absent ($PROJECTS); no sessions" >&2
  PROJECTS=""
fi
if [ -n "$LEDGER" ]; then
  if [ ! -f "$LEDGER" ] || [ ! -r "$LEDGER" ]; then die "--ledger is not a readable file: $LEDGER"; fi
else
  LEDGER="$(git rev-parse --git-common-dir 2>/dev/null || true)/cr-critic-scores.jsonl"
  [ -f "$LEDGER" ] || echo "usage-compute: note: default CR ledger absent ($LEDGER); no CR data" >&2
fi

# Ticket selector -> {prefix, lo, hi} or {list} or {} (all).
SEL='{}'
if [ -n "$RANGE" ] && [ -n "$TICKETS" ]; then die "--range and --tickets are exclusive"; fi
if [ -n "$RANGE" ]; then
  if ! [[ "$RANGE" =~ ^([A-Z][A-Z0-9]*)-([0-9]+)\.\.([A-Z][A-Z0-9]*)-([0-9]+)$ ]] \
    || [ "${BASH_REMATCH[1]}" != "${BASH_REMATCH[3]}" ]; then
    die "--range must be KEY-a..KEY-b with one key prefix: $RANGE"
  fi
  SEL="$(jq -nc --arg p "${BASH_REMATCH[1]}" --argjson lo "${BASH_REMATCH[2]}" --argjson hi "${BASH_REMATCH[4]}" '{prefix:$p,lo:$lo,hi:$hi}')"
elif [ -n "$TICKETS" ]; then
  # every comma-separated entry must be a KEY-n (a trailing comma is an empty entry)
  if ! jq -ne --arg l "$TICKETS" '($l | split(",") | length > 0 and all(.[]; test("^[A-Z][A-Z0-9]*-[0-9]+$")))' >/dev/null; then
    die "--tickets must be comma-separated KEY-n entries: $TICKETS"
  fi
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

# --- 2. join: sessions + CR ledger -> base records ---------------
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
if [ -n "$TICKETS" ] && [ "$(jq '[.[] | select(.ticket | startswith("_") | not)] | length' "$WORK/base.json")" = 0 ]; then die "--tickets matched no session or CR row: $TICKETS"; fi

# --- 3. PR/CI join (opt-in via --repo) ---------------------------------------
# gh JSON for one call, or die: auth, network, rate limit, a wrong repo and a
# bad --gh all land here, and nothing has been appended yet.
gh_json() {
  local out
  if ! out="$("$GH" "$@" 2>"$WORK/gh.err")"; then
    die "gh $1 $2 failed: $(head -c 200 "$WORK/gh.err" | tr '\n' ' ')"
  fi
  printf '%s' "$out"
}

# Sets PRJ and CIJ for ticket $1. Unknown never becomes a value: any failure or
# unexpected shape dies, so a stored record is either complete or absent.
# shellcheck disable=SC2016  # jq's own $vars
join_ticket() {
  local t="$1" prs mine branches b runs all="[]" n
  prs="$(gh_json pr list -R "$REPO" --search "$t in:title" --state all --json number,state,title,headRefName --limit 100)"
  jq -e 'type == "array" and all(.[]; (.number | type == "number") and (.state | IN("OPEN","CLOSED","MERGED")) and (.title | type == "string") and (.headRefName | type == "string" and length > 0 and (startswith("-") | not)))' <<<"$prs" >/dev/null 2>&1 \
    || die "gh pr list returned an unexpected shape for $t"
  [ "$(jq 'length' <<<"$prs")" -lt 100 ] || die "gh pr list hit its 100-row limit for $t; refusing a truncated join"
  mine="$(jq -c --arg t "$t" '[.[] | select(.title | test("(^|[^A-Z0-9])" + $t + "($|[^A-Z0-9])"; "i"))]' <<<"$prs")"
  if [ "$(jq 'length' <<<"$mine")" = 0 ]; then
    PRJ='{"state":"none"}'; CIJ='{"state":"no-pr"}'; return 0
  fi
  PRJ="$(jq -c '{state: "found", numbers: ([.[].number] | sort), merged: ([.[] | select(.state == "MERGED")] | length), open: ([.[] | select(.state == "OPEN")] | length), closed: ([.[] | select(.state == "CLOSED")] | length)}' <<<"$mine")"
  branches="$(jq -r '[.[].headRefName] | unique | .[]' <<<"$mine")"
  while IFS= read -r b; do
    runs="$(gh_json run list -R "$REPO" --branch "$b" --limit 100 --json databaseId,status,conclusion,createdAt,startedAt,updatedAt)"
    jq -e 'type == "array" and all(.[]; (.databaseId | type == "number") and (.status | type == "string") and (.createdAt | type == "string") and (.updatedAt | type == "string") and (.startedAt == null or (.startedAt | type == "string")))' <<<"$runs" >/dev/null 2>&1 \
      || die "gh run list returned an unexpected shape for $t on $b"
    n="$(jq 'length' <<<"$runs")"
    [ "$n" -lt 100 ] || die "gh run list hit its 100-row limit for $t on $b; refusing a truncated join"
    all="$(jq -c --argjson r "$runs" '. + $r' <<<"$all")"
  done <<<"$branches"
  # secs counts completed runs only; startedAt excludes queue wait, createdAt is the
  # recorded fallback when any completed run lacks it (ci.basis says which)
  CIJ="$(jq -c 'unique_by(.databaseId) | [.[] | select(.status == "completed")] as $c
    | (if ($c | length) == 0 then "none" elif all($c[]; .startedAt != null) then "startedAt" else "createdAt" end) as $b
    | [$c[] | (.updatedAt | fromdateiso8601) - ((if $b == "startedAt" then .startedAt else .createdAt end) | fromdateiso8601)] as $d
    | if any($d[]; . < 0) then error("negative ci duration") else . end
    | {state: "found", runs: 0, completed: ($c | length), basis: $b, secs: ($d | add // 0)}' <<<"$all")" || die "cannot compute ci seconds for $t"
  CIJ="$(jq -c --argjson n "$(jq 'unique_by(.databaseId) | length' <<<"$all")" '.runs = $n' <<<"$CIJ")"
}

# --- assemble final records + digest ----------------------------------------
: > "$WORK/records.jsonl"
for t in $(jq -r '.[].ticket' "$WORK/base.json"); do
  rec="$(jq -cS --arg t "$t" '.[] | select(.ticket == $t)' "$WORK/base.json")"
  if [ -n "$REPO" ] && [ "${t#_}" = "$t" ]; then
    join_ticket "$t"
    rec="$(printf '%s' "$rec" | jq -cS --argjson pr "$PRJ" --argjson ci "$CIJ" '. + {pr: $pr, ci: $ci}')"
  fi
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
