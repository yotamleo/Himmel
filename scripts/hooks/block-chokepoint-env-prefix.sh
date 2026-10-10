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
# HIMMEL-2927 (the unassigned-clear class): `env -u NAME` / `env --unset
# NAME` / `env --unset=NAME` clear a registered seam with no assignment
# word, and an in-shell `unset NAME` / `export -n NAME` clears it with no
# assignment word EITHER, from a DIFFERENT segment than the chokepoint's --
# both defeat the INVARIANT's "assignment word" test above while producing
# the exact same effect an env-prefixed VAR=x is denied for. This does not
# loosen the INVARIANT; it names two more ways a segment's seam state can
# change, both still resolved against the SAME registered-name set the
# INVARIANT already checks:
#   - inside `env`'s option state, `-u`/`--unset`'s operand (attached,
#     "=", or the next word -- the same operand-class grammar HIMMEL-1803
#     derives every other env option from) is added to that SEGMENT's
#     names exactly like a leading assignment word would be -- still SAME
#     SEGMENT, still gated on `env` being a recognized wrapper.
#   - `unset NAME` / `export -n NAME`, as a segment's own invoked-program
#     token, is NOT itself checked against the registry (neither is a
#     chokepoint path); instead its argument names are recorded and carried
#     to every LATER segment of the SAME top-level payload's scan_text
#     walk (never earlier ones -- shell execution order is left to right,
#     so an unset cannot retroactively clear a segment already run) --
#     deliberately cross-segment, because unsetting/un-exporting a shell
#     variable IS a cross-segment effect in the shell itself. Both paths
#     still gate the deny on check_invocation's membership test against
#     the matched chokepoint's OWN registered seam list, so a name that is
#     not a registered seam of anything changes nothing (over-match stays
#     closed the same way the assignment form closes it).
#
# `unset`/`export -n`'s OWN option scanning (scan_segment's `unset)` and
# `export)` arms) went through three CR rounds each finding the next edge
# a bash-option-VALIDITY model missed (-fn, the -f leading/trailing
# boundary, `--`, `-x`) -- round 5's ruling stopped modelling validity at
# all: for `unset`, or an `export` carrying `-n` anywhere in its leading
# run of option-shaped words (`--` and combined forms included), every
# remaining word that does not start with `-` is a candidate name, full
# stop -- no charset check, no leading-vs-trailing distinction, no
# invalid-option branch. This is DELIBERATELY fail-closed rather than
# fail-open: an invalid invocation (`unset -x NAME`) is denied too
# (documented over-deny -- real bash would refuse it and touch nothing
# anyway, so denying it here costs nothing and removes a parser this
# guard has no business re-implementing). Over-deny is the safe direction
# for a guard; a false ALLOW is the defect class this ticket exists for.
#
# HIMMEL-2933 (the third clearing shape): a plain or exported ASSIGNMENT in
# an earlier segment -- `SEAM=0;` / `export SEAM=;` / `export SEAM=0 &&` --
# clears a registered seam with no `unset`/`export -n`/`env -u` in sight
# either. A segment consumed ENTIRELY as leading assignment words (no
# command word ever reached) is folded into UNSET_NAMES the same way
# `unset`/`export -n` are; `export NAME[=val]`, `-n` or not, is folded
# unconditionally too (`export` never leads into a command position, so
# every non-option word after it is a name, fail-closed, no value
# inspection -- `export SEAM=1` denies too, a documented arming-direction
# over-deny).
#
# HIMMEL-2939 (the fourth clearing shape): `let`/`declare`/`typeset`/
# `readonly` all assign in the CURRENT shell exactly like a plain assignment
# word (HIMMEL-2933) does, `printf -v NAME` and `read NAME` write a shell
# variable the same way, and the legacy `$[NAME=0]` arithmetic construct
# assigns too, all with no `unset`/`export -n`/`env -u`/plain assignment in
# sight. Same fail-closed posture, resolved against the SAME registered-name
# set: for `let`/`declare`/`typeset`/`readonly`/`read`, every remaining word
# that does not start with `-`, `=`-suffix stripped, is a candidate name
# (declare -p NAME denies too -- documented over-deny, no option-validity
# model); for `printf`, only `-v`'s operand (attached `-vNAME` or the next
# word) is a candidate -- printf's other arguments are format/data, not
# names. All fold into UNSET_NAMES for later segments exactly like `unset`
# does. `$[...]` is not a segmentation boundary (unlike `$(`/backtick) --
# a segment containing the literal `$[` anywhere has every `NAME=` word in
# it folded into UNSET_NAMES too, no bracket-depth tracking, same fail-closed
# direction. `local` is function-scoped and cannot precede a top-level
# chokepoint, so it is not modelled. `mapfile`/`readarray` (HIMMEL-2943) DO
# fold: `mapfile NAME` converts a scalar seam into an array bash does not
# export to children, same clearing effect as `unset` -- word-bounded scan
# over every remaining word, same as `let`/`read`, no option-shape model.
#
# HIMMEL-3185 (the fifth clearing shape): an arithmetic COMMAND `(( ... ))` or
# EXPANSION `$(( ... ))` whose body assigns a registered seam clears it in
# the current shell like `let` does. `((NAME=0))` was already denied only by
# accident (the split body reads as an assignment WORD); the spaced
# `(( NAME = 0 ))`, `+=`, `++`/`--` and comma-joined forms left no assignment
# word and were ALLOWED. segment_cmd now lifts each `((`/`$((` body out whole
# (arith_body, quoted `"$(( ))"` included), scan_segment folds the seam names
# it ASSIGNS (arith_fold). Unlike `let`/`$[...]` this fold names the assignment
# forms rather than denying every mention, because a comparison inside `(( ))`
# (`(( NAME == 0 ))`, `(( NAME > 0 ))`) is the ordinary idiom and must ALLOW.
#
# The round-2 '(' carve-out is CLOSED: an unquoted '(' / ')' / backtick
# (and `$(` / backtick inside double quotes) opens a fresh command
# position via segmentation, so subshell, $(...), and backtick-wrapped
# invocations are recognized. Known residual (documented, unchanged
# posture -- the determined-bypass class this belt does not target,
# HIMMEL-912; the classifier still sees these commands): deliberately
# case-varied paths/vars, a path assembled from shell variables ($X.sh),
# PowerShell-native $env: syntax, sudo / xargs / find -exec wrappers (the
# transparent nice / timeout / stdbuf / ionice / chrt wrappers are NOT a
# residual since HIMMEL-3904: scan_segment steps over them, and an option
# wrapper_skip cannot model denies when the segment names a chokepoint),
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
# HIMMEL-4130 (HIMMEL-3986 sweep): `.command // .cmd` fell through to .cmd
# on a PRESENT but false .command, so the hook judged text the harness does
# not run. Only a null/absent .command falls back to .cmd; a non-string one
# is flagged on line 2 and fails closed below.
result=$(jq -r '(.tool_input // {}) as $t | ((.tool_name // "")|tostring) + "\n"
    + (if ($t | has("command")) and $t.command != null
       then (if ($t.command | type) == "string" then "s\n" + $t.command else "x\n" end)
       else "s\n" + (($t.cmd // "")|tostring) end)' <<<"$input" 2>/dev/null || true)
tool="${result%%$'\n'*}"
tool="${tool%$'\r'}"
cmd="${result#*$'\n'}"
kind="${cmd%%$'\n'*}"
kind="${kind%$'\r'}"
cmd="${cmd#*$'\n'}"
case "$tool" in
    Bash|PowerShell|"") ;;
    *) exit 0 ;;
esac
if [ "$kind" = "x" ]; then
    msg="block-chokepoint-env-prefix: refusing a ${tool:-tool} call whose tool_input.command is present but not a string, so the text that runs cannot be checked.

    Send the command as a JSON string. To bypass this guard intentionally,
    set ENV_PREFIX_GUARD_OK=1 in the LAUNCHING shell (a per-call prefix does
    not reach a hook process); restart without it to re-enable the guard."
    reason=$(printf '%s' "$msg" | jq -Rs . 2>/dev/null) \
        || reason='"block-chokepoint-env-prefix: tool_input.command is not a string -- refusing"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
    printf '%s\n' "$msg" >&2
    exit 2
fi

[ -n "$cmd" ] || exit 0
# HIMMEL-1813: the untouched command, newlines included, for the
# parse-independent backstop (raw_mention) that runs before scan_text.
raw_cmd=$cmd

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

# A shell-word that opens an assignment: NAME= or NAME+= (append, HIMMEL-1813)
# with a valid variable name.
ASSIGN_RE='^[A-Za-z_][A-Za-z0-9_]*[+]?='

# HIMMEL-3185: segment_cmd tags an arithmetic body it lifted out of a
# `(( ... ))` / `$(( ... ))` with this prefix so scan_segment can tell it from
# ordinary command text (see arith_body / arith_fold below).
ARITH_TAG=$'\001ARITH\001'

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

# arith_body <text> <index just past the opening `((`> -- set ARITH_BODY to
# the arithmetic expression up to its matching `))` (grouping parens inside
# it balanced) and return 0; return 1 when no adjacent `))` closes it (the
# `((cmd); cmd)` nested-subshell reading, or an unterminated span -- both
# keep the segmentation they always had). Quotes are not modelled: a `)`
# inside a quoted string in an arithmetic body mis-balances (ponytail:
# documented determined-bypass residual, same posture as the header's
# string-reconstruction note). Reads segment_cmd's byte array SC (its only
# caller), so <index> is a byte offset into <text>.
# HIMMEL-4529: the body ends at the first `)` that is unmatched since
# <index>, which is exactly the stack match of the `(` just before it. One
# stack pass over SC (first call per segment_cmd text) records every `(`'s
# match in segment_cmd's AMATCH, so each call is an O(1) lookup: it used to
# rescan to EOF per unclosed `((` (1500 openers = 40 s, past the hook budget).
arith_body() {
    local i="$2" j k=0 c
    local -a stk=()
    ARITH_BODY=''
    if [ "$AMATCH_BUILT" = "0" ]; then
        AMATCH_BUILT=1
        AMATCH=()
        while [ "$k" -lt "${#SC[@]}" ]; do
            c=${SC[k]-}
            case "$c" in
            '(') stk[${#stk[@]}]=$k ;;
            ')')
                if [ "${#stk[@]}" -gt 0 ]; then
                    AMATCH[${stk[${#stk[@]} - 1]}]=$k
                    unset "stk[${#stk[@]} - 1]"
                fi
                ;;
            esac
            k=$((k + 1))
        done
    fi
    j=${AMATCH[i - 1]-}
    [ -n "$j" ] || return 1
    [ "${SC[j + 1]-}" = ")" ] || return 1
    ARITH_BODY=${1:i:$((j - i))}
    return 0
}

# arith_fold <arithmetic body> -- fold every registered seam name the body
# ASSIGNS into UNSET_NAMES, exactly like `let`'s fold. Unlike `let`/`$[...]`
# (which deny a bare mention), a comparison or read inside `(( ))` is the
# ordinary idiom (`(( SEAM == 0 ))`, `(( SEAM > 0 ))`) and stays ALLOW, so
# this one fold does name the assignment forms: `NAME` (optionally
# `NAME[..]`) followed by `=` (not `==`), a compound `op=` (`+= -= *= /= %=
# &= |= ^= <<= >>=`), or a postfix `++`/`--`; and a prefix `++`/`--` before
# the name. Whitespace anywhere between the tokens is allowed -- the spaced
# spelling is the one the no-space assignment-WORD path never saw. Anywhere in
# the body counts (comma lists, ternary arms, grouping parens).
# ponytail: the fold is STATIC -- it only sees a seam NAME written in the body.
# A bare variable in `(( ))` has its VALUE evaluated as arithmetic, so
# `x=SEAM=0; (( x ))` assigns the seam through a value this fold cannot follow
# (the value could equally come from a file, `read` or the environment), and
# the guard ALLOWS it. HIMMEL-3195: accepted as a documented residual (operator
# ruling 2026-09-19), same class as the header's string-reconstruction note;
# the test suite pins it as a known ALLOW.
arith_fold() {
    local body="$1" flat='' n re c i=0 k=0 d=0 ins='' nb=${#1}
    local -a spans
    local ns=0
    local ws='[[:space:]]*'
    # A subscript `[ ... ]` may nest (`NAME[i[0]] = 0`), which no bracket
    # regex can match, so scan it with a depth counter (bash 3.2-safe): flatten
    # every top-level span to `[]` for the assignment test below and keep its
    # inside to be folded on its own -- an index is itself arithmetic
    # (`x[ SEAM = 0 ] = 1` assigns SEAM). An unterminated `[` is a bash syntax
    # error, so that body keeps its raw text.
    while [ "$i" -lt "$nb" ]; do
        c=${body:i:1}
        if [ "$d" -eq 0 ]; then
            flat="$flat$c"
            if [ "$c" = "[" ]; then d=1; ins=''; fi
        else
            case "$c" in
            '[') d=$((d + 1)); ins="$ins$c" ;;
            ']')
                d=$((d - 1))
                if [ "$d" -eq 0 ]; then
                    flat="$flat]"; spans[ns]="$ins"; ns=$((ns + 1))
                else
                    ins="$ins$c"
                fi
                ;;
            *) ins="$ins$c" ;;
            esac
        fi
        i=$((i + 1))
    done
    if [ "$d" -ne 0 ]; then flat="$body"; ns=0; fi
    for n in $ALL_SEAM_VARS; do
        [ -n "$n" ] || continue
        re="(^|[^A-Za-z0-9_])${n}${ws}(\\[\\])?${ws}((\\+\\+|--)|(([-+*/%&|^]|<<|>>)?=([^=]|\$)))"
        if [[ $flat =~ $re ]]; then
            unset_add "$n"
            continue
        fi
        re="(\\+\\+|--)${ws}${n}(\$|[^A-Za-z0-9_])"
        if [[ $flat =~ $re ]]; then
            unset_add "$n"
        fi
    done
    while [ "$k" -lt "$ns" ]; do
        arith_fold "${spans[k]}"
        k=$((k + 1))
    done
}

# segment_cmd <flat-command> -- print each command segment as
# "<paren-depth>\t<segment>", one per line. A segment is a span of text
# whose first word stands at COMMAND POSITION. Splits on unquoted ';', '&',
# '|', '(', ')' and backticks ('&&' / '||' / ';;' leave empty middle
# segments, which callers skip).
# PAREN DEPTH (HIMMEL-2929, POSITIVE/whitelist rule -- operator ruling after
# the blacklist collapse ("any `((`/`$(`/backtick anywhere disables scoping
# for the whole call") converged on the wrong invariant: every new grammar
# shape needed its own patch, never provably done. Inverted instead: a `(`
# opens a real subshell (scopes: depth++, a fresh UNSET_NAMES snapshot
# boundary) ONLY when it stands at COMMAND POSITION -- the first token of a
# command, i.e. at segment start or immediately after `;`, `&&`, `||`, `|`,
# `&`, `{`, `(`, a newline, or a scoping `(`'s open OR close. `cmdpos` tracks
# this directly: it starts true, resets true after any of those triggers,
# and goes false the moment any ordinary word character (including a
# single/double-quoted word or a backslash escape) is consumed -- so a
# keyword like `in` or `[[` disqualifies what follows for the mundane
# reason that it was already consumed as a word, never via a keyword
# exclusion list. A `(` that fails the command-position test is OPAQUE: it
# does not touch pdepth, but its matching `)` is tracked too (a per-open
# kind stack, S=scoping/O=opaque) so depth accounting never drifts. Three
# more disqualifiers, checked only when cmdpos is otherwise true:
#   - immediately preceded by `$`, `<`, `>` or `=` -- `$(...)` command
#     substitution, `<(...)`/`>(...)` process substitution, an array
#     assignment's `NAME=(...)` -- none of these fork a subshell.
#   - immediately followed by another `(` -- `((...))` arithmetic evaluation
#     opens with an ADJACENT pair, never a real subshell.
#   - already nested inside an opaque paren (stack top = O) -- forces O
#     unconditionally, so a grouping paren written INSIDE `((...))` (the
#     codex-1 round-2 false ALLOW under the old kind-tracking attempt) can
#     never be misread as a fresh real subshell: once opaque, everything
#     inside stays opaque until that paren's own matching close.
# A stray ')' with nothing open latches "confused": every later paren in
# this text is left untouched (fold-forward, the safe direction) same as an
# unmatched '(' left open at EOF. `no_scope` (scan_text's eval/`-c`
# recursion, the only caller passing depth > 0 -- see scan_text's header)
# forces every paren in the recursed text to O unconditionally: the
# ticket's rule that a `bash -c`/`eval` string is never modeled holds
# regardless of what parens that string contains (CodeRabbit, PR #643 @
# 5ce5bbed). Single-quoted spans are opaque; double-quoted spans are opaque
# EXCEPT that '$(' and backticks inside them still open real command
# positions (double quotes do not stop substitution), so those split too,
# closing the quoted span before the split and reopening it after so
# surrounding literal text stays a quoted word (never a fake command
# position) -- neither ever touches pdepth, same as their unquoted kin.
# Backslash escapes stay opaque, so a separator inside a value (VAR='a;b')
# never splits one assignment. Self-contained on purpose: the repo's shared
# tokenizer work is fenced off (HIMMEL-1688) and this guard must not grow a
# dependency on it.
segment_cmd() {
    local s="$1" seg='' c i n sub pdepth=0 confused=0 no_scope="${2:-0}" bdepth=0
    local cmdpos=1 kind='' lb='' nx='' ro=0
    local -a pkind SC AMATCH
    local ptop=0 LC_ALL=C AMATCH_BUILT=0
    n=${#s}
    split_bytes "$s" "$n"
    i=0
    while [ "$i" -lt "$n" ]; do
        c=${SC[i]-}
        case "$c" in
        \')
            seg+="$c"; i=$((i + 1))
            while [ "$i" -lt "$n" ]; do
                [ "${SC[i]-}" = "'" ] && { seg+="'"; i=$((i + 1)); break; }
                seg+="${SC[i]-}"; i=$((i + 1))
            done
            cmdpos=0
            ;;
        \")
            seg+="$c"; i=$((i + 1))
            sub=0
            while [ "$i" -lt "$n" ]; do
                c=${SC[i]-}
                case "$c" in
                \")
                    seg+="$c"; i=$((i + 1)); break
                    ;;
                \\)
                    seg+="$c"; i=$((i + 1))
                    [ "$i" -lt "$n" ] && { seg+="${SC[i]-}"; i=$((i + 1)); }
                    ;;
                \`)
                    if [ "$sub" = "0" ]; then
                        printf '%s\t%s\n' "$pdepth" "$seg\""; seg=''; sub=1
                    else
                        printf '%s\t%s\n' "$pdepth" "$seg"; seg='"'; sub=0
                    fi
                    i=$((i + 1))
                    ;;
                \$)
                    if [ "${SC[i + 1]-}" = "(" ]; then
                        # HIMMEL-3185: `"$(( ... ))"` -- same lift as the
                        # unquoted `((` arm; the sub=1 split below still runs.
                        if [ "${SC[i + 2]-}" = "(" ] && arith_body "$s" $((i + 3)); then
                            printf '%s\t%s\n' "$pdepth" "$ARITH_TAG$ARITH_BODY"
                        fi
                        printf '%s\t%s\n' "$pdepth" "$seg\""; seg=''; sub=1; i=$((i + 2))
                    else
                        seg+="$c"; i=$((i + 1))
                    fi
                    ;;
                \))
                    if [ "$sub" = "1" ]; then
                        printf '%s\t%s\n' "$pdepth" "$seg"; seg='"'; sub=0
                    else
                        seg+="$c"
                    fi
                    i=$((i + 1))
                    ;;
                \;|\||\&)
                    if [ "$sub" = "1" ]; then
                        printf '%s\t%s\n' "$pdepth" "$seg"; seg=''
                    else
                        seg+="$c"
                    fi
                    i=$((i + 1))
                    ;;
                *)
                    seg+="$c"; i=$((i + 1))
                    ;;
                esac
            done
            cmdpos=0
            ;;
        \$)
            # `$[ ... ]` legacy arithmetic expansion is an OPAQUE span, like
            # `$(( ... ))` (HIMMEL-2929). `$((` is already inert because the
            # `$` here lands in the default case (cmdpos:=0) so its parens are
            # never command-position -- but `$[...]` has no paren to hang that
            # on, and a `;`/`&`/`|`/newline INSIDE it would otherwise split the
            # segment and let the following `(` read as a real subshell,
            # scoping a seam assignment out of the deny set (the `$[1 +\n
            # (HIMMEL_CONSOLE_LEG=0)]` bypass). Consume the whole `$[...]` as
            # one opaque word, `[`-depth balanced, so it never splits and never
            # opens scope; an unterminated `$[` folds forward (safe direction),
            # same as a stray `(`. Any other `$` (including `$(` / `$((`) falls
            # through to the default char handling below, unchanged.
            if [ "${SC[i + 1]-}" = "[" ]; then
                seg+="\$["; i=$((i + 2))
                bdepth=1
                while [ "$i" -lt "$n" ] && [ "$bdepth" -gt 0 ]; do
                    c=${SC[i]-}
                    case "$c" in
                    \[) bdepth=$((bdepth + 1)) ;;
                    \]) bdepth=$((bdepth - 1)) ;;
                    esac
                    seg+="$c"; i=$((i + 1))
                done
                cmdpos=0
            else
                seg+="$c"; i=$((i + 1)); cmdpos=0
            fi
            ;;
        \\)
            seg+="$c"; i=$((i + 1))
            [ "$i" -lt "$n" ] && { seg+="${SC[i]-}"; i=$((i + 1)); }
            cmdpos=0
            ;;
        \{)
            seg+="$c"; i=$((i + 1)); cmdpos=1
            ;;
        \()
            # HIMMEL-3185: `((` / `$((` -- lift the arithmetic body out
            # whole, tagged, so scan_segment can fold a seam ASSIGNMENT in
            # it. The body's own text still segments below exactly as
            # before (its parens are opaque), but that path only sees an
            # assignment WORD (`NAME=0`); the spaced `NAME = 0` is words.
            # Emitted BEFORE the pending segment is flushed: bash expands
            # `$(( ))` in a word before it execs the command, so in
            # `bash chokepoint.sh $(( SEAM = 0 ))` the fold must already be
            # in UNSET_NAMES when the segment holding the chokepoint (the
            # text ahead of this `(`) is scanned (CodeRabbit, PR #853).
            if [ "${SC[i + 1]-}" = "(" ] && arith_body "$s" $((i + 2)); then
                printf '%s\t%s\n' "$pdepth" "$ARITH_TAG$ARITH_BODY"
            fi
            printf '%s\t%s\n' "$pdepth" "$seg"; seg=''
            if [ "$confused" = "0" ]; then
                kind='O'
                if [ "$no_scope" = "1" ]; then
                    kind='O'
                elif [ "$ptop" -gt 0 ] && [ "${pkind[$((ptop - 1))]}" = "O" ]; then
                    kind='O'
                elif [ "$cmdpos" = "1" ]; then
                    lb=''
                    [ "$i" -gt 0 ] && lb="${SC[i - 1]-}"
                    nx="${SC[i + 1]-}"
                    case "$lb" in
                    '$' | '<' | '>' | '=') kind='O' ;;
                    *)
                        if [ "$nx" = "(" ]; then
                            kind='O'
                        else
                            kind='S'
                        fi
                        ;;
                    esac
                fi
                pkind[ptop]="$kind"; ptop=$((ptop + 1))
                if [ "$kind" = "S" ]; then
                    pdepth=$((pdepth + 1))
                    cmdpos=1
                fi
            fi
            i=$((i + 1))
            ;;
        \))
            printf '%s\t%s\n' "$pdepth" "$seg"; seg=''
            if [ "$confused" = "0" ]; then
                if [ "$ptop" -gt 0 ]; then
                    ptop=$((ptop - 1))
                    if [ "${pkind[$ptop]}" = "S" ]; then
                        pdepth=$((pdepth - 1))
                        cmdpos=1
                    fi
                else
                    confused=1
                fi
            fi
            i=$((i + 1))
            ;;
        \&)
            # HIMMEL-1813: `>&`, `<&` (after an UNESCAPED < or >) and `&>`
            # are redirection operators, never a command separator.
            if [ "$ro" = "1" ] || [ "${SC[i + 1]-}" = ">" ]; then
                seg+="$c"; i=$((i + 1)); ro=0; continue
            fi
            printf '%s\t%s\n' "$pdepth" "$seg"; seg=''; cmdpos=1; i=$((i + 1))
            ;;
        \|)
            # HIMMEL-1813: `>|` (noclobber override) is a redirection.
            if [ "$ro" = "1" ]; then
                seg+="$c"; i=$((i + 1)); ro=0; continue
            fi
            printf '%s\t%s\n' "$pdepth" "$seg"; seg=''; cmdpos=1; i=$((i + 1))
            ;;
        \;|\`|$'\n')
            printf '%s\t%s\n' "$pdepth" "$seg"; seg=''; cmdpos=1; i=$((i + 1))
            ;;
        ' ' | $'\t')
            seg+="$c"; i=$((i + 1))
            ;;
        * )
            seg+="$c"; i=$((i + 1)); cmdpos=0
            case "$c" in '<'|'>') ro=1; continue ;; esac
            ;;
        esac
        ro=0
    done
    printf '%s\t%s\n' "$pdepth" "$seg"
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
    local s="$1" w='' c i n have=0 skip_word=0 LC_ALL=C
    local -a SC
    n=${#s}
    split_bytes "$s" "$n"
    i=0
    while [ "$i" -lt "$n" ]; do
        c=${SC[i]-}
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
                [ "${SC[i]-}" = "'" ] && { i=$((i + 1)); break; }
                w+="${SC[i]-}"; i=$((i + 1))
            done
            ;;
        \")
            i=$((i + 1)); have=1
            while [ "$i" -lt "$n" ]; do
                c=${SC[i]-}
                if [ "$c" = '"' ]; then i=$((i + 1)); break; fi
                if [ "$c" = "\\" ]; then
                    # bash drops a double-quoted backslash only before
                    # $ ` " \ (newline is already folded to ';'); before
                    # anything else it stays word content (HIMMEL-1813:
                    # dropping it hid "...\c" from split_unresolvable).
                    i=$((i + 1))
                    if [ "$i" -lt "$n" ]; then
                        case "${SC[i]-}" in
                        '$'|'`'|'"'|\\) : ;;
                        *) w+="\\" ;;
                        esac
                        w+="${SC[i]-}"; i=$((i + 1))
                    fi
                    continue
                fi
                w+="$c"; i=$((i + 1))
            done
            ;;
        '#')
            if [ "${TOK_ENV_SPLIT:-0}" = "1" ] && [ "$have" = "0" ]; then
                # env -S only: an unquoted '#' at argument start comments
                # out the rest of the split string.
                break
            fi
            w+="$c"; i=$((i + 1)); have=1
            ;;
        \\)
            i=$((i + 1))
            if [ "$i" -lt "$n" ]; then
                if [ "${TOK_ENV_SPLIT:-0}" = "1" ] && [ "${SC[i]-}" = "_" ]; then
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
                    w+="${SC[i]-}"; i=$((i + 1)); have=1
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
                case "${SC[i]-}" in '<'|'>') i=$((i + 1)) ;; *) break ;; esac
            done
            # HIMMEL-1813: `>&` / `<&` (fd duplication) -- the '&' is part
            # of the operator; its operand (1, -, a file) is not a word.
            # `>|` likewise: the '|' is part of the operator.
            if [ "${TOK_ENV_SPLIT:-0}" != "1" ]; then
                case "${SC[i]-}" in '&'|'|') i=$((i + 1)) ;; esac
            fi
            skip_word=1   # the operator's operand is not a word
            ;;
        '&')
            if [ "${TOK_ENV_SPLIT:-0}" != "1" ] && [ "${SC[i + 1]-}" = ">" ]; then
                # HIMMEL-1813: `&>` / `&>>` redirect stdout+stderr: a word
                # before it ends there, the operator and operand are dropped.
                if [ "$have" = "1" ]; then
                    if [ "$skip_word" = "1" ]; then skip_word=0; else printf ':%s\n' "$w"; fi
                    w=''; have=0
                fi
                i=$((i + 1))
                while [ "$i" -lt "$n" ]; do
                    case "${SC[i]-}" in '>') i=$((i + 1)) ;; *) break ;; esac
                done
                skip_word=1
            else
                w+="$c"; i=$((i + 1)); have=1
            fi
            ;;
        * )
            w+="$c"; i=$((i + 1)); have=1
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

    Retry as ONE literal command (HIMMEL-4815): bash ${script} <same args>
    -- no VAR= prefix, no env wrapper, no \$VAR path.

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

