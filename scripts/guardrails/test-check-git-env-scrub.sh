#!/usr/bin/env bash
# scripts/guardrails/test-check-git-env-scrub.sh — HIMMEL-3570: exercises
# check-git-env-scrub.sh against tracked fixtures under
# scripts/guardrails/git-env-scrub-cases/ (deliberately NOT named fixtures/ or
# test-fixtures/ — the checker itself excludes paths under those directory
# names, which would make every fixture here invisible to it).
#
# Platform guard: POSIX bash 3.2+, same as the other guardrail tests here —
# no .ps1 twin.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHECKER="$REPO_ROOT/scripts/guardrails/check-git-env-scrub.sh"
CASES="scripts/guardrails/git-env-scrub-cases"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

EMPTY_BASELINE="$(mktemp "${TMPDIR:-/tmp}/git-env-scrub-empty-baseline.XXXXXX")" || exit 2
trap 'rm -f "$EMPTY_BASELINE" "$SCOPED_BASELINE"' EXIT

# run <fixture...> -- scans the named fixture(s) under an EMPTY baseline (so
# no real baseline entry can accidentally mask a test), from the repo root.
OUT=""
run() {
    OUT="$(cd "$REPO_ROOT" && GIT_ENV_SCRUB_BASELINE="$EMPTY_BASELINE" bash "$CHECKER" --tree "$@" 2>&1)"
    return $?
}

expect_red() {
    local label="$1" fixture="$2"
    run "$CASES/$fixture"
    local rc=$?
    if [ "$rc" -eq 1 ] && grep -qF "$fixture" <<<"$OUT"; then
        pass "$label"
    else
        fail "$label (rc=$rc)"
        printf '%s\n' "$OUT" | sed 's/^/    /'
    fi
}

expect_green() {
    local label="$1" fixture="$2"
    run "$CASES/$fixture"
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "$label"
    else
        fail "$label (rc=$rc)"
        printf '%s\n' "$OUT" | sed 's/^/    /'
    fi
}

# ---- RED at base: the two fixtures the brief requires to fail out of the
# gate, with no scrub, no baseline, nothing to save them. ----
expect_red  "T1  unscrubbed shell entry point fails"          unscrubbed-entry.sh
expect_red  "T2  unscrubbed JS execFileSync('git', ...) fails" unscrubbed.mjs

# ---- shell: scrub / helper / exemption / control shapes ----
expect_green "T3  all-four unset on one line passes"           unset-scrubbed.sh
expect_green "T4  all-four unset split across lines passes"    split-unset-scrubbed.sh
expect_green "T5  source git-clean.sh + git_env_scrub passes"  helper-scrubbed.sh
expect_green "T6  file-level exemption with a reason passes"   file-exempt.sh
expect_red   "T7  file-level exemption with NO reason fails"   file-exempt-no-reason.sh
expect_green "T8  case-pattern/string/comment 'git' is not a call" case-pattern-only.sh

# ---- shell: shebang-less entry-point risk (console REDIRECT, 2026-09-24) ----
expect_red   "T9  shebang-less .sh with an unmarked git call fails" sourced-lib-unmarked.sh
expect_green "T10 shebang-less .sh marked '# sourced-lib' passes"   sourced-lib-marked.sh
expect_green "T11 shebang-less .sh with no git call at all passes"  sourced-lib-no-invocation.sh

# ---- JS: scrub / helper / exemption shapes ----
expect_green "T12 scrub keys visible in the call window passes" scrubbed.mjs
expect_green "T13 routes through the shared gitClean() helper"  helper.mjs
expect_green "T14 same-line exemption with a reason passes"     exempt.mjs
expect_red   "T15 same-line exemption with NO reason fails"     exempt-no-reason.mjs

# ---- baseline: a listed shell file and a listed JS call are grandfathered ----
SCOPED_BASELINE="$(mktemp "${TMPDIR:-/tmp}/git-env-scrub-scoped-baseline.XXXXXX")" || exit 2
{
    printf 'SHELL:%s/baseline-listed.sh\n' "$CASES"
    line="$(sed -n '6p' "$REPO_ROOT/$CASES/baseline-listed.mjs")"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    hash="$(printf '%s' "$trimmed" | sha256sum | cut -c1-12)"
    printf 'JS:%s/baseline-listed.mjs:%s\n' "$CASES" "$hash"
} > "$SCOPED_BASELINE"

OUT="$(cd "$REPO_ROOT" && GIT_ENV_SCRUB_BASELINE="$SCOPED_BASELINE" bash "$CHECKER" --tree "$CASES/baseline-listed.sh" "$CASES/baseline-listed.mjs" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "T16 baseline-listed shell file and JS call are grandfathered"
else
    fail "T16 baseline-listed shell file and JS call are grandfathered (rc=$rc)"
    printf '%s\n' "$OUT" | sed 's/^/    /'
fi

# T17 -- same two fixtures, WITHOUT the scoped baseline: both must fail, to
# prove T16 passed because of the baseline and not by accident.
run "$CASES/baseline-listed.sh" "$CASES/baseline-listed.mjs"
rc=$?
if [ "$rc" -eq 1 ] && grep -qF "baseline-listed.sh" <<<"$OUT" && grep -qF "baseline-listed.mjs" <<<"$OUT"; then
    pass "T17 same two fixtures fail without the baseline (control)"
else
    fail "T17 same two fixtures fail without the baseline (control) (rc=$rc)"
    printf '%s\n' "$OUT" | sed 's/^/    /'
fi

# T18 -- sanity: the real trust paths, under the real committed baseline,
# report clean. This is the ratchet's day-one promise.
REAL_OUT="$(cd "$REPO_ROOT" && bash "$CHECKER" --tree 2>&1)"
real_rc=$?
if [ "$real_rc" -eq 0 ] && grep -qF "clean" <<<"$REAL_OUT"; then
    pass "T18 real trust paths are clean under the committed baseline"
else
    fail "T18 real trust paths are clean under the committed baseline (rc=$real_rc)"
    printf '%s\n' "$REAL_OUT" | sed 's/^/    /'
fi

echo
echo "== summary =="
if [ "$failures" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$failures FAILURE(S)"
    exit 1
fi
