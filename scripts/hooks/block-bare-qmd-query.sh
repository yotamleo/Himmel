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
# indirection (`q=qmd; $q query`) is a miss (HIMMEL-4178). HIMMEL-4574 drops
# that false DENY where every command run is a reader (readers_only below):
# `grep -E 'a|qmd query' f | head` is a pattern, not a boundary.
#
# HIMMEL-4121: the regex also runs over the command's words after bash-style
# quote removal (qmd_words below), so a verb or program spelled through
# quote-splitting (`qmd "qu"ery`), `$'…'` (`qmd $'\x71uery'`) or a backslash
# (`qmd \query`, `q"md" query`) is refused, and `qmd "query"" notes"` — the
# one argument `query notes` — is not.
# ponytail: the verb in a variable (`v=query; qmd "$v" x`) is still a miss —
# nothing is expanded; closing it needs value tracking (HIMMEL-4178).
# ponytail: nested strings (`-c`, eval) are decoded and re-read to depth four
# (HIMMEL-4151), for every shell the hook names, the launchers that take a
# string (`su -c`, `script -c`, `flock -c`, `env -S`, watch, parallel) and a
# shell's here-string (HIMMEL-4166); what a shell reads from a pipe or a
# process substitution, and an alias for qmd, cannot be read and fail closed
# on naming qmd and a verb. A shell fed by a file (`sh <f`) is unread.
# HIMMEL-4244 adds sg, tmux, screen, at/batch, `builtin`, the prefix
# wrappers (setpriv … pkexec) and elvish/nu/xonsh/pwsh `-c`.
# HIMMEL-4305: a launcher that types or ships its command elsewhere fails
# closed on naming qmd and a verb anywhere in its words: tmux (every
# subcommand; send-keys -H hex decoded), screen (its \ooo, \n and ^X decoded),
# and the remote and container launchers (ssh, docker, podman, nerdctl,
# kubectl, oc, lxc, incus, distrobox, toolbox). pwsh/powershell
# -EncodedCommand is base64-decoded (UTF-16LE) and read as a command.
# HIMMEL-4330 / HIMMEL-4337: a pipe continues across a newline; the `&` of a
# redirection (`2>&1`, `&>f`) is no boundary; a piped stage that is no plain
# filter and holds anything that runs its stdin — a shell, an interpreter
# (python, perl, node, …, whose -c/-e string is read too), eval, xargs, an
# expansion as the program, a launcher, a filter given an executing script —
# fails closed on a producer naming a verb; and a shell or interpreter run on
# a file the same command wrote (`… > f; sh f`, `… | tee f; bash f`) fails
# closed on the command naming one.
# ponytail: an expansion is read as a stage's program only in program
# position (`| nice $l` is unread), and a written file only as the first
# operand and only when written by the same command; tracking values across
# commands and wrappers is HIMMEL-4178.
# ponytail: names_verb is a substring test, so a launcher whose words merely
# contain one (`tmux new -s research 'qmd status'`, `ssh research qmd status`)
# is over-denied — the safe direction; a word-bounded test is the upgrade,
# taken when such an over-deny is reported.
# A heredoc makes qmd_words decline and the coarser fallback readings below
# decide; the shared tokenizer (scripts/hooks/lib/shell-tokenize.sh,
# HIMMEL-912) models heredocs and can replace qmd_words once a third inlined
# copy is wired into its sync suite.
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
                            # `\C`, never the verb. zsh's \C-<x> is <x> & 0x1f,
                            # so \C-i is a tab and \C-j a newline in dec.
                            C|M)
                                case "${s:i+2:1}${s:i+3:1}" in
                                    -"'"|-'\'|-) v=-3 k=3 ;;
                                    -?)
                                        v=1 k=4
                                        if [ "$c2" = C ]; then
                                            printf -v dv '%d' "'${s:i+3:1}"; dv=$(( dv & 31 ))
                                            [ "$dv" = 9 ] || [ "$dv" = 10 ] || dv=''
                                        fi
                                        ;;
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
# HIMMEL-4218: watch, unbuffer, parallel and systemd-run too; flock takes its
# lock file first.
# HIMMEL-4244: builtin, the privilege, namespace, sandbox, tracing and
# session wrappers, and the -c shells elvish, nu, xonsh and pwsh. chroot and
# sg take one operand before the program, a bwrap option up to two values,
# and tmux runs the command of a session-starting subcommand.
TMUXSUB='(new(-session|-window)?|neww|split(-window|w)|respawn(-pane|-window|p|w)|run(-shell)?)'
TMUXREST="[[:space:]]${TMUXSUB}([[:space:]].*)?\$"
WRAP='(sudo|doas|nice|ionice|chrt|taskset|stdbuf|setsid|nohup|command|builtin|busybox|exec|eval|coproc|time|xargs|watch|unbuffer|parallel|systemd-run|systemd-inhibit|su|runuser|script|setpriv|unshare|nsenter|firejail|xvfb-run|strace|ltrace|chpst|cgexec|pkexec|screen|elvish|nu|xonsh|pwsh(\.exe)?|powershell(\.exe)?|fish|(r?ba|z|da|k|mk|lk|ok|pdk|po|ya|a|tc|c)?sh(\.exe)?)'"$OPTV"
WRAP="($WRAP|timeout${OPTV}[[:space:]]+[0-9.]+[smhd]?|(flock|chroot|sg)${OPTV}[[:space:]]+[^-[:space:]][^[:space:]]*|bwrap([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*([[:space:]]+[^-[:space:]][^[:space:]]*)?)?)*|tmux${OPTV}[[:space:]]+${TMUXSUB}${OPTV}|env([[:space:]]+(-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?|$ASSIGN))*|if|then|else|elif|do|while|until|!)"
# A case arm's `)` is a command position too, and zsh runs `=qmd` as the
# qmd its PATH finds (HIMMEL-4140).
# ponytail: any `)` opens a command, so `echo "$(x)"qmd query` over-denies;
# telling a case arm from a substitution's close is HIMMEL-4172.
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
# gets the top-level fallback readings. At the top level a substitution in
# program position is refused only when the command names qmd
# (`$(echo qmd) query x`). There a `)` or backtick usually closes the
# previous substitution (`x "$(a)" "$(b)"`), so SUBTOP drops both from the
# boundary, and keeps `)` only in a command holding a `case` word.
# Any word naming a shell counts, not only one in program position: a mention
# (`echo bash -c 'qmd query'`) reads as a nested command too, the safe
# direction.
# Its boundary has no `(`: inside "…" qmd_words reads `$((` as `$(` and `(`,
# so `"$(( $(date +%s) - 1 ))"` would read as a substitution program.
SUBPROG='(^|[|;&)`{])'"$CMDREST"'(\$\(|`)'
SUBTOP='(^|[|;&{])'"$CMDREST"'(\$\(|`)'
CASEWORD='(^|[^[:alnum:]_])case[[:space:]]'
# HIMMEL-4166: a positional parameter ("$@", $1) as the program or as qmd's
# verb is refused when the command names qmd and a verb (`set -- qmd query
# x; "$@"`).
POSPROG='(^|[|;&()`{])'"$CMDREST"'\$\{?[@*0-9]'
POSVERB="${CMDPOS}${QMDPROG}${QMDOPTS}${SEP}"'\$\{?[@*0-9]'
NESTSEP=' '$'\t'';&|()`<>'
NESTWORD='(^|[^[:alnum:]_.-])((r?ba|z|da|k|mk|lk|ok|pdk|po|ya|a|tc|c)?sh|fish|elvish|nu|xonsh|pwsh|powershell|sg|su|runuser|script|flock|source|at|batch|eval|watch|parallel|tmux|screen|env|alias|xargs|python[0-9.]*|pypy[0-9]*|perl[0-9.]*|ruby|irb|node|nodejs|bun|deno|php|lua|luajit|tclsh|expect|rscript|osascript|ssh|docker|podman|nerdctl|kubectl|oc|lxc|incus|distrobox|toolbox)(\.exe)?([^[:alnum:]_.-]|$)|<<<|<\('
# HIMMEL-4166 / HIMMEL-4218: what each word that runs a nested string does
# with the words after it. sh: a shell, or a launcher taking `-c STRING`
# (su, runuser, script, flock, sg); it also runs a here-string, a process
# substitution or, after a `|`, its stdin. src: source and `.`, and at and
# batch (HIMMEL-4244), which run those three but take no -c. eval: its words
# joined. run: watch and parallel, which join their words into one command
# too; tmux: the words after its session-starting subcommand, and all its
# words joined fail closed (HIMMEL-4305). screen and rem (ssh, docker, …):
# their words joined fail closed; the words stay read as the top level reads
# them. int: an interpreter, whose -c/-e-style string fails closed (HIMMEL-4337).
# env: its -S string and the words after it. alias: a definition naming qmd.
# HIMMEL-4337: every mode but env and alias runs a piped stdin.
# HIMMEL-4245: a pipe consumer stage that is a plain non-executing filter
# reads a shell word as an operand (`… | grep -v sh`), not as a program. Its
# program word is bare or /usr/bin- or /bin-prefixed, behind no wrapper but
# xargs with plain flag or count options, and no assignment or redirection. Every other stage — any launcher, modelled or
# not — keeps a shell word anywhere in it fail-closed. less and more are no
# filter: `+`/`!` commands and $LESS run a shell.
FILTPROG='^&?[[:space:]]*(xargs([[:space:]]+-([0rtx]+|[nlps][[:space:]]*[0-9]+))*[[:space:]]+)?(/usr/bin/|/bin/)?(grep|egrep|fgrep|rg|sed|awk|gawk|mawk|nawk|head|tail|wc|sort|uniq|cut|tr|cat|column|jq)([[:space:]]|$)'
# A command that could make a filter name run something else — a quoted,
# escaped or spliced consumer program (raw text), an alias, a function, a
# hash or enable entry, a PATH assignment or a sourced file — clears no stage.
FILTDECO='\|&?[[:space:]]*[^[:space:]|;&()<>]*["'\''\\]'
FILTREDEF='(^|[^[:alnum:]_])(alias|function|hash|enable|path=)|(^|[;&|({][[:space:]]*|(builtin|command|eval|exec)[[:space:]]+)(source|\.)([[:space:]]|$)|\([[:space:]]*\)'
AWKOPT='(^|[[:space:]])-[^Fv[:space:]]'
# A `|` (or `|&`) and then a newline anywhere in the rest of the command; the
# newline prints as `;` (a CR before it is a blank).
PIPENL='\|&?[[:space:]]*;'
# pipe_filter STAGE DEC — succeed when the consumer stage STAGE (qmd_words'
# text, DEC its decoded bytes) is a plain filter. Its program is matched in
# DEC too, so a case-folded name (`SED`, `GREP`) is no filter. sed takes only
# option words made of n/E/r/s/u/z, or a bare -e whose next word is script;
# no other word holds an e, w or W (`-ee` is `-e e`, run the pattern space);
# awk no system, getline, `|` or @-directive and only -F/-v options; no stage
# holds a long option (rg --pre, sort --compress-program), a substitution,
# subshell, group, list or expansion. Behind xargs the producer's bytes become the
# filter's ARGUMENTS (`-e e`, `--pre=sh`), so only filters with no executing
# option at all qualify there.
# shellcheck disable=SC2016 # literal ` bytes
pipe_filter() {
    local s=$1 d=$2 p x nxt=0 ws
    [ "$nofilt" = 0 ] || return 1
    [[ $s =~ $FILTPROG ]] || return 1
    [[ $d =~ $FILTPROG ]] || return 1
    p=${BASH_REMATCH[5]}
    if [ -n "${BASH_REMATCH[1]}" ]; then
        case "$p" in sed|awk|gawk|mawk|nawk|rg|sort) return 1 ;; esac
    fi
    d=${d:${#BASH_REMATCH[0]}}
    d=${d//$'\n'/ }
    case "${s#&}" in *'('*|*')'*|*'`'*|*';'*|*'&'*|*'|'*|*'{'*|*'}'*|*[[:space:]]--*) return 1 ;; esac
    # Any expansion ($X, "$X", ${…}, $(…), $'…', `…`, <(…), >(…)) — in the
    # text or the decoded bytes — hides the word the checks below read
    # (`X=e; … | sed $X - sh`), so the stage is no filter.
    case "$s$d" in *'$'*|*'`'*|*'<('*|*'>('*) return 1 ;; esac
    case "$p" in
        sed)
            read -r -a ws <<<"$d"
            for x in ${ws[@]+"${ws[@]}"}; do
                if [ "$nxt" = 1 ]; then
                    nxt=0
                    case "$x" in *[ewW]*) return 1 ;; esac
                    continue
                fi
                case "$x" in
                    -e) nxt=1 ;;
                    -|-[nErsuz]|-[nErsuz][nErsuz]|-[nErsuz][nErsuz][nErsuz]) ;;
                    -*|*[ewW]*) return 1 ;;
                esac
            done
            [ "$nxt" = 0 ] || return 1
            ;;
        awk|gawk|mawk|nawk)
            case "$d" in *system*|*getline*|*'|'*|*'@'*) return 1 ;; esac
            if [[ $d =~ $AWKOPT ]]; then return 1; fi
            ;;
    esac
    return 0
}
ENVSPLIT='^(-[[:alpha:]]*S|--split-string(=|$))'
# nest_mode WORD — set mode for WORD, or return 1 when it runs nothing nested.
nest_mode() {
    case "${1%.exe}" in
        sh|bash|rbash|zsh|dash|ksh|mksh|lksh|oksh|pdksh|ash|yash|posh|csh|tcsh|fish|elvish|nu|xonsh|pwsh|powershell|sg|su|runuser|script|flock) mode='sh' ;;
        source|.|at|batch) mode='src' ;;
        eval) mode='eval' ;;
        watch|parallel) mode='run' ;;
        tmux) mode='tmux' ;;
        screen) mode='screen' ;;
        ssh|docker|podman|nerdctl|kubectl|oc|lxc|incus|distrobox|toolbox) mode='rem' ;;
        python|python[0-9]|python[0-9].[0-9]|python[0-9].[0-9][0-9]|pypy|pypy[0-9]|perl|perl[0-9]*|ruby|irb|node|nodejs|bun|deno|php|lua|luajit|tclsh|expect|rscript|osascript) mode='int' ;;
        env) mode='env' ;;
        alias) mode='alias' ;;
        *) return 1 ;;
    esac
}
# names_verb TEXT — succeed when TEXT, quotes and backslashes removed, names
# qmd and a search verb anywhere: the fail-closed test for text a shell
# will run that cannot be read as words (a pipe's output, a substitution).
names_verb() {
    local s
    # shellcheck disable=SC1003 # a literal backslash in the tr set
    s=$(printf '%s' "$1" | LC_ALL=C tr -d '"'\''\\' | LC_ALL=C tr '[:upper:]' '[:lower:]')
    [[ $s == *qmd* ]] && [[ $s == *query* || $s == *search* ]]
}
# The helpers below run inside qmd_nested and read its locals (w, dec, n,
# pipe, pfrom, pp and the caches sk, se, sf, nk, nr).
# _stage_end START — set se to the end of the simple command holding START:
# the next `;`, `|`, `(`, `)` or boundary `&` (not a redirection's, HIMMEL-4337)
# outside a `$(…)`, `<(…)`, `>(…)` or backtick.
# shellcheck disable=SC2016 # literal $ and ` bytes
_stage_end() {
    local k=$1 c pd=0 bq=0
    while [ "$k" -lt "$n" ]; do
        c=${w:k:1}
        if [ "$bq" = 1 ]; then
            [ "$c" != '`' ] || bq=0
        elif [ "$pd" -gt 0 ]; then
            case "$c" in '(') pd=$((pd + 1)) ;; ')') pd=$((pd - 1)) ;; esac
        else
            case "$c" in
                '(') case "${w:k-1:1}" in '$'|'<'|'>') pd=1 ;; *) break ;; esac ;;
                '`') bq=1 ;;
                ';'|'|'|')') break ;;
                '&') case "${w:k-1:1}${w:k+1:1}" in '>'*|'<'*|*'>') ;; *) break ;; esac ;;
            esac
        fi
        k=$((k + 1))
    done
    se=$k
}
# _filt STAGE DEC — pipe_filter, but a `$` in DEC that STAGE does not hold
# came from quotes or an escape (awk's '{print $1}'): data, no expansion.
# shellcheck disable=SC2016 # a literal $ byte
_filt() {
    local s=$1 d=$2 m='' x k
    while [[ $d == *'$'* ]]; do
        x=${d%%\$*}
        k=$((${#m} + ${#x}))
        if [ "${s:k:1}" = '$' ]; then m=$m$x'$'; else m=$m$x'_'; fi
        d=${d:${#x}+1}
    done
    pipe_filter "$s" "$m$d"
}
# _prod_verb — succeed when the producer of the current pipe names a verb.
_prod_verb() {
    if [ "$nk" != "$pfrom,$pipe" ]; then
        nk="$pfrom,$pipe" nr=1
        names_verb "${dec:pfrom+1:pipe-pfrom-1}" || nr=0
    fi
    [ "$nr" = 1 ]
}
# _qn_runs START — HIMMEL-4337: succeed when the piped stage holding the
# executing element at START runs its stdin: it is no plain filter, read from
# the pipe or, for an element in program position, from START, and the
# producer names a verb. The stage end and its filter verdict are cached per
# stage, so a stage of many such words is scanned once.
_qn_runs() {
    local s=$1
    if [ "$sk" != "$pipe" ] || [ "$s" -ge "$se" ]; then
        _stage_end "$s"
        sk=$pipe sf=0
        if _filt "${w:pipe+1:se-pipe-1}" "${dec:pipe+1:se-pipe-1}"; then sf=1; fi
    fi
    [ "$sf" = 0 ] || return 1
    if [ "$pp" = 1 ] && _filt "${w:s:se-s}" "${dec:s:se-s}"; then return 1; fi
    _prod_verb
}
# _wr_add WORD — record a file the command writes (`>f`, `>>f`, `tee f`).
_wr_add() { wr="$wr ${1#./} "; }
# _ran_written WORD — succeed when WORD, a shell's or interpreter's
# operand, is a file the command wrote and the command names a verb.
_ran_written() {
    case "$wr" in *" ${1#./} "*) names_verb "$w" ;; *) return 1 ;; esac
}
# _screen_dec TEXT — set sd to TEXT with screen's \ooo, \n, \r decoded and
# its ^X dropped (a control byte never spells the verb).
# shellcheck disable=SC1003 # a literal backslash
_screen_dec() {
    local s=$1 i=0 m=${#1} c d k
    sd=''
    while [ "$i" -lt "$m" ]; do
        c=${s:i:1}
        if [ "$c" = '\' ]; then
            d=${s:i+1:1} k=1
            case "$d" in
                [0-7])
                    while [ "$k" -lt 3 ]; do
                        case "${s:i+1+k:1}" in [0-7]) d=$d${s:i+1+k:1}; k=$((k + 1)) ;; *) break ;; esac
                    done
                    d=$(( 8#$d & 255 ))
                    if [ "$d" -gt 32 ] && [ "$d" -lt 127 ]; then
                        printf -v d '%03o' "$d"
                        printf -v d '%b' "\\0$d"
                    else
                        d=' '
                    fi
                    ;;
                n|r) d=' ' ;;
            esac
            sd=$sd$d
            i=$((i + 1 + k))
        elif [ "$c" = '^' ] && [ -n "${s:i+1:1}" ]; then
            i=$((i + 2))
        else
            sd=$sd$c
            i=$((i + 1))
        fi
    done
}
# qmd_nested WORDS DEC DEPTH — run qmd_check on what each nested shell or
# eval in WORDS (qmd_words' first line, lower-cased) would run, spelled as in
# DEC (its decoded line). Sets deny=1 on the first refusal.
# shellcheck disable=SC2016 # literal $ and ` bytes
qmd_nested() {
    local LC_ALL=C w=$1 dec=$2 depth=$3 n i=0 j e c t v mode hasc pd bq scr rd rdop k piped sgw
    n=${#w}
    # bash copies $w on every index below, so the scan is quadratic in its
    # length: a long command holding a shell or eval word is refused, not
    # scanned against the chain's budget.
    # HIMMEL-4526: it also refuses one naming qmd and a verb (a reader with no
    # NESTWORD, `| awk '{system($0)}'`, `| sed e`, `| $x`), unless every
    # command it runs is a plain reader.
    if [ "$n" -gt 8192 ]; then
        if [[ $w =~ $NESTWORD ]]; then
            deny=1
        elif names_verb "$dec" && ! readers_only "$w"; then
            deny=1
        fi
        return 0
    fi
    # lb is the last command boundary seen; pipe, while set, is the offset of
    # the lone `|` (or `|&`) that feeds the current command, and pfrom the
    # boundary before the pipeline's first command, so the producer is every
    # stage before the pipe, dec[pfrom+1, pipe) (`echo … | cat | sh`).
    # HIMMEL-4245: a subshell, substitution or backtick opened in a piped
    # stage inherits its stdin, so it pushes a frame (lb, pipe and fb, the
    # pipe a list in the frame falls back to) that its close pops; a group or
    # loop keyword in a piped stage makes the pipe the frame's fallback. A
    # popped frame restores the boundary before its opener, so `(a) | sh`
    # reads `(a)` as the producer.
    # ponytail: the fallback outlives the group or loop it came from, so a
    # bare shell after it (`echo qmd query x | { cat; }; sh`) is over-denied;
    # match the closing keyword if one is hit.
    # HIMMEL-4330: pc is set while only blanks follow a lone `|` or `|&`, so a
    # newline there (printed `;`) continues the pipeline: the stage restarts
    # after it and the pipe still feeds it. HIMMEL-4337: pp is set while the
    # next word is in program position; ro while the next word is a `>`
    # target and te in a tee's words, both recorded in wr for _ran_written.
    # ri is set while the next word is a `<` target; sw is lb when the
    # current stage reads a written file on stdin (`< f sh`).
    local lb=-1 pipe='' pfrom=-1 fs='' fb='' fr pc=0 pp=1 ro=0 te=0 tw ws ri=0 sw='' so sr
    local sk='' se=0 sf=0 nk='' nr=0 pk=-1 e0 nw enc fo ia ct sj tk hx hs tx sd x oa sx atw
    while [ "$i" -lt "$n" ]; do
        c=${w:i:1}
        case "$NESTSEP" in
            *"$c"*)
                # The byte before, never a negative offset (bash 4 reads one
                # from the end).
                k=''
                [ "$i" -eq 0 ] || k=${w:i-1:1}
                case "$c" in
                    '|')
                        if [ "${w:i+1:1}" != '|' ] && [ "$k" != '|' ]; then
                            [ -n "$pipe" ] || pfrom=$lb
                            pipe=$i pc=1
                        else
                            pipe=$fb pc=0
                        fi
                        lb=$i pp=1 te=0 ro=0
                        # `>|` writes its target too.
                        [ "$k" != '>' ] || ro=1
                        ;;
                    '&')
                        # HIMMEL-4337: `>&`, `<&` and `&>` are one redirection.
                        if [ "$k" != '|' ] && [ "$k" != '>' ] && [ "$k" != '<' ] && [ "${w:i+1:1}" != '>' ]; then
                            pipe=$fb lb=$i pc=0 pp=1 te=0 ro=0
                        fi
                        ;;
                    ';')
                        if [ "$pc" = 1 ]; then pipe=$i; else pipe=$fb; fi
                        lb=$i pp=1 te=0 ro=0
                        ;;
                    '>') ro=1 pc=0 ;;
                    '<')
                        ro=0 pc=0 ri=0
                        if [ "$k" != '<' ] && [ "${w:i+1:1}" != '<' ]; then ri=1; fi
                        ;;
                    '('|')'|'`')
                        pc=0 te=0 ro=0
                        # A backtick as a piped stage's program runs its output.
                        if [ "$c" = '`' ] && [ "${fs##*,}" != b ] && [ -n "$pipe" ] && [ "$pp" = 1 ] &&
                            _qn_runs "$i"; then
                            deny=1
                            return 0
                        fi
                        pp=1
                        if [ "$c" = ')' ] || { [ "$c" = '`' ] && [ "${fs##*,}" = b ]; }; then
                            if [ -n "$fs" ]; then
                                fr=${fs##*/} fs=${fs%/*}
                                lb=${fr%%,*} fr=${fr#*,}
                                pipe=${fr%%,*} fr=${fr#*,}
                                fb=${fr%%,*}
                            else
                                pipe=$fb lb=$i
                            fi
                        else
                            k=p
                            [ "$c" != '`' ] || k=b
                            fs="$fs/$lb,$pipe,$fb,$k"
                            [ -z "$pipe" ] || fb=$pipe
                            lb=$i
                        fi
                        ;;
                esac
                i=$((i + 1))
                continue
                ;;
        esac
        j=$i
        while [ "$j" -lt "$n" ]; do
            case "$NESTSEP" in *"${w:j:1}"*) break ;; esac
            j=$((j + 1))
        done
        t=${w:i:j-i}
        tw=$t ws=$i
        i=$j
        pc=0
        if [ -n "$pipe" ]; then
            case "$t" in '{'|while|until|for|if|case|select) fb=$pipe ;; esac
        fi
        if [ "$ro" = 1 ]; then
            _wr_add "$tw"
        elif [ "$te" = 1 ]; then
            case "$tw" in -*) ;; *) _wr_add "$tw" ;; esac
        fi
        if [ "$ri" = 1 ]; then
            ri=0
            case "$wr" in *" ${tw#./} "*) sw=$lb ;; esac
        fi
        t=${t#=}
        t=${t##*/}
        [ "$t" != tee ] || te=1
        # HIMMEL-4337: xargs, a filter as the program, or an expansion as the
        # program, in a piped stage.
        if [ -n "$pipe" ]; then
            x=0
            if [ "$t" = xargs ]; then
                x=1
            elif [ "$pp" = 1 ]; then
                case "$tw" in
                    '$'*) x=1 ;;
                    *) case "$t" in grep|egrep|fgrep|rg|sed|awk|gawk|mawk|nawk|head|tail|wc|sort|uniq|cut|tr|cat|column|jq) x=1 ;; esac ;;
                esac
            fi
            if [ "$x" = 1 ] && _qn_runs "$ws"; then deny=1; return 0; fi
        fi
        # Program position: after a keyword or a plain prefix, and kept over
        # an assignment, a redirection's fd and its target.
        if [ "$ro" = 1 ]; then
            ro=0
        elif [[ $tw =~ ^[[:alnum:]_]+= ]] || { [[ ${w:j:1} == [\<\>] ]] && [[ $tw =~ ^[0-9]+$ ]]; }; then
            :
        else
            case "$tw" in do|then|else|elif|if|while|until|'!'|time|'{'|exec|command|builtin) pp=1 ;; *) pp=0 ;; esac
        fi
        nest_mode "$t" || continue
        pp=0
        piped=$pipe nw=${t%.exe} e0=$i enc=0 fo=0 ia=0 ct='' sj='' tk=0 hx=0 hs=0 tx=0
        # so: the program comes from an operand, code string or hand-back;
        # sr: stdin is a written file or a here-string; ss: sh -s seen.
        so=0 sr=0 ss=0
        # HIMMEL-4505: oa: the next word is an option's argument (`-o
        # errexit`), no program operand; sx: the -c string reads stdin
        # (`. /dev/stdin`, a nested shell); atw: at and batch, which read
        # their job from stdin unless given -f.
        oa=0 sx=0 atw=0
        case "$nw" in at|batch) atw=1 ;; esac
        [ "$sw" != "$lb" ] || sr=1
        # screen and rem only peek at their words (the walk below resumes
        # after the launcher word itself); one inside a span an earlier one
        # peeked at was read with it, so the scan stays linear.
        if { [ "$mode" = screen ] || [ "$mode" = rem ]; } && [ "$e0" -lt "$pk" ]; then continue; fi
        # The words that follow, to the end of the simple command. A word
        # keeps a `$(…)` or backtick substitution in it whole, blanks and all.
        e=$i hasc=0 scr='' rd=0
        # sg runs its operand after the group as a string, with or without
        # -c: read each word that is not handed back.
        sgw=0
        [ "$t" != sg ] || sgw=1
        while :; do
            while [ "$e" -lt "$n" ]; do
                case "${w:e:1}" in ' '|$'\t') e=$((e + 1)) ;; *) break ;; esac
            done
            if [ "$e" -ge "$n" ]; then break; fi
            # A redirection (`<f`, `2>&1`, `&>f`, `<<<w`) sits anywhere among
            # the words: step over its operator and drop its target word,
            # after checking any substitution in it.
            if [[ ${w:e:2} == '&>' ]] || [[ ${w:e:1} == [\<\>] ]]; then
                k=$e
                while [ "$e" -lt "$n" ]; do
                    case "${w:e:1}" in '<'|'>'|'&'|'|') e=$((e + 1)) ;; *) break ;; esac
                done
                rdop=${w:k:e-k}
                # A process substitution handed to a shell, source or an
                # interpreter runs its output, which cannot be read: refuse
                # one naming a verb.
                if [ "$rdop" = '<' ] && [ "${w:e:1}" = '(' ] &&
                    { [ "$mode" = sh ] || [ "$mode" = src ] || [ "$mode" = int ]; }; then
                    k=$e pd=0
                    while [ "$k" -lt "$n" ]; do
                        case "${w:k:1}" in
                            '(') pd=$((pd + 1)) ;;
                            ')') pd=$((pd - 1)); [ "$pd" -gt 0 ] || break ;;
                        esac
                        k=$((k + 1))
                    done
                    if names_verb "${dec:e:k-e}"; then deny=1; return 0; fi
                    e=$((k + 1))
                    continue
                fi
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
                [[ $rdop != *'>'* ]] || _wr_add "$t"
                if [ "$rdop" = '<<<' ]; then
                    sr=1
                elif [ "$rdop" = '<' ]; then
                    case "$wr" in *" ${t#./} "*) sr=1 ;; esac
                fi
                if [ "$rdop" = '<<<' ] && { [ "$mode" = sh ] || [ "$mode" = src ]; }; then
                    # A here-string is what a shell reading stdin runs.
                    qmd_check "$v" $((depth + 1))
                    if [ "$deny" = 1 ]; then return 0; fi
                elif [ "$rdop" = '<<<' ] && [ "$mode" = int ] && names_verb "$v"; then
                    deny=1
                    return 0
                elif [[ $t == *'$('* ]] || [[ $t == *'`'* ]]; then
                    qmd_check "$t" $((depth + 1))
                    if [ "$deny" = 1 ]; then return 0; fi
                fi
            elif [[ ${w:e:1} == [\<\>] ]] && [[ $t =~ ^([0-9]+|\{[[:alpha:]_][[:alnum:]_]*\})$ ]]; then
                # The fd of a redirection (`2>f`, `{fd}<f`), not a word.
                :
            elif [ "$mode" = tmux ] || [ "$mode" = screen ] || [ "$mode" = rem ]; then
                # HIMMEL-4305: every word, decoded, is kept joined (sj) and
                # concatenated (ct, which catches `send-keys q m d`); tmux's
                # also feed the TMUXREST reading below. After send-keys -H
                # each operand is one hex byte.
                [ "$mode" != tmux ] || scr="$scr $v"
                case "$t" in *'$'*|*'`'*) tx=1 ;; esac
                x=$v
                if [ "$mode" = tmux ]; then
                    if [ "$v" = ';' ]; then
                        tk=0 hx=0
                    elif [ "$hs" = 1 ]; then
                        hs=0
                    elif [ "$tk" = 1 ] && [[ $v == -* ]]; then
                        [[ $v != -*H* ]] || hx=1
                        [[ ! $v =~ ^-[[:alpha:]]*[tNc]$ ]] || hs=1
                    elif [ "$hx" = 1 ]; then
                        if [[ $v =~ ^[0-9a-fA-F]{1,2}$ ]]; then
                            printf -v x '%b' "\\x$v"
                        else
                            deny=1
                            return 0
                        fi
                    fi
                    case "$t" in send-keys|send) tk=1 ;; esac
                fi
                ct=$ct$x sj="$sj $v"
            elif [ "$mode" = eval ] || [ "$mode" = run ]; then
                # eval takes one option, the `--` that ends its options.
                if [ -n "$scr" ] || [ "$mode" != eval ] || [ "$t" != '--' ]; then scr="$scr $v"; fi
            elif [ "$mode" = alias ]; then
                # A definition whose value names qmd, in a command that
                # names a verb (`alias q=qmd; q query x`), fails closed.
                c=$(printf '%s' "${v#*=}" | LC_ALL=C tr '[:upper:]' '[:lower:]')
                if [[ $v == *=* ]] && [[ ${c//[\"\'\\]/} == *qmd* ]] && names_verb "qmd $w"; then
                    deny=1
                    return 0
                fi
            elif [ "$mode" = env ] && [[ $v =~ $ENVSPLIT ]]; then
                # env -S: the rest of the word and every word after it are
                # one command line, split by env's own quote rules.
                mode=run
                scr=" ${v#"${BASH_REMATCH[0]}"}"
            elif [ "$enc" = 1 ]; then
                # HIMMEL-4305: pwsh -EncodedCommand's base64 of UTF-16LE text,
                # decoded from the case-preserving bytes; a failed decode, or
                # no base64 to decode it with, fails closed.
                enc=2 so=1
                if ! command -v base64 >/dev/null 2>&1 ||
                    ! x=$(printf '%s' "$v" | base64 -d 2>/dev/null | LC_ALL=C tr -d '\000') ||
                    [ -z "$x" ] || names_verb "$x"; then
                    deny=1
                    return 0
                fi
                qmd_check "$x" $((depth + 1))
                if [ "$deny" = 1 ]; then return 0; fi
            elif [ "$mode" = int ]; then
                # HIMMEL-4337: an interpreter's code string — python's -c,
                # perl's, ruby's and lua's -e, node's and bun's -e/-p/--eval/
                # --print, php's -r, deno eval — is no shell: refuse one
                # naming a verb (so is any option word that names one).
                if [ "$ia" = 1 ]; then
                    ia=0 so=1
                    if names_verb "$v"; then deny=1; return 0; fi
                elif [[ $t == -* ]]; then
                    if names_verb "$v"; then deny=1; return 0; fi
                    case "$nw" in
                        python*|pypy*|tclsh|expect) x=c ;;
                        node|nodejs|bun) x=ep ;;
                        php) x=r ;;
                        *) x=e ;;
                    esac
                    if [[ $t =~ ^-[[:alnum:]]*[$x]$ ]] || [[ $t =~ ^--(eval|print)$ ]]; then ia=1; fi
                elif [ "$nw" = deno ] && [ "$t" = eval ] && [ "$fo" = 0 ]; then
                    ia=1 fo=1
                elif [[ $t == *'$('* ]] || [[ $t == *'`'* ]]; then
                    qmd_check "$t" $((depth + 1))
                    if [ "$deny" = 1 ]; then return 0; fi
                else
                    c=${t#=} k=$mode
                    if nest_mode "${c##*/}"; then
                        mode=$k so=1
                        e=$((j - ${#t}))
                        break
                    fi
                    # Every operand, not only the first: an option's own
                    # argument (`-I lib`, `-r ./x`) would shift the script.
                    # An operand naming stdin (/dev/stdin, /dev/fd/0,
                    # /proc/self/fd/0) is no program source.
                    fo=1
                    case "$v" in */dev/*|dev/*|*/proc/*|proc/*) ;; *) so=1 ;; esac
                    if _ran_written "$t"; then deny=1; return 0; fi
                fi
            elif [ "$hasc" = 0 ]; then
                # The string is the first word after an option cluster
                # holding c or su's C (`-c`, `-ec`, `-lc`, `-C`) or a
                # `--command` / su's `--session-command`; the later
                # words ($0 and its arguments) are read too — more reading
                # only adds denials.
                # HIMMEL-4305: pwsh's -EncodedCommand (any prefix, -ec, a
                # `--` or `/` lead) is read first: it would match the -c
                # cluster.
                x=${t#-} x=${x#-}
                [ "$x" != "$t" ] || x=${t#/}
                if [ "$mode" = sh ] && { [ "$nw" = pwsh ] || [ "$nw" = powershell ]; } && [ "$x" != "$t" ] &&
                    [[ $x =~ ^[a-z]+$ ]] && { [ "$x" = ec ] || [[ encodedcommand == "$x"* ]]; }; then
                    enc=1
                elif [ "$mode" = sh ] && [[ $t =~ ^-[[:alpha:]]*[cC][[:alpha:]]*$ || $t =~ ^--(session-)?command$ ]]; then
                    hasc=1
                elif [ "$mode" = sh ] && [[ $t =~ ^--(session-)?command= ]]; then
                    hasc=1 so=1
                    qmd_check "${v#*=}" $((depth + 1))
                    if [ "$deny" = 1 ]; then return 0; fi
                elif [ "$mode" != env ] && { [[ $t == *'$('* ]] || [[ $t == *'`'* ]]; }; then
                    # A substitution runs in the outer shell: check its text.
                    # env without -S runs its words as the outer shell would,
                    # and the top level already read them.
                    qmd_check "$t" $((depth + 1))
                    if [ "$deny" = 1 ]; then return 0; fi
                else
                    # HIMMEL-4337: a shell's or source's operand that the
                    # command wrote (`… > f; sh f`). Every operand: an
                    # option's argument (`-o errexit`) would shift the script.
                    # After sh -s the operands are positional args, and an
                    # operand naming stdin (/dev/stdin, /dev/fd/0,
                    # /proc/self/fd/0) is no program source: both keep the
                    # stdin check below on.
                    if [ "$mode" = sh ] && [ "$so" = 0 ] && [[ $t =~ ^-[[:alpha:]]*s[[:alpha:]]*$ ]]; then ss=1; fi
                    if [ "$oa" != 0 ]; then
                        # A shell option's argument is no program operand;
                        # an rc file (oa=2) is still run, so a written one
                        # denies.
                        if [ "$oa" = 2 ] && _ran_written "$t"; then deny=1; return 0; fi
                        oa=0
                    elif [ "$mode" = sh ] && [[ $nw =~ ^(sh|bash|rbash|zsh|dash|ksh|mksh|lksh|oksh|pdksh|ash|yash|posh|csh|tcsh|fish)$ ]] &&
                        [[ $t =~ ^[-+][[:alpha:]]*[oO]$ || $t =~ ^--(rcfile|init-file)$ ]]; then
                        oa=1
                        [[ $t == --* ]] && oa=2
                    elif [ "$atw" = 1 ]; then
                        # at and batch take a time spec, not a program; only
                        # a bare -f names the job file that replaces stdin;
                        # a cluster such as -qf is a queue letter, not a file.
                        if [[ $t = -f || $t = --file ]]; then so=1; fi
                        if _ran_written "$t"; then deny=1; return 0; fi
                    elif [ "$mode" != env ] && [[ $t != -* ]]; then
                        if [ "$ss" = 0 ]; then
                            case "$v" in */dev/*|dev/*|*/proc/*|proc/*) ;; *) so=1 ;; esac
                        fi
                        if _ran_written "$t"; then deny=1; return 0; fi
                    fi
                    # Another word that runs a nested string, before any -c:
                    # hand it back to the outer loop, so no word is scanned
                    # twice.
                    c=${t#=} k=$mode
                    if nest_mode "${c##*/}"; then
                        mode=$k so=1
                        e=$((j - ${#t}))
                        break
                    fi
                    if [ "$sgw" = 1 ]; then
                        case "$v" in
                            *[qQ]*|*'$'*|*'`'*) qmd_check "$v" $((depth + 1)) ;;
                        esac
                        if [ "$deny" = 1 ]; then return 0; fi
                    fi
                fi
            else
                # A string that reads stdin (`. /dev/stdin`, a nested shell)
                # is not the program source: stdin is, so keep the check on.
                if [[ $v =~ /dev/stdin|/dev/fd/0|/proc/[^[:space:]]*/fd/0 || $v =~ $NESTWORD ]]; then sx=1; fi
                [ "$sx" = 1 ] || so=1
                # A word with no q, `$` or backtick cannot spell qmd.
                case "$v" in
                    *[qQ]*|*'$'*|*'`'*) qmd_check "$v" $((depth + 1)) ;;
                esac
                if [ "$deny" = 1 ]; then return 0; fi
            fi
        done
        # Every word to here was read above (eval's in $scr): resume after
        # them, so the scan stays linear in the length of the command.
        # screen and rem resume after their own word: the words they peeked
        # at are read again as the top level reads them.
        i=$e
        if [ "$mode" = screen ] || [ "$mode" = rem ]; then i=$e0 pk=$e; fi
        # A shell or interpreter with no program operand or code string
        # reads its program from stdin (`< f`, `<<<`, a pipe, -s), as does
        # a source of /dev/stdin; with
        # none of them, -c's string comes from elsewhere (`xargs -a f sh
        # -c`). Fails closed on a command that wrote a file and names a verb.
        if { [ "$mode" = sh ] || [ "$mode" = src ] || [ "$mode" = int ]; } && [ "$so" = 0 ] && [ -n "$wr" ] &&
            { [ "$sr" = 1 ] || [ -n "$piped" ] || [ "$hasc" = 1 ]; } && names_verb "$w"; then
            deny=1
            return 0
        fi
        # A shell or source, fed by a pipe, runs the producer's output:
        # refuse a producer naming a verb. HIMMEL-4245: unless the consumer
        # stage, to the end of this command, is a plain filter (`… | grep -v
        # sh` is no shell). HIMMEL-4337: so does every mode but env and
        # alias, with or without -c.
        # HIMMEL-4244: a stage run on by a later `|` then a newline (printed
        # `;`) reaches the next line, so it is no filter.
        if [ -n "$piped" ] && [ "$mode" != env ] && [ "$mode" != alias ] &&
            { [[ ${w:e} =~ $PIPENL ]] || ! pipe_filter "${w:piped+1:e-piped-1}" "${dec:piped+1:e-piped-1}"; } &&
            names_verb "${dec:pfrom+1:piped-pfrom-1}"; then
            deny=1
            return 0
        fi
        if [ -n "$scr" ]; then
            # watch, parallel and env -S run their words as a program: read
            # them behind a plain wrapper so their options are stepped over.
            if [ "$mode" = run ]; then scr="exec$scr"; fi
            # tmux: the words after its first session-starting subcommand,
            # read the same way; with none it runs nothing nested.
            if [ "$mode" = tmux ]; then
                if [[ $scr =~ $TMUXREST ]]; then
                    scr="exec${BASH_REMATCH[0]#*"${BASH_REMATCH[1]}"}"
                else
                    scr=''
                fi
            fi
            qmd_check "$scr" $((depth + 1))
            if [ "$deny" = 1 ]; then return 0; fi
        fi
        # HIMMEL-4305: a launcher's words naming qmd and a verb fail closed:
        # tmux's and screen's concatenated (screen's escapes decoded), rem's
        # joined and also read as a command; and an expansion among them
        # fails closed on the command naming one.
        case "$mode" in
            tmux|screen)
                if [ "$mode" = screen ]; then _screen_dec "$ct"; ct=$sd; fi
                if [[ $ct == *[qQ]* ]] && names_verb "$ct"; then deny=1; return 0; fi
                ;;
            rem)
                if [[ $sj == *[qQ]* ]] && names_verb "$sj"; then deny=1; return 0; fi
                case "$sj" in
                    *[qQ]*|*'$'*|*'`'*) qmd_check "$sj" $((depth + 1)) ;;
                esac
                if [ "$deny" = 1 ]; then return 0; fi
                ;;
        esac
        if [ "$tx" = 1 ] && names_verb "$w"; then deny=1; return 0; fi
    done
    return 0
}

