#!/usr/bin/env bash
# PreToolUse hook for Edit/Write/MultiEdit/NotebookEdit, plus Bash and
# PowerShell write-path arms.
#
# Denies writing to a LIVE settings.json/settings.local.json — the operator's
# actual $HOME/.claude/ user-scope config, or the PRIMARY checkout's
# .claude/settings*.json (a change there only takes effect after PR review,
# merge, and the operator's next launch) — while ALLOWING the identical edit
# inside a linked git worktree, where landing a settings change is the
# legitimate mechanism (HIMMEL-2360).
#
# Replaces two now-removed `permissions.deny` rules
# (`Edit(**/.claude/settings.json)`, `Edit(**/.claude/settings.local.json)`)
# that were too broad: they also blocked a leg from editing the WORKTREE COPY
# of settings.json, which is harmless — a worktree edit has no effect until
# it rides that leg's PR through review and merge.
#
# Deny requires ALL of:
#   1. basename is settings.json or settings.local.json
#   2. immediate parent dir is named .claude
#   3. EITHER under $HOME/.claude/ (user-scope live config)
#      OR the target's repo is a PRIMARY checkout: `git rev-parse --git-dir`
#      and `--git-common-dir`, both resolved to absolute paths, are EQUAL.
# A linked worktree has git-dir != git-common-dir -> ALLOW.
#
# Deliberately NOT the cheaper `.git`-is-a-directory-vs-file proxy that
# block-edit-on-main.sh uses: that proxy would ALLOW a SUBMODULE's
# settings.json too (a submodule's `.git` is also a FILE, same shape as a
# linked worktree's). A submodule is a real checkout, not disposable
# work-in-progress — its settings.json should stay protected. The
# git-dir/git-common-dir comparison denies it correctly; do not "simplify"
# this back to the .git file/dir proxy.
#
# A second full clone of the repo elsewhere on disk also has
# git-dir == git-common-dir and is therefore DENIED too — intended: this
# hook protects by REPO LAYOUT (primary checkout vs. linked worktree), not by
# a specific machine path.
#
# Known limitation, deliberately not chased (HIMMEL-2360 CR round 4,
# codex-1): canon() follows symlinks (both `realpath -m` and
# `pathlib.resolve()` dereference existing symlink components), so if
# `.claude/settings.json` is ITSELF a symlink to a differently-named/located
# file, the basename/parent check runs against the SYMLINK'S TARGET, not
# "settings.json"/".claude" — a bypass. Out of scope for this arm's actual
# threat model: mediating CLAUDE's own tool calls against a live config file,
# not defending against an attacker who can already plant an arbitrary
# symlink inside the checkout, which is filesystem write access at least as
# strong as editing settings.json directly. Consistent with the existing
# "not a complete write fence" scope (below) — Copy-Item/Move-Item/New-Item
# under PowerShell aren't covered (see the PowerShell arm below).
#
# Bash/PowerShell arm (HIMMEL-2360 retask, rewritten HIMMEL-1525 retask 2):
# the replaced permission rules also covered Bash redirect targets, so a
# bare `Edit`/`Write`/etc. arm alone would silently reopen
# `echo x > <primary>/.claude/settings.json`.
#
# v1 of this arm extracted a "destination argument" per verb (redirect
# target, cp/mv's last arg, tee/sed -i's write args, a node -e/python3 -c
# fail-closed carve-out). Console adversarial review (NO-GO on PR #1115)
# found per-verb argument extraction cannot be made complete: trailing
# `;`/`&`/`#`/`2>&1`/`| cat`/`> /dev/null`, a directory destination
# (`cp x .claude/`, `-t .claude/`), combined short flags (`sed -Ei`),
# subshells/aliasing/indirection (`(cp …)`, `\cp`, `/bin/cp`, `xargs cp`,
# `bash -c '…'`, `eval`, `$(cp …)`, a for-loop) and other interpreters
# (`node -p`) all defeated the per-verb scan on the very verbs it claimed to
# cover — while ALSO false-positive-denying a worktree's own interpreter
# writes and read-only pipelines (`tee /tmp/log < .claude/settings.json`)
# because the target was never resolved against cwd.
#
# v2 (this version) drops per-verb argument extraction entirely and asks
# only two questions of the WHOLE command text, case-insensitively:
#   1. Does it mention a live settings file at all (substring match on
#      `settings.json` / `settings.local.json` — any prefix, quoting, or
#      trailing chaining/redirection, none of which changes whether the
#      file is NAMED)? If so, deny — UNLESS the command is one of a short
#      read-only allowlist (cat/head/tail/less/grep/rg/jq without a
#      redirect or `-i`/diff/wc/git diff|show|log|status|blame) with no
#      chaining or redirection metacharacter anywhere (so a trailing
#      `&& rm -rf /` can't ride in on an allowlisted first verb).
#   2. Does it target the primary's `.claude/` DIRECTORY itself as a
#      destination (cp/mv/install/rsync/ln/dd/tee/truncate/tar/gtar/bsdtar/unzip, git
#      checkout/restore, or a `-t`/`--target-directory` flag) without
#      necessarily naming settings.json in the text (`cp x .claude/`)?
# Either question denies ONLY when the mention resolves to a LIVE file: cwd
# is itself the primary checkout, or the command text contains the primary
# checkout's own absolute path or $HOME's (resolved once via
# git-common-dir/canon(), not re-parsed per candidate). A RELATIVE mention (no `..`, cd or -C)
# while cwd is a linked worktree names that worktree's OWN settings.json —
# allowed for every verb, matching a Write/Edit to the same path (fixes the
# false positives above). This is deliberately MORE conservative than v1 in
# one direction: a benign `cp <primary settings.json> /tmp/x` (reading, not
# overwriting) is now denied too, since verb/argument-position is no longer
# parsed — bypass: `EDIT_LIVE_SETTINGS_OK=1`, or use an allowlisted reader.
#
# ponytail: a variable-built path (`f="$HOME/.claude/settings.json"; cat
# "$f"`), a glob (`cat .cla*/settings.json`), a symlink staged to alias the
# file, or an absolute path into a SECOND clone of this repo elsewhere on
# disk (not this session's own primary) get no special handling here — none
# are text-matchable without a shell parser, and the Claude permission
# matcher (`permissions.deny` patterns), not this hook, is the right layer
# for that residual.
#
# Hook input arrives on stdin as JSON. Exit codes:
#   0 — allow
#   2 — block; stderr is shown to Claude and the user
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# python3 hang armor (HIMMEL-249): the Windows Store python3 stub can wedge
# (ignores SIGTERM, orphan child holds the $() pipe) — and a hung PreToolUse
# hook hangs the whole session. canon()'s python fallbacks go through this.
# Sourced GUARDED: under set -e an unguarded failed source exits rc=1, and
# PreToolUse only blocks on exit 2 — a missing lib would fail this security
# hook OPEN. Fail CLOSED instead (matches the capability checks below).
# shellcheck source=../lib/py-armor.sh
# shellcheck disable=SC1091
if ! { [ -r "$SCRIPT_DIR/../lib/py-armor.sh" ] && . "$SCRIPT_DIR/../lib/py-armor.sh"; } 2>/dev/null; then
    echo "block-edit-live-settings: cannot source py-armor.sh — refusing to evaluate" >&2
    exit 2
fi

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

# --- Capability checks (fail CLOSED on missing deps; security boundary) ---
if ! command -v jq >/dev/null 2>&1; then
    echo "block-edit-live-settings: jq not on PATH — refusing to evaluate; install jq or comment the hook in .claude/settings.json" >&2
    exit 2
fi
if ! command -v git >/dev/null 2>&1; then
    echo "block-edit-live-settings: git not on PATH — refusing to evaluate; install git or comment the hook in .claude/settings.json" >&2
    exit 2
fi

# Pick a canonicaliser. GNU realpath -m is preferred (handles non-existent
# paths). BSD realpath on macOS does NOT support -m, so fall back to python
# (pathlib resolves traversal + symlinks AND emits POSIX forward slashes for
# self-consistency with the realpath-m branch). Fail CLOSED if neither is
# available — see block-edit-on-main.sh's twin comment for why (a missing
# canonicaliser would re-open the `worktrees/../foo.sh` bypass).
#
# CANON_FORCE env var (test-only) overrides probe.
CANON_MODE=""
if [ -n "${CANON_FORCE:-}" ]; then
    CANON_MODE="$CANON_FORCE"
else
    probe=$(realpath -m /nonexistent-canon-probe 2>/dev/null || true)
    if [ "$probe" = "/nonexistent-canon-probe" ]; then
        CANON_MODE="realpath-m"
    elif command -v python3 >/dev/null 2>&1; then
        CANON_MODE="python3"
    elif command -v python >/dev/null 2>&1; then
        CANON_MODE="python"
    else
        echo "block-edit-live-settings: needs GNU realpath -m or python (3.x) — refusing to evaluate; install GNU coreutils (macOS: brew install coreutils && add gnubin to PATH) or comment the hook" >&2
        exit 2
    fi
fi

# normalize_drive_form PATH — Windows/Git-Bash only: unify backslashes to
# forward slashes, and a single-letter POSIX mount (Git-Bash's own /c/...
# translation of a drive letter) to the SAME drive-letter form (C:/...) used
# by this git build's own absolute-path output and by Windows-native callers
# (Claude Code's JSON, most likely). Without this, two strings naming the
# IDENTICAL file compare unequal by pure text — `realpath -m` does NOT
# cross-translate between the two representations (verified empirically:
# `realpath -m /c/Users/x` stays `/c/Users/x`, never `C:/Users/x`). This is
# the mechanism behind "$HOME comparison must be canonicalised the same way
# as the target" — $HOME is POSIX-mount form by default in Git-Bash while a
# target path from Claude Code is Windows-drive form, so without this they
# would never match. A generic multi-segment mount (not a single drive
# letter) is left untouched — out of scope; no such mount is expected for a
# real project path or $HOME.
normalize_drive_form() {
    local p="${1//\\//}"
    case "$p" in
        /[A-Za-z]/*)
            local letter="${p:1:1}"
            letter=$(printf '%s' "$letter" | tr '[:lower:]' '[:upper:]')
            p="${letter}:${p:2}"
            ;;
        [a-z]:/*)
            # Already drive form but a lowercase letter (Windows hands the
            # same file back interchangeably as c:/... or C:/...) — upper-
            # case it so it compares equal to the /[A-Za-z]/* branch's output.
            local letter="${p:0:1}"
            letter=$(printf '%s' "$letter" | tr '[:lower:]' '[:upper:]')
            p="${letter}${p:1}"
            ;;
    esac
    printf '%s\n' "$p"
}

canon() {
    # Canonicalise a path. Returns empty on failure; caller MUST decide how
    # to treat empty (edit-tool arm fails closed on it, Bash arm skips the
    # target and keeps scanning). See block-edit-on-main.sh's twin for the
    # py_armor_capture rationale (HIMMEL-249).
    local p; p=$(normalize_drive_form "$1")
    case "$CANON_MODE" in
        realpath-m)
            realpath -m "$p" 2>/dev/null
            ;;
        python3)
            py_armor_capture -c 'import sys,pathlib;print(pathlib.Path(sys.argv[1]).resolve(strict=False).as_posix())' "$p" 2>/dev/null || return 1
            printf '%s\n' "$PY_ARMOR_OUT"
            ;;
        python)
            PY_ARMOR_BIN=python py_armor_capture -c 'import sys,pathlib;print(pathlib.Path(sys.argv[1]).resolve(strict=False).as_posix())' "$p" 2>/dev/null || return 1
            printf '%s\n' "$PY_ARMOR_OUT"
            ;;
        *)
            return 1
            ;;
    esac
}

# check_target RAW_TARGET — resolve RAW_TARGET (joined onto $cwd if relative)
# and test it against the deny predicate. Prints exactly one of:
#   "deny <reason>: <canonicalised path>"
#   "allow"
#   "unknown"                      (canonicalisation failed)
# Never exits — callers decide fail-open vs fail-closed on "unknown".
check_target() {
    local raw="$1" t real base parent parent_base
    t="$raw"
    case "$t" in
        /*|[A-Za-z]:/*|[A-Za-z]:\\*) : ;;   # already absolute (POSIX or Windows drive form)
        *) t="$cwd/$t" ;;
    esac

    real=""; real=$(canon "$t") || real=""
    if [ -z "$real" ]; then
        echo "unknown"
        return
    fi

    # Case-FOLDED basename/parent match (HIMMEL-2360 CR round 2): NTFS and
    # APFS/HFS+ are case-insensitive by default, so `.CLAUDE/SETTINGS.JSON`
    # and `.claude/settings.json` name the SAME live file there — a
    # case-sensitive `case` match would let alternate casing walk straight
    # past this security fence. Fold both sides to lowercase before
    # comparing; per scripts/hooks/CLAUDE.md a security fence prefers a
    # false positive (denying an unrelated same-name-different-case file on
    # a case-SENSITIVE filesystem, vanishingly unlikely for this basename)
    # over a false negative (missing the real bypass).
    base=$(basename "$real")
    base_lc=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
    case "$base_lc" in
        settings.json|settings.local.json) : ;;
        *) echo "allow"; return ;;
    esac

    parent=$(dirname "$real")
    parent_base=$(basename "$parent")
    parent_base_lc=$(printf '%s' "$parent_base" | tr '[:upper:]' '[:lower:]')
    if [ "$parent_base_lc" != ".claude" ]; then
        echo "allow"; return
    fi

    # User-scope live config: $HOME/.claude/settings*.json. Case-FOLDED
    # (HIMMEL-2360 CR round 4): this compares the FULL parent PATH, not just
    # its basename, so round 2's basename/parent-basename fold does not
    # cover it — `$HOME/.CLAUDE/settings.json` (already past the folded
    # parent_base_lc gate above) still failed THIS case-sensitive equality
    # and fell through to allow on a non-repo, non-worktree cwd.
    if [ -n "${HOME:-}" ]; then
        local home_real=""
        home_real=$(canon "$HOME") || home_real=""
        if [ -n "$home_real" ]; then
            home_real="${home_real%/}"
            local parent_lc home_real_lc
            parent_lc=$(printf '%s' "$parent" | tr '[:upper:]' '[:lower:]')
            home_real_lc=$(printf '%s' "$home_real" | tr '[:upper:]' '[:lower:]')
            if [ "$parent_lc" = "$home_real_lc/.claude" ]; then
                echo "deny user-scope live config (\$HOME/.claude): $real"
                return
            fi
        fi
    fi

    # Primary-checkout live config: git-dir == git-common-dir (both resolved
    # to absolute paths). A linked worktree's git-dir lives under the
    # primary's .git/worktrees/<name> and so differs from git-common-dir ->
    # not denied here. A repo that isn't found at all is simply not a
    # primary checkout -> falls through to "allow" below; this is not a
    # capability failure, so it does not fail closed.
    #
    # `git -C <dir>` requires <dir> to literally exist on disk — but $parent
    # may not (a Write into a not-yet-created subdir, or a canonicalised
    # traversal that lands on a hypothetical nested path). Walk up from
    # $parent to the nearest ancestor that actually has a `.git` entry
    # (mirrors block-edit-on-main.sh's own ancestor walk) and anchor the git
    # calls there instead — that directory is guaranteed to exist.
    local _d="$parent" _prev="" repo_anchor=""
    while [ "$_d" != "$_prev" ]; do
        if [ -e "$_d/.git" ]; then repo_anchor="$_d"; break; fi
        _prev="$_d"
        _d=$(dirname "$_d") || _d="$_prev"
    done

    if [ -n "$repo_anchor" ]; then
        local raw_git_dir="" raw_git_common=""
        raw_git_dir=$(git -C "$repo_anchor" rev-parse --git-dir 2>/dev/null) || raw_git_dir=""
        raw_git_common=$(git -C "$repo_anchor" rev-parse --git-common-dir 2>/dev/null) || raw_git_common=""
        if [ -n "$raw_git_dir" ] && [ -n "$raw_git_common" ]; then
            local abs_git_dir abs_git_common git_dir_real="" git_common_real=""
            case "$raw_git_dir" in
                /*|[A-Za-z]:/*|[A-Za-z]:\\*) abs_git_dir="$raw_git_dir" ;;
                *) abs_git_dir="$repo_anchor/$raw_git_dir" ;;
            esac
            case "$raw_git_common" in
                /*|[A-Za-z]:/*|[A-Za-z]:\\*) abs_git_common="$raw_git_common" ;;
                *) abs_git_common="$repo_anchor/$raw_git_common" ;;
            esac
            git_dir_real=$(canon "$abs_git_dir") || git_dir_real=""
            git_common_real=$(canon "$abs_git_common") || git_common_real=""
            if [ -n "$git_dir_real" ] && [ -n "$git_common_real" ] && [ "$git_dir_real" = "$git_common_real" ]; then
                echo "deny primary checkout (git-dir == git-common-dir): $real"
                return
            fi
        fi
    fi

    echo "allow"
}

# check_claude_dir_target RAW_OPERAND — the Bash arm's operand check
# (HIMMEL-3700, J1329O I1): like check_target, but an operand that resolves to
# a `.claude` DIRECTORY ITSELF (a symlinked dir used as a dir-destination) is
# classified exactly as check_target classifies a settings file's parent, so
# a symlink onto the primary's or $HOME's `.claude/` denies whatever the
# operand is called. Anything else — including a path deep under `.claude/` —
# is judged by check_target alone (a settings leaf denies; a deeper path
# cannot become the live settings.json, and denying it broke ordinary
# reads/appends of `.claude/logs/*`). Prints "deny …", "allow" or "unknown".
check_claude_dir_target() {
    local raw="$1" t real
    case "$raw" in
        /*|[A-Za-z]:/*|[A-Za-z]:\\*) t="$raw" ;;
        *) t="$cwd/$raw" ;;
    esac
    real=""; real=$(canon "$t") || real=""
    if [ -z "$real" ]; then
        echo "unknown"
        return
    fi
    case "${real##*/}" in
        [.][cC][lL][aA][uU][dD][eE])
            check_target "$real/settings.json"
            return
            ;;
    esac
    check_target "$raw"
}

