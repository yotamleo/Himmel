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
# A second line, after a `:`, lists the offset of every quote byte that
# does not open a string: one closing a string, or data inside quotes.
# Returns 1 for what it does not model — an unterminated quote or `$(`, a
# heredoc (`<<`), a command over 16 KiB — and the caller falls back.
# A third line, after the second newline and up to a closing `.`, is the
# decoded text (HIMMEL-4151): the same bytes as the first line, one for one,
# but a quoted or escaped byte prints as the byte itself — the value bash
# hands the program — so a word's span in the first line is its value here.
# ponytail: a word of empty quotes alone vanishes, so `qmd "" query x` reads
# `qmd query x` and is over-denied; emit a placeholder for it (HIMMEL-4141).
# shellcheck disable=SC1003,SC2016 # literal backslash, $ and ` bytes
qmd_words() {
    local LC_ALL=C
    local s="$1" out='' dec='' ctx='' top='' c c2 d v dv i=0 n ws=1 drop k qp=''
    n=${#s}
    [ "$n" -le 16384 ] || return 1
    while [ "$i" -lt "$n" ]; do
        c=${s:i:1}
        c2=${s:i+1:1}
        top=''
        [ -z "$ctx" ] || top=${ctx:${#ctx}-1:1}
        case "$top$c" in [SD]\'|[SD]\") qp="$qp $i" ;; esac
        if [ "$top" = S ]; then
            if [ "$c" = "'" ]; then ctx=${ctx%?}; else _qw_q "$c"; fi
            i=$((i + 1))
            continue
        fi
        if [ "$top" = D ]; then
            case "$c" in
                '"') ctx=${ctx%?}; ws=0; i=$((i + 1)) ;;
                '\')
                    case "$c2" in
                        '$'|'`'|'"'|'\') _qw_q "$c2"; i=$((i + 2)) ;;
                        $'\n') i=$((i + 2)) ;;
                        *) _qw_q '\'; i=$((i + 1)) ;;
                    esac
                    ;;
                '$')
                    if [ "$c2" = '(' ]; then
                        out=$out'$(' dec=$dec'$('; ctx=${ctx}P; ws=1; i=$((i + 2))
                    else
                        out=$out'$' dec=$dec'$'; i=$((i + 1))
                    fi
                    ;;
                '`') out=$out'`' dec=$dec'`'; ctx=${ctx}B; ws=1; i=$((i + 1)) ;;
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
                    out=${out}0 dec=${dec}0; i=$k
                elif [ "$c2" = "'" ]; then
                    # ANSI-C quoting: decode bash's escapes. A NUL ends the
                    # word's value; the rest of the `$'…'` is dropped.
                    i=$((i + 2)) drop=0
                    while :; do
                        [ "$i" -lt "$n" ] || return 1
                        c=${s:i:1}
                        case "$c" in "'"|'"') qp="$qp $i" ;; esac
                        [ "$c" = "'" ] && { i=$((i + 1)); break; }
                        if [ "$c" != '\' ]; then
                            [ "$drop" = 1 ] || _qw_q "$c"
                            i=$((i + 1))
                            continue
                        fi
                        c2=${s:i+1:1}
                        v=-1 k=0 dv=''
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
                            # \c<x> is <x> & 0x1f in bash, so @, ` and space
                            # give NUL; zsh reads it as a plain `c<x>`. Bash's
                            # control byte can never be part of the verb, so
                            # zsh's reading is the one to check, except where
                            # bash ends the word (NUL) or breaks it (tab,
                            # newline). `\c'` ends the string in zsh only, so
                            # the shells split the words differently: decline.
                            c)
                                case "${s:i+2:1}" in
                                    "'"|'') return 1 ;;
                                    '@'|'`'|' ') v=0 k=3 ;;
                                    *)
                                        printf -v dv '%d' "'${s:i+2:1}"; dv=$(( dv & 31 ))
                                        if [ "$dv" = 9 ] || [ "$dv" = 10 ]; then v=1 k=3; else v=-2 k=2 dv=''; fi
                                        ;;
                                esac
                                ;;
                            # zsh's \C-<x> and \M-<x> give one control or meta
                            # byte, and a bare \C or \M, or one with nothing
                            # after its `-`, gives nothing. Bash keeps them as
                            # `\C`, never the verb.
                            C|M)
                                case "${s:i+2:1}${s:i+3:1}" in
                                    -"'"|-'\'|-) v=-3 k=3 ;;
                                    -?) v=1 k=4 ;;
                                    *) v=-3 k=2 ;;
                                esac
                                ;;
                            # dv is the byte the decoded text (dec) gets; a
                            # newline or a tab is a word break in it.
                            n) v=1 k=2 dv=10 ;;
                            t) v=1 k=2 dv=9 ;;
                            a|b|e|E|f|r|v) v=1 k=2 ;;
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
                            elif [ "$v" -eq -3 ]; then
                                :
                            elif [ "$v" -eq -2 ]; then
                                _qw_q "$c2"
                            elif [ "$v" -gt 32 ] && [ "$v" -lt 127 ]; then
                                printf -v d '%03o' "$v"
                                printf -v d '%b' "\\0$d"
                                _qw_q "$d"
                            elif [ "$v" -ne -1 ]; then
                                out=${out}_
                                [ -n "$dv" ] || dv=$v
                                if [ "$dv" -gt 0 ] && [ "$dv" -lt 127 ]; then
                                    printf -v d '%03o' "$dv"
                                    printf -v d '%b' "\\0$d"
                                    dec=$dec$d
                                else
                                    dec=$dec'?'
                                fi
                            else
                                _qw_q '\'
                            fi
                        fi
                        i=$((i + k))
                    done
                else
                    out=$out'$' dec=$dec'$'; i=$((i + 1))
                fi
                ;;
            '#')
                if [ "$ws" = 1 ]; then
                    while [ "$i" -lt "$n" ] && [ "${s:i:1}" != $'\n' ]; do i=$((i + 1)); done
                else
                    out=$out'#' dec=$dec'#'; i=$((i + 1))
                fi
                ;;
            '<')
                if [ "$c2" = '<' ]; then
                    [ "${s:i+2:1}" = '<' ] || return 1
                    out=$out'<<<' dec=$dec'<<<'; i=$((i + 3))
                else
                    out=$out'<' dec=$dec'<'; i=$((i + 1))
                fi
                ws=1
                ;;
            '(') [ "$top" != P ] || ctx=${ctx}P; out=$out'(' dec=$dec'('; ws=1; i=$((i + 1)) ;;
            # A `#` right after `)` or a backtick (closing a substitution
            # continues its word) is read as no comment: more text read can
            # only add denials.
            ')') [ "$top" != P ] || ctx=${ctx%?}; out=$out')' dec=$dec')'; ws=0; i=$((i + 1)) ;;
            '`') [ "$top" != B ] || ctx=${ctx%?}; out=$out'`' dec=$dec'`'; ws=0; i=$((i + 1)) ;;
            $'\n'|$'\r') out=$out';' dec=$dec';'; ws=1; i=$((i + 1)) ;;
            ' '|$'\t'|';'|'&'|'|'|'>') out=$out$c dec=$dec$c; ws=1; i=$((i + 1)) ;;
            *) out=$out$c dec=$dec$c; ws=0; i=$((i + 1)) ;;
        esac
    done
    [ -z "$ctx" ] || return 1
    printf '%s\n:%s\n%s.' "$out" "$qp" "$dec"
}
# _qw_q C — append a quoted or escaped byte to qmd_words' output.
_qw_q() {
    case "$1" in
        [[:alnum:]./~@:,+=%^-]) out=$out$1 ;;
        *) out=${out}_ ;;
    esac
    dec=$dec$1
}

