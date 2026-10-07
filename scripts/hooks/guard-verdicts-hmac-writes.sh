#!/usr/bin/env bash
# guard-verdicts-hmac-writes.sh — PreToolUse hook (matchers "Bash",
# "Edit|Write|MultiEdit|NotebookEdit" and "Read|Grep"; Codex: apply_patch):
# [HIMMEL-4733], the write fence HIMMEL-4714's security note asked for.
#
# Two fences, in every session (this hook has no marker no-op):
#
#   1. The GO HMAC key (~/.config/himmel/go-hmac.key). No agent tool reads or
#      writes it, the judge included: Read, Grep, Write, Edit, MultiEdit,
#      NotebookEdit and apply_patch on the key (or a `.go-hmac*` temp beside
#      it), and any Bash word that names the key or its directory — under any
#      spelling (~, $HOME, ${HOME}, relative, quoted), through a symlink or
#      hard link (`-ef`), as a glob that could match it, as the value of an
#      `X=` word (dd if=, an assignment), or in a cd into the directory.
#      Grep, and a recursive copier/searcher (cp rsync tar zip scp grep rg find
#      …), is also refused on ~/.config itself, and any text spelling
#      `himmel/go-hmac` (an interpreter one-liner, a cd-relative path) denies.
#      Only console-kit/go.sh and merge-on-green.sh (via scripts/lib/go-gate.sh)
#      touch the key, from inside the script, where no hook sees the access.
#      There is no bypass, not even block-read-secrets' READ_SECRETS_OK.
#
#   2. verdicts/ — judge-only writes. Outside a judge session
#      (HIMMEL_CONSOLE_JUDGE=1, exported by headed-arm-leg.sh --judge), a
#      write-tool path, a Bash output-redirect target, or a write operand of
#      tee cp mv rm rmdir install ln rsync scp dd truncate shred unlink touch
#      chmod chown patch sed(-i), whose physical path has a component named
#      exactly `verdicts` is refused, except under ~/.cache/himmel/verdicts/
#      (a judge's scratch). An interpreter one-liner (python perl ruby node
#      php awk) whose text names a /verdicts path is refused too. The refusal names the sanctioned
#      writer, console-kit/write-verdict.sh: a console-judge CALL (an
#      in-process subagent without the marker) writes through it, and since
#      the script does the write itself, its command line names no verdicts/
#      path and passes. Reads of verdicts/ stay allowed everywhere.
#
# Bash text is read with the shared quote-aware tokenizer (inlined below;
# canonical scripts/hooks/lib/shell-tokenize.sh, HIMMEL-3546). Wrappers (sudo
# env timeout nice xargs exec ...) and their option arguments are skipped to
# find each segment's command; a `bash|sh|zsh|dash|ksh -c` script and an `eval`
# argument are tokenized and checked the same way, up to 8 levels deep. When the
# tokenizer does not model a command (ST_OK=0), or nesting goes deeper, the
# hook falls back to a stricter text scan: deny
# on any `.config/himmel` mention, and on a write-shaped command naming a
# /verdicts path outside the judge cache.
#
# Fail-closed (security fence): missing jq, malformed / non-object JSON, a
# path field of the wrong type -> deny; any other non-0/2 exit is clamped to 2.
#
# ponytail: text-level fence — a script FILE that touches the key or writes a
# verdict without being handed the path, variable indirection that never
# spells it, a brace expansion, or a write utility off the list is not seen;
# upgrade path is a separate-uid key and verdict store (HIMMEL-3578).
# ponytail: verdicts/ is matched as ANY path component named `verdicts`, not
# only <handover root>/<user>/<bucket>/verdicts/ — no root resolution can fail
# open, at the cost of refusing a write into an unrelated dir named exactly
# `verdicts`; narrow it to the resolved root if such a dir ever appears.
# ponytail: the PowerShell tool is not wired, Windows is parked under
# HIMMEL-4102 — wire it when Windows legs resume.
#
# Platform guard (gitbash-only): POSIX bash 3.2+; no mapfile, no assoc arrays.
# Exit codes: 0 allow (no output); 2 deny (JSON hookSpecificOutput with
# permissionDecision "deny" on stdout).
# shellcheck disable=SC2317,SC2329 # the inlined tokenizer's sed helpers are unused here
set -uo pipefail
rc=0
trap 'rc=$?; if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit 2; fi' EXIT