deny_message() { # deny_message TOOL_LABEL ORIGINAL_TARGET REASON
    cat >&2 <<EOF
⛔ block-edit-live-settings: refusing $1 on \`$2\` — $3.

This is a LIVE settings file: user-scope (\$HOME/.claude/) or the PRIMARY
checkout's .claude/ — a change there takes effect immediately, unreviewed.

Edit the copy inside a worktree instead and let it ride that leg's PR
through review and merge (it only takes effect after the operator's next
launch):

    cd .claude/worktrees/<your-leg>
    # edit .claude/settings.json there

Bypass (single-run, set in the LAUNCHING shell — a per-call prefix cannot
reach the hook process):

    EDIT_LIVE_SETTINGS_OK=1 claude

Or temporarily comment out the hook stanza in .claude/settings.json.
EOF
}

# resolve_repo_context — sets is_primary_cwd (1 if $cwd's repo has
# git-dir == git-common-dir), primary_root_lc (the primary checkout's own
# absolute path, lowercased — dirname of git-common-dir, which for BOTH a
# primary cwd and a linked-worktree cwd resolves to the SAME primary
# directory) and home_root_lc (canon($HOME), lowercased). Empty on failure —
# callers must guard on non-empty before using either as a case pattern (an
# empty quoted pattern segment inside `*"$var"*` matches everything).
resolve_repo_context() {
    is_primary_cwd=0
    primary_root_lc=""
    own_root_lc=""
    home_root_lc=""
    local _d _prev repo_anchor="" raw_git_dir raw_git_common
    local abs_git_dir abs_git_common git_dir_real git_common_real primary_root home_real
    _d="$cwd"; _prev=""
    while [ "$_d" != "$_prev" ]; do
        if [ -e "$_d/.git" ]; then repo_anchor="$_d"; break; fi
        _prev="$_d"
        _d=$(dirname "$_d") || _d="$_prev"
    done
    if [ -n "$repo_anchor" ]; then
        raw_git_dir=$(git -C "$repo_anchor" rev-parse --git-dir 2>/dev/null) || raw_git_dir=""
        raw_git_common=$(git -C "$repo_anchor" rev-parse --git-common-dir 2>/dev/null) || raw_git_common=""
        if [ -n "$raw_git_dir" ] && [ -n "$raw_git_common" ]; then
            case "$raw_git_dir" in
                /*|[A-Za-z]:/*|[A-Za-z]:\\*) abs_git_dir="$raw_git_dir" ;;
                *) abs_git_dir="$repo_anchor/$raw_git_dir" ;;
            esac
            case "$raw_git_common" in
                /*|[A-Za-z]:/*|[A-Za-z]:\\*) abs_git_common="$raw_git_common" ;;
                *) abs_git_common="$repo_anchor/$raw_git_common" ;;
            esac
            git_dir_real=$(canon "$abs_git_dir") || git_dir_real=""
            git_common_real=$(canon "$abs_git_common") || git_common_real=""
            if [ -n "$git_dir_real" ] && [ -n "$git_common_real" ]; then
                [ "$git_dir_real" = "$git_common_real" ] && is_primary_cwd=1
                primary_root=$(dirname "$git_common_real")
                primary_root_lc=$(printf '%s' "$primary_root" | tr '[:upper:]' '[:lower:]' | tr -d "\"'")
                own_root_lc=$(canon "$repo_anchor" | tr '[:upper:]' '[:lower:]' | tr -d "\"'") || own_root_lc=""
            fi
        fi
    fi
    if [ -n "${HOME:-}" ]; then
        home_real=$(canon "$HOME") || home_real=""
        if [ -n "$home_real" ]; then
            home_real="${home_real%/}"
            # Quote-stripped like the command text in mentions_primary_or_home,
            # or an apostrophe in the root itself never matches (HIMMEL-3468).
            home_root_lc=$(printf '%s' "$home_real" | tr '[:upper:]' '[:lower:]' | tr -d "\"'")
        fi
    fi
}

# has_traversal_dots TEXT — true when a literal `..` is an actual
# path-traversal component: a non-path-name character (`/`, quote, space,
# start/end of string) on EITHER side, never a bare substring anywhere in the
# text. A `<sha>..<sha>` git range has a hex digit on BOTH sides of the `..`
# and never matches; `../.claude`, `worktrees/wt/../../x`, a bare `cd ..` and
# a `..` glued to a short option (`-t../primary/.claude`) all still match
# (HIMMEL-3675: the three `*..*` glob checks below treated a benign SHA range
# identically to a real climb-out, false-DENYing `impacted-suites.sh --check
# <base>..<head>` run from a linked worktree; a both-sides-only boundary check
# then let a glued short option through undetected — HIMMEL-3675 judge NO-GO).
has_traversal_dots() {
    [[ "$1" =~ (^|[^a-z0-9_])\.\.|\.\.([^a-z0-9_]|$) ]]
}

# mentions_primary_or_home CMD_LC — true when the command text contains the
# resolved primary checkout's own path, the resolved $HOME, or an
# unexpanded $HOME/~ literal immediately before .claude — i.e. the mention
# is NOT just a bare relative spelling of the current worktree's own copy.
mentions_primary_or_home() {
    local c="$1" c_noquotes
    # A quoted `"/resolved/path"/.claude/` interposes a quote character
    # between the resolved absolute path and its `.claude` suffix, which a
    # literal substring match can't span — strip quote characters once up
    # front so every match below sees the path as one contiguous string
    # regardless of quoting (matches the $HOME-literal handling further down).
    c_noquotes=$(printf '%s' "$c" | tr -d "\"'")
    # A linked worktree nested under the primary (`<primary>/.claude/
    # worktrees/<wt>`) contains the primary root in its own absolute path, so
    # its OWN settings write matched below (HIMMEL-3468 codex-1). Blank out
    # this worktree's own root first — never when a real traversal `..`
    # (has_traversal_dots) appears anywhere, since `<wt>/../../settings.json`
    # climbs back into the primary; a `<sha>..<sha>` git range never counts
    # (HIMMEL-3675). Only the root followed by `/` is removed: a bare string
    # prefix would also eat the front of a sibling path (`<dir>/prim` inside
    # `<dir>/primary/...`).
    if [ "$is_primary_cwd" = "0" ] && [ -n "$own_root_lc" ]; then
        if ! has_traversal_dots "$c_noquotes"; then
            # Pattern in a variable: bash 3.2 drops the quoted trailing `/` of an
            # inline `"$own_root_lc/"`, so it blanked the bare prefix (`<dir>/prim`
            # out of `<dir>/primary/...`) and hid the primary's own path.
            local own_root_pat="$own_root_lc/"
            c_noquotes=${c_noquotes//"$own_root_pat"/}
        fi
    fi
    # Only the primary root's OWN .claude counts as live — matching
    # primary_root_lc as a bare substring anywhere also matched any command
    # that merely mentions the primary checkout's resolved path with no
    # .claude reference at all, over-denying that command (HIMMEL-3465).
    # Same /.claude-adjacency treatment as home_root_lc below.
    if [ -n "$primary_root_lc" ]; then
        case "$c_noquotes" in *"$primary_root_lc/.claude"*) return 0 ;; esac
    fi
    # Only the resolved $HOME's OWN .claude counts as live — matching
    # home_root_lc as a bare substring anywhere also matched an unrelated
    # absolute path merely nested under $HOME (e.g. a worktree's own path),
    # over-denying that worktree's legitimate writes to its own settings.
    if [ -n "$home_root_lc" ]; then
        case "$c_noquotes" in *"$home_root_lc/.claude"*) return 0 ;; esac
    fi
    # An unexpanded home spelling (`~`, `~user`, `$HOME`, `${HOME}`) right
    # before `.claude`, which may end the word: `cp x ~/.claude` names the
    # directory itself as the destination.
    local out
    # shellcheck disable=SC2016 # literal unexpanded $home/${home} text, not expansion
    out=$(printf '%s' "$c_noquotes" | grep -E '(~[a-z0-9._-]*|\$home|\$\{home\})/\.claude([^a-z0-9_.-]|$)') || true
    [ -n "$out" ] && return 0
    # A relative parent-directory traversal landing directly on `.claude/`
    # (`../.claude/…`, any number of `../` segments) climbs OUT of the
    # current worktree — the worktree-relative exemption only covers this
    # worktree's own copy, which never needs `..` to name it, and in the
    # real `<repo>/.claude/worktrees/<name>` layout this is exactly the
    # shape that reaches the primary checkout's own `.claude/`.
    case "$c_noquotes" in *'../.claude/'*) return 0 ;; esac
    return 1
}

