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
#   * NEVER blocks, NEVER denies. Worst case it stays silent and the
#     command falls through to the normal permission flow (prompt in
#     interactive, abort in headless) — identical to this hook not
#     existing. It therefore FAILS OPEN: missing jq, unparseable input,
#     anything-not-provably-safe → silent `exit 0`, no decision emitted.
#   * It only ever EMITS "allow". The existing destructive deny-list and
#     the block-* deny hooks remain the hard backstop: per CC docs a deny
#     rule and an exit-2 hook WIN over a hook "allow". So auto-approving
#     `cat *`/`grep *` here cannot defeat block-read-secrets (that hook
#     exits 2 on a secret read; its decision takes precedence).
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
#      allow-listed in .claude/settings.json).
#   Variable expansion in ARGUMENTS (`cat $f`, `… get $t`) is fine — the
#   binary (argv[0]) is still a literal so we know what runs. If the binary
#   ITSELF is a variable (`$cmd …`) it is not in the safe set → falls
#   through. That is the simple_expansion case we deliberately approve:
#   the risk is the binary, not the loop variable.
#
# Known residual (accepted; gate targets accidental hangs, not a determined
# attacker — the deny-list + block-* hooks are the security backstop):
#   * Quoted operators (`grep "a|b" f`) over-split into segments and may
#     fall through to a prompt. That errs SAFE (prompt), never toward a
#     wrong approval.
#
# No bypass env var — there is nothing to bypass (the hook only grants).
# To DISABLE, comment it out in .claude/settings.json.
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

# git read-only subcommands (no mutating form). Deliberately EXCLUDES
# branch/tag/remote/config/worktree/stash/reflog/notes (have write forms)
# and commit/push/pull/merge/rebase/checkout/reset/clean (mutating) — those
# fall through to the normal prompt + deny-list.
git_subcmd_is_read() {
    local -a g=("$@")            # g[0] == git
    local n=${#g[@]} j=1 t
    while [ "$j" -lt "$n" ]; do  # skip global flags (some take a separate arg)
        t="${g[$j]}"
        case "$t" in
            # Exec sinks — `-c diff.external=cmd`, `-c core.pager=cmd`, config
            # injection, and `--exec-path` (relocates git's subcommand dir).
            # NEVER auto-approve these; fall through to a prompt.
            -c|--config-env|--config-env=*|--exec-path|--exec-path=*) return 1 ;;
            --git-dir=*|--work-tree=*|--namespace=*) j=$((j + 1)); continue ;;  # =form: no separate arg
            -C|--git-dir|--work-tree|--namespace) j=$((j + 2)); continue ;;     # space form: skip arg
            -*) j=$((j + 1)); continue ;;
            *) break ;;
        esac
    done
    [ "$j" -ge "$n" ] && return 1
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
        local sj=$((j + 1)) ops=0 w
        while [ "$sj" -lt "$n" ]; do
            w="${g[$sj]}"
            case "$w" in -*) ;; *) ops=$((ops + 1)) ;; esac
            sj=$((sj + 1))
        done
        [ "$ops" -ge 2 ] && return 1   # name + value = write form
    fi
    # Even on a read subcommand, reject subcommand-level exec / file-write flags:
    #   --output[=F] (diff/log/show write to a file)   --ext-diff (runs diff.external)
    #   -O[cmd] / --open-files-in-pager[=cmd] (git grep execs a pager command)
    #   --textconv / --filters (run gitattributes-configured filter commands)
    local f
    for f in "${g[@]}"; do
        case "$f" in
            --output|--output=*|-O|-O*|--open-files-in-pager|--open-files-in-pager=*|\
            --ext-diff|--textconv|--filters)
                return 1 ;;
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
    # Skip git global flags to land on the subcommand. Exec-sink flags
    # (-c / --exec-path) are rejected outright (same set as git_subcmd_is_read).
    while [ "$j" -lt "$n" ]; do
        t="${g[$j]}"
        case "$t" in
            -c|--config-env|--config-env=*|--exec-path|--exec-path=*) return 1 ;;
            --git-dir=*|--work-tree=*|--namespace=*) j=$((j + 1)); continue ;;
            -C|--git-dir|--work-tree|--namespace) j=$((j + 2)); continue ;;
            -*) j=$((j + 1)); continue ;;
            *) break ;;
        esac
    done
    [ "$j" -ge "$n" ] && return 1
    [ "${g[$j]}" = "push" ] || return 1
    local has_lease=0 has_bare_force=0 targets_main=0 k
    for k in "${g[@]:$((j + 1))}"; do
        case "$k" in
            --force-with-lease|--force-with-lease=*) has_lease=1 ;;
            --force|-f)                              has_bare_force=1 ;;
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
    for k in "${g[@]}"; do       # `--web`/`-w` launches a browser → not read
        case "$k" in --web|-w) return 1 ;; esac
    done
    while [ "$j" -lt "$n" ]; do  # leading global flags → group word
        case "${g[$j]}" in -*) j=$((j + 1)) ;; *) break ;; esac
    done
    local grp="${g[$j]:-}"
    k=$((j + 1))
    while [ "$k" -lt "$n" ]; do  # flags between group and verb
        case "${g[$k]}" in -*) k=$((k + 1)) ;; *) break ;; esac
    done
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

