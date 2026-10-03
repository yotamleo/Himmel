#!/usr/bin/env bash
# PreToolUse hook for Bash.
#
# HIMMEL-3956 / HIMMEL-3960: an agent's bare `qmd query|search|vsearch` in Bash
# can orphan a GPU-bound bun process for hours. The qmd launcher is a node
# trampoline that forwards no signals, so whatever kills it — the Bash tool's
# own timeout, a `timeout 60` prefix, the session ending — leaves the bun child
# running, reparented to init. Five such orphans ran at ~99 % CPU and up to
# 4.4 GB of VRAM for ~15 h. The himmel scripts route qmd through
# scripts/lib/qmd-bounded.sh, which kills the whole process group; this guard
# sends ad-hoc agent calls there too.
#
# REFUSED: the search verbs (`query`, `search`, `vsearch` — the ones that load
# models) when qmd is the invoked program, reached directly or through the
# launcher chain (`bun …/qmd.ts`, `node …/bin/qmd`, `bunx @tobilu/qmd`), behind
# any of the wrappers below. `timeout`, `nice`, `env` and the like are wrappers,
# NOT bounds: plain timeout(1) is exactly what fails to reap bun.
# ALLOWED: every other qmd verb (`status`, `update`, `embed`, `collection`,
# `get`, …); `bash …/qmd-bounded.sh <verb> …`, whose program is the wrapper
# script; a `qmd_bounded <secs> qmd query …` call inside a sourced script, where
# qmd is an argument and not the program; and a mere mention (`grep "qmd
# query"`, `echo qmd query`).
#
# The grammar is block-git-stash.sh's command-position shape (HIMMEL-851), with
# a wider wrapper set because the wrapper is the evasion here. It is a regex,
# not a shell parser, with the siblings' residuals in both directions: a
# separator inside quoted data (`git commit -m "a; qmd query b"`) reads as a
# command boundary and is a false DENY — the safe direction — and variable
# indirection (`q=qmd; $q query`) is a miss.
#
# HIMMEL-4121: the regex also runs over the command's words after bash-style
# quote removal (qmd_words below), so a verb or program spelled through
# quote-splitting (`qmd "qu"ery`), `$'…'` (`qmd $'\x71uery'`) or a backslash
# (`qmd \query`, `q"md" query`) is refused, and `qmd "query"" notes"` — the
# one argument `query notes` — is not.
# ponytail: the verb in a variable (`v=query; qmd "$v" x`) is still a miss —
# nothing is expanded; closing it needs value tracking, revisit if an agent is
# seen spelling the verb that way (HIMMEL-4121).
# ponytail: a nested shell string (`bash -c "qmd q\"uery\" x"`) is matched on
# its raw text only, one level deep; normalise the -c argument too if that
# spelling turns up (HIMMEL-4121). A heredoc makes qmd_words decline and the
# coarser fallback readings below decide; the shared tokenizer
# (scripts/hooks/lib/shell-tokenize.sh, HIMMEL-912) models heredocs and can
# replace qmd_words once a third inlined copy is wired into its sync suite.
#
# ponytail: Bash only — a PowerShell `qmd query` is unguarded; wire a
# PowerShell twin if a Windows station starts running qmd ad hoc (HIMMEL-3960).
#
# Hook input arrives on stdin as JSON. Exit codes:
#   0 - allow
#   2 - block; stderr is shown to the model/user
#
# Bypass: set QMD_UNBOUNDED_OK=1 in the shell that launched the agent.
# Session-sticky; restart without it to re-enable the guard.
set -euo pipefail

# Security hook: any unexpected top-level failure must deny, not fail open as a
# plain rc=1 hook error.
# shellcheck disable=SC2154 # rc is assigned inside the trap string.
trap 'rc=$?; if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit 2; fi' EXIT

if [ "${QMD_UNBOUNDED_OK:-0}" = "1" ]; then
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "block-bare-qmd-query: jq not on PATH - refusing to evaluate; install jq" >&2
    exit 2
fi