# is_readonly_allowlisted CMD_LC — the rule 1 exception: a short list of
# read-only programs, invoked alone (no chaining/redirection metacharacter
# anywhere, so a trailing `&& rm -rf /` can't ride in on an allowlisted
# first verb). Since HIMMEL-3546 a Bash command that tokenizes (TOK=1) is
# judged per segment by _tok_readonly_ok instead; this text check now serves
# PowerShell and a Bash command the tokenizer could not vouch for (TOK=0).
# ponytail: a bare `;` vetoes the whole command unconditionally, even when
# every `;`-separated segment is independently read-only (e.g.
# `SP=/some/path; jq '...' "$SP/a.json"; jq '...' "$SP/b.json"` denies).
# HIMMEL-3465/3517 panel rounds 2 and 3 both found a real bypass in a
# narrower per-segment allowlist (a same-line assignment shortcut riding
# past a later write on a newline-embedded segment; the same shortcut then
# recurring for a different segment shape one round later) — rising-severity
# findings concentrated in that one surface, so panel-first-pass.sh's own
# HALT-and-simplify signal fired and the per-segment split was reverted back
# to this blunt veto rather than patched a third time. A real fix needs
# quote-aware tokenization of the whole command, not another metacharacter
# scan. Upgrade path: HIMMEL-3546 did that for Bash (_tok_readonly_ok);
# PowerShell would need its own tokenizer, if a false deny there recurs.
is_readonly_allowlisted() {
    local c="$1" first second
    # shellcheck disable=SC2016 # literal metacharacter text, not expansion
    case "$c" in
        *';'*|*'&'*|*'|'*|*'`'*|*'$('*|*'<('*|*'>'*|*tee*) return 1 ;;
    esac
    first=$(printf '%s' "$c" | awk '{print $1}')
    case "$first" in
        cat|head|tail|grep|rg|diff|wc) return 0 ;;
        ls) [ "$_RO_LS" = 1 ] && return 0; return 1 ;;
        less)
            # less -o/-O (case already folded by cmd_lc) or --log-file logs
            # the input stream to a file — a write, despite the read-only verb.
            case "$c" in *' -o'*|*'--log-file'*) return 1 ;; esac
            return 0
            ;;
        jq)
            case "$c" in *' -i'*|*'--in-place'*) return 1 ;; esac
            return 0
            ;;
        git)
            second=$(printf '%s' "$c" | awk '{print $2}')
            case "$second" in diff|show|log|status|blame) ;; *) return 1 ;; esac
            # --output/--output=<file> redirects these read-only subcommands'
            # output to a file — writing, not reading, despite the verb.
            case "$c" in *'--output'*) return 1 ;; esac
            return 0
            ;;
        *) return 1 ;;
    esac
}

# The token-based checks below read the ST_* arrays st_tokenize (inlined
# above) left for the Bash command (HIMMEL-3546). TOK is 1 when those tokens
# can be trusted to be the whole command: it parsed, and it carries no
# heredoc (a body the tokenizer skips, which `bash <<EOF` would run) and no
# ANSI-C `$'…'` word (which spells any byte). TOK=0 sends every caller back
# to the older whole-text scan (PowerShell always) or fails closed.
TOK=0
# 1 when only a glob/alias leaf (HIMMEL-3938), not a named settings file, made
# the command a candidate: `ls` is then a read the allowlist may pass.
_RO_LS=0

# _tok_verb_write KIND REGEX — 0 (a candidate write) unless EVERY segment
# whose text matches REGEX (the same lowercased verb pattern
# has_write_verb_or_target_flag matched against the whole text) is accounted
# for as a non-writing use (HIMMEL-3564): every segment is judged, not the
# first that matched, and each tar/unzip word is judged by its own first
# argument, not by a flag anywhere in the text.
#   tar      every tar/gtar/bsdtar word (any case, any position — `find -exec
#            tar …` too) is followed by a create/list mode: -c…, -t…,
#            --create, --list, or an old-style `c…`/`t…` cluster. A segment
#            that matched REGEX with no tar word (`cat a.tar`) is a write,
#            as before.
#   unzip    every unzip word is followed by -l…, -t… or -v… (case-sensitive:
#            `-L` is not list mode).
#   checkout the matching segment also carries a `git` word.
# A match that no segment accounts for (it sat in a comment) is a write too,
# as is TOK=0.
_tok_verb_write() {
    local kind=$1 re=$2 s k j sg arg matched=0 gre='(^|[^a-z0-9_])git([^a-z0-9_]|$)'
    local -a segtxt segm found
    [ "$TOK" = 1 ] || return 0
    # One pass each over the words and the segments, no fork (J1242): a
    # per-segment rescan of every word made a padded command outrun the
    # runner's member timeout, and the runner then skipped this hook.
    k=0
    while [ "$k" -lt "$ST_N" ]; do
        sg=${ST_S[k]}
        segtxt[sg]="${segtxt[sg]:-} ${ST_LW[k]}"
        k=$((k + 1))
    done
    s=0
    while [ "$s" -lt "$ST_NSEG" ]; do
        segm[s]=0
        if [[ ${segtxt[s]:-} =~ $re ]]; then
            matched=1
            segm[s]=1
            if [ "$kind" = checkout ] && [[ ${segtxt[s]:-} =~ $gre ]]; then return 0; fi
        fi
        s=$((s + 1))
    done
    [ "$matched" = 1 ] || return 0
    [ "$kind" != checkout ] || return 1
    k=0
    while [ "$k" -lt "$ST_N" ]; do
        sg=${ST_S[k]}
        if [ "${segm[sg]}" = 1 ] && [ -z "${ST_RO[k]}" ]; then
            case "$kind:${ST_LW[k]##*/}" in
                tar:tar|tar:gtar|tar:bsdtar|unzip:unzip)
                    found[sg]=1
                    # its first argument: the next word in the segment that
                    # is not a redirect target, case kept
                    arg='' j=$((k + 1))
                    while [ "$j" -lt "$ST_N" ] && [ "${ST_S[j]}" = "$sg" ]; do
                        if [ -z "${ST_RO[j]}" ]; then arg=x${ST_W[j]}; break; fi
                        j=$((j + 1))
                    done
                    [ -n "$arg" ] || return 0
                    case "$kind:${arg#x}" in
                        tar:-c*|tar:-t*|tar:--create|tar:--list|tar:[ct]*) ;;
                        unzip:-l*|unzip:-t*|unzip:-v*) ;;
                        *) return 0 ;;
                    esac
                    ;;
            esac
        fi
        k=$((k + 1))
    done
    s=0
    while [ "$s" -lt "$ST_NSEG" ]; do
        if [ "${segm[s]}" = 1 ] && [ "${found[s]:-0}" != 1 ]; then return 0; fi
        s=$((s + 1))
    done
    return 1
}

# _tok_ln_write REGEX — 0 (a candidate write) unless every word matching the
# `ln` REGEX is a plain short-flag cluster of another program (`rg -ln`,
# `git grep -ln`; HIMMEL-3961): a word of only `-` and [a-z0-9], with no live
# `$`, no glob/brace and no redirect. Any other match — `ln`, `/bin/ln`,
# `l\n`, `{ln,…}`, `a=ln`, `${a}ln`, `xargs ln` — is the verb, and a text
# match that no word accounts for (a comment) is a write too, as is TOK=0.
_tok_ln_write() {
    local re=$1 k w hit=0
    [ "$TOK" = 1 ] || return 0
    k=0
    while [ "$k" -lt "$ST_N" ]; do
        w=${ST_LW[k]}
        if [[ $w =~ $re ]]; then
            hit=1
            [[ $w =~ ^-[a-z0-9]+$ ]] || return 0
            [ "${ST_X[k]}" = 0 ] && [ "${ST_G[k]}" = 0 ] && [ -z "${ST_RO[k]}" ] || return 0
        fi
        k=$((k + 1))
    done
    [ "$hit" = 1 ] || return 0
    return 1
}

# _unjudged_cmd_word WORD HAS_EXPANSION HAS_GLOB — 0 when a segment's command
# word cannot be read as a program this hook judges (HIMMEL-4119): a glob or
# brace (`/bin/l?`, `/bin/l{n,}`), a live expansion (`$v`), a flag-shaped word
# (`-ln`, which runs only when an executable of that name is on PATH), or a
# path to a program other than a known read-only one (`/opt/t/plant`;
# `/usr/bin/ls` stays a read). The verb lists match spellings, so a word that
# spells nothing they know cannot be cleared as a non-write: fail closed
# rather than emulate a PATH lookup.
_unjudged_cmd_word() {
    # the test commands write nothing; `[` reads as a glob to the tokenizer
    case "$1" in '['|'[['|test) return 1 ;; esac
    [ "$2" = 0 ] && [ "$3" = 0 ] || return 0
    case "$1" in
        -*) return 0 ;;
        */*)
            # only a system bin dir vouches for the name: `/tmp/ls` is not ls
            case "${1%/*}" in
                /bin|/usr/bin|/usr/local/bin|/opt/homebrew/bin)
                    case "${1##*/}" in
                        cat|head|tail|grep|rg|diff|wc|ls|less|jq|git) return 1 ;;
                    esac
                    ;;
            esac
            return 0
            ;;
    esac
    return 1
}

# _tok_unjudged_verb CMD_LC CMD_N — 0 when some segment's command word (the
# first word that is not an assignment, a redirect target or a reserved word,
# its bin-dir name read in its original case from CMD_N or the tokens) is
# unjudged (_unjudged_cmd_word) AND one of its possible DESTINATION operands —
# a redirect target, any operand that is not an option, an option's `=VALUE`
# (_uj_tok_dests) — can be the `.claude` directory itself (_uj_dir_itself).
# A mere mention (`graphify query x ~/.claude/projects`, a script run from
# under `~/.claude`) is not a destination. Every destination is also left in
# UJ_DEST for the main flow's climb and symlink scan, so `$L -sf X ../../`
# from a nested worktree is judged as `ln -sf X ../../` is. A segment the
# tokenizer ended at `(` is zsh's glob grouping glued to the word
# (`/bin/c(p|q)` runs /bin/cp under zsh), so its word counts as a glob and
# every word to the end of the command is a destination; in bash that shape
# is only a function definition (`f() …`), denied too.
# TOK=0 splits the text on `;`, `&`, `|` and newlines instead, takes each
# piece's first word, and reads the same destinations from that piece's words
# (_uj_text_dests), or every word to the end when the word carries a `(`.
# There a lone `-`, `--`, `*` or `+` (a markdown bullet in a heredoc body) is
# not judged.
# ponytail: a concrete path deeper under `.claude/` is not a destination (the
# settings-name rule judges a settings leaf whatever the verb); upgrade path:
# J1676 ruling — widen _uj_dir_itself only on a reported plant through one.
# An exec wrapper (`env`, `sudo`, `xargs`, `nohup`, `timeout`, zsh's `noglob`
# …) hands its operand on as the command, so after one the first word that
# is not a flag, an assignment or a number is judged as the command word too;
# after a `--` a flag-shaped word is the command (`env -- -ln …`).
# A bare word right after a wrapper option that takes an argument
# (_wrapper_opt_arg: `sudo -u root`) is that argument, not the command; a
# word there that is itself unjudged is still judged, so the table can only
# over-deny, never hide one.
# ponytail: an argument-taking wrapper option missing from the table, and a
# command a program runs from its arguments (`find -exec`, `sh -c '…'`), are
# not judged; upgrade path: extend _wrapper_opt_arg when such a plant is seen.

# _wrapper_opt_arg WRAPPER OPT_LC — 0 when the exec wrapper's option takes the
# next word as its argument. OPT_LC is lowercased, so `-U`/`-u` share a row.
_wrapper_opt_arg() {
    local o=$2 i=1 ch
    # A short-option cluster (`sudo -iu root`, HIMMEL-4149): as getopt reads
    # it, the first letter that takes an argument takes the rest of the
    # cluster, or the next word when it is the cluster's last letter.
    case "$o" in
        --*|-?) ;;
        -*)
            while [ "$i" -lt "${#o}" ]; do
                ch=${o:i:1}
                i=$((i + 1))
                if _wrapper_opt_arg "$1" "-$ch"; then
                    [ "$i" = "${#o}" ] && return 0
                    return 1
                fi
            done
            return 1
            ;;
    esac
    case "$1:$2" in
        sudo:-u|sudo:-g|sudo:-h|sudo:-p|sudo:-c|sudo:-d|sudo:-r|sudo:-t|sudo:-a \
        |sudo:--user|sudo:--group|sudo:--host|sudo:--prompt|sudo:--close-from \
        |sudo:--chdir|sudo:--role|sudo:--type|sudo:--other-user \
        |sudo:--command-timeout|sudo:--chroot|sudo:--auth-type|sudo:--login-class \
        |doas:-u|doas:-c \
        |env:-u|env:-c|env:-s|env:--unset|env:--chdir|env:--split-string \
        |timeout:-s|timeout:-k|timeout:--signal|timeout:--kill-after \
        |nice:-n|nice:--adjustment \
        |ionice:-c|ionice:-n|ionice:-p|ionice:-u|ionice:--class|ionice:--classdata \
        |stdbuf:-i|stdbuf:-o|stdbuf:-e \
        |xargs:-i|xargs:-l|xargs:-n|xargs:-p|xargs:-s|xargs:-d|xargs:-e|xargs:-a \
        |xargs:--arg-file|xargs:--delimiter|xargs:--max-args|xargs:--max-procs \
        |xargs:--max-chars|xargs:--max-lines|xargs:--process-slot-var \
        |exec:-a|time:-f|time:-o|time:--format|time:--output|taskset:-c|chrt:-p)
            return 0 ;;
    esac
    return 1
}

