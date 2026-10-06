# shellcheck shell=bash
# guard-unwrap.sh — re-scan the forms a must-run guard's text matcher cannot
# see (HIMMEL-4438). Sourced by block-read-secrets, block-git-stash,
# block-destructive-commands, block-tail-pipe-on-gates and require-quiet-run.
#
# Each of those hooks matches the command TEXT. The shell runs a different
# text whenever it removes quotes (`g'i't stash`), drops a wrapper
# (`env X=1 timeout 5 git stash`), joins a backslash-newline, or runs a string
# as a new command (`bash -c '…'`, `sh -ec`, `zsh -c` at any depth, `eval`,
# `env -S`). Teaching every matcher every spelling is the arms race this lib
# ends: guard_unwrap tokenizes the command once with the canonical
# shell-tokenize.sh, derives the text the shell would run, and feeds it back
# through the SAME hook as a fresh call. The hook's own scan of the original
# still runs, so a variant can only add a deny, never remove one.
#
# One child call per nesting level: the child's command is the rendered form
# (quotes removed, wrappers stripped) when there is one, else the `-c`/`eval`
# bodies joined by newlines. The child unwraps again, so depth N costs N runs.
# Past GU_MAX_DEPTH levels, or past GU_MAX_VARIANTS bodies in one command, the
# call DENIES: a form this lib will not read counts as a denied one.
#
# A command the tokenizer does not model (an unterminated quote, `;;`, more
# than 8 KiB) is retried with every `${…}` expansion replaced by a bare name,
# then with every heredoc body dropped. If it still fails, the call DENIES
# when its text (heredoc bodies dropped) shows a nested shell `-c`, an
# `eval`, or a quoted/escaped command word, and otherwise falls back to the
# hook's own scan alone.
#
# ponytail: a `$(…)` or backtick that splits a pipeline renders as `;`, so a
# variant loses the pipe across a substitution; a heredoc body is not
# rendered. Both stay covered by the hook's scan of the original text. Upgrade
# path: carry the pipe edge across substitution segments if a leak shows.
#
# Exports to the caller after guard_unwrap returns 0:
#   GU_CWD_UNKNOWN  1 when this command (cd, pushd, popd, env -C, sudo -D) or
#                   an enclosing one moved the cwd, so a glob in it does not
#                   expand against the hook's cwd (HIMMEL-4502)
#   GU_TOKENIZED       1 when the tokenizer read the command (ST_* hold it)
#   GU_SW[s]        the non-redirect word indices of segment s, space-joined
#   GU_CORE[s]      the position in GU_SW[s] of segment s's command word,
#                   after wrappers, assignments and keywords
#   GU_LOOKUP[s]    1 when segment s is `command -v/-V` (lookup only)

