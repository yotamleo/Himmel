#!/usr/bin/env bash
# block-chokepoint-env-prefix.sh -- PreToolUse hook (matcher "Bash|PowerShell"):
# DENY env-prefixed invocations of the REGISTERED sanctioned chokepoints
# (HIMMEL-1746).
#
# The sanctioned chokepoints (scripts/chokepoints.json -- one registry, one
# reader; the chokepoint paths x their seam variables live THERE, never
# hardcoded here, because a predicate written twice drifts: PR #1680's
# moonshot fence bypass and #1691's openrouter first-match-wins bug were both
# that defect class) hold standing permission allow-rules so an autonomous
# session may run them unattended. Each also accepts behavior-changing ENV
# OVERRIDES -- test seams and opt-ins (e.g. STOP_WORKER_BRIDGE_ROOT_OVERRIDE
# on stop-worker.sh, PR #1679; ARMAUTOMERGE on merge-on-green.sh). A per-call
# prefix
#     VAR=x bash scripts/handover/merge-on-green.sh
# cannot match the literal allow-rule (the native permission matcher bails
# on VAR= shapes, HIMMEL-203), so it falls through to classifier judgment.
# This guard gives that class its structural home: registered seams are
# denied HERE, with an actionable message, instead of resting on the
# classifier. It is a belt for the sanctioned SET only -- NOT a general
# env-var ban -- and it does not rewrite the chokepoints themselves.
# (Judge context, PR #1679 final panel: an env-prefixed forge of the
# registry adds no marginal capability -- script-internal process
# termination is already hook-invisible for any self-authored script -- so
# this is posture, not an exploit fix.)
#
# INVARIANT (HIMMEL-1746 CR rounds 1+2 -- four findings, ONE class): a
# chokepoint is recognized ONLY when its registered path is the
# INVOKED-PROGRAM TOKEN of a command segment -- the shell word standing at
# the segment's command position after TOKENIZING the segment (quote-,
# escape-, and redirection-aware) and stepping over leading assignment
# words and recognized wrappers (env / eval / command / exec / nohup, an
# interpreter word bash / sh / . / source, grouping keywords) -- and a
# seam assignment counts ONLY when it is a leading assignment word (or an
# env/eval-carried assignment) of that SAME segment. Both failure
# directions of the old predicate are structurally impossible under this
# rule: a path in argument position is not the invoked-program token, so
# over-match cannot happen; and word identity comes from the tokenizer,
# not from an enumerated boundary character set, so there is no boundary
# list to leave a character out of -- under-match by "unlisted separator"
# cannot happen either. All four round-1/2 findings were instances of
# violating exactly this invariant: substring-searching a string, then
# patching the characters around the match.
#
# HIMMEL-1803 (the env option arm): the scanner's model of `env` is
# DERIVED FROM env's real option grammar (the ENV_LONG_OPTS table below),
# not from an enumerated list of spellings -- three CR rounds of "add the
# spelling the last round missed" (-S, then the clustered -vS, then the
# separate operand of --unset / --chdir / --argv0) were one class, and
# this closed it as a class. For every option env accepts, the table
# records exactly one thing: what that option does to the words after it
# (nothing / consumes a data operand, separate or "="-attached /
# re-tokenizes its operand into a command line). Long names match
# exactly or by unique abbreviation (GNU getopt's long-option rule);
# "--" -- and the lone "-" operand -- ENDS option parsing, after which
# every word is assignments-then-command, never an option; and anything
# the table does not resolve gets the documented conservative DEFAULT
# (assume the option MAY consume an operand), so no spelling, known or
# future, can silently park command position on a would-be operand.
#
# HIMMEL-1803 round 4 completed that invariant's two missing halves.
# The SHORT-cluster arm had no conservative default at all (an unknown
# letter returned "unknown", a bare word-skip) and lacked GNU's -a
# (the short spelling of --argv0): both are the long arm's default now.
# And a -S / --split-string operand does NOT re-enter a fresh shell
# command scan -- GNU env tokenizes the string (shell-like quoting and
# escapes plus the documented "\_" argument separator) and feeds the
# produced argv, with the CLI words after the operand appended, back
# through env's OWN option parsing (coreutils src/env.c,
# parse_split_string): a leading -i / -u / -C inside the string is an
# env OPTION, never the invoked program. scan_split_argv is that model.
#
# HIMMEL-1803 round 6 named the property the whole family had been
# violating piecemeal: the scan is a positional SIMULATION of the argv
# each interpreter in the chain (shell, env, env's -S splitter) really
# receives, so every hand-off between stages must be ARGV-FAITHFUL --
# word count, word order, and word content INCLUDING ZERO-LENGTH WORDS
# -- and every consumption decision must come from the grammar of the
# interpreter that actually consumes the word. Rounds 1-4 were grammar
# infidelities (operand consumption mis-modelled); round 6 was a
# REPRESENTATION infidelity: the word streams between stages were bare
# newline-delimited lines, and a zero-length word is indistinguishable
# from no word in that encoding (and $(...) strips trailing newlines),
# so empty words -- which GNU env's -S splitter really produces from
# '' / "" and which real getopt really consumes as operands (env -a ''
# ARM=1 cmd runs cmd WITH the seam; verified on coreutils env) -- were
# silently dropped, shifting every later word's role. That mis-denied
# as often as it mis-allowed (an empty word standing AT command
# position means nothing can exec, which is the allow direction).
# Closed structurally: every word line in every stream now carries a
# one-character ':' sentinel prefix (a zero-length word is the line
# ':'), producers always emit it, consumers always strip it, and the
# two-line verdict protocols detect a missing second line instead of
# misreading the verdict as the operand. No stage can drop or invent
# a word again without breaking the encoding visibly.
#
# The round-2 '(' carve-out is CLOSED: an unquoted '(' / ')' / backtick
# (and `$(` / backtick inside double quotes) opens a fresh command
# position via segmentation, so subshell, $(...), and backtick-wrapped
# invocations are recognized. Known residual (documented, unchanged
# posture -- the determined-bypass class this belt does not target,
# HIMMEL-912; the classifier still sees these commands): deliberately
# case-varied paths/vars, a path assembled from shell variables ($X.sh),
# PowerShell-native $env: syntax, sudo / xargs / find -exec wrappers,
# multi-statement command substitutions inside double quotes, and string
# reconstruction deeper than the bounded eval / `bash -c` recursion.
#
# DENY CHANNELS: structured permissionDecision:"deny" JSON on stdout (which
# overrides the exit code where parsed) PLUS exit 2 + stderr -- the
# belt-and-braces idiom; see orchestrator-inline-guard.sh (HIMMEL-1791) and
# test-block-glm-external-writes.sh round 4.
#
# FAIL-OPEN POSTURE: this guard is a belt AROUND chokepoints whose bare
# invocations are already governed by allow-rules + the classifier. Every
# unresolvable input -- missing jq, missing/unparseable registry, empty
# command, unexpected internal error -- ALLOWS. The deny fires only on
# positive evidence (registry entry + invoked-program match + registered
# seam assignment in the same segment). A broken registry must never brick
# the sanctioned bare invocations it exists to protect. Where the
# tokenizer mis-parses an exotic shape, it degrades toward quoted words
# and non-matching segments -- the allow direction -- never toward a
# spurious deny of a bare invocation.
#
# Bypass: set ENV_PREFIX_GUARD_OK=1 in the shell that launched Claude Code
# (Claude cannot inject env vars into hook processes; a per-call prefix
# does NOT reach a hook). Session-sticky; restart without it to re-enable.
# Or comment the hook out in .claude/settings.json.
#
# Env knobs (optional):
#   ENV_PREFIX_GUARD_OK=1   launching-shell bypass (see above)
#   CHOKEPOINT_REGISTRY     registry path override (test seam; default
#                           scripts/chokepoints.json, resolved beside this
#                           hook's parent directory)
#
# Hook input arrives on stdin as JSON. Exit codes:
#   0 - allow (default, fail-open)
#   2 - deny; stderr + the stdout JSON carry the reason
#
# bash 3.2-compatible (no ${var,,}, no mapfile, no associative arrays;
# plain indexed arrays only). ASCII only.
set -uo pipefail

