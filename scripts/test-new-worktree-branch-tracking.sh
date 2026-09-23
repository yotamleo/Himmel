#!/usr/bin/env bash
# test-new-worktree-branch-tracking.sh — HIMMEL-3462: a leg's first `git push`
# (no -u, no branch arg) must succeed on a brand-new worktree branch. Builds a
# real origin (second bare repo, not the throwaway no-remote fixture the
# uniqueness suite uses) and a scratch HOME, so `git worktree add -b <branch>
# origin/<default>` and the branch-scoped tracking config it triggers are
# exercised for real, then a bare `git push` is run against that origin.
#
# Self-contained: scratch HOME, scratch origin, no live network. Skips (not
# fails) if the git-config semantics this asserts do not hold in the current
# git build — a version gap is not this fix's regression.
#
# Bash 3.2-safe; shellcheck-clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEW_WT="$SCRIPT_DIR/_new-worktree.sh"

PASS=0
FAIL=0

_pass() { printf 'PASS  %s\n' "$1"; PASS=$(( PASS + 1 )); }
_fail() { printf 'FAIL  %s\n  -> %s\n' "$1" "$2"; FAIL=$(( FAIL + 1 )); }

TMPBASE="${TMPDIR:-/tmp}/test-nwbt-$$"
mkdir -p "$TMPBASE"
# shellcheck disable=SC2064
trap 'rm -rf "$TMPBASE"' EXIT

export HOME="$TMPBASE/home"
mkdir -p "$HOME"
# HOME alone does not isolate git config: XDG and the system file still load,
# and an inherited push.default would fail the "no defaults touched" assertion.
export XDG_CONFIG_HOME="$HOME/.config"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
# An inherited repository env (e.g. when run from a git hook) would point every
# fixture git call, and _new-worktree.sh's primary lookup, at the caller's repo.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
# _new-worktree.sh exports FORGE and GH_CMD into its uniqueness guard, so an
# inherited FORGE=github would make forge_detect reach gh (HIMMEL-3496). Unset
# FORGE, and point GH_CMD at a tripwire that records any call it still gets.
unset FORGE GH_CMD
GH_CALLS="$TMPBASE/gh-calls.log"
GH_CMD="$TMPBASE/gh-tripwire.sh"
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 1\n' "$GH_CALLS" > "$GH_CMD"
chmod +x "$GH_CMD"
export GH_CMD

ORIGIN="$TMPBASE/origin.git"
git init -q --bare "$ORIGIN"

REPO="$TMPBASE/repo"
git clone -q "$ORIGIN" "$REPO"
git -C "$REPO" config user.email "test@test.local"
git -C "$REPO" config user.name "Test"
# Cloning a still-empty origin leaves the local default-branch name whatever
# init.defaultBranch resolves to (main or master, host-dependent) and no
# origin/HEAD symref; force it to 'main' so default_branch() and this push
# agree regardless of the host's git config.
git -C "$REPO" checkout -q -b main
git -C "$REPO" commit -q --allow-empty -m "init"
git -C "$REPO" push -q origin HEAD:main
git -C "$REPO" remote set-head origin main

BRANCH="fix/nwbt-probe"
WT_RELATIVE=".claude/worktrees/${BRANCH//\//+}"
WT_PATH="$REPO/$WT_RELATIVE"

# Run for real: FORGE unset so branch_has_merged_pr's forge_detect sees no
# github remote and the uniqueness guard's gh call is skipped (rc2, WARN-only).
out_f="$TMPBASE/out.txt"
err_f="$TMPBASE/err.txt"
rc=0
( cd "$REPO" && bash "$NEW_WT" "$BRANCH" --no-install ) >"$out_f" 2>"$err_f" || rc=$?

NAME="_new-worktree.sh succeeds against a real origin"
if [ "$rc" -eq 0 ] && [ -d "$WT_PATH" ]; then
    _pass "$NAME"
else
    _fail "$NAME" "rc=$rc stdout=[$(cat "$out_f")] stderr=[$(cat "$err_f")]"
    echo ""
    printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
fi

NAME="the uniqueness guard never reached gh (no live network)"
if [ ! -e "$GH_CALLS" ]; then
    _pass "$NAME"
else
    _fail "$NAME" "gh calls=[$(cat "$GH_CALLS")]"
fi

# Without this, a removed uniqueness guard would pass the no-gh-call check above.
NAME="the uniqueness guard ran and took its fail-open forge-unreachable branch"
if grep -Fq "WARN new-worktree: uniqueness-vs-merged-PR check skipped (forge unreachable)" "$err_f"; then
    _pass "$NAME"
else
    _fail "$NAME" "stderr=[$(cat "$err_f")]"
fi

NAME="new branch's tracking config points at its OWN future remote ref, not origin/<default>"
got_remote="$(git -C "$WT_PATH" config --get "branch.${BRANCH}.remote" || echo '(unset)')"
got_merge="$(git -C "$WT_PATH" config --get "branch.${BRANCH}.merge" || echo '(unset)')"
if [ "$got_remote" = "origin" ] && [ "$got_merge" = "refs/heads/${BRANCH}" ]; then
    _pass "$NAME"
else
    _fail "$NAME" "branch.${BRANCH}.remote=[$got_remote] branch.${BRANCH}.merge=[$got_merge]"
fi

NAME="no repo-wide or global push default was touched"
repo_wide="$(git -C "$WT_PATH" config --get push.autoSetupRemote 2>/dev/null || true)"
repo_default="$(git -C "$WT_PATH" config --get push.default 2>/dev/null || true)"
if [ -z "$repo_wide" ] && [ -z "$repo_default" ]; then
    _pass "$NAME"
else
    _fail "$NAME" "push.autoSetupRemote=[$repo_wide] push.default=[$repo_default]"
fi

NAME="a bare 'git push' (no -u, no refspec) from the new worktree creates the remote branch"
push_rc=0
git -C "$WT_PATH" push >"$TMPBASE/push-out.txt" 2>&1 || push_rc=$?
remote_has_branch=""
remote_has_branch="$(git ls-remote "$ORIGIN" 2>/dev/null | grep -F "refs/heads/${BRANCH}" || true)"
if [ "$push_rc" -eq 0 ] && [ -n "$remote_has_branch" ]; then
    _pass "$NAME"
else
    _fail "$NAME" "push_rc=$push_rc push_out=[$(cat "$TMPBASE/push-out.txt")] remote_has_branch=[$remote_has_branch]"
fi

echo ""
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
