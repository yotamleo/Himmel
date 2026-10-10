#!/usr/bin/env bash
# scripts/ci/impacted-selection.sh — HIMMEL-3897 (HIMMEL-3815 slice G).
#
# Decides, for one PR run, whether the fixed shell-unit shards run the FULL
# corpus or only the IMPACTED suites, and prints the decision as a manifest
# header that every shard and the aggregator copy verbatim.
#
# Usage: impacted-selection.sh <base-sha|''> [<head>]      (head defaults HEAD)
#
# BASE-SOURCED. This copy (the PR's) only bootstraps: it extracts the BASE
# commit's own impacted-selection.sh, ci-trust-paths.txt and selector
# (scripts/cr/impacted-suites.sh + its anchor hand-off) into a temp dir and
# execs THAT copy, which makes the decision. A PR therefore cannot narrow its
# own selection except by editing one of those files — and every one of them
# is a trust path, which forces `full` here and a trust-reviewed GO at merge
# (HIMMEL-3895). A base that predates this script decides `full`.
#
# Output, one `key value` per line, in this order:
#   mode full|impacted
#   reason <why>
#   base <sha|->
#   head <sha>
#   selector <base blob sha of scripts/cr/impacted-suites.sh|->
#   changed <path>      one per changed file (impacted only)
#   suite <path>        one per selected test-*.sh (impacted only; may be none)
#
# FAIL-CLOSED: an empty base (not a PR to the default branch), a base that does
# not resolve, a base that is not an ancestor of the default branch
# ($IMPSEL_DEFAULT_REF, default refs/remotes/origin/main — spec hole H1: a PR
# opened against a branch holding an unreviewed selector), an empty diff, an
# unreadable/empty trust list, a trust-path match, or ANY selector error each
# print `mode full`. Exit 0 whenever a verdict was printed; exit 2 only on usage
# or an unresolvable head, which callers treat as `full` (runner) or red
# (aggregator).
#
# Platform guard: bash 3.2+, git + grep + tar; Linux CI is the only caller.
set -uo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: impacted-selection.sh <base-sha|''> [<head>]" >&2
  exit 2
fi
base_arg="$1"
head_arg="${2:-HEAD}"

if ! head_sha=$(git rev-parse --verify --quiet --end-of-options "${head_arg}^{commit}"); then
  echo "impacted-selection: head '${head_arg}' does not resolve to a commit" >&2
  exit 2
fi

# verdict_full <reason> [<base>] [<selector>] — print a `full` header and stop.
verdict_full() {
  printf 'mode full\nreason %s\nbase %s\nhead %s\nselector %s\n' \
    "$1" "${2:--}" "$head_sha" "${3:--}"
  exit 0
}

[ -n "$base_arg" ] || verdict_full "no-base: not a pull_request to the default branch"
if ! base_sha=$(git rev-parse --verify --quiet --end-of-options "${base_arg}^{commit}"); then
  verdict_full "base-unresolved: ${base_arg}"
fi
default_ref="${IMPSEL_DEFAULT_REF:-refs/remotes/origin/main}"
if ! git rev-parse --verify --quiet "${default_ref}^{commit}" >/dev/null; then
  verdict_full "default-ref-unresolved: ${default_ref}" "$base_sha"
fi
if ! git merge-base --is-ancestor "$base_sha" "$default_ref"; then
  verdict_full "base-off-default: ${base_sha} is not an ancestor of ${default_ref}" "$base_sha"
fi
selector_blob=$(git rev-parse --verify --quiet "${base_sha}:scripts/cr/impacted-suites.sh") || selector_blob=""

# ---- bootstrap: hand the decision to the BASE commit's copy -----------------
if [ -z "${IMPSEL_BASE_TOOLS:-}" ]; then
  git cat-file -e "${base_sha}:scripts/ci/impacted-selection.sh" 2>/dev/null \
    || verdict_full "base-predates-selector" "$base_sha" "$selector_blob"
  tools=$(mktemp -d "${TMPDIR:-/tmp}/impacted-selection.XXXXXX") \
    || verdict_full "mktemp-failed" "$base_sha" "$selector_blob"
  # shellcheck disable=SC2064  # expand $tools now: it is the dir to remove
  trap "rm -rf '$tools'" EXIT
  if ! git archive --format=tar "$base_sha" -- \
         scripts/ci/impacted-selection.sh scripts/ci/ci-trust-paths.txt \
         scripts/cr/impacted-suites.sh scripts/cr/anchor-handoff.sh \
       | tar -x -C "$tools"; then
    verdict_full "base-extract-failed" "$base_sha" "$selector_blob"
  fi
  IMPSEL_BASE_TOOLS="$tools" bash "$tools/scripts/ci/impacted-selection.sh" "$base_sha" "$head_sha"
  exit $?
fi

# ---- decision (running from the base extraction) ----------------------------
tools="$IMPSEL_BASE_TOOLS"
# HIMMEL-4997: -z, because without it git C-quotes a name holding a double quote,
# backslash or tab, the anchored trust match below misses it and the PR stays on
# the impacted path. The NUL list feeds the trust match; tr makes the
# one-per-line copy the verdict prints.
if ! git diff -z --name-only --no-renames "${base_sha}...${head_sha}" > "$tools/changed.z"; then
  verdict_full "diff-failed" "$base_sha" "$selector_blob"
fi
[ -s "$tools/changed.z" ] || verdict_full "empty-diff" "$base_sha" "$selector_blob"
changed=$(tr '\0' '\n' < "$tools/changed.z")

trust_re=$(grep -vE '^[[:space:]]*(#|$)' "$tools/scripts/ci/ci-trust-paths.txt" 2>/dev/null) || trust_re=""
[ -n "$trust_re" ] || verdict_full "trust-list-empty" "$base_sha" "$selector_blob"
# grep: 0 = a trust path changed, 1 = none did, anything else = broken list.
# HIMMEL-5174: create the output first in a checked step. A redirect that cannot
# open its target is also rc 1, which the case below reads as "no trust path".
: > "$tools/hits.z" || verdict_full "trust-match-failed" "$base_sha" "$selector_blob"
grep -z -E -f <(printf '%s\n' "$trust_re") "$tools/changed.z" > "$tools/hits.z"; grc=$?
hits=$(tr '\0' '\n' < "$tools/hits.z")
case $grc in
  0) verdict_full "trust-path: ${hits%%$'\n'*}" "$base_sha" "$selector_blob" ;;
  1) ;;
  *) verdict_full "trust-match-failed" "$base_sha" "$selector_blob" ;;
esac

if ! suites=$(bash "$tools/scripts/cr/impacted-suites.sh" "${base_sha}..${head_sha}" --shell); then
  verdict_full "selector-error" "$base_sha" "$selector_blob"
fi

printf 'mode impacted\nreason base-sourced selector\nbase %s\nhead %s\nselector %s\n' \
  "$base_sha" "$head_sha" "${selector_blob:--}"
printf '%s\n' "$changed" | sed 's/^/changed /'
[ -z "$suites" ] || printf '%s\n' "$suites" | sed 's/^/suite /'
exit 0
