#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-doctor-check-ids.sh (HIMMEL-2664).
#
# Builds throwaway git repos with a fixture scripts/himmel-doctor.sh staged,
# exercises each rc case, asserts exact rc. Modeled on test-doc-guard.sh:
# only the git repo is a tempdir -- the checked script runs IN PLACE from
# the real tree (it sources scripts/lib/git-show-safe.sh via its own
# SCRIPT_DIR, and resolves the repo-to-check via `git rev-parse
# --show-toplevel`, which is CWD-relative).
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
#
# Usage: bash scripts/hooks/test-check-doctor-check-ids.sh
# Exit 0 if all cases pass, 1 otherwise.
#
# shellcheck disable=SC2016  # single-quoted fixture strings intentionally contain $
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HOOKS/check-doctor-check-ids.sh"
REPO_ROOT="$(cd "$HOOKS/../.." && pwd)"

# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HOOKS/../lib/fixture-tempdir.sh"

FIXTURE_HEADER='#!/usr/bin/env bash
# fixture himmel-doctor.sh for test-check-doctor-check-ids.sh
'

# setup_repo: temp git repo with scripts/himmel-doctor.sh staged from $1.
setup_repo() {
    R=$(fixture_mktemp_dir) || return 1
    git -C "$R" init -q
    git -C "$R" config user.email t@t
    git -C "$R" config user.name t
    mkdir -p "$R/scripts"
    printf '%s' "$1" > "$R/scripts/himmel-doctor.sh"
    git -C "$R" add scripts/himmel-doctor.sh
}

RUN_TAIL='
# --- run ------------------------------------------------------------------------
if [ "$DO_FIX" = 1 ]; then fix_c1_guardrail; else check_c1_guardrail; fi
'

_failures=0

run_case() {
    local name="$1" fixture="$2" want="$3" rc=0
    setup_repo "$fixture" || { echo "FAIL  $name (fixture setup failed)"; _failures=$((_failures + 1)); return; }
    ( cd "$R" && bash "$SCRIPT" >/dev/null 2>&1 )
    rc=$?
    if [ "$rc" -eq "$want" ]; then
        printf '  PASS  %s (rc=%s)\n' "$name" "$rc"
    else
        printf '  FAIL  %s -- expected rc=%s, got rc=%s\n' "$name" "$want" "$rc"
        _failures=$((_failures + 1))
    fi
}

# A1 RED control -- duplicate ID definition (check_c2 and check_c2_dup both
# claim ID 2; only check_c2 is called, so this isolates the duplicate-
# DEFINITION invariant from the duplicate-CALL invariant).
DUP_ID="${FIXTURE_HEADER}
check_c1_guardrail() { return 0; }
fix_c1_guardrail() { check_c1_guardrail; }
check_c2() { return 0; }
check_c2_dup() { return 0; }
${RUN_TAIL}
check_c2
"
run_case "A1 duplicate ID definition -> refused" "$DUP_ID" 1

# A2 RED control -- dropped call (check_c3_foo is defined but never
# invoked from the call list).
DROPPED_CALL="${FIXTURE_HEADER}
check_c1_guardrail() { return 0; }
fix_c1_guardrail() { check_c1_guardrail; }
check_c2() { return 0; }
check_c3_foo() { return 0; }
${RUN_TAIL}
check_c2
"
run_case "A2 defined-but-never-called -> refused" "$DROPPED_CALL" 1

# A3 -- called but never defined (a call-list typo / stale rename).
NEVER_DEFINED="${FIXTURE_HEADER}
check_c1_guardrail() { return 0; }
fix_c1_guardrail() { check_c1_guardrail; }
check_c2() { return 0; }
${RUN_TAIL}
check_c2
check_c9_typo
"
run_case "A3 called-but-never-defined -> refused" "$NEVER_DEFINED" 1

