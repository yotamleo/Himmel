#!/usr/bin/env bash
# PreToolUse Bash guard for /pr-check step 0's bare literal (HIMMEL-3383).
#
# HIMMEL-3359 (#1052) allow-listed the exact literal
#
#     bash scripts/cr/pr-check-context.sh
#
# for every leg profile (`gateAllow` in scripts/lanes/plugin-profiles.json).
# The runbook twins permit that spelling only when three conditions hold:
#
#   1. the himmel lane - the cwd's git-common-dir is "$HIMMEL_REPO/.git";
#   2. the cwd is the worktree root - `git rev-parse --show-prefix` is empty
#      (from a subdirectory the relative path names a local file there);
#   3. the working tree has no change vs refs/remotes/origin/main under
#      scripts/cr/ or in scripts/guardrails/lib.sh (the bytes step 0 runs).
#
# The allow rule matches the TEXT regardless, so a leg that skipped or misread
# the runbook check auto-ran the branch copy - and a branch that edits
# pr-check-context.sh itself controls the bytes that run before the script's
# own hand-off to the anchor. This hook re-checks the three conditions at match
# time: all hold -> exit 0 silently (the permission rules decide as before);
# any fails, or cannot be evaluated -> exit 2, naming the canonical anchored
# fence as the remedy. It never emits an allow decision of its own, so it can
# only narrow what the permission layer would do.
#
# SELF-CONTAINED BY DESIGN: this file sources and execs nothing from the
# checkout under review - no scripts/guardrails/lib.sh, no scripts/cr/*. Its
# own bytes are the project hook path run-hook-with-bash.js pins at session
# start (hook-integrity.js); everything else it consults is git's answer about
# the cwd, with the repo's fsmonitor and external-diff hooks switched off.
#
# FAILURE DIRECTION: FAIL CLOSED (scripts/hooks/CLAUDE.md) - a security fence.
# Unreadable stdin denies every call, as block-git-stash.sh in the same chain
# already does. There is no bypass variable: the canonical fence is always
# available and is the remedy.
set -uo pipefail

LITERAL='bash scripts/cr/pr-check-context.sh'
# shellcheck disable=SC2016 # printed verbatim as the remedy, never expanded
FENCE='if himmel_repo=$(printenv HIMMEL_REPO | grep .); then
    bash "$himmel_repo/scripts/cr/pr-check-context.sh"
else
    echo "pr-check: HIMMEL_REPO is unset or empty" >&2
    exit 2
fi'

deny() {
    {
        echo "guard-pr-check-literal: DENIED - \`$LITERAL\` (HIMMEL-3383): $1"
        echo "The bare literal is allowed only in a himmel checkout, at its worktree root,"
        echo "on a tree with no change vs refs/remotes/origin/main under scripts/cr/ or in"
        echo "scripts/guardrails/lib.sh. Run /pr-check step 0's canonical anchored fence instead:"
        echo
        echo "$FENCE"
    } >&2
    exit 2
}

input=""
IFS= read -r -d '' input 2>/dev/null || true
case "$input" in
    *[![:space:]]*) ;;
    *) echo "guard-pr-check-literal: empty/blank stdin - failing closed" >&2; exit 2 ;;
esac
# cwd travels JSON-encoded so a newline inside it cannot shift the command
# field (which would turn the literal into a fail-open non-match).
if ! result=$(jq -r '(.tool_name // "" | tostring) + "\n" + (.cwd // "" | tostring | @json) + "\n" + (.tool_input.command // "" | tostring)' <<<"$input" 2>/dev/null); then
    echo "guard-pr-check-literal: malformed/truncated JSON on stdin - failing closed" >&2
    exit 2
fi
tool="${result%%$'\n'*}"
tool="${tool%$'\r'}"
rest="${result#*$'\n'}"
cwd_json="${rest%%$'\n'*}"
cwd_json="${cwd_json%$'\r'}"
cmd="${rest#*$'\n'}"

case "$tool" in Bash|"") ;; *) exit 0 ;; esac

