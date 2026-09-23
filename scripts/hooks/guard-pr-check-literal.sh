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
#
# HIMMEL-3495 widens the targets to EVERY gate-allowed scripts/cr script (the
# `Bash(bash scripts/cr/...` rows of .claude/settings.json and the leg
# profiles' gateAllow). The other thirteen are held to the same three
# conditions over a narrower set: the entry file itself and
# scripts/cr/anchor-handoff.sh. Each of them sources that hand-off as its first
# statement, so an entry byte-equal to the anchor's still carries the line, the
# hand-off it sources is the anchor's too, and the relative run execs the
# ANCHOR's copy before any other byte - every lib it loads after that is the
# anchor's. A branch that deletes the line or edits the hand-off differs, and
# denies.
set -uo pipefail
set -f

# test-guard-pr-check-literal.sh derives this set from the allow rows and
# fails when the two drift apart.
TARGETS='clear-cr-marker.sh codex-adv-harvest.sh codex-adv-kickoff.sh cr-scores.sh
doc-freshness-advisory.sh docs-audit-panel.sh impacted-suites.sh known-findings.sh
ledger-append.sh orphan-check.sh panel-first-pass.sh pr-check-context.sh
pr-check-env.sh review-round.sh write-verdicts.sh'
# The bytes either pr-check script can run before or after its hand-off to the
# anchor: pr-check-context.sh sources lib.sh, pr-check-env.sh sources
# load-dotenv.sh, and both exec further scripts/cr/ files. Neither sourced file
# sources more. Every other target is held to itself + the hand-off (above).
FULL_GUARDED='scripts/cr scripts/guardrails/lib.sh scripts/lib/load-dotenv.sh'
GUARDED=$FULL_GUARDED
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
        echo "guard-pr-check-literal: DENIED - \`$shown\` (HIMMEL-3383, HIMMEL-3495): $1"
        echo "A relative spelling of a gate-allowed scripts/cr script is allowed only in a himmel"
        echo "checkout, at its worktree root, on a tree whose copy of what it runs equals the"
        echo "HIMMEL_REPO anchor's byte for byte and mode for mode (compared raw, so a CRLF checkout"
        echo "differs): scripts/cr/, scripts/guardrails/lib.sh and scripts/lib/load-dotenv.sh for"
        echo "pr-check-context.sh / pr-check-env.sh; the script and scripts/cr/anchor-handoff.sh for the rest."
        echo "If the command only mentions the script (a message, a heredoc), move that text into a file."
        case "$flat" in
            *pr-check-env*)
                echo "Run the canonical spelling with step 0's printed himmel_dir instead:"
                echo
                echo "bash \"<himmel_dir>/scripts/cr/pr-check-env.sh\" CR_CLAUDE_AGENTS"
                ;;
            *pr-check*)
                echo "Run /pr-check step 0's canonical anchored fence instead:"
                echo
                echo "$FENCE"
                ;;
            *)
                echo "Run the anchor's copy by step 0's printed himmel_dir instead, as its own command:"
                echo
                echo "bash \"<himmel_dir>/scripts/cr/<script>.sh\" <args>"
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

