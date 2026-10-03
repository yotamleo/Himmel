#!/usr/bin/env bash
# Hidden acceptance test for task finding-verify (HIMMEL-4090).
# Ground truth: F1 is real (the `s)` arm multiplies by 60); F2 is not real
# (cache-probe.sh refuses --turns below 1 with a usage error).
# Usage: accept.sh <worktree> <fixture-sha>
set -u
. "$(dirname "$0")/../accept-common.sh"
WT="$1"; FIX="$2"
V="$WT/lq-work/verdicts.json"

field() { jq -r --arg f "$1" --arg k "$2" '.[$f][$k] // ""' "$V" 2>/dev/null; }
# cited_line <finding> <expected-path> <regex>: the cited line exists and matches.
cited_line() {
  local ev path line
  ev="$(field "$1" evidence)"
  path="${ev%%:*}"; line="${ev##*:}"
  [ "$path" = "$2" ] || return 1
  case "$line" in ''|*[!0-9]*) return 1 ;; esac
  grep -Eq -- "$3" <<<"$(sed -n "${line}p" "$WT/$path")"
}

accept_ok verdicts-valid-json jq -e 'type == "object"' "$V"
accept_eq f1-verdict real "$(field F1 verdict)"
accept_ok f1-evidence cited_line F1 lq-work/parse-dur.sh '^[[:space:]]*s\)'
accept_eq f2-verdict not-real "$(field F2 verdict)"
accept_ok f2-evidence cited_line F2 scripts/eval/cache-probe.sh 'TURNS.*(-lt 1|>= 1)'
accept_ok parse-dur-untouched git -C "$WT" diff --quiet "$FIX" -- lq-work/parse-dur.sh
accept_ok cache-probe-untouched git -C "$WT" diff --quiet "$FIX" -- scripts/eval/cache-probe.sh

accept_done
