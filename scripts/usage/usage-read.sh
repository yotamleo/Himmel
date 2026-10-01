#!/usr/bin/env bash
# scripts/usage/usage-read.sh -- read CLI for the per-ticket usage store
# (HIMMEL-3994). Consumers use this instead of touching transcript JSONL.
#
# Usage:
#   usage-read.sh [--store <dir>] [--ticket KEY] [--all]
#
# Prints JSONL: the LATEST record per ticket (or of --ticket), or with --all
# every stored version in append order. Schema: docs/internals/usage-records.md.
#
# Platform guard (gitbash-only): bash 3.2-safe + jq; no .ps1 twin needed.
set -euo pipefail

STORE="${HIMMEL_USAGE_STORE:-${HOME}/.himmel/state/usage}"
TICKET=""
ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --store)  STORE="${2:-}"; shift 2 ;;
    --ticket) TICKET="${2:-}"; shift 2 ;;
    --all)    ALL=1; shift ;;
    *) echo "usage-read: unknown argument: $1" >&2; exit 1 ;;
  esac
done

FILE="$STORE/records.jsonl"
[ -f "$FILE" ] || { echo "usage-read: no store at $FILE" >&2; exit 1; }

# Take the store lock that usage-compute.sh holds while it appends, so a read
# never sees a torn last line. A store the reader cannot write (a shared or
# read-only mount) cannot be locked, so it is read without the lock and fails
# closed on a last line with no newline, the mark of an append in flight.
if [ ! -w "$STORE" ]; then
  # snapshot first, then check the snapshot: checking the live file and reading it
  # later would let an append start in between
  SNAP="$(mktemp)"; trap 'rm -f "$SNAP"' EXIT; trap 'exit 130' INT TERM HUP
  cat "$FILE" > "$SNAP"
  [ -z "$(tail -c1 "$SNAP")" ] || { echo "usage-read: $FILE ends mid-line (writer active on a store this reader cannot lock); retry" >&2; exit 1; }
  FILE="$SNAP"
else
  LOCK="$STORE/.lock"; n=0
  until mkdir "$LOCK" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -lt 120 ] || { echo "usage-read: store locked: $LOCK (remove it if no run is active)" >&2; exit 1; }
    sleep 0.5
  done
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
  trap 'exit 130' INT TERM HUP
fi

# shellcheck disable=SC2016  # jq's own $vars
jq -c --arg t "$TICKET" --argjson all "$ALL" -n '
  [inputs | select($t == "" or .ticket == $t)] as $rows
  | if $all == 1 then $rows[]
    else ($rows | reduce .[] as $r ({}; .[$r.ticket] = $r) | to_entries | sort_by(.key)[] | .value) end' "$FILE"
