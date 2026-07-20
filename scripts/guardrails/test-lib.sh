#!/usr/bin/env bash
# Smoke test for scripts/guardrails/lib.sh.
#
# Builds throwaway git repos, exercises each predicate, asserts rc.
# Usage: bash scripts/guardrails/test-lib.sh
#
# Exit 0 if all cases pass, 1 otherwise.
#
# The linter cannot follow lib.sh when only this file is passed as input (the
# test sources it dynamically via $REPO_ROOT / inside subshells, and the
# pre-commit hook lints just the single changed file). SC1091 is info-only, so
# disable it file-wide (directive must precede the first command) to keep a
# test-only commit from being blocked.
# shellcheck disable=SC1091
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

echo "== default_branch: both local main+master, origin/HEAD unset -> main + stderr ambiguity note (HIMMEL-323) =="
# A repo with NO remote (so origin/HEAD is unset) that has BOTH local main and
# master. The local-ref order returns main, but silently — HIMMEL-323 adds a
# stderr ambiguity note so the wrong-on-a-master-default-mirror guess is visible.
d=$(mktemp -d)
git -C "$d" init -q -b main
git -C "$d" config user.email t@t
git -C "$d" config user.name t
git -C "$d" commit --allow-empty -q -m "init"
git -C "$d" branch master   # both refs/heads/main and refs/heads/master now exist
errf=$(mktemp)
db_out=$(default_branch "$d" 2>"$errf")
db_err=$(cat "$errf"); rm -f "$errf"
if [ "$db_out" = "main" ]; then pass "ambiguous main+master -> stdout 'main' (stable default)"; else fail "ambiguous main+master -> expected stdout 'main' got [$db_out]"; fi
case "$db_err" in
    *"both local 'main' and 'master' exist"*) pass "ambiguous main+master -> stderr ambiguity note emitted (no longer silent)" ;;
    *) fail "ambiguous main+master -> expected stderr ambiguity note, got [$db_err]" ;;
esac
# Counter-case: only one default-candidate ref present -> NO note (no ambiguity).
git -C "$d" branch -D master >/dev/null 2>&1
errf=$(mktemp)
db_out=$(default_branch "$d" 2>"$errf")
db_err=$(cat "$errf"); rm -f "$errf"
if [ "$db_out" = "main" ] && [ -z "$db_err" ]; then pass "single default-candidate -> 'main', no ambiguity note"; else fail "single default-candidate -> expected 'main' + no note, got out=[$db_out] err=[$db_err]"; fi
rm -rf "$d"

echo "== is_himmel_dev_repo =="
td=$(mktemp -d); git -C "$td" init -q; : > "$td/.himmel-dev"
if ( cd "$td" && . "$REPO_ROOT/scripts/guardrails/lib.sh" && is_himmel_dev_repo ); then
  pass "is_himmel_dev_repo true when marker present"; else fail "is_himmel_dev_repo true when marker present"; fi
rm -rf "$td"

td=$(mktemp -d); git -C "$td" init -q
if ( cd "$td" && . "$REPO_ROOT/scripts/guardrails/lib.sh" && ! is_himmel_dev_repo ); then
  pass "is_himmel_dev_repo false when marker absent"; else fail "is_himmel_dev_repo false when marker absent"; fi
rm -rf "$td"

# Honors the optional DIR arg (called from a DIFFERENT cwd, no cd) like every
# other predicate in this lib.
td=$(mktemp -d); git -C "$td" init -q; : > "$td/.himmel-dev"
if is_himmel_dev_repo "$td"; then pass "is_himmel_dev_repo honors DIR arg (marker present)"; else fail "is_himmel_dev_repo honors DIR arg (marker present)"; fi
rm -f "$td/.himmel-dev"
if ! is_himmel_dev_repo "$td"; then pass "is_himmel_dev_repo honors DIR arg (marker absent)"; else fail "is_himmel_dev_repo honors DIR arg (marker absent)"; fi
rm -rf "$td"

# A repo using --separate-git-dir keeps its common git dir outside the checkout.
# The primary worktree entry must still resolve the marker at the checkout root,
# not at the separate git dir's parent.
sep_checkout=$(mktemp -d); sep_git_parent=$(mktemp -d)
git init -q --separate-git-dir="$sep_git_parent/repo.git" "$sep_checkout"
: > "$sep_checkout/.himmel-dev"
if is_himmel_dev_repo "$sep_checkout"; then pass "is_himmel_dev_repo separate git dir -> marker at checkout root"; else fail "is_himmel_dev_repo separate git dir -> expected marker at checkout root"; fi
rm -rf "$sep_checkout" "$sep_git_parent"

