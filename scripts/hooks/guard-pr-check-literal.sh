#!/usr/bin/env bash
# PreToolUse Bash guard for /pr-check's bare scripts/cr literals (HIMMEL-3383).
#
# HIMMEL-3359 (#1052) and HIMMEL-3375 (#1057) allow-listed the exact literals
#
#     bash scripts/cr/pr-check-context.sh
#     bash scripts/cr/pr-check-env.sh CR_CLAUDE_AGENTS
#
# for every leg profile (`gateAllow` in scripts/lanes/plugin-profiles.json).
# The runbook twins permit those spellings only when three conditions hold:
#
#   1. the himmel lane - the cwd's git-common-dir is "$HIMMEL_REPO/.git";
#   2. the cwd is the worktree root - `git rev-parse --show-prefix` is empty
#      (from a subdirectory the relative path names a local file there);
#   3. the working tree has no change vs refs/remotes/origin/main under
#      scripts/cr/ or in scripts/guardrails/lib.sh / scripts/lib/load-dotenv.sh
#      (every file either script runs or sources).
#
# The allow rule matches the TEXT regardless, so a leg that skipped or misread
# the runbook check auto-ran the branch copy - and a branch that edits
# the script itself controls the bytes that run before the script's
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
# the cwd, with the repo's fsmonitor switched off and no filter ever run.
#
# FAILURE DIRECTION: FAIL CLOSED (scripts/hooks/CLAUDE.md) - a security fence.
# Unreadable stdin denies every call, as block-git-stash.sh in the same chain
# already does. There is no bypass variable: the canonical fence is always
# available and is the remedy.
set -uo pipefail

CONTEXT_LITERAL='bash scripts/cr/pr-check-context.sh'
ENV_LITERAL='bash scripts/cr/pr-check-env.sh CR_CLAUDE_AGENTS'
LITERAL=$CONTEXT_LITERAL
# The bytes either literal can run before or after its hand-off to the anchor:
# pr-check-context.sh sources lib.sh, pr-check-env.sh sources load-dotenv.sh,
# and both exec further scripts/cr/ files. Neither sourced file sources more.
GUARDED='scripts/cr scripts/guardrails/lib.sh scripts/lib/load-dotenv.sh'
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
        echo "scripts/guardrails/lib.sh or scripts/lib/load-dotenv.sh."
        if [ "$LITERAL" = "$ENV_LITERAL" ]; then
            echo "Run the canonical spelling with step 0's printed himmel_dir instead:"
            echo
            echo "bash \"<himmel_dir>/scripts/cr/pr-check-env.sh\" CR_CLAUDE_AGENTS"
        else
            echo "Run /pr-check step 0's canonical anchored fence instead:"
            echo
            echo "$FENCE"
        fi
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
case "$cmd" in
    "$CONTEXT_LITERAL"|"$ENV_LITERAL") LITERAL=$cmd ;;
    *) exit 0 ;;
esac

# A sentinel keeps trailing newlines: $( ) strips them, which would turn a
# directory named "<worktree><newline>" into the worktree's own path.
cwd=$(jq -r '. + "."' <<<"$cwd_json" 2>/dev/null) \
    || deny "the payload cwd cannot be decoded."
cwd="${cwd%.}"
case "$cwd" in
    *$'\n'*|*$'\r'*) deny "the payload cwd carries a line break, so it cannot be trusted as a path." ;;
esac

# Every git call below answers about the payload cwd only: no inherited
# GIT_DIR/GIT_INDEX_FILE, no repo-configured fsmonitor, no filter, and no
# refs/replace/ mapping standing in for origin/main's real objects.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_REPLACE_REF_BASE
gitq() { git --no-replace-objects -C "$cwd" -c core.fsmonitor=false -c core.untrackedCache=false "$@"; }

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

# 3. the working-tree bytes of every $GUARDED file equal
# refs/remotes/origin/main's, file for file. Compared as raw blob ids, NOT via
# git diff: diff runs attribute-selected clean filters (repo-configured
# commands that can also normalise an edit back to the base) and skips paths
# flagged assume-unchanged/skip-worktree. hash-object --no-filters runs no
# filter and reads the index not at all; untracked files show up as extra
# paths. Spelled in full: a local branch named origin/main must not stand in
# for the remote-tracking ref.
gitq rev-parse --verify --quiet 'refs/remotes/origin/main^{commit}' >/dev/null 2>&1 \
    || deny "refs/remotes/origin/main does not resolve, so the branch's scripts/cr/ diff cannot be checked."
# shellcheck disable=SC2086 # $GUARDED is a fixed, space-free word list
tree=$(gitq ls-tree -r refs/remotes/origin/main -- $GUARDED 2>/dev/null) \
    || deny "refs/remotes/origin/main's scripts/cr/ tree cannot be listed."
[ -n "$tree" ] || deny "refs/remotes/origin/main carries no scripts/cr/ files to compare against."
# "<path> <oid>" per regular blob; any other mode (symlink, gitlink) becomes a
# line no working-tree file can produce, so it always mismatches.
want=$(printf '%s\n' "$tree" | awk -F'\t' '{ split($1, m, " "); if (m[1] ~ /^100(644|755)$/) print $2 " " m[3]; else print $2 " mode-" m[1] }' | LC_ALL=C sort)
# shellcheck disable=SC2086 # as above
odd=$(cd "$cwd" && find $GUARDED \( ! -type d ! -type f \) -o -name '*[[:cntrl:]]*' 2>/dev/null) \
    || deny "the files under scripts/cr/ cannot be listed."
[ -z "$odd" ] \
    || deny "a non-regular file or a control-character name sits under the guarded paths: $(printf '%s' "$odd" | tr '\n' ' ')"
# shellcheck disable=SC2086 # as above
files=$(cd "$cwd" && find $GUARDED -type f 2>/dev/null) \
    || deny "the files under scripts/cr/ cannot be listed."
oids=$(printf '%s\n' "$files" | gitq hash-object --no-filters --stdin-paths 2>/dev/null) \
    || deny "the working-tree bytes under scripts/cr/ cannot be hashed."
[ "$(printf '%s\n' "$files" | wc -l)" = "$(printf '%s\n' "$oids" | wc -l)" ] \
    || deny "the working-tree hash count does not match the file count."
have=$(paste -d' ' <(printf '%s\n' "$files") <(printf '%s\n' "$oids") | LC_ALL=C sort)
if [ "$have" != "$want" ]; then
    differ=$(LC_ALL=C comm -3 <(printf '%s\n' "$want") <(printf '%s\n' "$have") \
        | awk '{ sub(/^\t/, ""); sub(/ [^ ]*$/, ""); print }' | LC_ALL=C sort -u | tr '\n' ' ')
    deny "this tree changes the bytes step 0 runs vs refs/remotes/origin/main: $differ"
fi

exit 0
