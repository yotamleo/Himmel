#!/usr/bin/env bash
# Smoke test for scripts/guardrails/lib.sh.
#
# Builds throwaway git repos, exercises each predicate, asserts rc.
# Usage: bash scripts/guardrails/test-lib.sh
#
# Exit 0 if all cases pass, 1 otherwise.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/scripts/guardrails/lib.sh"

if [ ! -f "$LIB" ]; then
    echo "FAIL: $LIB not found"
    exit 1
fi

# shellcheck source=/dev/null
. "$LIB"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

setup_repo() {
    # $1 = branch name to leave HEAD on
    local dir
    dir="$(mktemp -d)"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email t@t
    git -C "$dir" config user.name t
    git -C "$dir" commit --allow-empty -q -m "init"
    if [ "$1" != "main" ]; then
        git -C "$dir" checkout -q -b "$1"
    fi
    printf '%s' "$dir"
}

echo "== is_on_main =="
d=$(setup_repo main)
if is_on_main "$d"; then pass "main -> true"; else fail "main -> expected 0 got $?"; fi
rm -rf "$d"

d=$(setup_repo feat/x)
if is_on_main "$d"; then fail "feat/x -> expected 1 got 0"; else pass "feat/x -> false"; fi
rm -rf "$d"

echo "== is_dirty =="
d=$(setup_repo feat/x)
if is_dirty "$d"; then fail "clean -> expected 1 got 0"; else pass "clean -> false"; fi
echo dirty > "$d/file.txt"
if is_dirty "$d"; then pass "untracked -> true"; else fail "untracked -> expected 0 got $?"; fi
rm -rf "$d"

echo "== is_merged_into_main =="
d=$(setup_repo feat/x)
git -C "$d" commit --allow-empty -q -m "feat: x"
git -C "$d" checkout -q main
git -C "$d" merge --no-ff -q feat/x -m "merge"
git -C "$d" checkout -q feat/x
if is_merged_into_main "$d"; then pass "merged -> true"; else fail "merged -> expected 0 got $?"; fi
rm -rf "$d"

d=$(setup_repo feat/y)
git -C "$d" commit --allow-empty -q -m "feat: y"
if is_merged_into_main "$d"; then fail "unmerged -> expected 1 got 0"; else pass "unmerged -> false"; fi
rm -rf "$d"

echo "== is_behind_origin_main =="
# Simulate origin via a bare repo + clone
origin=$(mktemp -d)
git -C "$origin" init -q --bare -b main
work=$(mktemp -d)
git clone -q "$origin" "$work"
git -C "$work" config user.email t@t
git -C "$work" config user.name t
git -C "$work" commit --allow-empty -q -m "base"
git -C "$work" push -q origin main
git -C "$work" checkout -q -b feat/z
# Advance origin/main by one commit
git -C "$work" checkout -q main
git -C "$work" commit --allow-empty -q -m "advance"
git -C "$work" push -q origin main
git -C "$work" checkout -q feat/z
git -C "$work" fetch -q origin
if is_behind_origin_main "$work"; then pass "behind -> true"; else fail "behind -> expected 0 got $?"; fi
rm -rf "$work" "$origin"

echo "== rc=2 fail-closed contract =="
# Non-git dir: every predicate that touches git must return rc=2 (not 1).
ngd=$(mktemp -d)
is_on_main "$ngd"; rc=$?
if [ "$rc" -eq 2 ]; then pass "is_on_main non-git -> rc=2"; else fail "is_on_main non-git -> expected 2 got $rc"; fi
is_dirty "$ngd"; rc=$?
if [ "$rc" -eq 2 ]; then pass "is_dirty non-git -> rc=2"; else fail "is_dirty non-git -> expected 2 got $rc"; fi
is_merged_into_main "$ngd"; rc=$?
if [ "$rc" -eq 2 ]; then pass "is_merged_into_main non-git -> rc=2"; else fail "is_merged_into_main non-git -> expected 2 got $rc"; fi
rm -rf "$ngd"