deny_unresolvable() {  # deny_unresolvable <script-path> -- from OUR
                       # registry, never raw command text (HIMMEL-1813).
    local script="$1" msg reason
    msg="block-chokepoint-env-prefix: refusing an env -S / --split-string invocation that mentions a sanctioned chokepoint.

    ${script}

    The split string cannot be fully resolved: it carries an escape, quote
    or character (e.g. \\c, \\t, '#', '\${') whose effect on the resulting
    argv this guard does not model, so it cannot prove no seam variable
    reaches the chokepoint. himmel's rule: set env overrides in the
    LAUNCHING shell, never per call. Run the chokepoint bare; if the text
    only mentions the chokepoint, move it into a file and pass the file.

    Retry as ONE literal command (HIMMEL-4815): bash ${script} <same args>
    -- no VAR= prefix, no env wrapper, no \$VAR path.

    To bypass this guard intentionally, set ENV_PREFIX_GUARD_OK=1 in the
    shell that launched Claude Code (a per-call prefix does not reach a
    hook process); restart without it to re-enable the guard."
    reason=$(printf '%s' "$msg" | jq -Rs . 2>/dev/null) \
        || reason='"block-chokepoint-env-prefix: env -S string mentioning a sanctioned chokepoint cannot be fully resolved -- run the chokepoint bare"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
    printf '%s\n' "$msg" >&2
    exit 2
}

deny_raw_mention() {  # deny_raw_mention <script-path> -- from OUR registry,
                      # never raw command text (HIMMEL-1813 backstop).
    local script="$1" msg reason
    msg="block-chokepoint-env-prefix: refusing a command that names a sanctioned chokepoint together with its seam variable or an env -S / --split-string.

    ${script}

    This check runs on the raw command text before any parsing, so it
    ignores quoting, comments, functions and nesting, and it can over-deny
    (e.g. a command that only PRINTS the chokepoint name next to one of its
    seam variables). himmel's rule: set env overrides in the
    LAUNCHING shell, never per call; run the chokepoint bare. If the text
    only mentions the chokepoint, move it into a file and pass the file.

    Retry as ONE literal command (HIMMEL-4815): bash ${script} <same args>
    -- no VAR= prefix, no env wrapper, no \$VAR path.

    To bypass this guard intentionally, set ENV_PREFIX_GUARD_OK=1 in the
    shell that launched Claude Code (a per-call prefix does not reach a
    hook process); restart without it to re-enable the guard."
    reason=$(printf '%s' "$msg" | jq -Rs . 2>/dev/null) \
        || reason='"block-chokepoint-env-prefix: command names a sanctioned chokepoint with its seam variable or env -S -- run the chokepoint bare"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
    printf '%s\n' "$msg" >&2
    exit 2
}

deny_text_layer() {  # deny_text_layer <reason constant> -- OUR text only
                     # (HIMMEL-3921), never raw command text.
    local why="$1" msg reason
    msg="block-chokepoint-env-prefix: refusing a command that ${why}.

    This is the text layer for detached / non-Linux launches (setsid -f, at,
    a double-fork) where the in-session seam guard cannot see the call. It
    runs on the raw command text, ignores parsing and can over-deny.
    himmel's rule: set env overrides in the LAUNCHING shell, never per call;
    run the chokepoint bare with a literal path.

    To bypass this guard intentionally, set ENV_PREFIX_GUARD_OK=1 in the
    shell that launched Claude Code (a per-call prefix does not reach a
    hook process); restart without it to re-enable the guard."
    reason=$(printf '%s' "$msg" | jq -Rs . 2>/dev/null) \
        || reason='"block-chokepoint-env-prefix: obfuscated chokepoint path, shell-startup seam or seam clear beside a chokepoint -- set env overrides in the LAUNCHING shell, not per call"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
    printf '%s\n' "$msg" >&2
    exit 2
}

