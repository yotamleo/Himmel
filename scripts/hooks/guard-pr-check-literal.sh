#!/usr/bin/env bash
# PreToolUse Bash guard for /pr-check's bare scripts/cr literals (HIMMEL-3383).
#
# HIMMEL-3359 (#1052) and HIMMEL-3375 (#1057) allow-listed the exact literals
#
#     bash scripts/cr/pr-check-context.sh
#     bash scripts/cr/pr-check-env.sh CR_CLAUDE_AGENTS
#
# for every leg profile (`gateAllow` in scripts/lanes/plugin-profiles.json),
# and `Bash(bash scripts/*)` in .claude/settings.json auto-allows every other
# relative spelling of them too. The runbook twins permit a relative spelling
# only when three conditions hold:
#
#   1. the himmel lane - the cwd's git-common-dir is "$HIMMEL_REPO/.git";
#   2. the cwd is the worktree root - `git rev-parse --show-prefix` is empty
#      (from a subdirectory the relative path names a local file there);
#   3. the worktree's scripts/cr/, scripts/guardrails/lib.sh and
#      scripts/lib/load-dotenv.sh (every file either script runs or sources)
#      are byte- and mode-equal to the HIMMEL_REPO anchor's.
#
# The allow rules match TEXT, so a leg that skipped or misread the runbook
# check auto-ran the branch copy - and a branch that edits the script itself
# controls the bytes that run before the script's own hand-off to the anchor.
# This hook classifies a command by the SCRIPT it runs, not by its text: any
# command that runs pr-check-context.sh or pr-check-env.sh through a relative
# path, in any spelling, is held to the three conditions. All hold -> exit 0
# silently (the permission rules decide as before); any fails, or cannot be
# evaluated -> exit 2, naming the canonical anchored fence as the remedy. It
# never emits an allow decision of its own, so it can only narrow what the
# permission layer would do.
#
# SELF-CONTAINED BY DESIGN: this file sources and execs nothing from the
# checkout under review - no scripts/guardrails/lib.sh, no scripts/cr/*. Its
# own bytes are the project hook path run-hook-with-bash.js pins at session
# start (hook-integrity.js); everything else it consults is git's answer about
# the cwd, with the repo's fsmonitor switched off and no filter ever run.
#
# FAILURE DIRECTION: FAIL CLOSED (scripts/hooks/CLAUDE.md) - a security fence,
# and a MUST_RUN_CHAIN_MEMBERS entry in run-hook-with-bash.js, so a starved run
# denies too. Unreadable stdin denies every call, as block-git-stash.sh in the
# same chain already does. There is no bypass variable: the canonical fence is
# always available and is the remedy.
set -uo pipefail
set -f

TARGETS='pr-check-context.sh pr-check-env.sh'
# The bytes either script can run before or after its hand-off to the anchor:
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
# shellcheck disable=SC2016 # matched as text
FENCE_ASSIGN='himmel_repo=$(printenv HIMMEL_REPO | grep .)'
# shellcheck disable=SC2016 # matched as text
FENCE_TOKEN='$himmel_repo/scripts/cr/pr-check-context.sh'

shown=""
deny() {
    {
        echo "guard-pr-check-literal: DENIED - \`$shown\` (HIMMEL-3383): $1"
        echo "A relative spelling of scripts/cr/pr-check-context.sh or pr-check-env.sh is allowed"
        echo "only in a himmel checkout, at its worktree root, on a tree whose scripts/cr/,"
        echo "scripts/guardrails/lib.sh and scripts/lib/load-dotenv.sh equal the HIMMEL_REPO"
        echo "anchor's byte for byte and mode for mode (compared raw, so a CRLF checkout differs)."
        echo "If the command only mentions the script (a message, a heredoc), move that text into a file."
        case "$flat" in
            *pr-check-env*)
                echo "Run the canonical spelling with step 0's printed himmel_dir instead:"
                echo
                echo "bash \"<himmel_dir>/scripts/cr/pr-check-env.sh\" CR_CLAUDE_AGENTS"
                ;;
            *)
                echo "Run /pr-check step 0's canonical anchored fence instead:"
                echo
                echo "$FENCE"
                ;;
        esac
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