segment_is_safe() {
    local -a a
    # shellcheck disable=SC2206 # intentional word split for tokenisation
    IFS=' ' read -ra a <<< "$1"
    local n=${#a[@]}
    [ "$n" -eq 0 ] && return 0
    local i=0 t
    # Skip shell keywords, group tokens, redirects and leading assignments
    # to land on the binary that this segment actually executes.
    while [ "$i" -lt "$n" ]; do
        t="${a[$i]}"
        case "$t" in
            ''|'('|')'|'{'|'}'|'!'|do|then|else|elif|done|fi|'esac'|';;')
                i=$((i + 1)); continue ;;
            if|while|until)                # eval the binary that follows
                i=$((i + 1)); continue ;;
            for|select)                    # header: following words are data
                return 0 ;;
            case)                          # don't parse case bodies — fall through
                return 1 ;;
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
                    *) return 1 ;;
                esac ;;
            *) break ;;
        esac
    done
    [ "$i" -ge "$n" ] && return 0          # nothing executable (e.g. bare `done`)
    local bin="${a[$i]}"
    bin="${bin#(}"; bin="${bin#\{}"        # strip glued group opener
    [ -z "$bin" ] && return 0

    if is_safe_bin "$bin"; then
        local k
        case "$bin" in
            find)                          # find can execute / delete — guard it
                for k in "${a[@]}"; do
                    case "$k" in
                        -exec|-execdir|-ok|-okdir|-delete|-fprint|-fprintf|-fprint0|-fls)
                            return 1 ;;
                    esac
                done ;;
            sort)                          # `sort -o FILE` writes a file — guard it
                for k in "${a[@]}"; do
                    case "$k" in
                        -o|--output|-o*|--output=*) return 1 ;;
                    esac
                done ;;
            xxd)                           # `xxd in out` / `xxd -r in out` writes
                local xops=0               # a 2nd positional = output file → write
                for k in "${a[@]:$((i + 1))}"; do
                    case "$k" in
                        -r|-revert) return 1 ;;          # reverse = write binary
                        [0-9]*'>'*|[0-9]*'<'*|'>'*|'<'*|'&>'*) ;;  # redirect token, not a positional
                        -*) ;;                           # other flags take no file
                        *) xops=$((xops + 1)) ;;
                    esac
                done
                [ "$xops" -ge 2 ] && return 1 ;;         # infile + outfile = write
            tree)                          # `tree -o FILE` / `--output FILE` writes
                for k in "${a[@]}"; do
                    case "$k" in -o|--output|-o*|--output=*) return 1 ;; esac
                done ;;
            base64)                        # BSD `base64 -o FILE` writes a file
                for k in "${a[@]}"; do
                    case "$k" in -o|--output|-o*|--output=*) return 1 ;; esac
                done ;;
            file)                          # `file -C [-m mf]` compiles/writes <mf>.mgc
                for k in "${a[@]}"; do
                    case "$k" in -C|--compile) return 1 ;; esac
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
            local k=$((i + 1)) scr=""
            while [ "$k" -lt "$n" ]; do
                case "${a[$k]}" in
                    -e|--eval|-p|--print|-) return 1 ;;
                    -*) k=$((k + 1)) ;;
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
scan_cmd() {
    local s="$1" n i c nx p st seg NL
    NL=$'\n'
    n=${#s}; i=0; st=0; seg=""; SCAN_SEGS=""; SCAN_MASK=""
    while [ "$i" -lt "$n" ]; do
        c="${s:$i:1}"
        if [ "$st" = 1 ]; then                       # inside single quotes
            seg="$seg${c/"$NL"/ }"; SCAN_MASK="$SCAN_MASK "
            [ "$c" = "'" ] && st=0
            i=$((i + 1)); continue
        fi
        if [ "$st" = 2 ]; then                       # inside double quotes
            if [ "$c" = "\\" ]; then                 # \<x> keeps next char literal
                nx="${s:$((i + 1)):1}"
                seg="$seg${c/"$NL"/ }${nx/"$NL"/ }"; SCAN_MASK="$SCAN_MASK  "
                i=$((i + 2)); continue
            fi
            seg="$seg${c/"$NL"/ }"; SCAN_MASK="$SCAN_MASK "
            [ "$c" = '"' ] && st=0
            i=$((i + 1)); continue
        fi
        # --- unquoted ---
        nx="${s:$((i + 1)):1}"
        case "$c" in
            "'") st=1; seg="$seg$c"; SCAN_MASK="$SCAN_MASK "; i=$((i + 1)); continue ;;
            '"') st=2; seg="$seg$c"; SCAN_MASK="$SCAN_MASK "; i=$((i + 1)); continue ;;
            "\\") seg="$seg${c/"$NL"/ }${nx/"$NL"/ }"; SCAN_MASK="$SCAN_MASK  "; i=$((i + 2)); continue ;;
            ';'|"$NL")                               # statement separator
                SCAN_SEGS="$SCAN_SEGS$seg$NL"; seg=""
                SCAN_MASK="$SCAN_MASK$c"; i=$((i + 1)); continue ;;
            '|')                                     # | or || → one break
                SCAN_SEGS="$SCAN_SEGS$seg$NL"; seg=""
                SCAN_MASK="$SCAN_MASK|"
                if [ "$nx" = '|' ]; then SCAN_MASK="$SCAN_MASK|"; i=$((i + 2)); else i=$((i + 1)); fi
                continue ;;
            '&')
                if [ "$nx" = '&' ]; then             # && logical-AND → break
                    SCAN_SEGS="$SCAN_SEGS$seg$NL"; seg=""
                    SCAN_MASK="$SCAN_MASK&&"; i=$((i + 2)); continue
                fi
                if [ "$nx" = '>' ]; then             # &> redirect form → keep with seg
                    seg="$seg$c"; SCAN_MASK="$SCAN_MASK&"; i=$((i + 1)); continue
                fi
                p=""; [ "$i" -gt 0 ] && p="${s:$((i - 1)):1}"
                case "$p" in                         # fd-dup 2>&1 / >&2 → keep
                    '>'|'<'|'&') seg="$seg$c"; SCAN_MASK="$SCAN_MASK&"; i=$((i + 1)); continue ;;
                esac
                SCAN_SEGS="$SCAN_SEGS$seg$NL"; seg=""    # bare & separator → break
                SCAN_MASK="$SCAN_MASK&"; i=$((i + 1)); continue ;;
        esac
        seg="$seg$c"; SCAN_MASK="$SCAN_MASK$c"; i=$((i + 1))
    done
    [ "$st" = 0 ] || return 1                        # unbalanced quote → fail closed
    SCAN_SEGS="$SCAN_SEGS$seg"
    return 0
}

