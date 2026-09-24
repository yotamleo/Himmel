#!/usr/bin/env bash
# PreToolUse Bash guard for /pr-check's bare scripts/cr literals (HIMMEL-3383).
#
# HIMMEL-3359 (#1052) and HIMMEL-3375 (#1057) allow-listed the exact literals
#
#     bash scripts/cr/pr-check-context.sh
#     bash scripts/cr/pr-check-env.sh CR_CLAUDE_AGENTS
#
# for every leg profile (`gateAllow` in scripts/lanes/plugin-profiles.json).
# HIMMEL-3402 later narrowed away .claude/settings.json's `Bash(bash scripts/*)`
# prefix rule; scripts/cr/, scripts/guardrails/ and scripts/hooks/ get no
# prefix allow at all now, only the exact literals below - but an exact
# literal still matches TEXT, so it auto-runs whatever bytes currently sit at
# that relative path in the caller's cwd, branch copy included. The runbook
# twins permit a relative spelling only when three conditions hold:
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

# HIMMEL-3437: the two scripts/handover/ gate-writer entries a leg profile
# also pre-approves as RELATIVE literals (merge-on-green.sh, console-kit/go.sh)
# - outside scripts/cr/, so TARGETS above (and the derived/declared check in
# the test suite, which is scoped to scripts/cr/ allow rows only) does not
# reach them. Held to the same narrower condition as every TARGETS entry but
# pr-check-context.sh/env.sh: the entry script and scripts/cr/anchor-handoff.sh
# (HIMMEL-3437's hand-off, shared with the scripts/cr/ family) byte- and
# mode-equal the anchor's. Full relative paths, not bare basenames: "go.sh" is
# too common a stem to key on alone, and matching the full path is exact
# rather than relying on a directory-marker substring.
HTARGETS='scripts/handover/merge-on-green.sh scripts/handover/console-kit/go.sh'
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
        echo "guard-pr-check-literal: DENIED - \`$shown\` (HIMMEL-3383, HIMMEL-3495, HIMMEL-3437): $1"
        echo "A relative spelling of a gate-allowed scripts/cr or scripts/handover/ writer is allowed"
        echo "only in a himmel checkout, at its worktree root, on a tree whose copy of what it runs"
        echo "equals the HIMMEL_REPO anchor's byte for byte and mode for mode (compared raw, so a CRLF"
        echo "checkout differs): scripts/cr/, scripts/guardrails/lib.sh and scripts/lib/load-dotenv.sh"
        echo "for pr-check-context.sh / pr-check-env.sh; the script and scripts/cr/anchor-handoff.sh"
        echo "for every other target, merge-on-green.sh and console-kit/go.sh included."
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
            *handover/merge-on-green*)
                echo "Run the anchored spelling instead (HIMMEL-3491) - EVERY argument must be"
                echo "unquoted, with no ' or \\ anywhere in the command (the anchor prefix is"
                echo "exempted only when the whole command carries neither):"
                echo
                # shellcheck disable=SC2016 # printed verbatim, never expanded
                echo 'bash "$HIMMEL_REPO/scripts/handover/merge-on-green.sh" <unquoted-args>'
                echo
                echo "If an argument genuinely needs quoting, use the anchor's copy by step 0's"
                echo "printed himmel_dir instead, as its own command:"
                echo
                echo "bash \"<himmel_dir>/scripts/handover/merge-on-green.sh\" <args>"
                ;;
            *console-kit/go*)
                echo "Run the anchor's copy by step 0's printed himmel_dir instead, as its own command:"
                echo
                echo "bash \"<himmel_dir>/scripts/handover/console-kit/go.sh\" <args>"
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
flat=${cmd//$'\\\n'/}
flat=${flat//[\'\"\\]/}

# >>> BEGIN shell-tokenize (HIMMEL-3546; canonical: scripts/hooks/lib/shell-tokenize.sh) >>>
# st_tokenize CMD — split CMD into words and segments the way bash reads it,
# expanding nothing. Returns 0 (ST_OK=1) on success, 1 (ST_OK=0) on anything
# it does not model — an unterminated quote, an unmatched `)`, `;;`, a
# backtick inside double quotes inside backticks, a `${…}` beyond a bare
# name, a redirect with no target, more than 16 KiB — and the caller then
# falls back to its older, stricter text scan.
#   ST_N        number of words
#   ST_W[i]     word i with quotes and escapes removed, nothing expanded
#   ST_Q[i]     1 when any byte of word i was quoted or escaped
#   ST_X[i]     1 when word i carries a live `$` (unquoted, or inside "…")
#   ST_G[i]     1 when word i carries an unquoted * ? [ or { (a glob or
#               brace expansion, which can become any word — even `-i`)
#   ST_A[i]     1 when word i is assignment-shaped (an unquoted NAME=)
#   ST_S[i]     segment index of word i
#   ST_RO[i]    the redirect operator word i is the target of (`>`, `2>&`,
#               `<<`, …), empty for an ordinary word
#   ST_NSEG     number of segments
#   ST_SEP[s]   operator ending segment s: ; & && | || |& nl ( ) $( ` <( >(
#               or empty for the last one. A substitution's inner command is
#               a segment of its own.
#   ST_SUBST ST_HEREDOC ST_ANSIC ST_COMMENT — 1 when the command carries a
#               live command/process substitution (including inside "…" and
#               an unquoted heredoc body), a heredoc, a $'…' word, a comment.
# shellcheck disable=SC1003,SC2016,SC2034 # literal \ ` $ bytes; ST_* are read by the caller
st_tokenize() {
    local LC_ALL=C
    local s="$1" n i c c2 c3 ctx='' top w='' win=0 wq=0 wx=0 wg=0 wqpos=-1
    local rop='' fd op rest body j bad=0 hd_n=0 hd_i=0
    local -a hd_d hd_q hd_t
    ST_OK=0 ST_N=0 ST_NSEG=0 ST_SUBST=0 ST_HEREDOC=0 ST_ANSIC=0 ST_COMMENT=0
    ST_W=() ST_Q=() ST_X=() ST_G=() ST_A=() ST_S=() ST_RO=() ST_SEP=()
    n=${#s}
    [ "$n" -le 16384 ] || return 1
    i=0
    while [ "$i" -lt "$n" ]; do
        c=${s:i:1}
        top=''
        [ -z "$ctx" ] || top=${ctx:${#ctx}-1:1}
        if [ "$top" = D ]; then
            case "$c" in
                '"') ctx=${ctx%?}; i=$((i + 1)) ;;
                '\')
                    c2=${s:i+1:1}
                    case "$c2" in
                        '$'|'`'|'"'|'\') _st_q; w=$w$c2; i=$((i + 2)) ;;
                        $'\n') i=$((i + 2)) ;;
                        *) _st_q; w=$w'\'; i=$((i + 1)) ;;
                    esac
                    ;;
                '$')
                    if [ "${s:i+1:1}" = '(' ]; then
                        ST_SUBST=1; _st_seg '$('; ctx=${ctx}P; i=$((i + 2))
                    else
                        _st_q; wx=1; w=$w'$'; i=$((i + 1))
                    fi
                    ;;
                '`')
                    case "$ctx" in *B*) return 1 ;; esac
                    ST_SUBST=1; _st_seg '`'; ctx=${ctx}B; i=$((i + 1))
                    ;;
                *) _st_q; w=$w$c; i=$((i + 1)) ;;
            esac
            continue
        fi
        case "$c" in
            ' '|$'\t') _st_word; i=$((i + 1)) ;;
            $'\n')
                _st_seg nl; i=$((i + 1))
                [ "$hd_i" -ge "$hd_n" ] || _st_heredocs
                ;;
            "'")
                rest=${s:i+1}
                case "$rest" in *"'"*) ;; *) return 1 ;; esac
                body=${rest%%"'"*}
                _st_q; w=$w$body; i=$((i + ${#body} + 2))
                ;;
            '"') _st_q; ctx=${ctx}D; i=$((i + 1)) ;;
            '\')
                c2=${s:i+1:1}
                case "$c2" in
                    $'\n') i=$((i + 2)) ;;
                    '') _st_q; w=$w'\'; i=$((i + 1)) ;;
                    *) _st_q; w=$w$c2; i=$((i + 2)) ;;
                esac
                ;;
            '$')
                c2=${s:i+1:1}
                case "$c2" in
                    "'")
                        ST_ANSIC=1; body=''; j=$((i + 2))
                        while [ "$j" -lt "$n" ]; do
                            c3=${s:j:1}
                            if [ "$c3" = '\' ]; then
                                body=$body${s:j:2}; j=$((j + 2))
                            elif [ "$c3" = "'" ]; then
                                break
                            else
                                body=$body$c3; j=$((j + 1))
                            fi
                        done
                        [ "$j" -lt "$n" ] || return 1
                        _st_q; w=$w$body; i=$((j + 1))
                        ;;
                    '"') _st_q; ctx=${ctx}D; i=$((i + 2)) ;;
                    '(') ST_SUBST=1; _st_seg '$('; ctx=${ctx}P; i=$((i + 2)) ;;
                    '{')
                        rest=${s:i+2}
                        body=${rest%%\}*}
                        [ "$body" != "$rest" ] || return 1
                        case "$body" in ''|*[!A-Za-z0-9_#!@*?$-]*) return 1 ;; esac
                        win=1; wx=1; w=$w'${'$body'}'; i=$((i + ${#body} + 3))
                        ;;
                    *) win=1; wx=1; w=$w'$'; i=$((i + 1)) ;;
                esac
                ;;
            '`')
                if [ "$top" = B ]; then
                    _st_seg '`'; ctx=${ctx%?}; _st_resume
                else
                    ST_SUBST=1; _st_seg '`'; ctx=${ctx}B
                fi
                i=$((i + 1))
                ;;
            '#')
                if [ "$win" = 0 ]; then
                    ST_COMMENT=1; rest=${s:i}; body=${rest%%$'\n'*}; i=$((i + ${#body}))
                else
                    w=$w'#'; i=$((i + 1))
                fi
                ;;
            ';')
                [ "${s:i+1:1}" != ';' ] || return 1
                _st_seg ';'; i=$((i + 1))
                ;;
            '&')
                c2=${s:i+1:1}
                case "$c2" in
                    '&') _st_seg '&&'; i=$((i + 2)) ;;
                    '>')
                        _st_word
                        [ -z "$rop" ] || return 1
                        if [ "${s:i+2:1}" = '>' ]; then rop='&>>'; i=$((i + 3)); else rop='&>'; i=$((i + 2)); fi
                        ;;
                    *) _st_seg '&'; i=$((i + 1)) ;;
                esac
                ;;
            '|')
                c2=${s:i+1:1}
                case "$c2" in
                    '|') _st_seg '||'; i=$((i + 2)) ;;
                    '&') _st_seg '|&'; i=$((i + 2)) ;;
                    *) _st_seg '|'; i=$((i + 1)) ;;
                esac
                ;;
            '(') _st_seg '('; ctx=${ctx}S; i=$((i + 1)) ;;
            ')')
                case "$top" in
                    P|S) _st_seg ')'; ctx=${ctx%?}; _st_resume; i=$((i + 1)) ;;
                    *) return 1 ;;
                esac
                ;;
            '<'|'>')
                fd=''
                if [ "$win" = 1 ] && [ "$wq" = 0 ] && [ -z "$rop" ]; then
                    case "$w" in *[!0-9]*) ;; *) fd=$w; w=''; win=0; wqpos=-1 ;; esac
                fi
                _st_word
                [ -z "$rop" ] || return 1
                c2=${s:i+1:1}
                c3=${s:i+2:1}
                if [ "$c" = '<' ]; then
                    case "$c2" in
                        '<')
                            if [ "$c3" = '<' ]; then op='<<<'
                            elif [ "$c3" = '-' ]; then op='<<-'; ST_HEREDOC=1
                            else op='<<'; ST_HEREDOC=1
                            fi
                            ;;
                        '&') op='<&' ;;
                        '>') op='<>' ;;
                        '(') op='<(' ;;
                        *) op='<' ;;
                    esac
                else
                    case "$c2" in
                        '>') op='>>' ;;
                        '&') op='>&' ;;
                        '|') op='>|' ;;
                        '(') op='>(' ;;
                        *) op='>' ;;
                    esac
                fi
                case "$op" in
                    '<('|'>(')
                        [ -z "$fd" ] || return 1
                        ST_SUBST=1; _st_seg "$op"; ctx=${ctx}P; i=$((i + 2))
                        ;;
                    *) rop=$fd$op; i=$((i + ${#op})) ;;
                esac
                ;;
            *)
                case "$c" in '*'|'?'|'['|'{') wg=1 ;; esac
                win=1; w=$w$c; i=$((i + 1))
                ;;
        esac
    done
    [ -z "$ctx" ] || return 1
    _st_word
    [ -z "$rop" ] || return 1
    ST_SEP[ST_NSEG]=''
    ST_NSEG=$((ST_NSEG + 1))
    [ "$bad" = 0 ] || return 1
    ST_OK=1
    return 0
}