deny() {
    # deny <rule> <detail>
    local msg reason
    case "$1" in
        key-*) msg="the GO HMAC key (~/.config/himmel/go-hmac.key) is never read or written through an agent tool, in any session (HIMMEL-4733). Only console-kit/go.sh and merge-on-green.sh touch it, from inside the script. There is no bypass" ;;
        verdicts-*) msg="verdicts/ is written only by a judge (HIMMEL-4733). Write a ruling with: bash scripts/handover/console-kit/write-verdict.sh <qid> <GO|NO-GO> <head> --evidence-file <path>. A judge session (headed-arm-leg.sh --judge) is exempt" ;;
        *) msg="security fence, fail-closed (HIMMEL-4733)" ;;
    esac
    reason=$(printf '%s' "guard-verdicts-hmac-writes: $1 ($2): $msg" | jq -Rs . 2>/dev/null) \
        || reason='"guard-verdicts-hmac-writes: denied"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
    exit 2
}

command -v jq >/dev/null 2>&1 || deny "unparseable-payload" "jq not on PATH"
input=$(cat 2>/dev/null || true)
printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || deny "unparseable-payload" "malformed or non-object JSON"
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null) \
    || deny "unparseable-payload" "unreadable tool_name"
case "$tool" in
    Bash|Read|Grep|Write|Edit|MultiEdit|NotebookEdit|apply_patch) ;;
    *) exit 0 ;;
esac
CWD=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
[ -n "$CWD" ] || CWD=$PWD

JUDGE=0
[ "${HIMMEL_CONSOLE_JUDGE:-}" = "1" ] && JUDGE=1
CONFIG="${HOME%/}/.config"
KEYDIR="$CONFIG/himmel"
KEY="$KEYDIR/go-hmac.key"
CACHE="${HOME%/}/.cache/himmel/verdicts"

# ---------------------------------------------------------------- paths ---

# _norm <abs-path> -> lexically normalised (., .., //), no trailing slash.
_norm() {
    local p="$1" out="" seg rest
    rest="${p#/}"
    while [ -n "$rest" ]; do
        case "$rest" in */*) seg="${rest%%/*}"; rest="${rest#*/}" ;; *) seg="$rest"; rest="" ;; esac
        case "$seg" in
            ''|.) ;;
            ..) out="${out%/*}" ;;
            *) out="$out/$seg" ;;
        esac
    done
    printf '%s' "${out:-/}"
}

# _phys <abs-path> -> physical path; a missing tail resolves through its
# deepest existing parent. Falls back to the lexical form.
_phys() {
    local p="$1" r head tail=""
    r=$(readlink -f -- "$p" 2>/dev/null) && [ -n "$r" ] && { printf '%s' "$r"; return; }  # gnu-ok: BSD readlink without -f fails here and falls to the lexical path
    head="$p"
    while [ -n "$head" ] && [ "$head" != "/" ] && [ ! -d "$head" ]; do
        tail="/${head##*/}$tail"
        head="${head%/*}"
    done
    r=$(readlink -f -- "${head:-/}" 2>/dev/null) || r=""  # gnu-ok: same fallback as above
    [ -n "$r" ] || { printf '%s' "$p"; return; }
    [ "$r" = "/" ] && r=""
    printf '%s' "$r$tail"
}

