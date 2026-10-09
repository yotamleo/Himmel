#!/usr/bin/env bash
# PreToolUse Bash auto-approve gateway (HIMMEL-203).
#
# WHY: Claude Code's static permission matcher REFUSES to consult the
# `allow` list whenever a Bash command contains shell variable expansion
# (`$t`), command substitution `$(…)`, backticks, or compound operators
# (`| && || ; &` / redirects) — surfaced as "Contains simple_expansion".
# So even a fully-allow-listed binary (`node *`, `grep *`) prompts the
# moment it is wrapped in a loop or pipe. Interactive that just nags; in
# headless/auto it HANGS then aborts → needs an operator. No amount of
# allow-list tuning fixes it: the matcher bails BEFORE reading the rules.
#
# This hook reads the FULL literal command and returns an explicit
# permissionDecision:"allow" for a curated set of read-only / inspection
# commands — which works DESPITE expansion because the hook sees the text
# and decides itself, bypassing the matcher's bail-out.
#
# CONTRACT — inverted vs the block-* hooks; read carefully:
#   * NEVER blocks (exit-2). ALMOST NEVER denies — the one carve-out below
#     emits an explicit permissionDecision:"deny", never an exit-2 block, and
#     even that is a single narrow shape. Otherwise it stays silent and the
#     command falls through to the normal permission flow (prompt in
#     interactive, abort in headless) — identical to this hook not
#     existing. It therefore FAILS OPEN: missing jq, unparseable input,
#     anything-not-provably-safe → silent `exit 0`, no decision emitted.
#   * It only ever EMITS "allow" — with exactly ONE documented DENY
#     carve-out (HIMMEL-2121): a root-anchored `find` with no `-maxdepth`
#     anywhere in its segment (e.g. `find / -iname x`, `find C:\ -name x`,
#     `find $HOME -name x`). WHY a deny and not silence: this hook exists
#     because the fall-through prompt is unattended in headless/cadence
#     sessions — but that only makes the walker WORSE, not safer, since an
#     orphaned whole-disk `find` outlives its dead parent (specimen: 20+ min,
#     pinned a saturated spawn path). The shape is never legitimate without
#     `-maxdepth`, so it is denied outright rather than left to a prompt
#     nobody is there to answer. Single-run bypass: `FIND_ROOTWALK_OK=1` set
#     in the LAUNCHING shell (see segment_is_rootwalk_find below).
#   * The existing destructive deny-list and the block-* deny hooks remain
#     the hard backstop: per CC docs a deny rule and an exit-2 hook WIN over
#     a hook "allow". So auto-approving `cat *`/`grep *` here cannot defeat
#     block-read-secrets (that hook exits 2 on a secret read; its decision
#     takes precedence).
#
# SAFETY MODEL — a command is auto-approved ONLY when ALL hold:
#   1. No command/process substitution: no `$(`  `` ` ``  `<(`  `>(`.
#   2. No interpreter shell-out tell: no `system(` `popen(` `exec(`.
#   3. No output redirect to a real file (`>`/`>>`); only `>/dev/null`
#      and fd-dups (`2>&1`) are tolerated. (We never auto-approve writing
#      a file. Reading via `<` is fine.)
#   4. Every sub-command (split on | && || ; & / newline) resolves — after
#      skipping shell keywords, redirects and leading VAR=val assignments —
#      to a binary that is either in the read-only safe set below, or
#      `git <read-subcommand>`, `gh <read-subcommand>`, or the dogfooded
#      Jira CLI (`node …/scripts/jira/dist/index.js …`, operator
#      allow-listed in .claude/settings.json). The jira CLI alone may also
#      carry a bare literal `JIRA_PROJECT_KEY=<KEY>` prefix (HIMMEL-4780).
#   The ONE non-read exception (HIMMEL-3131): a lone `queue-lock.sh` lock verb
#   (`[HANDOVER_DIR=<root>] bash scripts/handover/queue-lock.sh <verb> …`,
#   literal args) is approved ONLY as the whole command — see
#   segment_is_queue_lock. It is never one segment of a compound.
#   The second (HIMMEL-3486): /pr-check step 3.6's `impacted-suites.sh`
#   literal, whole command only and only on the anchor's bytes — see
#   cmd_is_impacted_suites.
#   Variable expansion in ARGUMENTS (`cat $f`, `… get $t`) is fine — the
#   binary (argv[0]) is still a literal so we know what runs. If the binary
#   ITSELF is a variable (`$cmd …`) it is not in the safe set → falls
#   through. That is the simple_expansion case we deliberately approve:
#   the risk is the binary, not the loop variable. EXCEPTION (HIMMEL-3660):
#   for the six write-guarded verbs (find, sort, xxd, tree, base64, file),
#   an unquoted brace/parameter expansion OR an unquoted glob (`*`, `?`,
#   `[`) anywhere in the segment falls through instead — any of those could
#   hide the write/delete/exec flag the guard is checking argv words for.
#   HIMMEL-3886: a brace expansion (unquoted `{a,b}` / `{a..b}`) in ANY word
#   of ANY segment falls through for every binary — one central refusal
#   before all allow arms (see word_has_brace_expansion).
#
# Known residual (accepted; gate targets accidental hangs, not a determined
# attacker — the deny-list + block-* hooks are the security backstop):
#   * Quoted operators (`grep "a|b" f`) over-split into segments and may
#     fall through to a prompt. That errs SAFE (prompt), never toward a
#     wrong approval.
#
# No bypass env var for the ALLOW side — there is nothing to bypass (grants
# only). The one DENY carve-out (HIMMEL-2121, above) has its own bypass:
# FIND_ROOTWALK_OK=1 in the launching shell.
# To DISABLE the hook entirely, comment it out in .claude/settings.json.
#
# bash 3.2-compatible (no mapfile / associative arrays).
set -uo pipefail

# Pure read-only / inspection binaries. Write-capable tools (rm mv cp mkdir
# chmod tee), command runners (xargs command env sudo nohup time exec), and
# programmable / general-purpose interpreters (sed awk gawk node npm npx bash
# sh python perl ruby — they can write files in place or shell out) are
# deliberately ABSENT: they fall through to a prompt. git/gh/jira are handled
# by the subcommand allow-lists below. `sort` and `find` ARE here but are
# flag-guarded in segment_is_safe (they have file-writing / exec options).
#
# cd/pushd/popd are shell-navigation builtins: they change the working
# directory only — no FS-content write, no process exec, no flags that take a
# command. A `cd <dir> && <safe>` is no more powerful than <safe> run from
# elsewhere (each later segment is still vetted independently); `cd $(…)` is
# already refused by the global command-substitution tripwire. Including them
# closes the HIMMEL-205 gap where a `cd`-prefixed jira write (or any safe
# command) fell through to the auto-mode classifier and was denied.
is_safe_bin() {
    case "$1" in
        cat|tac|head|tail|nl|fold|column|less|more|most) return 0 ;;
        grep|egrep|fgrep|rg|ripgrep|ag)                  return 0 ;;
        cut|tr|sort|uniq|comm|join|paste|wc)             return 0 ;;
        jq)                                              return 0 ;;
        xxd|od|hexdump|strings|file|base64)              return 0 ;;
        ls|find|tree|stat|du|df|realpath|readlink|basename|dirname|pwd) return 0 ;;
        cd|pushd|popd)                                   return 0 ;;
        echo|printf|date|seq|true|false|test|'['|read|:) return 0 ;;
        diff|cmp|cksum|md5sum|sha1sum|sha256sum)         return 0 ;;
        which|type|printenv)                             return 0 ;;
    esac
    return 1
}

# HIMMEL-3894: cook every argv word of a git/gh command into CW (index-aligned
# with the raw words) so flag checks see the argv text, not a quoted or escaped
# spelling (`"--output=x"`, `\-f`). Fails — the caller falls through — when a
# word cannot be cooked (an unquoted `$VAR`, a brace span), or when a word
# starts with an unquoted glob character, which can expand into a `-`-leading
# file name that reads as a flag. A `--` does not exempt later words: it may
# be an option's argument (`--grep --`), not the terminator. CW_GLOB=1 when
# any word carries an unquoted glob at all; CW_FIRST_GLOB is that word's index
# (a glob can expand to several words and shift every position after it).
cook_argv_words() {
    local w i=0
    CW=()
    CW_GLOB=0
    CW_FIRST_GLOB=999999
    for w in "$@"; do
        shell_word_value "$w" || return 1
        case "$w" in '*'*|'?'*|'['*) return 1 ;; esac
        # A glob behind quoted text (`""*`, `"-"*`) expands the same way.
        if [ "$SW_HAS_UNQUOTED_GLOB" = 1 ]; then
            [ "$CW_GLOB" = 1 ] || CW_FIRST_GLOB=$i
            CW_GLOB=1
            case "$SW_VALUE" in '-'*|'*'*|'?'*|'['*) return 1 ;; esac
        fi
        i=$((i + 1))
        CW+=("$SW_VALUE")
    done
    return 0
}

# git read-only subcommands (no mutating form). Deliberately EXCLUDES
# branch/tag/remote/config/worktree/stash/reflog/notes (have write forms)
# and commit/push/pull/merge/rebase/checkout/reset/clean (mutating) — those
# fall through to the normal prompt + deny-list.
git_subcmd_is_read() {
    local -a g=("$@")            # g[0] == git
    local n=${#g[@]} j=1 t
    cook_argv_words "$@" || return 1
    while [ "$j" -lt "$n" ]; do  # skip global flags (some take a separate arg)
        t="${g[$j]}"
        case "${CW[$j]}" in
            # Exec sinks — `-c diff.external=cmd`, `-c core.pager=cmd`, config
            # injection, and `--exec-path` (relocates git's subcommand dir).
            # NEVER auto-approve these; fall through to a prompt.
            -c|--config-env|--config-env=*|--exec-path|--exec-path=*) return 1 ;;
            # HIMMEL-3894: a quoted/escaped global flag would be skipped by the
            # raw walk below with the wrong arity; fall through.
            -*) [ "$t" = "${CW[$j]}" ] || return 1 ;;
        esac
        case "$t" in
            --git-dir=*|--work-tree=*|--namespace=*) j=$((j + 1)); continue ;;  # =form: no separate arg
            -C|--git-dir|--work-tree|--namespace) j=$((j + 2)); continue ;;     # space form: skip arg
            # HIMMEL-3907: only known VALUE-LESS globals are skipped; any other
            # dash word may take a value that shifts the subcommand → fall through.
            -p|--paginate|-P|--no-pager|--bare|--no-replace-objects|--no-lazy-fetch|--no-optional-locks|--no-advice|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs) j=$((j + 1)); continue ;;
            -*) return 1 ;;
            *) break ;;
        esac
    done
    [ "$j" -ge "$n" ] && return 1
    # A glob at or before the subcommand word can expand into extra words and
    # move which word git reads as the subcommand.
    [ "$CW_FIRST_GLOB" -le "$j" ] && return 1
    # ls-remote is DELIBERATELY EXCLUDED: it speaks to a <repository> that can
    # be `ext::<cmd>` (remote-helper transport ACE) or carry `--upload-pack=<cmd>`
    # — both run an arbitrary shell command. Like fetch/clone/pull it is a
    # remote op, not a local read; fall through to a prompt.
    case "${g[$j]}" in
        status|log|diff|show|rev-parse|rev-list|describe|blame|annotate|shortlog|\
        ls-files|ls-tree|cat-file|for-each-ref|symbolic-ref|name-rev|\
        merge-base|whatchanged|grep|count-objects|var|show-ref|show-branch|\
        cherry|verify-commit|verify-tag|version) ;;
        *) return 1 ;;
    esac
    # symbolic-ref is read-only ONLY in its query form (`git symbolic-ref HEAD`).
    # Given a 2nd non-flag operand (`git symbolic-ref HEAD refs/heads/x`) it
    # REWRITES the ref — a mutating side effect. Reject that form.
    if [ "${g[$j]}" = "symbolic-ref" ]; then
        # A glob operand can expand into the name + value write form.
        [ "$CW_GLOB" = 1 ] && return 1
        local sj=$((j + 1)) ops=0 w
        while [ "$sj" -lt "$n" ]; do
            w="${CW[$sj]}"
            case "$w" in -*) ;; *) ops=$((ops + 1)) ;; esac
            sj=$((sj + 1))
        done
        [ "$ops" -ge 2 ] && return 1   # name + value = write form
    fi
    # Even on a read subcommand, reject subcommand-level exec / file-write flags:
    #   --output[=F] (diff/log/show write to a file)   --ext-diff (runs diff.external)
    #   -O[cmd] / --open-files-in-pager[=cmd] (git grep execs a pager command)
    #   --textconv / --filters (run gitattributes-configured filter commands)
    # HIMMEL-3894: matched on the cooked words. git accepts a unique prefix of
    # a long option (`--outp=F`) and packs short flags (`-iO<cmd>`), so a long
    # word is matched as an abbreviation and any single-dash word holding an
    # `O` falls through. `--text` is its own option, not a `--textconv` prefix.
    local f
    for f in "${CW[@]}"; do
        case "$f" in
            --text) ;;
            --*)
                guard_is_long_abbrev "output" "$f" && return 1
                guard_is_long_abbrev "open-files-in-pager" "$f" && return 1
                guard_is_long_abbrev "ext-diff" "$f" && return 1
                guard_is_long_abbrev "textconv" "$f" && return 1
                guard_is_long_abbrev "filters" "$f" && return 1 ;;
            -*)
                case "${f#-}" in *O*) return 1 ;; esac ;;
        esac
    done
    return 0
}