# _uj_dir_itself WORD_LC — 0 when a destination operand can be the `.claude`
# directory itself: it names one (mentions_dot_claude_dir_dest) and nothing
# fixed follows it — `~/.claude`, `~/.claude/.`, a glob, brace, expansion or
# `..` after it. A concrete path deeper under `.claude/` is not the directory
# (check_claude_dir_target's own reading); a settings leaf is judged by the
# settings-name rule whatever the verb.
_uj_dir_itself() {
    local r
    mentions_dot_claude_dir_dest "$1" || return 1
    has_traversal_dots "$1" && return 0
    r=${1##*.claude}
    case "$r" in
        *[!/.]*) ;;
        *) return 0 ;;
    esac
    case "$r" in
        /*) ;;
        *) return 0 ;;
    esac
    case "$r" in
        *[*?[\{\$\`\(]*) return 0 ;;
    esac
    return 1
}

# _uj_dest WORD WORD_LC — record a destination operand of an unjudged command
# word for the main flow's operand (climb/symlink) scan; 0 when it can be the
# `.claude` directory itself.
_uj_dest() {
    UJ_DEST[${#UJ_DEST[@]}]=$1
    _uj_dir_itself "$2"
}

# _uj_tok_dests K SC — the possible destination operands of the command word
# at token K: every redirect target in its segment, every operand that is not
# an option, an `--opt=VALUE` value and a `-t` value glued to its flag. Which
# operand an unknown command writes to cannot be read from its options
# (`… ~/.claude --suffix .bak`), so none is ruled out. With SC=1 (the zsh `(`
# split, whose words cannot be placed) every word to the end. 0 when one is
# the `.claude` dir.
_uj_tok_dests() {
    local k=$1 sc=$2 sg=${ST_S[$1]} w=0 hit=1 lw rem
    while [ "$w" -lt "$ST_N" ]; do
        if [ "${ST_S[w]}" = "$sg" ] || { [ "$sc" = 1 ] && [ "${ST_S[w]}" -gt "$sg" ]; }; then
            lw=${ST_LW[w]}
            if [ -n "${ST_RO[w]}" ]; then
                case "${ST_RO[w]}" in *'>'*) _uj_dest "${ST_W[w]}" "$lw" && hit=0 ;; esac
            elif [ "$w" -le "$k" ]; then
                :
            elif [ "$sc" = 1 ]; then
                _uj_dest "${ST_W[w]}" "$lw" && hit=0
            else
                case "$lw" in
                    -*=*) _uj_dest "${ST_W[w]#*=}" "${lw#*=}" && hit=0 ;;
                    --*) ;;
                    -*t?*)
                        rem=${lw#-*t}
                        _uj_dest "${ST_W[w]#-*t}" "$rem" && hit=0
                        ;;
                    -*) ;;
                    *) _uj_dest "${ST_W[w]}" "$lw" && hit=0 ;;
                esac
            fi
        fi
        w=$((w + 1))
    done
    return "$hit"
}

# _uj_text_dests SKIP ALL TEXT_LC TEXT_N — _uj_tok_dests without tokens: the
# words of TEXT after the first SKIP, `>`-glued or following a `>` word, and
# every operand, `--opt=VALUE` value and glued `-t` value; ALL=1 takes every
# word. TEXT_N is the
# same text in its original case, used for the recorded operand when its
# words line up with TEXT_LC's.
_uj_text_dests() {
    local skip=$1 all=$2 i=0 n tnext=0 hit=1 lw rem nog=0
    local -a lws nws
    case $- in *f*) nog=1 ;; esac
    set -f
    # shellcheck disable=SC2206 # split into words, globbing off
    lws=($3)
    # shellcheck disable=SC2206
    nws=($4)
    [ "$nog" = 1 ] || set +f
    n=${#lws[@]}
    [ "${#nws[@]}" = "$n" ] || nws=(${lws[@]+"${lws[@]}"})
    while [ "$i" -lt "$n" ]; do
        lw=${lws[i]}
        if [ "$tnext" = 1 ]; then
            tnext=0
            _uj_dest "${nws[i]}" "$lw" && hit=0
        else
            case "$lw" in
                *'>'*)
                    rem=${lw##*>}
                    if [ -z "$rem" ]; then tnext=1
                    else _uj_dest "${nws[i]##*>}" "$rem" && hit=0
                    fi
                    ;;
                *)
                    if [ "$i" -lt "$skip" ]; then
                        :
                    elif [ "$all" = 1 ]; then
                        _uj_dest "${nws[i]}" "$lw" && hit=0
                    else
                        case "$lw" in
                            -*=*) _uj_dest "${nws[i]#*=}" "${lw#*=}" && hit=0 ;;
                            --*) ;;
                            -*t?*)
                                rem=${lw#-*t}
                                _uj_dest "${nws[i]#-*t}" "$rem" && hit=0
                                ;;
                            -*) ;;
                            *) _uj_dest "${nws[i]}" "$lw" && hit=0 ;;
                        esac
                    fi
                    ;;
            esac
        fi
        i=$((i + 1))
    done
    return "$hit"
}

_tok_unjudged_verb() {
    local k sg cur=-1 done_seg=0 wrapped=0 wname='' oparg=0 txt ntxt w g sc=0 nog=0 i n skip all
    local -a pieces
    UJ_DEST=()
    if [ "$TOK" = 1 ]; then
        k=0
        while [ "$k" -lt "$ST_N" ]; do
            sg=${ST_S[k]}
            if [ "$sg" != "$cur" ]; then cur=$sg done_seg=0 wrapped=0 oparg=0; fi
            g=${ST_G[k]}
            if [ "$done_seg" = 0 ] && [ -z "${ST_RO[k]}" ] && [ "${ST_A[k]}" = 0 ]; then
                # a bare word after an argument-taking wrapper option is its
                # argument, and a bare number a wrapper's count or duration
                if [ "$wrapped" != 0 ]; then
                    case "${ST_LW[k]}" in [0-9]*) oparg=1 ;; esac
                fi
                if [ "$oparg" = 1 ]; then
                    oparg=0
                    if ! _unjudged_cmd_word "${ST_W[k]}" "${ST_X[k]}" "$g"; then
                        k=$((k + 1))
                        continue
                    fi
                fi
                case "${ST_LW[k]}:${ST_Q[k]}:$wrapped" in
                    if:0:0|then:0:0|else:0:0|elif:0:0|do:0:0|while:0:0|until:0:0|'!:0:0'|'{:0:0') ;;
                    # `--` ends the wrapper's options: the next word is the command
                    --:?:1) wrapped=2 ;;
                    -*:?:1) ! _wrapper_opt_arg "$wname" "${ST_LW[k]}" || oparg=1 ;;
                    [a-z_]*=*:?:[12]) ;;
                    *)
                        done_seg=1 sc=0
                        [ "${ST_SEP[sg]}" != '(' ] || g=1 sc=1
                        if ! _unjudged_cmd_word "${ST_W[k]}" "${ST_X[k]}" "$g"; then
                            case "${ST_LW[k]}" in
                                env|sudo|doas|xargs|command|builtin|exec|nohup|nice|ionice|timeout|stdbuf|setsid|taskset|chrt|unbuffer|time|noglob|nocorrect)
                                    wrapped=1 wname=${ST_LW[k]} done_seg=0 ;;
                            esac
                        else
                            _uj_tok_dests "$k" "$sc" && return 0
                        fi
                        ;;
                esac
            fi
            k=$((k + 1))
        done
        return 1
    fi
    # npieces: the same pieces in the original case ($2), for the bin-dir
    # name check; nok=0 drops back to the lowercased word if they misalign
    local cw nw nok=1
    local -a npieces
    n=0
    while IFS= read -r txt; do
        pieces[n]=$txt
        n=$((n + 1))
    done <<EOF
$(printf '%s\n' "$1" | tr ';&|' '\n')
EOF
    nw=0
    while IFS= read -r txt; do
        npieces[nw]=$txt
        nw=$((nw + 1))
    done <<EOF
$(printf '%s\n' "${2:-$1}" | tr ';&|' '\n')
EOF
    [ "$nw" = "$n" ] || nok=0
    case $- in *f*) nog=1 ;; esac
    i=0
    while [ "$i" -lt "$n" ]; do
        set -f
        # shellcheck disable=SC2086 # split the piece into words, globbing off
        set -- ${pieces[i]}
        [ "$nog" = 1 ] || set +f
        nw=$#
        wrapped=0 oparg=0
        while [ $# -gt 0 ]; do
            w=0; case "$1" in *'$'*) w=1 ;; esac
            g=0; case "$1" in *[*?[\{\(]*) g=1 ;; esac
            [ "$wrapped" = 0 ] || case "$1" in [0-9]*) oparg=1 ;; esac
            if [ "$oparg" = 1 ]; then
                oparg=0
                if ! _unjudged_cmd_word "$1" "$w" "$g"; then shift; continue; fi
            fi
            case "$1:$wrapped" in
                if:?|then:?|else:?|elif:?|do:?|while:?|until:?|'!:'?|'{:'?|'(:'?) shift ;;
                [a-z_]*=*:?) shift ;;
                --:1) shift; wrapped=2 ;;
                -*:1)
                    ! _wrapper_opt_arg "$wname" "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" || oparg=1
                    shift ;;
                env:?|sudo:?|doas:?|xargs:?|command:?|builtin:?|exec:?|nohup:?|nice:?|ionice:?|timeout:?|stdbuf:?|setsid:?|taskset:?|chrt:?|unbuffer:?|time:?|noglob:?|nocorrect:?)
                    wname=$1; shift; wrapped=1 ;;
                *) break ;;
            esac
        done
        cw=${1:--} skip=$((nw - $# + 1))
        if [ "$nok" = 1 ] && [ $# -gt 0 ]; then
            k=$((nw - $#))
            set -f
            # shellcheck disable=SC2086 # the same piece, original case
            set -- ${npieces[i]}
            [ "$nog" = 1 ] || set +f
            if [ $# = "$nw" ]; then shift "$k"; cw=$1; fi
        fi
        case "$cw" in
            -|--|'*'|+) ;;
            *)
                w=0; case "$cw" in *'$'*) w=1 ;; esac
                g=0; case "$cw" in *[*?[\{\(]*) g=1 ;; esac
                if _unjudged_cmd_word "$cw" "$w" "$g"; then
                    # the zsh `(` split runs on past the piece, every word a
                    # possible destination
                    txt=${pieces[i]} ntxt=${npieces[i]} all=0 k=$((i + 1))
                    case "$cw" in
                        *'('*) all=1 ;;
                        *) k=$n ;;
                    esac
                    while [ "$k" -lt "$n" ]; do
                        txt="$txt ${pieces[k]}" ntxt="$ntxt ${npieces[k]}"
                        k=$((k + 1))
                    done
                    [ "$nok" = 1 ] || ntxt=$txt
                    _uj_text_dests "$skip" "$all" "$txt" "$ntxt" && return 0
                fi
                ;;
        esac
        i=$((i + 1))
    done
    return 1
}

# _tok_sensitive_name NAME — an assignment that can change what a later
# read-only command runs or reads: the loader, locale, pager, config-home and
# shell-behaviour variables, and each allowlisted tool's own environment.
# ponytail: a denylist — a variable a future allowlisted tool reads is not
# here until someone adds it; the upgrade path is to allow only lowercase
# names, which needs the console repros (`SP=…`) to change first.
_tok_sensitive_name() {
    case "$1" in
        PATH|IFS|HOME|SHELL|ENV|CDPATH|TMPDIR|TZ|LANG|LANGUAGE|POSIXLY_CORRECT) return 0 ;;
        EDITOR|VISUAL|PAGER|GCONV_PATH|LOCPATH|NLSPATH|GLIBC_TUNABLES|SHELLOPTS) return 0 ;;
        GLOBIGNORE|EXECIGNORE|FIGNORE|FUNCNEST|OPTIND|OPTERR|TIMEFORMAT|INPUTRC) return 0 ;;
        TERM|TERMINFO|TERMCAP|COLUMNS|LINES|MAIL|MAILPATH|HOSTFILE|auto_resume|histchars) return 0 ;;
        BASH*|LD_*|DYLD_*|MALLOC*|LESS*|*PAGER*|GIT_*|SSH*|GREP*|RIPGREP*|JQ_*) return 0 ;;
        LC_*|XDG_*|_POSIX*|HIST*|COMP*|PS[0-9]|PROMPT*) return 0 ;;
    esac
    return 1
}

# _tok_readonly_ok — the rule 1 exception, judged per segment from tokens
# (HIMMEL-3546; replaces is_readonly_allowlisted's bare-`;` veto for Bash).
# Allows only when EVERY segment is either an assignment-only segment or one
# allowlisted read-only program, joined by `;`, `&&`, `||`, `|` or a newline.
# Denies on: any substitution, subshell or background `&`; any word
# containing "tee"; an output redirect other than to /dev/null or an fd dup
# (`2>&1`); `<>`; an assignment to an exported or sensitive name
# (_tok_sensitive_name); a command word carrying a live `$` or a glob; and,
# for less/git/rg/sed, any word carrying a live `$` or a glob — each can
# expand into an option that writes or runs (`-i`, `--output=`, `--pre`,
# `+!cmd`). The per-program option vetoes are the old ones plus rg --pre and
# less `+…`.
_tok_readonly_ok() {
    local s k sg first fk name w lw sub re='^[A-Za-z_][A-Za-z0-9_]*$'
    [ "$ST_SUBST" = 0 ] || return 1
    s=0
    while [ "$s" -lt "$ST_NSEG" ]; do
        case "${ST_SEP[s]}" in ';'|'&&'|'||'|'|'|nl|'') ;; *) return 1 ;; esac
        s=$((s + 1))
    done
    # One pass over the words, no fork per word (J1242): a segment is judged
    # when the next one starts, and the last one after the loop.
    s=-1 first='' fk=-1 sub=''
    k=0
    while [ "$k" -lt "$ST_N" ]; do
        sg=${ST_S[k]}
        if [ "$sg" != "$s" ]; then
            [ "$s" -lt 0 ] || _tok_ro_segment || return 1
            s=$sg first='' fk=-1 sub=''
        fi
        w=${ST_W[k]}
        lw=${ST_LW[k]}
        case "$lw" in *tee*) return 1 ;; esac
        if [ -n "${ST_RO[k]}" ]; then
            case "${ST_RO[k]}" in
                *'<>'*) return 1 ;;
                *'>&') case "$w" in [0-9]|-) [ "${ST_X[k]}" = 0 ] || return 1 ;; *) return 1 ;; esac ;;
                *'>'*) [ "$w" = /dev/null ] || return 1 ;;
            esac
        elif [ "$fk" -lt 0 ] && [ "${ST_A[k]}" = 1 ]; then
            name=${w%%=*}
            [[ $name =~ $re ]] || return 1
            if _tok_sensitive_name "$name"; then return 1; fi
            if _tok_exported "$name"; then return 1; fi
            first=assign
        elif [ "$fk" -lt 0 ]; then
            [ "$first" != assign ] || return 1
            [ "${ST_X[k]}" = 0 ] && [ "${ST_G[k]}" = 0 ] || return 1
            first=$lw fk=$k
        else
            case "$first" in
                less|git|rg|sed) [ "${ST_X[k]}" = 0 ] && [ "${ST_G[k]}" = 0 ] || return 1 ;;
            esac
            [ -n "$sub" ] || sub=x$lw
            case "$first:$lw" in
                # less: -o/-O (alone or in a cluster) and --log-file
                # log the input stream to a file; a `+` word runs a
                # less command at startup (`+!cmd`).
                less:-o*|less:-[!-]*o*|less:--log-file*|less:+*) return 1 ;;
                jq:-i*|jq:--in-place*) return 1 ;;
                # --output=<file> writes these subcommands' output.
                git:--output*) return 1 ;;
                rg:--pre*) return 1 ;;
            esac
        fi
        k=$((k + 1))
    done
    [ "$s" -lt 0 ] || _tok_ro_segment || return 1
    return 0
}

# _tok_ro_segment — the end of one segment, in _tok_readonly_ok's scope: its
# command word, if any, is an allowlisted read; git's first argument (`sub`,
# prefixed x) is a read-only subcommand; sed runs only inert scripts.
_tok_ro_segment() {
    [ "$fk" -ge 0 ] || return 0
    case "$first" in
        cat|head|tail|grep|diff|wc|jq|rg|less|sed) ;;
        ls) [ "$_RO_LS" = 1 ] || return 1 ;;
        git)
            case "$sub" in xdiff|xshow|xlog|xstatus|xblame) ;; *) return 1 ;; esac
            ;;
        *) return 1 ;;
    esac
    if [ "$first" = sed ]; then st_sed_args "$fk" 0 || return 1; fi
    return 0
}

# _tok_exported NAME — NAME is in this hook's environment (what `printenv
# NAME` answered), read from one `compgen -e` listing taken on first use
# rather than a fork per assignment (J1242).
_TOK_ENV=''
_tok_exported() {
    [ -n "$_TOK_ENV" ] || _TOK_ENV=$'\n'$(compgen -e)$'\n'
    case "$_TOK_ENV" in *$'\n'"$1"$'\n'*) return 0 ;; esac
    return 1
}

# mentions_dot_claude_dir_dest CMD_LC — the command names a `.claude`
# directory as a path component, independent of whether it also spells out
# settings.json — rule 2 catches `cp x .claude/` / `cp -t .claude/ x`,
# where the destination basename is never "settings.json" in the text.
mentions_dot_claude_dir_dest() {
    local c out
    # A `.claude/worktrees/…` mention is a CONTAINER path, not a destination
    # (HIMMEL-3499/3555 panel round on #1210): every linked worktree lives at
    # <root>/.claude/worktrees/<name>, so `git -C <that-path> checkout …` or
    # `tar -C <that-path>/vendor -x …` names `.claude` only because that is
    # where worktrees live, not because the command targets the `.claude`
    # directory itself. Strip it before matching so an ordinary cross-
    # worktree reference never counts. Never strips a mention of the
    # worktree's OWN nested `.claude` (`…/worktrees/<wt>/.claude/settings.json`
    # keeps a SECOND, un-stripped `.claude` after the container segment), and
    # never touches rule 1 (`settings.json` is a distinct substring).
    #
    # Never stripped when a real traversal `..` (has_traversal_dots) appears
    # ANYWHERE in the text (HIMMEL-3499, third panel round on #1210):
    # `cp -r x/. …/worktrees/..` (or a deeper `worktrees/wt/../../`) climbs
    # back OUT of the worktrees container into `.claude` itself — the SAME
    # "any traversal `..` voids the strip" rule mentions_primary_or_home()
    # already applies to its own-root blanking, for the identical reason
    # (this hook does not resolve `..`, so it cannot tell how far a climb
    # reaches; only refusing to strip at all keeps the mention visible to
    # the live-check `..` rule below). A `<sha>..<sha>` git range (hex on
    # both sides of the `..`) is not a traversal and never voids the strip
    # (HIMMEL-3675 — this was the false-DENY on `impacted-suites.sh --check
    # <base>..<head>` run from a `.claude/worktrees/<name>` worktree).
    if has_traversal_dots "$1"; then
        c="$1"
    else
        c=${1//.claude\/worktrees/CLAUDE_WORKTREES_PATH}
    fi
    # No LEADING boundary requirement (HIMMEL-3499/3555 panel round on
    # #1210): a short flag glued directly to its argument (`-C.claude`,
    # `-d.claude`, `-t.claude`) puts an alnum character immediately before
    # the dot, which the old `(^|[^a-z0-9_])` leading class rejected — GNU
    # tar/unzip/cp all accept the glued form, so this was a real bypass, not
    # just a `cp -t.claude` residual (the same regex predates HIMMEL-3499).
    # The trailing boundary is the complement of a path-name character
    # (HIMMEL-3564): an enumerated class missed `)` and a backtick, so
    # `x=$(tar -xf a.tar -C ~/.claude)` never counted as naming `.claude`.
    # It still accepts a quote (`cp -r x/. ".claude"`), and still rejects a
    # longer name (`.claude.json`, `.claude-x`).
    # Accepted over-match: a real filename ending in `…x.claude` now matches
    # too — fail-closed, matching the project's stated preference.
    out=$(printf '%s' "$c" | grep -E '\.claude([^a-z0-9_.-]|$)') || true
    [ -n "$out" ]
}

# _dc_can_be_claude COMPONENT — 0 when one path component that carries a glob,
# brace, bracket or `$` can expand to `.claude` (HIMMEL-4156). A brace group
# with a comma becomes an extglob alternation, a sequence (`{a..z}`) any text,
# and a group with neither, or an unclosed one, stays literal text as bash
# leaves it; groups nest. A `$name`/`${…}` is any text. With _DC_XONLY=1 (a
# word whose globs are all quoted) only a `$` expands and the glob, brace and
# bracket characters are literal. The result is matched against `.claude`,
# ignoring case. A component without such a character is literal text and is
# left to the callers' own matching.
_dc_can_be_claude() {
    local c=$1 i=0 n=${#1} ch pat='' depth=0 r eg=0 nc=0 gs xo=${_DC_XONLY:-0}
    local -a gsa=() cma=()
    case "$xo:$c" in 1:*'$'*|0:*'*'*|0:*'?'*|0:*'['*|0:*'{'*|0:*'$'*) ;; *) return 1 ;; esac
    while [ "$i" -lt "$n" ]; do
        ch=${c:i:1}
        i=$((i + 1))
        if [ "$xo" = 1 ]; then
            case "$ch" in
                '{'|'}'|','|'*'|'?'|'['|']') pat="$pat\\$ch"; continue ;;
            esac
        fi
        case "$ch" in
            '{')
                gsa[depth]=${#pat} cma[depth]=0
                depth=$((depth + 1))
                pat="$pat@("
                ;;
            '}')
                if [ "$depth" -gt 0 ]; then
                    depth=$((depth - 1))
                    gs=${gsa[depth]}
                    if [ "${cma[depth]}" = 1 ]; then
                        pat="$pat)"
                    else
                        case "${pat:gs+2}" in
                            *..*) pat="${pat:0:gs}*" ;;
                            *) pat="${pat:0:gs}{${pat:gs+2}}" ;;
                        esac
                    fi
                else
                    pat="$pat}"
                fi
                ;;
            ',')
                if [ "$depth" -gt 0 ]; then
                    pat="$pat|" cma[depth - 1]=1
                else
                    pat="$pat,"
                fi
                ;;
            '$')
                case "${c:i:1}" in
                    '{')
                        while [ "$i" -lt "$n" ] && [ "${c:i:1}" != '}' ]; do i=$((i + 1)); done
                        i=$((i + 1))
                        ;;
                    [A-Za-z_])
                        while [ "$i" -lt "$n" ]; do
                            case "${c:i:1}" in [A-Za-z0-9_]) i=$((i + 1)) ;; *) break ;; esac
                        done
                        ;;
                    '') pat="$pat\$"; continue ;;
                    *) i=$((i + 1)) ;;
                esac
                pat="$pat*"
                ;;
            *) pat="$pat$ch" ;;
        esac
    done
    # an unclosed brace group is literal text, its commas included
    if [ "$depth" -gt 0 ]; then
        gs=${gsa[0]}
        r=${pat:gs}
        r=${r//'@('/'{'}
        pat="${pat:0:gs}${r//'|'/,}"
    fi
    shopt -q extglob && eg=1
    shopt -q nocasematch && nc=1
    shopt -s extglob nocasematch
    r=1
    # shellcheck disable=SC2053 # $pat is the pattern, on purpose
    [[ .claude == $pat ]] && r=0
    [ "$eg" = 1 ] || shopt -u extglob
    [ "$nc" = 1 ] || shopt -u nocasematch
    return "$r"
}

# _dc_name_fold TEXT — _DCF is TEXT with every path component that can expand
# to `.claude` (_dc_can_be_claude) written as the literal `.claude`, so every
# rule below judges `~/.c?aude`, `~/.cl*/`, `~/.c[l]aude` and `~/.cl{a,}ude`
# as it judges `~/.claude` (HIMMEL-4156: they planted a home settings file
# from a nested-worktree cwd, where only a literal home `.claude` is live). A
# component starts after a `/`, a space, `=`, `:`, a shell operator or a
# leading short option (`-t.c?aude`), and begins with `.` or `{`: a glob that
# begins with `*`, `?` or `[` never matches a dot-name (bash and zsh both need
# the leading `.` spelled), so `cp src/* d/` is left alone.
_dc_name_fold() {
    local t=$1 out='' m c pw
    # shellcheck disable=SC2016 # literal backtick in a regex bracket, not expansion
    local re='(^-[A-Za-z0-9]*|[[:space:]]-[A-Za-z0-9]*|^|[/[:space:]=:<>|;&(`])([.{][^/[:space:];&|<>()`]*)'
    local pre='[.{][^/[:space:]]*[][*?{}$]'
    _DCF=$1
    [[ $t =~ $pre ]] || return 0
    while [[ $t =~ $re ]]; do
        m=${BASH_REMATCH[0]}
        c=${BASH_REMATCH[2]}
        out=$out${t%%"$m"*}${BASH_REMATCH[1]}
        t=${t#*"$m"}
        # under a plain relative directory (`handovers/.*/`) a component is
        # never the home or primary `.claude`; a `/`, `~`, `$` or `.` root
        # or a `..` climb can be
        pw=x
        if [ "${BASH_REMATCH[1]}" = / ]; then
            pw=${out##*[[:space:]=:<>|;&(\`]}
            case "$pw" in [/~\$.]*|*../*) pw=x ;; esac
        fi
        [ "$pw" = x ] && _dc_can_be_claude "$c" && c=.claude
        out=$out$c
        [ -n "$m" ] || break
    done
    _DCF=$out$t
}

# _verb_segment TEXT VERB_GREP_PATTERN — the single shell "segment" of TEXT
# containing a match for VERB_GREP_PATTERN, split on `;`, `&` (covers `&&`
# too — each `&` is its own split point), `|` and `#` (HIMMEL-3499, third
# panel round on #1210): a mode-check that scanned the WHOLE command let a
# chained or commented trailing token spoof it via a coincidental
# ` -t`/` -c`/` -l`/` -v` elsewhere in the text — `tar -xzf a.tgz -C
# ~/.claude; ls -t` false-ALLOWED because `ls -t`'s `-t` read as tar's own
# list-mode flag. Falls back to the whole text if no segment matches (should
# not happen — the caller already matched the same pattern against the
# whole text), never to an empty result. Since HIMMEL-3564 this and
# _tar_verb_mode/_unzip_verb_mode serve PowerShell only: a Bash command goes
# through _tok_verb_write, which judges EVERY matching segment, not the first.
_verb_segment() {
    local seg
    seg=$(printf '%s' "$1" | tr ';&|#' '\n' | grep -E "$2" | head -1)
    [ -n "$seg" ] && printf '%s' "$seg" || printf '%s' "$1"
}

# _tar_verb_mode CMD_N — CMD_N is the case-preserved command text. Returns
# 0 (a candidate write) unless the tar/gtar/bsdtar segment (see
# _verb_segment above) names tar's CREATE (`-c`/`--create`) or LIST
# (`-t`/`--list`) mode, or an old-style clustered option (`tar cf …`,
# `tar tvf …`) whose first letter is `c`/`t` — none of those write into a
# destination directory (HIMMEL-3499/3555: `tar -czf out.tgz .claude` and
# `tar -tf a.tar .claude/` archive/list `.claude`'s CONTENTS, they do not
# write into it, and were false-denied).
#
# Checked on the CASE-PRESERVED text, not the lowercased CMD_LC
# has_write_verb_or_target_flag otherwise uses: tar's create flag is
# lowercase `-c`, distinct from the (uppercase) `-C` directory flag
# changes_directory() already recognizes. Case-folding first would conflate
# them — a command using only `-C` (extract-into-a-dir) would then read as
# `-c` (create) and be wrongly excluded, a bypass.
_tar_verb_mode() {
    local seg
    seg=$(_verb_segment "$1" '(^|[^a-zA-Z0-9_])(g?tar|bsdtar)([^a-zA-Z0-9_]|$)')
    case "$seg" in
        *' -c'*|*'--create'*|*' -t'*|*'--list'*) return 1 ;;
    esac
    case "$seg" in
        *' tar '[ct]*|*' gtar '[ct]*|*' bsdtar '[ct]*) return 1 ;;
        'tar '[ct]*|'gtar '[ct]*|'bsdtar '[ct]*) return 1 ;;
    esac
    return 0
}