# ---- classify: does this command run a guarded script by a relative path? ---
# Classification uses bash builtins only, so a missing tool cannot empty it
# into a no-op. Quotes and backslashes are dropped first, as the shell drops
# them, so 'scripts/cr/x', scripts/cr/\x and $'scripts/cr/x' all read as
# what they spell.
# A backslash-newline is a line continuation: the shell joins it away first.
# ponytail: this quote-strip is what lets a single-quoted backtick SPAN used
# as inert markdown-style prose (a `sed -i 's/x/`bash scripts\/cr\/review-
# round.sh`/'` replacement string, HIMMEL-3517 console repro 2026-09-23)
# still deny below — once the quotes are gone, that backtick reads exactly
# like a real command-substitution backtick, and `simple`'s split on backtick
# (below) then treats the enclosed text as a command word of its own. A real
# fix needs quote-aware tokenization (know which backtick was inside a
# quote), not a wider text scan; same shared limitation as
# block-edit-live-settings.sh's is_readonly_allowlisted() and a quoted `|`.
# Upgrade path: HIMMEL-3517 follow-up, if this recurs.
flat=${cmd//$'\\\n'/}
flat=${flat//[\'\"\\]/}
# A glob or brace list can spell a guarded name without either substring
# (scripts/c[r]/pr-chec[k]-context.sh), so it passes on to classification;
# so does any case of the names, which a case-insensitive filesystem folds.
names_target() { # names_target <text> - mentions pr-check or a target's exact
    # scripts/cr/<name> path token, in any case. A bare stem substring also
    # matched inside an unrelated file name that happens to contain it (a
    # test suite's own name, e.g. test-cr-scores.sh contains "cr-scores"),
    # which then made every $VAR token elsewhere in the same command look
    # unresolvable (HIMMEL-3517) - so a target only counts here when its stem
    # is immediately preceded by "cr/", never as a substring anywhere else.
    local t rc=1
    shopt -s nocasematch
    case "$1" in *pr-check*) rc=0 ;; esac
    for t in $TARGETS; do
        case "$1" in *[cC][rR]/"${t%.sh}"*) rc=0 ;; esac
    done
    shopt -u nocasematch
    return "$rc"
}
mentions=0
names_target "$flat" && mentions=1
case "$flat" in *[cC][rR]/*|*[][*?]*|*'{'*) ;; *) [ "$mentions" -eq 1 ] || exit 0 ;; esac

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

# Anything that runs a named file: an interpreter, `source`/`.`, `eval`, or
# the file itself as the command word. Wrappers (env, timeout, xargs, ...),
# their option words and VAR= prefixes are skipped to find that word; a
# wrapper counts as running something itself, since its option operands
# (env -C <dir>) hide the word that follows. Both a wrapper and a VAR= prefix
# (BASH_ENV runs a file first) make a guarded run unverifiable.
simple=${flat//[;&|()<>\`]/$'\n'}
runs=0
chdir=0
wrapped=0
bare_runs=0
while IFS= read -r line; do
    read -r -a w <<<"$line"
    i=0
    skip_opts=0
    while [ "$i" -lt "${#w[@]}" ]; do
        x=${w[$i]}
        # A bare number is a redirect's fd left by the split (`2>&1 bash ...`).
        case "$x" in ''|*[!0-9]*) ;; *) i=$((i + 1)); continue ;; esac
        case "$x" in
            [A-Za-z_]*=*) wrapped=1 ;;
            if|then|else|elif|do|while|until|'!'|'{'|'}') skip_opts=1 ;;
            time|command|builtin|nohup|nice|stdbuf|sudo|env|exec|timeout|xargs) skip_opts=1; runs=1; wrapped=1 ;;
            -C*|-D*|--chdir*|--directory*) [ "$skip_opts" -eq 1 ] || break; chdir=1 ;;
            -*|[0-9]*) [ "$skip_opts" -eq 1 ] || break ;;
            *) break ;;
        esac
        i=$((i + 1))
    done
    [ "$i" -lt "${#w[@]}" ] || continue
    cw=${w[$i]}
    case "${cw##*/}" in
        bash|sh|zsh|dash|ksh|mksh|busybox|toybox|source|.|eval) runs=1; bare_runs=1 ;;
        cd|pushd|popd) chdir=1 ;;
    esac
    # /dev/null is only ever reached as a redirect target (HIMMEL-3433).
    case "$cw" in /dev/null) ;; */*|pr-check*) runs=1 ;; esac
    is_target "${cw##*/}" && runs=1
done <<<"$simple"
# The leading-word walk above misses a runner behind an operand it does not
# know (`2>&1 bash ...`, `find . -exec env X=1 bash ...`), so these are
# PRESENCE tests over every word, not a position walk (HIMMEL-3433): an
# interpreter, a find -exec, a wrapper or an upper-case VAR= anywhere counts.
# bare_runs: something present could run a bare * or find's {} - but not a
# lone `.` or `source` away from the command word (`find . ...` is everywhere,
# and neither builtin can be exec'd by find or a wrapper).
# shellcheck disable=SC2086 # split into words on purpose; set -f is on
for x in $simple; do
    case "${x##*/}" in
        source|.) runs=1 ;;
        bash|sh|zsh|dash|ksh|mksh|busybox|toybox|eval) runs=1; bare_runs=1 ;;
        time|command|builtin|nohup|nice|stdbuf|sudo|env|exec|timeout|xargs) runs=1; wrapped=1; bare_runs=1 ;;
    esac
    case "$x" in
        -exec|-ok) runs=1 ;;
        -execdir|-okdir) runs=1 ;;
    esac
    [[ "$x" =~ ^[[:upper:]_][[:upper:][:digit:]_]*= ]] && wrapped=1