warn() { echo "block-chokepoint-env-prefix: $*" >&2; }

if [ "${ENV_PREFIX_GUARD_OK:-0}" = "1" ]; then
    exit 0
fi

command -v jq >/dev/null 2>&1 || { warn "jq not on PATH -- allowing (fail-open, no gate)"; exit 0; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${CHOKEPOINT_REGISTRY:-$SCRIPT_DIR/../chokepoints.json}"

# HIMMEL-2123: bash builtin `read` instead of `$(cat)`.
input=""
IFS= read -r -d '' input 2>/dev/null || true
[ -n "$input" ] || exit 0

# HIMMEL-2123: tool_name + command in ONE jq call (via `<<<`, no printf fork)
# instead of two separate `printf | jq` pipelines. `// ""` (empty STRING),
# not `// empty` (a zero-output jq GENERATOR): in a `+`-concatenation, one
# operand collapsing to `empty` zeroes out the WHOLE expression, not just
# that field -- and this hook's case arm allows tool=="" through on purpose,
# so silently blanking $cmd here would have been a real behavior change, not
# a coincidental no-op like in the sibling hooks. Windows jq.exe writes
# CRLF, so strip the stray CR off $tool (same shape as require-quiet-run.sh,
# HIMMEL-2060).
# RETASK R2123A (independent review): `|tostring` on both operands -- a
# NON-STRING but present field (e.g. `"command":["x"]`) makes jq's `+` a
# type error, a DIFFERENT failure than "field is null" and swallowed by the
# same `|| true`, silently blanking tool AND cmd. `tostring` is a no-op on
# an already-string value.
result=$(jq -r '((.tool_name // "")|tostring) + "\n" + ((.tool_input.command // .tool_input.cmd // "")|tostring)' <<<"$input" 2>/dev/null || true)
tool="${result%%$'\n'*}"
tool="${tool%$'\r'}"
cmd="${result#*$'\n'}"
case "$tool" in
    Bash|PowerShell|"") ;;
    *) exit 0 ;;
esac

[ -n "$cmd" ] || exit 0

# Backslash-newline is a line CONTINUATION -- join it BEFORE the newline
# fold below, or the continuation's two halves land in different segments
# and hide one logical command (found while ratcheting the round-2 fix).
# A backslash-newline inside single quotes is joined too; that mis-parse
# direction is a quoted word, which never reaches command position.
cmd="${cmd//\\$'\r\n'/}"
cmd="${cmd//\\$'\n'/}"
# Fold remaining newlines/CRs to ';' so each line is its own segment (same
# fold as block-destructive-commands.sh). HIMMEL-2123: `<<<` instead of a
# `printf |` feed drops one more fork -- segment_cmd/tokenize_seg are a
# character-by-character walk with no `$`-anchored regex depending on
# cmd_flat's exact trailing byte, so a herestring's synthetic trailing
# newline (folded to one more trailing ';', consumed as an empty final
# segment) is harmless here.
cmd_flat=$(tr '\n\r' ';;' <<<"$cmd")

