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
    if command -v sha256sum >/dev/null 2>&1; then
        hash="$(printf '%s' "$trimmed" | sha256sum | cut -c1-12)"
    else
        hash="$(printf '%s' "$trimmed" | shasum -a 256 | cut -c1-12)"
    fi
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

# ---- CR fixup (HIMMEL-3570): detector gaps the panel's self-review found
# before the console-facing review saw them ----
expect_red "T19 git inside a double-quoted \$(...) cmdsub is caught"     quoted-cmdsub-unscrubbed.sh
expect_red "T20 quoted multi-word command string ('git status') is caught" quoted-multiword-unscrubbed.mjs
expect_red "T21 bare exec( ) (no Sync/File) is caught"                   exec-bare-unscrubbed.mjs
expect_red "T22 scrub names in a COMMENT alone don't satisfy the window" comment-fake-scrub-unscrubbed.mjs

# ---- should-fix round (console adversarial review, 2026-09-24) ----

# T23 -- a --tree path that does not exist must fail, not report clean. Before
# the fix, a nonexistent path matches neither `-f` nor `-d` and is silently
# skipped, so the fixture below (deliberately never on disk) would previously
# report zero findings and rc=0.
T23_OUT="$(cd "$REPO_ROOT" && GIT_ENV_SCRUB_BASELINE="$EMPTY_BASELINE" bash "$CHECKER" --tree "$CASES/does-not-exist-xyz.sh" 2>&1)"
T23_RC=$?
if [ "$T23_RC" -ne 0 ] && grep -qF "does not exist" <<<"$T23_OUT"; then
    pass "T23 --tree on a nonexistent path fails, not clean"
else
    fail "T23 --tree on a nonexistent path fails, not clean (rc=$T23_RC)"
    printf '%s\n' "$T23_OUT" | sed 's/^/    /'
fi

# T24 -- bare `--tree` (no PATH args — the real full-scan mode CI runs, see
# T18 below) must fail, not report clean, when it scans zero trust-path
# files. Before the fix, `git ls-files ... 2>/dev/null` inside a process
# substitution silently swallows an empty/errored file list and the checker
# exits 0 "clean" with no floor on how many files it actually looked at.
# Isolated tmp repo: none of the five trust-path pathspecs exist in it, so
# `git ls-files` legitimately returns an empty list.
T24_REPO="$(mktemp -d "${TMPDIR:-/tmp}/git-env-scrub-empty-repo.XXXXXX")" || exit 2
(cd "$T24_REPO" && git init -q && git config user.email t@t && git config user.name t) >/dev/null 2>&1
T24_OUT="$(cd "$T24_REPO" && GIT_ENV_SCRUB_BASELINE="$EMPTY_BASELINE" bash "$CHECKER" --tree 2>&1)"
T24_RC=$?
rm -rf "$T24_REPO"
if [ "$T24_RC" -ne 0 ]; then
    pass "T24 default mode with 0 trust-path files scanned fails, not clean"
else
    fail "T24 default mode with 0 trust-path files scanned fails, not clean (rc=$T24_RC)"
    printf '%s\n' "$T24_OUT" | sed 's/^/    /'
fi

# T25 -- --staged must catch a rename INTO a trust path. Before the fix,
# `--diff-filter=ACM` omits `R`, so `git mv scripts/other/x.sh
# scripts/hooks/x.sh` (status R100) never reaches the scanner and pre-commit
# passes an unscrubbed file renamed straight into a guarded directory.
T25_REPO="$(mktemp -d "${TMPDIR:-/tmp}/git-env-scrub-staged-repo.XXXXXX")" || exit 2
(
    cd "$T25_REPO" || exit 1
    git init -q
    git config user.email t@t
    git config user.name t
    mkdir -p scripts/other scripts/hooks
    printf '#!/usr/bin/env bash\ngit status\n' > scripts/other/x.sh
    git add scripts/other/x.sh
    git commit -q -m init
    git mv scripts/other/x.sh scripts/hooks/x.sh
) >/dev/null 2>&1
T25_OUT="$(cd "$T25_REPO" && GIT_ENV_SCRUB_BASELINE="$EMPTY_BASELINE" bash "$CHECKER" --staged 2>&1)"
T25_RC=$?
rm -rf "$T25_REPO"
if [ "$T25_RC" -eq 1 ] && grep -qF "scripts/hooks/x.sh" <<<"$T25_OUT"; then
    pass "T25 --staged catches a rename INTO a trust path"
else
    fail "T25 --staged catches a rename INTO a trust path (rc=$T25_RC)"
    printf '%s\n' "$T25_OUT" | sed 's/^/    /'
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