# The helpers below run in st_tokenize's dynamic scope and share its locals.
# shellcheck disable=SC1003,SC2016,SC2034 # literal \ ` $ bytes; ST_* are read by the caller
_st_q() { # the next byte appended to the word is quoted or escaped
    [ "$wqpos" -ge 0 ] || wqpos=${#w}
    wq=1; win=1
}

# shellcheck disable=SC1003,SC2016,SC2034 # literal \ ` $ bytes; ST_* are read by the caller
_st_word() { # flush the pending word, if one was started
    local k e re='^[A-Za-z_][A-Za-z0-9_]*='
    if [ "$win" = 1 ]; then
        k=$ST_N
        ST_W[k]=$w; ST_Q[k]=$wq; ST_X[k]=$wx; ST_G[k]=$wg
        ST_S[k]=$ST_NSEG; ST_RO[k]=$rop; ST_A[k]=0
        if [ -z "$rop" ] && [[ $w =~ $re ]]; then
            e=${w%%=*}
            if [ "$wqpos" -lt 0 ] || [ "$wqpos" -gt "${#e}" ]; then ST_A[k]=1; fi
        fi
        case "$rop" in
            '<<'|'<<-'|[0-9]'<<'|[0-9]'<<-')
                hd_d[hd_n]=$w; hd_q[hd_n]=$wq
                case "$rop" in *-) hd_t[hd_n]=1 ;; *) hd_t[hd_n]=0 ;; esac
                hd_n=$((hd_n + 1))
                ;;
        esac
        ST_N=$((k + 1)); rop=''
    fi
    w=''; win=0; wq=0; wx=0; wg=0; wqpos=-1
}