# _unzip_verb_mode CMD_LC — 0 (a candidate write) unless the unzip segment
# (see _verb_segment above) names unzip's own LIST (`-l`), TEST (`-t`) or
# verbose-list (`-v`) mode AS ITS FIRST FLAG (HIMMEL-3499). The
# first-flag requirement is deliberate: `unzip -o a.zip -d ~/.claude -x -v`
# is a genuine extraction (destination `-d`, overwrite `-o`) that merely
# also passes `-v` — a bare "anywhere in the segment" check read that
# trailing `-v` as unzip's list mode and false-ALLOWED it. `unzip -l
# a.zip .claude/*` (mode flag first) still excludes correctly. Unlike tar,
# none of unzip's own flag letters collide across case, so CMD_LC is fine.
_unzip_verb_mode() {
    local seg
    seg=$(_verb_segment "$1" '(^|[^a-z0-9_])unzip([^a-z0-9_]|$)')
    case "$seg" in
        *' unzip '-[ltv]*|unzip' '-[ltv]*) return 1 ;;
    esac
    return 0
}

# has_write_verb_or_target_flag CMD_LC CMD_N — a copy/move/link/extract/
# checkout-shaped verb, or a `-t`/`--target-directory` flag (rule 2's verb
# list). CMD_N is the case-preserved text, needed only for tar's own
# create/list-mode check above.
#
# The word boundary on both sides is the COMPLEMENT of a word character, not
# a list of shell metacharacters (HIMMEL-3468): an enumerated class missed
# `(`, `\`, `"` and `'` in turn, and whatever it omits next is the next
# bypass. Any non-word character before the verb now counts, at the cost of
# over-matching a word that merely ends a token (`-cp`, `x.tee`) — which only
# denies when a `.claude` destination is named too, i.e. fail-closed.
#
# tar/gtar/bsdtar/unzip/checkout/restore (HIMMEL-3499): the same
# blunt verb-name list, widened to the extract and checkout tools that
# clobber a directory without naming settings.json in the text —
# `git checkout <ref> -- .claude`, `tar -x -C .claude`, `unzip -d .claude`.
# This is the SAME shape as the existing cp/mv/install/rsync/ln/dd/tee list
# (an allowlist of known destructive verb spellings), not the
# metacharacter-boundary enumeration HIMMEL-3468 ruled against — so it stays
# in scope for the "no more parsing" decision. gtar/bsdtar are the two other
# common tar spellings; before this they denied only by accident, via a
# `.tar`-suffixed archive-filename argument matching the bare `tar` word.
# tar's own directory flag happens to be spelled `-C`, which
# changes_directory() already treats as a directory-move signal for
# `git -C`/`env -C`/`make -C`; that rule cannot tell tar's self-targeting
# `-C .claude` apart from an unrelated cwd shift, so it also denies a
# worktree's own `tar -x -C .claude` — an accepted, documented false deny
# (test 136), the same shape as the cd/pushd precedent above.
#
# checkout/restore additionally require a `git` word in the SAME segment
# (see _verb_segment above; HIMMEL-3499): unlike cp/mv/tar/
# unzip, these are common English words that show up as ordinary
# filenames/arguments (`~/.claude/commands/checkout.md`, `grep -rn restore
# ~/.claude/skills`), and a bare-word match false-denied a plain read of
# one. Scoped to the segment, not just loose whole-text co-occurrence — `cat
# ~/.claude/checkout.md && git status` has "git" only in a LATER, unrelated
# segment and must stay allowed. `git -C <dir> checkout` and
# `git --work-tree=. checkout` both still count (same segment); the
# `.claude/worktrees/` path-stripping above is what excludes an ordinary
# cross-worktree `-C` reference, not this check.
has_write_verb_or_target_flag() {
    local c="$1" n="$2" out seg
    out=$(printf '%s' "$c" | grep -E '(^|[^a-z0-9_])(cp|mv|install|rsync|dd|tee|truncate)([^a-z0-9_]|$)') || true
    [ -n "$out" ] && return 0

    # ln is judged per word on Bash (_tok_ln_write, HIMMEL-3961), so another
    # program's `-ln` flag cluster is not read as the link verb.
    local re_ln='(^|[^a-z0-9_])ln([^a-z0-9_]|$)'
    out=$(printf '%s' "$c" | grep -E "$re_ln") || true
    if [ -n "$out" ]; then
        [ "$tool_name" = Bash ] || return 0
        _tok_ln_write "$re_ln" && return 0
    fi

    # A Bash command is judged per segment from its tokens (_tok_verb_write,
    # HIMMEL-3564): a Bash command the tokenizer could not vouch for (TOK=0)
    # is a candidate write, never sent back to the text scan it replaces.
    # PowerShell keeps the _verb_segment text scan.
    local re_tar='(^|[^a-z0-9_])(g?tar|bsdtar)([^a-z0-9_]|$)'
    local re_unzip='(^|[^a-z0-9_])unzip([^a-z0-9_]|$)'
    local re_co='(^|[^a-z0-9_])(checkout|restore)([^a-z0-9_]|$)'
    out=$(printf '%s' "$c" | grep -E "$re_tar") || true
    if [ -n "$out" ]; then
        if [ "$tool_name" = Bash ]; then
            _tok_verb_write tar "$re_tar" && return 0
        elif _tar_verb_mode "$n"; then
            return 0
        fi
    fi

    out=$(printf '%s' "$c" | grep -E "$re_unzip") || true
    if [ -n "$out" ]; then
        if [ "$tool_name" = Bash ]; then
            _tok_verb_write unzip "$re_unzip" && return 0
        elif _unzip_verb_mode "$c"; then
            return 0
        fi
    fi

    out=$(printf '%s' "$c" | grep -E "$re_co") || true
    if [ -n "$out" ] && [ "$tool_name" = Bash ]; then
        _tok_verb_write checkout "$re_co" && return 0
    elif [ -n "$out" ]; then
        seg=$(_verb_segment "$c" "$re_co")
        out=$(printf '%s' "$seg" | grep -E '(^|[^a-z0-9_])git([^a-z0-9_]|$)') || true
        [ -n "$out" ] && return 0
    fi

    # A command word no verb list can read (HIMMEL-4119), in a segment that
    # names a .claude directory, is a write: fail closed.
    if [ "$tool_name" = Bash ]; then
        _tok_unjudged_verb "$c" "$n" && return 0
    fi

    return 1
}