# Input handling is block-git-stash.sh's (HIMMEL-2123): builtin `read` rather
# than a `cat` substitution, blank or malformed stdin fails closed, and a
# present non-string `command` is an error rather than a silent allow; a
# `command: null` falls through to `cmd` rather than reading as empty.
input=""
IFS= read -r -d '' input 2>/dev/null || true
case "$input" in
    *[![:space:]]*) ;;
    *) echo "block-bare-qmd-query: empty/blank stdin - failing closed" >&2; exit 2 ;;
esac
if ! result=$(jq -r 'if (. == null or . == false) then error("bad-shape") else ((try (.tool_input | if has("command") and .command != null then .command else .cmd end) catch null) as $c | if ($c != null and ($c|type) != "string") then error("non-string-command") else (((try (.tool_name) catch null) // "" | tostring) + "\n" + ($c // "")) end) end' <<<"$input" 2>/dev/null); then
    echo "block-bare-qmd-query: malformed/truncated JSON on stdin - failing closed" >&2
    exit 2
fi
tool="${result%%$'\n'*}"
tool="${tool%$'\r'}"
cmd="${result#*$'\n'}"
case "$tool" in
    Bash|"") ;;
    *) exit 0 ;;
esac

[ -z "$cmd" ] && exit 0

# Lower-case and fold newlines to ';' so the anchors below see one line.
cmd_lc=$(printf '%s' "$cmd" | LC_ALL=C tr '[:upper:]\n\r' '[:lower:];;')
# The same text with every quote and backslash deleted: `q"md"`, `\qmd` and
# `$'qmd'` all read `qmd` here. A backslash-newline is folded first, as bash
# folds it, so `q\<newline>md` reads `qmd` too.
crude=${cmd//\\$'\n'/}
crude=$(printf '%s' "$crude" | LC_ALL=C tr '[:upper:]\n\r' '[:lower:];;')
crude=${crude//\$\'/\'}
# shellcheck disable=SC1003 # a literal backslash in the tr set
crude=$(printf '%s' "$crude" | LC_ALL=C tr -d '"'\''\\')

# Cheap pre-filter: no `qmd` anywhere, even with the quotes removed, and no
# `$'…'` that could decode to it — nothing to check.
case "$cmd_lc$crude" in
    *qmd*|*\$\'*) ;;
    *) exit 0 ;;
esac

# qmd_words CMD — print CMD with each word's quotes and escapes removed the
# way bash removes them (HIMMEL-4121), so `qmd "qu"ery`, `qmd $'\x71uery'`,
# `qmd \query` and `q"md" query` all print `qmd query`, while
# `qmd "query"" notes"` prints `qmd query_notes` — one word, not the verb.
# A byte that came from inside quotes, an escape or `$'…'` prints as itself
# when it is a plain character and as `_` when it is a blank, a quote, a
# backslash or a shell operator, so quoted data never reads as a word break,
# a command boundary or a quote. Unquoted text, `$(…)` and backticks
# (including those inside "…") print as they are, a newline as `;`, and a
# comment is dropped. Nothing is expanded: `$x` prints as `$x`.
# Returns 1 for what it does not model — an unterminated quote or `$(`, a
# heredoc (`<<`), a command over 16 KiB — and the caller falls back.
# shellcheck disable=SC1003,SC2016 # literal backslash, $ and ` bytes
qmd_words() {
    local LC_ALL=C
    local s="$1" out='' ctx='' top='' c c2 d v i=0 n ws=1 drop k
    n=${#s}
    [ "$n" -le 16384 ] || return 1
    while [ "$i" -lt "$n" ]; do
        c=${s:i:1}
        c2=${s:i+1:1}
        top=''
        [ -z "$ctx" ] || top=${ctx:${#ctx}-1:1}
        if [ "$top" = S ]; then
            if [ "$c" = "'" ]; then ctx=${ctx%?}; else _qw_q "$c"; fi
            i=$((i + 1))
            continue
        fi
        if [ "$top" = D ]; then
            case "$c" in
                '"') ctx=${ctx%?}; i=$((i + 1)) ;;
                '\')
                    case "$c2" in
                        '$'|'`'|'"'|'\') _qw_q "$c2"; i=$((i + 2)) ;;
                        $'\n') i=$((i + 2)) ;;
                        *) _qw_q '\'; i=$((i + 1)) ;;
                    esac
                    ;;
                '$')
                    if [ "$c2" = '(' ]; then
                        out=$out'$('; ctx=${ctx}P; ws=1; i=$((i + 2))
                    else
                        out=$out'$'; i=$((i + 1))
                    fi
                    ;;
                '`') out=$out'`'; ctx=${ctx}B; ws=1; i=$((i + 1)) ;;
                *) _qw_q "$c"; i=$((i + 1)) ;;
            esac
            continue
        fi
        # Unquoted: the top level, or a `$(…)` / backtick opened inside "…".
        case "$c" in
            "'") ctx=${ctx}S; ws=0; i=$((i + 1)) ;;
            '"') ctx=${ctx}D; ws=0; i=$((i + 1)) ;;
            '\')
                case "$c2" in
                    $'\n') ;;
                    '') _qw_q '\' ;;
                    *) _qw_q "$c2"; ws=0 ;;
                esac
                i=$((i + 2))
                ;;
            '$')
                ws=0
                if [ "$c2" = '"' ]; then
                    ctx=${ctx}D; i=$((i + 2))
                elif [ "$c2" = '(' ] && [ "${s:i+2:1}" = '(' ]; then
                    # $((…)) is arithmetic, so a `<<` in it is a shift, not
                    # a heredoc. Its value is a number and prints as 0. One
                    # holding a quote, a backslash, a backtick or `$(`, or
                    # not closed by an adjacent `))`, is declined.
                    k=$((i + 3)) d=2
                    while [ "$d" -gt 0 ]; do
                        [ "$k" -lt "$n" ] || return 1
                        case "${s:k:1}" in
                            '(') d=$((d + 1)) ;;
                            ')') d=$((d - 1)) ;;
                            "'"|'"'|'\'|'`') return 1 ;;
                            '$') [ "${s:k+1:1}" != '(' ] || return 1 ;;
                        esac
                        k=$((k + 1))
                    done
                    [ "${s:k-2:1}" = ')' ] || return 1
                    out=${out}0; i=$k
                elif [ "$c2" = "'" ]; then
                    # ANSI-C quoting: decode bash's escapes. A NUL ends the
                    # word's value; the rest of the `$'…'` is dropped.
                    i=$((i + 2)) drop=0
                    while :; do
                        [ "$i" -lt "$n" ] || return 1
                        c=${s:i:1}
                        [ "$c" = "'" ] && { i=$((i + 1)); break; }
                        if [ "$c" != '\' ]; then
                            [ "$drop" = 1 ] || _qw_q "$c"
                            i=$((i + 1))
                            continue
                        fi
                        c2=${s:i+1:1}
                        v=-1 k=0
                        case "$c2" in
                            [0-7])
                                d=$c2 k=2
                                while [ "$k" -lt 4 ]; do
                                    case "${s:i+k:1}" in [0-7]) d=$d${s:i+k:1}; k=$((k + 1)) ;; *) break ;; esac
                                done
                                v=$(( 8#$d & 255 ))
                                ;;
                            x|u|U)
                                case "$c2" in x) d=2 ;; u) d=4 ;; U) d=8 ;; esac
                                v='' k=2
                                while [ "$k" -lt $((d + 2)) ]; do
                                    case "${s:i+k:1}" in [0-9a-fA-F]) v=$v${s:i+k:1}; k=$((k + 1)) ;; *) break ;; esac
                                done
                                if [ -n "$v" ]; then
                                    v=$(( 16#$v ))
                                    [ "$c2" != x ] || v=$(( v & 255 ))
                                else
                                    v=-1 k=1
                                fi
                                ;;
                            # \c<x> is <x> & 0x1f, so @, ` and space give NUL.
                            c) case "${s:i+2:1}" in '@'|'`'|' ') v=0 ;; *) v=1 ;; esac; k=3 ;;
                            a|b|e|E|f|n|r|t|v) v=1 k=2 ;;
                            '\'|"'"|'"'|'?') v=-2 k=2 ;;
                            # An unknown escape: bash keeps `\X`, zsh (the
                            # Bash tool's shell on some stations) drops the
                            # backslash. Bash's word is never the verb, so
                            # zsh's reading is the one to check.
                            *) v=-2 k=2 ;;
                        esac
                        if [ "$drop" = 0 ]; then
                            if [ "$v" -eq 0 ]; then
                                drop=1
                            elif [ "$v" -eq -2 ]; then
                                _qw_q "$c2"
                            elif [ "$v" -gt 32 ] && [ "$v" -lt 127 ]; then
                                printf -v d '%03o' "$v"
                                printf -v d '%b' "\\0$d"
                                _qw_q "$d"
                            elif [ "$v" -ne -1 ]; then
                                out=${out}_
                            else
                                _qw_q '\'
                            fi
                        fi
                        i=$((i + k))
                    done
                else
                    out=$out'$'; i=$((i + 1))
                fi
                ;;
            '#')
                if [ "$ws" = 1 ]; then
                    while [ "$i" -lt "$n" ] && [ "${s:i:1}" != $'\n' ]; do i=$((i + 1)); done
                else
                    out=$out'#'; i=$((i + 1))
                fi
                ;;
            '<')
                if [ "$c2" = '<' ]; then
                    [ "${s:i+2:1}" = '<' ] || return 1
                    out=$out'<<<'; i=$((i + 3))
                else
                    out=$out'<'; i=$((i + 1))
                fi
                ws=1
                ;;
            '(') [ "$top" != P ] || ctx=${ctx}P; out=$out'('; ws=1; i=$((i + 1)) ;;
            ')') [ "$top" != P ] || ctx=${ctx%?}; out=$out')'; ws=1; i=$((i + 1)) ;;
            '`') [ "$top" != B ] || ctx=${ctx%?}; out=$out'`'; ws=1; i=$((i + 1)) ;;
            $'\n'|$'\r') out=$out';'; ws=1; i=$((i + 1)) ;;
            ' '|$'\t'|';'|'&'|'|'|'>') out=$out$c; ws=1; i=$((i + 1)) ;;
            *) out=$out$c; ws=0; i=$((i + 1)) ;;
        esac
    done
    [ -z "$ctx" ] || return 1
    printf '%s' "$out"
}
# _qw_q C — append a quoted or escaped byte to qmd_words' output.
_qw_q() {
    case "$1" in
        [[:alnum:]./~@:,+=%^-]) out=$out$1 ;;
        *) out=${out}_ ;;
    esac
}