CR=$'\r'
NL=$'\n'

# relief_off <text> -- HIMMEL-3955. The scoped scans below run ONLY on a command
# made of plain words (`[A-Za-z0-9_./=:@%+,-]+`) joined by spaces or tabs: no
# quote, backslash, $, backtick, redirection, separator, paren, brace, glob
# metachar or newline. rc 0 (relief OFF) for anything else, and the caller
# takes main's plain whole-text match unchanged, so the relief can never loosen
# main on a shape it cannot model (four rounds of blocklisting such shapes each
# missed one). An allowlist, not a parser. And the command's first
# word must be a read-only program (no leading assignment: PATH= or LD_PRELOAD= before it turns the relief off) that cannot exec or
# clear the environment (grep diff ls cat head tail wc stat file cut uniq cmp
# basename dirname realpath readlink echo printf); sed, sort, rg, git, find,
# xargs, shells and every launcher (env sudo su bwrap nix systemd-run
# flatpak-spawn timeout nice stdbuf setsid nohup exec command busybox) are NOT
# in the set, because main's anywhere-match caught their clearing options. No
# word may be env-like (any case) either.
relief_off() {
    local w prog=''
    [[ $1 =~ ^[A-Za-z0-9_./=:@%+,[:blank:]-]*$ ]] || return 0
    for w in $1; do
        case "$(printf '%s' "${w##*/}" | tr '[:upper:]' '[:lower:]')" in env) return 0 ;; esac
        [ -n "$prog" ] && continue
        [[ $w =~ ^[A-Za-z_][A-Za-z0-9_]*[+]?= ]] && return 0 # a leading assignment (PATH=, LD_PRELOAD=) can swap the program: no relief
        prog=$w # a path (./grep) is not the bare program name, so it never matches
    done
    case "$prog" in
        grep|diff|ls|cat|head|tail|wc|stat|file|cut|uniq|cmp|basename|dirname|realpath|readlink|echo|printf) return 1 ;;
    esac
    return 0
}

# env_like_word <plain word> -- rc 0 when its basename is `env`. HIMMEL-3955.
env_like_word() {
    local base=${1##*/}
    [ "$base" = env ]
}

# env_clear_opt <text> -- HIMMEL-3955. rc 0 when a standalone -u*/-i*/--unset*/--ignore-environment/
# bare - token sits in env position: after an `env` word with only option and
# NAME=val words between (any other plain word, e.g. grep/sed/diff/ls/sort/bash,
# ends the position). So `grep -i`, `sed -i`, `diff -u`, `ls -i` and a `--id N`
# flag are not env-clearing; `env -i`, `/usr/bin/env -u X` and
# `setsid -f env -i` still are. Any text relief_off keeps out takes main's
# whole-text match.
# HIMMEL-4095: a LONG option counts only when it is a prefix of
# ignore-environment or unset (GNU getopt_long takes any unique prefix: --i,
# --ign, --un=X) ending at a non-word character (space, =, end, or a quote, $,
# backslash or glob that may splice more on), or when it starts with the whole
# word (--unsetenv, --unset-env, --unset-environment). So --impacted, --update
# and --ignored are not env-clearing; every short -u*/-i* and bare - still is.
env_clear_opt() { # <text> [<text the allowlist gates on; default <text>>]
    local t="$1" w prev head=0 hit=1
    local long='(ignore-environment|unset)[[:alnum:]_-]*|(i|ig|ign|igno|ignor|ignore|ignore-|ignore-e|ignore-en|ignore-env|ignore-envi|ignore-envir|ignore-enviro|ignore-environ|ignore-environm|ignore-environme|ignore-environmen|u|un|uns|unse)([^[:alnum:]_-]|$)'
    local opt="(^|[^[:alnum:]_-]|\\\$[[:alnum:]_]+)-([ui]|[[:space:]]|\$|-($long))"
    if relief_off "${2-$t}"; then
        [[ $t =~ $opt ]] || return 1
        # HIMMEL-4779: a text the allowlist keeps out (a quote, a pipe, sed,
        # sort, git) still clears nothing when pobf_relief's stages put every
        # such token in a read-only stage or among sed's, gh's or an
        # interpreter's own options (grep -n -i 'x', sed -i s/a/b/ f,
        # sort -u, python3 - <<EOF). Anything it cannot model keeps the deny.
        case $- in *f*) pobf_relief "${2-$t}" "$opt" && return 1 ;;
            *) set -f; pobf_relief "${2-$t}" "$opt" && { set +f; return 1; }; set +f ;;
        esac
        return 0
    fi
    prev=''
    for w in $t; do
        if [[ $w =~ $opt ]] && [ "$head" = 1 ]; then hit=0; break; fi
        if env_like_word "$w"; then head=1
        else
            # A plain word right after an option is that option's operand
            # (`env --chdir /tmp -i`), so it does not end the position.
            case "$w" in
                -*|*=*) ;;
                *) case "$prev" in -*=*) head=0 ;; -*) ;; *) head=0 ;; esac ;;
            esac
        fi
        prev=$w
    done
    return $hit
}

# seam_assigned <text> <var> -- HIMMEL-3955. rc 0 when <text> assigns <var>
# (`VAR=`/`VAR+=`) the way a launch would. A `--long-option VAR=x` VALUE with no
# `env` word before it is an ARGUMENT of that program (ledger-append amend
# --set k=v), not an assignment, and does not count. raw_obfuscated only:
# raw_mention (a chokepoint is named) keeps the plain match, since
# `stop-worker.sh --dry-run VAR=9` is a pinned deny.
seam_assigned() {
    local t="$1" v="$2" w prev='' el=0
    local re="(^|[^[:alnum:]_])${v}[+]?="
    if relief_off "$t"; then [[ $t =~ $re ]]; return; fi
    for w in $t; do
        if [[ $w =~ $re ]]; then
            case "$prev" in
                *=*) return 0 ;;
                --[A-Za-z]*) [ "$el" = 1 ] && return 0 ;;
                *) return 0 ;;
            esac
        fi
        env_like_word "$w" && el=1
        prev=$w
    done
    return 1
}