# _abs <word> -> absolute lexical path (~, $HOME, ${HOME} expanded; relative
# words joined to CWD). Prints nothing for any other `$` or backtick word.
# shellcheck disable=SC2088,SC2016 # literal ~ / $HOME spellings are matched as text
_abs() {
    local w="$1"
    case "$w" in
        '~') w="$HOME" ;;
        '~/'*) w="$HOME/${w#\~/}" ;;
        '$HOME'|'${HOME}') w="$HOME" ;;
        '$HOME/'*) w="$HOME/${w#\$HOME/}" ;;
        '${HOME}/'*) w="$HOME/${w#\$\{HOME\}/}" ;;
    esac
    case "$w" in
        '') return ;;
        *'$'*|*'`'*) return ;;
        /*) ;;
        *) w="$CWD/$w" ;;
    esac
    _norm "$w"
}

# is_key <abs> — the key, its directory, or a go-hmac temp inside it, by
# lexical path or by inode (-ef follows every symlink and hard link).
KEY_PHYS=$(_phys "$KEY")
KEYDIR_PHYS=$(_phys "$KEYDIR")
CONFIG_PHYS=$(_phys "$CONFIG")
is_key() {
    local p="$1" x
    for x in "$p" "$(_phys "$p")"; do
        case "$x" in
            "$KEY"|"$KEYDIR"|"$KEYDIR"/*go-hmac*|"$KEY_PHYS"|"$KEYDIR_PHYS"|"$KEYDIR_PHYS"/*go-hmac*) return 0 ;;
        esac
    done
    { [ -e "$KEY" ] && [ "$p" -ef "$KEY" ]; } && return 0
    { [ -d "$KEYDIR" ] && [ "$p" -ef "$KEYDIR" ]; } && return 0
    return 1
}
# is_config <abs> — ~/.config itself (a recursive read of it reaches the key).
is_config() {
    case "$1" in "$CONFIG"|"$CONFIG_PHYS") return 0 ;; esac
    { [ -d "$CONFIG" ] && [ "$1" -ef "$CONFIG" ]; }
}
# glob_hits <abs-pattern> — the pattern could expand to the key, its dir or
# ~/.config. `*` crosses `/` here, so this over-matches (the safe direction).
glob_hits() {
    local pat="$1" x
    for x in "$KEY" "$KEYDIR" "$CONFIG" "$KEY_PHYS" "$KEYDIR_PHYS" "$CONFIG_PHYS"; do
        # shellcheck disable=SC2053 # $pat is deliberately a pattern
        [[ $x == $pat ]] && return 0
    done
    return 1
}
# is_verdicts <abs> — a path with a component named exactly `verdicts`, by
# lexical or physical path, outside the judge cache.
CACHE_PHYS=$(_phys "$CACHE")
is_verdicts() {
    local x
    for x in "$1" "$(_phys "$1")"; do
        case "$x" in
            "$CACHE"|"$CACHE"/*|"$CACHE_PHYS"|"$CACHE_PHYS"/*) continue ;;
            */verdicts|*/verdicts/*) return 0 ;;
        esac
    done
    return 1
}

# file_check <path> <write 0|1>
file_check() {
    local a
    a=$(_abs "$1")
    [ -n "$a" ] || deny "unparseable-payload" "unexpandable path $1"
    is_key "$a" && deny "key-file-tool" "$tool $1"
    case "${a##*/}" in *go-hmac*) deny "key-file-tool" "$tool $1" ;; esac
    [ "$2" = 1 ] && [ "$JUDGE" = 0 ] && is_verdicts "$a" && deny "verdicts-file-tool" "$tool $1"
    return 0
}