# git push --force-with-lease on a NON-main branch → auto-approve (HIMMEL-212).
# The blanket deny `Bash(git push --force*)` previously blocked even the SAFE
# lease form, so a clean rebase push prompted/hung in auto. This grant narrows
# that: it mirrors the protected-ref stance in scripts/guardrails/lib.sh
# (is_on_main) and the pre-push check-no-force-push.sh backstop (hard-refuse
# force-to-main, warn-on-non-main). It grants ONLY when ALL hold:
#   * subcommand is `push` AND a `--force-with-lease[=…]` flag is present;
#   * NO bare `--force` / `-f` anywhere (the no-lease form clobbers without the
#     stale-tip check, so it stays deny-listed);
#   * NO token names main OR master as the push target (`main`, `origin/main`,
#     `refs/heads/main`, `…:main`, `main:…`, and the `master` equivalents —
#     HIMMEL-297, both are protected defaults);
#   * current HEAD resolves to a branch that is NOT main/master (detached HEAD,
#     empty, or non-repo → NOT granted; fail safe).
# Not granted → falls through to the normal prompt; the pre-push hook still
# hard-refuses any force to main/master, so this is defense in depth, not the
# sole gate.
git_push_force_with_lease_is_safe() {
    local -a g=("$@")            # g[0] == git
    local n=${#g[@]} j=1 t
    cook_argv_words "$@" || return 1
    # A glob can expand into a protected refspec (`+*`, `HEAD:*`) unseen.
    [ "$CW_GLOB" = 1 ] && return 1
    # Skip git global flags to land on the subcommand. Exec-sink flags
    # (-c / --exec-path) are rejected outright (same set as git_subcmd_is_read).
    while [ "$j" -lt "$n" ]; do
        t="${g[$j]}"
        case "${CW[$j]}" in
            -c|--config-env|--config-env=*|--exec-path|--exec-path=*) return 1 ;;
            -*) [ "$t" = "${CW[$j]}" ] || return 1 ;;   # HIMMEL-3894: quoted global flag
        esac
        case "$t" in
            --git-dir=*|--work-tree=*|--namespace=*) j=$((j + 1)); continue ;;
            -C|--git-dir|--work-tree|--namespace) j=$((j + 2)); continue ;;
            # HIMMEL-3907: same value-less allowlist as git_subcmd_is_read.
            -p|--paginate|-P|--no-pager|--bare|--no-replace-objects|--no-lazy-fetch|--no-optional-locks|--no-advice|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs) j=$((j + 1)); continue ;;
            -*) return 1 ;;
            *) break ;;
        esac
    done
    [ "$j" -ge "$n" ] && return 1
    [ "${g[$j]}" = "push" ] || return 1
    local has_lease=0 has_bare_force=0 targets_main=0 k m=$((j + 1))
    while [ "$m" -lt "$n" ]; do
        # The lease itself must be a literal word (a quoted spelling never
        # grants); every denial below is matched on the cooked word.
        case "${g[$m]}" in
            --force-with-lease|--force-with-lease=*) has_lease=1 ;;
        esac
        k="${CW[$m]}"
        m=$((m + 1))
        case "$k" in
            --force-with-lease|--force-with-lease=*) ;;
            # HIMMEL-3894: a bare force spelled as a unique prefix (`--forc`)
            # or packed into a short cluster (`-uf`).
            --*) guard_is_long_abbrev "force" "$k" && has_bare_force=1 ;;
            -*)  case "${k#-}" in *f*) has_bare_force=1 ;; esac ;;
        esac
        case "$k" in
            # Any refspec that writes remote main OR master (both protected
            # defaults, HIMMEL-297) — incl. the `+`-force prefix (`+main` ≡
            # `+main:main`) and explicit `src:main` colon forms.
            main|+main|origin/main|+origin/main|refs/heads/main|+refs/heads/main|\
            *:main|*:refs/heads/main|main:*|\
            master|+master|origin/master|+origin/master|refs/heads/master|+refs/heads/master|\
            *:master|*:refs/heads/master|master:*) targets_main=1 ;;
        esac
    done
    [ "$has_lease" -eq 1 ]      || return 1
    [ "$has_bare_force" -eq 1 ] && return 1
    [ "$targets_main" -eq 1 ]   && return 1
    local br
    br=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1
    # main AND master are both protected defaults (HIMMEL-297) — never
    # auto-approve a lease push made while sitting on either.
    case "$br" in
        ''|HEAD|main|master) return 1 ;;
    esac
    return 0
}

# gh read-only subcommands. `gh api` is EXCLUDED (can POST/PATCH).
gh_subcmd_is_read() {
    local -a g=("$@")            # g[0] == gh
    local n=${#g[@]} j=1 k
    cook_argv_words "$@" || return 1
    # `--web`/`-w` launches a browser → not read. HIMMEL-3894: matched on the
    # cooked words, as a long-option prefix and inside a short cluster (`-wR`).
    for k in "${CW[@]}"; do
        case "$k" in
            --*) guard_is_long_abbrev "web" "$k" && return 1 ;;
            -*)  case "${k#-}" in *w*) return 1 ;; esac ;;
        esac
    done
    # HIMMEL-3907: a dash word before the group or between group and verb may
    # take a value that shifts which word gh reads as the verb → fall through.
    # Flags AFTER the verb are unaffected.
    local grp="${g[$j]:-}"
    case "$grp" in -*) return 1 ;; esac
    k=$((j + 1))
    case "${g[$k]:-}" in -*) return 1 ;; esac
    local verb="${g[$k]:-}"
    case "$grp" in
        pr)       case "$verb" in view|list|diff|checks|status) return 0 ;; esac ;;
        issue)    case "$verb" in view|list|status) return 0 ;; esac ;;
        repo)     case "$verb" in view|list) return 0 ;; esac ;;
        release)  case "$verb" in view|list) return 0 ;; esac ;;
        run)      case "$verb" in view|list) return 0 ;; esac ;;
        workflow) case "$verb" in view|list) return 0 ;; esac ;;
        label)    case "$verb" in list) return 0 ;; esac ;;
        auth)     case "$verb" in status) return 0 ;; esac ;;
    esac
    return 1
}

# split_bytes <text> <length> -- fill the CALLER's local array SC with <text>,
# one byte per element (HIMMEL-4678). The walkers below step through a command
# one character at a time, and bash resolves ${s:i:1} by scanning s from its
# start (decoding it, in a UTF-8 locale), so indexing the string made every
# walk O(n^2): a 12 KB heredoc of prose took seconds, outran this guard's 15 s
# chain window under fleet load, and the guard failed closed on a harmless
# call. One linear read into an array makes each step O(1). The callers run
# under LC_ALL=C, so ${#s}, SC and ${s:a:b} all count bytes. Walking bytes is
# the same walk as walking characters: every character a walker tests is
# ASCII, a UTF-8 multibyte sequence never contains an ASCII byte, so each
# ASCII byte is its own character either way and every other byte is only
# ever appended to a word, in order.
split_bytes() {
    local c k=0
    SC=()
    while [ "$k" -lt "$2" ] && IFS= read -r -d '' -n1 c; do
        SC[k]=$c; k=$((k + 1))
    done <<<"$1"
}

# Split one command segment into shell WORDS without evaluating it. Whitespace
# delimits words only when unquoted; quote delimiters and escapes stay in each
# raw token so shell_word_value can simulate their argv value and expansion
# semantics. Adjacent fragments (`/''`, `"$HOME"/`) remain one word.
tokenize_seg_words() {
    local s="$1" n i c nx st word have LC_ALL=C
    local -a SC
    n=${#s}; i=0; st=0; word=""; have=0; RB_TOKENS=()
    split_bytes "$s" "$n"
    while [ "$i" -lt "$n" ]; do
        c="${SC[i]-}"
        if [ "$st" = 1 ]; then                       # inside single quotes
            word+="$c"; have=1
            [ "$c" = "'" ] && st=0
            i=$((i + 1)); continue
        fi
        if [ "$st" = 2 ]; then                       # inside double quotes
            if [ "$c" = "\\" ]; then
                nx="${SC[i + 1]-}"
                word+="$c$nx"; have=1; i=$((i + 2)); continue
            fi
            word+="$c"; have=1
            [ "$c" = '"' ] && st=0
            i=$((i + 1)); continue
        fi
        case "$c" in
            "'") st=1; word+="$c"; have=1 ;;
            '"') st=2; word+="$c"; have=1 ;;
            "\\")
                nx="${SC[i + 1]-}"
                # Keep the established Git-Bash/Windows `find C:\ <expr>`
                # spelling as a drive-root token; the following space still
                # delimits the next word instead of being consumed here.
                case "$nx" in " "|$'\t'|$'\n'|$'\r') word+="$c"; have=1; i=$((i + 1)); continue ;; esac
                word+="$c$nx"; have=1; i=$((i + 2)); continue ;;
            # HIMMEL-5034: split on bash's IFS word separators (space, tab,
            # newline); FF, VT and U+2028 are word bytes to bash, so a root
            # walk needs a real separator.
            # ponytail: also splits on CR where bash does not (safe direction:
            # a bash word still starts with its first sub-token, so a leading
            # flag stays visible); revisit when any flag check relies on a
            # word's END or suffix rather than its prefix (HIMMEL-3886).
            " "|$'\t'|$'\n'|$'\r')
                if [ "$have" -eq 1 ]; then
                    RB_TOKENS+=("$word"); word=""; have=0
                fi ;;
            *) word+="$c"; have=1 ;;
        esac
        i=$((i + 1))
    done
    [ "$st" = 0 ] || return 1
    [ "$have" -eq 0 ] || RB_TOKENS+=("$word")
    return 0
}

# Simulate one raw shell word's argv text without performing expansion. The
# cooked value joins adjacent quote fragments and removes quote delimiters.
# SW_EXPANDS_HOME records whether $HOME/${HOME} or
# $USERPROFILE/${USERPROFILE} is a real expansion (unquoted or double-quoted),
# rather than identical-looking text protected by single quotes or a backslash.
# shellcheck disable=SC2016 # every variable spelling below is inspected literally; nothing is expanded
shell_word_value() {
    local s="$1" n i c nx st=0 bd=0 bf=0 LC_ALL=C
    local -a SC
    n=${#s}; i=0; SW_VALUE=""; SW_EXPANDS_HOME=0; SW_EXPANDS_TILDE=0; SW_HAS_UNQUOTED_GLOB=0
    split_bytes "$s" "$n"
    while [ "$i" -lt "$n" ]; do
        c="${SC[i]-}"
        if [ "$st" = 1 ]; then
            if [ "$c" = "'" ]; then st=0; else SW_VALUE+="$c"; fi
            i=$((i + 1)); continue
        fi
        if [ "$st" = 0 ] && [ "$c" = '$' ]; then
            nx="${SC[i + 1]-}"
            # ANSI-C and locale quotes have values that cannot be safely
            # classified statically; leave them for the approval prompt.
            case "$nx" in "'"|'"') return 1 ;; esac
        fi
        case "$c" in
            "'")
                [ "$st" = 0 ] && { st=1; i=$((i + 1)); continue; } ;;
            '"')
                if [ "$st" = 2 ]; then st=0; else st=2; fi
                i=$((i + 1)); continue ;;
            "\\")
                nx="${SC[i + 1]-}"
                if [ "$st" = 0 ]; then
                    if [ -z "$nx" ]; then
                        SW_VALUE+="$c"; i=$((i + 1)); continue
                    fi
                    SW_VALUE+="$nx"; i=$((i + 2)); continue
                fi
                case "$nx" in
                    '$'|'`'|'"'|"\\") SW_VALUE+="$nx"; i=$((i + 2)); continue ;;
                esac ;;
        esac
        # HIMMEL-3660: brace expansion (`{a,b}`, `{1..5}`) explodes ONE raw
        # word into several argv words before the command runs, so a token
        # containing an unquoted `{...,...}` or `{...\.\..}` can hide a
        # dangerous flag from every literal-word guard below it. Track only
        # the outermost unquoted brace span and fail closed the instant it
        # closes with a comma or `..` seen inside — never try to enumerate
        # what it would expand TO.
        if [ "$st" = 0 ]; then
            case "$c" in
                '{') bd=$((bd + 1)) ;;
                '}')
                    if [ "$bd" -gt 0 ]; then
                        bd=$((bd - 1))
                        [ "$bf" = 1 ] && return 1
                    fi ;;
                ',') [ "$bd" -gt 0 ] && bf=1 ;;
                '.') [ "$bd" -gt 0 ] && [ "${SC[i + 1]-}" = '.' ] && bf=1 ;;
                # HIMMEL-3660: an unquoted glob metacharacter can expand this
                # word into several argv words, one of which may be a
                # `-`-leading name that reads as a flag (`sort -* f` with a
                # file named `-oPWNED` writes it). Record it; callers that
                # guard a write/delete/exec flag check this before trusting
                # SW_VALUE's literal cooked text.
                '*'|'?'|'[') SW_HAS_UNQUOTED_GLOB=1 ;;
            esac
        fi
        if [ "$c" = '~' ] && [ "$st" = 0 ] && [ "$i" -eq 0 ]; then
            case "${SC[i + 1]-}" in ''|'/'|"'"|'"') SW_EXPANDS_TILDE=1 ;; esac
        fi
        if [ "$c" = '$' ]; then
            nx="${SC[i + 1]-}"
            # `$(...)` command substitution is a distinct expansion kind, out
            # of this ticket's scope; HIMMEL-2121's rootwalk-find scan already
            # tolerates it as opaque literal text, so keep that behavior and
            # only fail closed on PARAMETER expansion (`${…}`, bare `$VAR`)
            # below.
            if [ "$nx" = '(' ]; then
                SW_VALUE+="$c"; i=$((i + 1)); continue
            fi
            if [ "${s:$i:14}" = '${USERPROFILE}' ]; then
                SW_VALUE+=""'${USERPROFILE}'; SW_EXPANDS_HOME=1
                i=$((i + 14)); continue
            fi
            if [ "${s:$i:12}" = '$USERPROFILE' ]; then
                case "${SC[i + 12]-}" in
                    [A-Za-z0-9_]) ;;
                    *)
                        SW_VALUE+=""'$USERPROFILE'; SW_EXPANDS_HOME=1
                        i=$((i + 12)); continue ;;
                esac
            fi
            if [ "${s:$i:7}" = '${HOME}' ]; then
                SW_VALUE+=""'${HOME}'; SW_EXPANDS_HOME=1
                i=$((i + 7)); continue
            fi
            if [ "${s:$i:5}" = '$HOME' ]; then
                case "${SC[i + 5]-}" in
                    [A-Za-z0-9_]) ;;
                    *)
                        SW_VALUE+=""'$HOME'; SW_EXPANDS_HOME=1
                        i=$((i + 5)); continue ;;
                esac
            fi
            # HIMMEL-3660: every OTHER unquoted (or double-quoted) `$`
            # expansion — bare `$VAR`, `${VAR}`, `${VAR:-default}`, `$1`,
            # `$?`, … — substitutes a runtime value this hook cannot see
            # statically. Fail closed rather than cook it as literal text.
            return 1
        fi
        SW_VALUE+="$c"; i=$((i + 1))
    done
    [ "$st" = 0 ]
}