# shellcheck disable=SC1003,SC2016,SC2034 # literal \ ` $ bytes; ST_* are read by the caller
_st_seg() { # end the current segment with operator $1
    _st_word
    [ -z "$rop" ] || bad=1
    ST_SEP[ST_NSEG]=$1
    ST_NSEG=$((ST_NSEG + 1))
}

# shellcheck disable=SC1003,SC2016,SC2034 # literal \ ` $ bytes; ST_* are read by the caller
_st_resume() { # back from a substitution: inside "…" the word goes on
    case "$ctx" in *D) win=1; wq=1; [ "$wqpos" -ge 0 ] || wqpos=0 ;; esac
}

# shellcheck disable=SC1003,SC2016,SC2034 # literal \ ` $ bytes; ST_* are read by the caller
_st_heredocs() { # skip the bodies of every heredoc queued on the line just ended
    local d line
    while [ "$hd_i" -lt "$hd_n" ]; do
        d=${hd_d[hd_i]}
        while [ "$i" -lt "$n" ]; do
            rest=${s:i}
            line=${rest%%$'\n'*}
            i=$((i + ${#line} + 1))
            if [ "${hd_t[hd_i]}" = 1 ]; then
                while [ "${line:0:1}" = $'\t' ]; do line=${line:1}; done
            fi
            [ "$line" != "$d" ] || break
            if [ "${hd_q[hd_i]}" = 0 ]; then
                case "$line" in *'$('*|*'`'*) ST_SUBST=1 ;; esac
            fi
        done
        hd_i=$((hd_i + 1))
    done
}

# st_sed_inert SCRIPT — 0 when SCRIPT is one sed command that can neither
# write a file nor run one: an optional line address, then `p`, `d`, or a
# single `s` command whose flags are only g p i I m M and digits (no `w`, no
# `e`). Anything else — a second command, `e`, `w`, `r`, a newline — is 1.
# shellcheck disable=SC1003,SC2016,SC2034 # literal \ ` $ bytes; ST_* are read by the caller
st_sed_inert() {
    local LC_ALL=C s="$1" d n i c part=0 re='^([0-9]+(,([0-9]+|\$))?|\$)'
    case "$s" in *$'\n'*) return 1 ;; esac
    if [[ $s =~ $re ]]; then s=${s:${#BASH_REMATCH[0]}}; fi
    case "$s" in p|d) return 0 ;; s?*) ;; *) return 1 ;; esac
    d=${s:1:1}
    case "$d" in '\'|' ') return 1 ;; esac
    n=${#s}
    i=2
    while [ "$i" -lt "$n" ] && [ "$part" -lt 2 ]; do
        c=${s:i:1}
        if [ "$c" = '\' ]; then i=$((i + 2)); continue; fi
        [ "$c" != "$d" ] || part=$((part + 1))
        i=$((i + 1))
    done
    [ "$part" = 2 ] || return 1
    case "${s:i}" in *[!gpiImM0-9]*) return 1 ;; esac
    return 0
}

# st_sed_args K INPLACE_OK — the words after a sed at word K, up to the end
# of its segment. 0 when every script it runs is inert (st_sed_inert), each
# one a plain word (no live `$`, no unquoted glob), no script comes from a
# file (-f/--file), and -i/--in-place appears only when INPLACE_OK is 1.
# Sets ST_SED_SCRIPTS to the script words' indexes, space-separated.
# shellcheck disable=SC1003,SC2016,SC2034 # literal \ ` $ bytes; ST_* are read by the caller
st_sed_args() {
    local k=$1 inpl=$2 j sg a have=0 eo=0 scripts=''
    sg=${ST_S[k]}
    j=$((k + 1))
    while [ "$j" -lt "$ST_N" ] && [ "${ST_S[j]}" = "$sg" ]; do
        if [ -n "${ST_RO[j]}" ]; then j=$((j + 1)); continue; fi
        a=${ST_W[j]}
        if [ "$eo" = 0 ]; then
            case "$a" in
                -e|--expression)
                    j=$((j + 1))
                    [ "$j" -lt "$ST_N" ] && [ "${ST_S[j]}" = "$sg" ] || return 1
                    _st_sed_script "$j" "${ST_W[j]}" || return 1
                    ;;
                --expression=*) _st_sed_script "$j" "${a#--expression=}" || return 1 ;;
                -e?*) _st_sed_script "$j" "${a#-e}" || return 1 ;;
                -f*|--file|--file=*) return 1 ;;
                -i*|--in-place|--in-place=*) [ "$inpl" = 1 ] || return 1 ;;
                -l|--line-length) j=$((j + 1)) ;;
                --line-length=*|-l[0-9]*) ;;
                --) eo=1 ;;
                --posix|--debug|--sandbox|--quiet|--silent|--regexp-extended|--separate|--unbuffered|--null-data|--zero-terminated|--follow-symlinks) ;;
                -*[!nErsuz]*) return 1 ;;
                -?*) ;;
                *)
                    if [ "$have" = 0 ]; then
                        _st_sed_script "$j" "$a" || return 1
                    fi
                    ;;
            esac
        elif [ "$have" = 0 ]; then
            _st_sed_script "$j" "$a" || return 1
        fi
        j=$((j + 1))
    done
    [ "$have" = 1 ] || return 1
    ST_SED_SCRIPTS=$scripts
    return 0
}

