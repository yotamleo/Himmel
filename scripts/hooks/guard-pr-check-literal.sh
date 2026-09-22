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
# The fence's exact shape, once whitespace runs are collapsed: its statements
# may be split by newlines or `;`, and only the echo text may vary (no quote,
# $, backtick or backslash in it, so it cannot expand).
# shellcheck disable=SC2016 # a regex, matched as text
FENCE_RE='^if himmel_repo=\$\(printenv HIMMEL_REPO \| grep \.\) ?;? then bash "\$himmel_repo/scripts/cr/pr-check-context\.sh" ?;? else echo "[^"$`\\]*" >&2 ?;? exit 2 ?;? fi ?;?$'

shown=""
flat=""
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
# A CR is never part of a path a leg means to type: a CRLF payload would glue
# one onto the script name and hide it from the classifier.
cmd="${cmd//$'\r'/}"

case "$tool" in Bash|"") ;; *) exit 0 ;; esac

# Blanks quoted spans (each char replaced by a space, so length and position
# are preserved) so a later << search only finds a real redirect operator,
# never text that merely appears inside a quoted argument - `echo '<<EOF'`
# is not a heredoc (codex-2, found in HIMMEL-3433 review).
unquoted_mask() {
    local s=$1
    local out="" i=0 n=${#s} c q=""
    while [ "$i" -lt "$n" ]; do
        c=${s:$i:1}
        if [ -n "$q" ]; then
            [ "$c" = "$q" ] && q=""
            out+=" "
        elif [ "$c" = "'" ] || [ "$c" = '"' ]; then
            q=$c
            out+=" "
        else
            out+="$c"
        fi
        i=$((i + 1))
    done
    printf '%s' "$out"
}

# A heredoc body under a QUOTED marker (<<'EOF') is inert data for its
# redirect target end-to-end, so it is stripped: a body line that merely
# mentions a guarded path is never read as one of the "simple command lines"
# below (HIMMEL-3433). A body under an UNQUOTED marker (<<EOF) still
# undergoes command substitution when the heredoc actually runs, so it is
# left in place for the classifier below rather than discarded unseen
# (codex-1, found in HIMMEL-3433 review) - the classifier's own $( )
# extraction (below) then catches a guarded run inside it.
# ponytail: only the first heredoc on a line is tracked, so a rare second
# `<<` on the same line keeps its marker text unstripped - a stray marker
# word, never a guarded script's own text, so it cannot turn a deny into an
# allow.
strip_heredocs() {
    local text=$1 out="" hline marker="" in_body=0 masked prefix rest
    while IFS= read -r hline || [ -n "$hline" ]; do
        if [ "$in_body" -eq 1 ]; then
            if [ "$hline" = "$marker" ] || [[ "$hline" =~ ^$'\t'*${marker}$ ]]; then
                in_body=0
            fi
            continue
        fi
        out="$out$hline"$'\n'
        masked=$(unquoted_mask "$hline")
        if [[ "$masked" == *'<<'* ]]; then
            prefix=${masked%%<<*}
            rest=${hline:${#prefix}}
            if [[ "$rest" =~ ^\<\<-?[[:space:]]*[\'\"]([A-Za-z_][A-Za-z0-9_]*)[\'\"] ]]; then
                marker=${BASH_REMATCH[1]}
                in_body=1
            fi
        fi
    done <<<"$text"
    printf '%s' "$out"
}
cmd=$(strip_heredocs "$cmd")

# ---- classify: does this command run a guarded script by a relative path? ---
# Classification uses bash builtins only, so a missing tool cannot empty it
# into a no-op. Quotes and backslashes are dropped first, as the shell drops
# them, so 'scripts/cr/x', scripts/cr/\x and $'scripts/cr/x' all read as
# what they spell.
# A backslash-newline is a line continuation: the shell joins it away first.
flat=${cmd//$'\\\n'/}
flat=${flat//[\'\"\\]/}
# A glob or brace list can spell a guarded name without either substring
# (scripts/c[r]/pr-chec[k]-context.sh), so it passes on to classification;
# so does any case of the names, which a case-insensitive filesystem folds.
case "$flat" in *[pP][rR]-[cC][hH][eE][cC][kK]*|*[cC][rR]/*|*[][*?]*|*'{'*) ;; *) exit 0 ;; esac

# The canonical fence runs the anchor's copy through $himmel_repo, so it is
# exempt - but only in its exact shape. Anything added to it (a second
# assignment, a `read himmel_repo`, an export) makes it an ordinary command.
fence=${cmd//[$'\t\n\r']/ }
while :; do
    case "$fence" in *'  '*) fence=${fence//  / } ;; *) break ;; esac
done
fence=${fence# }
fence=${fence% }
[[ "$fence" =~ $FENCE_RE ]] && exit 0

# norm <path> - drop empty and . segments. A .. is kept, so the path no longer
# reads as scripts/cr/<script> and denies: the kernel resolves .. after
# following symlinks, so scripts/x/../cr can land outside the root.
norm() {
    local -a parts out=()
    local p
    IFS=/ read -r -a parts <<<"$1"
    for p in ${parts[@]+"${parts[@]}"}; do
        case "$p" in
            ''|.) ;;
            *) out+=("$p") ;;
        esac
    done
    local IFS=/
    printf '%s' "${out[*]-}"
}

is_target() { # is_target <basename> - names, or globs onto, a guarded script, in any case
    local t rc=1
    shopt -s nocasematch
    for t in $TARGETS; do
        case "$1" in "$t") rc=0 ;; esac
        # shellcheck disable=SC2254 # $1 IS the pattern: a glob operand
        case "$1" in
            *[][*?]*) case "$t" in $1) rc=0 ;; esac ;;
        esac
    done
    shopt -u nocasematch
    return "$rc"
}

# Splits <text> into simple-command lines (newline-joined) of NUL^A-joined
# words: quote-aware, so a metacharacter inside a quoted argument (the | and
# ( ) of a jq program) stays part of its one word instead of fracturing into
# spurious new lines, and a backslash-newline joins two physical lines with
# no character at all. A redirect (< or >) drops its own following word - a
# redirect target is never a command to classify (HIMMEL-3433).
# ponytail: a backslash-escaped quote char inside a double-quoted string
# (\") is not unescaped - it is read as closing the quote early. No target
# test row hits this; a wrongly-early close only ever narrows a word, so the
# failure direction stays a false deny, never a false allow.
tokenize() {
    local text=$1
    local -i i=0 n=${#text}
    local q="" word="" line="" res="" c nc pending_redirect=0
    while [ "$i" -lt "$n" ]; do
        c=${text:$i:1}
        if [ -n "$q" ]; then
            if [ "$c" = "$q" ]; then q=""; else word+="$c"; fi
            i=$((i + 1))
            continue
        fi
        case "$c" in
            \'|\") q=$c ;;
            \\)
                i=$((i + 1))
                if [ "$i" -lt "$n" ]; then
                    nc=${text:$i:1}
                    [ "$nc" = $'\n' ] || word+="$nc"
                fi
                ;;
            ' '|$'\t')
                if [ -n "$word" ]; then
                    if [ "$pending_redirect" -eq 1 ]; then
                        pending_redirect=0
                    else
                        line+="$word"$'\x01'
                    fi
                    word=""
                fi
                ;;
            ';'|'&'|'|'|'('|')'|'`'|$'\n')
                if [ -n "$word" ]; then
                    if [ "$pending_redirect" -eq 1 ]; then
                        pending_redirect=0
                    else
                        line+="$word"$'\x01'
                    fi
                    word=""
                fi
                res+="$line"$'\n'
                line=""
                pending_redirect=0
                ;;
            '<'|'>')
                if [ -n "$word" ]; then
                    if [ "$pending_redirect" -eq 1 ]; then
                        pending_redirect=0
                    else
                        line+="$word"$'\x01'
                    fi
                    word=""
                fi
                pending_redirect=1
                ;;
            *) word+="$c" ;;
        esac
        i=$((i + 1))
    done
    if [ -n "$word" ] && [ "$pending_redirect" -ne 1 ]; then
        line+="$word"$'\x01'
    fi
    res+="$line"$'\n'
    printf '%s' "$res"
}

# Anything that runs a named file: an interpreter, `source`/`.`, `eval`, or
# the file itself as the command word. Wrappers (env, timeout, xargs, ...),
# their option words and VAR= prefixes are skipped to find that word; a
# wrapper counts as running something itself, since its option operands
# (env -C <dir>) hide the word that follows. Both a wrapper and a VAR= prefix
# (BASH_ENV runs a file first) make a guarded run unverifiable. An interpreter
# name chains through the same skip-loop as a wrapper, so `env bash <op>` and
# a bare `sh <op>` both land on <op> - the one word this hook ever classifies
# on that line. A read-only program (grep, cat, jq, echo, ...) that is not a
# wrapper or interpreter, and does not itself look like a guarded path, is not
# executing anything checked here, so its argument words are never inspected
# (HIMMEL-3433) - this is what lets `grep -n x scripts/cr/*` alone.
#
# A candidate operand: a relative path whose last segment names a guarded
# script, a glob or brace list that could, or an absolute/tilde word (left to
# the permission layer: no allow rule matches them, and the runbook's
# <himmel_dir> spelling is one). Only a path that resolves to exactly
# scripts/cr/<script> from the cwd can be checked; any other candidate (a glob,
# a variable, a path outside the root, or a cd that moves what the path
# resolves against) is unresolvable and denies. A wrapper/interpreter chain
# that runs out of words before landing on one denies too - fail closed, since
# its operand cannot be read at all.
# ponytail: text classification, so a name the shell assembles from pieces the
# text never spells (a variable holding the whole path, with neither "cr/" nor
# "pr-check" in sight) is not seen. The branch can run arbitrary code through any other
# allow-listed scripts/ path anyway; this hook closes the two named scripts.
#
# Extracts the inner text of every $(...) and `...` substitution in the raw
# command, quoted or not, as its own line. tokenize()'s quote handling reads
# every character of a double-quoted word literally - including a $( ) the
# shell still expands there - so a substitution buried inside one would
# otherwise be swallowed as one opaque token and never classified (codex-3,
# found in HIMMEL-3433 review). An unquoted $( ) is already caught by
# tokenize() splitting on its bare parens; extracting it here too is
# redundant, not wrong. Depth-tracked for one level of nesting; a
# substitution nested inside an already-extracted one is not re-scanned.
extract_substitutions() {
    local text=$1
    local acc="" i=0 n=${#text} c depth inner
    while [ "$i" -lt "$n" ]; do
        c=${text:$i:1}
        if [ "$c" = '`' ]; then
            i=$((i + 1))
            inner=""
            while [ "$i" -lt "$n" ] && [ "${text:$i:1}" != '`' ]; do
                inner+="${text:$i:1}"
                i=$((i + 1))
            done
            acc+="$inner"$'\n'
        elif [ "$c" = '$' ] && [ "${text:$((i + 1)):1}" = '(' ]; then
            i=$((i + 2))
            depth=1
            inner=""
            while [ "$i" -lt "$n" ] && [ "$depth" -gt 0 ]; do
                c=${text:$i:1}
                case "$c" in
                    '(') depth=$((depth + 1)); inner+="$c" ;;
                    ')') depth=$((depth - 1)); [ "$depth" -gt 0 ] && inner+="$c" ;;
                    *) inner+="$c" ;;
                esac
                i=$((i + 1))
            done
            acc+="$inner"$'\n'
            continue
        fi
        i=$((i + 1))
    done
    printf '%s' "$acc"
}
simple=$(tokenize "$cmd"$'\n'"$(extract_substitutions "$cmd")")
runs=0
chdir=0
wrapped=0
hit=0
unresolved=""
while IFS= read -r line; do
    IFS=$'\x01' read -r -a w <<<"$line"
    i=0
    skip_opts=0
    chained=0
    lastw=""
    while [ "$i" -lt "${#w[@]}" ]; do
        x=${w[$i]}
        case "$x" in
            [A-Za-z_]*=*) wrapped=1 ;;
            if|then|else|elif|do|while|until|'!'|'{'|'}') skip_opts=1 ;;
            time|command|builtin|nohup|nice|stdbuf|sudo|env|exec|timeout|xargs) skip_opts=1; runs=1; wrapped=1; chained=1; lastw=$x ;;
            bash|sh|zsh|dash|ksh|mksh|busybox|toybox|source|.|eval) skip_opts=1; runs=1; chained=1; lastw=$x ;;
            -C*|-D*|--chdir*|--directory*) [ "$skip_opts" -eq 1 ] || break; chdir=1 ;;
            -*|[0-9]*) [ "$skip_opts" -eq 1 ] || break ;;
            *) break ;;
        esac
        i=$((i + 1))
    done
    if [ "$i" -ge "${#w[@]}" ]; then
        if [ "$chained" -eq 1 ]; then
            runs=1
            hit=1
            unresolved="${lastw:-(no operand)}"
        fi
        continue
    fi
    cw=${w[$i]}
    case "${cw##*/}" in
        cd|pushd|popd) chdir=1; continue ;;
    esac
    if [ "$chained" -eq 0 ]; then
        case "$cw" in
            */*|pr-check*) runs=1 ;;
            *) continue ;;
        esac
    fi
    case "$cw" in
        *[][*?~\$\(\`]*|*'{'*|*'}'*) hit=1; unresolved=$cw ;;
        /*|'~'*) ;;
        *[[:upper:]]*) hit=1; unresolved=$cw ;;
        *)
            # A brace list reads as a glob that matches every word it could
            # expand to, innermost group first; a pair it cannot reduce is
            # unresolvable.
            tok=$cw
            while :; do
                case "$tok" in *'{'*) ;; *) break ;; esac
                rest=${tok##*'{'}
                case "$rest" in *'}'*) ;; *) break ;; esac
                tok=${tok%'{'*}'*'${rest#*'}'}
            done
            case "$tok" in *'{'*'}'*) hit=1; unresolved=$tok ;; esac
            rel=$(norm "$cw")
            if is_target "${rel##*/}"; then
                hit=1
                case "$rel" in
                    scripts/cr/pr-check-context.sh|scripts/cr/pr-check-env.sh) ;;
                    *) unresolved=$cw ;;
                esac
            fi
            ;;
    esac
done <<<"$simple"
[ "$runs" -eq 1 ] || exit 0
# A chdir or a wrapper/VAR= prefix denies below on its own, even on a line
# whose landing operand itself never set hit (env -C elsewhere bash ...): only
# skip the deny chain when none of the three ever fired.
[ "$hit" -eq 1 ] || [ "$chdir" -eq 1 ] || [ "$wrapped" -eq 1 ] || exit 0

shown=${cmd//$'\n'/ }
shown=${shown:0:200}

[ -z "$unresolved" ] \
    || deny "'$unresolved' does not resolve to this root's scripts/cr/ by its text alone (a glob, a variable, or a path outside the root), so the bytes it runs cannot be checked."
[ "$chdir" -eq 0 ] \
    || deny "the command changes directory, so the relative path does not resolve against the cwd the conditions are checked in."
# Only one simple command can be checked: the conditions hold for the bytes
# at match time, and another command in the same call (cp, a redirect, a
# pipe) can rewrite them before the script runs; a wrapper's operands can
# hide what it runs.
case "$flat" in
    *[\;\&\|\(\)\<\>\`]*|*$'\n'*) deny "the command is not one simple command, so the bytes checked at match time are not guaranteed to be the bytes that run." ;;
esac
[ "$wrapped" -eq 0 ] \
    || deny "the command runs the script through a wrapper or a VAR= prefix (BASH_ENV, PATH, ...), which can run other code or change what runs before the checked bytes do."

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
# The anchor's working tree is itself one git write away (checkout <branch> --
# <path>, a detached HEAD), so it must be on refs/heads/main with the guarded
# paths equal to main's committed tree - compared by ls-tree, which runs no
# filter. Denies (the safe direction) whenever the primary has not been
# pulled to the branch's base, or is ahead of it.
# ponytail: refs/heads/main is trusted as the anchor's commit - a leg that
# moves main itself (update-ref) is fenced by the git-write guards, not here.
# ponytail: checked at match time only - a background job or another session
# can swap the bytes between this check and the exec (TOCTOU), not closed here.
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
anchorq() { git --no-replace-objects -C "$repo" -c core.fsmonitor=false -c core.quotePath=false "$@"; }
head_ref=$(anchorq symbolic-ref -q HEAD 2>/dev/null) || head_ref=""
[ "$head_ref" = refs/heads/main ] \
    || deny "the HIMMEL_REPO anchor ($repo) is not on refs/heads/main (its HEAD is '${head_ref:-detached}'), so its bytes are not main's."
# shellcheck disable=SC2086 # $GUARDED is a fixed, space-free word list
if ! committed=$(anchorq ls-tree -r --full-tree refs/heads/main -- $GUARDED 2>/dev/null \
    | awk -F'\t' '{ split($1, m, " "); print m[1] " " m[3] " " $2 }' | LC_ALL=C sort) || [ -z "$committed" ]; then
    deny "refs/heads/main's guarded paths in the HIMMEL_REPO anchor ($repo) cannot be listed."
fi
[ "$want" = "$committed" ] \
    || deny "the HIMMEL_REPO anchor's working tree ($repo) under the guarded paths is not refs/heads/main's committed bytes, so it cannot serve as the base."
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