# Trim surrounding whitespace; the literal itself carries no inner variation.
cmd="${cmd#"${cmd%%[![:space:]]*}"}"
cmd="${cmd%"${cmd##*[![:space:]]}"}"
[ "$cmd" = "$LITERAL" ] || exit 0

cwd=$(jq -r . <<<"$cwd_json" 2>/dev/null) \
    || deny "the payload cwd cannot be decoded."
case "$cwd" in
    *$'\n'*|*$'\r'*) deny "the payload cwd carries a line break, so it cannot be trusted as a path." ;;
esac

# Every git call below answers about the payload cwd only: no inherited
# GIT_DIR/GIT_INDEX_FILE, no repo-configured fsmonitor or external diff.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
gitq() { git -C "$cwd" -c core.fsmonitor=false -c core.untrackedCache=false "$@"; }

[ -n "$cwd" ] || deny "the hook payload carries no cwd, so the conditions cannot be evaluated."
[ -d "$cwd" ] || deny "the cwd ($cwd) is not a directory."

# 1. himmel lane.
repo="${HIMMEL_REPO:-}"
[ -n "$repo" ] || deny "HIMMEL_REPO is unset or empty, so the himmel lane cannot be proven."
repo="${repo%/}"
anchor_git=$(cd -P "$repo/.git" 2>/dev/null && pwd -P) \
    || deny "HIMMEL_REPO ($repo) has no .git directory."
if ! common=$(gitq rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || [ -z "$common" ]; then
    deny "the cwd ($cwd) is not inside a git checkout."
fi
common=$(cd -P "$common" 2>/dev/null && pwd -P) \
    || deny "the cwd's git-common-dir cannot be resolved."
[ "$common" = "$anchor_git" ] \
    || deny "not the himmel lane: the cwd's git-common-dir ($common) is not HIMMEL_REPO's ($anchor_git)."

# 2. worktree root.
prefix=$(gitq rev-parse --show-prefix 2>/dev/null) \
    || deny "the cwd's position in its worktree cannot be read."
[ -z "$prefix" ] \
    || deny "the cwd is not the worktree root (it is '$prefix' below it), so the relative path is not himmel's copy."

# 3. no scripts/cr/ or lib.sh change vs origin/main (tracked, uncommitted and
# untracked). Spelled in full: a local branch named origin/main must not
# stand in for the remote-tracking ref.
gitq rev-parse --verify --quiet 'refs/remotes/origin/main^{commit}' >/dev/null 2>&1 \
    || deny "refs/remotes/origin/main does not resolve, so the branch's scripts/cr/ diff cannot be checked."
changed=$(gitq diff --no-ext-diff --no-textconv --name-only refs/remotes/origin/main -- scripts/cr/ scripts/guardrails/lib.sh 2>/dev/null) \
    || deny "git diff against refs/remotes/origin/main failed, so the branch's scripts/cr/ diff cannot be checked."
untracked=$(gitq ls-files --others -- scripts/cr/ scripts/guardrails/lib.sh 2>/dev/null) \
    || deny "the untracked files under scripts/cr/ cannot be listed."
# assume-unchanged (lowercase tag) and skip-worktree (S) index flags make git
# diff skip the working-tree bytes of a flagged path, so any such flag on a
# guarded path means the diff above cannot vouch for what would run.
flags=$(gitq ls-files -v -- scripts/cr/ scripts/guardrails/lib.sh 2>/dev/null) \
    || deny "the index flags under scripts/cr/ cannot be listed."
hidden=$(printf '%s\n' "$flags" | awk '/^([a-z]|S) /')
[ -z "$hidden" ] \
    || deny "an index flag (assume-unchanged/skip-worktree) hides working-tree bytes from git diff: $(printf '%s' "$hidden" | tr '\n' ' ')"
if [ -n "$changed$untracked" ]; then
    deny "this tree changes the bytes step 0 runs vs refs/remotes/origin/main: $(printf '%s\n%s' "$changed" "$untracked" | tr -s '\n' ' ')"
fi

exit 0