# HIMMEL-3886: does this raw shell word carry a brace expansion — an unquoted
# `{...}` span holding an unquoted `,` or `..`? The shell turns such a word into
# several argv words, so a flag can hide in it from every literal-word match
# (`git log {--output=/tmp/PWN,-1}` runs `git log --output=/tmp/PWN -1`).
# Deliberately NOT shell_word_value: that returns early on a `$VAR`, before it
# reaches a brace later in the same word (`{$x,--output=y}`). Only quotes and
# backslash escapes are honored; every other character counts, so `${x,,}` is
# treated as a brace span too (fail closed — it only loses an allow). Unquoted
# whitespace ends a word, so a whole segment may be passed in: only space, tab
# and newline, the bytes bash itself splits on (a CR, FF or VT stays inside
# the brace word).
word_has_brace_expansion() {
    local s="$1" n i=0 c st=0 bd=0 bf=0 LC_ALL=C
    local -a SC
    n=${#s}
    split_bytes "$s" "$n"
    while [ "$i" -lt "$n" ]; do
        c="${SC[i]-}"
        if [ "$st" = 1 ]; then                       # inside single quotes
            [ "$c" = "'" ] && st=0
            i=$((i + 1)); continue
        fi
        if [ "$st" = 2 ]; then                       # inside double quotes
            case "$c" in
                "\\") i=$((i + 2)); continue ;;
                '"') st=0 ;;
            esac
            i=$((i + 1)); continue
        fi
        case "$c" in
            "'") st=1 ;;
            '"') st=2 ;;
            "\\") i=$((i + 2)); continue ;;
            ' '|$'\t'|$'\n') bd=0; bf=0 ;;           # unquoted word boundary
            '{') bd=$((bd + 1)) ;;
            '}')
                if [ "$bd" -gt 0 ]; then
                    bd=$((bd - 1))
                    [ "$bf" = 1 ] && return 0
                fi ;;
            ',') [ "$bd" -gt 0 ] && bf=1 ;;
            '.') [ "$bd" -gt 0 ] && [ "${SC[i + 1]-}" = '.' ] && bf=1 ;;
        esac
        i=$((i + 1))
    done
    return 1
}

# Tokenizes a segment and resolves the binary it actually executes: skips
# shell keywords, group tokens, redirects and leading assignments, same rules
# segment_is_safe has always used. Factored out so the HIMMEL-2121
# root-anchored-find deny check (segment_is_rootwalk_find, below) resolves
# "what runs" identically instead of re-deriving its own copy that could
# silently drift from the safety scan.
#
# Sets RB_TOKENS (full token array) and RB_STATUS:
#   empty — segment has no tokens.
#   safe  — no single resolvable binary, but not dangerous either (a
#           for/select header, or nothing executable e.g. bare `done`).
#   unsafe — a `case` body, or a leading VAR= that isn't an innocuous
#            locale/timezone var (must fall through to a prompt).
#   bin   — resolved; RB_BIN is the binary token, RB_IDX its index.
resolve_seg_binary() {
    tokenize_seg_words "$1" || { RB_TOKENS=(); RB_BIN=""; RB_IDX=-1; RB_JIRA_KEY=0; RB_STATUS=unsafe; return 0; }
    local -a a=("${RB_TOKENS[@]}")
    RB_BIN=""; RB_IDX=-1; RB_JIRA_KEY=0
    local n=${#a[@]}
    if [ "$n" -eq 0 ]; then RB_STATUS=empty; return 0; fi
    local i=0 t
    while [ "$i" -lt "$n" ]; do
        t="${a[$i]}"
        case "$t" in
            ''|'('|')'|'{'|'}'|'!'|do|then|else|elif|done|fi|'esac'|';;')
                i=$((i + 1)); continue ;;
            if|while|until)                # eval the binary that follows
                i=$((i + 1)); continue ;;
            for|select)                    # header: following words are data
                RB_STATUS=safe; return 0 ;;
            case)                          # don't parse case bodies — fall through
                RB_STATUS=unsafe; return 0 ;;
            '<'|'>'|'>>'|'<<'|'<<<'|'&>'|'&>>'|'2>'|'1>'|'2>>'|'<&'|'>&')
                i=$((i + 2)); continue ;;  # redirect operator + its target token
            [0-9]'>'*|[0-9]'<'*|'>'*|'<'*|'&>'*)
                i=$((i + 1)); continue ;;  # glued redirect (2>/dev/null, <file)
            [A-Za-z_]*=*)
                # Leading VAR=val: ONLY innocuous locale/timezone vars are
                # safe to skip. Anything else (GIT_EXTERNAL_DIFF, GIT_PAGER,
                # PAGER, GIT_SSH_COMMAND, LD_PRELOAD, NODE_OPTIONS, BASH_ENV,
                # IFS, …) can turn a "read" command into arbitrary code exec,
                # so fall through to a prompt. Allowlist > denylist here: the
                # dangerous-env-var set is open-ended.
                case "$t" in
                    LANG=*|LANGUAGE=*|LC_[A-Z]*=*|TZ=*) i=$((i + 1)); continue ;;
                esac
                # HIMMEL-4780: a bare literal JIRA_PROJECT_KEY=<KEY> only picks
                # the Jira project (as --project already may). Skipped here, but
                # segment_is_safe refuses it unless the binary is node, whose
                # branch approves the jira CLI alone.
                if [[ "$t" =~ ^JIRA_PROJECT_KEY=[A-Z][A-Z0-9_]*$ ]]; then
                    RB_JIRA_KEY=1; i=$((i + 1)); continue
                fi
                RB_STATUS=unsafe; return 0 ;;
            *) break ;;
        esac
    done
    if [ "$i" -ge "$n" ]; then RB_STATUS=safe; return 0; fi   # e.g. bare `done`
    local bin="${a[$i]}"
    bin="${bin#(}"; bin="${bin#\{}"        # strip glued group opener
    shell_word_value "$bin" || { RB_STATUS=unsafe; return 0; }
    bin="$SW_VALUE"
    if [ -z "$bin" ]; then RB_STATUS=safe; return 0; fi
    RB_STATUS=bin; RB_BIN="$bin"; RB_IDX="$i"
}

# HIMMEL-2121: does this segment run `find` with a root-anchored PATH OPERAND
# and no `-maxdepth N` anywhere? That shape walks the WHOLE disk; see header
# CONTRACT for why it is denied rather than left to an unattended prompt.
is_root_anchor() {
    local u expands_home expands_tilde
    shell_word_value "$1" || return 1
    u="$SW_VALUE"; expands_home="$SW_EXPANDS_HOME"; expands_tilde="$SW_EXPANDS_TILDE"
    # Canonicalize root-equivalent forms before matching: collapse every run
    # of consecutive `/` into one, drop a trailing `/.` (optionally followed
    # by `/`) (round 4, codex-1), and collapse runs of consecutive `\` into
    # one (round 5, codex-1) — so `///`, `/.`, `/./`, `//c/`, and a
    # double-backslash `C:\\` (common when an agent types `"C:\\"` inside
    # double quotes) all normalize to the string a plain `/`, `/c/`, or
    # `C:\` would, and can't dodge the case match below by spelling root a
    # different way.
    u=$(printf '%s' "$u" | sed -E 's@/+@/@g; s@/\.(/)?$@/@; s@\\+@\\@g')
    # shellcheck disable=SC2016,SC2088 # literal match patterns (this segment's
    # raw text), not tilde/expression expansion — the hook never eval's them.
    case "$u" in
        /|//)                     return 0 ;;  # POSIX root
        /[A-Za-z]|/[A-Za-z]/)     return 0 ;;  # MSYS drive root: /c, /c/ (NOT /c/subpath)
        [A-Za-z]:|[A-Za-z]:\\|[A-Za-z]:/) return 0 ;;  # Windows drive root: C:  C:\  C:/
        '%USERPROFILE%'|"%USERPROFILE%\\"|'%USERPROFILE%/') return 0 ;;
    esac
    if [ "$expands_tilde" -eq 1 ]; then
        # shellcheck disable=SC2088 # literal cooked forms, expansion was tracked from the raw word
        case "$u" in '~'|'~/') return 0 ;; esac
    fi
    if [ "$expands_home" -eq 1 ]; then
        # shellcheck disable=SC2016 # literal raw expansion forms, never this hook's environment
        case "$u" in
            '$HOME'|'${HOME}'|'$HOME/'|'${HOME}/'|\
            '$USERPROFILE'|'${USERPROFILE}'|'$USERPROFILE/'|'${USERPROFILE}/'|\
            "\$USERPROFILE\\"|"\${USERPROFILE}\\") return 0 ;;
        esac
    fi
    return 1
}