# lex_resolve BASE OP — join OP onto BASE (OP itself, if already absolute)
# and collapse `.`/`..` components as plain text, the way a shell would
# resolve the path, with NO filesystem access (HIMMEL-3686 item 1): a
# relative destination operand is judged by where it lexically lands, not
# by whether it merely contains `..`, so `../other` (stays under
# `worktrees/`) and `../..` (climbs out of it) resolve to different places.
lex_resolve() {
    local base="$1" op="$2" joined part n=0
    local -a out
    case "$op" in
        /*|[A-Za-z]:/*|[A-Za-z]:\\*) joined="$op" ;;
        *) joined="$base/$op" ;;
    esac
    local IFS=/
    # HIMMEL-3686 round-5 codex-3: unquoted word-splitting on $joined also
    # triggers pathname expansion on any segment containing a glob char,
    # against the HOOK PROCESS's own cwd (unrelated to the path being
    # resolved) — `set -f` keeps this loop the filesystem-blind textual
    # split the function promises.
    set -f
    for part in $joined; do
        case "$part" in
            ''|'.') : ;;
            '..')
                if [ "$n" -gt 0 ]; then
                    n=$((n - 1))
                    unset "out[$n]"
                fi
                ;;
            *) out[n]=$part; n=$((n + 1)) ;;
        esac
    done
    set +f
    local i=0 res=''
    while [ "$i" -lt "$n" ]; do
        res="$res/${out[$i]}"
        i=$((i + 1))
    done
    [ -n "$res" ] && printf '%s\n' "$res" || printf '/\n'
}

# has_unquoted_brace_group TEXT — a single, non-nested `{…,…}` brace pair in
# the (already quote/escape-stripped, HIMMEL-3468) command text (HIMMEL-3686
# item 2): `.{,.}/.{,.}/settings.json` hides an arbitrary `../` climb from
# every OTHER check in this file, none of which expand braces. Never
# expanded here either — a match just denies outright, the same fail-closed
# shape as an unresolvable canon().
has_unquoted_brace_group() {
    [[ "$1" =~ \{[^{}]*,[^{}]*\} ]]
}
# has_brace_climb_word WORD — HIMMEL-3700 (judge r1, I3 sibling): ONE word that
# is a path (has a `/`), holds a `{…,…}` group, and could expand to a `..`
# component — a literal `..`, a `.` inside a group alternative, or a `.` beside
# a group with an EMPTY alternative (`.{x,}.` -> `..`). Judged per word, never
# on the whole text, and whatever the leaf spells (`sett{ings,x}.json` names
# no settings file the text search could find).
has_brace_climb_word() {
    local w="$1"
    case "$w" in */*) : ;; *) return 1 ;; esac
    [[ "$w" =~ \{[^{}]*,[^{}]*\} ]] || return 1
    case "$w" in *..*) return 0 ;; esac
    [[ "$w" =~ \{[^{}]*\.[^{}]*\} ]] && return 0
    case "$w" in *.*) [[ "$w" =~ \{,|,\}|,, ]] && return 0 ;; esac
    return 1
}
# ponytail: matching against already quote-stripped text means a genuinely
# quoted brace-containing filename (e.g. a file literally named `.{,.}`,
# passed as `'.{,.}'`) is denied the same as a real unquoted, expandable
# `{…,…}` — ST_Q[] only tracks "any byte of this word was quoted", and bash
# still brace-expands an unquoted `{...}` segment even when another part of
# the SAME word is quoted, so that per-word flag cannot safely exempt this
# check. Accepted false-deny, same fail-closed direction as this file's other
# documented residuals. Upgrade path: HIMMEL-3696 (per-character quote
# tracking in the tokenizer).

# changes_directory CMD_LC CMD_N — a cd/pushd/popd word anywhere in the
# command, with the same complement-of-a-word-character boundary as the verb
# list, or a `-C <dir>` / `--chdir` word (`git -C`, `make -C`, `env -C`),
# which moves the target the same way. `-C` is matched on the case-preserved
# text CMD_N, so a lowercase `-c` (`bash -c`) is not one.
#
# tar/unzip naming a `.claude` destination (`tar -C .claude`, `tar --directory
# .claude`, `unzip -d .claude`) no longer need THIS function to be caught at
# all (HIMMEL-3499): has_write_verb_or_target_flag() now matches the bare
# `tar`/`unzip` word regardless of which directory flag it uses, so rule 2
# (mentions_dot_claude_dir_dest + has_write_verb_or_target_flag) denies them
# directly. tar's `-C` spelling happens to ALSO match this function's own
# `-C` case, which additionally voids the worktree-relative exemption for a
# worktree's own `tar -C .claude` — an accepted, documented false deny (test
# 136) — but that is a side effect of the shared `-C` spelling, not something
# this function needed to grow to close the residual.
# ponytail: a relative `find … -exec` naming `.claude` as its target is still
# not matched by either mechanism — the remaining documented residual.
# ponytail: a cd/pushd/popd/-C matched here relocates the real target
# directory, but neither _check_write_operand()'s `wabs` nor check_target()'s
# own relative-join (both use the fixed PreToolUse $cwd) adjust for it — so
# `cd sub && cp y link`, where `sub/link` is a pre-existing symlink into the
# primary's live settings.json, resolves `link` against the wrong base and
# silently evades items 1 and 3 (HIMMEL-3686 round-4 codex-2). Deferred
# rather than blunt-denied: the write-verb operand scan already inspects
# every word including the verb itself (round-2 codex-1's accepted ruling),
# so a blind "deny any relative operand when this function matches" would
# deny virtually any write-verb command containing a cd from a nested
# worktree, unrelated to .claude — a materially bigger blast radius than
# this function's existing HIMMEL-3468 role, where it only ever fires as an
# additional forcing factor on a command ALREADY flagged by another signal.
# Upgrade path: HIMMEL-3694 (track the real post-cd cwd per command segment
# via the tokenizer's own ST_S/ST_SEP arrays, falling back to deny only when
# a cd target isn't a simple literal).
changes_directory() {
    local out
    out=$(printf '%s' "$1" | grep -E '(^|[^a-z0-9_])(cd|pushd|popd)([^a-z0-9_]|$)') || true
    [ -n "$out" ] && return 0
    out=$(printf '%s' "$2" | grep -E '(^|[^A-Za-z0-9_-])(-C|--chdir)([^A-Za-z0-9_-]|$)') || true
    [ -n "$out" ]
}

# _exp_home W — sets _EH to W with a leading $HOME, ${HOME} or ~ replaced by
# $HOME's value (text only; the hook never sees the shell's expansion).
_EH=''
_exp_home() {
    # shellcheck disable=SC2088,SC2016 # `~/` and `$HOME` are matched as the literal text typed
    case "$1" in
        '$HOME'|'${HOME}'|'~') _EH=${HOME:-} ;;
        '$HOME/'*) _EH=${HOME:-}/${1#'$HOME/'} ;;
        '${HOME}/'*) _EH=${HOME:-}/${1#'${HOME}/'} ;;
        '~/'*) _EH=${HOME:-}/${1#'~/'} ;;
        *) _EH=$1 ;;
    esac
}