# A3b RED control (codex-3) -- a call-list entry whose ID matches a defined
# function but whose NAME does not (check_c3_bar called, only check_c3_foo
# defined). An ID-only comparison would wave this through as "ID 3
# satisfied"; the name-based check must catch it as both never-called
# (check_c3_foo) and never-defined (check_c3_bar).
NAME_MISMATCH_SAME_ID="${FIXTURE_HEADER}
check_c1_guardrail() { return 0; }
fix_c1_guardrail() { check_c1_guardrail; }
check_c2() { return 0; }
check_c3_foo() { return 0; }
${RUN_TAIL}
check_c2
check_c3_bar
"
run_case "A3b call-list entry shares an ID but not the name -> refused" "$NAME_MISMATCH_SAME_ID" 1

# A3c RED control (codex-5) -- a COMMENTED-OUT call does not satisfy the
# invariant: check_c3_foo is defined but its only call-list mention is
# inside a comment, so it must still be refused as never-called.
COMMENTED_OUT_CALL="${FIXTURE_HEADER}
check_c1_guardrail() { return 0; }
fix_c1_guardrail() { check_c1_guardrail; }
check_c2() { return 0; }
check_c3_foo() { return 0; }
${RUN_TAIL}
check_c2
# check_c3_foo
"
run_case "A3c commented-out call does not satisfy the invariant -> refused" "$COMMENTED_OUT_CALL" 1

# A3d -- a comment mentioning an ALREADY-called check must not create a
# false duplicate-call failure (codex-5).
COMMENT_MENTION="${FIXTURE_HEADER}
check_c1_guardrail() { return 0; }
fix_c1_guardrail() { check_c1_guardrail; }
check_c2() { return 0; }
${RUN_TAIL}
check_c2
# note: check_c2 covers the case from HIMMEL-0000
"
run_case "A3d comment mentioning a called check -> not a false duplicate" "$COMMENT_MENTION" 0

# A4 -- DOCTOR_CHECK_IDS_OK=1 bypasses an otherwise-refused violation.
setup_repo "$DUP_ID" || { echo "FAIL  A4 bypass env var (fixture setup failed)"; _failures=$((_failures + 1)); }
( cd "$R" && DOCTOR_CHECK_IDS_OK=1 bash "$SCRIPT" >/dev/null 2>&1 )
rc=$?
if [ "$rc" -eq 0 ]; then
    printf '  PASS  %s (rc=%s)\n' "A4 DOCTOR_CHECK_IDS_OK=1 bypasses a refused fixture" "$rc"
else
    printf '  FAIL  %s -- expected rc=0, got rc=%s\n' "A4 DOCTOR_CHECK_IDS_OK=1 bypasses a refused fixture" "$rc"
    _failures=$((_failures + 1))
fi

# B1 -- clean fixture, including the conditional C1 call-site shape, passes.
CLEAN="${FIXTURE_HEADER}
check_c1_guardrail() { return 0; }
fix_c1_guardrail() { check_c1_guardrail; }
check_c2() { return 0; }
check_c3_foo() { return 0; }
${RUN_TAIL}
check_c2
check_c3_foo
"
run_case "B1 clean fixture (incl. C1 conditional) -> passes" "$CLEAN" 0

# B2 -- the real doctor script on this checkout passes (positive control,
# runs against the checkout's own scripts/himmel-doctor.sh, not a fixture).
( cd "$REPO_ROOT" && bash "$SCRIPT" >/dev/null 2>&1 )
rc=$?
if [ "$rc" -eq 0 ]; then
    printf '  PASS  %s (rc=%s)\n' "B2 real doctor on this checkout -> passes" "$rc"
else
    printf '  FAIL  %s -- expected rc=0, got rc=%s\n' "B2 real doctor on this checkout -> passes" "$rc"
    _failures=$((_failures + 1))
fi

if [ "$_failures" -eq 0 ]; then
    echo "PASS: test-check-doctor-check-ids.sh (all cases)"
    exit 0
fi
echo "FAIL: test-check-doctor-check-ids.sh ($_failures case(s) failed)"
exit 1