# pobf_word <text> -- rc 0 when <text> holds a path word (one with a `/`) with a
# glob, grouping or extendedglob metachar in any segment: the HIMMEL-4157
# anchor-less test. Only a leading `~` (home) or `#` (comment) is exempt, and
# `$(` / `${` are expansions, not groupings. Caller holds `set -f`.
pobf_word() {
    local w
    for w in ${1//[;|&<>]/ }; do
        case "$w" in */*) ;; *) continue ;; esac
        w=${w//\$\(/}
        w=${w//\$\{/}
        case "${w#[#~]}" in *[\*\?\[\{\(\#^\~]*) return 0 ;; esac
    done
    return 1
}

# pobf_tok -- pobf_relief's helper: close the quoted body into a token.
pobf_tok() {
    if [ -n "$body" ]; then TOK[n]=$body; F="$F$T1$n$T1"; n=$((n + 1)); fi
    body=''
}

# pobf_exp <text> <mode> -- pobf_relief's helper: put the token bodies back
# into <text>, result in PX (no fork). Mode p pads each body with a blank
# each side, s puts one blank in its place, r puts it back as is and then
# drops trailing newlines, as the $( ) it replaces did. The result is that
# of replacing marker k = 0, 1, .. n-1 in turn, but only a k that stands
# between two adjacent \001 marks can match, so only those are visited
# (J1685: a walk over all n per stage or per redirect was super-linear).
# They go in text order when no two share a mark and (mode r) no body is
# all digits, the cases where order cannot change the result; otherwise k
# runs in order over the whole range that can match.
pobf_exp() {
    local x=$1 m=$2 r='' seg ks='' lo=-1 hi=-1 prev=0 ov=0 k
    case "$x" in *"$T1"*) r=${x#*"$T1"} ;; esac
    while :; do
        case "$r" in *"$T1"*) ;; *) break ;; esac
        seg=${r%%"$T1"*}; r=${r:${#seg}+1}
        case "$seg" in ''|*[!0-9]*|0?*) prev=0; continue ;; esac
        if [ "${#seg}" -gt 9 ] || [ "$seg" -ge "$n" ]; then prev=0; continue; fi
        [ "$prev" = 1 ] && ov=1
        prev=1
        ks="$ks $seg"
        if [ "$lo" -lt 0 ] || [ "$seg" -lt "$lo" ]; then lo=$seg; fi
        [ "$seg" -gt "$hi" ] && hi=$seg
        [ "$m" = r ] && case "${TOK[seg]}" in *[!0-9]*) ;; *) ov=1 ;; esac
    done
    if [ "$ov" = 1 ]; then
        k=$lo
        [ "$m" = r ] && hi=$((n - 1))
        # No body holds a \001, so once x has under two marks no marker is
        # left and the rest of the range is a no-op (HIMMEL-4447: walking it
        # per digit-token redirect was redirects x tokens).
        while [ "$k" -le "$hi" ]; do
            case "$x" in *"$T1"*"$T1"*) ;; *) break ;; esac
            pobf_put
            k=$((k + 1))
        done
    else
        for k in $ks; do pobf_put; done
    fi
    if [ "$m" = r ]; then
        k=${x##*[!"$NL"]}
        x=${x%"$k"}
    fi
    PX=$x
}

# pobf_put -- pobf_exp's helper: put token k back into x per mode m.
pobf_put() {
    case "$x" in
        *"$T1$k$T1"*)
            case "$m" in
                r) x=${x//"$T1$k$T1"/"${TOK[k]}"} ;;
                p) x=${x//"$T1$k$T1"/" ${TOK[k]} "} ;;
                *) x=${x//"$T1$k$T1"/ } ;;
            esac ;;
    esac
}

# Every command name pobf_relief gives relief to (plus sed/awk, which lost
# theirs); a function may not shadow one.
POBF_NAMES='ls cat grep egrep fgrep head tail wc echo diff uniq cut stat file du jq basename dirname realpath readlink test tr column nl tac rev fold fmt paste rm find git bash sh zsh dash ksh mksh gh printf sort rg sed gsed awk gawk mawk python python3 node perl ruby command builtin time'

# pobf_relief <raw text> [<env-clear regex>] -- HIMMEL-4157 over-deny relief (judge J1685d: the
# anchor-less arm denied 134 of 164 HANDOVER_DIR history rows, because its
# quote-blind word split counted quoted sed/grep regexes, python programs and
# heredoc prose as path words). Runs ONLY when that arm is about to deny and
# only when the shell-operand form did not match, so it costs nothing on the
# common path. rc 0 (relief: allow) when no path word with a metachar stands
# where something can run or glob-expand it into a command; rc 1 (no relief:
# deny as before) on anything it cannot model.
# It reads quotes and heredocs: each '..', "..", $'..' body and each heredoc
# body becomes a token. The text is split into stages at ; && || | & NL and
# at $( ( ) and backticks; the text after a substitution continues the stage
# it interrupted. Per stage, by its command word:
#   - a read-only program (ls cat grep head tail wc echo diff cut stat jq rm
#     ..., test without -v, printf without -v, sort without --compress, rg
#     without --pre, find without -exec/-ok/-fprint, git grep/log/show/status/
#     ls-files/rev-parse without -O/--ext-diff/--textconv/--output, a shell
#     running a LITERAL script file) skips its words and tokens;
#   - gh (no extension/codespace/ssh/browse/alias/config) and python/node/
#     perl/ruby with no exec, import or spawn word skip only their tokens;
#   - an assignment prefix voids a stage's relief unless it runs a shell on
#     a literal script (PAGER=, GIT_PAGER=, GH_BROWSER= name a program);
#   - sed and awk get NO relief: their scripts run programs (sed e, awk
#     system/getline/pipes) in forms only a parse could rule out (HIMMEL-3930);
#   - anything else is scanned like the old split, tokens included
#     (bash -c 'g?.sh', eval, cat <<EOF | sh).
# Inside $( ) or backticks a read-only stage still has its words scanned, and
# echo/printf/cat its tokens too: that output may become a command word.
# Every stage is scanned (no relief anywhere) when a stage pipes into
# anything but a read-only program (| sh, | xargs, | while read, a
# compound's `done | sh`), or when a file written by a redirect is run again:
# a command word ending in its name, or its name beside a shell, source, `.`,
# exec, eval, xargs, env, nohup, setsid or timeout word; and when any file is
# written (a redirect, tee, cp, mv, install, ln, dd of=) beside a command
# word with a / or one outside the relief names (CR round 8).
# No relief at all on: an unquoted heredoc body with $( or a backtick,
# <( >( =(, a paren glued to a word (zsh grouping, extglob), alias, function,
# hash, enable, an unquoted empty paren pair (`name () {`), an assignment to
# functions/dis_functions/aliases/dis_aliases/galiases/saliases/BASH_ALIASES,
# a PATH/LD_*/IFS/BASH_ENV/ENV/ZDOTDIR assignment, or an unterminated quote or
# heredoc.
# ponytail: an allowed interpreter can still assemble a path with no
# metachar, and the read-only set is a closed list a new exec-capable
# option would slip past; the HIMMEL-3930 structural parse replaces this.
# '$(' and '\' below are literal case patterns, not missed expansions;
# the unquoted $g_* in ${rest%%$g_*} are glob patterns on purpose.
# shellcheck disable=SC2016,SC1003,SC2295
pobf_relief() {
    local t="$1" F='' L rest q md=U body='' n=0 hn=0 hi=0 hb='' cmp i j k c c2 w s x cls nf ostk bqi sub=0 bq=0 stack='' ap wr=0
    local PX p tl rd=0 ea sa eo=${2-} z
    local -a TOK HD HDASH HQ HIX ST SP SS CL CW C2 FL CO XP ED
    local SQ="'" DQ='"' BQ='`' T1=$'\001' T2=$'\002' T3=$'\003' T5=$'\005' TAB=$'\t'
    # Each scan cuts at the first special char with a glob (the prefix up to
    # the first char of the set), not a ^(..)(.*)$ regex, and reads a long
    # line or text 256 chars at a time (rest, the tail in tl): the regex
    # copied the whole rest per quote or stage, quadratic on a long line
    # (J1685). Every choice looks at most 3 chars past the prefix, so rest
    # is topped up while tl is left and rest holds under 4 chars; the heredoc
    # and $'..' regexes, which read on, get the whole tail.
    local g_dq="[${DQ}\\\\\$${BQ}]*"
    local g_uq="[${SQ}${DQ}\\\\\$#<()${BQ}]*"
    local g_sp="[\$();&|${BQ}${NL}]*"
    local re_an="^(([^${SQ}\\\\]|\\\\.)*)${SQ}(.*)\$"
    local re_hd="^<<(-?)[[:blank:]]*(${SQ}([^${SQ}]*)${SQ}|${DQ}([^${DQ}]*)${DQ}|\\\\?([^][:blank:];|&<>()${SQ}${DQ}\\\\]+))(.*)\$"
    local re_wr=">[>|]?[[:blank:]]*([^[:blank:];|&()<>${NL}]*)"
    local re_pa="[^][:blank:];|&()\$<>${BQ}=${NL}]\\(|\\)[^][:blank:];|&()<>${BQ}${NL}]"
    local re_eq="(^|[[:blank:];|&(${NL}])=\\("
    local re_ep="\\([[:blank:]]*\\)"
    local re_dw="(^|[^[:alnum:]_])(alias|unalias|function|hash|enable|disable|zmodload|autoload)([^[:alnum:]_]|\$)"
    local re_as="(^|[[:blank:];|&(${NL}])(PATH|path|LD_[[:alnum:]_]*|DYLD_[[:alnum:]_]*|IFS|BASH_ENV|ENV|ZDOTDIR)\\+?="
    local re_fp="(^|[^[:alnum:]_])(functions|dis_functions|aliases|dis_aliases|galiases|dis_galiases|saliases|dis_saliases|commands|BASH_ALIASES|BASH_CMDS|fpath|FPATH|enable|autoload)([^[:alnum:]_]|\$)"
    local re_sa="(^|[^[:alnum:]_])set([[:blank:]]+[-+][[:alnum:]]*)*[[:blank:]]+[-+][[:alnum:]]*A"
    local re_ix="system|popen|shell=|subprocess|Popen|spawn|exec|eval|qx|os\\.|child_process|pty|__import__|importlib|getattr|require|ctypes|Kernel|open3|IO\\.|%x|${BQ}|\\|-|-\\|"
    case "$t" in *"$T1"*|*"$T2"*) return 1 ;; esac
    t=${t//\\$NL/}
    while IFS= read -r L; do
        if [ "$hi" -lt "$hn" ]; then
            cmp=$L
            [ "${HDASH[hi]}" = - ] && cmp=${L#"${L%%[!"$TAB"]*}"}
            if [ "$cmp" = "${HD[hi]}" ]; then
                TOK[HIX[hi]]=$hb; hb=''; hi=$((hi + 1))
                continue
            fi
            if [ "${HQ[hi]}" = 0 ]; then
                case "$L" in *'$('*|*"$BQ"*) return 1 ;; esac
            fi
            hb="$hb$L$NL"
            continue
        fi
        # A line the regex . cannot read (bytes invalid in this locale) gets no
        # relief: the regex scan the globs below replaced dropped its tail.
        [[ $L =~ ^.*$ ]] || return 1
        rest=${L:0:256}; tl=${L:256}
        while :; do
            if [ -n "$tl" ] && [ "${#rest}" -lt 4 ]; then rest="$rest${tl:0:256}"; tl=${tl:256}; fi
            [ -n "$rest" ] || break
            q=${md#"${md%?}"}
            case "$q" in
                S)
                    case "$rest" in
                        *"$SQ"*)
                            p=${rest%%"$SQ"*}
                            body="$body$p"; rest=${rest:${#p}+1}; md=${md%?}; pobf_tok ;;
                        *) body="$body$rest"; rest='' ;;
                    esac
                    continue ;;
                A)
                    rest="$rest$tl"; tl=''
                    if [[ $rest =~ $re_an ]]; then
                        body="$body${BASH_REMATCH[1]}"; rest=${BASH_REMATCH[3]}; md=${md%?}; pobf_tok
                    else body="$body$rest"; rest=''; fi
                    continue ;;
                D)
                    p=${rest%%$g_dq}
                    body="$body$p"; rest=${rest:${#p}}
                    [ -n "$tl" ] && [ "${#rest}" -lt 4 ] && continue
                    case "$rest" in
                        '') ;;
                        "$DQ"*) md=${md%?}; pobf_tok; rest=${rest#?} ;;
                        # A lone trailing backslash: no relief (it looped).
                        '\') return 1 ;;
                        '\'*) body="$body${rest:0:2}"; rest=${rest#??} ;;
                        '$('*) pobf_tok; md="${md}C"; F="$F$T3\$("; rest=${rest#??} ;;
                        "$BQ"*) pobf_tok; md="${md}B"; F="$F $BQ"; rest=${rest#?} ;;
                        *) body="$body${rest:0:1}"; rest=${rest#?} ;;
                    esac
                    continue ;;
            esac
            # Unquoted: U top level, C inside $( ), P a ( inside it, B backticks.
            p=${rest%%$g_uq}
            F="$F$p"; rest=${rest:${#p}}
            [ -n "$tl" ] && [ "${#rest}" -lt 4 ] && continue
            case "$rest" in
                '') ;;
                "$SQ"*) md="${md}S"; rest=${rest#?} ;;
                "$DQ"*) md="${md}D"; rest=${rest#?} ;;
                '$'"$SQ"*) md="${md}A"; rest=${rest#??} ;;
                '$('*) md="${md}C"; F="$F\$("; rest=${rest#??} ;;
                '$'*) F="$F\$"; rest=${rest#?} ;;
                '\') return 1 ;;
                '\'*) F="$F${rest:0:2}"; rest=${rest#??} ;;
                '#'*)
                    case "$F" in
                        ''|*[[:blank:]\;\|\&\(\)]|*"$NL"|*"$BQ") rest=''; tl='' ;;
                        *) F="$F#"; rest=${rest#?} ;;
                    esac ;;
                '('*) case "$q" in C|P) md="${md}P" ;; esac; F="$F("; rest=${rest#?} ;;
                ')'*)
                    F="$F)"; rest=${rest#?}
                    case "$q" in C|P) md=${md%?}; case "$md" in *D) F="$F$T5" ;; esac ;; esac ;;
                "$BQ"*)
                    F="$F$BQ"; rest=${rest#?}
                    if [ "$q" = B ]; then
                        md=${md%?}; case "$md" in *D) F="$F " ;; esac
                    else md="${md}B"; fi ;;
                '<<<'*) F="$F<<<"; rest=${rest#???} ;;
                '<<'*)
                    rest="$rest$tl"; tl=''
                    [[ $rest =~ $re_hd ]] || return 1
                    HDASH[hn]=${BASH_REMATCH[1]}
                    HD[hn]="${BASH_REMATCH[3]}${BASH_REMATCH[4]}${BASH_REMATCH[5]}"
                    case "${BASH_REMATCH[2]}" in "$SQ"*|"$DQ"*|'\'*) HQ[hn]=1 ;; *) HQ[hn]=0 ;; esac
                    rest=${BASH_REMATCH[6]}
                    HIX[hn]=$n; TOK[n]=''; F="$F $T1$n$T1 "; n=$((n + 1)); hn=$((hn + 1)) ;;
                *) F="$F${rest:0:1}"; rest=${rest#?} ;;
            esac
        done
        [ "$hi" -lt "$hn" ] && [ "$md" != U ] && return 1
        case "$md" in
            *[SDA]) body="$body$NL" ;;
            *) F="$F$NL" ;;
        esac
    done <<< "$t"
    [ "$md" = U ] && [ "$hi" = "$hn" ] || return 1
    case "$F" in *'<('*|*'>('*) return 1 ;; esac
    # FM keeps the markers for a $( opening inside double quotes (T3) and the
    # ) closing it (T5); everything after the scan reads F with them as blanks.
    local FM=$F
    F=${F//$T3/ }; F=${F//$T5/ }
    # No relief (HIMMEL-4442) on an unquoted empty paren pair, on any unquoted
    # word functions, dis_functions, aliases, dis_aliases, galiases,
    # dis_galiases, saliases, dis_saliases, commands, BASH_ALIASES, BASH_CMDS,
    # fpath, FPATH, enable or autoload (delimited by a non-identifier char each
    # side, after quote removal), or on set followed by -A or +A.
    # No relief (HIMMEL-4454) on a definition built at run time, which the text
    # scan above cannot see: an eval command word, or a source / command-word
    # `.`, whatever it reads (a file, stdin, a here-string or here-doc).
    # Process substitution is refused above.
    local re_cp="(^|[;&|({!${NL}]|(^|[[:blank:]])(then|do|else|elif|builtin|command|exec|time|coproc|noglob|nocorrect|eval)[[:blank:]])[[:blank:]]*"
    local re_ev="${re_cp}eval([^[:alnum:]_]|\$)"
    local re_sr="(^|[^[:alnum:]_.])source([^[:alnum:]_]|\$)|${re_cp}\\.[[:blank:]]"
    [[ $F =~ $re_ev ]] && return 1
    [[ $F =~ $re_sr ]] && return 1
    # The same, structurally: split F at ; & | ( ) and backticks (a newline
    # already ends a line), skip what can precede a command word (keywords,
    # their options, assignments, redirects), and refuse relief when the
    # command word is not a plain literal (a quote token, a backslash, a $ or
    # a brace) or is eval, source, `.`, a DEBUG/ERR/ZERR/RETURN trap, a
    # mapfile / readarray -C callback or a zsh emulate -c.
    local re_op="${T3}\\\$[[:blank:]]*\$"
    local sp=0
    local -a stk
    local re_dp='(^|[^$])\(\('
    [[ $F =~ $re_dp ]] && return 1
    local re_rd='^[0-9]*(<<<|<>|>>|>\||&>|<|>)(.*)$'
    local re_tr='(^|[^[:alnum:]_])(DEBUG|ERR|ZERR|RETURN)([^[:alnum:]_]|$)'
    local re_mc='[[:blank:]]-[[:alnum:]]*C'
    local re_ec='[[:blank:]]-[[:alnum:]]*c'
    # Backticks pair up (an escaped one is not a delimiter): the text after a
    # closing one continues the same command, so its first line is no stage.
    local cw sk bj skf G sg
    local -a bqs
    G=${FM//\\$BQ/$'\004'}
    IFS=$BQ read -r -d '' -a bqs <<< "$G" || :
    for bj in "${!bqs[@]}"; do
        skf=0; [ "$bj" -gt 0 ] && [ $((bj % 2)) = 0 ] && skf=1
        # >&, <& and &> are redirects, not a stage break: fold them first.
        sg=${bqs[bj]//>&/>}; sg=${sg//<&/<}; sg=${sg//&>/>}
        while IFS= read -r L; do
            [ "$skf" = 1 ] && { skf=0; continue; }
            cw=''; sk=0
            # A line led by T5 is the text after the ) closing a "$( ): it
            # continues the command that opened it (stk holds that command's
            # word, empty while only assignments precede), so it is no stage.
            if [[ $L == "$T5"* ]]; then
                [ "$sp" -gt 0 ] || return 1
                sp=$((sp - 1)); cw=${stk[sp]}; L=${L#?}
                case "$L" in
                    ''|[[:blank:]]*) ;;
                    *[[:blank:]]*) L=${L#*[[:blank:]]} ;;
                    *) L='' ;;
                esac
            fi
            # Fail closed: any reserved word or compound opener, in any
            # position, means a compound command whose real command word this
            # scan does not model (a [[ test, a coproc name, zsh `always`).
            for w in $L; do
                case "$w" in
                    '[['|if|then|elif|else|fi|while|until|do|done|for|select|case|'esac'|in|function|coproc|time|'!'|'{'|'}'|always|foreach|repeat) return 1 ;;
                esac
            done
            for w in $L; do
                [ -n "$cw" ] && break
                [ "$sk" = 1 ] && { sk=0; continue; }
                case "$w" in
                    if|then|do|else|elif|while|until|'!'|'{'|'}'|time|coproc|nocorrect|noglob|builtin|command|exec|-*) continue ;;
                    repeat) sk=1; continue ;;
                esac
                if [[ $w =~ $re_rd ]]; then [ -z "${BASH_REMATCH[2]}" ] && sk=1; continue; fi
                [[ $w =~ ^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?= ]] && continue
                cw=$w; break
            done
            case "$cw" in
                '') ;;
                *"$T1"*|*"$T2"*|*\\*|*\$*|*\{*|*\}*) return 1 ;;
                eval|source|.) return 1 ;;
                trap) [[ $L =~ $re_tr ]] && return 1 ;;
                mapfile|readarray) [[ $L =~ $re_mc ]] && return 1 ;;
                emulate) [[ $L =~ $re_ec ]] && return 1 ;;
            esac
            # A line ending in the T3 $ of a "$( ) opening: remember its command.
            if [[ $L =~ $re_op ]]; then stk[sp]=$cw; sp=$((sp + 1)); fi
        done <<< "${sg//[;&|()]/$NL}"
    done
    [ "$sp" = 0 ] || return 1
    [[ $F =~ $re_ep || $F =~ $re_fp || $F =~ $re_sa ]] && return 1
    [[ $F =~ $re_eq || $F =~ $re_pa || $F =~ $re_dw || $F =~ $re_as ]] && return 1
    F=${F//[0-9]>&[0-9]/ }
    F=${F//>&[0-9]/ }
    F=${F//[0-9]>&-/ }
    F=${F//>&-/ }
    F=${F//<&[0-9]/ }
    F=${F//&>/>}
    F=${F//|&/|}
    # Split into stages: ST text, SP 1 when it pipes into the next stage, SS 1
    # inside $( ) or backticks (its output may become a command word), CO the
    # stage a substitution interrupted (the text after it continues that one).
    rest=${F:0:256}; tl=${F:256}; s=''; i=0; ostk=''; bqi=0
    while :; do
        p=${rest%%$g_sp}
        s="$s$p"; rest=${rest:${#p}}
        if [ -n "$tl" ] && [ "${#rest}" -lt 4 ]; then rest="$rest${tl:0:256}"; tl=${tl:256}; continue; fi
        case "$rest" in '$'[!\(]*|'$') s="$s\$"; rest=${rest#?}; continue ;; esac
        sub=0; case "$stack" in *S*) sub=1 ;; esac
        [ "$bq" = 1 ] && sub=1
        ST[i]=$s; SS[i]=$sub; SP[i]=0; s=''
        [ -z "${CO[i]-}" ] && CO[i]=-1
        case "$rest" in
            '') i=$((i + 1)); break ;;
            '$(('*) stack="PP$stack"; ostk="- - $ostk"; rest=${rest#???} ;;
            '$('*) stack="S$stack"; ostk="$i $ostk"; rest=${rest#??} ;;
            '('*) stack="P$stack"; ostk="- $ostk"; rest=${rest#?} ;;
            ')'*)
                stack=${stack#?}; w=${ostk%% *}; ostk=${ostk#* }
                case "$w" in -|'') ;; *) CO[i + 1]=$w ;; esac
                rest=${rest#?} ;;
            "$BQ"*)
                if [ "$bq" = 0 ]; then bqi=$i; else CO[i + 1]=$bqi; fi
                bq=$((1 - bq)); rest=${rest#?} ;;
            '||'*|'&&'*|';;'*) rest=${rest#??} ;;
            '|'*) SP[i]=1; rest=${rest#?} ;;
            *) rest=${rest#?} ;;
        esac
        i=$((i + 1))
    done
    # Class per stage: 2 = skip words and tokens, 1 = skip tokens, 0 = scan.
    j=0
    while [ "$j" -lt "$i" ]; do
        s=${ST[j]//[<>]/ }
        c=''; c2=''; ap=0
        for w in $s; do
            [ -n "$c" ] && { c2=$w; break; }
            case "$w" in
                if|then|do|else|elif|while|until|'!'|'{'|'}'|time|command|builtin) continue ;;
            esac
            [[ $w =~ ^[A-Za-z_][A-Za-z0-9_]*\+?= ]] && { ap=1; continue; }
            c=$w
        done
        case "$c" in /bin/*|/usr/bin/*) c=${c##*/} ;; esac
        pobf_exp "${ST[j]}" p; x=$PX; XP[j]=$x
        cls=0
        FL[j]=0
        case "$c" in
            ls|cat|grep|egrep|fgrep|head|tail|wc|echo|diff|uniq|cut|stat|file|du|jq|basename|dirname|realpath|readlink|tr|column|nl|tac|rev|fold|fmt|paste|rm) cls=2 ;;
            # test -v 'a[$(cmd)]' expands the subscript.
            test|'[') case "$x" in *-v*) ;; *) cls=2 ;; esac ;;
            find) case "$x" in *-exec*|*-ok*|*-fprint*|*-fls*) ;; *) cls=2 ;; esac ;;
            git) case "$c2" in
                     grep|log|show|status|ls-files|rev-parse)
                         case "$x" in *--ext-diff*|*--textconv*|*--output*|*--open-files-in-pager*) ;;
                             *) [[ $x =~ (^|[[:space:]])-[[:alnum:]]*O ]] || cls=2 ;;
                         esac ;;
                 esac ;;
            # A shell running a LITERAL script file (no metachar, no option, no
            # -c, not /dev or /proc) takes its args and stdin as data, like any
            # program; a script that runs its args is a self-authored wrapper,
            # which no text layer sees anyway (header: posture, not exploit).
            bash|sh|zsh|dash|ksh|mksh)
                case "$c2" in -*|''|/dev/*|/proc/*) ;; *) [[ $c2 =~ ^[A-Za-z0-9_./+-]+$ ]] && cls=2 ;; esac ;;
            gh) [[ $x =~ extension|ext[[:space:]]|codespace|ssh|browse|alias|config ]] || cls=1 ;;
            printf) case "$x" in *-v*) ;; *) cls=2 ;; esac ;;
            sort) case "$x" in *--compress*) ;; *) cls=2 ;; esac ;;
            rg) case "$x" in *--pre*) ;; *) cls=2 ;; esac ;;
            python|python3|node|perl|ruby) [[ $x =~ $re_ix ]] || cls=1 ;;
        esac
        # An assignment prefix (PAGER=, GIT_PAGER=, GH_BROWSER=, ...) can name a
        # program the command then runs; only a shell on a literal script keeps
        # its relief (BASH_ENV/ENV/PATH are refused above).
        [ "$ap" = 1 ] && case "$c" in bash|sh|zsh|dash|ksh|mksh) ;; *) cls=0 ;; esac
        ED[j]=0
        [ "$ap" = 0 ] && case "$c" in sed|gsed) ED[j]=1 ;; esac
        if [ "${CO[j]-}" -ge 0 ] 2>/dev/null && [ "${CO[j]}" -lt "$j" ]; then
            cls=${CL[CO[j]]}; c=${CW[CO[j]]}; c2=${C2[CO[j]]}; ED[j]=${ED[CO[j]]}
        fi
        CL[j]=$cls; CW[j]=$c; C2[j]=$c2
        [ "$cls" = 2 ] && FL[j]=1
        j=$((j + 1))
    done
    # Global: a pipe into anything but a read-only filter (sh, xargs, while,
    # tee, a compound's `done | sh`), or a file written and named again (a
    # command word ending in its name, or its name beside a shell word: bash
    # f, . f), voids every stage's relief.
    nf=0
    j=1
    while [ "$j" -lt "$i" ]; do
        [ "${SP[j - 1]}" = 1 ] && [ "${FL[j]}" = 0 ] && nf=1
        j=$((j + 1))
    done
    # Per stage, once (J1685: per redirect it was redirects x stages, a fork
    # each): ea joins every command word, sa every shell-like stage's text,
    # each closed by \002, which no token or word holds. "A command word ends
    # in the name" is then ea holding name\002; "a shell stage names it" is
    # sa holding it. Once nf is 1 no later redirect can change a verdict.
    x=$F
    while [[ $x =~ $re_wr ]]; do
        w=${BASH_REMATCH[1]}
        x=${x/>/ }
        case "$w" in /dev/null|/dev/stderr|/dev/stdout|/dev/tty) continue ;; esac
        wr=1
        [ "$nf" = 1 ] && break
        if [ "$rd" = 0 ]; then
            rd=1; ea=$T2; sa=$T2; j=0
            while [ "$j" -lt "$i" ]; do
                pobf_exp "${CW[j]}" r; c=$PX
                ea="$ea$c$T2"
                case "$c" in
                    bash|sh|zsh|dash|ksh|mksh|source|.|exec|eval|xargs|env|nohup|setsid|timeout)
                        # A literal script's later words are its data.
                        s=${ST[j]}
                        [ "${CL[j]}" = 2 ] && s=${C2[j]}
                        while [[ $s =~ $re_wr ]]; do s=${s/"${BASH_REMATCH[0]}"/ }; done
                        pobf_exp "$s" r; sa="$sa$PX$T2" ;;
                esac
                j=$((j + 1))
            done
        fi
        pobf_exp "$w" r; w=${PX##*/}
        [ -z "$w" ] && { nf=1; break; }
        case "$ea" in *"$w$T2"*) nf=1 ;; esac
        case "$sa" in *"$w"*) nf=1 ;; esac
    done
    # CR round 8: a written file (a redirect, tee, cp, mv, install, ln, dd
    # of=) can run under a name the scan above never ties to it (./run after
    # a cd, a PATH directory, a copy). Beside a command word with a / or one
    # outside the relief names, every stage's relief is voided.
    j=0
    while [ "$j" -lt "$i" ]; do
        case "${CW[j]}" in
            tee|cp|mv|install|ln) wr=1 ;;
            dd) case "${ST[j]}" in *of=*) wr=1 ;; esac ;;
        esac
        j=$((j + 1))
    done
    if [ "$wr" = 1 ]; then
        j=0
        while [ "$j" -lt "$i" ]; do
            c=${CW[j]}
            case "$c" in
                '') ;;
                */*) nf=1 ;;
                *) case " $POBF_NAMES " in *" $c "*) ;; *) nf=1 ;; esac ;;
            esac
            j=$((j + 1))
        done
    fi
    j=0
    while [ "$j" -lt "$i" ]; do
        cls=${CL[j]}
        [ "$nf" = 1 ] && cls=0
        # Inside $( ) or backticks the output may become a command word, and any
        # command can print a glob it was handed (find -printf, awk, python3,
        # gh): no stage there has relief, every token is scanned (CR rounds
        # 10, 11).
        [ "${SS[j]}" = 1 ] && cls=0
        if [ -n "$eo" ]; then
            # Env mode (HIMMEL-4779, env_clear_opt): the question is whether a
            # -u/-i/bare - token can clear an environment, not where a path
            # word stands. A read-only stage's words are its own data; sed's,
            # gh's and an interpreter's unquoted option words are their own
            # options (sed -i, python3 -), so only a token left in their
            # quoted or heredoc text counts (sed '1e env -i ..'); any other
            # stage (env, sudo, su, timeout, xargs, $E, a substitution's
            # output) gets no relief.
            # ponytail: a quoted text an interpreter or sed's e command runs
            # is read only for a LITERAL token (an escape like \055i slips
            # past, as it did the old whole-text match), the HIMMEL-3930
            # structural parse closes it.
            [ "$cls$nf${SS[j]}${ED[j]}" = 0001 ] && cls=1
            case "$cls" in
                2) ;;
                1) z=''
                   for w in ${ST[j]}; do
                       case "$w" in *"$T1"*) ;; -*) continue ;; esac
                       z="$z $w"
                   done
                   pobf_exp "$z" p
                   [[ $PX =~ $eo ]] && return 1 ;;
                *) [[ ${XP[j]} =~ $eo ]] && return 1 ;;
            esac
            j=$((j + 1))
            continue
        fi
        case "$cls" in
            2) ;;
            1) pobf_exp "${ST[j]}" s
               pobf_word "$PX" && return 1 ;;
            *) pobf_word "${XP[j]}" && return 1 ;;
        esac
        j=$((j + 1))
    done
    return 0
}

# raw_obfuscated <raw text> -- HIMMEL-3921 text layer, run on the UNTOUCHED
# command. Deny-leaning and parse-free on purpose: every special-case parse
# rule in a guard became a bypass (PR 1494/1501/1508), so this is a plain scan.
# Deny when a shell word names a `scripts/` path with a glob/brace metachar
# (* ? [ {) or a $ after it, or carries an ANSI-C $', AND the text writes a
# seam: a registered seam NAME= assignment, or an export/env/read/printf/
# declare/typeset/readonly/let/eval word (the verb alone denies, so the
# obfuscated seam NAME -- export "$n=1" -- is covered when the path is also
# obfuscated; an obfuscated NAME beside a LITERAL chokepoint path stays a
# residual of this layer). HIMMEL-4157 closed a glob or grouping that hides
# the anchor (scr(ipts)/, (scripts)/, {scripts,x}/, scrip?s/, `cd` then
# ./g?.sh, ./g(o).sh or bash g?.sh, $D/g*.sh) and the zsh extendedglob
# operators # ## ^ ~: any path word with a metachar in any segment, and any
# glob word handed to a shell or `source`, now counts (second loop below).
# ponytail: still open -- a word assembled wholly from variables ($D/$B, no
# metachar), an obfuscated seam NAME or an obfuscated env word (/usr/bin/en?
# -i) beside an anchor-less path, and zsh <-> numeric ranges (the tr splits
# at <); close them with the structural guard once HIMMEL-3930 lands.
raw_obfuscated() {
    local t="$1" w rest v wv vcmd clr d u kw ov tw='' cw='/.claude/worktrees/' xg=0 write=0 obf=0 hard=0 vdata=0 wonly=1 pobf=0 so=0 SQ="'"
    case "$t" in *'('*) xg=1 ;; esac
    wv='(export|env|exec|read|printf|declare|typeset|readonly|let|eval|unset|BASH_ENV|BASH_FUNC_[[:alnum:]_]*|SHELLOPTS|BASHOPTS|extdebug)'
    wv="(^|[^[:alnum:]_/-])$wv([^[:alnum:]_]|$)|[/-]$wv([^[:alnum:]_./-]|$)"
    local ansi_esc="\\\\[^ntr\\\\${SQ}\"abfv]"
    set -f
    for w in $(printf '%s' "$t" | tr ';|&()<>' '       '); do
        case "$w" in
            # A bare $'\t' / $'\n' is ordinary shell; only an ANSI-C word that
            # names a path or carries a hex/unicode/octal escape is obfuscation.
            *'$'"$SQ"*)
                case "$w" in
                    */*|*.sh*) obf=1; hard=1 ;;
                    # Allowlist: only plain whitespace/quote escapes are benign;
                    # ANY other backslash escape (\x \u \U \c \e octal, future
                    # ones) counts as obfuscation.
                    *) [[ $w =~ $ansi_esc ]] && { obf=1; hard=1; } ;;
                esac ;;
            *scripts/*)
                # Any glob/brace/$var after scripts/ counts, unconditionally: no
                # prefix compare or registry resolution (every spelling of a
                # split or quoted segment mis-resolved it). The deny still needs
                # a write or env-clearing token in the same command.
                rest=${w#*scripts/}
                # Blunt, no normaliser: any word containing scripts/ (absolute,
                # ./, or with a leading directory) spelled with a `/.`
                # (`/./`, `/../`) or `//` segment can name any path, so it counts.
                # HIMMEL-4130: the worktree dot directory `/.claude/worktrees/`
                # is not a traversal, so a plain absolute worktree path stops
                # counting. It is stripped only from a wholly plain word
                # ([A-Za-z0-9_./+-]; `+` because worktree dirs are fix+slug) in
                # a text with no `(` at all: the tr above splits a word at `(`,
                # so zsh grouping (`g(o).sh`), extglob (`@(x)`) and glob
                # qualifiers would otherwise look plain (judges J1663, J1663b).
                # Every other `/.` still counts: /./ /../ a trailing /. or /..,
                # any other dot directory, and anything quoted or escaped.
                case "$w" in *//*) obf=1; hard=1 ;; esac
                d=$w
                if [ "$xg" = 0 ] && [[ $w =~ ^[A-Za-z0-9_./+-]+$ ]]; then
                    d=${w//"$cw"/\/}
                fi
                case "$d" in *'/.'*) obf=1; hard=1 ;; esac
                # HIMMEL-4157: zsh extendedglob # ^ ~ count like * ? [ {.
                # HIMMEL-4933: a glob alone is soft -- the read-only relief at
                # the deny (pobf_relief) may clear it; a $var, `/.`, `//` or
                # ANSI-C word is hard and never gets that relief.
                case "$rest" in
                    *'$'*) obf=1; hard=1 ;;
                    *[\*\?\[\{\#^\~]*) obf=1 ;;
                esac ;;
        esac
    done
    # HIMMEL-4148: the tr above splits a word at `(`, so a zsh grouping,
    # alternation or glob flag in the basename (g(o).sh, (go).sh, go.s(h),
    # (#i)GO.sh -- this station's Bash runs zsh -c, which globs them to the
    # chokepoint) left every piece plain. Re-split keeping the parens: any `(`
    # after scripts/ in a word counts, like the glob characters above.
    # HIMMEL-4157: a glob or grouping can hide the scripts/ anchor itself
    # (scr(ipts)/, {scripts,x}/, scrip?s/, or cd then ./g?.sh), and zsh
    # extendedglob adds non-paren operators (g#o.sh, go##.sh, ^x.sh, g*~x.sh).
    # So ANY path word (one holding a `/`) with a glob, grouping or
    # extendedglob metachar in any segment counts, scripts/ or not. Only a
    # leading `~` (home) or `#` (comment) is exempt, and `$(` / `${` are
    # expansions, not groupings (a $var alone stays the ponytail residual).
    for w in $(printf '%s' "$t" | tr ';|&<>' '     '); do
        case "$w" in *scripts/*) case "${w#*scripts/}" in *'('*) obf=1; hard=1 ;; esac ;; esac
        case "$w" in */*) ;; *) continue ;; esac
        w=${w//\$\(/}
        w=${w//\$\{/}
        case "${w#[#~]}" in *[\*\?\[\{\(\#^\~]*) pobf=1 ;; esac
    done
    set +f
    # A slash-less glob word as the SCRIPT operand of a shell or `source`
    # (cd into the directory, then bash g?.sh) names a script the same way.
    # Only the first non-option operand counts (-o/-O, --rcfile and
    # --init-file take a value; a short cluster holding c runs a command
    # string, which needs a path or PATH to reach one). Any other --long
    # option, and a bare --, is skipped (J1685: --norc, --restricted).
    _c_strip_expansion_openers "$t"; d=$REPLY
    # `.` counts only in command position (prose has ". ("): after a
    # separator or `$(`, then any keyword, precommand or VAR=x prefix.
    # `source` counts as any word. The shell may be an absolute path
    # (/bin/bash) or quoted ('bash').
    kw='(then|do|else|elif|if|while|until|time|builtin|command|eval|\{|!|[[:alnum:]_]+=[^[:blank:]]*)'
    # An option value may be quoted, blanks and all (-o "errexit"); each
    # o/O in a short cluster takes its own value (-eo errexit, -oo a b).
    ov="(\"[^\"]*\"|${SQ}[^${SQ}]*${SQ}|[^[:blank:]\"$SQ]+)+"
    [[ $d =~ ((^|[^[:alnum:]_.-])(bash|sh|zsh|dash|ksh|mksh|source)[\"$SQ]?([[:blank:]]+([-+][^-c[:blank:]]*[oO][^c[:blank:]]*([[:blank:]]+${ov})+|--(rcfile|init-file)[[:blank:]]+${ov}|--[^[:blank:]]*|-[^-c[:blank:]]*|\+[^c[:blank:]]*))*|(^|[\;\|\&\(\`=$NL])[[:blank:]]*(${kw}[[:blank:]]+)*\.)[[:blank:]]+([\*\?\[\{\(\^]|[^#~[:blank:]-][^[:blank:]]*[\*\?\[\{\(\#\^\~]) ]] && so=1 && pobf=1
    [ "$obf$pobf" = 00 ] && return 0
    clr='(declare|typeset|local)[[:space:]]+(.*[[:space:]])?\+[[:alnum:]]*x|(^|[^[:alnum:]_-])exec[[:space:]]+-|\$\{!|(^|[^[:alnum:]_-])export[[:space:]]+-[[:alnum:]]*n'
    if [ "$obf" = 0 ]; then
        # The anchor-less arm needs stronger evidence than a write VERB: a glob
        # or regex beside printf/read/export is everyday text (the verb set
        # newly denied 7,777 of 261,405 real-history commands; this arm 615).
        # So it denies on the console marker NAME anywhere, a seam NAME
        # written (below), an env-clearing option beside an `env` word, unset
        # or env -u of a non-literal name, an export/declare/let NAME= or
        # printf -v whose name is assembled ($n, `cmd`), export -n, declare
        # +x, exec -, ${!, or bash startup state; names are read quote-,
        # backslash- and ${}-joined, as raw_mention reads them. ponytail: a
        # seam name assembled for read/mapfile/getopts/for (read "$n") beside
        # an anchor-less path is not seen; close it with the HIMMEL-3930 parse.
        u=${t//[\'\"\\]/}
        rest=$u
        while [[ $rest =~ ^(.*)\$\{[^}]*\}(.*)$ ]]; do rest="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"; done
        u="$u$NL$rest"
        local seg="[^;|&$NL]*" nl="(^|[^[:alnum:]_])"
        [[ $t =~ $clr ]] && write=1
        [[ $u =~ ${nl}(BASH_ENV|BASH_FUNC_[[:alnum:]_]*|SHELLOPTS|BASHOPTS|extdebug|HIMMEL_CONSOLE_LEG)([^[:alnum:]_]|$) ]] && write=1
        # unset / env -u with a NON-literal operand ($n, `cmd`, zsh unset -m
        # pattern); a literal seam operand is caught by the name scan below.
        [[ $u =~ ${nl}unset[[:blank:]]${seg}([\$\`]|-[[:alnum:]]*m) ]] && write=1
        [[ $u =~ ${nl}(export|declare|typeset|readonly|local|let)([[:blank:]]${seg})?[[:blank:]][^=[:blank:]]*[\$\`][^[:blank:]]*= ]] && write=1
        [[ $u =~ ${nl}printf[[:blank:]]+-v[[:blank:]]*[\$\`] ]] && write=1
        # env clearing: -i / --i(gnore-environment) / a bare - anywhere in the
        # env word's segment, or -u / --u(nset) with a non-literal operand.
        [[ $u =~ (^|[^[:alnum:]_.-])env([[:blank:]]${seg})?[[:blank:]]-(-?i|[[:alnum:]]*i|[[:blank:]]|$) ]] && write=1
        [[ $u =~ (^|[^[:alnum:]_.-])env([[:blank:]]${seg})?[[:blank:]](-[[:alnum:]]*u|--u[[:alnum:]-]*)[=[:blank:]]*[^[:blank:]]*[\$\`] ]] && write=1
        # A seam NAME counts when assigned (NAME=, NAME+=, NAME = in (( )),
        # ${NAME:=}; a $NAME / ${NAME read and a == test do not) or after a
        # writer word or option in the same segment (unset, export, read,
        # declare, typeset, local, readonly, let, mapfile, readarray, getopts,
        # for, select, printf -v, env -u, export -n).
        for v in $ALL_SEAM_VARS; do
            case "$v" in ''|*[!A-Za-z0-9_]*) continue ;; esac
            [[ $u =~ (^|[^[:alnum:]_\$\{])${v}[+]?= || $u =~ \$\{${v}:?= ]] && write=1
            [[ $u =~ (^|[^[:alnum:]_\$\{])${v}[[:blank:]]*([-+*/%^\|\&]|<<|>>)?=([^=]|$) ]] && write=1
            [[ $u =~ ${nl}(unset|export|read|declare|typeset|local|readonly|let|mapfile|readarray|getopts|for|select|-[[:alnum:]]*[vun]|--unset)([=[:blank:]]${seg})?[^[:alnum:]_]${v}([^[:alnum:]_]|$) ]] && write=1
        done
        [ "$write" = 1 ] || return 0
        # HIMMEL-4157 (J1685d): a glob handed to a shell or source gets no
        # relief; a glob path word only where pobf_relief cannot clear it.
        if [ "$so" = 0 ]; then
            set -f
            pobf_relief "$t" && { set +f; return 0; }
            set +f
        fi
        deny_text_layer "names a seam or clears the environment beside a path with a glob or grouping in a segment"
    fi
    # ponytail: the verb scan also matches inside a quoted argument value
    # (--set 'reason=...exec...'), skipping quoted spans is a parse rule;
    # HIMMEL-4135 tracks a proven-safe shape or the HIMMEL-3930 structural parse.
    # Not even --reason '<no quote inside>' is safe on raw text: in
    # echo $'a --reason ' ; export SEAM=1 ; echo 'b' that "value" is live code.
    # HIMMEL-4572: a verb is part of a name only when BOTH sides join it to
    # one, - or / on its left AND - . or / on its right (block-chokepoint-
    # env-prefix, scripts/eval/, pr-check-env.sh). One joined side is not
    # enough: -printf and --printf= are printf options that read escapes,
    # .env is process.env/os.env, /usr/bin/env is env. They still count as
    # triggers, but HIMMEL-4933 relieves them (vdata) in argument position of
    # read-only stages beside a glob-only path; heading a stage they deny.
    # A heredoc or quoted body is not
    # skipped: written and run in one call (cat >f <<EOF .. EOF; bash f) it
    # is live code, and its printf can feed a shell a seam name no other arm
    # sees (printf '\101..=1 ..' | sh), so that deny is intended. The refusal
    # names the trigger, always a word from the fixed sets below.
    if [[ $t =~ $wv ]]; then
        write=1
        tw=${BASH_REMATCH[2]:-${BASH_REMATCH[4]}}
        case "$tw" in BASH_FUNC_*) tw='BASH_FUNC_*' ;; esac
        tw="the word $tw"
        # HIMMEL-4933: a verb word that heads a stage (export X; unset X; read
        # x; printf ..) acts; one in argument position (grep env, find -printf)
        # is data and may get the read-only relief below.
        # HIMMEL-4954: a stage also starts after a newline, { or a case-arm ), after a
        # then/do/else/elif/if/while/until/! keyword, and past command/builtin/
        # time/nohup (with their options) or a \ escape. A wider match only
        # fails closed: vdata stays 0 and the relief is withheld.
        vcmd='(^|[;&|(){`'"$NL"']|\$\(|(^|[[:space:]])(then|do|else|elif|if|while|until|!)[[:space:]])'
        vcmd+='([[:space:]]*\\?(command|builtin|time|nohup)[[:space:]]+(-[^[:space:]]*[[:space:]]+)*)*'
        vcmd+='[[:space:]]*\\?(export|env|exec|read|printf|declare|typeset|readonly|let|eval|unset)([^[:alnum:]_]|$)'
        [[ $t =~ $vcmd ]] || vdata=1
    fi
    # Any env-CLEARING token anywhere counts too (no anchoring on a program word
    # or verb): standalone -u*/-i*/--unset*/--ignore-environment/bare -, declare/typeset +x,
    # export -n, exec -<opt>, ${! (same set as raw_mention's clear arm). The
    # standalone -u*/-i*/--unset*/--ignore-environment/bare - token counts only in env position
    # (env_clear_opt, HIMMEL-3955); a seam NAME= counts as an assignment, not
    # as a --long-option's value (seam_assigned).
    # shellcheck disable=SC2016 # ${! is the literal trigger text, not an expansion
    [[ $t =~ $clr ]] && { wonly=0; write=1; tw=${tw:-'declare +x, export -n, exec - or ${!'}; }
    env_clear_opt "$t" && { wonly=0; write=1; tw=${tw:-'an env-clearing -u, -i, --unset, --ignore-environment or bare -'}; }
    for v in $ALL_SEAM_VARS; do
        case "$v" in ''|*[!A-Za-z0-9_]*) continue ;; esac
        seam_assigned "$t" "$v" && { wonly=0; write=1; tw="the seam variable $v"; }
    done
    [ "$write" = 1 ] || return 0
    # HIMMEL-4933: a soft (glob-only) path word that sits only in read-only
    # stages (grep -l export scripts/*/x.sh | sort) is data, not a seam write:
    # the same relief the anchor-less arm above applies. A hard word, a
    # shell/source glob operand, or a stage pobf_relief cannot prove read-only
    # keeps the deny; pobf_relief returns 1 on anything it cannot parse
    # (fail-closed).
    if [ "$hard" = 0 ] && [ "$so" = 0 ] && [ "$vdata" = 1 ] && [ "$wonly" = 1 ]; then
        set -f
        pobf_relief "$t" && { set +f; return 0; }
        set +f
    fi
    deny_text_layer "writes a seam variable beside an obfuscated (glob, brace, ANSI-C or \$var) path under scripts/ (it matched $tw)"
}

# raw_mention <text> <any> -- HIMMEL-1813 parse-independent backstop (console
# ruling at b8ae2143, after a new spelling surfaced every parser round). Deny
# (deny_raw_mention) when <text> names a registered chokepoint's basename AND,
# anywhere in the same text, an assignment to one of that chokepoint's own
# seam vars (`SEAM=`) or an `env` word
# later followed by -S / an -xS cluster / --s... (--split-string and its
# abbreviations); any=1 drops the second condition (the scan_text depth cap).
# The name match runs on the text with quotes and backslashes removed, and
# again with every ${...} also dropped -- both only JOIN characters, so a name
# quoted, escaped or \${}-split apart still matches. Over-deny is accepted.
# names_base <text> <basename> -- rc 0 when <basename> occurs in <text> at the
# start of a path component: the character before it (if any) is not a
# filename character [A-Za-z0-9_.-]. So `go.sh` matches `x/go.sh` but not
# `cargo.sh` (HIMMEL-3914). Left boundary only: the text is backslash-stripped,
# so `go.sh\c` arrives as `go.shc` and a right boundary would miss it. The text
# is also quote-stripped, so `$x"go.sh"` (x empty -> go.sh) arrives as
# `$xgo.sh`: a `$` + identifier run on the left also counts as a boundary.
# Over-deny (`go.sh.bak`) is accepted.
names_base() {
    local t="$1" b="$2" pre l
    while :; do
        case "$t" in *"$b"*) ;; *) return 1 ;; esac
        pre=${t%%"$b"*}
        l=${pre#"${pre%?}"}
        case "$l" in
            [A-Za-z0-9_]) case "$pre" in *'$'*) case "${pre##*\$}" in *[!A-Za-z0-9_]*) ;; *) return 0 ;; esac ;; esac ;;
            [.-]) ;;
            *) return 0 ;;
        esac
        t=${t#"$pre"?}
    done
}

# raw_strip <text> -- raw_mention's join/strip steps into RAW_T (quotes and
# continuations dropped) and RAW_U (RAW_T minus ${...}). Only these pattern ops
# re-decode the whole string in a UTF-8 locale (quadratic on a large heredoc,
# HIMMEL-4729) and every character they test is ASCII, so they alone run under
# C. The class regexes in raw_mention stay in the caller's locale: [[:space:]]
# must still match U+3000 and the other Unicode spaces an IFS can split on.
raw_strip() {
    local LC_ALL=C
    local t="$1"
    t=${t//\\$'\r\n'/}
    t=${t//\\$'\n'/}
    t=${t//[\'\"\\]/}
    # HIMMEL-5153: a Unicode space is a separator for the class regexes only in
    # a UTF-8 locale, so with the ambient locale C/POSIX (no UTF-8 locale
    # installed) U+3000 and friends would pass. Map their UTF-8 byte sequences
    # to an ASCII space here, under C, so the match is the same in every
    # locale. U+00A0, U+0085, U+200B and U+FEFF are included: they are not
    # iswspace but are valid IFS separators (HIMMEL-5152). Pure-ASCII text
    # (the common case) skips the passes.
    case $t in
        *[!$'\001'-$'\177']*)
            local sp
            for sp in $'\302\205' $'\302\240' $'\341\232\200' \
                $'\342\200\200' $'\342\200\201' $'\342\200\202' $'\342\200\203' \
                $'\342\200\204' $'\342\200\205' $'\342\200\206' $'\342\200\207' \
                $'\342\200\210' $'\342\200\211' $'\342\200\212' $'\342\200\213' \
                $'\342\200\250' $'\342\200\251' $'\342\200\257' $'\342\201\237' \
                $'\343\200\200' $'\357\273\277'; do
                t=${t//"$sp"/ }
            done ;;
    esac
    strip_brace_exp "$t"
    RAW_T=$t
    RAW_U=$REPLY
}

# HIMMEL-5154: the result of deleting, again and again, the rightmost
# `${...}` (an opener, then no `}`, then the closer) until none is left. The
# per-delete regex rescan of the whole string was quadratic in the number of
# expansions; this single left-to-right pass keeps a stack of the `${`
# openers since the last retained `}` and drops the nearest one when a `}`
# arrives, which yields the same string (also when a delete joins a `$` and a
# `{` into a fresh opener). Result in REPLY. Callers run under LC_ALL=C.
# Literal-pattern deletions of `$((`, `$(` and `${`, in C: in a UTF-8 locale a
# `${s//lit/}` over multibyte text is quadratic (HIMMEL-5154); the patterns are
# ASCII, so bytes give the same string. Result in REPLY.
_c_strip_expansion_openers() {
    local LC_ALL=C
    local x=${1//\$\(\(/}
    x=${x//\$\(/}
    REPLY=${x//\$\{/}
}

strip_brace_exp() {
    local out="" piece before off hasbrace p k j nparts nsub
    local olen=0 np=0 lastc=""
    local -a pos parts sub
    pos=()
    # split at every `}` in one pass (a trailing `x` keeps a final empty piece)
    IFS='}' read -r -d '' -a parts <<< "$1x" || true
    nparts=${#parts[@]}
    parts[nparts - 1]=${parts[nparts - 1]%x$'\n'}
    for ((k = 0; k < nparts; k++)); do
        piece=${parts[k]}
        hasbrace=1
        [ "$k" -lt $((nparts - 1)) ] || hasbrace=0
        if [ "$lastc" = '$' ] && [ "${piece:0:1}" = '{' ]; then
            pos[np]=$((olen - 1)); np=$((np + 1))
        fi
        # shellcheck disable=SC2016  # literal ${ glob pattern, not meant to expand
        if [[ $piece == *'${'* ]]; then
            # split at every `$` once: a segment that starts with `{` follows a
            # `${` opener at the running offset (re-slicing the remainder per
            # opener was quadratic in the opener count, HIMMEL-5154)
            IFS='$' read -r -d '' -a sub <<< "${piece}x" || true
            nsub=${#sub[@]}
            sub[nsub - 1]=${sub[nsub - 1]%x$'\n'}
            off=$((olen + ${#sub[0]}))
            for ((j = 1; j < nsub; j++)); do
                before=${sub[j]}
                [ "${before:0:1}" = '{' ] && { pos[np]=$off; np=$((np + 1)); }
                off=$((off + 1 + ${#before}))
            done
        fi
        if [ -n "$piece" ]; then
            out+=$piece
            olen=$((olen + ${#piece}))
            lastc=${piece: -1}
        fi
        [ "$hasbrace" = 1 ] || break
        if [ "$np" -gt 0 ]; then
            np=$((np - 1))
            p=${pos[np]}
            out=${out:0:p}
            olen=$p
            lastc=""
            [ "$p" -gt 0 ] && lastc=${out: -1}
        else
            out+='}'
            olen=$((olen + 1))
            lastc='}'
            pos=()
        fi
    done
    REPLY=$out
}

raw_mention() {
    local t="$1" any="$2" u script_path vars_list base v env_s=0
    local env_re='(^|[^[:alnum:]_-])env([^[:alnum:]_-].*)?(^|[^[:alnum:]_-])-(-s|[[:alnum:]]*S)'
    raw_strip "$t"
    t=$RAW_T
    u=$RAW_U
    t="$t$NL$u"
    [[ $t =~ $env_re ]] && env_s=1
    while IFS=$'\t' read -r script_path vars_list; do
        script_path=${script_path%"$CR"}
        vars_list=${vars_list%"$CR"}
        base=${script_path##*/}
        [ -n "$base" ] || continue
        names_base "$t" "$base" || continue
        [ "$any$env_s" = 00 ] || deny_raw_mention "$script_path"
        # Seam arm = an ASSIGNMENT only (console X ruling 07:05): the whole
        # identifier followed by `=` (SEAM=1 cmd, export/declare -x SEAM=,
        # env SEAM=, empty SEAM=). A bare read, `unset SEAM` and `env -u SEAM`
        # were the legitimate clear-and-prove spellings and stay out of THIS
        # arm; since HIMMEL-3921 the clear arm below denies them beside the
        # chokepoint word.
        for v in $vars_list; do
            [[ $t =~ (^|[^[:alnum:]_])${v}[+]?= ]] && deny_raw_mention "$script_path"
        done
        # HIMMEL-5152, beside a chokepoint word: ANY assignment to IFS. Bash
        # splits words on whatever characters IFS holds (U+00A0, U+0085,
        # U+200B, U+FEFF, an ANSI-C tab), so a later `$c` can spell
        # `export -n NAME` or `declare +x NAME` with a separator this text layer
        # does not treat as a space. Denying the assignment closes the class
        # without enumerating separators. A read-only IFS expansion stays out.
        [[ $t =~ (^|[^[:alnum:]_])IFS[+]?= ]] \
            && deny_text_layer "assigns IFS (a word-splitting character the text layer cannot enumerate) beside a sanctioned chokepoint"
        # HIMMEL-3921, beside a chokepoint word: bash startup state that runs
        # before the chokepoint's own first line (BASH_ENV, BASH_FUNC_*,
        # SHELLOPTS, BASHOPTS, extdebug) is refused on sight, and so is CLEARING
        # a seam or the console marker (env -u / --unset / unset / export -n),
        # which the assignment arm above does not see. A detached or
        # double-forked call has no claude ancestor, so the structural guard
        # cannot catch a removal there.
        [[ $t =~ (^|[^[:alnum:]_])(BASH_ENV|BASH_FUNC_|SHELLOPTS|BASHOPTS) || $t =~ extdebug ]] \
            && deny_text_layer "sets bash startup state (BASH_ENV, BASH_FUNC_*, SHELLOPTS, BASHOPTS, extdebug) beside a sanctioned chokepoint"
        # `env` carrying ANY option token (-u NAME, -uNAME, -iu, --unset[=]NAME,
        # -S, -C) denies with no per-spelling parse: GNU env stops option
        # parsing at its first non-option, so the option is the word right
        # after `env`. A chokepoint is never called through `env -<opt>`.
        [[ $t =~ (^|[^[:alnum:]_-])env[[:space:]]+- ]] \
            && deny_text_layer "env with an option (clears or rewrites the environment) beside a sanctioned chokepoint"
        # Deny-leaning, no var-name needed, beside a chokepoint word: a
        # declare/typeset/local +x (drops the export attribute), exec with an
        # option (-c clears the env), ${!prefix*} indirect names, export -n,
        # ANY unset (whatever its argument: an ANSI-C-split, command-substituted
        # or concatenated name defeats a name match), and any standalone -u* /
        # -i* / --u* / --i* / bare - token (env -u spelled through a $var, a
        # glob, an attached NAME or a long option).
        [[ $t =~ (declare|typeset|local)[[:space:]]+(.*[[:space:]])?\+[[:alnum:]]*x \
            || $t =~ (^|[^[:alnum:]_-])exec[[:space:]]+- \
            || $t == *\$\{!* \
            || $t =~ (^|[^[:alnum:]_-])export[[:space:]]+-[[:alnum:]]*n \
            || $t =~ (^|[^[:alnum:]_-])unset([^[:alnum:]_]|$) ]] \
            && deny_text_layer "drops or rewrites the environment (unset of anything, declare +x, exec -c, \${!, export -n, -u/-i/--unset*/--ignore-environment/bare -) beside a sanctioned chokepoint"
        # The standalone -u*/-i*/--unset*/--ignore-environment/bare - token counts only in env
        # position (HIMMEL-3955): grep -i, sed -i, diff -u, a --id flag do not.
        env_clear_opt "$t" "$1" \
            && deny_text_layer "drops or rewrites the environment (unset of anything, declare +x, exec -c, \${!, export -n, -u/-i/--unset*/--ignore-environment/bare -) beside a sanctioned chokepoint"
    done <<<"$REG_LINES"
    return 0
}

# HIMMEL-2927: names cleared by an in-shell `unset` or `export -n` seen so
# far -- accumulates left-to-right across the whole payload, carried to
# every LATER segment (see scan_text's fold and scan_segment's `unset`/
# `export` case). `env -u`/`--unset` is scoped to that ONE invocation's
# child instead -- it feeds the segment-local `names`, not this global.
UNSET_NAMES=''

# HIMMEL-4399: every write to UNSET_NAMES goes through unset_add, which adds
# each whitespace-split word ONCE. scan_segment's `names` already carries the
# inherited UNSET_NAMES, so the old plain append made an assignment-only
# segment append the list to itself -- it doubled per segment and `a=;` x 30
# pinned a CPU for hours. Dedupe keeps the SET of names unchanged (the words
# a later unquoted expansion splits out) and bounds its length. Past
# UNSET_CAP distinct names the hook DENIES: never allow, never truncate.
# ponytail: 256 distinct names is a fixed ceiling (a longer genuine list
# over-denies), raise UNSET_CAP if a real payload trips it.
UNSET_CAP=256
# HIMMEL-4414: UNSET_COUNT is the number of words in UNSET_NAMES, kept in step
# by unset_add (and restored with UNSET_NAMES by scan_text's subshell
# snapshot), so an add is a membership test plus an increment instead of a
# re-split of the whole list. The cap counts every distinct name in the
# payload so far, INHERITED ones included (scan_text seeds scan_segment from
# $inames $UNSET_NAMES): "distinct names seen", not "names cleared".
UNSET_COUNT=0
unset_add() {  # unset_add <word>...
    local arg n
    local -a ws
    for arg in "$@"; do
        IFS=$' \t\n' read -r -d '' -a ws <<<"$arg"
        for n in ${ws[@]+"${ws[@]}"}; do
            case " $UNSET_NAMES " in *" $n "*) continue ;; esac
            UNSET_NAMES="$UNSET_NAMES $n"
            UNSET_COUNT=$((UNSET_COUNT + 1))
            [ "$UNSET_COUNT" -le "$UNSET_CAP" ] || deny_unset_cap
        done
    done
}

deny_unset_cap() {  # OUR text only, never raw command text (HIMMEL-4399).
    local msg reason
    msg="block-chokepoint-env-prefix: refusing a command that assigns or clears more than $UNSET_CAP distinct variable names in the current shell.

    This guard tracks every name a command assigns or clears in the current
    shell so a later segment cannot run a sanctioned chokepoint with a
    cleared seam variable. The count covers every distinct name the command
    has assigned or cleared so far, inherited ones included. Past $UNSET_CAP
    names it fails closed rather than track an unbounded list. Split the
    command into smaller ones.

    To bypass this guard intentionally, set ENV_PREFIX_GUARD_OK=1 in the
    shell that launched Claude Code (a per-call prefix does not reach a
    hook process); restart without it to re-enable the guard."
    reason=$(printf '%s' "$msg" | jq -Rs . 2>/dev/null) \
        || reason='"block-chokepoint-env-prefix: command assigns or clears too many variable names to track -- split it"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
    printf '%s\n' "$msg" >&2
    exit 2
}

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
        u)
            # HIMMEL-2927: same operand shape as C|P|a below, but the
            # caller records the operand as a candidate seam name.
            if [ $((i + 1)) -lt "$n" ]; then
                printf 'unset-attached\n%s\n' "${word:$((i + 1))}"
            else
                printf 'unset-next\n\n'
            fi
            return 0 ;;
        C|P|a)
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
#             DATA for the scan to step over (a dir, an argv[0], an
#             alternate path) -- never command position (-C/--chdir,
#             --argv0).
#   unset  -- mandatory operand, same shape as `arg` (separate word or
#             "--name=VAL" attached), but the operand is also a candidate
#             SEAM NAME (HIMMEL-2927): `env -u`/`--unset` clears it with no
#             assignment word, the same effect an env-prefixed VAR=x is
#             denied for -- so its operand is added to the segment's names
#             like a leading assignment word would be (-u/--unset).
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
unset|unset
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
    unset)
        # HIMMEL-2927: same operand shape as `arg`, but the caller records
        # the operand as a candidate seam name (env -u/--unset clears it
        # with no assignment word).
        if [ "$hasval" = "1" ]; then printf 'unset-attached\n%s\n' "$val"
        else printf 'unset-next\n\n'; fi ;;
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
#
# split_unresolvable <split-string text> -- HIMMEL-1813: true when GNU env's
# split-string grammar can produce an argv tokenize_seg does not model.
# After seven rounds of spelling enumeration (r7 = "\c", ignore the rest)
# the rule inverts: only an explicit resolvable set passes -- plain text,
# quotes, and the escapes \_ \\ \" \' outside quotes, \\ \" inside double
# quotes. Anything else is unresolvable: every other escape (\c, \t, ...),
# any backslash inside single quotes, a trailing backslash, any '#'
# (comment), any '$' (${VAR} expansion), and the separators GNU splits on
# but tokenize_seg does not: ';' (cmd_flat's fold of newline and CR),
# vertical tab, form feed and CR.
split_unresolvable() {
    local s="$1" c i=0 n q=''
    n=${#s}
    case "$s" in *'#'*|*'$'*|*';'*|*$'\v'*|*$'\f'*|*$'\r'*) return 0 ;; esac
    while [ "$i" -lt "$n" ]; do
        c=${s:i:1}
        i=$((i + 1))
        case "$q$c" in
        "'\\") return 0 ;;
        "''"|'""') q='' ;;
        \'|\") q=$c ;;
        "'"*|'"'[!\\]) : ;;
        *\\)
            [ "$i" -lt "$n" ] || return 0
            c=${s:i:1}
            i=$((i + 1))
            if [ "$q" = '"' ]; then
                case "$c" in \\|\") ;; *) return 0 ;; esac
            else
                case "$c" in _|\\|\"|\') ;; *) return 0 ;; esac
            fi
            ;;
        esac
    done
    return 1
}

# split_mention <text> -- deny (deny_unresolvable) when <text>, with quote
# and backslash characters removed, contains the basename of any registered
# chokepoint path. Quote/backslash removal only ever JOINS characters, so a
# name quoted or escaped apart still matches.
split_mention() {
    local t="$1" script_path vars_list base re='^(.*)\$\{[^}]*\}(.*)$'
    t=${t//[\'\"\\]/}
    # GNU env -S expands ${VAR} (an unset one to nothing): drop every
    # ${...} so a name split apart by one still matches.
    while [[ $t =~ $re ]]; do t="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"; done
    while IFS=$'\t' read -r script_path vars_list; do
        script_path=${script_path%"$CR"}
        [ -n "$script_path" ] || continue
        base=${script_path##*/}
        [ -n "$base" ] || continue
        names_base "$t" "$base" && deny_unresolvable "$script_path"
    done <<<"$REG_LINES"
    return 0
}

scan_split_argv() {
    local text="$1" inames="$2" depth="$3" appended="$4"
    local words='' seg_text=''
    # HIMMEL-1813: past the depth cap nothing is simulated, so a split
    # string that mentions a registered chokepoint is denied there too.
    if [ "$depth" -gt 5 ]; then
        split_mention "$text$NL$appended"
        return 0
    fi
    # HIMMEL-1813: a split string the simulation cannot fully model, when
    # it or the appended words mention a registered chokepoint, is denied
    # outright rather than simulated.
    if split_unresolvable "$text"; then
        split_mention "$text$NL$appended"
    fi
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

# wrapper_skip <nice|timeout|stdbuf|ionice|chrt> <index> -- HIMMEL-3904.
# Step over a transparent process wrapper's own options and operand (W/nw
# come from scan_segment's dynamic scope) and set WRAP_NEXT to the index of the
# wrapped command's first word, or -1 when an option cannot be modelled (the
# caller then denies if the segment names a chokepoint). Options are matched
# against an explicit list per wrapper, never a general getopt model: an
# option not on the list is unmodelled, so its operand's role is a guess.
WRAP_NEXT=-1
wrapper_skip() {
    local kind="$1" i="$2" w
    WRAP_NEXT=-1
    while [ "$i" -lt "$nw" ]; do
        w=${W[$i]}
        case "$w" in
        --) i=$((i + 1)); break ;;
        -?*) ;;
        *) break ;;
        esac
        case "$kind:$w" in
        nice:-n|nice:--adjustment|timeout:-s|timeout:-k|timeout:--signal|timeout:--kill-after|\
        stdbuf:-i|stdbuf:-o|stdbuf:-e|stdbuf:--input|stdbuf:--output|stdbuf:--error|\
        ionice:-c|ionice:-n|ionice:--class|ionice:--classdata)
            i=$((i + 2)) ;;
        nice:-n?*|nice:--adjustment=*|nice:-[0-9]*|\
        timeout:-s?*|timeout:-k?*|timeout:--signal=*|timeout:--kill-after=*|\
        timeout:--preserve-status|timeout:--foreground|timeout:-v|timeout:--verbose|\
        stdbuf:-i?*|stdbuf:-o?*|stdbuf:-e?*|stdbuf:--input=*|stdbuf:--output=*|stdbuf:--error=*|\
        ionice:-c?*|ionice:-n?*|ionice:-t|ionice:--ignore|ionice:--class=*|ionice:--classdata=*|\
        chrt:--batch|chrt:--deadline|chrt:--fifo|chrt:--idle|chrt:--other|chrt:--rr|\
        chrt:--reset-on-fork|chrt:--verbose|chrt:--max|chrt:--all-tasks)
            i=$((i + 1)) ;;
        chrt:--*) return 0 ;;
        chrt:-*[!abdfimorRv]*) return 0 ;;
        chrt:-*) i=$((i + 1)) ;;
        *) return 0 ;;
        esac
    done
    # timeout's DURATION is one positional operand. chrt's PRIORITY is a number,
    # optional for -b/-i/-o (util-linux 2.42), and may be followed by its own
    # `--`: consume it only when numeric, so `chrt -b env ...` keeps env.
    case "$kind" in
    timeout) [ "$i" -ge "$nw" ] || i=$((i + 1)) ;;
    chrt)
        if [ "$i" -lt "$nw" ]; then
            case "${W[$i]}" in
            *[!0-9]*) ;;
            *)
                i=$((i + 1))
                if [ "$i" -lt "$nw" ] && [ "${W[$i]}" = "--" ]; then i=$((i + 1)); fi ;;
            esac
        fi ;;
    esac
    [ "$i" -le "$nw" ] || i=$nw
    WRAP_NEXT=$i
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
    local n
    # HIMMEL-3185: an arithmetic body lifted by segment_cmd is not command
    # text -- fold its seam assignments and stop.
    if [[ $seg == "$ARITH_TAG"* ]]; then
        arith_fold "${seg#"$ARITH_TAG"}"
        return 0
    fi
    names="$inames"
    # HIMMEL-2939 (collapse, CR round 4 -- console ruling on the pattern
    # that parked HIMMEL-2929 and ended #635 at round 5): `$[NAME=0]`
    # (legacy arithmetic expansion) is not a segmentation boundary the way
    # `$(`/backtick are, so it never opens a fresh command position of its
    # own. Three straight rounds each found the next arithmetic-operator
    # shape a validity model missed (bare `=`, compound `*=`/`+=`, prefix
    # AND postfix `++`/`--`) -- there is always one more operator. STOP
    # parsing `$[...]`'s grammar: any registered seam var (across every
    # chokepoint, not just the one this payload happens to target --
    # ALL_SEAM_VARS, computed once from the registry) occurring anywhere
    # in a segment carrying the literal `$[`, WORD-BOUNDED (the char
    # before/after is not `[A-Za-z0-9_]`, so a longer name sharing the
    # registered name's PREFIX does not match), folds forward -- no
    # bracket-depth tracking, no operator inspection at all. Documented
    # over-deny: `$[HIMMEL_CONSOLE_LEG+1]` (reads the seam, does not clear
    # it) denies too -- costs nothing; a false ALLOW is the defect class
    # this ticket exists for.
    if [[ $seg == *'$['* ]]; then
        for n in $ALL_SEAM_VARS; do
            [ -n "$n" ] || continue
            if [[ $seg =~ (^|[^A-Za-z0-9_])"$n"($|[^A-Za-z0-9_]) ]]; then
                unset_add "$n"
                # ...and into THIS segment's own names: `bash chokepoint.sh
                # $[ SEAM = 0 ]` expands before the exec, so the call in the
                # same segment must see it (CodeRabbit, PR #853 class sweep).
                names="$names $n"
            fi
        done
    fi
    # ':'-sentinel stream (r6): a blank line is a stream artifact (no
    # word); the line ':' is a zero-length word and MUST take its slot in
    # W -- real getopt consumes it as an operand (env -a '' SEAM=1 cmd
    # runs cmd with the seam) and real exec fails on it at command
    # position; dropping it shifted every later word's role.
    while IFS= read -r w; do
        [ -n "$w" ] || continue
        W[nw]="${w#:}"; nw=$((nw + 1))
    done <<<"$(tokenize_seg "$seg")"
    # HIMMEL-1813: a here-string is scanned as a script (the heredoc body
    # is already scanned through the newline fold) UNLESS its command is a
    # non-executing reader. Fail-closed: any other command, a shell or a
    # `source /dev/stdin`, may run it. Every operand is scanned: the
    # command reads the last, so none is safe to skip. A reader's output
    # can itself reach a shell (a pipe, `$(`, a backtick, `<(` / `>(`), so
    # the reader exemption holds only when the command has none of those.
    if [[ $seg == *'<<<'* ]]; then
        while [ "$j" -lt "$nw" ] && [[ ${W[$j]} =~ $ASSIGN_RE ]]; do j=$((j + 1)); done
        k=reader
        case "$cmd" in *'|'*|*\$\(*|*'`'*|*'<('*|*'>('*) k='' ;; esac
        # `-`: a redirect-only segment (`<<< x`) has no command word, and an
        # unbound W[$j] under nounset would abort the hook (rc=1 = no deny).
        w=${W[$j]-}
        case "$k${w##*/}" in
        readergrep|readercat|readerwc|readerhead|readertail|readertee|readerdiff|readercmp) : ;;
        *)
            k=$seg
            while [[ $k == *'<<<'* ]]; do
                k=${k#*<<<}
                IFS= read -r w <<<"$(tokenize_seg "$k")"
                scan_text "${w#:}" "$names" $((depth + 1))
            done
            ;;
        esac
        j=0
    fi
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
                    unset-attached)
                        # HIMMEL-2927: `--unset=NAME` clears NAME for THIS
                        # env invocation's own command -- same segment,
                        # recorded like a leading assignment word.
                        names="$names $lo_operand"
                        j=$((j + 1)); continue ;;
                    unset-next)
                        # HIMMEL-2927: `--unset NAME` (separate operand).
                        if [ $((j + 1)) -lt "$nw" ]; then
                            names="$names ${W[$((j + 1))]}"
                        fi
                        j=$((j + 2)); continue ;;
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
                    unset-attached)
                        # HIMMEL-2927: attached `-uNAME` clears NAME for
                        # THIS env invocation's own command -- same segment.
                        names="$names $cluster_operand"
                        j=$((j + 1)); continue ;;
                    unset-next)
                        # HIMMEL-2927: separate `-u NAME` (or mid-cluster).
                        if [ $((j + 1)) -lt "$nw" ]; then
                            names="$names ${W[$((j + 1))]}"
                        fi
                        j=$((j + 2)); continue ;;
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
                w=${w%%=*}; names="$names ${w%+}"; j=$((j + 1)); continue
            fi
            phase=start; asg_ok=0
            continue    # reprocess this word at command position
            ;;
        start)
            if [ "$asg_ok" = "1" ] && [[ $w =~ $ASSIGN_RE ]]; then
                w=${w%%=*}; names="$names ${w%+}"; j=$((j + 1)); continue
            fi
            case "$w" in
            env|*/env)
                # A fresh env process: its option parsing starts over
                # ("env -- A=1 env -S '...'": the outer "--" must not
                # leak into the inner env's option scan).
                # HIMMEL-1813: a redirect word of any shape in an env
                # segment makes env's options unresolvable (the tokenizer
                # drops it, so its operand's role is a guess): deny when
                # the segment mentions a registered chokepoint.
                [[ $seg == *[\<\>]* ]] && split_mention "$seg"
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
            nice|*/nice|timeout|*/timeout|stdbuf|*/stdbuf|ionice|*/ionice|chrt|*/chrt)
                # HIMMEL-3904: a transparent process wrapper re-enters
                # command position (`nice env SEAM=x bash chokepoint`), and
                # its operands are words, not assignments. An option the
                # list in wrapper_skip cannot model fails CLOSED when the
                # segment names a chokepoint.
                wrapper_skip "${w##*/}" $((j + 1))
                if [ "$WRAP_NEXT" -lt 0 ]; then split_mention "$seg"; return 0; fi
                asg_ok=0; j=$WRAP_NEXT; continue ;;
            command|exec|nohup)
                # These re-enter command position but their arguments are
                # words, not assignments (command VAR=x foo does not export
                # VAR) -- stop counting assignments.
                asg_ok=0; j=$((j + 1)); continue ;;
            \{|!|time|if|then|else|elif|do|while|until)
                # Grouping/keyword openers start a fresh simple command:
                # assignments after them DO lead it.
                asg_ok=1; j=$((j + 1)); continue ;;
            unset)
                # HIMMEL-2927 (ruling, pr-check round 5): FAIL-CLOSED by
                # construction, not by modelling unset's option grammar --
                # three rounds each found the next edge a validity model
                # missed (-fn, -f -n boundary, `--`, `-x`), so this stops
                # re-implementing bash's option parser. Every remaining word
                # that does NOT start with `-` is a candidate name; a word
                # that starts with `-` (a bare `--` included) is skipped as
                # option-shaped and nothing else about it is inspected --
                # no charset check, no leading-vs-trailing boundary, no
                # invalid-option branch. This also denies an INVALID
                # invocation (`unset -x NAME`) -- a documented over-deny:
                # real bash would refuse that invocation and touch nothing,
                # so denying it here costs nothing and removes a whole class
                # of parser edge to get wrong (over-deny is the safe
                # direction for a guard; a false ALLOW is the defect class
                # this ticket exists for).
                k=$((j + 1))
                while [ "$k" -lt "$nw" ]; do
                    case "${W[$k]}" in
                    -*) ;;
                    *) unset_add "${W[$k]}" ;;
                    esac
                    k=$((k + 1))
                done
                return 0 ;;
            export)
                # HIMMEL-2927/HIMMEL-2933 (ruling, pr-check round 5 + the
                # 2933 extension): same fail-closed simplification as
                # `unset` above, now applied whether or not `-n` is present.
                # `export -n NAME` un-exports NAME (the child no longer
                # inherits it -- the unset direction); `export NAME[=val]`
                # (over)writes NAME's exported value, and `export NAME`
                # alone re-exports its CURRENT value unchanged -- but with
                # no value inspection, either shape is recorded the same
                # fail-closed way (documented arming-direction over-deny:
                # `export SEAM=1` denies too). `export` never leads into a
                # command position of its own, so every remaining
                # non-option word (name stripped of its optional `=value`)
                # is a candidate, full stop -- no charset check, no
                # invalid-option branch.
                k=$((j + 1))
                while [ "$k" -lt "$nw" ]; do
                    case "${W[$k]}" in
                    -*) ;;
                    *) unset_add "${W[$k]%%=*}" ;;
                    esac
                    k=$((k + 1))
                done
                return 0
                ;;
            let|declare|typeset|readonly)
                # HIMMEL-2939 (collapse, CR round 4 -- console ruling, same
                # shape as #635 round 5 and the HIMMEL-2929 park): three
                # straight rounds each found the next `let` operator shape a
                # validity model missed (bare `=`, compound `*=`/`+=`,
                # comma-joined `,NAME=`, prefix `++`, postfix AFTER a comma)
                # -- modelling this grammar never terminates, there is
                # always one more operator. STOP: do not parse `=`, commas,
                # `++`/`--` or leading identifiers at all. Any registered
                # seam var (across every chokepoint -- ALL_SEAM_VARS,
                # computed once from the registry) occurring anywhere in a
                # remaining word, WORD-BOUNDED (the char before/after is not
                # `[A-Za-z0-9_]`, so a longer name sharing the registered
                # name's PREFIX does not match), folds forward regardless of
                # assignment shape (`declare -p NAME` denies too, a
                # documented over-deny). Documented over-deny: `let
                # x=HIMMEL_CONSOLE_LEG+1` (reads the seam, does not clear
                # it) denies too -- costs nothing; a false ALLOW is the
                # defect class this ticket exists for.
                #
                # CR round 5 (console ruling): round 4 still skipped every
                # dash-prefixed word (`-*) ;;`) as if it were an option --
                # that skip IS grammar modelling in disguise. `let`
                # evaluates each operand as arithmetic, where a LEADING `--`
                # after the `--` option-terminator is the prefix-decrement
                # operator, not a flag: `let -- '--HIMMEL_CONSOLE_LEG'`
                # genuinely decrements the seam (verified live) and the
                # dash-skip hid it from the scan. Deleted: every remaining
                # word, dash-prefixed or not, goes through the word-bounded
                # scan unconditionally -- `-` is outside `[A-Za-z0-9_]`, so
                # the word-boundary match already handles it correctly.
                k=$((j + 1))
                while [ "$k" -lt "$nw" ]; do
                    for n in $ALL_SEAM_VARS; do
                        [ -n "$n" ] || continue
                        if [[ "${W[$k]}" =~ (^|[^A-Za-z0-9_])"$n"($|[^A-Za-z0-9_]) ]]; then
                            unset_add "$n"
                        fi
                    done
                    k=$((k + 1))
                done
                return 0 ;;
            read)
                # HIMMEL-2939 (collapse, CR round 4 continued -- console
                # ruling): `read NAME [NAME2 ...]` assigns every operand
                # name, but an operand can also be an ARRAY-ELEMENT form
                # (`NAME[0]`) -- whole-word capture folded the literal
                # "NAME[0]" text, which never exact-matched the registered
                # "NAME" in check_invocation. Same fix as `let`/`declare`/
                # `$[...]`: word-bounded substring match against
                # ALL_SEAM_VARS instead of capturing the whole word (a
                # `-p`/`-d` option's OWN operand is scanned too, documented
                # over-deny, no option-argument modelling).
                #
                # CR round 5 (console ruling): same `-*) ;;` deletion as the
                # `let` arm above, for consistency -- no option-shape
                # modelling anywhere in this collapse, every remaining word
                # goes through the scan unconditionally.
                k=$((j + 1))
                while [ "$k" -lt "$nw" ]; do
                    for n in $ALL_SEAM_VARS; do
                        [ -n "$n" ] || continue
                        if [[ "${W[$k]}" =~ (^|[^A-Za-z0-9_])"$n"($|[^A-Za-z0-9_]) ]]; then
                            unset_add "$n"
                        fi
                    done
                    k=$((k + 1))
                done
                return 0 ;;
            mapfile|readarray)
                # HIMMEL-2943 (residual deferred off HIMMEL-2939 round 5,
                # codex-1): `mapfile NAME <<< 0` (readarray is its alias)
                # reads stdin into array NAME, converting a scalar seam
                # variable into an array -- bash does not export arrays to
                # child processes, so a later chokepoint loses the seam with
                # no name folded into UNSET_NAMES. Same STOP-parsing-grammar
                # ruling as the `let`/`read` arms above (round 5): no
                # option-shape model, every remaining word goes through the
                # word-bounded scan unconditionally, so a value-taking
                # option's own operand (`-C callback`, `-c quantum`) is
                # scanned too -- documented over-deny, costs nothing.
                k=$((j + 1))
                while [ "$k" -lt "$nw" ]; do
                    for n in $ALL_SEAM_VARS; do
                        [ -n "$n" ] || continue
                        if [[ "${W[$k]}" =~ (^|[^A-Za-z0-9_])"$n"($|[^A-Za-z0-9_]) ]]; then
                            unset_add "$n"
                        fi
                    done
                    k=$((k + 1))
                done
                return 0 ;;
            printf)
                # HIMMEL-2939 (collapse, CR round 4 continued -- console
                # ruling): unlike unset/export/read, printf's other words are
                # a format string and data, not names -- only `-v`'s operand
                # (attached or the next word) is a candidate, but that
                # operand can also be an array-element form (`NAME[0]`) --
                # same word-bounded substring match against ALL_SEAM_VARS as
                # the `read` arm, instead of capturing the whole word.
                k=$((j + 1))
                while [ "$k" -lt "$nw" ]; do
                    case "${W[$k]}" in
                    -v)
                        if [ $((k + 1)) -lt "$nw" ]; then
                            for n in $ALL_SEAM_VARS; do
                                [ -n "$n" ] || continue
                                if [[ "${W[$((k + 1))]}" =~ (^|[^A-Za-z0-9_])"$n"($|[^A-Za-z0-9_]) ]]; then
                                    unset_add "$n"
                                fi
                            done
                        fi
                        k=$((k + 2)); continue ;;
                    -v?*)
                        for n in $ALL_SEAM_VARS; do
                            [ -n "$n" ] || continue
                            if [[ "${W[$k]#-v}" =~ (^|[^A-Za-z0-9_])"$n"($|[^A-Za-z0-9_]) ]]; then
                                unset_add "$n"
                            fi
                        done
                        k=$((k + 1)); continue ;;
                    -*) k=$((k + 1)); continue ;;
                    *) break ;;
                    esac
                done
                return 0 ;;
            esac
            # The invoked-program token of this segment. Words beyond it
            # are arguments and never match (the finding-4 direction).
            check_invocation "$w" "$names"
            return 0
            ;;
        esac
    done
    # HIMMEL-2933: a segment consumed ENTIRELY as leading assignment words
    # (phase never left "start", no command word was ever reached) is a
    # bare shell assignment -- `SEAM=0;` / `SEAM=0 OTHER=1;` with nothing
    # after -- which bash runs in the CURRENT shell, so it persists to
    # every LATER segment exactly like `unset`/`export -n` (HIMMEL-2927).
    # Fold this segment's collected names into the same accumulator. `env`/
    # `interp` phases exhausting the same way do NOT persist (an env-scoped
    # assignment with no trailing command doesn't export or set anything)
    # and are excluded by the phase check.
    if [ "$phase" = "start" ] && [ "$asg_ok" = "1" ]; then
        unset_add "$names"
    fi
    return 0
}