# _settings_leaf_candidates LEAF GLOB — sets _SLC to the settings leaf names
# (settings.json, settings.local.json) LEAF could spell when it is not
# literally one of them (HIMMEL-3938), empty when it cannot. Two shapes:
#   alias  a Windows spelling of the same file, taken through a symlinked
#          .claude: a trailing dot or space (`settings.json.`), an NTFS
#          stream suffix (`settings.json::$DATA`, everything from the first
#          `:`), an 8.3 short name (`SETTIN~1.JSO`; either file, so both).
#   glob   (GLOB=1, the word carried an unquoted glob) a pattern that matches
#          a settings name. A `{…}` group is read as `*` (a superset of its
#          alternatives), so `sett{ings,x}.json` is `sett*.json`: deny-lean,
#          no brace expansion (#1494/#1501 style). Case-insensitive.
# Judged on the leaf alone; the caller resolves its directory.
_SLC=''
_settings_leaf_candidates() {
    local leaf="$1" glob="$2" a pat pre rest nc=0 n
    _SLC=''
    case "$leaf" in
        *[*?[]*|*'{'*|*'~'*|*:*|*.|*' ') : ;;
        *) return 0 ;;
    esac
    a=${leaf%%:*}
    while :; do
        case "$a" in *.|*' ') a=${a%?} ;; *) break ;; esac
    done
    shopt -q nocasematch && nc=1
    shopt -s nocasematch
    if [ "$a" != "$leaf" ]; then
        case "$a" in
            settings.json) _SLC='settings.json' ;;
            settings.local.json) _SLC='settings.local.json' ;;
            settin~[0-9]*.jso) _SLC='settings.json settings.local.json' ;;
        esac
    elif [[ "$leaf" == settin~[0-9]*.jso ]]; then
        _SLC='settings.json settings.local.json'
    fi
    if [ "$glob" = 1 ]; then
        pat=$leaf
        while :; do
            case "$pat" in *'{'*) : ;; *) break ;; esac
            pre=${pat%%'{'*}
            rest=${pat#*'{'}
            case "$rest" in *'}'*) pat="$pre*${rest#*'}'}" ;; *) pat="$pre*$rest" ;; esac
        done
        pat=${pat//\}/*}
        # A leaf of `*` only (`.claude/*`) is the directory glob the older
        # checks already judge (HIMMEL-3938: it false-denied
        # `unzip -l a.zip .claude/*`, test 145). Any other wildcard leaf
        # (`????????.????`) can spell a settings name and is matched below.
        case "$pat" in *[!*]*) : ;; *) pat='' ;; esac
        case "$pat" in
            *[*?[]*)
                for n in settings.json settings.local.json; do
                    # shellcheck disable=SC2053 # $pat is the glob, on purpose
                    if [[ "$n" == $pat ]]; then
                        case " $_SLC " in *" $n "*) : ;; *) _SLC="${_SLC:+$_SLC }$n" ;; esac
                    fi
                done
                ;;
        esac
    fi
    [ "$nc" = 1 ] || shopt -u nocasematch
    return 0
}

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)

cwd=$(printf '%s' "$input" | jq -r '.tool_input.cwd // .cwd // empty' 2>/dev/null || true)
[ -n "$cwd" ] || cwd="$PWD"