# Lexically normalize a literal absolute POSIX path and report only paths whose
# `.` / `..` segments reduce all the way to `/`. This deliberately does not
# inspect the filesystem, resolve symlinks, or expand variables: `/tmp/..`
# qualifies, while `/tmp/../var`, `/tmp/..hidden`, and `$HOME/..` do not.
path_textually_resolves_to_root() {
    local path="$1" part idx
    local -a parts stack=()
    case "$path" in /*) ;; *) return 1 ;; esac
    IFS='/' read -ra parts <<< "$path"
    for part in "${parts[@]}"; do
        case "$part" in
            ''|'.') ;;
            '..')
                if [ "${#stack[@]}" -gt 0 ]; then
                    idx=$((${#stack[@]} - 1)); unset "stack[$idx]"
                fi ;;
            *) stack+=("$part") ;;
        esac
    done
    [ "${#stack[@]}" -eq 0 ]
}

# HIMMEL-3734 (J1300A finding 7): a bare brace-list word (`{/,.}`) is
# uncookable to shell_word_value (HIMMEL-3660 fails closed on the internal
# comma) and so is normally treated as OPAQUE by the path-operand loop below
# — but `find {/,.} -name x` expands to `find / . -name x`, a real root walk.
# Scoped narrowly to stay obviously-correct: only a word that is ENTIRELY one
# non-nested `{...}` span counts, split on TOP-LEVEL commas, and only a
# literal `/`-only alternative is treated as root — this does not attempt to
# cook the general brace-expansion case.
brace_word_is_rootwalk() {
    local w="$1" inner part
    case "$w" in '{'*'}') ;; *) return 1 ;; esac
    inner="${w#\{}"; inner="${inner%\}}"
    case "$inner" in *'{'*|*'}'*) return 1 ;; esac
    # ponytail: nested brace words (e.g. {{/,a},b}) stay opaque here — a
    # one-level comma split, not a recursive brace-expansion parser.
    # HIMMEL-3753 tracks whether that's worth building.
    local IFS=',' norm
    for part in $inner; do
        # codex-1 (round 1): // is POSIX root too (is_root_anchor:503).
        # codex-2 (round 3): any run of slashes only (///, ////, ...) is the
        # same root — is_root_anchor gets this for free by collapsing runs of
        # `/` before its case match (line 499); this loop has no such
        # normalization pass, so match the whole class directly instead.
        case "$part" in
            '') ;;
            *[!/]*)
                # codex-1 (round 8): `/.` (and `/./`, `//.`, ...) is root too
                # — is_root_anchor's own normalization (line 499) already
                # strips a trailing `/.` before matching, so apply the same
                # sed here rather than duplicate its case logic; a part with
                # any OTHER non-slash byte (e.g. `a`, `a/.`) still falls
                # through untouched.
                norm=$(printf '%s' "$part" | sed -E 's@/+@/@g; s@/\.(/)?$@/@')
                [ "$norm" = / ] && return 0
                ;;
            *) return 0 ;;
        esac
    done
    return 1
}

segment_is_rootwalk_find() {
    resolve_seg_binary "$1"
    [ "$RB_STATUS" = bin ] || return 1
    case "$RB_BIN" in
        find|find.exe|*/find|*/find.exe) ;;
        *) return 1 ;;
    esac
    local -a a=("${RB_TOKENS[@]}")
    local total=${#a[@]} j tok val cooked has_root=0 has_maxdepth=0

    # -maxdepth N: a real -maxdepth is an OPTION immediately followed by a
    # nonempty all-digits VALUE — count it only in that shape (round 2,
    # codex-2/codex-4). A token that merely READS "-maxdepth" as some OTHER
    # primary's value (e.g. `find / -name -maxdepth`, nothing digit-shaped
    # after it) is not counted. Quotes are stripped first so `"-maxdepth" 2`
    # is recognized too. This scans every remaining token — -maxdepth is a
    # flag, not a path operand, so it may legally appear anywhere — EXCEPT
    # inside an ACTION primary's own payload: `-exec`/`-execdir`/`-ok`/
    # `-okdir` consume every following token as their OWN argument list up to
    # a terminator (`;` / `\;` / `+`), so a `-maxdepth N` sitting in there,
    # e.g. `find / -exec echo -maxdepth 2 \;`, is echo's argument, not find's
    # option, and must not count. Once the terminator is seen, RESUME
    # scanning find's OWN remaining flags (round 4, codex-4: a genuinely
    # bounded `-exec ... \; -maxdepth N` must not be denied). `-delete` takes
    # NO payload — it is a plain flag, so it is deliberately NOT in this set;
    # a `-maxdepth` after it is real.
    # HIMMEL-3660: a word `shell_word_value` cannot cook (an unquoted `$VAR`,
    # `{a,b}`, …) is treated as OPAQUE here, never as a reason to abort the
    # whole scan — an uncookable word can't literally BE `-maxdepth`, `-exec`
    # or a terminator (all fixed ASCII), so skipping it costs nothing, and
    # bailing out used to report "not a rootwalk" even when a literal root
    # path elsewhere in the same segment made it one (the HIMMEL-2121 DENY
    # this segment exists to enforce).
    j=$((RB_IDX + 1))
    while [ "$j" -lt "$total" ]; do
        if ! shell_word_value "${a[$j]}"; then
            j=$((j + 1)); continue
        fi
        tok="$SW_VALUE"
        case "$tok" in
            -exec|-execdir|-ok|-okdir)
                j=$((j + 1))
                while [ "$j" -lt "$total" ]; do
                    if ! shell_word_value "${a[$j]}"; then
                        j=$((j + 1)); continue
                    fi
                    case "$SW_VALUE" in
                        ';'|'\;'|'+') j=$((j + 1)); break ;;
                        *) j=$((j + 1)) ;;
                    esac
                done
                continue ;;
        esac
        if [ "$tok" = "-maxdepth" ]; then
            if shell_word_value "${a[$((j + 1))]:-}"; then
                val="$SW_VALUE"
                case "$val" in
                    ''|*[!0-9]*) : ;;              # empty or not all-digits → not it
                    *) has_maxdepth=1 ;;
                esac
            fi   # uncookable value ($N, {1,2}, …) → not a valid -maxdepth either
        fi
        j=$((j + 1))
    done

    # Path operands: `find [-H|-L|-P] [-D dbgopts] [-Olevel] [--] [path...]
    # [expr]` — first skip find's own leading OPTIONS (round 2, codex-1: they
    # used to hide a root path behind them, e.g. `find -L / ...`; round 4,
    # codex-3: a bare `--` option terminator is skipped here too, not treated
    # as the break that stops path-operand collection, e.g. `find -- / ...`),
    # THEN collect path operands until the first expression token (a
    # `-flag`, `(`, or `!`). A root-anchor string in an EXPRESSION arg
    # (`-name "~"`, `-path "$HOME"`) is not a path find will walk — only a
    # true path operand counts. No path operand at all → find defaults to
    # `.` → never a rootwalk.
    j=$((RB_IDX + 1))
    while [ "$j" -lt "$total" ]; do
        # HIMMEL-3660: an uncookable word can't literally be `-H`/`-D`/`-O*`/`--`
        # (all fixed ASCII) — stop skipping leading options and let the path-
        # operand loop below scan it, rather than bailing "not a rootwalk".
        if ! shell_word_value "${a[$j]}"; then
            break
        fi
        tok="$SW_VALUE"
        case "$tok" in
            -H|-L|-P) j=$((j + 1)); continue ;;
            -D)       j=$((j + 2)); continue ;;   # consumes a following debugopts arg
            -O*)      j=$((j + 1)); continue ;;   # glued optimisation level (-O2, -O3)
            --)       j=$((j + 1)); continue ;;   # find's own option terminator
            *)        break ;;
        esac
    done
    for tok in "${a[@]:$j}"; do
        # HIMMEL-3660: an opaque operand is skipped, not treated as ending
        # path-operand collection — a literal root anchor later in the same
        # segment must still be found.
        if ! shell_word_value "$tok"; then
            brace_word_is_rootwalk "$tok" && has_root=1
            continue
        fi
        cooked="$SW_VALUE"
        case "$cooked" in
            -*|'('|'!') break ;;
        esac
        is_root_anchor "$tok" && has_root=1
        path_textually_resolves_to_root "$cooked" && has_root=1
    done

    [ "$has_root" -eq 1 ] && [ "$has_maxdepth" -eq 0 ]
}

# HIMMEL-3668: a word is a redirect only when it has no quoting (raw == cooked)
# and the text before its first < or > is empty, all digits, or `&`. A glob
# like `[0-9]*>` would also match `9x<in`, where bash passes `9x` as an operand
# (an output file for uniq/xxd), so it must still count as a positional.
is_redirect_word() {
    [ "$1" = "$2" ] || return 1
    case "$2" in *'<'*|*'>'*) ;; *) return 1 ;; esac
    local pre="${2%%[<>]*}"
    [[ "$pre" =~ ^([0-9]*|&)$ ]]
}

segment_is_safe() {
    resolve_seg_binary "$1"
    # HIMMEL-4780: the JIRA_PROJECT_KEY= prefix is approvable on node only.
    if [ "$RB_JIRA_KEY" = 1 ] && { [ "$RB_STATUS" != bin ] || [ "$RB_BIN" != node ]; }; then
        return 1
    fi
    case "$RB_STATUS" in
        empty|safe) return 0 ;;
        unsafe)     return 1 ;;
    esac
    local -a a=("${RB_TOKENS[@]}")
    local n=${#a[@]} i="$RB_IDX" bin="$RB_BIN"

    if is_safe_bin "$bin"; then
        local k
        case "$bin" in
            find)                          # find can execute / delete — guard it
                for k in "${a[@]}"; do
                    shell_word_value "$k" || return 1
                    [ "$SW_HAS_UNQUOTED_GLOB" = 1 ] && return 1   # HIMMEL-3660: a glob could expand into -delete/-exec
                    case "$SW_VALUE" in
                        -exec|-execdir|-ok|-okdir|-delete|-fprint|-fprintf|-fprint0|-fls)
                            return 1 ;;
                    esac
                done ;;
            sort)                          # `sort -o FILE` writes a file, and
                                           # `--compress-program` runs one on
                                           # spill — guard both. FAIL CLOSED:
                                           # an option this can't cook or that
                                           # doesn't match a known long name
                                           # falls through to normal permission,
                                           # never a wider per-shape parse.
                for k in "${a[@]}"; do
                    shell_word_value "$k" || return 1
                    [ "$SW_HAS_UNQUOTED_GLOB" = 1 ] && return 1   # HIMMEL-3660: a glob could expand into -o/--output
                    case "$SW_VALUE" in
                        -[!-]*)
                            case "${SW_VALUE#-}" in *o*) return 1 ;; esac ;;
                        --*)
                            guard_is_long_abbrev "output" "$SW_VALUE" && return 1
                            guard_is_long_abbrev "compress-program" "$SW_VALUE" && return 1 ;;
                    esac
                done ;;
            xxd)                           # `xxd in out` / `xxd -r in out` writes
                local xops=0               # a 2nd positional = output file → write
                for k in "${a[@]:$((i + 1))}"; do
                    shell_word_value "$k" || return 1
                    [ "$SW_HAS_UNQUOTED_GLOB" = 1 ] && return 1   # HIMMEL-3660: a glob could expand into -r/-revert or a 2nd positional
                    case "$SW_VALUE" in
                        # reverse = write binary. xxd takes any `-r…` word as
                        # -r (HIMMEL-3894), so any flag word holding an r falls through.
                        -*r*) return 1 ;;
                        -*) ;;                           # other flags take no file
                        *) is_redirect_word "$k" "$SW_VALUE" || xops=$((xops + 1)) ;;  # redirect token, not a positional
                    esac
                done
                [ "$xops" -ge 2 ] && return 1 ;;         # infile + outfile = write
            uniq)                          # HIMMEL-3668: `uniq in out` — a 2nd operand
                                           # is an OUTPUT file. Value-taking options'
                                           # values are not operands.
                local uops=0 uskip=0 udd=0
                for k in "${a[@]:$((i + 1))}"; do
                    shell_word_value "$k" || return 1
                    [ "$SW_HAS_UNQUOTED_GLOB" = 1 ] && return 1   # a glob could expand into a 2nd operand
                    if [ "$uskip" = 1 ]; then uskip=0; continue; fi
                    if [ "$udd" = 1 ]; then uops=$((uops + 1)); continue; fi
                    # An unquoted redirect token is not an operand. Only a token with no
                    # quoting/escaping at all (raw == cooked) can be one: `'>out'`,
                    # `1'>'out` and `\>out` are filenames, so they stay operands.
                    is_redirect_word "$k" "$SW_VALUE" && continue
                    case "$SW_VALUE" in
                        --) udd=1 ;;
                        --*=*) ;;
                        --*) guard_is_long_abbrev "skip-fields" "$SW_VALUE" && uskip=1
                             guard_is_long_abbrev "skip-chars" "$SW_VALUE" && uskip=1
                             guard_is_long_abbrev "check-chars" "$SW_VALUE" && uskip=1 ;;
                        -?*)   # cluster: f/s/w takes the rest as its value, else the next word
                            case "${SW_VALUE#-}" in
                                *[fsw]) uskip=1 ;;
                            esac ;;
                        *) uops=$((uops + 1)) ;;
                    esac
                done
                [ "$uops" -ge 2 ] && return 1 ;;     # input + output = write
            rg|ripgrep|ag)                 # HIMMEL-3668: `--pre`/`--hostname-bin` run a
                                           # program per file, `-z` runs decompressors,
                                           # `ag --pager` runs a program. FAIL CLOSED.
                for k in "${a[@]}"; do
                    shell_word_value "$k" || return 1
                    [ "$SW_HAS_UNQUOTED_GLOB" = 1 ] && return 1   # a glob could expand into one of these
                    case "$SW_VALUE" in
                        --*)
                            guard_is_long_abbrev "pre-glob" "$SW_VALUE" && return 1
                            guard_is_long_abbrev "hostname-bin" "$SW_VALUE" && return 1
                            guard_is_long_abbrev "search-zip" "$SW_VALUE" && return 1
                            guard_is_long_abbrev "pager" "$SW_VALUE" && return 1 ;;
                        -[!-]*) case "${SW_VALUE#-}" in *z*) return 1 ;; esac ;;
                    esac
                done ;;
            tree)                          # `tree -o FILE` / `--output FILE` writes
                for k in "${a[@]}"; do
                    shell_word_value "$k" || return 1
                    [ "$SW_HAS_UNQUOTED_GLOB" = 1 ] && return 1   # HIMMEL-3660: a glob could expand into -o/--output
                    case "$SW_VALUE" in
                        --*) guard_is_long_abbrev "output" "$SW_VALUE" && return 1 ;;
                        -*) case "${SW_VALUE#-}" in *o*) return 1 ;; esac ;;  # HIMMEL-3894: clustered -o
                    esac
                done ;;
            base64)                        # BSD `base64 -o FILE` writes a file
                for k in "${a[@]}"; do
                    shell_word_value "$k" || return 1
                    [ "$SW_HAS_UNQUOTED_GLOB" = 1 ] && return 1   # HIMMEL-3660: a glob could expand into -o/--output
                    case "$SW_VALUE" in
                        --*) guard_is_long_abbrev "output" "$SW_VALUE" && return 1 ;;
                        -*) case "${SW_VALUE#-}" in *o*) return 1 ;; esac ;;  # HIMMEL-3894: clustered -o
                    esac
                done ;;
            file)                          # `file -C [-m mf]` compiles/writes <mf>.mgc
                for k in "${a[@]}"; do
                    shell_word_value "$k" || return 1
                    [ "$SW_HAS_UNQUOTED_GLOB" = 1 ] && return 1   # HIMMEL-3660: a glob could expand into -C
                    case "$SW_VALUE" in
                        --*) guard_is_long_abbrev "compile" "$SW_VALUE" && return 1 ;;
                        -*) case "${SW_VALUE#-}" in *C*) return 1 ;; esac ;;  # HIMMEL-3894: clustered -C
                    esac
                done ;;
        esac
        return 0
    fi

    case "$bin" in
        git)
            git_subcmd_is_read "${a[@]:$i}" && return 0
            # Not a read subcommand — allow ONLY a safe force-with-lease push
            # on a non-main branch (HIMMEL-212); everything else falls through.
            git_push_force_with_lease_is_safe "${a[@]:$i}"; return $? ;;
        gh)  gh_subcmd_is_read "${a[@]:$i}"; return $? ;;
        node)
            # The script node ACTUALLY runs is its first non-flag arg. It must
            # BE the dogfooded Jira CLI — not merely appear somewhere in the
            # args. Reject inline-code flags outright. (Without this a marker
            # riding along as a later arg, e.g. `node -e <code> …/index.js`,
            # would grant arbitrary code execution.)
            # HIMMEL-3886: only an ALLOWLIST of inert flags may precede the
            # script. Skipping every `-*` word let an `=`-form code loader ride
            # along (`--require=./x.js`, `--import=`, `--env-file=` feeding
            # NODE_OPTIONS, `--openssl-config=` loading an engine) — an
            # open-ended set, so no denylist is used.
            local k=$((i + 1)) scr=""
            while [ "$k" -lt "$n" ]; do
                case "${a[$k]}" in
                    --no-warnings|--no-deprecation|--trace-warnings|\
                    --trace-deprecation|--enable-source-maps) k=$((k + 1)) ;;
                    -*) return 1 ;;
                    *) scr="${a[$k]}"; break ;;
                esac
            done
            case "$scr" in
                scripts/jira/dist/index.js|*/scripts/jira/dist/index.js) return 0 ;;
            esac
            return 1 ;;
    esac
    return 1
}