if [ ! -f "$REGISTRY" ]; then  # fail-open-ok: deliberate posture — "no registry → no gate" is this hook's documented stance; an existing-but-unreadable registry is NOT caught here (-f is a plain existence test), it falls through to the jq check below, which fails closed... to the SAME allow branch (jq cannot open it either), so the outcome is identical either way
    warn "registry not found at $REGISTRY -- allowing (fail-open, no gate)"
    exit 0
fi
if ! jq -e 'type == "object"' "$REGISTRY" >/dev/null 2>&1; then  # fail-open-ok: catches an unreadable-but-existing registry too (jq cannot open it) — same documented no-registry posture as above
    warn "registry at $REGISTRY is not a JSON object -- allowing (fail-open, no gate)"
    exit 0
fi

# A shell-word that opens an assignment: NAME= with a valid variable name.
ASSIGN_RE='^[A-Za-z_][A-Za-z0-9_]*='

# segment_cmd <flat-command> -- print each command segment on its own line.
# A segment is a span of text whose first word stands at COMMAND POSITION.
# Splits on unquoted ';', '&', '|', '(', ')' and backticks ('&&' / '||' /
# ';;' leave empty middle segments, which callers skip; '(' covers
# subshells, function bodies, and -- because '$' is an ordinary word char
# -- '$(...)' command substitution). Single-quoted spans are opaque;
# double-quoted spans are opaque EXCEPT that '$(' and backticks inside
# them still open real command positions (double quotes do not stop
# substitution), so those split too, closing the quoted span before the
# split and reopening it after so surrounding literal text stays a quoted
# word (never a fake command position). Backslash escapes stay opaque, so
# a separator inside a value (VAR='a;b') never splits one assignment.
# Self-contained on purpose: the repo's shared tokenizer work is fenced
# off (HIMMEL-1688) and this guard must not grow a dependency on it.
segment_cmd() {
    local s="$1" seg='' c i n sub
    n=${#s}
    i=0
    while [ "$i" -lt "$n" ]; do
        c=${s:i:1}
        case "$c" in
        \')
            seg="$seg$c"; i=$((i + 1))
            while [ "$i" -lt "$n" ]; do
                [ "${s:i:1}" = "'" ] && { seg="$seg'"; i=$((i + 1)); break; }
                seg="$seg${s:i:1}"; i=$((i + 1))
            done
            ;;
        \")
            seg="$seg$c"; i=$((i + 1))
            sub=0
            while [ "$i" -lt "$n" ]; do
                c=${s:i:1}
                case "$c" in
                \")
                    seg="$seg$c"; i=$((i + 1)); break
                    ;;
                \\)
                    seg="$seg$c"; i=$((i + 1))
                    [ "$i" -lt "$n" ] && { seg="$seg${s:i:1}"; i=$((i + 1)); }
                    ;;
                \`)
                    if [ "$sub" = "0" ]; then
                        printf '%s\n' "$seg\""; seg=''; sub=1
                    else
                        printf '%s\n' "$seg"; seg='"'; sub=0
                    fi
                    i=$((i + 1))
                    ;;
                \$)
                    if [ "${s:$((i + 1)):1}" = "(" ]; then
                        printf '%s\n' "$seg\""; seg=''; sub=1; i=$((i + 2))
                    else
                        seg="$seg$c"; i=$((i + 1))
                    fi
                    ;;
                \))
                    if [ "$sub" = "1" ]; then
                        printf '%s\n' "$seg"; seg='"'; sub=0
                    else
                        seg="$seg$c"
                    fi
                    i=$((i + 1))
                    ;;
                \;|\||\&)
                    if [ "$sub" = "1" ]; then
                        printf '%s\n' "$seg"; seg=''
                    else
                        seg="$seg$c"
                    fi
                    i=$((i + 1))
                    ;;
                *)
                    seg="$seg$c"; i=$((i + 1))
                    ;;
                esac
            done
            ;;
        \\)
            seg="$seg$c"; i=$((i + 1))
            [ "$i" -lt "$n" ] && { seg="$seg${s:i:1}"; i=$((i + 1)); }
            ;;
        \;|\&|\||\(|\)|\`)
            printf '%s\n' "$seg"; seg=''; i=$((i + 1))
            ;;
        * )
            seg="$seg$c"; i=$((i + 1))
            ;;
        esac
    done
    printf '%s\n' "$seg"
}

# tokenize_seg <segment> -- the segment's shell WORDS, one per line, with
# quotes and backslash escapes resolved into word content and redirections
# (operator + operand, plus an attached pure-digit IO number like 2>)
# dropped entirely. This is where the invariant's word identity comes
# from: 'path>/tmp/log' is the word 'path' plus a redirection, and
# scripts/handover/"merge-on-green.sh" is ONE word equal to the registered
# path -- no boundary character set involved in either direction.
# ENCODING (HIMMEL-1803 r6): every word line carries a leading ':'
# sentinel -- a zero-length word ('' / "") is the line ':', never a blank
# line -- because bare newline-delimited streams cannot represent empty
# words (a blank line reads as no word, and $(...) strips trailing
# newlines), and a dropped empty word shifts every later word's role.
# Consumers strip the sentinel; requote_words round-trips it.
tokenize_seg() {
    local s="$1" w='' c i n have=0 skip_word=0
    n=${#s}
    i=0
    while [ "$i" -lt "$n" ]; do
        c=${s:i:1}
        case "$c" in
        ' '|$'\t')
            if [ "$have" = "1" ]; then
                if [ "$skip_word" = "1" ]; then skip_word=0; else printf ':%s\n' "$w"; fi
                w=''; have=0
            fi
            i=$((i + 1))
            ;;
        \')
            i=$((i + 1)); have=1
            while [ "$i" -lt "$n" ]; do
                [ "${s:i:1}" = "'" ] && { i=$((i + 1)); break; }
                w="$w${s:i:1}"; i=$((i + 1))
            done
            ;;
        \")
            i=$((i + 1)); have=1
            while [ "$i" -lt "$n" ]; do
                c=${s:i:1}
                if [ "$c" = '"' ]; then i=$((i + 1)); break; fi
                if [ "$c" = "\\" ]; then
                    i=$((i + 1))
                    [ "$i" -lt "$n" ] && { w="$w${s:i:1}"; i=$((i + 1)); }
                    continue
                fi
                w="$w$c"; i=$((i + 1))
            done
            ;;
        '#')
            if [ "${TOK_ENV_SPLIT:-0}" = "1" ] && [ "$have" = "0" ]; then
                # env -S only: an unquoted '#' at argument start comments
                # out the rest of the split string.
                break
            fi
            w="$w$c"; i=$((i + 1)); have=1
            ;;
        \\)
            i=$((i + 1))
            if [ "$i" -lt "$n" ]; then
                if [ "${TOK_ENV_SPLIT:-0}" = "1" ] && [ "${s:i:1}" = "_" ]; then
                    # env -S re-tokenization only: GNU's documented "\_"
                    # is an ARGUMENT SEPARATOR (HIMMEL-1803 r4) -- end the
                    # word instead of collapsing the escape to a literal
                    # underscore. A QUOTED "\_" (single or double) stays
                    # word content: quote state wins, as everywhere.
                    # Consecutive separators COLLAPSE (whitespace-like, no
                    # empty arg) -- verified against GNU env: -S 'a\_\_b'
                    # yields [a, b].
                    if [ "$have" = "1" ]; then
                        if [ "$skip_word" = "1" ]; then skip_word=0; else printf ':%s\n' "$w"; fi
                        w=''; have=0
                    fi
                    i=$((i + 1))
                else
                    w="$w${s:i:1}"; i=$((i + 1)); have=1
                fi
            fi
            ;;
        '<'|'>')
            if [ "$have" = "1" ]; then
                case "$w" in
                ''|*[!0-9]*)
                    # A real word ends at the redirection operator. The ''
                    # arm (r6): a quoted-empty word attached to '>' (''>f)
                    # is a WORD standing at its position -- quoting made it
                    # one -- not an IO number; dropping it shifted later
                    # words' roles (and false-denied ARMAUTOMERGE=1 ''>f
                    # bash <chokepoint>, where nothing can exec).
                    if [ "$skip_word" = "1" ]; then skip_word=0; else printf ':%s\n' "$w"; fi
                    ;;
                *) : ;;   # attached pure-digit IO number (2>): drop it
                esac
                w=''; have=0
            fi
            while [ "$i" -lt "$n" ]; do
                case "${s:i:1}" in '<'|'>') i=$((i + 1)) ;; *) break ;; esac
            done
            skip_word=1   # the operator's operand is not a word
            ;;
        * )
            w="$w$c"; i=$((i + 1)); have=1
            ;;
        esac
    done
    if [ "$have" = "1" ] && [ "$skip_word" != "1" ]; then
        printf ':%s\n' "$w"
    fi
}

# requote_words -- stdin carries the ':'-sentinel word stream (one word
# per line, never a newline INSIDE a word: the pre-tokenization newline
# fold guarantees that); print the words single-quoted and space-joined on
# one line -- a segment text that re-tokenizes to EXACTLY those words,
# zero-length words included ('' round-trips as ''), whatever spaces,
# quotes, or shell metacharacters they carry. A blank line is NO word
# (stream artifact), the line ':' is an EMPTY word -- the r6 distinction.
# Round-tripping through text rather than passing an array keeps every
# consumer bash-3.2-safe (no array slicing).
requote_words() {
    local q='' w
    while IFS= read -r w; do
        [ -n "$w" ] || continue
        w=${w#:}
        w=${w//\'/\'\\\'\'}
        if [ -n "$q" ]; then q="$q '$w'"; else q="'$w'"; fi
    done
    printf '%s\n' "$q"
}

deny() {  # deny <script-path> <var-name> -- both from OUR registry, never
          # raw command text, so nothing caller-authored reaches the
          # model-facing reason.
    local script="$1" var="$2" msg reason
    msg="block-chokepoint-env-prefix: refusing an env-prefixed invocation of a sanctioned chokepoint.

    ${var}=... ${script}

    '${var}' is a registered seam variable for this chokepoint
    (scripts/chokepoints.json). himmel's rule: an env override or opt-in is
    set in the LAUNCHING shell (e.g. '${var}=1 claude'), never as a per-call
    prefix -- a per-call prefix does NOT work and cannot match the standing
    allow-rule either. Run the chokepoint bare (its own opt-in message says
    the same thing), or if this is a test seam, set it from the test suite's
    own process, not the agent's command line.

    To bypass this guard intentionally, set ENV_PREFIX_GUARD_OK=1 in the
    shell that launched Claude Code (a per-call prefix does not reach a
    hook process); restart without it to re-enable the guard."
    reason=$(printf '%s' "$msg" | jq -Rs . 2>/dev/null) \
        || reason='"block-chokepoint-env-prefix: env-prefixed invocation of a sanctioned chokepoint -- set env overrides in the launching shell, not as a per-call prefix"'
    # Structured deny on stdout (overrides the exit code where parsed) AND
    # exit 2 + stderr (the documented blocking channel) -- deny on both.
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
    printf '%s\n' "$msg" >&2
    exit 2
}

CR=$'\r'
NL=$'\n'

# check_invocation <invoked-program word> <assignment-name list> -- the
# invariant's deny point, and the registry's ONLY reader. Deny iff the
# invoked-program token IS a registered chokepoint path (exact, or
# '/'-suffix so absolute and $CLAUDE_PROJECT_DIR-qualified forms carry the
# registered suffix) AND one of THAT chokepoint's registered seam vars is
# among the segment's leading assignment names. Strip a trailing CR from
# each registry field: on Windows, jq's text-mode stdout turns line
# endings into CRLF, and a CR riding the LAST var of an entry would fail
# the name validation and silently drop that seam.
check_invocation() {
    local word="$1" names="$2" script_path vars_list v n
    [ -n "$word" ] || return 0
    [ -n "${names// /}" ] || return 0
    while IFS=$'\t' read -r script_path vars_list; do
        script_path=${script_path%"$CR"}
        vars_list=${vars_list%"$CR"}
        [ -n "$script_path" ] || continue
        [ -n "$vars_list" ] || continue
        if [ "$word" != "$script_path" ]; then
            case "$word" in */"$script_path") ;; *) continue ;; esac
        fi
        # Registry content is data; a var name with regex/glob metachars is
        # skipped, never interpreted.
        # shellcheck disable=SC2086 # word-split of the space-joined list is intended
        for v in $vars_list; do
            case "$v" in ''|*[!A-Za-z0-9_]*) continue ;; esac
            # shellcheck disable=SC2086 # word-split of the space-joined list is intended
            for n in $names; do
                [ "$n" = "$v" ] && deny "$script_path" "$v"
            done
        done
    done <<<"$REG_LINES"
    return 0
}

# env_short_cluster <word> -- GNU-getopt walk of ONE env short-option word
# (HIMMEL-1803 round 2). Short options cluster: "-vS str" is flag -v plus
# -S whose operand is the NEXT word, "-vSstr" attaches the operand to the
# same word, and an argument-taking letter mid-cluster ("-vu FOO",
# "-CS dir") consumes the next word / the rest of the word as ITS operand
# and ends the cluster there. This is the SHORT-half of the option table
# ENV_LONG_OPTS documents below (the operand classes are the same ones):
# flags -i -0 -v; argument-taking -u -C -a -S plus BSD/macOS env's -P (an
# alternate utility path) -- a data operand; the union-model letters -a
# (GNU's short spelling of --argv0) and -P are ones where an env family
# that does not accept the letter exits before running anything.
# Only -S re-tokenizes its operand into a command line (the eval /
# interpreter -c shape); -u / -C / -a / -P operands are data (a var to
# unset, a dir, an argv[0], a search path) for the caller to step over.
# Prints TWO lines: a verdict from {flags, arg-attached, arg-next,
# split-attached, split-next}, then the attached split operand for
# split-attached (empty otherwise). r6: $(...) strips trailing newlines,
# so an EMPTY second line vanishes from the captured output -- callers
# must treat a capture with no newline as verdict-plus-empty-operand,
# never read the verdict itself as the operand. A letter OUTSIDE the set
# gets the same
# CONSERVATIVE DEFAULT env_long_option uses (HIMMEL-1803 r4): assume the
# option MAY consume an operand (arg-attached when letters remain in the
# word, arg-next when it ends the word) -- never a bare word-skip that
# parks command position on a would-be operand. Real env exits on an
# invalid option, so nothing runs however the word is treated; the
# default exists so an option a FUTURE env gains cannot reopen the seam.
env_short_cluster() {
    local word="$1" i=1 n c
    n=${#word}
    while [ "$i" -lt "$n" ]; do
        c=${word:i:1}
        case "$c" in
        i|0|v) i=$((i + 1)); continue ;;
        u|C|P|a)
            if [ $((i + 1)) -lt "$n" ]; then
                printf 'arg-attached\n\n'
            else
                printf 'arg-next\n\n'
            fi
            return 0 ;;
        S)
            if [ $((i + 1)) -lt "$n" ]; then
                printf 'split-attached\n%s\n' "${word:$((i + 1))}"
            else
                printf 'split-next\n\n'
            fi
            return 0 ;;
        *)
            # The conservative default (the documented answer for any
            # letter the table does not name): treat it as operand-taking.
            if [ $((i + 1)) -lt "$n" ]; then
                printf 'arg-attached\n\n'
            else
                printf 'arg-next\n\n'
            fi
            return 0 ;;
        esac
    done
    printf 'flags\n\n'
    return 0
}

# ENV_LONG_OPTS -- the env option GRAMMAR the scan derives from
# (HIMMEL-1803 round 3). Three CR rounds each found a spelling the
# previous hand-written list missed -- -S, then the clustered -vS, then
# the separate operand of --unset / --chdir / --argv0 -- so the model is
# no longer a list of spellings: every option env accepts is classified
# by the ONE thing the scanner needs to know, what it does to the words
# after it. Grounded in GNU coreutils env (getopt_long) plus POSIX env,
# with BSD/macOS env's long-only twins folded in where they exist (union
# model: a spelling one env family rejects makes THAT env exit before
# running anything, so modelling the union is safe). Entries are
# "name|class":
#   flag   -- consumes nothing (-i/--ignore-environment, -0/--null,
#             -v/--debug, --list-signal-handling, --help, --version).
#   arg    -- mandatory operand, separate word or "--name=VAL" attached:
#             DATA for the scan to step over (a var to unset, a dir, an
#             argv[0], an alternate path) -- never command position
#             (-u/--unset, -C/--chdir, --argv0).
#   optarg -- optional operand, "=" spelling ONLY (GNU getopt: an
#             optional long-option argument cannot be a separate word;
#             the next word stays an operand/command word)
#             (--block-signal, --default-signal, --ignore-signal).
#   split  -- operand is re-tokenized by env into the whole command line
#             (the eval/-c shape): the scan re-parses it (-S/
#             --split-string).
# A name matches EXACTLY or by UNIQUE abbreviation (GNU getopt's
# long-option rule; an ambiguous or unknown abbreviation falls to
# env_long_option's conservative default).
ENV_LONG_OPTS='
ignore-environment|flag
null|flag
debug|flag
unset|arg
chdir|arg
argv0|arg
block-signal|optarg
default-signal|optarg
ignore-signal|optarg
list-signal-handling|flag
split-string|split
help|flag
version|flag
'

# env_long_option <word> -- classify ONE env long-option word ("--..." or
# the bare "--") against ENV_LONG_OPTS. Prints TWO lines: a verdict from
# {endopts, flag, consume-next, consume-attached, split-next,
# split-attached}, then the attached operand for split-attached (empty
# otherwise; r6 -- callers must treat a capture with no newline as an
# EMPTY operand, "--split-string=" being the real case, since $(...)
# strips the empty second line). The CONSERVATIVE DEFAULT -- the
# documented answer for any word the table does not resolve (an
# unrecognised option, or an abbreviation real env would reject as
# ambiguous) -- assumes the option
# MAY consume an operand: consume-next / consume-attached, never a bare
# word-skip that silently parks command position on a would-be operand
# (the defect class of rounds 1-3). env exits on an option it does not
# recognise, so nothing runs in that case anyway; the default exists so
# an option a FUTURE env gains cannot reopen the seam.
env_long_option() {
    local word="$1" name='' val='' hasval=0 cls='' hits=0 line oname
    if [ "$word" = "--" ]; then printf 'endopts\n\n'; return 0; fi
    name=${word#--}
    case "$name" in
    *=*) hasval=1; val=${name#*=}; name=${name%%=*} ;;
    esac
    if [ -n "$name" ]; then
        # Exact match first (GNU getopt: an exact name wins even when it
        # is also a prefix of another option's name).
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            oname=${line%%|*}
            if [ "$oname" = "$name" ]; then cls=${line#*|}; hits=1; break; fi
        done <<EOF
$ENV_LONG_OPTS
EOF
        if [ "$hits" = "0" ]; then
            # Unique-abbreviation match; 2+ hits is exactly the set real
            # env rejects as ambiguous, so it falls to the default too.
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                oname=${line%%|*}
                case "$oname" in
                "$name"*) hits=$((hits + 1)); cls=${line#*|} ;;
                esac
            done <<EOF
$ENV_LONG_OPTS
EOF
        fi
    fi
    if [ "$hits" != "1" ]; then
        if [ "$hasval" = "1" ]; then printf 'consume-attached\n\n'
        else printf 'consume-next\n\n'; fi
        return 0
    fi
    case "$cls" in
    flag)
        # "--flag=VAL" is a spelling env rejects ("option ... doesn't
        # allow an argument") -- nothing runs; the word is skipped.
        printf 'flag\n\n' ;;
    arg|optarg)
        # An optarg's optional operand exists ONLY in the "=" spelling;
        # a separate word after it is an operand/command word, untouched.
        if [ "$hasval" = "1" ]; then printf 'consume-attached\n\n'
        elif [ "$cls" = "arg" ]; then printf 'consume-next\n\n'
        else printf 'flag\n\n'; fi ;;
    split)
        if [ "$hasval" = "1" ]; then printf 'split-attached\n%s\n' "$val"
        else printf 'split-next\n\n'; fi ;;
    esac
    return 0
}

# scan_split_argv <split-string text> <names> <depth> <newline-joined
# appended words> -- the HIMMEL-1803 r4 model of a -S / --split-string
# operand. GNU env does NOT hand that operand to a fresh shell scan: it
# TOKENIZES the string with its own split-string tokenizer (shell-like
# quoting and backslash escapes, plus the documented "\_" argument
# separator) and RE-ENTERS env's OWN option parsing over the produced
# argv -- a leading -i / -u / -C inside the string is an env OPTION, not
# the invoked program -- with the CLI words after the -S operand APPENDED
# to that argv (one getopt pass over the concatenation; coreutils
# src/env.c, the parse_split_string path). So the scan here: tokenize the
# string (tokenize_seg with TOK_ENV_SPLIT enabled, so "\_" splits
# where env splits), splice on the appended words, re-quote every merged
# word losslessly (requote_words; the pre-tokenization newline fold
# guarantees no word contains a newline, so a newline-joined list is
# exact), and re-enter scan_segment AT THE ENV PHASE. Depth-capped like
# scan_text: deeper reconstruction stays the documented determined-bypass
# residual.
scan_split_argv() {
    local text="$1" inames="$2" depth="$3" appended="$4"
    local words='' seg_text=''
    [ "$depth" -le 5 ] || return 0
    TOK_ENV_SPLIT=1
    words=$(tokenize_seg "$text")
    TOK_ENV_SPLIT=0
    if [ -n "$appended" ]; then
        if [ -n "$words" ]; then words="$words${NL}$appended"; else words="$appended"; fi
    fi
    [ -n "$words" ] || return 0
    seg_text=$(printf '%s\n' "$words" | requote_words)
    [ -n "$seg_text" ] || return 0
    scan_segment "$seg_text" "$inames" "$depth" env
    return 0
}

# scan_segment <segment> <inherited assignment names> <depth> [phase] --
# walk the segment's words to its command position, collecting the leading
# assignment names that bind to it, then hand the invoked-program token to
# check_invocation. Wrappers that re-enter command position are stepped
# over; `eval` and an interpreter's `-c` string re-parse their operand, so
# those recurse (bounded) with the already-collected names -- an outer
# seam assignment reaches the inner command's environment. The optional
# 4th arg is the INITIAL phase: "env" re-enters env's option state over
# the segment's words (scan_split_argv's -S model), "start" (the default)
# scans a fresh command position.
scan_segment() {
    local seg="$1" inames="$2" depth="$3"
    local -a W
    local w nw=0 j=0 k rest names asg_ok=1 expect_cstr=0
    local phase="${4:-start}"
    local env_endopts=0 lo_out lo_verdict lo_operand
    local cluster_out cluster_verdict cluster_operand
    names="$inames"
    # ':'-sentinel stream (r6): a blank line is a stream artifact (no
    # word); the line ':' is a zero-length word and MUST take its slot in
    # W -- real getopt consumes it as an operand (env -a '' SEAM=1 cmd
    # runs cmd with the seam) and real exec fails on it at command
    # position; dropping it shifted every later word's role.
    while IFS= read -r w; do
        [ -n "$w" ] || continue
        W[nw]="${w#:}"; nw=$((nw + 1))
    done <<<"$(tokenize_seg "$seg")"
    while [ "$j" -lt "$nw" ]; do
        w=${W[$j]}
        case "$phase" in
        interp)
            if [ "$expect_cstr" = "1" ]; then
                # -c: the NEXT word is a command STRING (re-parsed by the
                # interpreter; recurse into it), and any words after it are
                # $0/positional parameters -- NOT an invoked script, so a
                # chokepoint path there must not match.
                scan_text "$w" "$names" $((depth + 1))
                return 0
            fi
            case "$w" in
            -c) expect_cstr=1; j=$((j + 1)); continue ;;
            -*) j=$((j + 1)); continue ;;
            esac
            check_invocation "$w" "$names"
            return 0
            ;;
        env)
            # Option words (HIMMEL-1803, rounds 1-4): what an env option
            # does to the words after it is DERIVED from the option
            # grammar table (env_long_option for long words and long
            # ABBREVIATIONS, env_short_cluster for short/clustered words):
            # nothing (flag), a stepped-over DATA operand -- separate or
            # "="-attached, never command position -- or a re-tokenized
            # command line (-S / --split-string, every spelling). Each
            # split spelling re-enters env's OWN option state over its
            # tokenized operand plus the CLI words after it
            # (scan_split_argv), carrying the names env has collected so
            # far (env A=1 -S 'B=2 cmd' exports both): a leading -i/-u/-C
            # inside the string is an env OPTION, and the words after the
            # operand are arguments APPENDED to the string's command line
            # (r4: GNU env feeds the split string back through its own
            # getopt, coreutils parse_split_string -- never a fresh shell
            # command scan). "--" (and the lone "-" operand) ENDS option
            # parsing: every later word is assignments-then-command, never
            # an option. Anything the table does not resolve uses its
            # conservative default (assume the option MAY consume an
            # operand) -- in the LONG arm and the SHORT-cluster arm alike.
            # No per-spelling case list remains to leave a spelling out of.
            if [ "$env_endopts" = "0" ]; then
                case "$w" in
                --*)
                    lo_out=$(env_long_option "$w")
                    lo_verdict=${lo_out%%"$NL"*}
                    # r6: an EMPTY operand line is stripped by $(...) --
                    # "--split-string=" captures as ONE line; without this
                    # guard the verdict word itself became the operand and
                    # a fake command word parked command position.
                    case "$lo_out" in
                    *"$NL"*) lo_operand=${lo_out#*"$NL"} ;;
                    *)       lo_operand='' ;;
                    esac
                    case "$lo_verdict" in
                    endopts)          env_endopts=1; j=$((j + 1)); continue ;;
                    flag)             j=$((j + 1)); continue ;;
                    consume-next)     j=$((j + 2)); continue ;;
                    consume-attached) j=$((j + 1)); continue ;;
                    split-next)
                        j=$((j + 1))
                        [ "$j" -lt "$nw" ] || return 0
                        rest=''
                        k=$((j + 1))
                        while [ "$k" -lt "$nw" ]; do rest="$rest${NL}:${W[$k]}"; k=$((k + 1)); done
                        scan_split_argv "${W[$j]}" "$names" $((depth + 1)) "$rest"
                        return 0 ;;
                    split-attached)
                        rest=''
                        k=$((j + 1))
                        while [ "$k" -lt "$nw" ]; do rest="$rest${NL}:${W[$k]}"; k=$((k + 1)); done
                        scan_split_argv "$lo_operand" "$names" $((depth + 1)) "$rest"
                        return 0 ;;
                    esac
                    ;;
                -)
                    # A lone "-": FreeBSD/macOS env documents it as
                    # end-of-options, and GNU env ACCEPTS it too --
                    # treats it like -i (an empty environment) and
                    # executes the command (verified on the dev
                    # machine: "env - /usr/bin/printf ..." prints and
                    # exits 0; a bare utility name after it fails only
                    # because the emptied environment carries no PATH).
                    # Whichever family executes the line, the words
                    # after "-" are assignments-then-command, so the
                    # scan must not read an option into them.
                    env_endopts=1; j=$((j + 1)); continue ;;
                -?*)
                    cluster_out=$(env_short_cluster "$w")
                    cluster_verdict=${cluster_out%%"$NL"*}
                    # r6: same empty-second-line guard as the long arm
                    # (split-attached always has a non-empty operand here,
                    # but the protocol must not depend on that).
                    case "$cluster_out" in
                    *"$NL"*) cluster_operand=${cluster_out#*"$NL"} ;;
                    *)       cluster_operand='' ;;
                    esac
                    case "$cluster_verdict" in
                    arg-next) j=$((j + 2)); continue ;;
                    split-attached)
                        rest=''
                        k=$((j + 1))
                        while [ "$k" -lt "$nw" ]; do rest="$rest${NL}:${W[$k]}"; k=$((k + 1)); done
                        scan_split_argv "$cluster_operand" "$names" $((depth + 1)) "$rest"
                        return 0 ;;
                    split-next)
                        j=$((j + 1))
                        [ "$j" -lt "$nw" ] || return 0
                        rest=''
                        k=$((j + 1))
                        while [ "$k" -lt "$nw" ]; do rest="$rest${NL}:${W[$k]}"; k=$((k + 1)); done
                        scan_split_argv "${W[$j]}" "$names" $((depth + 1)) "$rest"
                        return 0 ;;
                    *) j=$((j + 1)); continue ;;
                    esac ;;
                esac
            fi
            if [[ $w =~ $ASSIGN_RE ]]; then
                names="$names ${w%%=*}"; j=$((j + 1)); continue
            fi
            phase=start; asg_ok=0
            continue    # reprocess this word at command position
            ;;
        start)
            if [ "$asg_ok" = "1" ] && [[ $w =~ $ASSIGN_RE ]]; then
                names="$names ${w%%=*}"; j=$((j + 1)); continue
            fi
            case "$w" in
            env|*/env)
                # A fresh env process: its option parsing starts over
                # ("env -- A=1 env -S '...'": the outer "--" must not
                # leak into the inner env's option scan).
                phase='env'; env_endopts=0; j=$((j + 1)); continue ;;
            eval)
                # eval joins its arguments and re-parses them as a new
                # command; recurse over the joined remainder.
                rest=''; k=$((j + 1))
                while [ "$k" -lt "$nw" ]; do rest="$rest ${W[$k]}"; k=$((k + 1)); done
                scan_text "$rest" "$names" $((depth + 1))
                return 0 ;;
            bash|sh|*/bash|*/sh|bash.exe|*/bash.exe|sh.exe|*/sh.exe|.|source)
                phase=interp; j=$((j + 1)); continue ;;
            command|exec|nohup)
                # These re-enter command position but their arguments are
                # words, not assignments (command VAR=x foo does not export
                # VAR) -- stop counting assignments.
                asg_ok=0; j=$((j + 1)); continue ;;
            \{|!|time|if|then|else|elif|do|while|until)
                # Grouping/keyword openers start a fresh simple command:
                # assignments after them DO lead it.
                asg_ok=1; j=$((j + 1)); continue ;;
            esac
            # The invoked-program token of this segment. Words beyond it
            # are arguments and never match (the finding-4 direction).
            check_invocation "$w" "$names"
            return 0
            ;;
        esac
    done
    return 0
}

# scan_text <command text> <inherited assignment names> <depth> -- segment
# and scan; the recursion target for eval / -c strings (depth-capped:
# deeper reconstruction is the documented determined-bypass residual).
scan_text() {
    local text="$1" inames="$2" depth="$3" seg
    [ "$depth" -le 5 ] || return 0
    while IFS= read -r seg; do
        [[ $seg =~ [^[:space:]] ]] || continue
        scan_segment "$seg" "$inames" "$depth"
    done <<<"$(segment_cmd "$text")"
    return 0
}

# One registry read: "path<TAB>var var ..." per line; check_invocation is
# its only consumer. An empty/unreadable registry allows (fail-open).
REG_LINES=$(jq -r 'to_entries[] | "\(.key)\t\((.value.seam_env_vars // []) | join(" "))"' "$REGISTRY" 2>/dev/null) || REG_LINES=''
[ -n "$REG_LINES" ] || exit 0

scan_text "$cmd_flat" "" 0

exit 0
