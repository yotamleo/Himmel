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

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/scripts/guardrails/lib.sh"

if [ ! -f "$LIB" ]; then
    echo "FAIL: $LIB not found"
    exit 1
fi

# shellcheck source=/dev/null
. "$LIB"

# shellcheck source=scripts/lib/fixture-tempdir.sh
. "$REPO_ROOT/scripts/lib/fixture-tempdir.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

setup_repo() {
    # $1 = branch name to leave HEAD on
    local dir
    dir="$(fixture_mktemp_dir)" || return 1
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
d=$(setup_repo main) || exit 1
if is_on_main "$d"; then pass "main -> true"; else fail "main -> expected 0 got $?"; fi
rm -rf "$d"

d=$(setup_repo feat/x) || exit 1
if is_on_main "$d"; then fail "feat/x -> expected 1 got 0"; else pass "feat/x -> false"; fi
rm -rf "$d"

echo "== is_dirty =="
d=$(setup_repo feat/x) || exit 1
if is_dirty "$d"; then fail "clean -> expected 1 got 0"; else pass "clean -> false"; fi
echo dirty > "$d/file.txt"
if is_dirty "$d"; then pass "untracked -> true"; else fail "untracked -> expected 0 got $?"; fi
rm -rf "$d"

echo "== is_merged_into_main =="
d=$(setup_repo feat/x) || exit 1
git -C "$d" commit --allow-empty -q -m "feat: x"
git -C "$d" checkout -q main
git -C "$d" merge --no-ff -q feat/x -m "merge"
git -C "$d" checkout -q feat/x
if is_merged_into_main "$d"; then pass "merged -> true"; else fail "merged -> expected 0 got $?"; fi
rm -rf "$d"

d=$(setup_repo feat/y) || exit 1
git -C "$d" commit --allow-empty -q -m "feat: y"
if is_merged_into_main "$d"; then fail "unmerged -> expected 1 got 0"; else pass "unmerged -> false"; fi
rm -rf "$d"

echo "== is_behind_origin_main =="
# Simulate origin via a bare repo + clone
origin=$(fixture_mktemp_dir) || exit 1
git -C "$origin" init -q --bare -b main
work=$(fixture_mktemp_dir) || exit 1
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
d=$(setup_repo feat/x) || exit 1
git -C "$d" commit --allow-empty -q -m "feat"
git -C "$d" branch -D main 2>/dev/null || true
is_merged_into_main "$d"; rc=$?
if [ "$rc" -eq 2 ]; then pass "is_merged_into_main no-main-ref -> rc=2"; else fail "is_merged_into_main no-main-ref -> expected 2 got $rc"; fi
rm -rf "$d"

echo "== detached HEAD =="
d=$(setup_repo feat/x) || exit 1
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
d=$(setup_repo "feat.x") || exit 1
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
d=$(setup_repo main) || exit 1
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

echo "== is_merged_into_main: HIMMEL-1947 FF-merged + main advances after -> false (widened tradeoff) =="
# Pins the WIDENED tradeoff: HIMMEL-114 only pinned FF-merge-no-advance
# (above). HIMMEL-1947 replaced the behind-count check with the
# first-parent-chain check, which extends the same "not merged" tradeoff to
# FF-merged branches where main has since advanced too - an FF-merge creates
# no new commit, so the feature tip stays on main's first-parent chain
# permanently and remains referentially indistinguishable from a fresh
# branch. Not a bug: this is the accepted tradeoff, same as the case above.
# If a future "fix" tries to reinstate FF-merge detection here, this test
# will start failing - that's the signal to re-read the tradeoff (and re-fix
# the fresh-branch regression separately), not to silently delete the case.
d=$(setup_repo main) || exit 1
git -C "$d" commit --allow-empty -q -m "base"
git -C "$d" checkout -q -b feat/ff2
git -C "$d" commit --allow-empty -q -m "feat: x2"
git -C "$d" checkout -q main
git -C "$d" merge --ff-only -q feat/ff2
git -C "$d" commit --allow-empty -q -m "advance 1"
git -C "$d" commit --allow-empty -q -m "advance 2"
git -C "$d" checkout -q feat/ff2
is_merged_into_main "$d"; rc=$?
if [ "$rc" -eq 1 ]; then pass "FF-merged + main advances after -> false (chosen tradeoff per HIMMEL-1947)"; else fail "FF-merged + main advances after -> expected 1 (tradeoff) got $rc"; fi
rm -rf "$d"

echo "== is_merged_into_main: HIMMEL-114 fresh branch at main SHA (no unique commits) -> false =="
# Bug repro: a brand-new branch at main's SHA (no divergent commit yet,
# typical of staged-but-uncommitted state) was false-flagged as merged by
# the direct-merge arm because `git branch --merged main` lists every ref
# at main's SHA. Post-fix: ahead=0 short-circuits to return 1 (not merged).
d=$(setup_repo main) || exit 1
git -C "$d" commit --allow-empty -q -m "base"
git -C "$d" checkout -q -b feat/fresh   # branch is now at main's SHA, ahead=0
is_merged_into_main "$d"; rc=$?
if [ "$rc" -eq 1 ]; then pass "fresh branch at main SHA -> false"; else fail "fresh branch -> expected 1 got $rc"; fi
rm -rf "$d"

echo "== is_merged_into_main: HIMMEL-1947 fresh branch, main advances -> false (regression repro) =="
# Regression repro: a fresh branch with no commits of its own, where main
# advances past the branch point before the branch's first commit. Pre-fix
# this produced ahead=0 + behind>0 and the HIMMEL-114 short-circuit (which
# only caught behind=0) didn't fire, so the direct-merge arm's `git branch
# --merged main` - which lists every ref reachable from main, including
# this still-empty branch - returned 0 (merged): hard-blocking the first
# commit on every fresh worktree branch as soon as main moved.
d=$(setup_repo main) || exit 1
git -C "$d" commit --allow-empty -q -m "base"
git -C "$d" checkout -q -b feat/behind   # branch point, ahead=0
git -C "$d" checkout -q main
git -C "$d" commit --allow-empty -q -m "advance 1"
git -C "$d" commit --allow-empty -q -m "advance 2"
git -C "$d" checkout -q feat/behind
is_merged_into_main "$d"; rc=$?
if [ "$rc" -eq 1 ]; then pass "fresh branch, main advanced -> false (HIMMEL-1947)"; else fail "fresh branch, main advanced -> expected 1 got $rc"; fi
rm -rf "$d"

echo "== is_merged_into_main: HIMMEL-1947 direct merge + main advances further -> true (gate still bites) =="
# Hardens the existing --no-ff merge case against the new short-circuit:
# after a direct merge, main keeps moving, so HEAD (the merge's second
# parent) reads ahead=0 + behind>0 - the same shape as the regression case
# above, but here HEAD is OFF main's first-parent chain, so the
# short-circuit must not fire and the direct-merge arm must still block.
d=$(setup_repo feat/w) || exit 1
git -C "$d" commit --allow-empty -q -m "feat: w"
git -C "$d" checkout -q main
git -C "$d" merge --no-ff -q feat/w -m "merge"
git -C "$d" commit --allow-empty -q -m "advance further"
git -C "$d" checkout -q feat/w
is_merged_into_main "$d"; rc=$?
if [ "$rc" -eq 0 ]; then pass "merged + main advances further -> true"; else fail "merged + main advances further -> expected 0 got $rc"; fi
rm -rf "$d"

echo "== is_merged_into_main: squash-merge arm =="
d=$(setup_repo feat/squashy) || exit 1
echo a > "$d/a.txt"; git -C "$d" add a.txt; git -C "$d" commit -q -m "feat: a"
git -C "$d" checkout -q main
git -C "$d" merge --squash -q feat/squashy
git -C "$d" commit -q -m "squashed feat/squashy"
git -C "$d" checkout -q feat/squashy
is_merged_into_main "$d"; rc=$?
if [ "$rc" -eq 0 ]; then pass "squash-merged -> true"; else fail "squash-merged -> expected 0 got $rc"; fi
rm -rf "$d"

echo "== is_merged_into_main: HIMMEL-2027 large first-parent history (>64 KiB) does not hang =="
# Regression fixture for the here-string wedge: `git rev-list --first-parent
# main` must print more than 64 KiB for the old `grep -qFx -- "$head_sha"
# <<< "$first_parents"` here-string to reproduce the MSYS hang. 1650 lines *
# 41 bytes/line (40-hex SHA1 + newline) = 67650 > 65536. Built via a single
# `git fast-import` call (not 1650 `git commit` forks) to keep the fixture
# cheap on Windows.
big_history_repo() {
    local dir n i
    n="${1:-1650}"
    dir="$(fixture_mktemp_dir)" || return 1
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email t@t
    git -C "$dir" config user.name t
    {
        echo "commit refs/heads/main"
        echo "committer t <t@t> 1600000000 +0000"
        echo "data <<EOMSG"
        echo "init"
        echo "EOMSG"
        for i in $(seq 2 "$n"); do
            echo "commit refs/heads/main"
            echo "committer t <t@t> 1600000000 +0000"
            echo "data <<EOMSG"
            echo "n$i"
            echo "EOMSG"
        done
    } | git -C "$dir" fast-import --quiet
    git -C "$dir" reset --hard -q
    printf '%s' "$dir"
}

d=$(big_history_repo 1650) || exit 1
git -C "$d" checkout -q -b feat/big-fresh   # branch off tip, ahead=0, no commits of its own
# shellcheck disable=SC2016 # $1/$2 are for the inner `bash -c` script, not this shell.
timeout 10 bash -c '. "$1"; is_merged_into_main "$2"' _ "$LIB" "$d"
rc=$?
if [ "$rc" -eq 1 ]; then pass "big-history fresh branch (ahead=0) -> false, no hang"; else fail "big-history fresh branch -> expected 1 got $rc (124 = timed out)"; fi

# Inverse: a branch that IS the second parent of a --no-ff merge on the same
# big-history repo must still be caught by the direct-merge arm.
git -C "$d" checkout -q main
git -C "$d" checkout -q -b feat/big-merged
git -C "$d" commit --allow-empty -q -m "feat: big merged"
git -C "$d" checkout -q main
git -C "$d" merge --no-ff -q feat/big-merged -m "merge"
git -C "$d" checkout -q feat/big-merged
# shellcheck disable=SC2016 # $1/$2 are for the inner `bash -c` script, not this shell.
timeout 10 bash -c '. "$1"; is_merged_into_main "$2"' _ "$LIB" "$d"
rc=$?
if [ "$rc" -eq 0 ]; then pass "big-history direct-merged branch -> true"; else fail "big-history direct-merged branch -> expected 0 got $rc (124 = timed out)"; fi
rm -rf "$d"

# HIMMEL-297: master is a protected default too. A repo whose default branch is
# `master` (no `main` ref at all) must resolve default_branch=master, treat
# master as on-main, and use master as the merge/behind base.
setup_master_repo() {
    # $1 = branch name to leave HEAD on
    local dir
    dir="$(fixture_mktemp_dir)" || return 1
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
d=$(setup_master_repo master) || exit 1
db=$(default_branch "$d")
if [ "$db" = "master" ]; then pass "default_branch -> master"; else fail "default_branch -> expected master got [$db]"; fi
if is_on_main "$d"; then pass "is_on_main on master -> true"; else fail "is_on_main master -> expected 0 got $?"; fi
if is_main_ref refs/heads/master; then pass "is_main_ref master -> true"; else fail "is_main_ref master -> expected 0"; fi
rm -rf "$d"

echo "== is_merged_into_main: master base =="
d=$(setup_master_repo feat/m) || exit 1
git -C "$d" commit --allow-empty -q -m "feat: m"
git -C "$d" checkout -q master
git -C "$d" merge --no-ff -q feat/m -m "merge"
git -C "$d" checkout -q feat/m
is_merged_into_main "$d"; rc=$?
if [ "$rc" -eq 0 ]; then pass "merged into master -> true"; else fail "merged into master -> expected 0 got $rc"; fi
rm -rf "$d"

d=$(setup_master_repo feat/n) || exit 1
git -C "$d" commit --allow-empty -q -m "feat: n"
is_merged_into_main "$d"; rc=$?
if [ "$rc" -eq 1 ]; then pass "unmerged (master base) -> false"; else fail "unmerged (master base) -> expected 1 got $rc"; fi
rm -rf "$d"

echo "== is_behind_origin_main: master default =="
# Bare origin whose default is master; clone wires origin/HEAD -> origin/master,
# so default_branch resolves master and the behind check reads origin/master.
origin=$(fixture_mktemp_dir) || exit 1
git -C "$origin" init -q --bare -b master
work=$(fixture_mktemp_dir) || exit 1
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
d=$(fixture_mktemp_dir) || exit 1
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
td=$(fixture_mktemp_dir) || exit 1; git -C "$td" init -q; : > "$td/.himmel-dev"
if ( cd "$td" && . "$REPO_ROOT/scripts/guardrails/lib.sh" && is_himmel_dev_repo ); then
  pass "is_himmel_dev_repo true when marker present"; else fail "is_himmel_dev_repo true when marker present"; fi
rm -rf "$td"

td=$(fixture_mktemp_dir) || exit 1; git -C "$td" init -q
if ( cd "$td" && . "$REPO_ROOT/scripts/guardrails/lib.sh" && ! is_himmel_dev_repo ); then
  pass "is_himmel_dev_repo false when marker absent"; else fail "is_himmel_dev_repo false when marker absent"; fi
rm -rf "$td"

# Honors the optional DIR arg (called from a DIFFERENT cwd, no cd) like every
# other predicate in this lib.
td=$(fixture_mktemp_dir) || exit 1; git -C "$td" init -q; : > "$td/.himmel-dev"
if is_himmel_dev_repo "$td"; then pass "is_himmel_dev_repo honors DIR arg (marker present)"; else fail "is_himmel_dev_repo honors DIR arg (marker present)"; fi
rm -f "$td/.himmel-dev"
if ! is_himmel_dev_repo "$td"; then pass "is_himmel_dev_repo honors DIR arg (marker absent)"; else fail "is_himmel_dev_repo honors DIR arg (marker absent)"; fi
rm -rf "$td"

# A repo using --separate-git-dir keeps its common git dir outside the checkout.
# The primary worktree entry must still resolve the marker at the checkout root,
# not at the separate git dir's parent.
sep_checkout=$(fixture_mktemp_dir) || exit 1; sep_git_parent=$(fixture_mktemp_dir) || exit 1
git init -q --separate-git-dir="$sep_git_parent/repo.git" "$sep_checkout"
: > "$sep_checkout/.himmel-dev"
if is_himmel_dev_repo "$sep_checkout"; then pass "is_himmel_dev_repo separate git dir -> marker at checkout root"; else fail "is_himmel_dev_repo separate git dir -> expected marker at checkout root"; fi
rm -rf "$sep_checkout" "$sep_git_parent"

# A bare repo has no worktree root, so marker resolution must fail closed even
# when a .himmel-dev file exists in the bare repo's parent directory.
bare_parent=$(fixture_mktemp_dir) || exit 1
bare="$bare_parent/repo.git"
git init --bare -q "$bare"; : > "$bare_parent/.himmel-dev"
is_himmel_dev_repo "$bare"; rc=$?
if [ "$rc" -eq 2 ]; then pass "is_himmel_dev_repo bare repo -> rc=2"; else fail "is_himmel_dev_repo bare repo -> expected 2 got $rc"; fi
rm -rf "$bare_parent"

# HIMMEL-1131: the marker is gitignored and lives ONLY in the primary worktree,
# so detection must resolve it from --git-common-dir, not the current worktree
# root — else every himmel-dev gate silently no-ops inside a worktree (where
# himmel work happens). Prove the gate FIRES from a linked worktree.
td=$(fixture_mktemp_dir) || exit 1; git -C "$td" init -q -b main
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
R=$(fixture_mktemp_dir) || exit 1; git -C "$R" init -q; mkdir -p "$R/docs"; : > "$R/docs/commands-catalog.md"; : > "$R/.pre-commit-config.yaml"
out=$( . "$REPO_ROOT/scripts/guardrails/lib.sh"; warn_doc_guard_off "$R" 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" -i "\.himmel-dev"; then pass "warns when source checkout lacks marker"; else fail "warns when source checkout lacks marker (rc=$rc)"; fi

: > "$R/.himmel-dev"
out=$( . "$REPO_ROOT/scripts/guardrails/lib.sh"; warn_doc_guard_off "$R" 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "silent when marker present"; else fail "silent when marker present (rc=$rc)"; fi
rm -rf "$R"

# The source checkout files live in the linked worktree, but the untracked marker
# lives only in the primary. The warning must use the same common-dir resolution
# as is_himmel_dev_repo instead of falsely reporting that doc-guard is off.
td=$(fixture_mktemp_dir) || exit 1; git -C "$td" init -q -b main
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
if [ "$rc" -eq 0 ] && grepq "$out" -i "\.himmel-dev"; then pass "warns from a worktree when primary marker absent"; else fail "warns from a worktree when primary marker absent (rc=$rc)"; fi
git -C "$td" worktree remove --force "$wtd" 2>/dev/null
rm -rf "$td" "$wtparent"

# ============================================================================
# HIMMEL-2526: guard_canon_path / repo_root_for_path / primary_checkout_root /
# main_checkout_verdict — the shared destination-based write-fence predicate
# family.
#
# FIXTURE RULE: built under the REAL home (a temp dir there), NOT under /tmp
# — a /tmp-rooted fixture is exempted by a downstream temp-path check and
# would make several rows here vacuous or silently green. HOME goes hermetic
# only AFTER the fixture root is captured from the real $HOME.
# ============================================================================
echo "== HIMMEL-2526: guard_canon_path / repo_root_for_path / primary_checkout_root / main_checkout_verdict =="
_REAL_HOME="$HOME"
FIX=$(mktemp -d "${_REAL_HOME}/.himmel-2526-libfix-XXXXXX") || exit 1
trap 'rm -rf "$FIX"' EXIT
export HOME="$FIX/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$FIX/gitconfig"
GITID() { git -c user.email=t@example.invalid -c user.name=t "$@"; }

echo "-- guard_canon_path --"
GC_BASE="$FIX/gc"
mkdir -p "$GC_BASE/a"
GC_BASE_REAL=$(cd "$GC_BASE" && pwd -P)

out=$(guard_canon_path "$GC_BASE/a/../b")
if [ "$out" = "$GC_BASE_REAL/b" ]; then pass "guard_canon_path: <existing>/a/../b collapses -> $GC_BASE_REAL/b"; else fail "guard_canon_path: <existing>/a/../b -> expected $GC_BASE_REAL/b got [$out]"; fi

out=$(guard_canon_path "$GC_BASE/a/no/such/deep")
if [ "$out" = "$GC_BASE_REAL/a/no/such/deep" ]; then pass "guard_canon_path: non-existent tail canonicalises"; else fail "guard_canon_path: non-existent tail -> expected $GC_BASE_REAL/a/no/such/deep got [$out]"; fi

out=$(cd "$GC_BASE" && guard_canon_path "a")
if [ "$out" = "$GC_BASE_REAL/a" ]; then pass "guard_canon_path: relative path resolves against \$PWD"; else fail "guard_canon_path: relative path -> expected $GC_BASE_REAL/a got [$out]"; fi

out=$(guard_canon_path ""); rc=$?
if [ "$rc" -eq 1 ] && [ -z "$out" ]; then pass "guard_canon_path: empty input -> rc=1, no output"; else fail "guard_canon_path: empty input -> expected rc=1+empty got rc=$rc out=[$out]"; fi

# codex-1 (HIMMEL-2526): an EXISTING REGULAR FILE must canonicalise too — the
# walk must pop the file's basename into the tail and cd into its containing
# DIRECTORY, not try (and fail) to cd into the file itself.
touch "$GC_BASE/a/existing-file.txt"
out=$(guard_canon_path "$GC_BASE/a/existing-file.txt" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$GC_BASE_REAL/a/existing-file.txt" ]; then pass "guard_canon_path: EXISTING regular file canonicalises (codex-1, HIMMEL-2526)"; else fail "guard_canon_path: EXISTING regular file -> expected rc=0+$GC_BASE_REAL/a/existing-file.txt got rc=$rc out=[$out]"; fi

# codex-3 (HIMMEL-2526 CR round 3): a symlink at the FINAL path component
# whose target is a regular file (not a directory) must be FOLLOWED to its
# referent — the ancestor walk's `cd`+`pwd -P` only dereferences a symlink
# that resolves to a DIRECTORY; a symlink to a regular file fell out of the
# walk as a plain textual tail component and was returned unresolved,
# letting a worktree symlink pointing at a primary-checkout file read back
# as a worktree-local path.
ln -sf "$GC_BASE_REAL/a/existing-file.txt" "$GC_BASE/a/link-to-file"
out=$(guard_canon_path "$GC_BASE/a/link-to-file" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$GC_BASE_REAL/a/existing-file.txt" ]; then pass "guard_canon_path: final-component symlink resolves to its referent (codex-3, HIMMEL-2526 CR round 3)"; else fail "guard_canon_path: final-component symlink -> expected rc=0+$GC_BASE_REAL/a/existing-file.txt got rc=$rc out=[$out]"; fi

# codex-3 (HIMMEL-2526 CR round 3): a DANGLING symlink (target does not
# exist) must NOT make guard_canon_path return 1 — every caller in this file
# treats rc=1 as "cannot canonicalise" and fails CLOSED on it, so a dangling
# symlink would become a false-positive DENY on an ordinary write.
ln -sf "$GC_BASE/a/does-not-exist.txt" "$GC_BASE/a/dangling-link"
out=$(guard_canon_path "$GC_BASE/a/dangling-link" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] && [ -n "$out" ]; then pass "guard_canon_path: dangling symlink does NOT return 1 (codex-3, HIMMEL-2526 CR round 3)"; else fail "guard_canon_path: dangling symlink -> expected rc=0+non-empty got rc=$rc out=[$out]"; fi

# HIMMEL-2597 (cap raised 8 -> 40): exhausting the depth cap is NOT success.
# A chain of MORE than 40 hops ending at a real file must return rc=1 with NO
# output — printing the still-symlinked head as though fully resolved would
# let an over-cap chain from a worktree into the primary checkout classify as
# worktree-local and be ALLOWED, the exact write this fence exists to refuse.
# 42 hops gives the same +2 margin above the cap the original 10-hop row gave
# above the old cap of 8.
touch "$GC_BASE/a/long-chain-target.txt"
ln -sf "$GC_BASE_REAL/a/long-chain-target.txt" "$GC_BASE/a/long-chain-41"
i=41
while [ "$i" -gt 0 ]; do
    ln -sf "$GC_BASE_REAL/a/long-chain-$i" "$GC_BASE/a/long-chain-$((i-1))"
    i=$((i-1))
done
out=$(guard_canon_path "$GC_BASE/a/long-chain-0" 2>/dev/null); rc=$?
if [ "$rc" -eq 1 ] && [ -z "$out" ]; then pass "guard_canon_path: >40-hop chain -> rc=1, no output (HIMMEL-2597, cap=40, depth-cap exhaustion is not success)"; else fail "guard_canon_path: >40-hop chain -> expected rc=1+empty got rc=$rc out=[$out] (HIMMEL-2597, cap=40)"; fi

# Control (HIMMEL-2597 cap-raise ruling): a ~10-hop chain — RED under the OLD
# cap of 8, but well inside the NEW cap of 40 — must now RESOLVE (rc=0,
# correct referent). This is the whole point of the ruled-on cap raise: a
# legitimate long chain that never leaves the worktree is a false positive
# at cap=8, not a safety win, and must stop being denied at cap=40.
touch "$GC_BASE/a/mid-chain-target.txt"
ln -sf "$GC_BASE_REAL/a/mid-chain-target.txt" "$GC_BASE/a/mid-chain-9"
i=9
while [ "$i" -gt 0 ]; do
    ln -sf "$GC_BASE_REAL/a/mid-chain-$i" "$GC_BASE/a/mid-chain-$((i-1))"
    i=$((i-1))
done
out=$(guard_canon_path "$GC_BASE/a/mid-chain-0" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$GC_BASE_REAL/a/mid-chain-target.txt" ]; then pass "guard_canon_path: a ~10-hop chain now resolves at rc=0 under cap=40 (HIMMEL-2597 cap-raise control; was rc=1 under cap=8)"; else fail "guard_canon_path: ~10-hop chain -> expected rc=0+$GC_BASE_REAL/a/mid-chain-target.txt got rc=$rc out=[$out] (HIMMEL-2597 cap-raise control)"; fi

# Control: a SHORT chain (2 hops) well inside the cap must still resolve to
# the final referent at rc=0 — the task-1 fix must not touch the ordinary,
# well-inside-budget case.
touch "$GC_BASE/a/short-chain-target.txt"
ln -sf "$GC_BASE_REAL/a/short-chain-target.txt" "$GC_BASE/a/short-chain-1"
ln -sf "$GC_BASE_REAL/a/short-chain-1" "$GC_BASE/a/short-chain-0"
out=$(guard_canon_path "$GC_BASE/a/short-chain-0" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$GC_BASE_REAL/a/short-chain-target.txt" ]; then pass "guard_canon_path: a short (2-hop) chain still resolves to its referent at rc=0 (HIMMEL-2597 control)"; else fail "guard_canon_path: short chain -> expected rc=0+$GC_BASE_REAL/a/short-chain-target.txt got rc=$rc out=[$out] (HIMMEL-2597 control)"; fi

# codex-3 (HIMMEL-2526 CR round 3) / HIMMEL-2597: a symlink LOOP (A -> B -> A)
# must terminate rather than hang the hook — the depth cap (40, raised from
# the original 8) must fire, and the call must FAIL CLOSED (rc=1, no output):
# the capped walk never settles on a non-symlink, so printing its last
# landing spot as though resolved would be exactly the exhaustion-is-not
# -success bug HIMMEL-2597 fixes. Raising the cap does not weaken this row —
# a genuine A<->B cycle never resolves no matter how many hops are allowed,
# so it still exhausts whatever the cap is and still denies; only the
# iteration count before it fires changes. Run under `timeout` in a fresh
# subshell so a regression that reintroduces an unbounded chase fails this
# row with a clearly-distinguished timeout message instead of wedging the
# whole suite or being conflated with an ordinary non-zero failure.
if ! command -v timeout >/dev/null 2>&1; then
    echo "  SKIP guard_canon_path symlink-loop row: 'timeout' not on PATH"
else
    ln -sf "$GC_BASE/a/loop-b" "$GC_BASE/a/loop-a"
    ln -sf "$GC_BASE/a/loop-a" "$GC_BASE/a/loop-b"
    out=$(timeout 5 bash -c ". \"$LIB\"; guard_canon_path \"$GC_BASE/a/loop-a\"" 2>/dev/null); rc=$?  # gnu-ok: timeout needed to bound symlink loop; matches pre-existing bare timeout at lines 289, 302 (no _TIMEOUT_BIN resolver exists)
    if [ "$rc" -eq 124 ]; then
        fail "guard_canon_path: symlink loop -> timed out (rc=124), depth cap did not fire"
    elif [ "$rc" -eq 1 ] && [ -z "$out" ]; then
        pass "guard_canon_path: a symlink loop terminates via the depth cap and fails CLOSED, rc=1+no output (HIMMEL-2597 task 1; was rc=0+non-empty pre-fix)"
    else
        fail "guard_canon_path: symlink loop -> expected rc=1+empty got rc=$rc out=[$out] (HIMMEL-2597 task 1)"
    fi
fi

# HIMMEL-2597 task 2: a link whose referent sits inside a symlinked
# DIRECTORY must have that ancestor physically re-canonicalised — not just
# the original call's own ancestor prefix. Two hops max (well inside the
# depth-40 budget), so a pass here cannot be masked by the depth cap.
mkdir -p "$GC_BASE/a/symdir-real"
touch "$GC_BASE/a/symdir-real/target.txt"
ln -sf "$GC_BASE_REAL/a/symdir-real" "$GC_BASE/a/symdir-alias"
ln -sf "$GC_BASE_REAL/a/symdir-alias/target.txt" "$GC_BASE/a/link-through-symdir"
out=$(guard_canon_path "$GC_BASE/a/link-through-symdir" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$GC_BASE_REAL/a/symdir-real/target.txt" ]; then pass "guard_canon_path: a hop through a symlinked ANCESTOR directory is physically resolved (HIMMEL-2597 task 2)"; else fail "guard_canon_path: hop through symlinked ancestor -> expected rc=0+$GC_BASE_REAL/a/symdir-real/target.txt (real dir, not the alias) got rc=$rc out=[$out] (HIMMEL-2597 task 2)"; fi

# HIMMEL-2597 (per-hop ancestor fix, RED row): the per-hop step must resolve
# the LONGEST existing ancestor, not just try the referent's IMMEDIATE
# parent directory. `deep-missing -> alias-to-primary/missing-dir/f.txt`
# where `missing-dir` does not exist: the immediate parent
# (alias-to-primary/missing-dir) can't be `cd`'d into, so a resolver that
# only tries that one directory keeps the WHOLE path textual — including the
# `alias-to-primary` symlinked ancestor, which then never gets dereferenced.
# The correct result climbs past `missing-dir/f.txt` (neither exists yet)
# and physically resolves `alias-to-primary` itself.
mkdir -p "$GC_BASE/a/deep-primary"
ln -sf "$GC_BASE_REAL/a/deep-primary" "$GC_BASE/a/alias-to-deep-primary"
ln -sf "$GC_BASE_REAL/a/alias-to-deep-primary/missing-dir/f.txt" "$GC_BASE/a/deep-missing"
out=$(guard_canon_path "$GC_BASE/a/deep-missing" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$GC_BASE_REAL/a/deep-primary/missing-dir/f.txt" ]; then pass "guard_canon_path: a hop with a non-existent tail still resolves its symlinked ANCESTOR, not just the immediate parent (HIMMEL-2597 per-hop ancestor fix)"; else fail "guard_canon_path: hop with non-existent tail -> expected rc=0+$GC_BASE_REAL/a/deep-primary/missing-dir/f.txt (real dir, not the alias) got rc=$rc out=[$out] (HIMMEL-2597 per-hop ancestor fix)"; fi

# HIMMEL-2597 task 3: guard_canon_path_nofollow must return the directory
# ENTRY's own canonical path (preserving its name) on a final-component
# symlink, while guard_canon_path on the SAME input still dereferences to the
# referent — assert both in the same block so the pair is the assertion.
# Matrix over BOTH link kinds: a pair that only covered a FILE symlink is
# what let the directory-symlink case (below) through — `-d` FOLLOWS a
# symlink, so a directory symlink never fell into the ancestor walk's own
# not-a-directory pop the way a file symlink does, and nofollow silently
# dereferenced it. `rm <primary>/dirlink -> <worktree>/dir` is the directory
# twin of the file case: unlinking the ENTRY, not its referent.

# 3a. file symlink (the pair as originally landed).
out_follow=$(guard_canon_path "$GC_BASE/a/link-to-file" 2>/dev/null); rc_follow=$?
out_nofollow=$(guard_canon_path_nofollow "$GC_BASE/a/link-to-file" 2>/dev/null); rc_nofollow=$?
if [ "$rc_follow" -eq 0 ] && [ "$out_follow" = "$GC_BASE_REAL/a/existing-file.txt" ] \
   && [ "$rc_nofollow" -eq 0 ] && [ "$out_nofollow" = "$GC_BASE_REAL/a/link-to-file" ]; then
    pass "guard_canon_path follows / guard_canon_path_nofollow does not, on a FILE symlink (HIMMEL-2597 task 3a)"
else
    fail "guard_canon_path/guard_canon_path_nofollow pair (file symlink) -> expected follow=rc0:$GC_BASE_REAL/a/existing-file.txt nofollow=rc0:$GC_BASE_REAL/a/link-to-file, got follow=rc$rc_follow:[$out_follow] nofollow=rc$rc_nofollow:[$out_nofollow] (HIMMEL-2597 task 3a)"
fi

# 3b. RED row: DIRECTORY symlink — same pair, over a symlink whose target is
# a directory rather than a file.
mkdir -p "$GC_BASE/a/nf-realdir"
ln -sf "$GC_BASE_REAL/a/nf-realdir" "$GC_BASE/a/nf-dirlink"
out_follow=$(guard_canon_path "$GC_BASE/a/nf-dirlink" 2>/dev/null); rc_follow=$?
out_nofollow=$(guard_canon_path_nofollow "$GC_BASE/a/nf-dirlink" 2>/dev/null); rc_nofollow=$?
if [ "$rc_follow" -eq 0 ] && [ "$out_follow" = "$GC_BASE_REAL/a/nf-realdir" ] \
   && [ "$rc_nofollow" -eq 0 ] && [ "$out_nofollow" = "$GC_BASE_REAL/a/nf-dirlink" ]; then
    pass "guard_canon_path follows / guard_canon_path_nofollow does not, on a DIRECTORY symlink (HIMMEL-2597 task 3b)"
else
    fail "guard_canon_path/guard_canon_path_nofollow pair (DIRECTORY symlink) -> expected follow=rc0:$GC_BASE_REAL/a/nf-realdir nofollow=rc0:$GC_BASE_REAL/a/nf-dirlink, got follow=rc$rc_follow:[$out_follow] nofollow=rc$rc_nofollow:[$out_nofollow] (HIMMEL-2597 task 3b)"
fi

# 3c. trailing-slash carve-out: `dirlink/` forces directory resolution at the
# shell/kernel level (`[ -L "dirlink/" ]` is false even though `[ -L "dirlink" ]`
# is true) — nofollow must NOT special-case this form; it stays FOLLOW.
out_nofollow=$(guard_canon_path_nofollow "$GC_BASE/a/nf-dirlink/" 2>/dev/null); rc_nofollow=$?
if [ "$rc_nofollow" -eq 0 ] && [ "$out_nofollow" = "$GC_BASE_REAL/a/nf-realdir" ]; then
    pass "guard_canon_path_nofollow: a trailing-slash directory-symlink path still FOLLOWs (HIMMEL-2597 task 3c)"
else
    fail "guard_canon_path_nofollow: trailing-slash form -> expected rc=0+$GC_BASE_REAL/a/nf-realdir got rc=$rc_nofollow out=[$out_nofollow] (HIMMEL-2597 task 3c)"
fi

# 3d. nofollow entry reached through a symlinked ANCESTOR directory: the
# entry's own name must be preserved (not dereferenced) while its ancestor
# IS physically resolved — reuses the symdir-alias/symdir-real fixture from
# task 2.
ln -sf "$GC_BASE_REAL/a/symdir-real/target.txt" "$GC_BASE/a/symdir-real/entry-link"
out_nofollow=$(guard_canon_path_nofollow "$GC_BASE/a/symdir-alias/entry-link" 2>/dev/null); rc_nofollow=$?
if [ "$rc_nofollow" -eq 0 ] && [ "$out_nofollow" = "$GC_BASE_REAL/a/symdir-real/entry-link" ]; then
    pass "guard_canon_path_nofollow: entry name preserved, ANCESTOR physically resolved through a symlinked directory (HIMMEL-2597 task 3d)"
else
    fail "guard_canon_path_nofollow: entry through symlinked ancestor -> expected rc=0+$GC_BASE_REAL/a/symdir-real/entry-link (real ancestor, entry name kept) got rc=$rc_nofollow out=[$out_nofollow] (HIMMEL-2597 task 3d)"
fi

# codex-7 (HIMMEL-2526): a Windows drive-absolute path (C:/...) must be
# recognised as ALREADY absolute, matching block-write-into-main-checkout.sh's
# own _bwimc_resolve_abs — otherwise it gets prefixed with $PWD, resolving a
# DIFFERENT location on Git Bash. Real Git-Bash `cd`/`pwd -P` semantics for a
# drive letter are UNVERIFIED on this Linux station; this row only asserts the
# $PWD-prefix bug is gone, not full Windows-correct resolution.
#
# codex-5 (HIMMEL-2526 CR round 3): the property this row wants is "not
# $PWD-prefixed", NOT "does not start with /". On a REAL Git Bash where the
# `C:/win-repo` ancestor actually EXISTS, `cd "C:/win-repo" && pwd -P`
# correctly resolves through MSYS's own drive-letter translation to
# `/c/win-repo` — a path that legitimately starts with `/` for entirely
# correct reasons unrelated to the $PWD-prefix bug this row exists to catch.
# The OLD `case "$out" in /*) fail` assertion would have flagged that CORRECT
# resolution as broken, making this suite RED on Git Bash for behaviour that
# is right. Assert against $PWD directly instead: the bug this row guards
# against is `path="$PWD/$path"` when the drive-absolute case is not
# recognised, so the only thing that must never happen is the output being
# rooted under this process's own $PWD.
out=$(guard_canon_path "C:/win-repo/file.txt" 2>/dev/null); rc=$?
case "$out" in
    "$PWD"|"$PWD"/*) fail "guard_canon_path: Windows drive path -> got \$PWD-prefixed [$out] (codex-7, HIMMEL-2526)" ;;
    *) if [ "$rc" -eq 0 ] && [ -n "$out" ]; then pass "guard_canon_path: Windows drive path C:/... is not \$PWD-prefixed (codex-7/codex-5, HIMMEL-2526; real Git-Bash cd semantics — e.g. resolving through pwd -P to /c/win-repo — remain unverified on this Linux station, but are NOT flagged as a false failure here)"; else fail "guard_canon_path: Windows drive path -> expected non-empty output at rc=0, got rc=$rc out=[$out] (codex-7)"; fi ;;
esac

echo "-- repo_root_for_path --"
RR_REPO="$FIX/rr-repo"
mkdir -p "$RR_REPO/sub"
git -C "$RR_REPO" init -q -b main
GITID -C "$RR_REPO" commit -q --allow-empty -m init
: > "$RR_REPO/sub/file.txt"

out=$(repo_root_for_path "$RR_REPO/sub/file.txt")
if [ "$out" = "$RR_REPO" ]; then pass "repo_root_for_path: from a file inside a repo"; else fail "repo_root_for_path: file inside repo -> expected $RR_REPO got [$out]"; fi

out=$(repo_root_for_path "$RR_REPO/newdir/deep/notyet.txt")
if [ "$out" = "$RR_REPO" ]; then pass "repo_root_for_path: not-yet-created file, missing parent dirs"; else fail "repo_root_for_path: not-yet-created file -> expected $RR_REPO got [$out]"; fi

out=$(repo_root_for_path "$RR_REPO")
if [ "$out" = "$RR_REPO" ]; then pass "repo_root_for_path: the repo DIRECTORY itself (cp x <primary> shape)"; else fail "repo_root_for_path: repo directory itself -> expected $RR_REPO got [$out]"; fi

repo_root_for_path "$HOME/nowhere/file.txt"; rc=$?
if [ "$rc" -eq 1 ]; then pass "repo_root_for_path: path in no repo -> rc=1"; else fail "repo_root_for_path: no repo -> expected rc=1 got $rc"; fi

echo "-- primary_checkout_root --"
PC_PRIMARY="$FIX/pc-primary"
mkdir -p "$PC_PRIMARY"
git -C "$PC_PRIMARY" init -q -b main
GITID -C "$PC_PRIMARY" commit -q --allow-empty -m init
git -C "$PC_PRIMARY" branch -q feat/x
PC_PRIMARY_REAL=$(cd "$PC_PRIMARY" && pwd -P)
PC_WT="$FIX/pc-wt"
git -C "$PC_PRIMARY" worktree add -q "$PC_WT" feat/x

out=$(primary_checkout_root "$PC_PRIMARY")
if [ "$out" = "$PC_PRIMARY_REAL" ]; then pass "primary_checkout_root: from the primary"; else fail "primary_checkout_root: primary -> expected $PC_PRIMARY_REAL got [$out]"; fi

out=$(primary_checkout_root "$PC_WT")
if [ "$out" = "$PC_PRIMARY_REAL" ]; then pass "primary_checkout_root: from a LINKED WORKTREE -> echoes the primary"; else fail "primary_checkout_root: linked worktree -> expected primary $PC_PRIMARY_REAL got [$out]"; fi

SEP_CHECKOUT="$FIX/pc-sep-checkout"
SEP_GITDIR_PARENT="$FIX/pc-sep-gitdir-parent"
mkdir -p "$SEP_GITDIR_PARENT"
git init -q --separate-git-dir="$SEP_GITDIR_PARENT/repo.git" "$SEP_CHECKOUT"
GITID -C "$SEP_CHECKOUT" commit -q --allow-empty -m init
SEP_CHECKOUT_REAL=$(cd "$SEP_CHECKOUT" && pwd -P)

out=$(primary_checkout_root "$SEP_CHECKOUT")
if [ "$out" = "$SEP_CHECKOUT_REAL" ]; then pass "primary_checkout_root: --separate-git-dir -> echoes the checkout, not dirname(common_dir)"; else fail "primary_checkout_root: --separate-git-dir -> expected checkout $SEP_CHECKOUT_REAL got [$out]"; fi

mkdir -p "$FIX/pc-none"
primary_checkout_root "$FIX/pc-none"; rc=$?
if [ "$rc" -eq 1 ]; then pass "primary_checkout_root: non-repo -> rc=1"; else fail "primary_checkout_root: non-repo -> expected rc=1 got $rc"; fi

echo "-- main_checkout_verdict --"
MV_MAIN="$FIX/mv-main"
mkdir -p "$MV_MAIN"
git -C "$MV_MAIN" init -q -b main
printf 'A\n' > "$MV_MAIN/a.txt"
git -C "$MV_MAIN" add a.txt
GITID -C "$MV_MAIN" commit -q -m init
MV_MAIN_C=$(cd "$MV_MAIN" && pwd -P)
# Ignore patterns for the untracked+gitignored rows below (info/exclude, so no
# tracked .gitignore is needed).
# mkdir -p guard: this append is otherwise silently dependent on `git init`
# having populated the template with info/exclude already in place — under an
# empty GIT_TEMPLATE_DIR (or, apparently, some other as-yet-unidentified
# condition seen once under a ~200-suite load run) `git init` does NOT create
# .git/info/, and the bare `>>` then fails ENOENT, turning this row from
# meaningful into a hard failure rather than a vacuous pass.
mkdir -p "$MV_MAIN/.git/info"
printf 'ignored.local\n.env\n.single-writer\n' >> "$MV_MAIN/.git/info/exclude"
if git -C "$MV_MAIN" check-ignore -q -- .single-writer; then
    pass "main_checkout_verdict fixture: .single-writer is ignored in mv-main"
else
    fail "main_checkout_verdict fixture: .single-writer NOT ignored in mv-main — row would be vacuous"
fi

out=$(main_checkout_verdict "$MV_MAIN_C/a.txt"); rc=$?
if [ "$rc" -eq 1 ] && [ "$out" = "$MV_MAIN_C" ]; then pass "main_checkout_verdict: on-main tracked target -> rc=1"; else fail "main_checkout_verdict: on-main -> expected rc=1+$MV_MAIN_C got rc=$rc out=[$out]"; fi

MV_PRIMFEAT="$FIX/mv-primfeat"
mkdir -p "$MV_PRIMFEAT"
git -C "$MV_PRIMFEAT" init -q -b main
GITID -C "$MV_PRIMFEAT" commit -q --allow-empty -m init
git -C "$MV_PRIMFEAT" checkout -q -b feat/y
MV_PRIMFEAT_C=$(cd "$MV_PRIMFEAT" && pwd -P)

out=$(main_checkout_verdict "$MV_PRIMFEAT_C/newfile.txt"); rc=$?
if [ "$rc" -eq 2 ] && [ "$out" = "$MV_PRIMFEAT_C" ]; then pass "main_checkout_verdict: primary-checkout-on-feature-branch target -> rc=2"; else fail "main_checkout_verdict: primary-feature -> expected rc=2+$MV_PRIMFEAT_C got rc=$rc out=[$out]"; fi

git -C "$MV_MAIN" branch -q feat/wt
MV_WT="$FIX/mv-wt"
git -C "$MV_MAIN" worktree add -q "$MV_WT" feat/wt
MV_WT_C=$(cd "$MV_WT" && pwd -P)

out=$(main_checkout_verdict "$MV_WT_C/newfile.txt"); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$MV_WT_C" ]; then pass "main_checkout_verdict: linked-worktree target -> rc=0"; else fail "main_checkout_verdict: linked worktree -> expected rc=0+$MV_WT_C got rc=$rc out=[$out]"; fi

out=$(main_checkout_verdict "$MV_MAIN_C/handovers/x.md"); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$MV_MAIN_C" ]; then pass "main_checkout_verdict: <repo>/handovers/x.md on main -> rc=0"; else fail "main_checkout_verdict: handovers carve-out -> expected rc=0+$MV_MAIN_C got rc=$rc out=[$out]"; fi

out=$(main_checkout_verdict "$MV_MAIN_C/ignored.local"); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$MV_MAIN_C" ]; then pass "main_checkout_verdict: untracked+gitignored file on main -> rc=0"; else fail "main_checkout_verdict: untracked+gitignored -> expected rc=0+$MV_MAIN_C got rc=$rc out=[$out]"; fi

out=$(main_checkout_verdict "$MV_MAIN_C/.env"); rc=$?
if [ "$rc" -eq 1 ] && [ "$out" = "$MV_MAIN_C" ]; then pass "main_checkout_verdict: secret-class basename (.env) untracked+gitignored on main -> rc=1 (stays denied)"; else fail "main_checkout_verdict: secret .env -> expected rc=1+$MV_MAIN_C got rc=$rc out=[$out]"; fi

out=$(main_checkout_verdict "$MV_MAIN_C/.single-writer"); rc=$?
if [ "$rc" -eq 1 ] && [ "$out" = "$MV_MAIN_C" ]; then pass "main_checkout_verdict: .single-writer untracked+gitignored on main -> rc=1 (NEW carve-out, HIMMEL-2526)"; else fail "main_checkout_verdict: .single-writer target -> expected rc=1+$MV_MAIN_C got rc=$rc out=[$out]"; fi

out=$(EDIT_ON_MAIN_OK=1 main_checkout_verdict "$MV_MAIN_C/a.txt"); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$MV_MAIN_C" ]; then pass "main_checkout_verdict: EDIT_ON_MAIN_OK=1 -> rc=0"; else fail "main_checkout_verdict: EDIT_ON_MAIN_OK=1 -> expected rc=0+$MV_MAIN_C got rc=$rc out=[$out]"; fi

MV_SW="$FIX/mv-singlewriter"
mkdir -p "$MV_SW"
git -C "$MV_SW" init -q -b main
GITID -C "$MV_SW" commit -q --allow-empty -m init
: > "$MV_SW/.single-writer"
MV_SW_C=$(cd "$MV_SW" && pwd -P)

out=$(main_checkout_verdict "$MV_SW_C/other.txt"); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$MV_SW_C" ]; then pass "main_checkout_verdict: repo carrying a .single-writer marker -> rc=0"; else fail "main_checkout_verdict: .single-writer marker repo -> expected rc=0+$MV_SW_C got rc=$rc out=[$out]"; fi

out=$(main_checkout_verdict "$HOME/nowhere/file.txt"); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "main_checkout_verdict: path in no repo -> rc=0, no output"; else fail "main_checkout_verdict: no repo -> expected rc=0+empty got rc=$rc out=[$out]"; fi

git -C "$MV_MAIN" worktree remove --force "$MV_WT" 2>/dev/null || true
git -C "$PC_PRIMARY" worktree remove --force "$PC_WT" 2>/dev/null || true
rm -rf "$FIX"
trap - EXIT
export HOME="$_REAL_HOME"
unset GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL

if [ "$failures" -eq 0 ]; then
    echo "OK: all cases passed"
    exit 0
else
    echo "FAIL: $failures case(s) failed"
    exit 1
fi
