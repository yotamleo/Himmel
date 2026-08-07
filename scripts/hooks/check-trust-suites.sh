#!/usr/bin/env bash
# Run the scripts/trust node:test suites (HIMMEL-1589, operator decision D4).
#
# The trust suites are the spec for the trust-boundary gates. Like the
# hook/lib suites (check-hook-lib-suites.sh) they had no runner on any machine
# or in any pipeline until this hook existed, so a regression could land and
# stay green. This hook runs them path-filtered on pre-commit, alongside the
# sibling hook-lib-node-suites entry.
#
# WHY PRE-COMMIT AND NOT CI: same reasoning as check-hook-lib-suites.sh (which
# deviates from its own ticket the same way): Actions is OFF on the private
# repo by design, and the public mirror lacks the fixtures these suites source.
# Pre-commit is the only surface that both executes and has the fixtures.
set -uo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$repo_root" || { echo "check-trust-suites: cannot cd to $repo_root" >&2; exit 1; }

# HIMMEL-1583: scrub the git environment pre-commit exports before running the
# suites. pre-commit invokes its hooks with GIT_DIR/GIT_INDEX_FILE (and friends)
# set; `node --test` inherits them, and every `git` the fixtures spawn then
# resolves against THIS repository instead of the throwaway repo the fixture
# just created. See check-hook-lib-suites.sh for the measured impact (16-of-94
# false passes under an inherited GIT_DIR). Order matters: repo_root is derived
# from `git rev-parse` above, so this must come AFTER that call.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX \
      GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CONFIG_PARAMETERS

if ! command -v node >/dev/null 2>&1; then
  echo "check-trust-suites: node not found — cannot run the trust suites" >&2
  exit 1
fi

status=0
# One glob, so no loop — check-hook-lib-suites.sh iterates only because it owns
# two. A single-element `for … in` also reads to shellcheck as a mistyped
# command substitution (SC2041).
glob='scripts/trust/tests/*.test.mjs'

# ls-guard (the ci.yml:117 idiom): `node --test` reports zero tests and exits
# 0 when the glob matches nothing, so a renamed or deleted suite would go
# green with nothing executed. `ls` on an unexpanded pattern fails, so we do.
# Unquoted on purpose — the SHELL must expand it here, unlike the node call
# below where node does its own expansion.
# shellcheck disable=SC2086
if ! ls $glob >/dev/null 2>&1; then
  echo "check-trust-suites: no suite matched $glob" >&2
  status=1
elif ! out=$(node --test "$glob" 2>&1); then
  echo "check-trust-suites: FAILED $glob" >&2
  echo "$out" >&2
  status=1
else
  echo "  ok  $glob"
fi

exit "$status"
