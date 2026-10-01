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

# shellcheck disable=SC2016  # jq's own $vars
jq -c --arg t "$TICKET" --argjson all "$ALL" -n '
  [inputs | select($t == "" or .ticket == $t)] as $rows
  | if $all == 1 then $rows[]
    else ($rows | reduce .[] as $r ({}; .[$r.ticket] = $r) | to_entries | sort_by(.key)[] | .value) end' "$FILE"