emit_allow() {
    local reason
    reason=$(printf '%s' "auto-approve-safe-bash: $1" | jq -Rs . 2>/dev/null) || reason='"safe read-only command"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":%s}}\n' "$reason"
    exit 0
}

# --- Fail open on anything we cannot evaluate ---
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat 2>/dev/null || true)
[ -n "$input" ] || exit 0
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
[ "$tool" = "Bash" ] || exit 0   # PowerShell keeps its own native rules
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$cmd" ] || exit 0

# --- Global tripwires: never auto-approve dynamic execution / file writes ---
# shellcheck disable=SC2016 # the single-quoted $( etc. are literal match patterns, not expansions
case "$cmd" in
    *'$('*|*'`'*|*'<('*|*'>('*)        exit 0 ;;  # command / process substitution
    *'system('*|*'popen('*|*'exec('*)  exit 0 ;;  # interpreter shell-out
esac

# Quote-aware structural scan (HIMMEL-209): produces SCAN_SEGS (split only at
# UNQUOTED separators) + SCAN_MASK (quoted spans blanked). Fail closed if the
# quotes are unbalanced — better to fall through to a prompt than mis-parse.
scan_cmd "$cmd" || exit 0

# Output redirect to a real file → not safe. Strip /dev/null sinks + fd-dups first.
# Anchor /dev/null to a token boundary so `>/dev/null.bak` (a real file) is
# NOT mistaken for the sink and stripped. Run on SCAN_MASK so a '>' inside a
# quoted argument (e.g. a comment body) is not mistaken for a real redirect.
rd=$(printf '%s' "$SCAN_MASK" | sed -E \
    -e 's@&?>>?[[:space:]]*/dev/null([[:space:]]|$)@ @g' \
    -e 's@[0-9]*>>?[[:space:]]*/dev/null([[:space:]]|$)@ @g' \
    -e 's@[0-9]*>&[0-9]@ @g')
case "$rd" in *'>'*) exit 0 ;; esac

# --- Every segment must be safe ---
# Segments come from scan_cmd's quote-aware walk (SCAN_SEGS): split on | || &&
# ; newlines and a bare `&` separator, but ONLY where they appear UNQUOTED. A
# bare `&` IS a real command separator: `cat a & rm b` runs `rm b`, so the
# segment after it must also be vetted; fd redirections that contain `&`
# (`2>&1`, `>&2`, `&>file`) are kept intact, and separators inside quotes are
# left as literal text. Segment text retains its quotes so the per-binary
# guards (find -delete, sort -o, …) still see real flag values.
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