# is_merged_into_main: missing local `main` ref -> rc=2 (cannot evaluate).
d=$(setup_repo feat/x)
git -C "$d" commit --allow-empty -q -m "feat"
git -C "$d" branch -D main 2>/dev/null || true
is_merged_into_main "$d"; rc=$?
if [ "$rc" -eq 2 ]; then pass "is_merged_into_main no-main-ref -> rc=2"; else fail "is_merged_into_main no-main-ref -> expected 2 got $rc"; fi
rm -rf "$d"

echo "== detached HEAD =="
d=$(setup_repo feat/x)
git -C "$d" commit --allow-empty -q -m "feat"
sha=$(git -C "$d" rev-parse HEAD)
git -C "$d" checkout -q "$sha"
b=$(_branch "$d"); rc=$?
if [ "$rc" -eq 1 ] && [ -z "$b" ]; then pass "_branch detached -> empty + rc=1"; else fail "_branch detached -> expected empty+rc=1 got [$b] rc=$rc"; fi
is_on_main "$d"; rc=$?
if [ "$rc" -eq 1 ]; then pass "is_on_main detached -> false"; else fail "is_on_main detached -> expected 1 got $rc"; fi
is_merged_into_main "$d"; rc=$?
if [ "$rc" -eq 1 ]; then pass "is_merged_into_main detached -> false"; else fail "is_merged_into_main detached -> expected 1 got $rc"; fi
rm -rf "$d"

echo "== is_merged_into_main: regex-metachar branch names not interpreted =="
# Branch name `feat.x` (dot is regex meta). After branch creation but
# NOT merged into main, is_merged_into_main must return 1, not be fooled
# by `feat.x` matching any 6-char string in `branch --merged main`.
d=$(setup_repo "feat.x")
git -C "$d" commit --allow-empty -q -m "feat"
# Sanity: only `main` is in branch --merged main (feat.x not merged).
is_merged_into_main "$d"; rc=$?
if [ "$rc" -eq 1 ]; then pass "regex-meta branch unmerged -> false"; else fail "regex-meta branch -> expected 1 got $rc"; fi
rm -rf "$d"

echo "== is_merged_into_main: HIMMEL-114 FF-merged + no main advance -> false (chosen tradeoff) =="
# Pin the chosen tradeoff: an FF-merged branch where main has NOT advanced
# since produces ahead=0 + behind=0 (referentially identical to a fresh
# branch). HIMMEL-114 treats both as "not merged" because blocking fresh
# branches' first commit was the more painful failure mode.
# If a future "fix" tries to restore FF-merge detection by removing the
# ahead=0+behind=0 short-circuit, this test will start failing - that's
# the signal to reconsider the tradeoff (and re-fix the fresh-branch
# regression separately).
d=$(setup_repo main)
git -C "$d" commit --allow-empty -q -m "base"
git -C "$d" checkout -q -b feat/ff
git -C "$d" commit --allow-empty -q -m "feat: x"
git -C "$d" checkout -q main
git -C "$d" merge --ff-only -q feat/ff
git -C "$d" checkout -q feat/ff
# feat/ff at main's SHA: ahead=0, behind=0 (main FF'd to feat/ff exactly).
is_merged_into_main "$d"; rc=$?
if [ "$rc" -eq 1 ]; then pass "FF-merged + no advance -> false (chosen tradeoff per HIMMEL-114)"; else fail "FF-merged + no advance -> expected 1 (tradeoff) got $rc"; fi
rm -rf "$d"

echo "== is_merged_into_main: HIMMEL-114 fresh branch at main SHA (no unique commits) -> false =="
# Bug repro: a brand-new branch at main's SHA (no divergent commit yet,
# typical of staged-but-uncommitted state) was false-flagged as merged by
# the direct-merge arm because `git branch --merged main` lists every ref
# at main's SHA. Post-fix: ahead=0 short-circuits to return 1 (not merged).
d=$(setup_repo main)
git -C "$d" commit --allow-empty -q -m "base"
git -C "$d" checkout -q -b feat/fresh   # branch is now at main's SHA, ahead=0
is_merged_into_main "$d"; rc=$?
if [ "$rc" -eq 1 ]; then pass "fresh branch at main SHA -> false"; else fail "fresh branch -> expected 1 got $rc"; fi
rm -rf "$d"

