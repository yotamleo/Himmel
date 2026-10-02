#!/usr/bin/env bash
# scripts/handover/suite-coverage.sh — HIMMEL-4112. Read-only: says, per suite,
# whether CI actually runs it, DERIVED from scripts/ci/run-shell-tests.sh's own
# tables (never hand-copied, so it cannot drift from them).
#
#   suite-coverage.sh [--runner <run-shell-tests.sh>] <suite-path>...
#
# Verdicts (one line per suite):
#   not run in CI (SKIP_LIST) — uncovered      a SKIP_LIST entry; NEVER write "CI verifies"
#   superseded by <wrappers>                   SKIP_LIST entry whose reason names its --only wrappers
#   nightly only (extended tier, cap Ns)       SUITE_TIER_DEFAULT "extended"
#   runs in PR CI (cap Ns)                     everything else
# The cap is the runner's own _suite_timeout_for answer, evaluated, not parsed.
# Exit 0 = every suite classified, 2 = usage / unreadable runner.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
runner="$HERE/../ci/run-shell-tests.sh"
suites=()
while [ $# -gt 0 ]; do
  case "$1" in
    --runner) runner="${2:-}"; shift 2 ;;
    *) suites+=("$1"); shift ;;
  esac
done
if [ ! -r "$runner" ] || [ "${#suites[@]}" -eq 0 ]; then
  echo "usage: suite-coverage.sh [--runner <run-shell-tests.sh>] <suite-path>..." >&2
  exit 2
fi

# table <VAR> — the body of the runner's `VAR="…"` block, entries one per line.
table() { awk -v v="$1" '$0 == v "=\"" {on=1; next} on && $0 == "\"" {exit} on' "$runner"; }
skip_list="$(table SKIP_LIST)"
tier_list="$(table SUITE_TIER_DEFAULT)"

# cap <suite> — evaluate the runner's own per-suite timeout function.
cap_fn="$(awk '/^_suite_timeout_for\(\) \{/ {on=1} on {print} on && /^}/ {exit}' "$runner")"
cap() {
  # shellcheck disable=SC2317,SC2329,SC2034 # _suite_num and the vars are read by the eval'd runner function
  ( _suite_num() { printf '%s' "$2"; }
    SUITE_TIMEOUT_EXPLICIT=''; SUITE_TIMEOUT=600
    eval "$cap_fn"; _suite_timeout_for "$1" ) 2>/dev/null
}

# entry_for <table> <suite> — the table line designating the suite (full-path
# match on a "/" boundary, same as the runner's suite_entry_matches).
entry_for() {
  local line path
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line%%#*}"; path="$(printf '%s' "$path" | awk '{print $1}')"
    case "$2" in "$path"|*"/$path") printf '%s\n' "$line"; return 0 ;; esac
  done <<< "$1"
  return 1
}

for s in "${suites[@]}"; do
  s="${s#./}"
  if line="$(entry_for "$skip_list" "$s")"; then
    reason="${line#*#}"
    if grep -q 'superseded by' <<< "$reason"; then
      wrappers="$(grep -o 'test-[A-Za-z0-9._-]*\.sh' <<< "$reason" | grep -vxF "$(basename "$s")" | awk '!seen[$0]++' | paste -sd, - | sed 's/,/, /g')"
      echo "$s: superseded by ${wrappers:-its wrappers} (monolith in SKIP_LIST; the wrappers carry the coverage)"
    else
      echo "$s: not run in CI (SKIP_LIST) — uncovered; never write \"CI verifies\" for it —${reason}"
    fi
  elif entry_for "$tier_list" "$s" >/dev/null; then
    echo "$s: nightly only (extended tier, cap $(cap "$s")s) — not in per-PR CI"
  else
    echo "$s: runs in PR CI (cap $(cap "$s")s)"
  fi
done