# EXEPFX / ASSIGN / SEP are block-git-stash.sh's, verbatim.
EXEPFX='["'\'']?([a-z]:)?([^[:space:]|;&`"'\'']*[/\\])?'
ASSIGN='[[:alnum:]_]+=('\''[^'\'']*'\''|"[^"]*"|[^[:space:]|;&]*)'
SEP='([[:space:]]|\\[[:space:]]*;+)+[[:space:]]*'
# A run of options, each optionally taking ONE non-dash value (`-n 10`, `-k 5`).
OPTV='([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*'
# Wrappers that run their argument as a program. timeout takes its duration.
WRAP='(sudo|doas|nice|ionice|chrt|taskset|stdbuf|setsid|nohup|command|exec|eval|time|xargs|(ba|z|da|k)?sh(\.exe)?)'"$OPTV"
WRAP="($WRAP|timeout${OPTV}[[:space:]]+[0-9.]+[smhd]?|env([[:space:]]+(-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?|$ASSIGN))*|if|then|else|elif|do|while|until|!)"
# A case arm's `)` is a command position too, and zsh runs `=qmd` as the
# qmd its PATH finds (HIMMEL-4140).
CMDREST='[[:space:]]*(('"$ASSIGN"'|=?'"$EXEPFX$WRAP"')[[:space:]]+)*=?'"$EXEPFX"
CMDPOS='(^|[|;&()`{])'"$CMDREST"
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
# On the raw text a quote that OPENS a string after the verb continues the
# word (`qmd "query"" notes"` is the one argument `query notes`), so it is no
# boundary there; the normalised words decide whether that word is still the
# verb. Every other quote (one closing a string, as in a nested `bash -c`
# string ending in the verb, or one that is data inside quotes) stays a
# boundary, as on main: a raw match ending at such a quote (BAREEND, tested
# on the text before it) denies.
RAWBOUND='([^[:alnum:]_"'\''-]|$)'
BAREEND="$BARE"'$'
# qp_deny OFFSETS — succeed when the raw text up to one of qmd_words' quote
# offsets ends in a bare verb. The offsets count bytes, so the slice must
# too: under a UTF-8 locale a multibyte character would shift it (J1666c).
qp_deny() {
    local LC_ALL=C p
    for p in $1; do
        # A verb quoted inside the string ends in its own quote (J1666d).
        case "${cmd_lc:0:p}" in *query|*search|*query[\"\']|*search[\"\']) ;; *) continue ;; esac
        [[ ${cmd_lc:0:p} =~ $BAREEND ]] && return 0
    done
    return 1
}

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
    t=${t//\$\'/$'\002'}
    t=${t//\$\"/$'\002'}
    printf '%s' "$t" | LC_ALL=C tr '[:upper:]\n\r' '[:lower:];;' | LC_ALL=C tr -d '"'\''\\'
}
# The sentinel is 0x02, not 0x01: bash 3.2's =~ drops a literal 0x01 (its
# internal CTLESC) from the regex, fixed only in bash 4.2.14.
AQ_PROG='[^[:space:];&|]*'$'\002''[^[:space:];&|]*'
AQ_ARGS="${CMDPOS}${QMDPROG}[[:space:]][^;&|]*"$'\002'
AQ_WORD="${CMDPOS}${AQ_PROG}[[:space:]][^;&|]*("$'\002'"|${QMDVERB})"
# HIMMEL-4140 / HIMMEL-4151: a nested shell runs its -c string, and eval its
# words joined by blanks, through the same quote removal again. The decoded
# value of each such word is read as a command, and its own nested strings in
# turn, to a depth of four; a deeper one is refused. A nested string that
# names qmd and that the normaliser cannot read, or one whose program
# position holds a command substitution (`sh -c "$(echo qmd) query"`), is
# refused rather than guessed; one that cannot be read and does not name qmd
# gets the top-level fallback readings.
# Any word naming a shell counts, not only one in program position: a mention
# (`echo bash -c 'qmd query'`) reads as a nested command too, the safe
# direction.
# Its boundary has no `(`: inside "…" qmd_words reads `$((` as `$(` and `(`,
# so `"$(( $(date +%s) - 1 ))"` would read as a substitution program.
SUBPROG='(^|[|;&)`{])'"$CMDREST"'(\$\(|`)'
NESTSEP=' '$'\t'';&|()`<>'
# qmd_nested WORDS DEC DEPTH — run qmd_check on what each nested shell or
# eval in WORDS (qmd_words' first line, lower-cased) would run, spelled as in
# DEC (its decoded line). Sets deny=1 on the first refusal.
# shellcheck disable=SC2016 # literal $ and ` bytes
qmd_nested() {
    local LC_ALL=C w=$1 dec=$2 depth=$3 n i=0 j e c t v mode hasc pd bq scr rd
    n=${#w}
    while [ "$i" -lt "$n" ]; do
        case "$NESTSEP" in *"${w:i:1}"*) i=$((i + 1)); continue ;; esac
        j=$i
        while [ "$j" -lt "$n" ]; do
            case "$NESTSEP" in *"${w:j:1}"*) break ;; esac
            j=$((j + 1))
        done
        t=${w:i:j-i}
        i=$j
        t=${t#=}
        t=${t##*/}
        case "$t" in
            sh|bash|zsh|dash|ksh|sh.exe|bash.exe|zsh.exe|dash.exe|ksh.exe) mode='sh' ;;
            eval) mode='eval' ;;
            *) continue ;;
        esac
        # The words that follow, to the end of the simple command. A word
        # keeps a `$(…)` or backtick substitution in it whole, blanks and all.
        e=$i hasc=0 scr='' rd=0
        while :; do
            while [ "$e" -lt "$n" ]; do
                case "${w:e:1}" in ' '|$'\t') e=$((e + 1)) ;; *) break ;; esac
            done
            if [ "$e" -ge "$n" ]; then break; fi
            # A redirection (`<f`, `2>&1`, `&>f`, `<<<w`) sits anywhere among
            # the words: step over its operator and drop its target word.
            if [[ ${w:e:2} == '&>' ]] || [[ ${w:e:1} == [\<\>] ]]; then
                while [ "$e" -lt "$n" ]; do
                    case "${w:e:1}" in '<'|'>'|'&'|'|') e=$((e + 1)) ;; *) break ;; esac
                done
                rd=1
                continue
            fi
            case "${w:e:1}" in ';'|'&'|'|'|'('|')') break ;; esac
            j=$e pd=0 bq=0
            while [ "$j" -lt "$n" ]; do
                c=${w:j:1}
                if [ "$bq" = 1 ]; then
                    if [ "$c" = '`' ]; then bq=0; fi
                elif [ "$pd" -gt 0 ]; then
                    case "$c" in '(') pd=$((pd + 1)) ;; ')') pd=$((pd - 1)) ;; esac
                elif [ "$c" = '$' ] && [ "${w:j+1:1}" = '(' ]; then
                    pd=1 j=$((j + 1))
                elif [ "$c" = '`' ]; then
                    bq=1
                else
                    case "$c" in ' '|$'\t'|';'|'&'|'|'|'('|')'|'<'|'>') break ;; esac
                fi
                j=$((j + 1))
            done
            t=${w:e:j-e}
            v=${dec:e:j-e}
            e=$j
            if [ "$rd" = 1 ]; then
                rd=0
            elif [ "$mode" = eval ]; then
                scr="$scr $v"
            elif [ "$hasc" = 0 ]; then
                # The string is the first word after an option cluster
                # holding c (`-c`, `-ec`, `-lc`); the later words ($0 and its
                # arguments) are read too — more reading only adds denials.
                if [[ $t =~ ^-[[:alpha:]]*c[[:alpha:]]*$ ]]; then hasc=1; fi
            else
                qmd_check "$v" $((depth + 1))
                if [ "$deny" = 1 ]; then return 0; fi
            fi
        done
        if [ -n "$scr" ]; then
            qmd_check "$scr" $((depth + 1))
            if [ "$deny" = 1 ]; then return 0; fi
        fi
    done
    return 0
}