# A bare repo has no worktree root, so marker resolution must fail closed even
# when a .himmel-dev file exists in the bare repo's parent directory.
bare=$(mktemp -d)/repo.git; git init --bare -q "$bare"; : > "$(dirname "$bare")/.himmel-dev"
is_himmel_dev_repo "$bare"; rc=$?
if [ "$rc" -eq 2 ]; then pass "is_himmel_dev_repo bare repo -> rc=2"; else fail "is_himmel_dev_repo bare repo -> expected 2 got $rc"; fi
rm -rf "$(dirname "$bare")"

# HIMMEL-1131: the marker is gitignored and lives ONLY in the primary worktree,
# so detection must resolve it from --git-common-dir, not the current worktree
# root — else every himmel-dev gate silently no-ops inside a worktree (where
# himmel work happens). Prove the gate FIRES from a linked worktree.
td=$(mktemp -d); git -C "$td" init -q -b main
git -C "$td" config user.email t@t; git -C "$td" config user.name t
git -C "$td" commit --allow-empty -q -m init
: > "$td/.himmel-dev"
wtparent=$(mktemp -d); wtd="$wtparent/wt"
git -C "$td" worktree add -q "$wtd" -b wt-branch
if ( cd "$wtd" && . "$REPO_ROOT/scripts/guardrails/lib.sh" && is_himmel_dev_repo ); then
  pass "is_himmel_dev_repo true from a worktree (marker on primary)"; else fail "is_himmel_dev_repo true from a worktree (marker on primary)"; fi
# No false positive: marker removed from primary -> false from the worktree too.
rm -f "$td/.himmel-dev"
if ( cd "$wtd" && . "$REPO_ROOT/scripts/guardrails/lib.sh" && ! is_himmel_dev_repo ); then
  pass "is_himmel_dev_repo false from a worktree when primary marker absent"; else fail "is_himmel_dev_repo false from a worktree when primary marker absent"; fi
git -C "$td" worktree remove --force "$wtd" 2>/dev/null
rm -rf "$td" "$wtparent"

echo "== warn_doc_guard_off =="
R=$(mktemp -d); git -C "$R" init -q; mkdir -p "$R/docs"; : > "$R/docs/commands-catalog.md"; : > "$R/.pre-commit-config.yaml"
out=$( . "$REPO_ROOT/scripts/guardrails/lib.sh"; warn_doc_guard_off "$R" 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi "\.himmel-dev"; then pass "warns when source checkout lacks marker"; else fail "warns when source checkout lacks marker (rc=$rc)"; fi

: > "$R/.himmel-dev"
out=$( . "$REPO_ROOT/scripts/guardrails/lib.sh"; warn_doc_guard_off "$R" 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "silent when marker present"; else fail "silent when marker present (rc=$rc)"; fi
rm -rf "$R"

# The source checkout files live in the linked worktree, but the untracked marker
# lives only in the primary. The warning must use the same common-dir resolution
# as is_himmel_dev_repo instead of falsely reporting that doc-guard is off.
td=$(mktemp -d); git -C "$td" init -q -b main
git -C "$td" config user.email t@t; git -C "$td" config user.name t
mkdir -p "$td/docs"; : > "$td/docs/commands-catalog.md"; : > "$td/.pre-commit-config.yaml"
git -C "$td" add docs/commands-catalog.md .pre-commit-config.yaml
git -C "$td" commit -q -m init
: > "$td/.himmel-dev"
wtparent=$(mktemp -d); wtd="$wtparent/wt"
git -C "$td" worktree add -q "$wtd" -b warn-wt-branch
out=$( . "$REPO_ROOT/scripts/guardrails/lib.sh"; warn_doc_guard_off "$wtd" 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "silent from a worktree when marker is on primary"; else fail "silent from a worktree when marker is on primary (rc=$rc)"; fi
rm -f "$td/.himmel-dev"
out=$( . "$REPO_ROOT/scripts/guardrails/lib.sh"; warn_doc_guard_off "$wtd" 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi "\.himmel-dev"; then pass "warns from a worktree when primary marker absent"; else fail "warns from a worktree when primary marker absent (rc=$rc)"; fi
git -C "$td" worktree remove --force "$wtd" 2>/dev/null
rm -rf "$td" "$wtparent"

if [ "$failures" -eq 0 ]; then
    echo "OK: all cases passed"
    exit 0
else
    echo "FAIL: $failures case(s) failed"
    exit 1
fi
