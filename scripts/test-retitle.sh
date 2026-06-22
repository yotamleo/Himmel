#!/usr/bin/env bash
# Tests for scripts/retitle.sh (HIMMEL-432).
#
# Hermetic: inference is driven through the RETITLE_BRANCH seam; the
# not-a-git-repo cases run with the process cwd inside a temp dir OUTSIDE any
# git tree (git rev-parse walks only parent dirs, so it genuinely fails there).
# Never touches real session state — the script is read-only inference + print.
#
# Cases (spec §Success criteria + plan-critic case 14):
#   1.  feat/himmel-432-rename-session-title → /rename HIMMEL-432 rename-session-title
#   2.  handover/HIMMEL-141-pr-merge        → /rename HIMMEL-141 pr-merge
#   3.  feat/himmel-432-x + arg HIMMEL-430  → /rename HIMMEL-432/HIMMEL-430 x
#   4.  feat/abc-12-do-thing               → /rename ABC-12 do-thing (name half do-thing)
#   5.  main (no ticket)                   → rc 3, WARN, /rename main (no ticket part)
#   6.  main + arg HIMMEL-500              → /rename HIMMEL-500 main
#   7.  arg not-a-key!                     → rc 1, usage on stderr
#   8.  not-a-git-repo + no args           → rc 2
#   9.  feat/ABC-1-2-rest                  → /rename ABC-1 2-rest
#   10. fix-himmel-432-thing (mid-slug)    → /rename HIMMEL-432 fix-himmel-432-thing
#   11. not-a-git-repo + arg HIMMEL-500    → /rename HIMMEL-500 (empty name half)
#   12. doc anti-rot: output has tab-title note + /rename reference
#   13. detached HEAD (RETITLE_BRANCH=HEAD, in non-repo) + no args → rc 2, no /rename HEAD
#   14. RETITLE_BRANCH= (empty) in non-repo + no args → rc 2 (empty ≡ unset)
#   15. ticket-only branch feat/himmel-432 (empty name via branch route) → /rename HIMMEL-432
#   16. digit-led token feat/1-2-foo (not a valid ticket) → rc 3, /rename 1-2-foo, no ticket part
#   17. valid + invalid arg (HIMMEL-430 bad!) → rc 1, stderr names the invalid one
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/retitle.sh"

PASS=0; FAIL=0; COUNT=0; NONREPO=""

# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$NONREPO" ] && [ -d "$NONREPO" ]; then rm -rf "$NONREPO" 2>/dev/null || true; fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

OUT=""; ERR=""; RC=0
# run <cwd> <branch-spec> [args...]
#   branch-spec: the literal RETITLE_BRANCH value, or the sentinel UNSET to unset it.
run() {
    local cwd="$1" bspec="$2"; shift 2
    COUNT=$((COUNT+1))
    local of ef
    of=$(mktemp); ef=$(mktemp)
    if [ "$bspec" = UNSET ]; then
        ( cd "$cwd" && unset RETITLE_BRANCH && bash "$SCRIPT" "$@" ) >"$of" 2>"$ef"
    else
        ( cd "$cwd" && RETITLE_BRANCH="$bspec" bash "$SCRIPT" "$@" ) >"$of" 2>"$ef"
    fi
    RC=$?
    OUT=$(cat "$of"); ERR=$(cat "$ef")
    rm -f "$of" "$ef"
}

# The suggestion line is printed on the stable form "  /rename …"; assert on it
# alone (not the whole stdout) so boilerplate can't false-fail (spec M1).
suggestion() { printf '%s\n' "$OUT" | grep '^  /rename ' | head -1 | sed 's/^  *//'; }

assert_rc()         { if [ "$RC" -eq "$1" ]; then pass "$2"; else fail "$2" "rc=$RC want $1"; fi; }
assert_suggestion() { local g; g=$(suggestion); if [ "$g" = "$1" ]; then pass "$2"; else fail "$2" "got [$g] want [$1]"; fi; }
assert_out_has()    { if printf '%s' "$OUT" | grep -qF -- "$1"; then pass "$2"; else fail "$2" "stdout missing: $1"; fi; }
assert_err_has()    { if printf '%s' "$ERR" | grep -qiF -- "$1"; then pass "$2"; else fail "$2" "stderr missing: $1"; fi; }
refute_suggestion_ticket() {
    local g; g=$(suggestion)
    if printf '%s' "$g" | grep -qE '[A-Z][A-Z0-9]*-[0-9]+'; then fail "$1" "unexpected ticket in: $g"; else pass "$1"; fi
}
refute_out_has() { if printf '%s' "$OUT" | grep -qF -- "$1"; then fail "$2" "unexpected: $1"; else pass "$2"; fi; }

# Precondition (plan-critic F1): a temp dir OUTSIDE any git tree where rev-parse fails.
NONREPO=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then NONREPO=$(cygpath -m "$NONREPO"); fi
if git -C "$NONREPO" rev-parse --abbrev-ref HEAD >/dev/null 2>&1; then
    echo "PRECONDITION FAILED: \$NONREPO ($NONREPO) is inside a git repo — cannot simulate not-a-git-repo"; exit 1