# qmd_check CMD DEPTH — set deny=1 when CMD runs a bare search verb. DEPTH is
# 0 for the tool call's command and counts nested strings. It always returns
# 0 and is called bare, so set -e still stops the hook (and the EXIT trap
# denies) on a failure inside it.
qmd_check() {
    local cmd=$1 depth=$2 cmd_lc crude res words words_lc dec aq
    if [ "$depth" -gt 4 ]; then deny=1; return 0; fi
    # Lower-case and fold newlines to ';' so the anchors below see one line.
    cmd_lc=$(printf '%s' "$cmd" | LC_ALL=C tr '[:upper:]\n\r' '[:lower:];;')
    # The same text with every quote and backslash deleted: `q"md"`, `\qmd` and
    # `$'qmd'` all read `qmd` here. A backslash-newline is folded first, as bash
    # folds it, so `q\<newline>md` reads `qmd` too.
    crude=${cmd//\\$'\n'/}
    crude=$(printf '%s' "$crude" | LC_ALL=C tr '[:upper:]\n\r' '[:lower:];;')
    crude=${crude//\$\'/\'}
    crude=${crude//\$\"/\"}
    # shellcheck disable=SC1003 # a literal backslash in the tr set
    crude=$(printf '%s' "$crude" | LC_ALL=C tr -d '"'\''\\')

    # Cheap pre-filter: no `qmd` anywhere, even with the quotes removed, and no
    # `$'…'` or `$"…"` that could spell it — nothing to check.
    case "$cmd_lc$crude" in
        *qmd*|*\$\'*|*\$\"*) ;;
        *) return 0 ;;
    esac
    if res=$(qmd_words "$cmd"); then
        words=${res%%$'\n'*}
        res=${res#*$'\n'}
        dec=${res#*$'\n'}
        dec=${dec%.}
        res=${res%%$'\n'*}
        words_lc=$(printf '%s' "$words" | LC_ALL=C tr '[:upper:]' '[:lower:]')
        if [[ $words_lc =~ $BARE$BOUND ]] || [[ $cmd_lc =~ $BARE$RAWBOUND ]]; then
            deny=1
        elif qp_deny "${res#:}"; then
            deny=1
        elif [ "$depth" -gt 0 ] && [[ $words_lc =~ $SUBPROG ]]; then
            deny=1
        else
            qmd_nested "$words_lc" "$dec" "$depth"
        fi
    elif [ "$depth" -gt 0 ] && [[ $crude == *qmd* ]]; then
        deny=1
    elif [[ $cmd == *"\\c'"* ]] && [[ $crude == *qmd* ]]; then
        # qmd_words declines an ANSI-C `\c'`: bash and zsh split it apart.
        deny=1
    elif [[ $cmd_lc =~ $BARE$BOUND ]] || [[ $crude =~ $BARE$BOUND ]]; then
        deny=1
    else
        aq=$(ansi_q)
        if [[ $aq =~ $AQ_ARGS ]] || [[ $aq =~ $AQ_WORD ]]; then
            deny=1
        fi
    fi
    return 0
}

deny=0
qmd_check "$cmd" 0

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