# ---- classify: does this command run a guarded script by a relative path? ---
# Quotes and backslashes are dropped first, as the shell drops them, so
# 'scripts/cr/x', scripts/cr/\x and $'scripts/cr/x' all read as what they spell.
flat=$(printf '%s' "$cmd" | tr -d "'\"\\\\")
case "$flat" in *pr-check*|*/cr/*) ;; *) exit 0 ;; esac

# The canonical fence runs the anchor's copy through $himmel_repo. It is
# exempt only when it is the fence's own assignment that sets it, once, and
# nothing in the command re-points HIMMEL_REPO.
n_assign=$(printf '%s' "$flat" | grep -o 'himmel_repo=' | wc -l)
case "$cmd" in
    *"$FENCE_ASSIGN"*)
        case "$flat" in
            *HIMMEL_REPO=*) ;;
            *) [ "$n_assign" -eq 1 ] && flat=${flat//"$FENCE_TOKEN"/ } ;;
        esac
        ;;
esac

is_target() { # is_target <basename> - names, or globs onto, a guarded script
    local t
    for t in $TARGETS; do
        [ "$1" = "$t" ] && return 0
        # shellcheck disable=SC2254 # $1 IS the pattern: a glob operand
        case "$1" in
            *[][*?]*) case "$t" in $1) return 0 ;; esac ;;
        esac
    done
    return 1
}

# Anything that runs a named file: an interpreter, `source`/`.`, `eval`, or
# the file itself as the command word. Wrappers (env, timeout, xargs, ...),
# their option words and VAR= prefixes are skipped to find that word.
# shellcheck disable=SC2020 # each separator char maps to a newline
simple=$(printf '%s\n' "$flat" | tr ';&|()<>`' '\n\n\n\n\n\n\n\n')
runs=0
while IFS= read -r line; do
    read -r -a w <<<"$line"
    i=0
    skip_opts=0
    while [ "$i" -lt "${#w[@]}" ]; do
        x=${w[$i]}
        case "$x" in
            [A-Za-z_]*=*) ;;
            if|then|else|elif|do|while|until|'!'|'{'|'}'|time|command|builtin|nohup|nice|stdbuf|sudo|env|exec|timeout|xargs) skip_opts=1 ;;
            -*|[0-9]*) [ "$skip_opts" -eq 1 ] || break ;;
            *) break ;;
        esac
        i=$((i + 1))
    done
    [ "$i" -lt "${#w[@]}" ] || continue
    cw=${w[$i]}
    case "${cw##*/}" in
        bash|sh|zsh|dash|ksh|mksh|source|.|eval) runs=1 ;;
    esac
    case "$cw" in */*|pr-check*) runs=1 ;; esac
done <<<"$simple"
[ "$runs" -eq 1 ] || exit 0

# A candidate operand: a relative path whose last segment names a guarded
# script (after dropping trailing / and /. - scripts/x/../cr/... still ends in
# the name), a glob or brace list that could, or a runtime-built word when the
# command mentions pr-check at all. Absolute paths are left to the permission
# layer: no allow rule matches them, and the runbook's <himmel_dir> spelling
# is one.
# ponytail: text classification, so a name the shell assembles from pieces the
# text never spells (hex escapes, concatenated variables with no "pr-check" in
# sight) is not seen. The branch can run arbitrary code through any other
# allow-listed scripts/ path anyway; this hook closes the two named scripts.
hit=0
# shellcheck disable=SC2020 # as above
for tok in $(printf '%s\n' "$flat" | tr ';&|()<>`=' '\n\n\n\n\n\n\n\n\n'); do
    case "$tok" in /*|'~'*) continue ;; esac
    case "$tok" in
        *'$'[A-Za-z_'{']*) case "$flat" in *pr-check*) hit=1 ;; esac ;;
    esac
    case "$tok" in *pr-check*'{'*|*pr-check*'}'*) hit=1 ;; esac
    while :; do
        case "$tok" in
            */) tok=${tok%/} ;;
            */.) tok=${tok%/.} ;;
            *) break ;;
        esac
    done
    is_target "${tok##*/}" && hit=1
done
[ "$hit" -eq 1 ] || exit 0

shown=${cmd//$'\n'/ }
shown=${shown:0:200}

for t in git awk sort find paste wc tr comm grep; do
    command -v "$t" >/dev/null 2>&1 \
        || deny "the hook's own tool '$t' is not on PATH, so the conditions cannot be evaluated."
done

# A sentinel keeps trailing newlines: $( ) strips them, which would turn a
# directory named "<worktree><newline>" into the worktree's own path.
cwd=$(jq -r '. + "."' <<<"$cwd_json" 2>/dev/null) \
    || deny "the payload cwd cannot be decoded."
cwd="${cwd%.}"
case "$cwd" in
    *$'\n'*|*$'\r'*) deny "the payload cwd carries a line break, so it cannot be trusted as a path." ;;