# scan_text <command text> <inherited assignment names> <depth> -- segment
# and scan; the recursion target for eval / -c strings (depth-capped:
# deeper reconstruction is the documented determined-bypass residual).
# HIMMEL-2929: a clear learned at paren-depth >=1 must not outlive its
# subshell -- snapshot UNSET_NAMES on the way down each depth, restore it
# on the way back up, so it folds back to what stood outside the `(...)`.
# depth > 0 means this text IS an eval/`-c` string's re-parsed operand (the
# only caller passing depth+1) -- force segment_cmd's no_scope regardless
# of what that string itself contains (CodeRabbit, PR #643 @ 5ce5bbed).
scan_text() {
    local text="$1" inames="$2" depth="$3" line pdepth seg cur=0 force=0
    local -a PSNAP PSNAPN
    # HIMMEL-1813: past the depth cap a chokepoint mention denies (fail-closed).
    [ "$depth" -le 5 ] || { raw_mention "$text" 1; return 0; }
    [ "$depth" -gt 0 ] && force=1
    while IFS= read -r line; do
        pdepth=${line%%$'\t'*}
        seg=${line#*$'\t'}
        if [ "$pdepth" -gt "$cur" ]; then
            PSNAP[pdepth]="$UNSET_NAMES"; PSNAPN[pdepth]=$UNSET_COUNT
            cur=$pdepth
        elif [ "$pdepth" -lt "$cur" ]; then
            UNSET_NAMES="${PSNAP[$((pdepth + 1))]}"; UNSET_COUNT=${PSNAPN[$((pdepth + 1))]}
            cur=$pdepth
        fi
        [[ $seg =~ [^[:space:]] ]] || continue
        # HIMMEL-2927: an in-shell `unset`/`export -n` or an `env -u`/
        # `--unset` in an EARLIER segment clears a name for every LATER
        # segment in this same payload -- fold the accumulator in fresh
        # each iteration so it reflects only what ran before this segment.
        scan_segment "$seg" "$inames $UNSET_NAMES" "$depth"
    done <<<"$(segment_cmd "$text" "$force")"
    return 0
}

# One registry read: "path<TAB>var var ..." per line; check_invocation is
# its only consumer. An empty/unreadable registry allows (fail-open).
REG_LINES=$(jq -r 'to_entries[] | "\(.key)\t\((.value.seam_env_vars // []) | join(" "))"' "$REGISTRY" 2>/dev/null) || REG_LINES=''
[ -n "$REG_LINES" ] || exit 0

# HIMMEL-2939 (collapse, CR round 4): every seam var name across every
# chokepoint, flattened once -- scan_segment's `let`/`declare`/`$[...]`
# folds check membership against THIS (the registry's own var set), never
# against `$names` (the per-segment accumulator check_invocation reads,
# not a source of truth for "is this name registered anywhere").
ALL_SEAM_VARS=''
while IFS=$'\t' read -r _reg_path _reg_vars; do
    _reg_vars=${_reg_vars%"$CR"}
    ALL_SEAM_VARS="$ALL_SEAM_VARS $_reg_vars"
done <<<"$REG_LINES"

# HIMMEL-1813 backstop, on the untouched command. It runs BEFORE scan_text
# so a nounset abort or a hook timeout inside the parser cannot skip it
# (console X ruling at 64bc44b1); where both would deny, the backstop's
# message now fires instead of the parser's more specific one.
raw_obfuscated "$raw_cmd"
raw_mention "$raw_cmd" 0
scan_text "$cmd_flat" "" 0

exit 0