# Quote-aware structural scan of a Bash command (HIMMEL-209). Walks char by
# char tracking single/double-quote state so command separators (; | || &&
# newline, bare &) and output redirects appearing INSIDE quotes are treated as
# the literal text they are — not as shell structure. The previous sed split
# was quote-blind: a newline / ';' / '>' inside a quoted jira-comment body
# shredded the command into junk segments ("LUNA-36 (catch-up) …") that failed
# is_safe_bin, so a fully-safe write fell through to the auto-mode classifier
# and was DENIED.
#
# Sets two globals, returns 1 (fail closed) on unbalanced quotes:
#   SCAN_SEGS — top-level segments (ORIGINAL text, one per line) split ONLY at
#               UNQUOTED separators. Quotes are preserved so segment_is_safe
#               still sees real args (e.g. a quoted `-delete` flag stays gated).
#   SCAN_MASK — the command with every quoted-span char (+ quote delimiters and
#               backslash-escaped chars) replaced by a space, so the existing
#               redirect detector sees only UNQUOTED '>'.
# bash 3.2-safe: only ${s:i:1}, ${#s}, arithmetic.
#
# HIMMEL-3762 (J1370A finding 2): this walk had its OWN naive backslash-newline
# collapse, independent of (and downstream from) fold_backslash_newline() —
# fixing only the top-level fold left this one still folding a comment's
# trailing backslash-newline as a continuation, hiding the real command that
# followed. `cm` tracks "inside a real # comment" using the same word-start
# (`aws`) rule as fold_backslash_newline(): a comment can start only where a
# new word can, so `$#`/`${#x}`/mid-word `#` are excluded by construction, not
# special-cased. Once cm=1, every byte is copied through as plain comment text
# (no separator, no backslash-continuation) until the terminating newline,
# which still ends the comment AND breaks the segment as it always did.
scan_cmd() {
    local s="$1" n i c nx p ppe st seg NL cm aws pesc LC_ALL=C
    local -a SC
    NL=$'\n'
    n=${#s}; i=0; st=0; cm=0; aws=1; seg=""; SCAN_SEGS=""; SCAN_MASK=""; SCAN_ESC_AMP=0; pesc=0
    split_bytes "$s" "$n"
    while [ "$i" -lt "$n" ]; do
        c="${SC[i]-}"
        # HIMMEL-3777: was s[i-1] itself the escaped byte of a `\x` pair (so it
        # is data, not a live operator char)? Captured before this iteration's
        # own escape branch (if any) resets pesc for the NEXT iteration.
        ppe="$pesc"; pesc=0
        if [ "$st" = 1 ]; then                       # inside single quotes
            seg+="${c/"$NL"/ }"; SCAN_MASK+=" "
            [ "$c" = "'" ] && st=0
            aws=0
            i=$((i + 1)); continue
        fi
        if [ "$st" = 2 ]; then                       # inside double quotes
            if [ "$c" = "\\" ]; then                 # \<x> keeps next char literal
                nx="${SC[i + 1]-}"
                if [ "$nx" = "$NL" ]; then          # line continuation: remove both bytes
                    SCAN_MASK+="  "; i=$((i + 2)); continue
                fi
                seg+="${c/"$NL"/ }${nx/"$NL"/ }"; SCAN_MASK+="  "
                aws=0; pesc=1; i=$((i + 2)); continue
            fi
            seg+="${c/"$NL"/ }"; SCAN_MASK+=" "
            [ "$c" = '"' ] && st=0
            aws=0
            i=$((i + 1)); continue
        fi
        # --- unquoted ---
        nx="${SC[i + 1]-}"
        if [ "$cm" = 1 ] && [ "$c" = "$NL" ]; then   # a newline always ends a comment
            cm=0
            SCAN_SEGS+="$seg$NL"; seg=""
            SCAN_MASK+="$c"; aws=1; i=$((i + 1)); continue
        fi
        case "$c" in
            "'")
                if [ "$cm" = 1 ]; then                   # inside a comment: no quote semantics
                    seg+="$c"; SCAN_MASK+="$c"; aws=0; i=$((i + 1)); continue
                fi
                st=1; seg+="$c"; SCAN_MASK+=" "; aws=0; i=$((i + 1)); continue ;;
            '"')
                if [ "$cm" = 1 ]; then                   # inside a comment: no quote semantics
                    seg+="$c"; SCAN_MASK+="$c"; aws=0; i=$((i + 1)); continue
                fi
                st=2; seg+="$c"; SCAN_MASK+=" "; aws=0; i=$((i + 1)); continue ;;
            '#')
                [ "$aws" = 1 ] && cm=1
                seg+="$c"; SCAN_MASK+="$c"; aws=0; i=$((i + 1)); continue ;;
            "\\")
                if [ "$cm" = 1 ]; then               # inside a comment: no continuation fold
                    seg+="$c"; SCAN_MASK+="$c"; aws=0; i=$((i + 1)); continue
                fi
                if [ "$nx" = "$NL" ]; then          # line continuation: remove both bytes
                    SCAN_MASK+="  "; i=$((i + 2)); continue
                fi
                # HIMMEL-3793 (J1397A finding 4): keep the backslash itself
                # LITERAL in SCAN_MASK (blank only the escaped byte it
                # protects). Blanking both to spaces made an escaped CR (or a
                # trailing backslash) right after an fd-dup digit look like a
                # genuine word boundary to the :1571 strip below — but to real
                # bash the backslash keeps that byte glued to the word, so
                # `>&2\<CR>` opens a real file named "2\r", not fd 2. A raw
                # backslash is never itself a boundary char nor a separator
                # any downstream SCAN_MASK consumer looks for, so this cannot
                # newly satisfy any of them — it can only stop a false match.
                # An unquoted `\&` is a literal & word byte, not a separator —
                # but it lands as an operand real tools may treat as an output
                # file (`uniq -c f \&` creates `&`). Flag it so the walk's
                # caller falls through instead of approving.
                [ "$nx" = '&' ] && SCAN_ESC_AMP=1
                seg+="${c/"$NL"/ }${nx/"$NL"/ }"; SCAN_MASK+="\\ "; aws=0; pesc=1; i=$((i + 2)); continue ;;
            ';'|"$NL")                               # statement separator
                SCAN_SEGS+="$seg$NL"; seg=""
                SCAN_MASK+="$c"; aws=1; i=$((i + 1)); continue ;;
            '|')                                     # | or || → one break
                SCAN_SEGS+="$seg$NL"; seg=""
                SCAN_MASK+="|"; aws=1
                if [ "$nx" = '|' ]; then SCAN_MASK+="|"; i=$((i + 2)); else i=$((i + 1)); fi
                continue ;;
            '&')
                if [ "$nx" = '&' ]; then             # && logical-AND → break
                    SCAN_SEGS+="$seg$NL"; seg=""
                    SCAN_MASK+="&&"; aws=1; i=$((i + 2)); continue
                fi
                if [ "$nx" = '>' ]; then             # &> redirect form → keep with seg
                    seg+="$c"; SCAN_MASK+="&"; aws=0; i=$((i + 1)); continue
                fi
                p=""; [ "$i" -gt 0 ] && p="${SC[i - 1]-}"
                # HIMMEL-3777: a raw '>'/'<'/'&' immediately before is only a
                # live fd-dup neighbor when it was NOT itself the escaped
                # payload of a preceding `\x` — otherwise `\&&` reads its
                # escaped first & as a false fd-dup partner for the second,
                # LIVE &, hiding it from the bare-& break below.
                if [ "$ppe" != 1 ]; then
                    case "$p" in                     # fd-dup 2>&1 / >&2 → keep
                        '>'|'<'|'&') seg+="$c"; SCAN_MASK+="&"; aws=0; i=$((i + 1)); continue ;;
                    esac
                fi
                SCAN_SEGS+="$seg$NL"; seg=""    # bare & separator → break
                SCAN_MASK+="&"; aws=1; i=$((i + 1)); continue ;;
        esac
        seg+="$c"; SCAN_MASK+="$c"
        case "$c" in
            ' '|$'\t'|'('|')'|'<'|'>') aws=1 ;;
            *) aws=0 ;;
        esac
        i=$((i + 1))
    done
    [ "$st" = 0 ] || return 1                        # unbalanced quote → fail closed
    SCAN_SEGS+="$seg"
    return 0
}