# EXEPFX / ASSIGN / SEP are block-git-stash.sh's, verbatim.
EXEPFX='["'\'']?([a-z]:)?([^[:space:]|;&`"'\'']*[/\\])?'
ASSIGN='[[:alnum:]_]+=('\''[^'\'']*'\''|"[^"]*"|[^[:space:]|;&]*)'
SEP='([[:space:]]|\\[[:space:]]*;+)+[[:space:]]*'
# A run of options, each optionally taking ONE non-dash value (`-n 10`, `-k 5`).
OPTV='([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*'
# Wrappers that run their argument as a program. timeout takes its duration.
WRAP='(sudo|doas|nice|ionice|chrt|taskset|stdbuf|setsid|nohup|command|exec|time|xargs|(ba|z|da|k)?sh(\.exe)?)'"$OPTV"
WRAP="($WRAP|timeout${OPTV}[[:space:]]+[0-9.]+[smhd]?|env([[:space:]]+(-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?|$ASSIGN))*|if|then|else|elif|do|while|until|!)"
CMDPOS='(^|[|;&(`{])[[:space:]]*(('"$ASSIGN"'|'"$EXEPFX$WRAP"')[[:space:]]+)*'"$EXEPFX"
# The program: qmd itself, or a JS runtime handed qmd's entry point.
RUNTIME='((bun|node|bunx|npx|deno)(\.exe)?["'\'']?'"$OPTV"'[[:space:]]+((run|x)[[:space:]]+)?'"$EXEPFX"')?'
QMDPROG="${RUNTIME}"'qmd(\.(ts|js|mjs|cjs|exe|cmd))?["'\'']?'
# qmd's global options (`--index <name>`) sit between the program and the verb.
QMDOPTVAL='('\''[^'\'']*'\''|"[^"]*"|[^-[:space:]][^[:space:]]*)'
QMDOPTS='('"${SEP}"'-[^[:space:]]+('"${SEP}${QMDOPTVAL}"')?)*'
# The verb may be quoted (`qmd "query" x`, HIMMEL-4011); the shell strips the
# quote, so it is still the verb. The quotes must match around the verb alone,
# so `qmd "query notes"` (one argument, not the verb) is not refused.
QMDVERB='(query|search|vsearch)'
BARE="${CMDPOS}${QMDPROG}${QMDOPTS}${SEP}"'('"${QMDVERB}"'|"'"${QMDVERB}"'"|'\''('"${QMDVERB}"')'\'')'
BOUND='([^[:alnum:]_-]|$)'
# On the raw text a quote after the verb continues the word (`qmd "query""
# notes"` is the one argument `query notes`), so it is no boundary there; the
# normalised words below decide whether that word is still the verb.
RAWBOUND='([^[:alnum:]_"'\''-]|$)'

