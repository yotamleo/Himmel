#!/usr/bin/env bash
# scripts/handover/resolve-active-item-report.sh — /pr-check steps 4.6/4.7's
# best-effort item-dir resolution, moved out of an inline shell fence
# (HIMMEL-3707). guard-pr-check-literal.sh's tokenizer reads a `case`
# statement's bare `*` default arm as an unresolved scripts/handover/ writer
# operand whenever the same simple command also invokes a scripts/handover/
# script, denying pr-check.md's own step 4.6/4.7 fence outright. Wrapping the
# rc branching in a script — the same move HIMMEL-2321 made for the
# reviewer-notes/bugs writers — keeps the runbook down to one plain
# `bash "<path>" --branch '<branch>'` call the guard never needs to parse a
# case out of.
#
# Exit: always 0 (best-effort — steps 4.6/4.7 never block the gate, matching
# resolve-active-item.sh's own graceful-skip contract).
# stdout: the item dir on a match (rc 0), or an explicit skip line (rc 3).
# stderr: a distinguishable error line on any other rc.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
branch=""
while [ $# -gt 0 ]; do case "$1" in
  --branch) branch="${2-}"; if [ $# -gt 1 ]; then shift 2; else shift; fi;;
  *) echo "resolve-active-item-report.sh: unknown arg $1 — ignoring, best-effort" >&2; shift;;
esac; done

item_rc=0
item_dir=$(bash "$HERE/resolve-active-item.sh" --branch "$branch") || item_rc=$?
if [ "$item_rc" -eq 0 ]; then
  printf '%s\n' "$item_dir"
elif [ "$item_rc" -eq 3 ]; then
  echo "4.6/4.7: no active handover item for $branch — handover bridges SKIPPED (not a failure)"
else
  echo "4.6/4.7: resolve-active-item.sh errored (rc=$item_rc) — handover bridges skipped, best-effort" >&2
fi
exit 0