# nested_wt_primary — set only when $cwd is itself inside a linked
# worktree's own container path (<primary>/.claude/worktrees/<name>/…);
# then it is that <primary> root, used below (HIMMEL-3686 item 1/2) to spot
# a relative destination that climbs back OUT of worktrees/ into the
# primary's own .claude — text-only, no filesystem access.
nested_wt_primary=""
case "$cwd" in
    */.claude/worktrees/*) nested_wt_primary=${cwd%%/.claude/worktrees/*} ;;
esac

if [ "$tool_name" = "Bash" ] || [ "$tool_name" = "PowerShell" ]; then
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    cmd_n=$cmd
    # ST_LW holds the lowercased words: the lowercased text tokenizes to the
    # same words and segments (case never changes how bash splits), so a
    # second pass over it costs no fork, where a `tr` per word did (J1242).
    if [ "$tool_name" = Bash ]; then
        st_lower "$cmd"
        if st_tokenize "$ST_LOWER"; then
            ST_LW=("${ST_W[@]}") lw_n=$ST_N lw_nseg=$ST_NSEG
            if st_tokenize "$cmd" && [ "$ST_HEREDOC" = 0 ] && [ "$ST_ANSIC" = 0 ] \
                && [ "$ST_N" = "$lw_n" ] && [ "$ST_NSEG" = "$lw_nseg" ]; then
                TOK=1
            fi
        fi
    fi
    # The shell drops quotes and escapes inside a word (`c\p`, `c""p` and
    # `settings.js\on` all name what they spell without them), so every
    # match below runs on the text with those characters removed
    # (HIMMEL-3468). Removing characters never removes a chaining or
    # redirection metacharacter, so the read-only allowlist only gets
    # stricter. PowerShell's escape is the backtick, and there `\` is a path
    # separator: fold it to `/` to match the forward-slash roots (codex-3).
    # ponytail: only the separator is folded — a POSIX-mount spelling
    # (`/c/Users/...`) of a drive-letter root is still not matched.
    # A line continuation (escape + newline) vanishes entirely, newline
    # included, so it is removed as a pair first; a bare newline stays, since
    # it separates commands.
    if [ "$tool_name" = "PowerShell" ]; then
        cmd_n=${cmd_n//$'`\r\n'/}
        cmd_n=${cmd_n//$'`\n'/}
        cmd_n=$(printf '%s' "$cmd_n" | tr "\\\\" '/' | tr -d "\"'\`")
    else
        cmd_n=${cmd_n//$'\\\r\n'/}
        cmd_n=${cmd_n//$'\\\n'/}
        cmd_n=$(printf '%s' "$cmd_n" | tr -d "\"'\\\\")
    fi
    # `//` and `/./` name the same path as `/`, so they are collapsed before
    # any root is matched (`<home>//.claude`, `~/./.claude`).
    while :; do
        case "$cmd_n" in
            *//*) cmd_n=${cmd_n//\/\//\/} ;;
            */./*) cmd_n=${cmd_n//\/.\//\/} ;;
            *) break ;;
        esac
    done
    # cmd_n keeps its case for the `-C` flag test; everything else matches
    # the lowercased text.
    cmd_lc=$(printf '%s' "$cmd_n" | tr '[:upper:]' '[:lower:]')
    # A glob/brace spelling of a `.claude` component counts as `.claude`
    # (HIMMEL-4156), in each lowercased word and in the text. A quoted glob
    # never expands, so when the tokenizer vouches only a word carrying an
    # unquoted glob or a live `$` folds, and the text folds only if one did.
    dc_fold=1
    if [ "$TOK" = 1 ]; then
        dc_fold=0 widx=0
        while [ "$widx" -lt "$ST_N" ]; do
            if [ "${ST_G[widx]}" = 1 ] || [ "${ST_X[widx]}" = 1 ]; then
                _DC_XONLY=1
                [ "${ST_G[widx]}" = 0 ] || _DC_XONLY=0
                _dc_name_fold "${ST_LW[widx]}"
                _DC_XONLY=0
                [ "$_DCF" = "${ST_LW[widx]}" ] || dc_fold=1
                ST_LW[widx]=$_DCF
            fi
            widx=$((widx + 1))
        done
    fi
    if [ "$dc_fold" = 1 ]; then
        _dc_name_fold "$cmd_lc"
        cmd_lc=$_DCF
    fi

    mentions_settings=0
    case "$cmd_lc" in
        *settings.json*|*settings.local.json*) mentions_settings=1 ;;
    esac

    # ANSI-C quoting (`$'\x2e\x2e'`, `settings$'\x2e'json`) spells any byte,
    # so the text above cannot say what it names. Not decoded: a `$'` beside
    # any `settings` or `claude` substring is treated as a live mention
    # (HIMMEL-3468). Judged on the raw text — the fold removed the quote —
    # with line continuations joined first, since bash joins `$\<NL>'` into
    # `$'` before it reads words.
    # ponytail: a word whose `settings`/`claude` letters are themselves
    # escaped (`$'\x73ettings.json'`) is not caught — same class as a path
    # built by `$(printf …)`, `printf %b` or `${var@E}`.
    ansi_c=0
    cmd_j=${cmd//$'\\\r\n'/}
    cmd_j=${cmd_j//$'\\\n'/}
    case "$cmd_j" in
        *"\$'"*)
            case "$cmd_lc" in
                *settings*|*claude*) ansi_c=1; mentions_settings=1 ;;
            esac
            ;;
    esac

    write_verb=0
    UJ_DEST=()
    has_write_verb_or_target_flag "$cmd_lc" "$cmd_n" && write_verb=1

    dir_dest=0
    if mentions_dot_claude_dir_dest "$cmd_lc" && [ "$write_verb" = 1 ]; then
        dir_dest=1
    fi

    # HIMMEL-3686 items 1 and 3, out-of-scope follow-ups from #1313/
    # HIMMEL-3675 (J1313O): neither needs mentions_settings/dir_dest, so
    # both are judged BEFORE the early exit below that they would otherwise
    # never reach. One pass over the command's words, gated on a write verb
    # being present at all.
    #
    # A quoted destination containing a space ("my path/s") must stay ONE
    # word — splitting cmd_n on whitespace (already quote-stripped) breaks
    # it into two words that name neither the real symlink nor the real
    # climb target (codex-1 panel finding on this ticket). When the
    # tokenizer vouched for this command (TOK=1, Bash only — HIMMEL-3546),
    # ST_W still holds cmd's own words, quotes/escapes removed but internal
    # spaces intact; use those instead. PowerShell and any Bash command the
    # tokenizer could not vouch for (heredoc, ANSI-C word) fall back to the
    # whitespace split, same documented ceiling every other TOK=0 fallback
    # in this file already accepts.
    _check_one_operand() {
        local w="$1" resolved wabs wparent wleaf result
        [ -n "$w" ] || return 0
        if [ -n "$nested_wt_primary" ]; then
            case "$w" in
                *..*)
                    resolved=$(lex_resolve "$cwd" "$w")
                    case "$resolved" in
                        "$nested_wt_primary/.claude/worktrees"|"$nested_wt_primary/.claude/worktrees/"*) : ;;
                        "$nested_wt_primary/.claude"|"$nested_wt_primary/.claude/"*) dirdest_climb=1 ;;
                    esac
                    ;;
            esac
        fi
        case "$w" in
            /*|[A-Za-z]:/*|[A-Za-z]:\\*) wabs="$w" ;;
            *) wabs="$cwd/$w" ;;
        esac
        # round-3 codex-1: `-e` follows symlinks and reports false for a
        # DANGLING one (a symlink whose target does not exist yet, e.g. one
        # pointing at a settings.json that has not been created) — `-L`
        # is a second stat-family builtin, no subprocess, and catches the
        # symlink itself so canon() still resolves where it points.
        if [ -e "$wabs" ] || [ -L "$wabs" ]; then
            result=$(check_claude_dir_target "$w")
            case "$result" in deny\ *) symlink_dest=1 ;; esac
            return
        fi
        # HIMMEL-178 round-2 codex-2: a destination that does not exist YET
        # can still be reached through a pre-existing symlinked PARENT
        # directory that escapes into the primary's .claude/. canon()'s
        # realpath -m / Python resolve(strict=False) already resolve a
        # missing final component safely (symlinks in every EXISTING
        # component are followed, the rest is appended lexically), so gate
        # on the PARENT existing too, not only the full path — but only when
        # the leaf is actually a live-settings filename: check_target's own
        # canon() (a realpath/python subprocess) is expensive, and a padded
        # command can carry thousands of non-existent operand words (J1242
        # timing tests), so calling it whenever a word's PARENT merely exists
        # (almost always true — the parent is often just the cwd) blew the
        # 5s timing budget. The leaf match uses a bash case pattern, not
        # `tr`, so this pre-filter itself never forks.
        wleaf="${wabs##*/}"
        case "$wleaf" in
            [sS][eE][tT][tT][iI][nN][gG][sS].[jJ][sS][oO][nN]) : ;;
            [sS][eE][tT][tT][iI][nN][gG][sS].[lL][oO][cC][aA][lL].[jJ][sS][oO][nN]) : ;;
            # ponytail: a brand-new, non-settings-named leaf reached through a
            # pre-existing symlinked PARENT that itself resolves into the
            # primary's live .claude/ never reaches check_target() here (the
            # leaf filter exists to keep the padded-command case cheap, per
            # the comment above) — an arbitrary new file, just not
            # settings.json, can still land in the live .claude/ this way.
            # Upgrade path: HIMMEL-3697 (a cheaper parent-existence check that
            # does not require narrowing to a settings-only leaf name).
            *) return ;;
        esac
        wparent="${wabs%/*}"
        [ -n "$wparent" ] || wparent="/"
        if [ -e "$wparent" ]; then
            result=$(check_claude_dir_target "$w")
            case "$result" in deny\ *) symlink_dest=1 ;; esac
        fi
    }
    # HIMMEL-3700 (J1329O I2, I4): a word can carry its path glued to an
    # option — dd's `of=<path>`, `--target-directory=<dir>`, or a short-option
    # cluster ending in t whose argument follows without a space (`-t<dir>`,
    # `-rt<dir>`) — so the operand is judged as spelled AND with that prefix
    # removed. A candidate that names no path is inert (it does not exist).
    # GNU getopt accepts any unambiguous prefix of a long option, so every
    # `--t…=<dir>` whose name is a prefix of `--target-directory` (`--target=`,
    # `--targ=`, `--t=`) is that same option.
    _check_write_operand() {
        local w="$1" cand='' lname longopt='--target-directory'
        _check_one_operand "$w"
        case "$w" in
            of=*) cand=${w#of=} ;;
            --t*=*)
                lname=${w%%=*}
                case "$longopt" in "$lname"*) cand=${w#*=} ;; esac
                ;;
            --*) : ;;
            -*t*) cand=${w#-*t} ;;
        esac
        [ -z "$cand" ] || _check_one_operand "$cand"
    }
    dirdest_climb=0
    symlink_dest=0
    # The operand scan runs for a write verb (every word) and, since
    # HIMMEL-3700 (I2), for any other writer's redirect target: `echo x > s`
    # writes through a symlink `s` exactly as `cp y s` does. A command the
    # tokenizer could not model has no redirect targets to pick out, so a `>`
    # anywhere in it scans every word (the same fallback a write verb gets).
    op_scan=0
    if [ "$write_verb" = 1 ]; then
        op_scan=1
    elif [ "$TOK" = 1 ]; then
        op_scan=2
    else
        case "$cmd_n" in *'>'*) op_scan=1 ;; esac
    fi
    if [ "$op_scan" != 0 ]; then
        if [ "$TOK" = 1 ]; then
            widx=0
            while [ "$widx" -lt "$ST_N" ]; do
                if [ "$op_scan" = 1 ]; then
                    _check_write_operand "${ST_W[widx]}"
                else
                    case "${ST_RO[widx]}" in *'>'*) _check_write_operand "${ST_W[widx]}" ;; esac
                fi
                widx=$((widx + 1))
            done
        else
            # CodeRabbit (HIMMEL-3686): unquoted `for w in $cmd_n` is subject
            # to pathname expansion against the HOOK PROCESS's own real cwd —
            # unrelated to the command's cwd — so a glob-containing operand
            # could reach _check_write_operand as an unrelated expanded path
            # instead of its literal text. `set -f` for exactly this loop
            # keeps the fallback textual, restoring the prior noglob state
            # after (mirrors lex_resolve's own set -f/set +f bracket).
            case $- in
                *f*) _had_noglob=1 ;;
                *) _had_noglob=0 ;;
            esac
            set -f
            for w in $cmd_n; do
                _check_write_operand "$w"
            done
            if [ "$_had_noglob" = 1 ]; then
                set -f
            else
                set +f
            fi
        fi
    fi
    # HIMMEL-4119: an unjudged command word (`$L`, `-ln`, `/bin/l?`) that is not
    # a write verb by its text alone still has its destination operands
    # climb- and symlink-checked, as a write verb's would be.
    if [ "$write_verb" = 0 ]; then
        for w in ${UJ_DEST[@]+"${UJ_DEST[@]}"}; do
            _check_write_operand "$w"
        done
    fi

    # HIMMEL-3938: three ways a live settings.json landed past the text and
    # operand checks above, one mechanism — every word is judged for the
    # settings files it could NAME and the directories it could land them in,
    # each resolved through _check_one_operand (so symlinks, $HOME and the
    # worktree exemption behave as for any other operand). A hit sets
    # variant_dest, which makes the command live (an operand resolving to a
    # live settings file is live by construction).
    #   IMP-1  a glob/brace/bracket leaf (`.claude/sett{ings,x}.json`, `sett*`,
    #          `settings.jso?`) and IMP-3 a Windows alias of the leaf
    #          (`settings.json.`, `::$DATA`, `SETTIN~1.JSO`):
    #          _settings_leaf_candidates names the settings leaves, whatever
    #          the verb (`sed -i` is no write verb).
    #   IMP-2  a recursive cp/rsync whose SOURCE directory holds
    #          .claude/settings*.json, into a directory whose `.claude` is
    #          live — the destination is one level ABOVE the live file, so no
    #          operand names it.
    # False-deny growth, accepted and named: any command word whose leaf glob
    # or brace group CAN match a settings name under a live .claude (`cp x
    # .claude/*`, `git add .claude/*.json`, `.claude/{a,b}.json`); a recursive
    # cp/rsync from a settings-bearing tree into a live parent. Read-only
    # allowlisted commands and `ls` are exempt below, as for a named settings.
    # A glob in the `.claude` component itself (`.cla*/settings.json`) is
    # folded to `.claude` before this runs (_dc_name_fold, HIMMEL-4156).
    # ponytail: a glob in another DIRECTORY component, a source
    # tree with the settings file deeper than `<src>/.claude/`, and a case-
    # insensitive `DLINK/` spelling (needs a case-insensitive filesystem to
    # model) are not judged; upgrade path: a path-expanding parse (HIMMEL-3934).
    variant_dest=0
    _check_variant() {
        local w="$1" glob="$2" dir leaf n sd
        case "$w" in
            */*) dir=${w%/*}; leaf=${w##*/}; [ -n "$dir" ] || dir=/ ;;
            *) dir=.; leaf=$w ;;
        esac
        _settings_leaf_candidates "$leaf" "$glob"
        [ -n "$_SLC" ] || return 0
        _dc_name_fold "$dir"
        _exp_home "$_DCF"
        dir=$_EH
        for n in $_SLC; do
            sd=$symlink_dest
            symlink_dest=0
            _check_one_operand "${dir%/}/$n"
            [ "$symlink_dest" = 0 ] || variant_dest=1
            symlink_dest=$sd
        done
    }
    # _tree_copy_seg V — judges the cp/rsync at OPW[V], reading only its own
    # segment (a later `; echo done` is not its destination). The destination
    # is the `-t`/`--target-directory` argument (cp only: rsync's -t is a
    # flag), or else the last operand; every other operand is a source.
    _tree_copy_seg() {
        local v=$1 i n=${#OPW[@]} w d='' base hit=0 tnext=0 sd
        local -a pos=()
        i=$((v + 1))
        while [ "$i" -lt "$n" ]; do
            w=${OPW[i]}
            if [ "$TOK" = 1 ]; then
                [ "${ST_S[i]}" = "${ST_S[v]}" ] || break
                if [ -n "${ST_RO[i]}" ]; then i=$((i + 1)); continue; fi
            else
                case "$w" in
                    ';'|'&'|'&&'|'|'|'||'|'|&') break ;;
                    *'>'*|*'<'*) i=$((i + 1)); continue ;;
                    *[\;\&\|]) w=${w%?}; i=$n ;;
                esac
            fi
            i=$((i + 1))
            if [ "$tnext" = 1 ]; then d=$w; tnext=0; continue; fi
            case "$w" in
                '') continue ;;
                --target-directory=*) d=${w#*=}; continue ;;
                --target-directory) tnext=1; continue ;;
                -*)
                    if [ "${OPW[v]##*/}" = cp ]; then
                        # the first t of a short cluster takes the rest (or the next word)
                        case "$w" in
                            -[!-]*) case "${w#-}" in *t*) if [ -z "${w#*t}" ]; then tnext=1; else d=${w#*t}; fi ;; esac ;;
                        esac
                    fi
                    continue
                    ;;
            esac
            pos[${#pos[@]}]=$w
        done
        if [ -z "$d" ] && [ "${#pos[@]}" -gt 0 ]; then
            d=${pos[${#pos[@]}-1]}
            unset "pos[${#pos[@]}-1]"
        fi
        [ -n "$d" ] || return 0
        for w in ${pos[@]+"${pos[@]}"}; do
            _exp_home "$w"
            case "$_EH" in /*|[A-Za-z]:/*|[A-Za-z]:\\*) base=$_EH ;; *) base="$cwd/$_EH" ;; esac
            if [ -d "$base" ] && { [ -e "$base/.claude/settings.json" ] || [ -e "$base/.claude/settings.local.json" ]; }; then
                hit=1
                break
            fi
        done
        [ "$hit" = 1 ] || return 0
        _exp_home "$d"
        sd=$symlink_dest
        symlink_dest=0
        _check_one_operand "${_EH%/}/.claude/settings.json"
        [ "$symlink_dest" = 0 ] || variant_dest=1
        symlink_dest=$sd
    }
    _check_tree_copy() {
        local i=0 n=${#OPW[@]}
        while [ "$i" -lt "$n" ]; do
            case "${OPW[i]##*/}" in cp|rsync) _tree_copy_seg "$i" ;; esac
            i=$((i + 1))
        done
    }
    OPW=()
    OPG=()
    if [ "$TOK" = 1 ]; then
        if [ "$ST_N" -gt 0 ]; then
            OPW=("${ST_W[@]}")
            OPG=("${ST_G[@]}")
        fi
    else
        case $- in *f*) _had_noglob=1 ;; *) _had_noglob=0 ;; esac
        set -f
        for w in $cmd_n; do OPW[${#OPW[@]}]=$w; OPG[${#OPG[@]}]=1; done
        if [ "$_had_noglob" = 1 ]; then set -f; else set +f; fi
    fi
    widx=0
    while [ "$widx" -lt "${#OPW[@]}" ]; do
        _check_variant "${OPW[widx]}" "${OPG[widx]}"
        widx=$((widx + 1))
    done
    [ "$write_verb" = 0 ] || _check_tree_copy

    # HIMMEL-3686 item 2: a brace group in the text is refused outright
    # whenever it could hide a climb that matters — the text already names
    # a live settings file (any writer: `sed -i`, `perl -pi` and others the
    # verb list does not know, HIMMEL-3700 I3), or, under a write verb, a
    # primary .claude dir-dest, or $cwd is itself a nested worktree a hidden
    # `../` could climb out of.
    brace_dir_dest=0
    if has_unquoted_brace_group "$cmd_n" \
        && { [ "$mentions_settings" = "1" ] \
            || { [ "$write_verb" = 1 ] && { [ "$dir_dest" = "1" ] || [ -n "$nested_wt_primary" ]; }; }; }; then
        brace_dir_dest=1
    fi
    # A writer that is not a recognised verb (sed -i, perl -pi, ...) from a
    # nested worktree: one word that is a path with a brace group that could
    # spell a `..` climb denies whatever its leaf spells (HIMMEL-3700, judge
    # r1). The whole-text search above cannot see a leaf like `sett{ings,x}.json`.
    if [ "$brace_dir_dest" = 0 ] && [ "$write_verb" = 0 ] && [ -n "$nested_wt_primary" ] \
        && has_unquoted_brace_group "$cmd_n"; then
        if [ "$TOK" = 1 ]; then
            widx=0
            while [ "$widx" -lt "$ST_N" ]; do
                if has_brace_climb_word "${ST_W[widx]}"; then brace_dir_dest=1; break; fi
                widx=$((widx + 1))
            done
        else
            # noglob for this loop only, as in the operand scan above
            case $- in *f*) _had_noglob=1 ;; *) _had_noglob=0 ;; esac
            set -f
            for w in $cmd_n; do
                if has_brace_climb_word "$w"; then brace_dir_dest=1; break; fi
            done
            if [ "$_had_noglob" = 1 ]; then set -f; else set +f; fi
        fi
    fi

    if [ "$mentions_settings" = "0" ] && [ "$dir_dest" = "0" ] && [ "$dirdest_climb" = "0" ] \
        && [ "$symlink_dest" = "0" ] && [ "$brace_dir_dest" = "0" ] && [ "$variant_dest" = "0" ]; then
        exit 0
    fi

    resolve_repo_context

    live=0
    if [ "$is_primary_cwd" = "1" ] || [ "$ansi_c" = "1" ] || [ "$dirdest_climb" = "1" ] \
        || [ "$symlink_dest" = "1" ] || [ "$brace_dir_dest" = "1" ] || [ "$variant_dest" = "1" ]; then
        live=1
    elif changes_directory "$cmd_lc" "$cmd_n"; then
        # The worktree-relative exemption is judged against the PreToolUse
        # cwd; a cd/pushd/popd (or a `-C <dir>`) in the same command moves the
        # real target (`cd ../../.. && echo x > .claude/settings.json` lands
        # on the primary), so the exemption no longer applies. Blunt on
        # purpose: a harmless cd is denied too (HIMMEL-3468, accepted false
        # deny).
        live=1
    else
        if has_traversal_dots "$cmd_lc"; then
            # A real traversal `..` climbs out of the worktree the exemption
            # covers — from `<primary>/.claude/worktrees/<wt>`,
            # `../../settings.json` IS the primary's file — whatever the verb.
            # The worktree's own copy never needs `..` to name it
            # (HIMMEL-3468). A `<sha>..<sha>` git range never counts
            # (HIMMEL-3675).
            live=1
        fi
        if [ "$live" = "0" ] && mentions_primary_or_home "$cmd_lc"; then
            live=1
        elif [ "$live" = "0" ] && [ -z "$primary_root_lc" ]; then
            # No repo upward from cwd (or it did not resolve): there is no
            # worktree to exempt, and a relative mention resolves to whatever
            # sits under cwd — `$HOME/.claude/settings.json` when cwd is
            # $HOME. Fail closed.
            live=1
        fi
    fi

    if [ "$live" = "0" ]; then
        exit 0
    fi

    # A command that only reached here through a glob/alias/tree-copy leaf
    # (variant_dest) may also be a plain `ls`, which names no file's content.
    [ "$mentions_settings" = "1" ] || _RO_LS=1
    if [ "$mentions_settings" = "1" ] || [ "$variant_dest" = "1" ]; then
        if [ "$TOK" = 1 ]; then
            _tok_readonly_ok && exit 0
        elif is_readonly_allowlisted "$cmd_lc"; then
            exit 0
        fi
    fi

    if [ "${EDIT_LIVE_SETTINGS_OK:-0}" = "1" ]; then
        exit 0
    fi

    if [ "$mentions_settings" = "0" ] && [ "$variant_dest" = "1" ]; then
        deny_message "a $tool_name command" "$cmd" "a word can spell a live settings.json/settings.local.json (a glob, brace or bracket leaf, a Windows alias such as a trailing dot, ::\$DATA or an 8.3 name, or a recursive cp/rsync of a tree carrying .claude/settings*.json into the directory above a live .claude)"
    elif [ "$mentions_settings" = "1" ]; then
        deny_message "a $tool_name command" "$cmd" "the command text names a live settings.json/settings.local.json (worktree-relative spellings of the worktree's OWN copy are exempt; this one resolves to the primary checkout or \$HOME)"
    else
        deny_message "a $tool_name command" "$cmd" "the command targets the primary checkout's .claude/ directory itself (cp/mv/install/rsync/ln/dd/tee/truncate/tar/gtar/bsdtar/unzip, git checkout/restore, or a -t/--target-directory destination)"
    fi
    exit 2
fi

# Edit/Write/MultiEdit/NotebookEdit arm. MultiEdit's exact tool_input schema
# is not documented (it does carry file_path in every observed shape, but
# read it defensively rather than assuming) — file_path/notebook_path/path
# cover every known and plausible field name; a target this can't find
# simply falls through to allow, same as an unresolvable target already did
# under the removed permission rules.
target=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // empty' 2>/dev/null || true)
[ -n "$target" ] || exit 0

result=$(check_target "$target")
case "$result" in
    deny\ *)
        if [ "${EDIT_LIVE_SETTINGS_OK:-0}" = "1" ]; then
            exit 0
        fi
        deny_message "$tool_name" "$target" "${result#deny }"
        exit 2
        ;;
    unknown)
        # Fail CLOSED — an unresolvable target would otherwise prefix-match
        # nothing and exit 0, re-opening the `worktrees/../foo.sh` traversal
        # bypass (mirrors block-edit-on-main.sh's canon-failure handling).
        echo "block-edit-live-settings: canonicalisation failed for '$target' — refusing to evaluate" >&2
        exit 2
        ;;
    *)
        exit 0
        ;;
esac