# shellcheck disable=SC1003,SC2016,SC2034 # literal \ ` $ bytes; ST_* are read by the caller
_st_sed_script() { # one sed script at word $1 with text $2, in st_sed_args's scope
    [ "${ST_X[$1]}" = 0 ] && [ "${ST_G[$1]}" = 0 ] || return 1
    st_sed_inert "$2" || return 1
    have=1
    scripts="$scripts $1"
}
# <<< END shell-tokenize <<<

# Quoted text that is provably inert is data, not a command (HIMMEL-3546):
# once the quote-strip above has run, a `|`, `;` or backtick inside a quoted
# argument reads exactly like a real one, and `echo 'bash scripts/cr/x.sh'`
# or `--reason "a; b"` denied as "not one simple command". When the command
# is one simple command by its tokens — a single segment, no substitution,
# heredoc, ANSI-C word or comment — $flat is rebuilt from its words with the
# inert ones left out, and every check below reads that. A word is inert
# only when it is quoted, carries no live `$` and no glob, is not a redirect
# target, has no VAR= prefix in front of its command, and is:
#   - an argument of echo, printf, grep, egrep, fgrep, jq, cat, head, tail
#     or wc, none of which runs its arguments;
#   - a sed script st_sed_args verified can neither write nor run (no `e`,
#     no `w`, no second command) — the script, never a file operand;
#   - an argument after an unquoted `.sh` path that `bash`/`sh` runs, or
#     that is itself the command word: data handed to the script whose
#     bytes the checks below verify.
# Anything else keeps the old text, so every command that was not one
# simple command still is not, and a redirect is re-emitted with its target.
if st_tokenize "$cmd" && [ "$ST_NSEG" -eq 1 ] && [ "$ST_SUBST$ST_HEREDOC$ST_ANSIC$ST_COMMENT" = 0000 ]; then
    tk_cmd=-1 tk_path=-1 tk_pre=0 tk_dropped=0 tk_flat='' ST_SED_SCRIPTS=''
    k=0
    while [ "$k" -lt "$ST_N" ]; do
        if [ -z "${ST_RO[k]}" ]; then
            if [ "${ST_A[k]}" = 1 ]; then
                tk_pre=1
            else
                tk_cmd=$k
                break
            fi
        fi
        k=$((k + 1))
    done
    if [ "$tk_pre" = 0 ] && [ "$tk_cmd" -ge 0 ] && [ "${ST_X[tk_cmd]}${ST_G[tk_cmd]}" = 00 ]; then
        case "${ST_W[tk_cmd]}" in
            bash|sh)
                k=$((tk_cmd + 1))
                while [ "$k" -lt "$ST_N" ] && [ -n "${ST_RO[k]}" ]; do k=$((k + 1)); done
                if [ "$k" -lt "$ST_N" ] && [ "${ST_Q[k]}${ST_X[k]}${ST_G[k]}" = 000 ]; then
                    case "${ST_W[k]}" in *.sh) tk_path=$k ;; esac
                fi
                ;;
            *.sh) [ "${ST_Q[tk_cmd]}" = 1 ] || tk_path=$tk_cmd ;;
            sed) st_sed_args "$tk_cmd" 1 || ST_SED_SCRIPTS='' ;;
        esac
        k=0
        while [ "$k" -lt "$ST_N" ]; do
            tk_inert=0
            if [ "$k" -gt "$tk_cmd" ] && [ -z "${ST_RO[k]}" ] && [ "${ST_Q[k]}${ST_X[k]}${ST_G[k]}" = 100 ]; then
                case "${ST_W[tk_cmd]}" in
                    echo|printf|grep|egrep|fgrep|jq|cat|head|tail|wc) tk_inert=1 ;;
                    sed) case "$ST_SED_SCRIPTS " in *" $k "*) tk_inert=1 ;; esac ;;
                    *) [ "$tk_path" -lt 0 ] || [ "$k" -le "$tk_path" ] || tk_inert=1 ;;
                esac
            fi
            if [ "$tk_inert" = 1 ]; then
                tk_dropped=1
            else
                tk_flat="$tk_flat ${ST_RO[k]}${ST_W[k]}"
            fi
            k=$((k + 1))
        done
        if [ "$tk_dropped" = 1 ]; then
            flat=${tk_flat# }
            flat=${flat//[\'\"\\]/}
        fi
    fi
fi
# A glob or brace list can spell a guarded name without either substring
# (scripts/c[r]/pr-chec[k]-context.sh), so it passes on to classification;
# so does any case of the names, which a case-insensitive filesystem folds.
names_target() { # names_target <text> - mentions pr-check, a scripts/cr/
    # target's exact path token, or an HTARGETS marker+stem, in any case. A
    # bare stem substring also matched inside an unrelated file name that
    # happens to contain it (a test suite's own name, e.g. test-cr-scores.sh
    # contains "cr-scores"), which then made every $VAR token elsewhere in
    # the same command look unresolvable (HIMMEL-3517) - so a target only
    # counts here when its stem is immediately preceded by "cr/", never as a
    # substring anywhere else.
    local t rc=1
    shopt -s nocasematch
    case "$1" in *pr-check*) rc=0 ;; esac
    for t in $TARGETS; do
        # ponytail: this is a PREFIX-stem match (cr/<stem>*), so a filename
        # that merely STARTS WITH a guarded stem after "cr/" (e.g. a target
        # named "foo.sh" also matches "cr/foo-other.sh") counts as a mention
        # even though it names a different file (codex-2 panel finding,
        # round 5, HIMMEL-3517, deferred by console ruling on
        # K-N431-7980c9b9). Over-matching here only makes `mentions` MORE
        # likely to be 1, which routes the command into the slower,
        # stricter classification path below rather than the early
        # fast-exit - the safe direction (a false-deny residual, not a
        # hole). HIMMEL-3546's tokenizer only drops provably inert quoted
        # words from $flat; it does not change this match. Upgrade path:
        # match the tokenized path word exactly, if the residual recurs.
        case "$1" in *[cC][rR]/"${t%.sh}"*) rc=0 ;; esac
    done
    # HIMMEL-3437: same prefix-stem match, keyed on each HTARGET's own
    # immediate parent directory (handover/ for merge-on-green.sh,
    # console-kit/ for go.sh) rather than a fixed "cr/" marker.
    case "$1" in *[hH]andover/merge-on-green*) rc=0 ;; esac
    case "$1" in *[cC]onsole-kit/go*) rc=0 ;; esac
    shopt -u nocasematch
    return "$rc"
}
mentions=0
names_target "$flat" && mentions=1
case "$flat" in *[cC][rR]/*|*[hH]andover/*|*[][*?]*|*'{'*) ;; *) [ "$mentions" -eq 1 ] || exit 0 ;; esac

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

is_htarget() { # is_htarget <basename> - names, or globs onto, an HTARGETS
    # basename, in any case. Basename-only, like is_target above: this is a
    # coarse candidate test, not the exact full-path match the classify loop
    # below makes before trusting it.
    local p t rc=1
    shopt -s nocasematch
    for p in $HTARGETS; do
        t=${p##*/}
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
    is_htarget "${cw##*/}" && runs=1
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
                        # executable was previously treated as safe). sed and
                        # awk are deliberately NOT on this allowlist even
                        # without -i/--in-place: sed's `e` command and awk's
                        # `system()` can execute a guarded relative script
                        # from find's changed cwd with no in-place flag at all
                        # (codex-1 round-5 panel finding, HIMMEL-3517) - they
                        # are not fixed-behavior read-only tools, so they stay
                        # chdir-gated like every other bare word.
                        case "$nextw" in
                            */*) chdir=1 ;;
                            *)
                                case "${nextw##*/}" in
                                    grep|cat|head|tail|wc|ls|stat|file|sha256sum|md5sum)
                                        is_target "${nextw##*/}" && chdir=1 ;;
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

