# shellcheck shell=bash
# shellcheck disable=SC2034,SC2016 # the verbatim block: HTARGETS, PR_TOKFAIL and hit are used in the guard only; CMDPOS_REF_RE matches a literal $
# git-env-ok: the word git appears only as a parsed command word; this file runs no git
# lib-cmdpos-clean.sh - the command-position predicate of guard-pr-check-literal.sh,
# shared with the guards that source it (block-chokepoint-env-prefix.sh,
# block-tail-pipe-on-gates.sh). Sourced, never run.
#
# cmdpos_clean_for <names-fn> <command> is true when no segment of <command>
# executes a script but the himmel-gate dispatcher by its anchored spelling:
# every command word is a reader, an inert sed, a pathspec-only git, echo,
# printf without -v, cd, or `bash "$HIMMEL_REPO/scripts/handover/console-kit/
# himmel-gate.sh"`, with no VAR= word, substitution, $'…', comment or write
# redirect. A guard whose rule is about how a script is EXECUTED (a seam var
# beside it, its rc piped away) has nothing to judge in such a command, so a
# mention in a commit message, grep, sed -n or quoted heredoc body is not one.
#
# The block between the markers is guard-pr-check-literal.sh's own code, byte
# for byte: that hook is self-contained and integrity-pinned, so it keeps its
# copy and sources nothing, and test-cmdpos-clean.sh fails when a definition
# here drifts from its same-named one there. Edit there first, then copy.
#
# Relief only: a caller that cannot source this file, or gets false, runs its
# full scan unchanged. bash 3.2-compatible.

