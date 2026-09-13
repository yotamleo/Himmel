#!/usr/bin/env bash
# Run the scripts/hooks + scripts/lib node:test suites (HIMMEL-1578).
#
# Both suites are the spec for a SECURITY gate (the settings.json hook wirers
# and the shared settings lock) and, until this hook existed, no runner on any
# machine or in any pipeline invoked them. wire-hook-bash.test.mjs was 6-of-7
# RED on committed main for a full day and five consecutive chain legs read,
# discussed and deferred that file while it was broken.
#
# WHY PRE-COMMIT ONLY, HISTORICALLY (HIMMEL-1578 deviated from its own ticket):
# Actions was off on the then-private repo and the public mirror lacked
# .claude/settings.json (the wire-hook-bash fixture source), so a ci.yml step
# could not run this at all. Both premises died 2026-09-09 — origin is now the
# public repo with Actions on every PR, and .claude/settings.json is tracked
# there — so `lanes-and-trust-suites` in ci.yml now calls this script too
# (HIMMEL-3028). Pre-commit remains the fast local gate; CI is the surface a
# bypassed or skipped local hook can no longer dodge.
set -uo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$repo_root" || { echo "check-hook-lib-suites: cannot cd to $repo_root" >&2; exit 1; }

# HIMMEL-1583: scrub the git environment pre-commit exports before running the
# suites. pre-commit invokes its hooks with GIT_DIR/GIT_INDEX_FILE (and friends)
# set; `node --test` inherits them, and every `git` the fixtures spawn then
# resolves against THIS repository instead of the throwaway repo the fixture
# just created. guardrail-block.test.mjs hands git deliberately malformed
# configs and asserts git REFUSES them, so under an inherited GIT_DIR those
# assertions see rc=0 — git never read the fixture's config at all.
#
# Measured, same checkout, back to back:
#   standalone            tests 94 · pass 93 · FAIL 0
#   with GIT_DIR exported tests 94 · pass 74 · FAIL 16
#
# So the suite passed everywhere EXCEPT the surface this hook put it on, and
# blocked every scripts/hooks + scripts/lib commit repo-wide on failures
# unrelated to the diff being committed.
#
# Order matters: repo_root is derived from `git rev-parse` above, so this must
# come AFTER that call (it falls back to `pwd` regardless).
#
# This unblocks the runner. The DURABLE fix belongs in the suite — the fixture
# helpers should pass a scrubbed env to every spawn, so the suites are correct
# under ANY runner rather than correct because one caller cleans up for them.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX \
      GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CONFIG_PARAMETERS

if ! command -v node >/dev/null 2>&1; then
  echo "check-hook-lib-suites: node not found — cannot run the hook/lib suites" >&2
  exit 1
fi

status=0
for glob in \
  'scripts/hooks/*.test.mjs' \
  'scripts/lib/*.test.mjs'
do
  # ls-guard (the ci.yml:117 idiom): `node --test` reports zero tests and exits
  # 0 when the glob matches nothing, so a renamed or deleted suite would go
  # green with nothing executed. `ls` on an unexpanded pattern fails, so we do.
  # Unquoted on purpose — the SHELL must expand it here, unlike the node call
  # below where node does its own expansion.
  # shellcheck disable=SC2086
  if ! ls $glob >/dev/null 2>&1; then
    echo "check-hook-lib-suites: no suite matched $glob" >&2
    status=1
    continue
  fi
  if ! out=$(node --test "$glob" 2>&1); then
    echo "check-hook-lib-suites: FAILED $glob" >&2
    echo "$out" >&2
    status=1
  else
    echo "  ok  $glob"
  fi
done

exit "$status"