# HIMMEL-3131: is this segment EXACTLY one `queue-lock.sh` lock verb?
#   [HANDOVER_DIR=<root>] bash [<repo>/]scripts/handover/queue-lock.sh
#       acquire <doc> | release|heartbeat <doc> [<token>] | status <doc>
#       | status --sweep [<dir>]
# WHY: the shape is not a merge — it writes one lock dir under the handover
# root and touches no git ref — but `bash` is not a safe binary and a leading
# HANDOVER_DIR= is not an innocuous assignment, so it fell through to the
# auto-mode classifier, which read a just-landed merge in the narrative and
# denied `release` as [Merge Without Review]. Deliberately NOT wired into
# segment_is_safe: the caller approves it only when it is the WHOLE command, so
# a queue-lock segment inside a compound (`x && …`, `x | …`, `… ; …`) still
# falls through. HANDOVER_DIR is the only env prefix accepted, so
# QUEUE_LOCK_FORCE_RELEASE=1 (a console action) can never ride along.
# Every value must be a literal: no expansion, no glob, no `..`, doc absolute
# and `.md`, doc under HANDOVER_DIR when one is given. "Absolute" is `/x`, `/c/x`
# or a Git-Bash drive path `C:/x` (ql_abs_path, HIMMEL-3192) — in the
# HANDOVER_DIR, doc and sweep positions only, which name a lock dir and are
# never executed.
# The script is the relative `scripts/handover/queue-lock.sh` or a `/`-rooted
# path (HIMMEL-3494: no drive letter, `\` or `'`); either way the checkout it
# resolves into must be a real one of this repo (ql_root_is_own_checkout) — for
# the relative form that is the payload `cwd`, which must be absolute (never the
# hook's own $PWD), since bash resolves it there.
# ponytail: HANDOVER_DIR is not checked against the registered handover root —
# a stray root only lets queue-lock write a `.locks/queue/` dir there — and the
# relative form only accepts a cwd that IS a checkout root: from a sub-directory
# (where the relative path would not resolve anyway) it falls through to a prompt.
# On Windows Git Bash a drive-letter payload cwd or script path also falls
# through to a prompt (as cmd_is_impacted_suites does, HIMMEL-3486).
ql_word_literal() {   # $1 raw word → QW (cooked); fails on any expansion/glob/`..`
    case "$1" in *'$'*) return 1 ;; esac
    shell_word_value "$1" || return 1
    QW="$SW_VALUE"
    case "$QW" in
        *'~'*|*'*'*|*'?'*|*'['*|*']'*|*'{'*|*'}'*|*'!'*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*|*'('*|*')'*|*'`'*|*' '*) return 1 ;;
        ..|../*|*/..|*/../*) return 1 ;;
    esac
    [ -n "$QW" ]
}

# HIMMEL-3192: the ONE absolute-path helper for every path position (the
# HANDOVER_DIR value, the script, the `status --sweep` dir, the doc). $1 is a
# cooked word; fails unless it is absolute and `..`-free. Accepts a slash-prefixed
# POSIX/MSYS path (`/x`, `/c/x`) or a Git-Bash drive-letter path (`C:/x`, `c:\x`).
# Sets QN — the canonical spelling every containment comparison uses (a drive
# path becomes `/<lower-case drive>/…`, so `C:/x` and `/c/x` are equal and a
# drive spelling cannot dodge containment) — and QC, the spelling `cd` is given.
# A backslash is a separator only in a drive path; a `/`-prefixed path carrying
# one is refused, since MSYS reads it as a separator that would hide a `..`.
# ponytail: on a POSIX host `C:/x` is really a cwd-relative name, which is why
# segment_is_queue_lock refuses it in the executed script position (HIMMEL-3494)
# and only lets it name a lock dir; the drive-relative `C:x`, UNC `//host/x` and an upper-case `/C/x` are
# not accepted (they fall through to a prompt).
ql_abs_path() {
    local p="$1" d
    case "$p" in
        [A-Za-z]:[/\\]*)
            p=$(printf '%s' "$p" | tr "\\\\" '/')
            d=$(printf '%s' "${p%%:*}" | tr '[:upper:]' '[:lower:]')
            QC="$p"; QN="/$d${p#?:}" ;;
        //*) return 1 ;;   # slash-form UNC (`//host/share`) is a remote share under Git Bash
        /*)
            case "$p" in *"\\"*) return 1 ;; esac
            QC="$p"; QN="$p" ;;
        *) return 1 ;;
    esac
    case "$QN" in */..|*/../*) return 1 ;; esac
    return 0
}

# Is <root> a real checkout of THIS repo — the checkout this hook lives in, or
# one of its `git worktree list` siblings (the primary checkout included) — that
# actually holds queue-lock.sh? A lookalike `/tmp/x/scripts/handover/queue-lock.sh`
# (even one that exists) is not, so it falls through. Both sides of every
# comparison go through ql_abs_path (HIMMEL-3192), so the drive letter's case or
# a `C:/x` vs `/c/x` spelling can neither dodge nor defeat it.
ql_root_is_own_checkout() {
    local real here wt wts
    real=$(cd "$1" 2>/dev/null && pwd -P) || return 1
    [ -f "$real/scripts/handover/queue-lock.sh" ] || return 1
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P) || return 1
    ql_abs_path "$real" || return 1; real="$QN"
    ql_abs_path "$here" || return 1; here="$QN"
    [ "$real" = "$here" ] && return 0
    wts=$(git -C "$here" worktree list --porcelain 2>/dev/null) || return 1
    while IFS= read -r wt; do
        case "$wt" in "worktree "*) ;; *) continue ;; esac
        wt=$(cd "${wt#worktree }" 2>/dev/null && pwd -P) || continue
        ql_abs_path "$wt" || continue
        [ "$QN" = "$real" ] && return 0
    done <<EOF
$wts
EOF
    return 1
}

segment_is_queue_lock() {
    tokenize_seg_words "$1" || return 1
    local -a a=("${RB_TOKENS[@]}")
    local n=${#a[@]} i=0 hd="" hr verb doc ql_cwd
    [ "$n" -ge 3 ] || return 1
    case "${a[0]}" in
        HANDOVER_DIR=*)
            ql_word_literal "${a[0]#HANDOVER_DIR=}" || return 1
            ql_abs_path "$QW" || return 1
            # HIMMEL-3198: a root (`/`, empty once stripped) reads below as "no
            # handover dir given", and a bare drive root (`C:/` → `/c`) contains a
            # whole drive — neither may stand in for a handover dir.
            hr="$QN"; while [ "${hr%/}" != "$hr" ]; do hr="${hr%/}"; done
            # A `.` component spells the same root (`/.`, `/c/.`, `/./`), so it is refused too.
            case "$hr" in ""|/[A-Za-z]|*/.|*/./*) return 1 ;; esac
            hd="${QN%/}"
            i=1 ;;
    esac
    [ "${a[$i]:-}" = "bash" ] || return 1
    # HIMMEL-3494: no `\` or `'` in the script word, and no drive letter — on
    # POSIX `C:\x\…` or `C:/x/…` is checked as one path but run as a
    # cwd-relative file bash finds by its literal name.
    case "${a[$((i + 1))]:-}" in *\\*|*\'*) return 1 ;; esac
    ql_word_literal "${a[$((i + 1))]:-}" || return 1
    case "$QW" in
        scripts/handover/queue-lock.sh)
            # Relative: bash resolves it against the session cwd, so that cwd
            # must itself be a real checkout. Only an absolute payload `.cwd`,
            # never the hook's own $PWD. Read lazily (this rare path only) so
            # the hot path keeps its single jq call.
            ql_cwd=$(jq -r '.cwd // ""' <<<"$input" 2>/dev/null) || return 1
            case "$ql_cwd" in /*) ;; *) return 1 ;; esac
            ql_root_is_own_checkout "$ql_cwd" || return 1 ;;
        /*)
            ql_abs_path "$QW" || return 1
            case "$QN" in /*/scripts/handover/queue-lock.sh) ;; *) return 1 ;; esac
            ql_root_is_own_checkout "${QC%/scripts/handover/queue-lock.sh}" || return 1 ;;
        *) return 1 ;;
    esac
    verb="${a[$((i + 2))]:-}"
    i=$((i + 3))
    local rest=$((n - i))
    if [ "$verb" = "status" ] && [ "${a[$i]:-}" = "--sweep" ]; then
        [ "$rest" -le 2 ] || return 1
        if [ "$rest" -eq 2 ]; then
            ql_word_literal "${a[$((i + 1))]}" || return 1
            ql_abs_path "$QW" || return 1
        fi
        return 0
    fi
    [ "$rest" -ge 1 ] || return 1
    ql_word_literal "${a[$i]}" || return 1
    ql_abs_path "$QW" || return 1
    doc="$QN"
    case "$doc" in *.md) ;; *) return 1 ;; esac
    [ -z "$hd" ] || case "$doc" in "$hd"/*) ;; *) return 1 ;; esac
    case "$verb" in
        acquire|status) [ "$rest" -eq 1 ] ;;
        release|heartbeat)
            [ "$rest" -le 2 ] || return 1
            [ "$rest" -eq 1 ] && return 0
            ql_word_literal "${a[$((i + 1))]}" || return 1
            case "$QW" in *[!A-Za-z0-9._-]*) return 1 ;; esac ;;
        *) return 1 ;;
    esac
}

# HIMMEL-3486: is the WHOLE command one of /pr-check step 3.6's literals?
#   bash <P> <40hex>..<40hex>
#   bash <P> --check <40hex>..<40hex>
#   bash <P> --check <40hex>..<40hex> <<'IMPACTED_EOF'
#   SUITE ...            (zero or more lines, each starting `SUITE `)
#   IMPACTED_EOF
# <P> is `scripts/cr/impacted-suites.sh` (resolved against the payload cwd,
# which must be absolute; never the hook's own $PWD) or a `/`-rooted
# `<root>/scripts/cr/impacted-suites.sh`, bare or double-quoted. No `\`, `'` or
# drive letter: on POSIX `C:\x\…` or `C:/x/…` is checked as one path but run as
# a cwd-relative file bash finds by its literal name. WHY: the step is a
# required gate, and the classifier denied the listing as [Out-of-Place Publication], parking the leg. Read off the RAW
# command, ahead of scan_cmd and the tripwires: the heredoc body is inert data
# (its delimiter is quoted, so nothing in it expands), and a SKIP reason may
# carry an apostrophe or `$(`. Only a line starting `SUITE ` sits between the
# opener and the one closing `IMPACTED_EOF`, so no body line can close the
# heredoc early and nothing runs after it.
# The script is branch-editable and a gate, so the bytes that run must be the
# anchor's (HIMMEL-3383 precedent, guard-pr-check-literal.sh): <root> is a
# worktree root whose git-common-dir is $HIMMEL_REPO/.git, and its
# impacted-suites.sh (a regular file, not a symlink) hashes, unfiltered, to the
# same blob as both the anchor's working-tree copy and refs/heads/main's, with
# the anchor on refs/heads/main. The script sources nothing, so that one file
# is every byte it runs.
# ponytail: checked at match time only - the bytes can change between this
# check and the exec (TOCTOU), as in guard-pr-check-literal.sh; and a
# docs-audit lane's `origin/main..<head>` range is not accepted (it falls
# through to the classifier); and Windows Git Bash always falls through to a
# prompt (its jq.exe CRLF output, drive-letter cwd and paths are all refused).
IS_LINE1_RE="^bash +(\"[^\"]*\"|[^ \"]+) +(--check +)?[0-9a-f]{40}\\.\\.[0-9a-f]{40}( +<<'IMPACTED_EOF')? *\$"
cmd_is_impacted_suites() {
    local c="${1%$'\n'}" l1 body word root
    case "$c" in *$'\r'*) return 1 ;; esac
    l1="${c%%$'\n'*}"
    case "$l1" in *[[:cntrl:]]*) return 1 ;; esac
    [[ "$l1" =~ $IS_LINE1_RE ]] || return 1
    word="${BASH_REMATCH[1]}"
    if [ -n "${BASH_REMATCH[3]}" ]; then
        [ -n "${BASH_REMATCH[2]}" ] || return 1
        body="${c#*$'\n'}"
        [ "$body" != "$c" ] || return 1
        case "$body" in IMPACTED_EOF) body="" ;; *$'\n'IMPACTED_EOF) body="${body%$'\n'IMPACTED_EOF}" ;; *) return 1 ;; esac
        [ -z "$body" ] || while IFS= read -r l; do
            case "$l" in 'SUITE '*) ;; *) return 1 ;; esac
            case "$l" in *[[:cntrl:]]*) return 1 ;; esac
        done <<EOF
$body
EOF
        [ -z "$body" ] || case "$body" in *$'\n'IMPACTED_EOF|*$'\n'IMPACTED_EOF$'\n'*) return 1 ;; esac
    else
        case "$c" in *$'\n'*) return 1 ;; esac
    fi
    case "$word" in *\\*|*\'*) return 1 ;; esac
    ql_word_literal "$word" || return 1
    case "$QW" in
        scripts/cr/impacted-suites.sh)
            root=$(jq -r '.cwd // ""' <<<"$input" 2>/dev/null) || return 1
            case "$root" in /*) ;; *) return 1 ;; esac ;;
        /*)
            ql_abs_path "$QW" || return 1
            case "$QN" in /*/scripts/cr/impacted-suites.sh) ;; *) return 1 ;; esac
            root="${QC%/scripts/cr/impacted-suites.sh}" ;;
        *) return 1 ;;
    esac
    impacted_suites_is_anchored "$root"
}

impacted_suites_is_anchored() {   # $1 root — subshell: the unsets stay local
    (
        unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_REPLACE_REF_BASE
        g() { git --no-replace-objects -c core.fsmonitor=false -c core.untrackedCache=false "$@" 2>/dev/null; }
        f=scripts/cr/impacted-suites.sh
        repo="${HIMMEL_REPO:-}"; repo="${repo%/}"
        [ -n "$repo" ] || exit 1
        anchor_git=$(cd -P "$repo/.git" 2>/dev/null && pwd -P) || exit 1
        root=$(cd -P "$1" 2>/dev/null && pwd -P) || exit 1
        common=$(g -C "$root" rev-parse --path-format=absolute --git-common-dir) || exit 1
        common=$(cd -P "$common" 2>/dev/null && pwd -P) || exit 1
        [ "$common" = "$anchor_git" ] || exit 1
        prefix=$(g -C "$root" rev-parse --show-prefix) || exit 1
        [ -z "$prefix" ] || exit 1
        [ -f "$root/$f" ] && [ ! -L "$root/$f" ] && [ -f "$repo/$f" ] && [ ! -L "$repo/$f" ] || exit 1
        [ "$(g -C "$repo" symbolic-ref -q HEAD)" = refs/heads/main ] || exit 1
        want=$(g -C "$repo" rev-parse --verify -q "refs/heads/main:$f") || exit 1
        [ -n "$want" ] || exit 1
        [ "$(g -C "$repo" hash-object --no-filters -- "$f")" = "$want" ] || exit 1
        [ "$(g -C "$root" hash-object --no-filters -- "$f")" = "$want" ]
    )
}