_cp_dir=${BASH_SOURCE[0]%/*}
[ "$_cp_dir" != "${BASH_SOURCE[0]}" ] || _cp_dir=.
if [ "$(type -t st_tokenize)" != function ]; then
    # shellcheck source=lib/shell-tokenize.sh
    { [ -r "$_cp_dir/lib/shell-tokenize.sh" ] && . "$_cp_dir/lib/shell-tokenize.sh"; } 2>/dev/null || return 1
fi

# >>> BEGIN cmdpos (verbatim from guard-pr-check-literal.sh) >>>
TARGETS='clear-cr-marker.sh cr-scores.sh
doc-freshness-advisory.sh docs-audit-panel.sh impacted-suites.sh known-findings.sh
ledger-append.sh orphan-check.sh panel-first-pass.sh pr-check-context.sh
pr-check-env.sh review-round.sh write-verdicts.sh'
HTARGETS='scripts/handover/merge-on-green.sh scripts/handover/console-kit/go.sh
scripts/handover/console-kit/himmel-gate.sh'
PR_READERS=' grep egrep fgrep cat head tail wc ls cut tr uniq nl jq '
PR_GIT_UNSAFE=0 PR_TOKFAIL=0 PR_GIT_EXEC=0
GATE_REL=scripts/handover/console-kit/himmel-gate.sh
CMDPOS_REF_RE='^(.*)\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)(.*)$'
_c_unquote() { local LC_ALL=C; REPLY=${1//[\'\"\\]/}; }
_c_join_continuations() { local LC_ALL=C; REPLY=${1//$'\\\n'/}; }
names_target() { # names_target <text> - mentions pr-check, a scripts/cr/
    # target's exact path token, or an HTARGETS marker+stem, in any case. A
    # bare stem substring also matched inside an unrelated file name that
    # happens to contain it (a test suite's own name, e.g. test-cr-scores.sh
    # contains "cr-scores"), which then made every $VAR token elsewhere in
    # the same command look unresolvable - so a target only
    # counts here when its stem is immediately preceded by "cr/", never as a
    # substring anywhere else.
    local t rc=1 pc=$1
    shopt -s nocasematch
    # This hook's own file name (and its suite's) and the slash
    # command's doc are not a pr-check script
    # (`head -n 5 test-guard-pr-check-literal.sh > out`).
    pc=${pc//pr-check-literal.sh/}
    pc=${pc//pr-check.md/}
    case "$pc" in *pr-check*) rc=0 ;; esac
    for t in $TARGETS; do
        # ponytail: this is a PREFIX-stem match (cr/<stem>*), so a filename
        # that merely STARTS WITH a guarded stem after "cr/" (e.g. a target
        # named "foo.sh" also matches "cr/foo-other.sh") counts as a mention
        # even though it names a different file.
        # Over-matching here only makes `mentions` MORE
        # likely to be 1, which routes the command into the slower,
        # stricter classification path below rather than the early
        # fast-exit - the safe direction (a false-deny residual, not a
        # hole). The tokenizer only drops provably inert quoted
        # words from $flat; it does not change this match. Upgrade path:
        # match the tokenized path word exactly, if the residual recurs.
        case "$1" in *[cC][rR]/"${t%.sh}"*) rc=0 ;; esac
    done
    # same prefix-stem match, keyed on each HTARGET's own
    # immediate parent directory (handover/ for merge-on-green.sh,
    # console-kit/ for go.sh) rather than a fixed "cr/" marker.
    case "$1" in *[hH]andover/merge-on-green*) rc=0 ;; esac
    case "$1" in *[cC]onsole-kit/go*) rc=0 ;; esac
    case "$1" in *[cC]onsole-kit/himmel-gate*) rc=0 ;; esac
    shopt -u nocasematch
    return "$rc"
}
short_cluster_has_O() { # short_cluster_has_O <word> <subcommand or ''>
    local c ch vals=mbBDcFCtsXuSo
    case "$1" in --* | -) return 1 ;; -*) ;; *) return 1 ;; esac
    case "$2" in
        # '*' = subcommand unknown (an unrecognised option came first): strict.
        '*' | diff | log | show) case "$1" in *O*) return 0 ;; esac; return 1 ;;
        grep) vals=efABCm ;;
    esac
    c=${1#-}
    while [ -n "$c" ]; do
        ch=${c:0:1}; c=${c:1}
        [ "$ch" = O ] && return 0
        case "$vals" in *"$ch"*) return 1 ;; esac
    done
    return 1
}
git_mentions_only() { # git_mentions_only <command-word index>
    local j=$(( $1 + 1 )) sg=${ST_S[$1]} w sub='' cached=0 dir=0 paths=0 xp=0 bad=0 xk nsub=0 es
    local bsub='' bnext=0 rsub=0 xc xch
    while [ "$j" -lt "$ST_N" ] && [ "${ST_S[j]}" = "$sg" ]; do
        w=${ST_W[j]}
        if [ -n "${ST_RO[j]}" ]; then j=$((j + 1)); continue; fi
        if [ "${ST_X[j]}${ST_G[j]}" != 00 ]; then
            # an expanded word that can begin with `-` may become
            # an exec-capable option (`-O{bash,x}`, `{-O,x}bash`, `--ext-d?ff`).
            # After --, words are pathspec operands, not options.
            # A `$` anywhere in the word word-splits (`echo$IFS-Obash`), so it
            # is unsafe wherever it appears, not only at the start.
            if [ "$paths" != 1 ]; then
                case "$w" in -* | '{'* | '$'* | '*'* | '?'* | '['* | '~'* | *'$'*) PR_GIT_UNSAFE=1 ;; esac
            fi
            # Keep scanning: a later word may be an exec option (`docs/{a,b} -O{x,y}`).
            # an expanded word before the subcommand is a global
            # option's value or the subcommand itself (`$S`, `g?ep`): either way
            # the subcommand is unknowable, so only a positively identified
            # literal one may take the relaxed reading.
            if [ -z "$sub" ]; then sub='*'; dir=0; fi
            # a glob/brace word in the subcommand slot
            # (`re[b]ase`, `rebase{,}`) may BE rebase or bisect: fail closed.
            if [ "$sub" = '*' ] && [ "$nsub" = 0 ] && [ "$paths" != 1 ]; then PR_GIT_UNSAFE=1; PR_GIT_EXEC=1; fi
            # a glob in the bisect verb slot (`r[u]n`) or an
            # expanded word after rebase may be the run verb or an exec flag.
            case "$bsub" in
                bisect) [ "$bnext" = 0 ] || { bnext=0; PR_GIT_EXEC=1; PR_GIT_UNSAFE=1; } ;;
            esac
            if [ "$rsub" = 1 ]; then
                case "$w" in
                    -* | '{'* | '$'* | '*'* | '?'* | '['* | '~'* | *'$'*) PR_GIT_EXEC=1; PR_GIT_UNSAFE=1 ;;
                esac
            fi
            xp=1; j=$((j + 1)); continue
        fi
        # After --, option-shaped words are literal pathspec operands.
        if [ "$paths" = 1 ]; then j=$((j + 1)); continue; fi
        # while no subcommand is identified yet (and none is a known
        # non-grep builtin) the grammar is unknown: strict any-O reading.
        es=$sub
        if [ -z "$sub" ] && [ "$nsub" = 0 ]; then es='*'; fi
        # Refuse these even when the older text classifier cannot see a
        # runner: git aliases/config and helper options can execute operands.
        case "$w" in
            --oneline | --extended | --extended-regexp) ;;
            -c* | --config* | --exec* | --ex | --exe | --ex=* | --exe=* | \
                --upload* | --receive* | ext::* | \
                --o* | --ext*) PR_GIT_UNSAFE=1; bad=1 ;;
            *) if short_cluster_has_O "$w" "$es"; then PR_GIT_UNSAFE=1; bad=1; fi ;;
        esac
        # an exec/write option is denied whatever the pathspec; a
        # directory or empty pathspec matches guarded scripts without naming them.
        case "$w" in
            # Benign long options that share a prefix with an exec option.
            --oneline | --on* | --output-indicator-* | --extended | --extended-regexp) ;;
            # Only the prefixes of --output and --open-files-in-pager (--ou* would
            # also hit --ours); a bare --o* also hit --others and --objects.
            --exec* | --ex | --exe | --ex=* | --exe=* | \
                --upload* | --receive* | ext::* | --ext* | --op* | \
                --ou | --out | --outp | --outpu | --output | \
                --ou=* | --out=* | --outp=* | --outpu=* | --output=*) PR_GIT_EXEC=1 ;;
            -c* | --config*)
                if [ -n "$sub" ] && [ "${w#--}" = "$w" ]; then
                    # After the subcommand -c* is a short-flag cluster (grep -c),
                    # not a config option; -O inside it is the pager/orderfile flag.
                    if short_cluster_has_O "$w" "$es"; then
                        case "$sub" in diff | log | show) ;; *) PR_GIT_EXEC=1 ;; esac
                    fi
                else
                    # Match the config KEY (git folds its case), never the value.
                    # --config-env=KEY=ENVVAR and `--config-env KEY=ENVVAR` carry the key too.
                    case "$w" in
                        -c | --config-env) xk=${ST_W[j + 1]:-}; xk=${xk%%=*} ;;
                        --config-env=*) xk=${w#--config-env=}; xk=${xk%%=*} ;;
                        -c*) xk=${w#-c}; xk=${xk%%=*} ;;
                        *) xk=$w ;;
                    esac
                    xk=$(printf '%s' "$xk" | tr '[:upper:]' '[:lower:]')
                    case "$xk" in
                        *pager* | *alias.* | *filter.* | *textconv* | *fsmonitor* | *sshcommand* | *.command* | *external*) PR_GIT_EXEC=1 ;;
                    esac
                fi ;;
            # -O runs a pager only for grep; diff/log/show take it as an orderfile.
            -*) if short_cluster_has_O "$w" "$es"; then
                    case "$sub" in diff | log | show) ;; *) PR_GIT_EXEC=1 ;; esac
                fi ;;
        esac
        # `git bisect run <prog>` and `git rebase -x|--exec <cmd>`
        # run an arbitrary program, so a guarded script they name is never a
        # pathspec mention. bsub is set only for a positively identified builtin.
        case "$bsub" in
            # bnext: this is the first plain word after `bisect` (redirect
            # targets are skipped at the loop top), i.e. the verb.
            bisect) [ "$bnext" = 0 ] || {
                    bnext=0
                    [ "$w" != run ] || { PR_GIT_EXEC=1; PR_GIT_UNSAFE=1; }
                } ;;
        esac
        # rsub is independent of bsub: a later `bisect` operand word must not
        # overwrite the armed rebase (`git -P rebase bisect -x CMD main`).
        if [ "$rsub" = 1 ]; then
            # -x takes the rest of the word as its command; -s/-X/-C/-S take
            # theirs as a value, so a later x there is text.
            case "$w" in
                --*) ;;
                -?*) xc=${w#-}
                    while [ -n "$xc" ]; do
                        xch=${xc:0:1}; xc=${xc:1}
                        case "$xch" in
                            x) PR_GIT_EXEC=1; PR_GIT_UNSAFE=1; break ;;
                            s|X|C|S|r) break ;;
                        esac
                    done ;;
            esac
        fi
        # An unknown global option (`-P`, `--bare`, ...) leaves sub='*', so the
        # builtin arm below never sees the subcommand; arm it from the word.
        # Re-armed on every later bisect/rebase word: a valued global option
        # after sub='*' (`-P --namespace bisect rebase -x`) is not skipped, so
        # its value can be mistaken for the subcommand; the real one re-arms.
        if [ "$sub" = '*' ]; then
            # any other non-option word may be an alias
            # for rebase or bisect (`git -P rb -x CMD`): arm both, fail closed.
            case "$w" in
                bisect) bsub=bisect; bnext=1 ;;
                rebase) rsub=1 ;;
                -*) ;;
                *) rsub=1; bsub=bisect; bnext=1 ;;
            esac
        fi
        if [ "$dir" = 1 ]; then
            dir=0
            [ "${ST_Q[j]}" = 0 ] || sub='*'
        elif [ -z "$sub" ]; then
            [ "${ST_Q[j]}" = 0 ] || bad=1
            # a global option's separate value is not the subcommand
            # (`--namespace add grep`); an unrecognised option makes the
            # subcommand unknowable, so sub='*' keeps the strict any-O reading.
            case "$w" in
                -C) dir=1 ;;
                -c | --git-dir | --work-tree | --namespace | --super-prefix | \
                    --config-env | --attr-source) bad=1; dir=1 ;;
                --git-dir=* | --work-tree=* | --namespace=* | --super-prefix=* | \
                    --config-env=* | --attr-source=* | -C* | -c*) bad=1 ;;
                --no-pager) ;;
                grep|log|show|diff|add|restore|rm) sub=$w ;;
                -*) bad=1; [ "$nsub" = 1 ] || sub='*' ;;
                # Git ignores an alias that shadows a builtin, so only a builtin
                # name has a known option grammar (long-stable builtins only: a
                # newer one is an alias on an older git). Any other first word
                # may be an alias for grep (`-O` takes the program): strict.
                am | apply | archive | bisect | blame | branch | bundle | \
                    checkout | cherry-pick | clean | clone | commit | config | \
                    describe | fetch | format-patch | gc | init | \
                    ls-files | ls-tree | merge | mv | notes | pull | push | rebase | \
                    reflog | remote | reset | rev-list | rev-parse | revert | \
                    shortlog | stash | status | tag | worktree)
                    bad=1; nsub=1
                    case "$w" in bisect) bsub=bisect; bnext=1 ;; rebase) rsub=1 ;; esac ;;
                # the unknown word may be an alias for
                # rebase or bisect (`git rb -x CMD`): arm both, fail closed.
                *) bad=1
                    if [ "$nsub" = 0 ]; then rsub=1; bsub=bisect; bnext=1; fi
                    [ "$nsub" = 1 ] || sub='*' ;;
            esac
            # A quoted word is not positively identified either.
            [ "${ST_Q[j]}" = 0 ] || sub='*'
        elif [ "$w" = -- ]; then
            # An unknown option may consume -- as its value (-e/-S, ...),
            # rather than end options. Keep that ambiguous shape fenced.
            if ! [[ ${ST_W[j - 1]} =~ ^-[0-9]+$ ]]; then
                case "${ST_W[j - 1]}" in
                    --cached|--staged|--oneline|--name-only|--name-status|--follow|--*=*|-n|-p|-A|-a|-u|-w|--stat) ;;
                    -*) PR_GIT_UNSAFE=1; bad=1 ;;
                esac
            fi
            paths=1
        elif [ "$w" = --cached ]; then
            cached=1
        fi
        j=$((j + 1))
    done
    [ "$bad" = 0 ] && [ "$xp" = 0 ] && [ -n "$sub" ] && [ "$dir" = 0 ] || return 1
    [ "$sub" != rm ] || [ "$cached" = 1 ]
}
edword_names() { # edword_names <word> - a guarded script spelled as a path
    # EXACTLY flat's normalisation: _c_join_continuations, then
    # _c_unquote. A word that keeps quotes, backslashes or a backslash-newline
    # from inside single quotes (scripts/c\<nl>r/x.sh) must match the way the
    # shell git spawns will spell it, never the raw tokenized text.
    local uw
    _c_join_continuations "$1"
    _c_unquote "$REPLY"
    uw=$REPLY
    case "$uw" in
        *.sh* | *scripts/* | *cr/* | *handover/*) names_target "$uw" ;;
        *) return 1 ;;
    esac
}
cmdpos_git() {
    local unsafe=$PR_GIT_UNSAFE gexec=$PR_GIT_EXEC j=$1 rc=0
    PR_GIT_UNSAFE=0 PR_GIT_EXEC=0
    if ! git_mentions_only "$1"; then
        [ "$PR_GIT_UNSAFE$PR_GIT_EXEC" = 00 ] || rc=1
        while [ "$rc" = 0 ] && [ "$j" -lt "$ST_N" ] && [ "${ST_S[j]}" = "${ST_S[$1]}" ]; do
            ! edword_names "${ST_W[j]}" || rc=1
            j=$((j + 1))
        done
    fi
    PR_GIT_UNSAFE=$unsafe PR_GIT_EXEC=$gexec
    return "$rc"
}
cmdpos_clean() { # true when no segment of $cmd executes a script but the dispatcher
    local k j sg=-1 cw=-1 kind='' dk=-1 gates=0 gseg=-1 w t raw hit
    # shellcheck disable=SC2016 # the literal anchored spellings, never expanded
    local s1="\"\$HIMMEL_REPO/$GATE_REL\"" s2="\"\${HIMMEL_REPO}/$GATE_REL\""
    st_tokenize "$cmd" || return 1
    [ "$ST_SUBST$ST_ANSIC$ST_COMMENT" = 000 ] || return 1
    k=0
    while [ "$k" -lt "$ST_N" ]; do
        [ "${ST_A[k]}" = 0 ] || return 1
        if [ "${ST_S[k]}" != "$sg" ]; then sg=${ST_S[k]}; cw=-1; kind=''; fi
        w=${ST_W[k]}
        case "${ST_RO[k]}" in
            *'>&') case "$w" in *[!0-9-]* | '') return 1 ;; esac ;;
            *'>' | *'>|') [ "$w" = /dev/null ] || return 1 ;;
        esac
        case "$kind" in
            strict) [ "${ST_X[k]}${ST_G[k]}" = 00 ] || return 1 ;;
            printf) case "$w" in -v*) return 1 ;; esac ;;
        esac
        if [ "${ST_X[k]}" = 1 ] && [ "$k" != "$dk" ]; then
            t=$w
            while [[ $t =~ $CMDPOS_REF_RE ]]; do t="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"; done
            case "$t" in *'$'*) return 1 ;; esac
        fi
        if [ -z "${ST_RO[k]}" ] && [ "$cw" -lt 0 ]; then
            cw=$k
            [ "${ST_Q[k]}${ST_X[k]}${ST_G[k]}" = 000 ] || return 1
            case "$w" in
                bash)
                    j=$((k + 1))
                    while [ "$j" -lt "$ST_N" ] && [ -n "${ST_RO[j]}" ]; do j=$((j + 1)); done
                    [ "$j" -lt "$ST_N" ] && [ "${ST_S[j]}" = "$sg" ] || return 1
                    [ "${ST_Q[j]}${ST_X[j]}${ST_G[j]}" = 110 ] || return 1
                    # shellcheck disable=SC2016 # literal text, never expanded
                    case "${ST_W[j]}" in '$HIMMEL_REPO/'"$GATE_REL" | '${HIMMEL_REPO}/'"$GATE_REL") ;; *) return 1 ;; esac
                    # A pipe only after a lone --help: an fd dup (1>&2, 1>&-)
                    # hides the pipe from the dispatcher's own check.
                    if [ "${ST_SEP[sg]}" = '|' ]; then
                        [ "$((j + 3))" -le "$ST_N" ] && [ "${ST_S[j + 2]}" = "$sg" ] || return 1
                        [ "$((j + 3))" = "$ST_N" ] || [ "${ST_S[j + 3]}" != "$sg" ] || return 1
                        case "${ST_W[j + 2]}" in --help | -h) ;; *) return 1 ;; esac
                        case "${ST_RO[j + 1]}${ST_RO[j + 2]}" in '') ;; *) return 1 ;; esac
                    fi
                    [ "$gseg" -ge 0 ] || gseg=$sg
                    dk=$j
                    gates=$((gates + 1))
                    ;;
                sed) st_sed_args "$k" 0 || return 1 ;;
                git | /usr/bin/git) cmdpos_git "$k" || return 1; kind=strict ;;
                printf) kind='printf' ;;
                echo | cd) ;;
                *) case "$PR_READERS" in *" $w "*) ;; *) return 1 ;; esac ;;
            esac
        fi
        k=$((k + 1))
    done
    [ "$gates" -gt 0 ] || return 0
    # From the first dispatcher on, only && or a pipe joins segments, so no
    # later command replaces a failed gate's rc.
    k=$gseg
    while [ "$k" -lt "$ST_NSEG" ]; do
        case "${ST_SEP[k]}" in '' | '&&' | '|') ;; *) return 1 ;; esac
        k=$((k + 1))
    done
    # Every dispatcher word is one of the two raw spellings above (a `"$"`
    # or quoted-away `$` reads the same once tokenized), the command names
    # HIMMEL_REPO nowhere else, and this hook's own value is an anchor that
    # carries the dispatcher.
    case "${HIMMEL_REPO:-}" in /*) [ -f "$HIMMEL_REPO/$GATE_REL" ] || return 1 ;; *) return 1 ;; esac
    raw=$cmd
    k=0
    while :; do
        case "$raw" in
            *"$s1"*) raw=${raw/"$s1"/ } ;;
            *"$s2"*) raw=${raw/"$s2"/ } ;;
            *) break ;;
        esac
        k=$((k + 1))
    done
    [ "$k" = "$gates" ] || return 1
    case "$raw" in *HIMMEL_REPO*) return 1 ;; esac
    return 0
}
# <<< END cmdpos <<<

# The predicate above knows guard-pr-check-literal.sh's targets only. A git
# that is neither pathspec-only nor `git commit` can still run a script one of
# its words names (`git submodule foreach '<script>'`, an alias), so for the
# caller's own scripts, named by <names-fn> <word>, such a git segment is not
# clean. A backslash-newline beside a heredoc can split its terminator or a
# `$(` inside its body, which the tokenizer reads as body text, so such a
# command is not clean either. Nor is a printf with a %n conversion: bash's
# printf assigns through it (`printf '%n' PATH` sets PATH), which can repoint
# the `bash` a later dispatcher segment runs. An option or format word with a
# live `$` or a glob can expand to such a conversion, so it is not clean
# either; a `%%` prints a literal `%` and is skipped.
cmdpos_clean_for() { # cmdpos_clean_for <names-fn> <command>
    local cmd=$2 k ek cw w fmt rc=0 unsafe=$PR_GIT_UNSAFE gexec=$PR_GIT_EXEC nof=0
    local pn_re='%[^A-Za-z%]*n' pp='%%'
    case $- in *f*) ;; *) nof=1; set -f ;; esac
    case $cmd in *'<<'*\\$'\n'* | *\\$'\n'*'<<'*) rc=1 ;; esac
    [ "$rc" = 1 ] || cmdpos_clean || rc=1
    k=0
    while [ "$rc" = 0 ] && [ "$k" -lt "$ST_N" ]; do
        ek=$k cw=-1
        while [ "$ek" -lt "$ST_N" ] && [ "${ST_S[ek]}" = "${ST_S[k]}" ]; do
            [ "$cw" -ge 0 ] || [ -n "${ST_RO[ek]}" ] || cw=$ek
            ek=$((ek + 1))
        done
        if [ "$cw" -ge 0 ]; then
            case "${ST_W[cw]}" in
                git | /usr/bin/git)
                    # `git commit` (a literal builtin right after git, which no
                    # alias can shadow) takes no option that runs a program.
                    if [ "${ST_W[cw + 1]:-}${ST_Q[cw + 1]:-1}" != commit0 ] \
                        && ! git_mentions_only "$cw"; then
                        w=$((cw + 1))
                        while [ "$w" -lt "$ek" ]; do
                            ! "$1" "${ST_W[w]}" || rc=1
                            w=$((w + 1))
                        done
                    fi ;;
                printf)
                    w=$((cw + 1)) fmt=0
                    while [ "$w" -lt "$ek" ]; do
                        [ "$fmt" = 1 ] || [ "${ST_X[w]}${ST_G[w]}" = 00 ] || rc=1
                        [[ ! ${ST_W[w]//"$pp"/} =~ $pn_re ]] || rc=1
                        case "$fmt${ST_W[w]}" in 0-?*) ;; 0*) fmt=1 ;; esac
                        w=$((w + 1))
                    done ;;
            esac
        fi
        k=$ek
    done
    PR_GIT_UNSAFE=$unsafe PR_GIT_EXEC=$gexec
    [ "$nof" = 0 ] || set +f
    return "$rc"
}