# Two readings, deny on either (HIMMEL-4121). The raw text keeps what quote
# removal hides — a separator or a nested `bash -c "qmd query"` inside quoted
# data. The normalised words see the verb and program bash will run after its
# quote removal. When the normaliser declines (a heredoc, an unterminated
# quote, over 16 KiB), three readings stand in for it: the pre-HIMMEL-4121
# raw match; the quote-stripped text, which catches quote-splitting and
# backslashes; and, because that text cannot decode `$'…'` or `$"…"`, a deny
# for a qmd program with either in its arguments, or for a program word
# spelled with one and followed by one or a verb. It is not a parser: it
# over-denies some commands and can still miss a spelling only full parsing
# would decode.
# shellcheck disable=SC1003 # a literal backslash in the tr set
ansi_q() {
    local t=${cmd//\\$'\n'/}
    t=${t//\$\'/$'\001'}
    t=${t//\$\"/$'\001'}
    printf '%s' "$t" | LC_ALL=C tr '[:upper:]\n\r' '[:lower:];;' | LC_ALL=C tr -d '"'\''\\'
}
AQ_PROG='[^[:space:];&|]*'$'\001''[^[:space:];&|]*'
AQ_ARGS="${CMDPOS}${QMDPROG}[[:space:]][^;&|]*"$'\001'
AQ_WORD="${CMDPOS}${AQ_PROG}[[:space:]][^;&|]*("$'\001'"|${QMDVERB})"
deny=0
if words=$(qmd_words "$cmd"); then
    words_lc=$(printf '%s' "$words" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    if [[ $words_lc =~ $BARE$BOUND ]] || [[ $cmd_lc =~ $BARE$RAWBOUND ]]; then
        deny=1
    fi
elif [[ $cmd_lc =~ $BARE$BOUND ]] || [[ $crude =~ $BARE$BOUND ]]; then
    deny=1
else
    aq=$(ansi_q)
    if [[ $aq =~ $AQ_ARGS ]] || [[ $aq =~ $AQ_WORD ]]; then
        deny=1
    fi
fi

if [ "$deny" = 1 ]; then
    bounded="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)/qmd-bounded.sh"
    cat >&2 <<DENY
block-bare-qmd-query: a bare qmd query/search/vsearch is refused (HIMMEL-3956).

The qmd launcher forwards no signals, so when this call is killed — by the Bash
tool's timeout, a timeout(1) prefix or the session ending — its bun child keeps
running on the GPU, orphaned. Five such queries ran for ~15 h.

Run it under the group deadline instead (default ${QMD_TIMEOUT_SECS:-300} s, set QMD_TIMEOUT_SECS):
    bash $bounded query -c <collection> "<question>"
or use the qmd MCP tool (mcp__qmd__query), which the harness manages.

Non-search verbs (status, update, embed, collection, get) are not refused.
Bypass (deliberate, session-sticky): launch with QMD_UNBOUNDED_OK=1.
DENY
    exit 2
fi

exit 0
