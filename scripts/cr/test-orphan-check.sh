#!/usr/bin/env bash
# Smoke test for scripts/cr/orphan-check.sh (HIMMEL-2226).
#
# Usage: bash scripts/cr/test-orphan-check.sh
#
# Exit codes:
#   0 -- all cases passed
#   1 -- at least one case failed
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/orphan-check.sh"

FAILED=0
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label -- expected '$expected', got '$actual'"
        FAILED=$((FAILED + 1))
    fi
}
assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *) echo "FAIL $label -- expected to find '$needle' in: $haystack"; FAILED=$((FAILED + 1)) ;;
    esac
}
assert_not_contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) echo "FAIL $label -- unexpectedly found '$needle' in: $haystack"; FAILED=$((FAILED + 1)) ;;
        *) echo "PASS $label" ;;
    esac
}

TMP=$(mktemp -d -t orphan-check.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
mkdir -p "$REPO"
(
  cd "$REPO" || exit 1
  git init -q -b main .
  git config user.email t@t
  git config user.name t
  git config commit.gpgsign false
  git commit -q --allow-empty -m init
)
GIT_DIR="$REPO/.git"

write_prior() { # branch content
    local branch="$1" content="$2"
    mkdir -p "$(dirname "$GIT_DIR/cr-prior-blocking/$branch")"
    printf '%s' "$content" >"$GIT_DIR/cr-prior-blocking/$branch"
}
write_agg() { # branch content
    local branch="$1" content="$2"
    mkdir -p "$(dirname "$GIT_DIR/cr-aggregate-verdicts/$branch")"
    printf '%s' "$content" >"$GIT_DIR/cr-aggregate-verdicts/$branch"
}
run_check() { # branch [dir] -> sets OUT, ERR, RC
    local d="${2:-$REPO}"
    OUT=$( (cd "$d" && bash "$SCRIPT" --branch "$1") 2>"$TMP/err.txt" )
    RC=$?
    ERR=$(cat "$TMP/err.txt")
}

# T1: both files present, every phase-A id also in the aggregate -> 0 orphans,
# no diagnostics on stderr.
write_prior t1 'VERDICT [x-1] = disproved
VERDICT [codex-adv-2] = agreed
'
write_agg t1 'VERDICT [x-1] = disproved
VERDICT [codex-adv-2] = agreed
VERDICT [coderabbit-9] = unaddressed
'
run_check t1
assert_eq "T1 stdout" "orphan-check: 0 unaddressed phase-A candidate(s)" "$OUT"
assert_eq "T1 rc" "0" "$RC"
assert_eq "T1 stderr empty" "" "$ERR"

# T2: a phase-A id missing from the aggregate -> count 1, id on stderr.
write_prior t2 'VERDICT [x-1] = disproved
VERDICT [codex-adv-2] = agreed
'
write_agg t2 'VERDICT [x-1] = disproved
'
run_check t2
assert_eq "T2 stdout" "orphan-check: 1 unaddressed phase-A candidate(s)" "$OUT"
assert_eq "T2 rc" "0" "$RC"
assert_contains "T2 stderr names the orphan id" "$ERR" "codex-adv-2"

# T3: aggregate file missing entirely, prior-blocking has 2 candidates ->
# BOTH are orphans (fail-closed).
write_prior t3 'VERDICT [a-1] = agreed
VERDICT [b-2] = conflict
'
run_check t3
assert_eq "T3 stdout" "orphan-check: 2 unaddressed phase-A candidate(s)" "$OUT"
assert_contains "T3 stderr has a-1" "$ERR" "a-1"
assert_contains "T3 stderr has b-2" "$ERR" "b-2"

# T4: aggregate present but EMPTY, prior-blocking has candidates -> same
# fail-closed result as T3.
write_prior t4 'VERDICT [c-1] = agreed
VERDICT [d-2] = conflict
'
write_agg t4 ''
run_check t4
assert_eq "T4 stdout" "orphan-check: 2 unaddressed phase-A candidate(s)" "$OUT"

# T5: prior-blocking file missing -> 0 orphans, exit 0 (fail-open).
write_agg t5 'VERDICT [z-1] = agreed
'
run_check t5
assert_eq "T5 stdout" "orphan-check: 0 unaddressed phase-A candidate(s)" "$OUT"
assert_eq "T5 rc" "0" "$RC"

# T6: prior-blocking file present but empty -> 0 orphans, exit 0.
write_prior t6 ''
write_agg t6 'VERDICT [z-1] = agreed
'
run_check t6
assert_eq "T6 stdout" "orphan-check: 0 unaddressed phase-A candidate(s)" "$OUT"
assert_eq "T6 rc" "0" "$RC"

# T7: extra ids in the AGGREGATE not in prior-blocking (the real
# [coderabbit-N] shape, adjudicated in step 3.5) -> must NOT be reported.
write_prior t7 'VERDICT [x-1] = agreed
'
write_agg t7 'VERDICT [x-1] = agreed
VERDICT [coderabbit-5] = unaddressed
'
run_check t7
assert_eq "T7 stdout" "orphan-check: 0 unaddressed phase-A candidate(s)" "$OUT"
assert_eq "T7 stderr empty" "" "$ERR"

# T8: branch scoping -- concurrent /pr-check on different LINKED WORKTREES
# shares one git-common-dir, so a run for branch Y must not see branch X's
# file (HIMMEL-1219 round 1b). Uses two real `git worktree add` checkouts:
# driving both checks from $REPO alone cannot catch a SUT that scoped
# records to each worktree's PRIVATE git dir (--git-dir) instead of the
# shared --git-common-dir, because a non-worktree repo's --git-dir IS its
# --git-common-dir -- the two only diverge inside a real linked worktree.
git -C "$REPO" branch -q wt-scope-x
git -C "$REPO" branch -q wt-scope-y
WT_X="$TMP/wt-x"
WT_Y="$TMP/wt-y"
git -C "$REPO" worktree add -q "$WT_X" wt-scope-x
git -C "$REPO" worktree add -q "$WT_Y" wt-scope-y

write_prior scope-x 'VERDICT [x-only] = agreed
'
write_agg scope-x ''
write_prior scope-y 'VERDICT [y-only] = agreed
'
write_agg scope-y 'VERDICT [y-only] = agreed
'
run_check scope-y "$WT_Y"
assert_eq "T8 scope-y stdout" "orphan-check: 0 unaddressed phase-A candidate(s)" "$OUT"
assert_not_contains "T8 scope-y stderr does not leak scope-x's orphan" "$ERR" "x-only"
run_check scope-x "$WT_X"
assert_eq "T8 scope-x stdout" "orphan-check: 1 unaddressed phase-A candidate(s)" "$OUT"
assert_contains "T8 scope-x stderr has x-only" "$ERR" "x-only"

git -C "$REPO" worktree remove -f "$WT_X" 2>/dev/null || true
git -C "$REPO" worktree remove -f "$WT_Y" 2>/dev/null || true

# T9: a branch name containing '/' (real himmel branches are type/slug) --
# the nested path must resolve correctly.
write_prior "fix/himmel-2226-guardrail-ux" 'VERDICT [n-1] = agreed
'
write_agg "fix/himmel-2226-guardrail-ux" ''
run_check "fix/himmel-2226-guardrail-ux"
assert_eq "T9 stdout" "orphan-check: 1 unaddressed phase-A candidate(s)" "$OUT"
assert_contains "T9 stderr has n-1" "$ERR" "n-1"

# T10a: --branch with no value -> exit 2.
out10a=$( (cd "$REPO" && bash "$SCRIPT" --branch) 2>"$TMP/err10a.txt" )
rc10a=$?
assert_eq "T10a rc (--branch no value)" "2" "$rc10a"
assert_eq "T10a stdout empty" "" "$out10a"

# T10b: unknown argument -> exit 2.
out10b=$( (cd "$REPO" && bash "$SCRIPT" --bogus) 2>"$TMP/err10b.txt" )
rc10b=$?
assert_eq "T10b rc (unknown argument)" "2" "$rc10b"
assert_eq "T10b stdout empty" "" "$out10b"

# T11: run outside a git repository -> exit 3. GIT_CEILING_DIRECTORIES stops
# git from walking up past TMP into an ancestor real repo (same idiom as
# test-check-pr-lane-isolation.sh's T6).
NONREPO="$TMP/nonrepo"
mkdir -p "$NONREPO"
rc11=$( (cd "$NONREPO" && GIT_CEILING_DIRECTORIES="$TMP" bash "$SCRIPT" >/dev/null 2>"$TMP/err11.txt"); echo "$?" )
assert_eq "T11 rc" "3" "$rc11"

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