# ------------------------------------------------------------ file tools ---
case "$tool" in
    Read|Write|Edit|MultiEdit|NotebookEdit|Grep)
        field=file_path
        [ "$tool" = NotebookEdit ] && field=notebook_path
        [ "$tool" = Grep ] && field=path
        ptype=$(printf '%s' "$input" | jq -r --arg f "$field" '(.tool_input[$f] // .tool_input.file_path) | type' 2>/dev/null) \
            || deny "unparseable-payload" "unreadable tool_input"
        case "$ptype" in
            string) ;;
            null)
                if [ "$tool" = Grep ]; then p="$CWD"; else deny "unparseable-payload" "no $field"; fi
                ;;
            *) deny "unparseable-payload" "$field not a string" ;;
        esac
        [ "$ptype" = string ] && p=$(printf '%s' "$input" | jq -r --arg f "$field" '.tool_input[$f] // .tool_input.file_path' 2>/dev/null)
        case "$tool" in
            Read) file_check "$p" 0 ;;
            Grep)
                file_check "$p" 0
                a=$(_abs "$p")
                is_config "$a" && deny "key-file-tool" "Grep over $p"
                ;;
            *) file_check "$p" 1 ;;
        esac
        exit 0
        ;;
    apply_patch)
        patch=$(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.patch // .tool_input.input // ""' 2>/dev/null) \
            || deny "unparseable-payload" "unreadable apply_patch payload"
        while IFS= read -r ln; do
            ln="${ln%$'\r'}"
            case "$ln" in
                '*** Add File: '*) p="${ln#\*\*\* Add File: }" ;;
                '*** Update File: '*) p="${ln#\*\*\* Update File: }" ;;
                '*** Delete File: '*) p="${ln#\*\*\* Delete File: }" ;;
                '*** Move to: '*) p="${ln#\*\*\* Move to: }" ;;
                *) continue ;;
            esac
            file_check "$p" 1
        done <<EOF
$patch
EOF
        exit 0
        ;;
esac

# ------------------------------------------------------------------ Bash ---
ctype=$(printf '%s' "$input" | jq -r '.tool_input.command | type' 2>/dev/null) \
    || deny "unparseable-payload" "unreadable command"
case "$ctype" in
    string) ;;
    null) exit 0 ;;
    *) deny "unparseable-payload" "command not a string" ;;
esac
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command' 2>/dev/null) \
    || deny "unparseable-payload" "unreadable command"
[ -n "$cmd" ] || exit 0

# >>> BEGIN shell-tokenize (HIMMEL-3546; canonical: scripts/hooks/lib/shell-tokenize.sh) >>>
# st_tokenize CMD — split CMD into words and segments the way bash reads it,
# expanding nothing. Returns 0 (ST_OK=1) on success, 1 (ST_OK=0) on anything
# it does not model — an unterminated quote, an unmatched `)`, `;;`, a
# backtick inside double quotes inside backticks, a `${…}` beyond a bare
# name, a redirect with no target, more than 8 KiB — and the caller then
# falls back to its older, stricter text scan. The cap bounds the hooks'
# worst case well inside run-hook-with-bash.js's 15 s member timeout (J1242):
# every loop here and in the callers is linear and fork-free, so an 8 KiB
# command tokenizes in a fraction of a second.
#   ST_N        number of words
#   ST_W[i]     word i with quotes and escapes removed (a $'…' body
#               decoded), nothing expanded
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
    [ "$n" -le 8192 ] || return 1
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
                        # The shell runs the decoded word (`$'\x2dr'` is -r,
                        # HIMMEL-4576). ${…@E} is bash 4.4+; an older bash
                        # keeps the raw body, as before (declining here would
                        # switch guard_unwrap off for the whole command, J1946
                        # B1). The eval'd text is constant, never input.
                        if [ "${BASH_VERSINFO[0]}" -gt 4 ] \
                            || { [ "${BASH_VERSINFO[0]}" = 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }; then
                            eval 'body=${body@E}'
                        fi
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

# st_lower STR — ST_LOWER is STR with A-Z folded to a-z (bytes, as `tr` does
# in the C locale), without a fork: a fork per word is what made a padded
# command outrun the runner's member timeout (J1242).
# shellcheck disable=SC2034,SC2317,SC2329 # ST_LOWER is read by the caller; only block-edit calls it, the guard inlines the whole lib
st_lower() {
    local s="$1" u=ABCDEFGHIJKLMNOPQRSTUVWXYZ l=abcdefghijklmnopqrstuvwxyz i=0
    while [ "$i" -lt 26 ]; do
        s=${s//${u:i:1}/${l:i:1}}
        i=$((i + 1))
    done
    ST_LOWER=$s
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

# a path component named exactly `verdicts` inside free text
VRE='/verdicts([^[:alnum:]_.-]|$)'
WRE='(^|[^[:alnum:]_])(tee|cp|mv|rm|rmdir|install|ln|rsync|scp|dd|truncate|shred|unlink|touch|chmod|chown|patch|sed|python3?|perl|ruby|node)([^[:alnum:]_]|$)'
# nesting deeper than this (bash -c inside bash -c ...) gets the text scan
MAX_DEPTH=8
WRAPPERS=' sudo env command exec nohup nice time timeout stdbuf xargs builtin doas '

st_lower "$cmd"
case "$ST_LOWER" in *himmel/go-hmac*) deny "key-bash" "the command text spells himmel/go-hmac" ;; esac

# text_scan <cmd> — the stricter fallback for text the tokenizer does not
# model, or nesting past MAX_DEPTH.
text_scan() {
    local rest
    st_lower "$1"
    case "$ST_LOWER" in *.config/himmel*) deny "key-bash" "unmodelled command names .config/himmel" ;; esac
    [ "$JUDGE" = 0 ] || return 0
    rest="${1//"$CACHE"/}"
    rest="${rest//\~\/.cache\/himmel\/verdicts/}"
    if [[ "$rest" =~ $VRE ]]; then
        case "$rest" in *'>'*) deny "verdicts-bash" "unmodelled write-shaped command names verdicts/" ;; esac
        [[ "$rest" =~ $WRE ]] && deny "verdicts-bash" "unmodelled write-shaped command names verdicts/"
    fi
    return 0
}