done
# -execdir/-okdir moves find's cwd only while running the word right after
# it; that word only makes a guarded run unverifiable when it could itself
# run something (an interpreter, a wrapper, or a target's own name) -
# otherwise (find ... -execdir grep foo {} \;) it never resolves a path
# itself, so the {} carve-out below still applies (HIMMEL-3517).
while IFS= read -r line; do
    read -r -a lw <<<"$line"
    j=0
    while [ "$j" -lt "${#lw[@]}" ]; do
        case "${lw[$j]}" in
            -execdir|-okdir)
                nextw=${lw[$((j + 1))]:-}
                case "${nextw##*/}" in
                    ''|bash|sh|zsh|dash|ksh|mksh|busybox|toybox|source|.|eval|time|command|builtin|nohup|nice|stdbuf|sudo|env|exec|timeout|xargs)
                        chdir=1 ;;
                    *)
                        # A path-qualified word (./wrapper, bin/wrapper) names
                        # an arbitrary file whose behavior this hook cannot
                        # see, and it runs from find's CHANGED cwd - treat it
                        # the same as an unverifiable runner (codex-2 panel
                        # finding, HIMMEL-3517). A bare word (no /) resolves
                        # via PATH to whatever is installed there, which this
                        # hook cannot see either - only a SMALL, explicit,
                        # fixed-behavior read-only allowlist gets the relaxed
                        # (non-chdir-gating) treatment; every other bare word
                        # is an unverifiable runner too (codex-1 round-4
                        # panel finding, HIMMEL-3517: an unknown PATH
                        # executable was previously treated as safe).
                        case "$nextw" in
                            */*) chdir=1 ;;
                            *)
                                case "${nextw##*/}" in
                                    grep|cat|head|tail|wc|ls|stat|file|sha256sum|md5sum)
                                        is_target "${nextw##*/}" && chdir=1 ;;
                                    sed|awk)
                                        # sed -i / awk -i inplace is a WRITE,
                                        # not read-only - still chdir-gated.
                                        case "$line" in
                                            *' -i'*|*'--in-place'*) chdir=1 ;;
                                            *) is_target "${nextw##*/}" && chdir=1 ;;
                                        esac
                                        ;;
                                    *) chdir=1 ;;
                                esac
                                ;;
                        esac
                        ;;
                esac
                ;;
        esac
        j=$((j + 1))
    done
done <<<"$simple"
# find runs the found file itself when {} is the -exec command word.
[[ "$flat" =~ -(exec|execdir|ok|okdir)[[:space:]]+[^[:space:]]*\{\} ]] && bare_runs=1
[ "$runs" -eq 1 ] || exit 0