echo "== is_merged_into_main: squash-merge arm =="
d=$(setup_repo feat/squashy)
echo a > "$d/a.txt"; git -C "$d" add a.txt; git -C "$d" commit -q -m "feat: a"
git -C "$d" checkout -q main
git -C "$d" merge --squash -q feat/squashy
git -C "$d" commit -q -m "squashed feat/squashy"
git -C "$d" checkout -q feat/squashy
is_merged_into_main "$d"; rc=$?
if [ "$rc" -eq 0 ]; then pass "squash-merged -> true"; else fail "squash-merged -> expected 0 got $rc"; fi
rm -rf "$d"

# HIMMEL-297: master is a protected default too. A repo whose default branch is
# `master` (no `main` ref at all) must resolve default_branch=master, treat
# master as on-main, and use master as the merge/behind base.
setup_master_repo() {
    # $1 = branch name to leave HEAD on
    local dir
    dir="$(mktemp -d)"
    git -C "$dir" init -q -b master
    git -C "$dir" config user.email t@t
    git -C "$dir" config user.name t
    git -C "$dir" commit --allow-empty -q -m "init"
    if [ "$1" != "master" ]; then
        git -C "$dir" checkout -q -b "$1"
    fi
    printf '%s' "$dir"
}

echo "== master-default repo (HIMMEL-297) =="
d=$(setup_master_repo master)
db=$(default_branch "$d")
if [ "$db" = "master" ]; then pass "default_branch -> master"; else fail "default_branch -> expected master got [$db]"; fi
if is_on_main "$d"; then pass "is_on_main on master -> true"; else fail "is_on_main master -> expected 0 got $?"; fi
if is_main_ref refs/heads/master; then pass "is_main_ref master -> true"; else fail "is_main_ref master -> expected 0"; fi
rm -rf "$d"

echo "== is_merged_into_main: master base =="
d=$(setup_master_repo feat/m)
git -C "$d" commit --allow-empty -q -m "feat: m"
git -C "$d" checkout -q master
git -C "$d" merge --no-ff -q feat/m -m "merge"
git -C "$d" checkout -q feat/m
is_merged_into_main "$d"; rc=$?
if [ "$rc" -eq 0 ]; then pass "merged into master -> true"; else fail "merged into master -> expected 0 got $rc"; fi
rm -rf "$d"

d=$(setup_master_repo feat/n)
git -C "$d" commit --allow-empty -q -m "feat: n"
is_merged_into_main "$d"; rc=$?
if [ "$rc" -eq 1 ]; then pass "unmerged (master base) -> false"; else fail "unmerged (master base) -> expected 1 got $rc"; fi
rm -rf "$d"

echo "== is_behind_origin_main: master default =="
# Bare origin whose default is master; clone wires origin/HEAD -> origin/master,
# so default_branch resolves master and the behind check reads origin/master.
origin=$(mktemp -d)
git -C "$origin" init -q --bare -b master
work=$(mktemp -d)
git clone -q "$origin" "$work"
git -C "$work" config user.email t@t
git -C "$work" config user.name t
git -C "$work" commit --allow-empty -q -m "base"
git -C "$work" push -q origin master
git -C "$work" checkout -q -b feat/z
git -C "$work" checkout -q master
git -C "$work" commit --allow-empty -q -m "advance"
git -C "$work" push -q origin master
git -C "$work" checkout -q feat/z
git -C "$work" fetch -q origin
if is_behind_origin_main "$work"; then pass "behind (master default) -> true"; else fail "behind (master default) -> expected 0 got $?"; fi
rm -rf "$work" "$origin"

if [ "$failures" -eq 0 ]; then
    echo "OK: all cases passed"
    exit 0
else
    echo "FAIL: $failures case(s) failed"
    exit 1
fi