# _check_key_word <i> — the word itself, and the value after its first `=`.
_check_key_word() {
    local i="$1" w="${ST_W[$1]}" save=$CWD x
    case "$w" in
        /*|'~'*|'$'*) _check_key_word_in "$i" ;;
        *)
            # relative: against every directory this line can have cd'd into
            [ "$CD_DYN_K" = 0 ] || case "$w" in *go-hmac*) deny "key-bash" "$w after a cd into a dynamic himmel config path" ;; esac
            for x in "${CWDS[@]}"; do
                CWD=$x
                _check_key_word_in "$i"
                CWD=$save
            done ;;
    esac
}
_check_key_word_in() {
    local i="$1" w="${ST_W[$1]}" c a d
    for c in "$w" "${w#*=}"; do
        [ -n "$c" ] || continue
        if [ "${ST_G[i]}" = 1 ]; then
            a=$(_abs "$c")
            [ -n "$a" ] || continue
            glob_hits "$a" && deny "key-bash" "glob $c can match the key"
            # the literal dir prefix may be a symlink to the key dir
            d="${a%%[*?[]*}"
            d="${d%/*}"
            [ -n "$d" ] && glob_hits "$(_phys "$d")${a#"$d"}" && deny "key-bash" "glob $c can match the key"
            continue
        fi
        a=$(_abs "$c")
        [ -n "$a" ] || continue
        is_key "$a" && deny "key-bash" "$c"
    done
}

# _target <text> — a write target outside a judge session.
_target() {
    local t="$1" a
    case "$t" in
        *'$'*|*'`'*)
            case "$t" in *verdicts*) deny "verdicts-bash" "dynamic write target $t" ;; esac
            return 0 ;;
    esac
    # shellcheck disable=SC2088 # a literal ~ word, expanded by _abs
    case "$t" in
        /*|'~'|'~/'*) a=$(_abs "$t")
            [ -n "$a" ] && is_verdicts "$a" && deny "verdicts-bash" "write target $t"
            return 0 ;;
    esac
    # A relative target is checked against every directory this command can
    # have cd'd into, not only the session cwd (codex-2).
    [ "$CD_DYN_V" = 0 ] || deny "verdicts-bash" "write target $t after a cd into a dynamic verdicts path"
    local d save=$CWD
    for d in "${CWDS[@]}"; do
        CWD=$d
        a=$(_abs "$t")
        CWD=$save
        [ -n "$a" ] && is_verdicts "$a" && deny "verdicts-bash" "write target $t"
    done
    return 0
}

# _cd <word> — record a cd/pushd target as a directory later relative write
# targets may resolve against. A dynamic target naming verdicts sets CD_DYN_V.
_cd() {
    local w="$1" d a save=$CWD n=${#CWDS[@]}
    case "$w" in
        *'$'*|*'`'*)
            case "$w" in *verdicts*) CD_DYN_V=1 ;; esac
            case "$w" in *.config*|*himmel*) CD_DYN_K=1 ;; esac
            return 0 ;;
    esac
    for d in "${CWDS[@]:0:n}"; do
        CWD=$d
        a=$(_abs "$w")
        CWD=$save
        [ -n "$a" ] && CWDS+=("$a")
    done
    return 0
}
CWDS=("$CWD")
CD_DYN_V=0
CD_DYN_K=0

# analyze <cmd> <depth> — tokenize and check one command line. A nested
# `bash -c` / `sh -c` script and an `eval` argument are analysed the same way,
# after this level is done (the tokenizer's state is global).
analyze() {
    local depth="$2" nested=() nn=0 k i s w b c ci ro prev a t x
    if [ "$depth" -gt "$MAX_DEPTH" ] || ! st_tokenize "$1"; then
        text_scan "$1"
        return 0
    fi

    # Segment command words: the first non-assignment, non-redirect word,
    # with wrappers, their options and option arguments skipped.
    seg_cmd=(); seg_cmd_i=(); seg_wrap=(); seg_skip=(); seg_last=(); seg_inpl=(); seg_cflag=(); seg_eval=(); seg_cdone=()
    i=0
    while [ "$i" -lt "$ST_N" ]; do
        s=${ST_S[i]}
        if [ -z "${seg_cmd[s]+x}" ] && [ -z "${ST_RO[i]}" ] && [ "${ST_A[i]}" = 0 ]; then
            w=${ST_W[i]}
            b=${w##*/}
            if [ "${seg_skip[s]:-}" = 1 ]; then
                seg_skip[s]=""
            else
                case "$WRAPPERS" in *" $b "*) seg_wrap[s]=1 ;; *)
                    if [ -n "${seg_wrap[s]:-}" ]; then
                        case "$w" in
                            -[sknugCIPLdEaDp]|--signal|--kill-after|--user|--group|--unset|--chdir|--adjustment) seg_skip[s]=1 ;;
                            -*|*=*) ;;
                            *) [[ $w =~ ^[0-9.]+[smhd]?$ ]] || { seg_cmd[s]=$b; seg_cmd_i[s]=$i; } ;;
                        esac
                    else
                        seg_cmd[s]=$b; seg_cmd_i[s]=$i
                    fi ;;
                esac
            fi
        fi
        i=$((i + 1))
    done

    # cd/pushd targets, recorded before either fence resolves a relative word
    # (codex-2). A cd anywhere in the line counts, whatever its position.
    i=0
    while [ "$i" -lt "$ST_N" ]; do
        s=${ST_S[i]}
        ci=${seg_cmd_i[s]:--1}
        if [ -z "${ST_RO[i]}" ] && [ "$ci" -ge 0 ] && [ "$i" -gt "$ci" ]; then
            case "${seg_cmd[s]}" in
                cd|pushd)
                    case "${ST_W[i]}" in
                        -*) ;;
                        *) [ -n "${seg_cdone[s]:-}" ] || { seg_cdone[s]=1; _cd "${ST_W[i]}"; } ;;
                    esac ;;
            esac
        fi
        i=$((i + 1))
    done

    # 1. the key — every word, in every session.
    i=0
    while [ "$i" -lt "$ST_N" ]; do
        _check_key_word "$i"
        s=${ST_S[i]}
        if [ "${ST_G[i]}" = 0 ] && [ "$i" != "${seg_cmd_i[s]:--1}" ]; then
            case "${seg_cmd[s]:-}" in
                cp|rsync|tar|zip|7z|scp|cpio|grep|egrep|rg|ag|find|du|sftp)
                    t=$CWD
                    for x in "${CWDS[@]}"; do
                        CWD=$x
                        a=$(_abs "${ST_W[i]}")
                        CWD=$t
                        [ -n "$a" ] && is_config "$a" && deny "key-bash" "${seg_cmd[s]} over ${ST_W[i]}"
                    done
                    ;;
            esac
        fi
        i=$((i + 1))
    done

    # Per-segment operand facts, and the nested scripts to analyse next.
    i=0
    while [ "$i" -lt "$ST_N" ]; do
        s=${ST_S[i]}
        ci=${seg_cmd_i[s]:--1}
        if [ -z "${ST_RO[i]}" ] && [ "$ci" -ge 0 ] && [ "$i" -gt "$ci" ]; then
            w=${ST_W[i]}
            case "$w" in -*) ;; *) seg_last[s]=$i ;; esac
            case "$w" in -i*|--in-place*) seg_inpl[s]=1 ;; esac
            case "${seg_cmd[s]}" in
                bash|sh|zsh|dash|ksh)
                    case "$w" in
                        --*) ;;
                        -*c*) seg_cflag[s]=1 ;;
                        -*) ;;
                        *)
                            if [ "${seg_cflag[s]:-}" = 1 ]; then
                                nested[nn]=$w; nn=$((nn + 1)); seg_cflag[s]=2
                            fi ;;
                    esac ;;
                eval)
                    # eval runs its arguments joined by spaces, as one script (codex-3).
                    seg_eval[s]="${seg_eval[s]:-} $w" ;;
            esac
        fi
        i=$((i + 1))
    done
    for s in ${seg_eval[@]+"${!seg_eval[@]}"}; do
        nested[nn]=${seg_eval[s]}; nn=$((nn + 1))
    done

    # 2. verdicts/ — write targets, outside a judge session.
    if [ "$JUDGE" = 0 ]; then
        i=0
        prev=""
        while [ "$i" -lt "$ST_N" ]; do
            s=${ST_S[i]}
            w=${ST_W[i]}
            ro=${ST_RO[i]}
            if [ -n "$ro" ]; then
                case "$ro" in
                    *'<&') ;;
                    *'>&')
                        # `>& file` writes the file; only an fd number or `-` duplicates (codex-1).
                        case "$w" in *[!0-9-]*) _target "$w" ;; esac ;;
                    *'>'*) [ "$w" = /dev/null ] || _target "$w" ;;
                esac
                prev=""
                i=$((i + 1))
                continue
            fi
            c=${seg_cmd[s]:-}
            ci=${seg_cmd_i[s]:--1}
            if [ "$ci" -ge 0 ] && [ "$i" -gt "$ci" ]; then
                case "$c" in
                    tee|rm|rmdir|mv|truncate|shred|unlink|touch|chmod|chown|patch)
                        case "$w" in -*) ;; *) _target "$w" ;; esac ;;
                    sed)
                        if [ "${seg_inpl[s]:-}" = 1 ]; then
                            case "$w" in -*) ;; *) _target "$w" ;; esac
                        fi ;;
                    cp|install|ln|rsync|scp)
                        case "$w" in
                            --target-directory=*) _target "${w#--target-directory=}" ;;
                            -*) ;;
                            *)
                                case "$prev" in -t|--target-directory) _target "$w" ;; esac
                                [ "$i" = "${seg_last[s]:-}" ] && _target "$w"
                                ;;
                        esac ;;
                    dd)
                        case "$w" in of=*) _target "${w#of=}" ;; esac ;;
                    python|python2|python3|perl|ruby|node|php|awk|gawk)
                        t="${w//"$CACHE"/}"
                        [[ "$t" =~ $VRE ]] && deny "verdicts-bash" "$c one-liner names verdicts/" ;;
                esac
            fi
            prev=$w
            i=$((i + 1))
        done
    fi

    k=0
    while [ "$k" -lt "$nn" ]; do
        analyze "${nested[k]}" $((depth + 1))
        k=$((k + 1))
    done
    return 0
}

analyze "$cmd" 0
exit 0