emit_allow() {
    local reason
    # HIMMEL-2123: `jq -n --arg r "<text>" '$r'` JSON-encodes the exact string
    # in ONE jq call with no piped input at all — no `printf` fork feeding it
    # (a herestring/pipe here would also risk a spurious trailing-newline
    # byte inside the encoded string, which `-Rs` slurp mode would have kept
    # literally; `--arg` passes the value as-is, unchanged).
    reason=$(jq -n --arg r "auto-approve-safe-bash: $1" '$r' 2>/dev/null) || reason='"safe read-only command"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":%s}}\n' "$reason"
    exit 0
}

# HIMMEL-2121: the one DENY carve-out — see header CONTRACT.
emit_deny() {
    local reason
    reason=$(jq -n --arg r "auto-approve-safe-bash: $1" '$r' 2>/dev/null) || reason='"denied: root-anchored find with no -maxdepth"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
    exit 0
}

# --- Fail open on anything we cannot evaluate ---
command -v jq >/dev/null 2>&1 || exit 0
# HIMMEL-2610 F2 (J1267O): is_safe_bin's write-flag checks (sort/tree/base64
# --output, file --compile) call guard_is_long_abbrev/guard_long_opt_name to
# recognize an abbreviated OR full long option the same way GNU getopt_long
# does. The HIMMEL-2121 root-walk `find` DENY below does NOT need lib.sh, so
# an `|| exit 0` on a missing lib.sh used to withdraw that DENY too, not just
# abbreviation recognition. Define local fallbacks first — sourcing lib.sh,
# when it succeeds, simply overwrites them with its own (identical) copies —
# so a missing lib.sh only narrows abbreviation recognition, never DENY.
guard_long_opt_name() {
    local tok="$1" rest
    rest="${tok#--}"
    # shellcheck disable=SC2034 # GUARD_LOPT_VAL/GUARD_LOPT_HAS_EQ kept for parity with lib.sh's real guard_long_opt_name; this file's caller only needs GUARD_LOPT_NAME
    case "$rest" in
        *=*) GUARD_LOPT_NAME="${rest%%=*}"; GUARD_LOPT_VAL="${rest#*=}"; GUARD_LOPT_HAS_EQ=1 ;;
        *)   GUARD_LOPT_NAME="$rest"; GUARD_LOPT_VAL=""; GUARD_LOPT_HAS_EQ=0 ;;
    esac
}
guard_is_long_abbrev() {
    local full="$1" tok="$2"
    guard_long_opt_name "$tok"
    [ -n "$GUARD_LOPT_NAME" ] || return 1
    case "$full" in
        "$GUARD_LOPT_NAME"*) return 0 ;;
        *) return 1 ;;
    esac
}
# HIMMEL-3750 judge J1370A (NO-GO, round 3->4): the naive `${cmd//$'\\\n'/}`
# fold treated every backslash-newline pair as a continuation, even when the
# backslash itself was already escaped by a PRECEDING backslash (`\\<NL>`: the
# shell consumes the first two backslashes as one literal `\`, so the newline
# that follows is a real, unescaped command separator, not a continuation).
# That let `echo \\<NL>touch PWN` fold into a single harmless-looking `echo`
# line while the shell actually ran `touch PWN` as a second command — a
# non-approved command turned into an auto-APPROVE. Only an ODD run of
# backslashes immediately before the newline is a genuine continuation (the
# last backslash is unescaped); an even run pairs off completely and the
# newline stays a real separator, so leave it unfolded and let the existing
# unquoted-separator/newline handling see it. Single quotes give backslash no
# special meaning at all, so no fold happens inside them either.
#
# HIMMEL-3750 round 6 (codex-1): a `'` is only a single-quote DELIMITER when
# not already inside double quotes — real shells nest quoting that way, so
# `"'$\<NL>(touch PWN)"` has a literal apostrophe, not a quote open, and the
# backslash-newline after it still folds (double quotes fold it same as
# unquoted text). The old check toggled in_sq on ANY `'`, double-quoted or
# not, so that literal apostrophe wrongly entered "single-quote" mode and
# suppressed the fold for the rest of the string (no closing `'` ever came),
# leaving the raw-text `$(` tripwire unable to see the reconstituted `$(`.
# Track double-quote state too so a `'` inside `"..."` stays inert.
# HIMMEL-3750 round 7 (codex-1): a `"` (or `'`) immediately after an ODD
# backslash run is an ESCAPED quote character in real shell parsing — it
# stays a literal byte and never opens/closes a quoted region (`\"` inside
# double quotes writes a literal `"` without closing the string; `\'`
# outside any quotes writes a literal apostrophe without opening one). The
# old code let the backslash branch consume only the backslash run and then
# let the next loop iteration process the quote character with its
# unconditional/`in_dq==0`-gated toggle, with no memory that a backslash had
# just escaped it. `echo "\"'$\<NL>(touch PWN)"` exploited exactly that: the
# escaped `"` wrongly flipped in_dq from 1 to 0, which then let the
# following literal (still-inside-real-double-quotes) apostrophe wrongly
# open the code's own fake single-quote mode, which suppressed the
# backslash-newline fold for the rest of the string and hid the
# reconstituted `$(` from the raw-text tripwire. Detect an escaped quote
# right where the backslash run is measured and copy it through untouched.
#
# HIMMEL-3762 (J1370A finding 2): a real `#` comment ends at the very next
# newline UNCONDITIONALLY — the shell never honors a trailing backslash as a
# continuation of comment text, no matter how many backslashes precede the
# newline. The old walk had no comment state at all, so `# note \<NL>rm -rf x`
# folded the newline away and let `rm -rf x` ride inside the (approved) `#`
# comment of the first segment. Track `aws` ("at word start": true at the
# start of the string and right after whitespace or a structural operator —
# `;|&()<>` or newline) and open a real comment only when an unquoted `#`
# lands there — exactly bash's own "a word beginning with # is a comment"
# rule. That rule alone disambiguates the three shapes HIMMEL-3762 called
# out without any special-casing: `$#` and `${#x}` fail the word-start test
# on the `$`/`{` immediately before the `#`, and a mid-word `#` (`foo#bar`)
# fails it on the preceding letter — all three fall through as plain
# characters, same as real bash. Once inside a comment, every byte (including
# backslashes) is copied through verbatim until the terminating newline,
# which is copied too and never folded.
fold_backslash_newline() {
    local s="$1" out="" i=0 n c j run k nc in_sq=0 in_dq=0 in_cm=0 aws=1 bs=$'\\' LC_ALL=C
    local -a SC
    n=${#s}
    split_bytes "$s" "$n"
    while [ "$i" -lt "$n" ]; do
        c="${SC[i]-}"
        if [ "$in_cm" = 1 ]; then
            out+="$c"
            if [ "$c" = $'\n' ]; then
                in_cm=0
                aws=1
            fi
            i=$((i + 1))
            continue
        fi
        if [ "$in_sq" = 1 ]; then
            out+="$c"
            [ "$c" = "'" ] && in_sq=0
            aws=0
            i=$((i + 1))
            continue
        fi
        if [ "$c" = "'" ] && [ "$in_dq" = 0 ]; then
            in_sq=1
            out+="$c"
            aws=0
            i=$((i + 1))
            continue
        fi
        if [ "$c" = '"' ]; then
            [ "$in_dq" = 0 ] && in_dq=1 || in_dq=0
            out+="$c"
            aws=0
            i=$((i + 1))
            continue
        fi
        if [ "$c" = '#' ] && [ "$in_dq" = 0 ] && [ "$aws" = 1 ]; then
            in_cm=1
            out+="$c"
            i=$((i + 1))
            continue
        fi
        if [ "$c" = "$bs" ]; then
            run=0
            j=$i
            while [ "${SC[j]-}" = "$bs" ]; do
                run=$((run + 1))
                j=$((j + 1))
            done
            if [ "${SC[j]-}" = $'\n' ] && [ $((run % 2)) -eq 1 ]; then
                # An odd run of N backslashes folds in real shell parsing as
                # the final lone backslash+newline being the continuation
                # that disappears, leaving the other (N-1, always even)
                # backslashes RAW rather than pre-collapsed to (N-1)/2
                # literal backslash bytes here. Pre-collapsing them handed
                # scan_cmd's own backslash-escape walk a single
                # already-resolved backslash byte indistinguishable from a
                # fresh, still-escaping one, so it swallowed the next real
                # character (e.g. a `;` separator) as if it were escaped
                # when it was not (HIMMEL-3750 round 5, codex-1). Left raw,
                # scan_cmd re-derives the same even pairing bash does on its
                # own and correctly leaves the following character
                # unescaped.
                k=0
                while [ "$k" -lt "$((run - 1))" ]; do
                    out+="\\"
                    k=$((k + 1))
                done
                [ "$run" -gt 1 ] && aws=0
                i=$((j + 1))
                continue
            fi
            nc="${SC[j]-}"
            if [ $((run % 2)) -eq 1 ] && { [ "$nc" = "'" ] || [ "$nc" = '"' ]; }; then
                k=0
                while [ "$k" -lt "$((run - 1))" ]; do
                    out+="\\"
                    k=$((k + 1))
                done
                out+="\\$nc"
                aws=0
                i=$((j + 1))
                continue
            fi
            k=0
            while [ "$k" -lt "$run" ]; do
                out+="\\"
                k=$((k + 1))
            done
            aws=0
            i=$j
            continue
        fi
        out+="$c"
        case "$c" in
            ' '|$'\t'|$'\n'|';'|'|'|'&'|'('|')'|'<'|'>') aws=1 ;;
            *) aws=0 ;;
        esac
        i=$((i + 1))
    done
    printf '%s' "$out"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
[ -r "$SCRIPT_DIR/../guardrails/lib.sh" ] && . "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null
# HIMMEL-2123: bash builtin `read` instead of `$(cat)` drops one spawn.
input=""
IFS= read -r -d '' input 2>/dev/null || true
[ -n "$input" ] || exit 0
# tool_name + command in ONE jq call (via `<<<`, no printf fork) instead of
# two separate `printf | jq` pipelines — same shape already proven in
# require-quiet-run.sh (HIMMEL-2060) and block-tail-pipe-on-gates.sh
# (HIMMEL-2123). Windows jq.exe writes CRLF, so strip the stray CR off $tool.
# `// ""` (empty STRING), not `// empty` (a zero-output jq GENERATOR): in a
# `+`-concatenation, one operand collapsing to `empty` zeroes out the WHOLE
# expression (cross-product-of-generators semantics), not just that field.
result=$(jq -r '(.tool_name // "") + "\n" + (.tool_input.command // "")' <<<"$input" 2>/dev/null) || exit 0
tool="${result%%$'\n'*}"
# HIMMEL-3773/HIMMEL-3776 (judge J1387A): `tool` is jq's own first output
# line and never legitimately contains a CR — a trailing CR on it means jq
# itself is rendering every LF in `result` as CRLF (Windows jq.exe), so the
# SAME rendering also doubled every embedded newline in `cmd` below. Detect
# that here, before stripping the CR off `tool`.
case "$tool" in
    *$'\r') win_crlf=1 ;;
    *) win_crlf=0 ;;
esac
tool="${tool%$'\r'}"
cmd="${result#*$'\n'}"
# J1397A finding 1: on the CRLF-jq (Windows) rendering, jq.exe's OWN final
# newline also comes out as CRLF, but the `<<<`/`$()` substitution above
# strips only the trailing LF, leaving a stray, unpaired CR on the end of
# every command (nothing to fold: no CRLF pair remains to match). That is
# jq's own artifact, not part of the command bash will see, so strip exactly
# one trailing CR here -- before the boundary checks further down that would
# otherwise treat it as a hostile CR right after a redirect target (e.g.
# `cmd 2>&1` arriving as `cmd 2>&1<CR>`) and refuse the whole command. A
# CRAFTED trailing CR (HIMMEL-3782) arrives DOUBLED under this same
# rendering, so one copy survives this strip and is still caught below.
[ "$win_crlf" = 1 ] && cmd="${cmd%$'\r'}"
# Only touch cmd when it actually contains a CR (HIMMEL-3773/J1387A finding
# 3: skip the fold entirely on CR-free input — no-op on the common case,
# avoiding the added cost on large CR-free heredocs).
case "$cmd" in
    *$'\r'*)
        if [ "$win_crlf" = 1 ]; then
            # Windows jq.exe rendering: every LF became CRLF, including the
            # LF of a genuine `\`+LF continuation, so a blind fold back to
            # LF (main's original behavior) is correct here — it restores
            # exactly what the shell will actually execute. A CRAFTED
            # `\`+CR arrives doubled as `\`+CR+CR+LF; this fold consumes only
            # the trailing CR+LF, leaving `\`+CR+LF, which
            # fold_backslash_newline()/scan_cmd() correctly read as a
            # non-continuation (backslash precedes CR, not LF).
            cmd="${cmd//$'\r\n'/$'\n'}"
        fi
        # Native jq: `cmd` already carries the exact bytes bash will see.
        # Real bash gives CR no special meaning and only LF ends a
        # statement/continuation, so folding anything here would be the
        # HIMMEL-3773 bug (turning a backslash-preceded CR+LF into a
        # continuation that hides the command after the CR) — never fold.
        ;;