# glob_is_literal_elsewhere <raw-token> <normalised> - a glob operand that
# cannot name a target (HIMMEL-3433): its directory part is literal (no glob,
# brace, $, ~, .., // or /./) and is not scripts/cr, or it is a bare * (or
# find's {}) with nothing present that would run it. A cd anywhere makes no
# glob safe.
glob_is_literal_elsewhere() {
    local raw=$1 rel=$2 dir
    [ "$chdir" -eq 0 ] || return 1
    case "${rel##*/}" in *[][*?]*) ;; *) return 1 ;; esac
    case "$rel" in
        */*)
            dir=${raw%/*}
            case "$dir" in *[][*?{}~\$]*|*..*|*//*|*/./*) return 1 ;; esac
            shopt -s nocasematch
            case "/${rel%/*}" in */cr|*/scripts/cr/*) shopt -u nocasematch; return 1 ;; esac
            shopt -u nocasematch
            return 0
            ;;
        '*') [ "$bare_runs" -eq 0 ] ;;
        *) return 1 ;;
    esac
}

# A candidate operand: a relative path whose last segment names a guarded
# script, a glob or brace list that could, or a runtime-built word when the
# command mentions pr-check at all. Only a path that resolves to exactly
# scripts/cr/<script> from the cwd can be checked; any other candidate (a glob,
# a variable, a path outside the root, or a cd that moves what the path
# resolves against) is unresolvable and denies. Absolute paths are left to the
# permission layer: no allow rule matches them, and the runbook's
# <himmel_dir> spelling is one.
# ponytail: text classification, so a name the shell assembles from pieces the
# text never spells (a variable holding the whole path, with neither "cr/" nor
# "pr-check" in sight) is not seen. The branch can run arbitrary code through any other
# allow-listed scripts/ path anyway; this hook closes the two named scripts.
hit=0
unresolved=""
# A whole word that names a path through cr/ (any case) is read by its text
# alone, so a word the shell rewrites first - an expansion, a substitution, a
# glob, a brace list, a tilde - is unresolvable, and so is a relative one a
# case-insensitive filesystem folds. Whole words, before any split: a
# substitution ($(pwd)/scripts/cr/...) only looks absolute once split.
# Absolute words keep their case (an adopter's /Users/... anchor path).
for word in $flat; do
    case "$word" in *[cC][rR]/*) ;; *) continue ;; esac
    case "$word" in
        *[][*?~\$\(\`]*|*'{'*|*'}'*) hit=1; unresolved=$word ;;
        /*) ;;
        *[[:upper:]]*) hit=1; unresolved=$word ;;
    esac
done
entries=""
for tok in ${flat//[;&|()<>\`=]/$'\n'}; do
    case "$tok" in /*|'~'*) continue ;; esac
    case "$tok" in
        *'$'[A-Za-z_'{']*) [ "$mentions" -eq 0 ] || { hit=1; unresolved=$tok; } ;;
    esac
    case "$tok" in *'{'*|*'}'*) ! names_target "$tok" || { hit=1; unresolved=$tok; } ;; esac
    raw=$tok
    # A brace list reads as a glob that matches every word it could expand to,
    # innermost group first; a pair it cannot reduce is unresolvable.
    while :; do
        case "$tok" in *'{'*) ;; *) break ;; esac
        rest=${tok##*'{'}
        case "$rest" in *'}'*) ;; *) break ;; esac
        tok=${tok%'{'*}'*'${rest#*'}'}
    done
    case "$tok" in *'{'*'}'*) hit=1; unresolved=$tok ;; esac
    rel=$(norm "$tok")
    if is_target "${rel##*/}" && ! glob_is_literal_elsewhere "$raw" "$rel"; then
        hit=1
        case "$rel" in
            scripts/cr/*)
                e=${rel#scripts/cr/}
                case " $TARGETS " in
                    *[[:space:]]"$e"[[:space:]]*)
                        case " $entries " in *" $e "*) ;; *) entries="$entries $e" ;; esac ;;
                    *) unresolved=$tok ;;
                esac
                ;;
            *) unresolved=$tok ;;
        esac
    fi
done
[ "$hit" -eq 1 ] || exit 0
# ponytail: a glob through a directory symlink the text does not spell as
# scripts/cr (`bash scripts/lnk/*`, lnk -> cr) is not a candidate - the same
# class as `bash scripts/lnk/x.sh`, which this hook never saw either, and no
# allow rule matches it. The manifest refuses a symlinked scripts/ or
# scripts/cr itself.
case " $entries " in
    *' pr-check-context.sh '*|*' pr-check-env.sh '*) GUARDED=$FULL_GUARDED ;;
    *)
        GUARDED='scripts/cr/anchor-handoff.sh'
        for e in $entries; do GUARDED="$GUARDED scripts/cr/$e"; done
        ;;
esac

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
    # scripts/ and scripts/cr/ themselves must be real directories: a per-file
    # GUARDED list would otherwise read straight through a symlinked one.
    odd=$(cd "$root" && {
        find scripts scripts/cr -prune ! -type d
        find $GUARDED \( ! -type d ! -type f \) -o -name '*[[:cntrl:]]*'
    } 2>/dev/null) || return 1
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