fi

echo "test-retitle.sh"

# 1
run "$SCRIPT_DIR" feat/himmel-432-rename-session-title
assert_suggestion "/rename HIMMEL-432 rename-session-title" "1 conventional feat branch suggestion"
assert_rc 0 "1 conventional feat branch rc 0"

# 2
run "$SCRIPT_DIR" handover/HIMMEL-141-pr-merge
assert_suggestion "/rename HIMMEL-141 pr-merge" "2 handover branch suggestion"
assert_rc 0 "2 handover branch rc 0"

# 3 — multi-ticket via arg
run "$SCRIPT_DIR" feat/himmel-432-x HIMMEL-430
assert_suggestion "/rename HIMMEL-432/HIMMEL-430 x" "3 multi-ticket join"
assert_rc 0 "3 multi-ticket rc 0"

# 4 — lowercase token, original-case strip (name half must be do-thing, not abc-12-do-thing)
run "$SCRIPT_DIR" feat/abc-12-do-thing
assert_suggestion "/rename ABC-12 do-thing" "4 lowercase token uppercased + name half do-thing"
assert_rc 0 "4 lowercase rc 0"

# 5 — no ticket, base branch
run "$SCRIPT_DIR" main
assert_suggestion "/rename main" "5 main suggestion (no ticket)"
refute_suggestion_ticket "5 main suggestion has no ticket part"
assert_rc 3 "5 main rc 3 degraded"
assert_err_has "no ticket" "5 main WARN on stderr"

# 6 — no inferred ticket but explicit arg
run "$SCRIPT_DIR" main HIMMEL-500
assert_suggestion "/rename HIMMEL-500 main" "6 arg ticket + base-branch name"
assert_rc 0 "6 arg ticket rc 0"

# 7 — invalid arg
run "$SCRIPT_DIR" feat/himmel-432-x "not-a-key!"
assert_rc 1 "7 invalid arg rc 1"
assert_err_has "usage" "7 invalid arg usage on stderr"

# 8 — not a git repo, no args
run "$NONREPO" ""
assert_rc 2 "8 not-a-git-repo no-args rc 2"

# 9 — malformed multi-dash key, first left-bounded match
run "$SCRIPT_DIR" feat/ABC-1-2-rest
assert_suggestion "/rename ABC-1 2-rest" "9 multi-dash first match"
assert_rc 0 "9 multi-dash rc 0"

# 10 — mid-slug ticket (non-conventional, no leading type/), name left whole
run "$SCRIPT_DIR" fix-himmel-432-thing
assert_suggestion "/rename HIMMEL-432 fix-himmel-432-thing" "10 mid-slug token not stripped"
assert_rc 0 "10 mid-slug rc 0"

# 11 — not a git repo + valid arg → empty name half
run "$NONREPO" "" HIMMEL-500
assert_suggestion "/rename HIMMEL-500" "11 not-a-git-repo + arg, empty name half"
assert_rc 0 "11 not-a-git-repo + arg rc 0"

# 12 — doc anti-rot
run "$SCRIPT_DIR" feat/himmel-432-rename-session-title
assert_out_has "tab title" "12 terminal tab-title note present"
assert_out_has "/rename" "12 references built-in /rename"

# 13 — detached HEAD in non-repo (real git path can't rescue) + no args
run "$NONREPO" HEAD
assert_rc 2 "13 detached HEAD rc 2"
refute_out_has "/rename HEAD" "13 no nonsense /rename HEAD line"

# 14 — explicitly empty RETITLE_BRANCH in non-repo + no args (empty ≡ unset)
run "$NONREPO" ""
assert_rc 2 "14 empty RETITLE_BRANCH ≡ unset → rc 2"

# 15 — ticket-only branch: name half empty via the BRANCH route (not arg)
run "$SCRIPT_DIR" feat/himmel-432
assert_suggestion "/rename HIMMEL-432" "15 ticket-only branch, empty name half"
assert_rc 0 "15 ticket-only branch rc 0"

# 16 — digit-led first token is not a valid ticket → degrades, name = whole slug
run "$SCRIPT_DIR" feat/1-2-foo
assert_suggestion "/rename 1-2-foo" "16 digit-led token not extracted"
refute_suggestion_ticket "16 digit-led degrades with no ticket part"
assert_rc 3 "16 digit-led rc 3 degraded"

# 17 — valid arg then invalid arg → fail-fast on the invalid one
run "$SCRIPT_DIR" feat/himmel-432-x HIMMEL-430 "bad!"
assert_rc 1 "17 valid+invalid arg rc 1"
assert_err_has "bad!" "17 stderr names the invalid arg"

echo
echo "ran $COUNT cases; PASS=$PASS FAIL=$FAIL"
if [ "$COUNT" -ne 17 ]; then echo "CASE-COUNT MISMATCH: ran $COUNT want 17"; exit 1; fi
[ "$FAIL" -eq 0 ] || exit 1