_gu_dir=${BASH_SOURCE[0]%/*}
[ "$_gu_dir" != "${BASH_SOURCE[0]}" ] || _gu_dir=.
# shellcheck source=shell-tokenize.sh
{ [ -r "$_gu_dir/shell-tokenize.sh" ] && . "$_gu_dir/shell-tokenize.sh"; } 2>/dev/null || return 1
declare -F st_tokenize >/dev/null || return 1

GU_MAX_DEPTH=8
GU_MAX_VARIANTS=32
GU_SHELLS=' bash sh zsh dash ksh mksh ash yash posh '

# _gu_render_word K — GU_RW is word K as shell text that tokenizes back to
# the same word: bare when its bytes are inert (glob and `$` bytes stay live
# when the word had them live), else single-quoted. GU_BARE=1 when bare.
# shellcheck disable=SC2016 # literal $ in the character classes
_gu_render_word() {
    local w=${ST_W[$1]} re_plain='^[A-Za-z0-9_./:@%+,=~^-]+$'
    local re_glob='^[][A-Za-z0-9_./:@%+,=~^*?{}!-]+$' re_var='^[A-Za-z0-9_./:@%+,=~^${}-]+$'
    GU_BARE=1
    if [[ $w =~ $re_plain ]]; then GU_RW=$w; return 0; fi
    if [ "${ST_G[$1]}" = 1 ] && [[ $w =~ $re_glob ]]; then GU_RW=$w; return 0; fi
    if [ "${ST_X[$1]}" = 1 ] && [[ $w =~ $re_var ]]; then GU_RW=$w; return 0; fi
    GU_BARE=0
    GU_RW="'${w//\'/\'\\\'\'}'"
}

# _gu_add TEXT — queue one body (a string the shell runs as a command).
_gu_add() {
    GU_V[${#GU_V[@]}]=$1
}

# _gu_value WRAP OPT VALUE — a wrapper option's value: a cwd change or an
# `env -S` command string.
_gu_value() {
    case "$1:$2" in
        env:C|env:--chdir|sudo:D|sudo:--chdir) GU_SHIFT=1 ;;
        env:S|env:--split-string) _gu_add "$3"; GU_VS[${#GU_VS[@]}]=$3 ;;
    esac
}

# _gu_short_vals WRAP — the short options of WRAP that take a value.
_gu_short_vals() {
    case "$1" in
        env) GU_SV=uCS ;;
        exec) GU_SV=a ;;
        nice) GU_SV=n ;;
        ionice) GU_SV=cnp ;;
        timeout) GU_SV=sk ;;
        time) GU_SV=fo ;;
        stdbuf) GU_SV=ioe ;;
        sudo) GU_SV=ughpCDrtUT ;;
        doas) GU_SV=uC ;;
        xargs) GU_SV=InLPsdEa ;;
        *) GU_SV='' ;;
    esac
}

# _gu_long_val WRAP OPT — 0 when long option OPT of WRAP takes a separate value.
_gu_long_val() {
    case "$1:$2" in
        env:--unset|env:--chdir|env:--split-string) return 0 ;;
        nice:--adjustment|ionice:--class|ionice:--classdata|ionice:--pid) return 0 ;;
        timeout:--signal|timeout:--kill-after|time:--format|time:--output) return 0 ;;
        stdbuf:--input|stdbuf:--output|stdbuf:--error) return 0 ;;
        sudo:--user|sudo:--group|sudo:--host|sudo:--prompt|sudo:--chdir) return 0 ;;
        sudo:--role|sudo:--type|sudo:--other-user|sudo:--close-from) return 0 ;;
        sudo:--command-timeout) return 0 ;;
        xargs:--arg-file|xargs:--max-args|xargs:--max-procs|xargs:--max-chars) return 0 ;;
        xargs:--delimiter|xargs:--eof|xargs:--max-lines) return 0 ;;
    esac
    return 1
}

# _gu_core S — find segment S's command word past assignments, keywords and
# wrappers with their options; set GU_CORE[S], GU_LOOKUP[S], GU_STRIP, and
# GU_XA[S] to the position of the first stripped `xargs`.
_gu_core() {
    local s=$1 n p=0 k w b wrap='' endopt=0 dur=0 val='' opt l c j
    local -a idx
    read -r -a idx <<<"${GU_SW[s]}"
    n=${#idx[@]}
    GU_LOOKUP[s]=0
    while [ "$p" -lt "$n" ]; do
        k=${idx[p]}
        w=${ST_W[k]}
        if [ -n "$val" ]; then
            _gu_value "$wrap" "$val" "$w"; val=''; p=$((p + 1)); continue
        fi
        if [ "${ST_A[k]}" = 1 ] && { [ -z "$wrap" ] || [ "$wrap" = env ]; }; then
            GU_STRIP=1; p=$((p + 1)); continue
        fi
        # env takes any NAME=VALUE word as an assignment, quoted or not.
        if [ "$wrap" = env ]; then
            case "$w" in
                [A-Za-z_]*=*) GU_STRIP=1; p=$((p + 1)); continue ;;
            esac
        fi
        if [ -n "$wrap" ] && [ "$endopt" = 0 ]; then
            case "$w" in
                --) endopt=1; p=$((p + 1)); continue ;;
                --*=*)
                    opt=${w%%=*}
                    _gu_value "$wrap" "$opt" "${w#*=}"
                    p=$((p + 1)); continue ;;
                --?*)
                    if _gu_long_val "$wrap" "$w"; then val=$w; fi
                    p=$((p + 1)); continue ;;
                -?*)
                    if [ "$wrap" = command ]; then
                        case "$w" in *[vV]*) GU_LOOKUP[s]=1; GU_CORE[s]=$n; return 0 ;; esac
                    fi
                    _gu_short_vals "$wrap"
                    l=${w#-}
                    j=0
                    while [ "$j" -lt "${#l}" ]; do
                        c=${l:j:1}
                        case "$GU_SV" in
                            *"$c"*)
                                if [ "$((j + 1))" -lt "${#l}" ]; then
                                    _gu_value "$wrap" "$c" "${l:j+1}"
                                else
                                    val=$c
                                fi
                                break ;;
                        esac
                        j=$((j + 1))
                    done
                    p=$((p + 1)); continue ;;
            esac
        fi
        if [ "$dur" = 1 ]; then dur=0; p=$((p + 1)); continue; fi
        b=${w##*/}
        case "$b" in
            env|command|builtin|exec|nohup|setsid|nice|ionice|timeout|time|stdbuf|sudo|doas|xargs)
                wrap=$b; endopt=0; dur=0
                [ "$b" != timeout ] || dur=1
                [ "$b" != xargs ] || [ -n "${GU_XA[s]:-}" ] || GU_XA[s]=$p
                GU_STRIP=1; p=$((p + 1)); continue ;;
            '!'|'{'|if|then|else|elif|while|until|do)
                wrap=''; endopt=0; dur=0
                GU_STRIP=1; p=$((p + 1)); continue ;;
            cd|pushd|popd) GU_SHIFT=1 ;;
        esac
        break
    done
    GU_CORE[s]=$p
}