esac
# HIMMEL-3886 (judge, PR 1468): the tokenizers below split on [[:space:]],
# but bash splits words only on space, tab and newline, so a raw FF or VT
# makes them see different words than the shell runs. No allow for those
# bytes. CR is left to tokenize_seg_words' ponytail note (CRLF inputs must
# keep their verdict, test-crlf-boundary.sh).
# HIMMEL-4967: abstain AFTER the root-walk DENY below, never before it -- an
# early exit would downgrade that deny to no opinion.
abstain=0
case "$cmd" in
    *[$'\f\v']*) abstain=1 ;;
esac
# HIMMEL-4752 (judge j2011): U+2028 (LINE SEPARATOR, bytes e2 80 a8) is a word
# character to bash but a space to some tokenizers; abstain rather than guess.
case "$cmd" in
    *$'\xe2\x80\xa8'*) abstain=1 ;;
esac
# HIMMEL-3750 round 3 (codex-1): a backslash-newline continuation is folded
# away by the shell before parsing even INSIDE double quotes, so a quoted
# `"$\<NL>=x"` reaches the shell as `"$=x"` — the raw-text tripwires below
# must see the same joined text the shell will actually execute, not the
# literal backslash-newline bytes (which never match `*'$='*` etc). Fold it
# here, before scan_cmd, so both the structural scan and the tripwires agree.
# Judge J1370A (round 4): a NAIVE fold of every `\`+newline pair is wrong when
# the backslash is itself escaped by a preceding one — see
# fold_backslash_newline()'s header comment above for why only an odd
# backslash run is a genuine continuation.
cmd="$(fold_backslash_newline "$cmd")"
[ "$tool" = "Bash" ] || exit 0   # PowerShell keeps its own native rules
[ -n "$cmd" ] || exit 0

# HIMMEL-3486: /pr-check step 3.6's impacted-suites.sh literals, read off the
# raw command before scan_cmd (see cmd_is_impacted_suites) — the jq text as it
# came, before the CRLF→LF fold above, so any CR at all refuses it.
case "$cmd" in
    bash*impacted-suites.sh*)
        [ "$abstain" = 0 ] && cmd_is_impacted_suites "${result#*$'\n'}" && emit_allow "pr-check impacted-suites literal (HIMMEL-3486): ${cmd%%$'\n'*}" ;;
esac

# Quote-aware structural scan (HIMMEL-209): produces SCAN_SEGS (split only at
# UNQUOTED separators) + SCAN_MASK (quoted spans blanked). Fail closed if the
# quotes are unbalanced — better to fall through to a prompt than mis-parse.
scan_cmd "$cmd" || exit 0

# Bash ANSI-C ($'...') and locale ($"...") quotes can encode or rewrite values
# at runtime, so no static token value is trustworthy enough for ALLOW or DENY.
# Fail open before both classification paths; an over-match only prompts.
case "$cmd" in *'$"'*|*"$'"*) exit 0 ;; esac

# --- HIMMEL-2121: deny a root-anchored `find` with no -maxdepth ---
# Fires on EVERY segment, deliberately BEFORE the global tripwires below
# (round 2, codex-3): a command carrying $(...)/`` /<()/>() used to fall
# through those tripwires first and never reach this deny, so
# `find / -iname $(hostname)` was silently let through to a prompt instead
# of denied. The deny never APPROVES anything, so running it ahead of the
# tripwires cannot make the hook less safe — it only widens what gets caught.
# Also fires ahead of the redirect/safe-segment scan further below, so it
# catches the shape even when a later segment would merely fall through to a
# prompt — headless/cadence sessions leave that prompt unattended, and the
# orphaned whole-disk walker outlives its dead parent (specimen: 20+ min,
# saturated the spawn path). Bypass: FIND_ROOTWALK_OK set to a truthy value
# (1/true/yes/on) in the LAUNCHING shell.
case "${FIND_ROOTWALK_OK:-}" in
    1|true|yes|on) ;;  # explicit truthy bypass — skip the deny scan entirely
    *)
        while IFS= read -r seg; do
            seg="${seg#"${seg%%[! $'\t']*}"}"   # ltrim space/tab only (HIMMEL-5034)
            [ -z "$seg" ] && continue
            if segment_is_rootwalk_find "$seg"; then
                emit_deny "a root-anchored find with no -maxdepth walks the WHOLE disk and can outlive its parent for 20+ minutes in headless/cadence sessions, where the fall-through prompt is unattended (HIMMEL-2121). Use the Glob tool, or scope it to a repo-rooted directory: find <dir> ... -maxdepth N. One-run bypass: set FIND_ROOTWALK_OK=1 in the LAUNCHING shell."
            fi
        done <<EOF
$SCAN_SEGS
EOF
        ;;
esac

# HIMMEL-4967: the deny scan is done; the FF/VT/U+2028 abstain applies now.
[ "$abstain" = 1 ] && exit 0

# --- Global tripwires: never auto-approve dynamic execution / file writes ---
# shellcheck disable=SC2016 # the single-quoted $( etc. are literal match patterns, not expansions
case "$cmd" in
    *'$('*|*'`'*|*'<('*|*'>('*)        exit 0 ;;  # command / process substitution
    *'system('*|*'popen('*|*'exec('*)  exit 0 ;;  # interpreter shell-out
esac

# HIMMEL-3750 (J1366A finding 1): zsh parameter-flag expansions reach code
# execution or defeat quoting even inside double quotes, so SCAN_MASK's
# quoted-span blanking never sees them — this must check the RAW $cmd text,
# not the mask. Refuse unconditionally, quoted or not:
#   - `${(...)`  — the `(e)`/`(#)`/`(%)`/... parameter flags. `(e)` re-
#     evaluates its value (arbitrary code), and nested `(#):-N` flags build
#     `$(` from character codes, hiding it from the tripwire above even
#     unquoted. VERIFIED (zsh -f): `echo "${(e)${:-${(#):-36}${(#):-40}touch
#     P${(#):-41}}}"` runs `touch P`.
#   - `$=` / `${=` — the SH_WORD_SPLIT flag forces field-splitting on the
#     substituted value EVEN INSIDE DOUBLE QUOTES, so a quoted `"$=x"` can
#     still explode into several argv words, one of which can be a flag
#     (`ls "$=x"` with x="-l /etc/passwd" runs `ls -l /etc/passwd`).
#     VERIFIED (zsh -f).
# `${~...}` (the GLOB_SUBST flag) was checked too: quoted, it does NOT glob
# (VERIFIED zsh -f) — quoting still protects it, so it is not a new bypass
# and is left alone.
# shellcheck disable=SC2016 # literal raw-text match patterns, nothing expanded
case "$cmd" in
    *'${('*|*'$='*|*'${='*)  exit 0 ;;
esac

# HIMMEL-3732 / HIMMEL-3733 (J1300A findings 6,7): an unquoted `(` in ANY word
# is zsh glob-qualifier (`f(e:'cmd':)` — arbitrary code under zsh defaults) or
# grouping-glob (`(-)oPWNED` — a real write) syntax, independent of which
# binary carries it — so this refuses GLOBALLY, not only in the six
# write-guarded arms (HIMMEL-3660). SCAN_MASK already blanks quoted spans and
# backslash-escaped chars to spaces, so any '(' surviving in it is a genuinely
# unquoted, unescaped one. Strip the constructs the tripwire above and
# elsewhere already own — $((...)), $(...), <(...), >(...) — before checking,
# since those are handled cases, not this one. Longest-first so stripping
# "$((" doesn't leave a stray "(" from a truncated "$(" match.
# shellcheck disable=SC2016 # literal match patterns, not expansions
paren_mask="$SCAN_MASK"
paren_mask="${paren_mask//"\$(("/}"
paren_mask="${paren_mask//"\$("/}"
paren_mask="${paren_mask//"<("/}"
paren_mask="${paren_mask//">("/}"
case "$paren_mask" in *'('*) exit 0 ;; esac

# Output redirect to a real file → not safe. Strip /dev/null sinks + fd-dups first.
# Anchor /dev/null to a token boundary so `>/dev/null.bak` (a real file) is
# NOT mistaken for the sink and stripped. Run on SCAN_MASK so a '>' inside a
# quoted argument (e.g. a comment body) is not mistaken for a real redirect.
#      HIMMEL-3782 (J1387B): the fd-dup strip below requires a real word
#      boundary right after the target digit — space/tab/newline or one of
#      the separators scan_cmd itself treats as live (`;|&`), or end of
#      string. A CR is deliberately EXCLUDED from that boundary class: to
#      real bash, `>&2<CR>` is `>&word` with word == "2<CR>" (not the digit
#      2, since CR is just an ordinary byte to bash, not a separator), so
#      bash opens/creates a REAL FILE named "2<CR>" instead of duplicating
#      fd 2. Requiring the boundary means that shape no longer matches here,
#      so its `>` survives into $rd and falls through to the same
#      not-auto-approved path as any other real-file redirect.
rd=$(printf '%s' "$SCAN_MASK" | sed -E \
    -e 's@&?>>?[[:space:]]*/dev/null([[:space:]]|$)@ @g' \
    -e 's@[0-9]*>>?[[:space:]]*/dev/null([[:space:]]|$)@ @g' \
    -e 's@[0-9]*>&[0-9]([[:blank:];|&]|$)@ @g')
case "$rd" in *'>'*) exit 0 ;; esac

# HIMMEL-3793 (J1397A finding 4): an unquoted backslash-escaped `&` is a
# literal operand byte, which real tools may treat as an output file
# (`uniq -c f \&` creates `&`, `uniq -c f a\&\&b` creates `a&&b`). Uniform
# fall-through here (after the deny scans, so a DENY still wins) — no
# per-binary logic, an earlier uniq-specific guard kept yielding bypasses.
[ "$SCAN_ESC_AMP" = 1 ] && exit 0

# HIMMEL-3886: a brace expansion in ANY word of ANY segment never reaches an
# allow — one central refusal ahead of every arm below (queue-lock, git, gh,
# node, the safe-bin set), not a per-arm patch. Each arm matches flags on
# literal words, and a brace word explodes into argv words none of them saw.
# The HIMMEL-2121 deny scan above runs first, so a braced root walk still
# DENIES. The whole segment is scanned, not tokenize_seg_words' tokens: that
# tokenizer splits at a backslash-space (the `find C:\ ` drive-root spelling),
# while the shell keeps `{--output=a\ b,-1}` one word and expands it.
while IFS= read -r seg; do
    word_has_brace_expansion "$seg" && exit 0
done <<EOF
$SCAN_SEGS
EOF

# --- Every segment must be safe ---
# Segments come from scan_cmd's quote-aware walk (SCAN_SEGS): split on | || &&
# ; newlines and a bare `&` separator, but ONLY where they appear UNQUOTED. A
# bare `&` IS a real command separator: `cat a & rm b` runs `rm b`, so the
# segment after it must also be vetted; fd redirections that contain `&`
# (`2>&1`, `>&2`, `&>file`) are kept intact, and separators inside quotes are
# left as literal text. Segment text retains its quotes so the per-binary
# guards (find -delete, sort -o, …) still see real flag values.
# HIMMEL-3131: a queue-lock.sh lock verb is approved ONLY as the whole command
# (exactly one segment) — see segment_is_queue_lock. "Exactly one non-empty
# segment" is not enough: scan_cmd emits an EMPTY segment after a trailing (or
# before a leading) separator and the count below skips it, so `… status <doc> &`
# (which backgrounds the op), `…;`, `… &&`, `… |` and a trailing newline would all
# pass as a lone command. SCAN_MASK keeps every UNQUOTED separator (quoted spans
# are blanked), so any of them in it disqualifies the carve-out outright.
ql_unquoted_sep=0
case "$SCAN_MASK" in *';'*|*'|'*|*'&'*|*$'\n'*) ql_unquoted_sep=1 ;; esac
ql_segs=0; ql_only=""
while IFS= read -r seg; do
    seg="${seg#"${seg%%[![:space:]]*}"}"   # ltrim
    [ -z "$seg" ] && continue
    ql_segs=$((ql_segs + 1)); ql_only="$seg"
done <<EOF
$SCAN_SEGS
EOF
if [ "$ql_unquoted_sep" -eq 0 ] && [ "$ql_segs" -eq 1 ] && segment_is_queue_lock "$ql_only"; then
    emit_allow "queue-lock.sh lock verb (HIMMEL-3131): $cmd"
fi

all_safe=1
while IFS= read -r seg; do
    seg="${seg#"${seg%%[![:space:]]*}"}"   # ltrim
    [ -z "$seg" ] && continue
    if ! segment_is_safe "$seg"; then all_safe=0; break; fi
done <<EOF
$SCAN_SEGS
EOF

[ "$all_safe" = "1" ] && emit_allow "$cmd"
exit 0