esac

# Every git call below answers about one directory only: no inherited
# GIT_DIR/GIT_INDEX_FILE, no repo-configured fsmonitor, no filter, and no
# refs/replace/ mapping.
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

# 3. every $GUARDED file in the worktree equals the anchor's, file for file,
# in bytes and in mode. The base is the anchor's WORKING TREE, not a ref: every
# worktree shares the anchor's git-common-dir, so refs/remotes/origin/main (or
# any ref) is one `git update-ref` away for the leg under review, while the
# anchor's files are the bytes the scripts' own hand-off execs. Raw blob ids,
# NOT git diff: diff runs attribute-selected clean filters (repo-configured
# commands that can also normalise an edit back to the base) and skips paths
# flagged assume-unchanged/skip-worktree. hash-object --no-filters runs no
# filter and reads no index; an extra file on either side is an extra line.
# ponytail: trusts the anchor's working tree - legs are kept off the primary
# checkout by block-edit-on-main / block-write-into-main-checkout, not by this
# hook - and denies (the safe direction) whenever the primary has not been
# pulled to the branch's base, or is ahead of it.
manifest() { # manifest <root> - "<mode> <blob-id> <path>" per regular file, sorted
    local root=$1 odd files execs oids modes
    # shellcheck disable=SC2086 # $GUARDED is a fixed, space-free word list
    odd=$(cd "$root" && find $GUARDED \( ! -type d ! -type f \) -o -name '*[[:cntrl:]]*' 2>/dev/null) || return 1
    [ -z "$odd" ] || { printf 'ODD %s\n' "$(printf '%s' "$odd" | tr '\n' ' ')"; return 0; }
    # shellcheck disable=SC2086 # as above
    files=$(cd "$root" && find $GUARDED -type f 2>/dev/null) || return 1
    [ -n "$files" ] || return 1
    # shellcheck disable=SC2086 # as above
    execs=$(cd "$root" && find $GUARDED -type f -perm -100 2>/dev/null) || return 1
    oids=$(printf '%s\n' "$files" \
        | git --no-replace-objects -C "$root" -c core.fsmonitor=false hash-object --no-filters --stdin-paths 2>/dev/null) || return 1
    modes=$(awk 'NR == FNR { x[$0] = 1; next } { print (($0 in x) ? "100755" : "100644") }' \
        <(printf '%s\n' "$execs") <(printf '%s\n' "$files")) || return 1
    [ "$(printf '%s\n' "$files" | wc -l)" = "$(printf '%s\n' "$oids" | wc -l)" ] || return 1
    [ "$(printf '%s\n' "$files" | wc -l)" = "$(printf '%s\n' "$modes" | wc -l)" ] || return 1
    paste -d' ' <(printf '%s\n' "$modes") <(printf '%s\n' "$oids") <(printf '%s\n' "$files") | LC_ALL=C sort
}
if ! want=$(manifest "$repo") || [ -z "$want" ]; then
    deny "the HIMMEL_REPO anchor's scripts/cr/ and sourced libs ($repo) cannot be read and hashed."
fi
case "$want" in ODD\ *) deny "the HIMMEL_REPO anchor carries a non-regular file or a control-character name under the guarded paths: ${want#ODD }" ;; esac
if ! have=$(manifest "$cwd") || [ -z "$have" ]; then
    deny "the worktree's scripts/cr/ and sourced libs cannot be read and hashed."
fi
case "$have" in ODD\ *) deny "a non-regular file or a control-character name sits under the guarded paths: ${have#ODD }" ;; esac
if [ "$have" != "$want" ]; then
    differ=$(LC_ALL=C comm -3 <(printf '%s\n' "$want") <(printf '%s\n' "$have") \
        | awk '{ sub(/^\t/, ""); sub(/^[^ ]* [^ ]* /, ""); print }' | LC_ALL=C sort -u | tr '\n' ' ')
    deny "this tree's copy of the bytes step 0 runs differs from the HIMMEL_REPO anchor's ($repo): $differ"
fi

exit 0