# _gu_shell_bodies S — queue the `-c` body of every shell word in segment S,
# at any position (`find -exec sh -c`, `xargs bash -c`). In a short option
# bundle, each o/O takes the next word as its value before the body
# (HIMMEL-4506: `bash -co pipefail 'cmd'`).
_gu_shell_bodies() {
    local s=$1 n j q w b found nval l
    local -a idx
    read -r -a idx <<<"${GU_SW[s]}"
    n=${#idx[@]}
    j=0
    while [ "$j" -lt "$n" ]; do
        b=${ST_W[idx[j]]##*/}
        b=${b%.exe}
        case "$GU_SHELLS" in
            *" $b "*) ;;
            *) j=$((j + 1)); continue ;;
        esac
        found=0
        q=$((j + 1))
        while [ "$q" -lt "$n" ]; do
            w=${ST_W[idx[q]]}
            case "$w" in
                --) q=$((q + 1)); break ;;
                --rcfile|--init-file) q=$((q + 2)) ;;
                --*) q=$((q + 1)) ;;
                [-+]?*)
                    l=${w:1}
                    case "$l" in *c*) found=1 ;; esac
                    nval=${l//[!oO]/}
                    q=$((q + 1 + ${#nval}))
                    ;;
                *) break ;;
            esac
        done
        if [ "$found" = 1 ] && [ "$q" -lt "$n" ]; then
            _gu_add "${ST_W[idx[q]]}"
        fi
        j=$((j + 1))
    done
}

# _gu_fallback CMD — the tokenizer could not read CMD: 0 (deny) when its raw
# text shows a shape this lib exists to unwrap.
_gu_fallback() {
    local re_nest='(^|[^A-Za-z0-9_.-])(ba|z|da|k|mk|a|ya|po)?sh(\.exe)?["'"'"']?[[:space:]]+([-+][A-Za-z]*[[:space:]]+)*["'"'"']?[-+][A-Za-z]*c'
    local re_eval='(^|[;&|(`[:space:]])eval[[:space:]]'
    local re_split='(^|[;&|(`]|\$\()[[:space:]]*[A-Za-z0-9_./-]*[A-Za-z0-9_./-]["'"'"'\\][^[:space:]]*'
    [[ $1 =~ $re_nest ]] && return 0
    [[ $1 =~ $re_eval ]] && return 0
    [[ $1 =~ $re_split ]] && return 0
    return 1
}

# _gu_flatten_params CMD — GU_FLAT is CMD with every `${…}` replaced by a
# bare `${GU}`, the one expansion shape the tokenizer models.
_gu_flatten_params() {
    local s=$1 re='\$\{[^}]*\}' out=''
    while [[ $s =~ $re ]]; do
        # shellcheck disable=SC2016 # a literal ${GU}, expanded by nobody
        out=$out${s%%"${BASH_REMATCH[0]}"*}'${GU}'
        s=${s#*"${BASH_REMATCH[0]}"}
    done
    GU_FLAT=$out$s
}

# _gu_strip_heredocs CMD — GU_NOHD is CMD with every heredoc body line
# dropped (opener and terminator lines kept).
_gu_strip_heredocs() {
    local line out='' rest d t re='(^|[^<])<<(-?)[[:space:]]*(["'"'"']?)([A-Za-z_][A-Za-z0-9_]*)\3'
    local -a pend=()
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "${#pend[@]}" -gt 0 ]; then
            t=$line
            case "${pend[0]}" in -*) t=${t#"${t%%[!$'\t']*}"} ;; esac
            if [ "$t" = "${pend[0]#-}" ]; then
                out=$out$line$'\n'
                pend=("${pend[@]:1}")
            fi
            continue
        fi
        out=$out$line$'\n'
        rest=$line
        while [[ $rest =~ $re ]]; do
            d=${BASH_REMATCH[4]}
            [ -z "${BASH_REMATCH[2]}" ] || d=-$d
            pend[${#pend[@]}]=$d
            rest=${rest#*"${BASH_REMATCH[0]}"}
        done
    done <<<"$1"
    GU_NOHD=${out%$'\n'}
}

# guard_unwrap HOOK CMD — 0 when no derived form of CMD is denied by HOOK;
# 2 (the denial already on stderr) when one is, or when a cap is reached.
guard_unwrap() {
    local hook=$1 cmd=$2 depth=${GUARD_UNWRAP_DEPTH:-0} s k w e sep render='' seg child first
    local trigger=0 nl=$'\n' err rc cwd_env xrender='' xseg vs=''
    local -a children=()
    GU_V=() GU_VS=() GU_SW=() GU_SR=() GU_CORE=() GU_LOOKUP=() GU_XA=()
    GU_SHIFT=0 GU_STRIP=0 GU_TOKENIZED=0
    GU_CWD_UNKNOWN=0
    [ "${GUARD_UNWRAP_CWD:-}" != unknown ] || GU_CWD_UNKNOWN=1
    case "$depth" in ''|*[!0-9]*) depth=$GU_MAX_DEPTH ;; esac

    if ! st_tokenize "$cmd"; then
        _gu_flatten_params "$cmd"
        _gu_strip_heredocs "$GU_FLAT"
        if { [ "$GU_FLAT" = "$cmd" ] || ! st_tokenize "$GU_FLAT"; } \
            && { [ "$GU_NOHD" = "$GU_FLAT" ] || ! st_tokenize "$GU_NOHD"; }; then
            if _gu_fallback "$GU_NOHD"; then
                echo "guard-unwrap: refusing a command whose quoting this guard cannot read and that runs a nested shell, an eval or a quoted command word." >&2
                return 2
            fi
            if [[ $GU_NOHD =~ (^|[^A-Za-z0-9_-])(cd|pushd|popd)[[:space:]]|(^|[^A-Za-z0-9_-])env[[:space:]].*(-C|--chdir) ]]; then
                GU_CWD_UNKNOWN=1
            fi
            return 0
        fi
    fi
    # shellcheck disable=SC2034 # read by the sourcing hook
    GU_TOKENIZED=1

    k=0
    while [ "$k" -lt "$ST_N" ]; do
        s=${ST_S[k]}
        if [ -z "${ST_RO[k]}" ]; then
            GU_SW[s]="${GU_SW[s]:-} $k"
        else
            GU_SR[s]="${GU_SR[s]:-} $k"
        fi
        k=$((k + 1))
    done

    s=0
    while [ "$s" -lt "$ST_NSEG" ]; do
        : "${GU_SW[s]:=}"
        _gu_core "$s"
        _gu_shell_bodies "$s"
        s=$((s + 1))
    done
    [ "$GU_SHIFT" = 0 ] || GU_CWD_UNKNOWN=1

    # Render every segment from its command word on, plus its redirects.
    s=0
    while [ "$s" -lt "$ST_NSEG" ]; do
        local -a idx=()
        read -r -a idx <<<"${GU_SW[s]}"
        seg='' xseg=''
        if [ "${GU_LOOKUP[s]}" = 0 ]; then
            k=${GU_CORE[s]}
            if [ "$k" -lt "${#idx[@]}" ] && [ "${ST_W[idx[k]]##*/}" = eval ]; then
                e=''
                w=$((k + 1))
                while [ "$w" -lt "${#idx[@]}" ]; do
                    e="$e${e:+ }${ST_W[idx[w]]}"
                    w=$((w + 1))
                done
                [ -z "$e" ] || _gu_add "$e"
            fi
            first=${GU_CORE[s]}
            while [ "$k" -lt "${#idx[@]}" ]; do
                _gu_render_word "${idx[k]}"
                w=${ST_W[idx[k]]}
                if [ "${GU_QUOTE_ARGS:-0}" = 1 ] && [ "$k" != "$first" ] && [ "${ST_Q[idx[k]]}" = 1 ]; then
                    # A quoted argument stays one quoted word: the hook
                    # tells a quoted pattern from a path by its quotes.
                    GU_RW="'${w//\'/\'\\\'\'}'"
                    if [ "${ST_X[idx[k]]}" = 0 ] && [[ $cmd != *"$GU_RW"* ]] \
                        && [[ $cmd != *"\"$w\""* ]]; then
                        trigger=1
                    fi
                elif [ "$GU_BARE" = 1 ] && [ "${ST_Q[idx[k]]}" = 1 ] && [ "${ST_X[idx[k]]}" = 0 ]; then
                    trigger=1
                fi
                seg="$seg${seg:+ }$GU_RW"
                k=$((k + 1))
            done
            # A stripped xargs runs its command on targets read from stdin,
            # so `rm` alone is not what runs: the second render keeps the
            # xargs word on (HIMMEL-4577).
            k=${GU_XA[s]:-$first}
            while [ "$k" -lt "$first" ]; do
                _gu_render_word "${idx[k]}"
                xseg="$xseg${xseg:+ }$GU_RW"
                k=$((k + 1))
            done
            xseg="$xseg${xseg:+${seg:+ }}$seg"
        fi
        for k in ${GU_SR[s]:-}; do
            case "${ST_RO[k]}" in
                '<<'|'<<-'|[0-9]'<<'|[0-9]'<<-') ;;
                *)
                    _gu_render_word "$k"
                    seg="$seg${seg:+ }${ST_RO[k]}$GU_RW"
                    xseg="$xseg${xseg:+ }${ST_RO[k]}$GU_RW" ;;
            esac
        done
        if [ -n "$seg" ]; then
            sep=${ST_SEP[s]}
            case "$sep" in
                '&&'|'||'|'|'|'|&'|'&') ;;
                '') ;;
                *) sep=';' ;;
            esac
            render="$render$seg${sep:+ $sep }"
            xrender="$xrender$xseg${sep:+ $sep }"
        fi
        s=$((s + 1))
    done
    [ "$GU_STRIP" = 0 ] || trigger=1
    # shellcheck disable=SC1003 # a literal backslash before the newline
    case "$cmd" in *'\'$'\n'*) trigger=1 ;; esac

    if [ "${#GU_V[@]}" -gt "$GU_MAX_VARIANTS" ]; then
        echo "guard-unwrap: refusing a command with more than $GU_MAX_VARIANTS nested shell bodies." >&2
        return 2
    fi
    if [ "$trigger" = 1 ]; then
        # The render keeps every shell and eval word at or past the command
        # word, so the child re-derives those bodies itself. Only `env -S`
        # strings sit before the command word and are dropped, so only they
        # are re-added: re-adding a kept body grows the child at every level.
        for e in "${GU_VS[@]+"${GU_VS[@]}"}"; do vs="$vs$nl$e"; done
        children=("$render$vs")
        # The xargs-kept render renders to itself, so it adds one child, not
        # a level per depth.
        [ "$xrender" = "$render" ] || children[1]="$xrender$vs"
    else
        child=''
        for e in "${GU_V[@]+"${GU_V[@]}"}"; do child="$child${child:+$nl}$e"; done
        children=("$child")
    fi

    cwd_env=''
    [ "$GU_CWD_UNKNOWN" = 0 ] || cwd_env=unknown
    rc=0
    for child in "${children[@]}"; do
        [ -n "$child" ] || continue
        [ "$child" != "$cmd" ] || continue
        if [ "$depth" -ge "$GU_MAX_DEPTH" ]; then
            echo "guard-unwrap: refusing a command nested more than $GU_MAX_DEPTH levels deep." >&2
            return 2
        fi
        if ! child=$(jq -cn --arg c "$child" '{tool_name:"Bash",tool_input:{command:$c}}' 2>/dev/null); then
            echo "guard-unwrap: cannot build the unwrapped call - failing closed" >&2
            return 2
        fi
        if err=$(GUARD_UNWRAP_DEPTH=$((depth + 1)) GUARD_UNWRAP_CWD=$cwd_env "${BASH:-bash}" "$hook" <<<"$child" 2>&1 >/dev/null); then
            continue
        else
            rc=$?
        fi
        break
    done
    [ "$rc" != 0 ] || return 0
    [ -z "$err" ] || printf '%s\n' "$err" >&2
    if [ "$depth" = 0 ]; then
        echo "    (denied in the form the shell actually runs: quotes removed, wrappers stripped, nested shell bodies read; rc=$rc)" >&2
    fi
    return 2
}
