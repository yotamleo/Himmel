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
# Exit 0 = every suite classified, 2 = usage / unreadable or unintelligible
# runner, 3 = at least one suite is unknown (printed as such).
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
runner="$HERE/../ci/run-shell-tests.sh"
default_runner=1
suites=()
while [ $# -gt 0 ]; do
  case "$1" in
    --runner) [ $# -ge 2 ] || break; runner="$2"; default_runner=0; shift 2 ;;
    *) suites+=("$1"); shift ;;
  esac
done
if [ $# -gt 0 ] || [ ! -r "$runner" ] || [ "${#suites[@]}" -eq 0 ]; then
  echo "usage: suite-coverage.sh [--runner <run-shell-tests.sh>] <suite-path>..." >&2
  exit 2
fi

# table <VAR> — the body of the runner's `VAR="…"` block, entries one per line.
table() { awk -v v="$1" '$0 == v "=\"" {on=1; next} on && $0 == "\"" {exit} on' "$runner"; }
skip_list="$(table SKIP_LIST)"
tier_list="$(table SUITE_TIER_DEFAULT)"

# cap <suite> — evaluate the runner's own per-suite timeout function.
cap_fn="$(awk '/^_suite_timeout_for\(\) \{/ {on=1} on {print} on && /^}/ {exit}' "$runner")"
if [ -z "$skip_list" ] || [ -z "$tier_list" ] || [ -z "$cap_fn" ]; then
  echo "suite-coverage.sh: $runner has no SKIP_LIST / SUITE_TIER_DEFAULT table or _suite_timeout_for — not a run-shell-tests.sh this helper understands" >&2
  exit 2
fi
# shellcheck disable=SC2016 # a literal pattern for the runner's own source line
default_line="$(grep -m1 '^SUITE_TIMEOUT=\$(_suite_num SUITE_TIMEOUT ' "$runner")"
cap() {
  # shellcheck disable=SC2317,SC2329,SC2034 # _suite_num and the vars are read by the eval'd runner code
  ( _suite_num() { printf '%s' "$2"; }
    SUITE_TIMEOUT_EXPLICIT=''; SUITE_TIMEOUT=''
    [ -n "$default_line" ] && eval "$default_line"   # the runner's own default, its single source
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

rc=0
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
  elif [ "$default_runner" -eq 1 ] && { [ ! -f "$HERE/../../$s" ] || [[ "$(basename "$s")" != test-*.sh ]]; }; then
    echo "$s: unknown — not an existing test-*.sh suite in this repo; coverage cannot be stated"
    rc=3
  else
    c="$(cap "$s")"
    case "$c" in ''|*[!0-9]*) echo "suite-coverage.sh: could not evaluate the runner's cap for $s" >&2; exit 2 ;; esac
    if line="$(entry_for "$tier_list" "$s")" && [ "$(awk '{print $2}' <<< "$line")" = extended ]; then
      echo "$s: nightly only (extended tier, cap ${c}s) — not in per-PR CI"
    else
      echo "$s: runs in PR CI (cap ${c}s)"
    fi
  fi
done
exit "$rc"