# HIMMEL-3437 console NO-GO rounds 2-3: a "$HIMMEL_REPO/..." word is the
# anchor spelling ONLY when the whole command is genuinely one simple
# command (no separator, so nothing later in it can re-point the variable
# or hide a second command behind it), carries no wrapper or VAR=
# assignment anywhere ($wrapped, already computed above - a re-point
# earlier in the SAME command, `HIMMEL_REPO=.; bash "$HIMMEL_REPO/..."`,
# must still deny), and HIMMEL_REPO is referenced exactly once. Round 3
# (F1): the RAW command must carry no quote or backslash ANYWHERE - not
# only right next to the reference (round 2's check) - since $flat has
# already stripped every quote by the time any later check runs, and a
# stray one elsewhere still changes how a real shell groups tokens; a
# quoted or backslash-escaped reference never expands in a real shell
# either, so denying on ANY quote/backslash present is never a false
# negative on legitimate use, which needs neither (only a bare or plain
# double-quoted prefix is ever a real allow rule's spelling). Round 3
# (F2): what follows the prefix must resolve as a plain path too - no
# `..` and no further `$` (`$HIMMEL_REPO/../../etc$PWD/...` denies).
himmel_anchor_prefix=0
case "$flat" in
    *[\;\&\|\(\)\<\>\`]*|*$'\n'*) ;;
    *)
        if [ "$wrapped" -eq 0 ]; then
            case "$cmd" in
                *HIMMEL_REPO*)
                    rest=$cmd
                    n=0
                    while :; do
                        case "$rest" in *HIMMEL_REPO*) ;; *) break ;; esac
                        n=$((n + 1))
                        rest=${rest#*HIMMEL_REPO}
                    done
                    # shellcheck disable=SC1003 # literal quote/backslash match, not an escape
                    case "$cmd" in *"'"*|*'\'*) n=0 ;; esac
                    if [ "$n" -eq 1 ]; then
                        before=${cmd%%HIMMEL_REPO*}
                        after=${cmd#*HIMMEL_REPO}
                        # shellcheck disable=SC2016 # literal text match, never expanded
                        case "$before" in
                            *'"${')
                                head=${before%???}
                                case "$head" in
                                    ''|*[[:space:]])
                                        case "$after" in
                                            '}'/*'..'*|'}'/*'$'*) ;;
                                            '}'/*) himmel_anchor_prefix=1 ;;
                                        esac
                                        ;;
                                esac
                                ;;
                            *'${')
                                head=${before%??}
                                case "$head" in
                                    ''|*[[:space:]])
                                        case "$after" in
                                            '}'/*'..'*|'}'/*'$'*) ;;
                                            '}'/*) himmel_anchor_prefix=1 ;;
                                        esac
                                        ;;
                                esac
                                ;;
                            *'"$')
                                head=${before%??}
                                case "$head" in
                                    ''|*[[:space:]])
                                        case "$after" in
                                            *'..'*|*'$'*) ;;
                                            /*) himmel_anchor_prefix=1 ;;
                                        esac
                                        ;;
                                esac
                                ;;
                            *'$')
                                head=${before%?}
                                case "$head" in
                                    ''|*[[:space:]])
                                        case "$after" in
                                            *'..'*|*'$'*) ;;
                                            /*) himmel_anchor_prefix=1 ;;
                                        esac
                                        ;;
                                esac
                                ;;
                        esac
                    fi
                    ;;
            esac
        fi
        ;;
esac

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
            case "/${rel%/*}" in
                */cr|*/scripts/cr/*|*/scripts/handover|*/scripts/handover/console-kit)
                    shopt -u nocasematch; return 1 ;;
            esac
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
# <himmel_dir> spelling is one. A literal `$HIMMEL_REPO/` or `${HIMMEL_REPO}/`
# prefix (HIMMEL-3437 console finding 1, HIMMEL-3491's documented anchored
# merge-on-green.sh spelling) is exempted the same way: this hook only sees
# the raw command TEXT, never evaluates the variable, so the word is exactly
# as trusted as any other absolute path once the shell resolves it - the
# anchor, never a branch, picks HIMMEL_REPO's value (a per-call HIMMEL_REPO=
# re-point is a separate registered chokepoint, block-chokepoint-env-prefix.sh).
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
    case "$word" in *[cC][rR]/*|*[hH]andover/*) ;; *) continue ;; esac
    if [ "$himmel_anchor_prefix" -eq 1 ]; then
        # shellcheck disable=SC2016 # literal text match, never expanded
        case "$word" in '$HIMMEL_REPO/'*|'${HIMMEL_REPO}/'*) continue ;; esac
    fi
    case "$word" in
        *[][*?~\$\(\`]*|*'{'*|*'}'*) hit=1; unresolved=$word ;;
        /*) ;;
        *[[:upper:]]*) hit=1; unresolved=$word ;;
    esac
done
entries=""
hentries=""
for tok in ${flat//[;&|()<>\`=]/$'\n'}; do
    if [ "$himmel_anchor_prefix" -eq 1 ]; then
        # shellcheck disable=SC2016 # literal text match, never expanded
        case "$tok" in '$HIMMEL_REPO/'*|'${HIMMEL_REPO}/'*) continue ;; esac
    fi
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
    elif is_htarget "${rel##*/}" && ! glob_is_literal_elsewhere "$raw" "$rel"; then
        # HIMMEL-3437: the two scripts/handover/ writers, held to the entry
        # itself + scripts/cr/anchor-handoff.sh - full-path match, not a
        # TARGETS-style basename lookup, since HTARGETS entries are full
        # relative paths (a basename alone, "go.sh", is too common a stem).
        hit=1
        case " $HTARGETS " in
            *[[:space:]]"$rel"[[:space:]]*)
                case " $hentries " in *" $rel "*) ;; *) hentries="$hentries $rel" ;; esac ;;
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
for e in $hentries; do
    case " $GUARDED " in
        *' scripts/cr/anchor-handoff.sh '*) ;;
        *) GUARDED="$GUARDED scripts/cr/anchor-handoff.sh" ;;
    esac
    GUARDED="$GUARDED $e"
    # HIMMEL-3437 console finding 2: go.sh sources these two siblings via its
    # own $HERE. Once entry + the hand-off it shares with scripts/cr/ byte-
    # match the anchor's, the hand-off's own `exec` fully replaces the
    # process before $HERE (or either sibling) is ever read, landing $HERE
    # in the ANCHOR's own console-kit/ - a branch's edited siblings are
    # provably never read (verified empirically with a toy fixture, not
    # just reasoned). Listed anyway as defence in depth: for an anchor
    # predating #1212 (no hand-off wired yet) and for N463's upcoming
    # go.sh/go-gate.sh touch.
    case "$e" in
        scripts/handover/console-kit/go.sh)
            GUARDED="$GUARDED scripts/lib/go-gate.sh scripts/lib/handover-path.sh" ;;
    esac
done

shown=${cmd//$'\n'/ }
shown=${shown:0:200}

[ -z "$unresolved" ] \
    || deny "'$unresolved' does not resolve to this root's scripts/cr/ or scripts/handover/ writer by its text alone (a glob, a variable, or a path outside the root), so the bytes it runs cannot be checked."
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
    local root=$1 odd files execs oids modes prune_dirs
    # shellcheck disable=SC2086 # $GUARDED is a fixed, space-free word list
    # scripts/ and scripts/cr/ themselves must be real directories: a per-file
    # GUARDED list would otherwise read straight through a symlinked one.
    # HIMMEL-3437: scripts/handover/ and scripts/handover/console-kit/ join the
    # same check, but only when $GUARDED actually reaches under them - the
    # fixtures a scripts/cr/-only run checks never create scripts/handover/,
    # and an unconditional check here would deny those runs on a missing path.
    prune_dirs='scripts scripts/cr'
    case " $GUARDED " in
        *' scripts/handover/console-kit/go.sh '*) prune_dirs="$prune_dirs scripts/handover scripts/handover/console-kit" ;;
        *' scripts/handover/merge-on-green.sh '*) prune_dirs="$prune_dirs scripts/handover" ;;
    esac
    # shellcheck disable=SC2086 # prune_dirs is a fixed, space-free word list
    odd=$(cd "$root" && {
        find $prune_dirs -prune ! -type d
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