# readers_only WORDS — succeed when every command qmd_words' reading of the
# command runs is a reader that never runs an argument (HIMMEL-4574). Quoted
# data there is only ever a pattern or a file name, so the raw-text reading
# (whose job is a separator or a nested `bash -c` inside quotes) is skipped:
# `ls | grep 'a|qmd query'` is a mention. WORDS prints quoted operators as `_`,
# so only real separators split it, and `$(`, a backtick, `<(`, a brace group
# or a function body each start a command of their own. A VAR= prefix, a
# redirect before the program, a path or any other program is no reader.
# echo and printf are deliberately not readers: their output is commonly
# piped on, and the J1666 rows keep `echo "x; qmd query"` denied.
QREADERS=' grep egrep fgrep cat head tail wc ls '
readers_only() {
    local t=$1 seg w
    # An fd dup or an &> redirect is no command boundary.
    t=${t//'>&'/'> '}
    t=${t//'&>'/' >'}
    t=${t//[|;&()\{\}\`]/$'\n'}
    while IFS= read -r seg; do
        read -r w _ <<<"$seg" || true
        [ -n "$w" ] || continue
        case "$QREADERS" in *" $w "*) ;; *) return 1 ;; esac
    done <<<"$t"
    return 0
}

# qmd_check CMD DEPTH — set deny=1 when CMD runs a bare search verb. DEPTH is
# 0 for the tool call's command and counts nested strings. It always returns
# 0 and is called bare, so set -e still stops the hook (and the EXIT trap
# denies) on a failure inside it.
qmd_check() {
    local cmd=$1 depth=$2 cmd_lc crude res words words_lc dec aq raw
    # A work bound, refused when hit: the chain skips a member past its
    # budget, so a slow scan must deny rather than run out the clock.
    checks=$((checks + 1))
    if [ "$depth" -gt 4 ] || [ "$checks" -gt 64 ]; then deny=1; return 0; fi
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
    # `$'…'` or `$"…"` that could spell it — nothing to check. HIMMEL-4305:
    # tmux, screen and pwsh decode keys, escapes and base64 that can spell it
    # with no `qmd` in the text.
    case "$cmd_lc$crude" in
        *qmd*|*\$\'*|*\$\"*|*tmux*|*screen*|*pwsh*|*powershell*) ;;
        *) return 0 ;;
    esac
    # Whether a filter can clear a piped stage (pipe_filter) is read from the
    # raw text of every level, and once refused stays refused. qmd_words
    # decodes `$'…'` and `$"…"` and drops their `$`, so pipe_filter's
    # expansion check cannot see them: their raw `$` refuses here.
    if [[ $cmd =~ $FILTDECO ]] || [[ $cmd_lc =~ $FILTREDEF ]] ||
        [[ $cmd == *"\$'"* ]] || [[ $cmd == *'$"'* ]]; then
        nofilt=1
    fi
    # Nested strings share one byte budget, so four levels of a long string
    # cannot each pay a full scan.
    if [ "$depth" -gt 0 ]; then
        nested=$((nested + ${#cmd}))
        if [ "$nested" -gt 8192 ]; then deny=1; return 0; fi
    fi
    if res=$(qmd_words "$cmd"); then
        words=${res%%$'\n'*}
        res=${res#*$'\n'}
        dec=${res#*$'\n'}
        dec=${dec%.}
        res=${res%%$'\n'*}
        words_lc=$(printf '%s' "$words" | LC_ALL=C tr '[:upper:]' '[:lower:]')
        raw=1
        readers_only "$words_lc" && raw=0
        if [[ $words_lc =~ $BARE$BOUND ]]; then
            deny=1
        elif [ "$raw" = 1 ] && [[ $cmd_lc =~ $BARE$RAWBOUND ]]; then
            deny=1
        elif [ "$raw" = 1 ] && qp_deny "${res#:}"; then
            deny=1
        elif [ "$depth" -gt 0 ] && [[ $words_lc =~ $SUBPROG ]]; then
            deny=1
        elif [[ $crude == *qmd* ]] && { [[ $words_lc =~ $SUBTOP ]] ||
            { [[ $words_lc =~ $CASEWORD ]] && [[ $words_lc =~ $SUBPROG ]]; }; }; then
            deny=1
        elif { [[ $words_lc =~ $POSPROG ]] || [[ $words_lc =~ $POSVERB ]]; } && names_verb "$words_lc"; then
            deny=1
        else
            qmd_nested "$words_lc" "$dec" "$depth"
        fi
    elif [ "$depth" -gt 0 ] && [[ $crude == *qmd* ]]; then
        deny=1
    elif [[ $cmd == *"\\c'"* ]] && [[ $crude == *qmd* ]]; then
        # qmd_words declines an ANSI-C `\c'`: bash and zsh split it apart.
        deny=1
    elif [ "$(printf '%s' "$cmd" | LC_ALL=C wc -c)" -gt 16384 ] &&
        { { [[ $crude == *qmd* ]] &&
            { [[ $crude == *query* || $crude == *search* ]] || [[ $cmd == *"\$'"* || $cmd == *'$"'* ]]; }; } ||
            [[ $cmd_lc$crude == *tmux* || $cmd_lc$crude == *screen* ||
                $cmd_lc$crude == *pwsh* || $cmd_lc$crude == *powershell* ]] ||
            [[ $cmd == *"\$'"* ]]; }; then
        # HIMMEL-4526: qmd_words declines past 16 KiB, which leaves only the
        # bare readings; every pipe, redirect, launcher and stdin reading
        # would be skipped. An oversized command naming qmd and a verb (or an
        # ANSI-C string that could spell one) is no legitimate allow case.
        # tmux, screen and pwsh spell qmd with keys, escapes or base64 and
        # cannot be decoded here, so naming one at all fails closed.
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

deny=0 checks=0 nested=0 nofilt=0 wr=""
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
