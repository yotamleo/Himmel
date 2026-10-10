#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-chokepoint-env-prefix.sh (HIMMEL-1746:
# deny env-prefixed invocations of the REGISTERED sanctioned chokepoints).
#
# The SHIPPED registry (scripts/chokepoints.json) drives the fixtures: every
# (chokepoint, seam var) pair the registry carries is exercised, so a new
# registry entry is covered by this suite without editing it. No hand-written
# duplicate of the predicate lives here -- that is the drift class
# (PR #1680 / #1691) the registry exists to prevent.
#
# Intended behavior pinned by this suite:
#   - registered chokepoint + registered seam var as a per-call prefix (or an
#     `env` wrapper argument) -> DENY, with the message naming the
#     launching-shell convention;
#   - bare invocation, unregistered script, unregistered var, and a seam var
#     registered for a DIFFERENT chokepoint -> ALLOW (fail-open; the registry
#     is the predicate, not a general env ban).
#
# Usage: bash scripts/hooks/test-block-chokepoint-env-prefix.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed
# bash 3.2-compatible. ASCII only.
set -uo pipefail

# Invoked via `bash` below, never chmod'd: making the hook executable from
# the suite would hide a missing exec-bit/wiring problem and leave file-mode
# changes behind on POSIX checkouts with core.filemode=true (HIMMEL-1761
# class; HIMMEL-1803). git status must be clean after a run.
HOOK="$(cd "$(dirname "$0")" && pwd)/block-chokepoint-env-prefix.sh"
REPO_ROOT=$(cd "$(dirname "$HOOK")/../.." && pwd -P)
REGISTRY="$REPO_ROOT/scripts/chokepoints.json"

FAILED=0
CASES=0

# Registry-driven fixtures (never hand-duplicated above the shipped data).
# tr -d '\r': jq's Windows text-mode stdout emits CRLF; a CR riding the last
# var of an entry would corrupt every command built from it (same trap the
# hook strips at its own read).
reg_entry() {  # reg_entry <basename-suffix> -> prints "path<TAB>var var ..."
    jq -r --arg suf "$1" 'to_entries[] | select(.key | endswith($suf)) | "\(.key)\t\((.value.seam_env_vars // []) | join(" "))"' "$REGISTRY" | tr -d '\r'
}
STOP_WORKER=$(reg_entry "stop-worker.sh" | cut -f1)
STOP_WORKER_VARS=$(reg_entry "stop-worker.sh" | cut -f2)
MERGE_ON_GREEN=$(reg_entry "merge-on-green.sh" | cut -f1)
MERGE_ON_GREEN_VARS=$(reg_entry "merge-on-green.sh" | cut -f2)
SW_VAR=$(printf '%s' "$STOP_WORKER_VARS" | awk '{print $1}')
MOG_VAR=$(printf '%s' "$MERGE_ON_GREEN_VARS" | awk '{print $1}')

# Fail fast if the shipped registry did not yield the fixtures this suite
# names -- silent empties would turn every assert below into noise.
if [ ! -f "$REGISTRY" ] || [ -z "$STOP_WORKER" ] || [ -z "$SW_VAR" ] \
   || [ -z "$MERGE_ON_GREEN" ] || [ -z "$MOG_VAR" ]; then
    echo "FAIL fixture: registry $REGISTRY did not yield stop-worker.sh / merge-on-green.sh entries"
    exit 1
fi

j() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
jp() { printf '{"tool_name":"PowerShell","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }

# HOOK_WRAP: an optional wrapper argv the hook runs under (empty = none).
HOOK_WRAP=''

# run <json> [ENV=VAL ...] -> runs the hook, sets OUT/ERR/RC.
run() {
    local input="$1"; shift
    local outf errf
    outf=$(mktemp); errf=$(mktemp)
    # shellcheck disable=SC2086 # HOOK_WRAP is a space-joined wrapper argv
    printf '%s' "$input" | env -u ENV_PREFIX_GUARD_OK -u CHOKEPOINT_REGISTRY "$@" $HOOK_WRAP bash "$HOOK" >"$outf" 2>"$errf"
    RC=$?
    OUT=$(cat "$outf"); ERR=$(cat "$errf")
    rm -f "$outf" "$errf"
}

assert_allow() {  # assert_allow <label> <json> [ENV=VAL ...]
    local label="$1"; shift
    run "$@"
    local decision
    decision=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)
    CASES=$((CASES + 1))
    if [ "$RC" = "0" ] && [ "$decision" != "deny" ]; then
        echo "PASS $label (allowed, untouched)"
    else
        echo "FAIL $label -- expected rc=0 with no deny decision, got rc=$RC decision='$decision'"
        FAILED=$((FAILED + 1))
    fi
}

assert_deny() {  # assert_deny <label> <json>
    local label="$1"; shift
    run "$@"
    local decision
    decision=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)
    CASES=$((CASES + 1))
    if [ "$RC" = "2" ] && [ "$decision" = "deny" ] \
       && grep -q "LAUNCHING shell" <<<"$ERR"; then  # a here-string: piping into grep -q races SIGPIPE under pipefail
        echo "PASS $label (denied, message names the launching-shell convention)"
    else
        echo "FAIL $label -- expected rc=2 + permissionDecision=deny + launching-shell message, got rc=$RC decision='$decision'"
        FAILED=$((FAILED + 1))
    fi
}

# --- DENIED: every registered (chokepoint, seam var) pair, straight from the
# shipped registry -- the suite auto-grows with the registry. ---
while IFS=$'\t' read -r reg_path reg_vars; do
    [ -n "$reg_path" ] || continue
    # shellcheck disable=SC2086 # space-joined registry list is split intentionally
    for reg_var in $reg_vars; do
        assert_deny "registry pair ${reg_var}= on $reg_path" "$(j "${reg_var}=1 bash $reg_path --list")"
    done
done < <(jq -r 'to_entries[] | "\(.key)\t\((.value.seam_env_vars // []) | join(" "))"' "$REGISTRY" | tr -d '\r')

# --- DENIED: the named ticket shapes + wrapper/compound variants ---
assert_deny "env wrapper on $MERGE_ON_GREEN"            "$(j "env ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny "env -u PATH wrapper (flag consumes value)" "$(j "env -u PATH ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny "path-qualified /usr/bin/env wrapper"       "$(j "/usr/bin/env ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny "assignment run after benign prefix"        "$(j "BENIGN_TOKEN=1 ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny "quoted assignment value"                   "$(j "${MOG_VAR}='a b' bash $MERGE_ON_GREEN")"
assert_deny "compound after &&"                         "$(j "cd /tmp && ${SW_VAR}=9 bash $STOP_WORKER --list")"
assert_deny "second line of a newline compound"         "$(j "git status
${SW_VAR}=9 bash $STOP_WORKER --list")"
assert_deny "\$CLAUDE_PROJECT_DIR-qualified path"       "$(j "${MOG_VAR}=1 bash \"\$CLAUDE_PROJECT_DIR/$MERGE_ON_GREEN\"")"
assert_deny "PowerShell tool carrying the same shape"   "$(jp "${MOG_VAR}=1 bash $MERGE_ON_GREEN")"

# HIMMEL-4815: the deny names its literal retry (the bare chokepoint), built
# from registry fields only.
run "$(j "${MOG_VAR}=1 bash $MERGE_ON_GREEN")"
CASES=$((CASES + 1))
if grep -qF ": bash $MERGE_ON_GREEN <same args>" <<<"$ERR"; then
    echo "PASS deny names the literal bare-chokepoint retry"
else
    echo "FAIL deny lacks the literal retry line: $ERR"
    FAILED=$((FAILED + 1))
fi

# --- HIMMEL-2927: `env -u`/`--unset` and an in-shell `unset`/`export -n`
# clear a registered seam with no assignment word, so the assignment
# predicate above never fires -- same defect class as VAR=x, inside the
# registered set. HIMMEL_CONSOLE_LEG is a registered seam of
# merge-on-green.sh (chokepoints.json) and, since #630, is what makes
# merge-on-green.sh require the console's GO file -- clearing it unguarded
# silently disarms the HIMMEL-2919 gate. `unset`/`export -n` are cross-segment
# by design (the shell effect crosses segments too), so the chokepoint's
# segment can come later in the same payload. ---
assert_deny "env -u clears a registered seam"                    "$(j "env -u HIMMEL_CONSOLE_LEG bash $MERGE_ON_GREEN 1")"
assert_deny "env --unset=NAME clears a registered seam"          "$(j "env --unset=HIMMEL_CONSOLE_LEG bash $MERGE_ON_GREEN 1")"
assert_deny "env --unset NAME (separate operand) clears a seam"  "$(j "env --unset HIMMEL_CONSOLE_LEG bash $MERGE_ON_GREEN 1")"
assert_deny "in-shell unset; then the chokepoint"                 "$(j "unset HIMMEL_CONSOLE_LEG; bash $MERGE_ON_GREEN 1")"
assert_deny "in-shell unset && then the chokepoint"               "$(j "unset HIMMEL_CONSOLE_LEG && bash $MERGE_ON_GREEN 1")"
assert_deny "export -n; then the chokepoint"                      "$(j "export -n HIMMEL_CONSOLE_LEG; bash $MERGE_ON_GREEN 1")"
# codex-1 (pr-check round 1): export's flags (-f/-n/-p) combine and
# reorder freely -- `-np`/`-pn` genuinely strip the export attribute in
# real bash (verified), same as a bare `-n`, so a combined cluster must
# be recognized too, not just the exact word "-n".
assert_deny "export -np (combined cluster); then the chokepoint"  "$(j "export -np HIMMEL_CONSOLE_LEG; bash $MERGE_ON_GREEN 1")"
assert_deny "export -pn (reordered cluster); then the chokepoint" "$(j "export -pn HIMMEL_CONSOLE_LEG; bash $MERGE_ON_GREEN 1")"
# Over-match controls: these must stay ALLOWED -- the widened predicate is
# scoped to REGISTERED seam names of a chokepoint actually in the SAME
# payload, never a general env/unset ban.
assert_deny "env -u UNREGISTERED name beside a chokepoint (3921 r3 over-deny: any env option)" "$(j "env -u SOME_OTHER_VAR bash $MERGE_ON_GREEN 1")"
assert_allow "unset with no chokepoint in the payload"            "$(j "unset HIMMEL_CONSOLE_LEG; echo hi")"
assert_allow "env -u registered name, non-chokepoint program"     "$(j "env -u HIMMEL_CONSOLE_LEG bash scripts/some/unregistered-script.sh")"

# --- HIMMEL-2933: the third way to clear a registered seam from an earlier
# segment -- a plain or exported ASSIGNMENT, with no `unset`/`export -n`/
# `env -u` in sight. `SEAM=0;`/`SEAM=;` is a segment consumed ENTIRELY as
# leading assignment words with no command word ever reached -- bash runs
# that in the current shell and it persists to every LATER segment, the
# same cross-segment effect HIMMEL-2927 folds `unset`/`export -n` into.
# `export SEAM=`/`export SEAM=0 &&` sets it AND exports it; `export SEAM`
# alone (no `=`) re-exports an already-set value unchanged, but is recorded
# anyway -- fail-closed, no value inspection, same posture as HIMMEL-2927. ---
assert_deny "bare assignment; then the chokepoint (SEAM=0;)"      "$(j "HIMMEL_CONSOLE_LEG=0; bash $MERGE_ON_GREEN 1")"
assert_deny "bare assignment to empty; then the chokepoint"       "$(j "HIMMEL_CONSOLE_LEG=; bash $MERGE_ON_GREEN 1")"
assert_deny "two assignment words in the earlier segment"         "$(j "HIMMEL_CONSOLE_LEG=0 OTHER=1; bash $MERGE_ON_GREEN 1")"
assert_deny "export to empty; then the chokepoint"                "$(j "export HIMMEL_CONSOLE_LEG=; bash $MERGE_ON_GREEN 1")"
assert_deny "export SEAM=0 && the chokepoint"                     "$(j "export HIMMEL_CONSOLE_LEG=0 && bash $MERGE_ON_GREEN 1")"
assert_deny "export NAME=1 (no -n): also denies (arming-direction over-deny)" "$(j "export HIMMEL_CONSOLE_LEG=1; bash $MERGE_ON_GREEN 1")"
assert_deny "export bare NAME (already-set, no =): recorded fail-closed" "$(j "export HIMMEL_CONSOLE_LEG; bash $MERGE_ON_GREEN 1")"
# Over-match controls: unaffected.
assert_allow "unrelated bare assignment; then the chokepoint"     "$(j "OTHER_VAR=0; bash $MERGE_ON_GREEN 1")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): chokepoint FIRST; bare assignment in a LATER segment" "$(j "bash $MERGE_ON_GREEN 1; HIMMEL_CONSOLE_LEG=0")"

# HIMMEL-2927 ruling (pr-check round 5): unset/export option-VALIDITY
# modelling is GONE. Three CR rounds each found the next edge a validity
# model missed (-fn, the -f leading/trailing boundary, `--`, `-x`), and
# round 5 surfaced a genuine BYPASS in the validity model itself
# (`export -n -- NAME` -- real bash treats `--` as ending option parsing
# and still strips NAME's export attribute, but a validity-charset model
# read the bare `--` as an invalid option and skipped recording the
# clear). The ruling: stop re-implementing bash's option parser. For
# `unset`, or an `export` carrying `-n` anywhere in its leading run of
# option-shaped words (`--` and combined forms included), EVERY remaining
# word that does not start with `-` is a candidate name, full stop -- no
# charset check, no leading-vs-trailing distinction, no invalid-option
# branch. Consequence, deliberate: several shapes previously modelled
# (correctly, at the time) as ALLOWED now DENY too -- documented
# over-deny, since real bash would refuse or no-op these invocations
# anyway, so denying them here costs nothing and removes a parser this
# guard has no business re-implementing. Over-deny is the safe direction
# for a guard; a false ALLOW (codex-1's `export -n -- NAME` finding) is
# the defect class this ticket exists for.
assert_deny "export -n -- NAME (-- ends options; the leading -n still carries -- codex-1's bypass)" "$(j "export -n -- HIMMEL_CONSOLE_LEG; bash $MERGE_ON_GREEN 1")"
assert_deny "export -nx (unrecognized flag; the leading -n still carries)" "$(j "export -nx HIMMEL_CONSOLE_LEG; bash $MERGE_ON_GREEN 1")"
assert_deny "unset -f (documented over-deny -- bash would touch nothing)" "$(j "unset -f HIMMEL_CONSOLE_LEG; bash $MERGE_ON_GREEN 1")"
assert_deny "export -fn (documented over-deny -- bash errors, strips nothing)" "$(j "export -fn HIMMEL_CONSOLE_LEG; bash $MERGE_ON_GREEN 1")"
assert_deny "export -nf (documented over-deny, reordered)"        "$(j "export -nf HIMMEL_CONSOLE_LEG; bash $MERGE_ON_GREEN 1")"
assert_deny "export -f -n (documented over-deny, separate words)" "$(j "export -f -n HIMMEL_CONSOLE_LEG; bash $MERGE_ON_GREEN 1")"
# The simplified scanner does not track any leading-vs-trailing boundary
# either -- every non-option word anywhere after `unset` is a candidate,
# so both readings of these already denied (unaffected by the ruling).
assert_deny "unset -- NAME -f (both readings still clear the seam)" "$(j "unset -- HIMMEL_CONSOLE_LEG -f; bash $MERGE_ON_GREEN 1")"
assert_deny "unset NAME -f (both readings still clear the seam)"    "$(j "unset HIMMEL_CONSOLE_LEG -f; bash $MERGE_ON_GREEN 1")"
assert_deny "unset -x NAME (documented over-deny -- bash refuses, touches nothing)" "$(j "unset -x HIMMEL_CONSOLE_LEG; bash $MERGE_ON_GREEN 1")"
assert_deny "export -n -x NAME (documented over-deny -- bash refuses, touches nothing)" "$(j "export -n -x HIMMEL_CONSOLE_LEG; bash $MERGE_ON_GREEN 1")"

# --- HIMMEL-2939 (the fourth clearing shape): six MORE ways an earlier
# segment clears a registered seam with no `unset`/`export -n`/`env -u`/plain
# assignment in sight -- `let`/`declare`/`typeset`/`printf -v`/`read` all
# assign in the CURRENT shell, and the legacy `$[NAME=0]` arithmetic
# construct assigns too. Same fail-closed posture as HIMMEL-2927/2933: no
# option-validity model, every non-option word (after any `-v` for `printf`)
# is a candidate name, folded into UNSET_NAMES for later segments. The
# `$((SEAM=0))` control (already denied via the existing `$(` carve-out,
# unrelated to this change) stays DENY. ---
assert_deny "legacy \$[NAME=0] arithmetic assigns the seam"      "$(j "echo \$[HIMMEL_CONSOLE_LEG=0]; bash $MERGE_ON_GREEN 1")"
assert_deny "let NAME=0 assigns the seam"                        "$(j "let HIMMEL_CONSOLE_LEG=0; bash $MERGE_ON_GREEN 1")"
assert_deny "declare NAME=0 assigns the seam"                    "$(j "declare HIMMEL_CONSOLE_LEG=0; bash $MERGE_ON_GREEN 1")"
assert_deny "typeset NAME= assigns the seam to empty"            "$(j "typeset HIMMEL_CONSOLE_LEG=; bash $MERGE_ON_GREEN 1")"
assert_deny "printf -v NAME writes the seam"                     "$(j "printf -v HIMMEL_CONSOLE_LEG 0; bash $MERGE_ON_GREEN 1")"
assert_deny "read NAME <<< 0 writes the seam"                    "$(j "read HIMMEL_CONSOLE_LEG <<< 0; bash $MERGE_ON_GREEN 1")"
assert_deny "read -r a NAME b (name anywhere in read's word list)" "$(j "read -r a HIMMEL_CONSOLE_LEG b <<< '1 2 3'; bash $MERGE_ON_GREEN 1")"
assert_deny "declare -p NAME (documented over-deny -- no -p inspection)" "$(j "declare -p HIMMEL_CONSOLE_LEG; bash $MERGE_ON_GREEN 1")"
assert_deny "\$((NAME=0)) control (pre-existing, via the \$( carve-out)" "$(j "\$((HIMMEL_CONSOLE_LEG=0)); bash $MERGE_ON_GREEN 1")"
# Over-match control: unaffected.
assert_allow "let x=1 (no seam) stays allowed"                   "$(j "let x=1; bash $MERGE_ON_GREEN 1")"

# --- HIMMEL-2939 CR round (codex-1): compound arithmetic-assignment
# operators glued onto the name (`let NAME*=0`) escaped both the `%%=*`
# suffix-strip (left `NAME*` as the folded name, which never matches the
# registered `NAME`) and the `$[...]` bracket regex's bare `NAME=` match
# (no `=` immediately follows the identifier). Fixed by matching the
# LEADING identifier instead of stripping from the first `=`. ---
assert_deny "let NAME*=0 (compound arithmetic op) assigns the seam"        "$(j "let HIMMEL_CONSOLE_LEG*=0; bash $MERGE_ON_GREEN 1")"
assert_deny "legacy \$[NAME*=0] (compound arithmetic op) assigns the seam" "$(j "echo \$[HIMMEL_CONSOLE_LEG*=0]; bash $MERGE_ON_GREEN 1")"

# --- HIMMEL-2939 CR round 2 (codex-1): a single `let` operand can comma-join
# multiple arithmetic assignments -- everything after the first comma was
# invisible to the leading-identifier-only match (codex-1). (codex-2):
# `++`/`--` prefix or postfix WRITES the operand without ever producing a
# bare `=`, so the `=`-anchored `let`/`declare` leading match and the
# `$[...]` bracket-fold both missed it. Fixed by adding comma-joined and
# prefix/postfix inc/dec fold passes at both sites. ---
assert_deny "let comma-joined assignment (NAME after comma) assigns the seam" "$(j "let 'x=0,HIMMEL_CONSOLE_LEG=0'; bash $MERGE_ON_GREEN 1")"
assert_deny "let prefix ++NAME assigns the seam"                    "$(j "let '++HIMMEL_CONSOLE_LEG'; bash $MERGE_ON_GREEN 1")"
assert_deny "let postfix NAME-- assigns the seam"                   "$(j "let 'HIMMEL_CONSOLE_LEG--'; bash $MERGE_ON_GREEN 1")"
assert_deny "legacy \$[--NAME] (prefix decrement) assigns the seam" "$(j "echo \$[--HIMMEL_CONSOLE_LEG]; bash $MERGE_ON_GREEN 1")"
assert_deny "legacy \$[NAME++] (postfix increment) assigns the seam" "$(j "echo \$[HIMMEL_CONSOLE_LEG++]; bash $MERGE_ON_GREEN 1")"

# --- HIMMEL-2939 CR round 4 (collapse, console ruling): three straight
# rounds each found the next `let` arithmetic-operator shape (bare `=`,
# compound `*=`, comma-join, prefix `++`, now postfix AFTER a comma) a
# validity model missed -- codex-1 this round: `let 'x=0,NAME--'` still
# escaped because the comma-joined scan only matched `=` or prefix
# `++`/`--`, not postfix after a comma. Ruling: stop parsing `let`
# grammar entirely -- any registered seam name occurring anywhere in a
# remaining word, WORD-BOUNDED (the char before/after is not
# [A-Za-z0-9_]), folds forward regardless of assignment shape. Documented
# over-deny: reading the seam without clearing it denies too -- costs
# nothing, and a false ALLOW is the defect class this ticket exists for.
# The word-boundary control (a longer name sharing the registered name's
# PREFIX) stays ALLOW. ---
assert_deny "let comma-joined THEN postfix (NAME-- after comma) assigns the seam" "$(j "let 'x=0,HIMMEL_CONSOLE_LEG--'; bash $MERGE_ON_GREEN 1")"
assert_deny "let x=NAME+1 (reads, does not clear -- documented over-deny)" "$(j "let 'x=HIMMEL_CONSOLE_LEG+1'; bash $MERGE_ON_GREEN 1")"
assert_allow "let NAME_LONGER=0 (word boundary -- shares the registered name's PREFIX, not equal)" "$(j "let HIMMEL_CONSOLE_LEGACY=0; bash $MERGE_ON_GREEN 1")"

# --- HIMMEL-2939 (collapse, round 4 continued -- console ruling named
# `printf -v` and `read` for the SAME treatment as `let`/`declare`/`$[...]`):
# both builtins also accept an ARRAY-ELEMENT operand (`NAME[0]`), which bash
# assigns into NAME exactly like a bare `NAME` operand -- but the pre-collapse
# code captured the whole word (`${W[$k]%%=*}`) as the candidate, so
# `HIMMEL_CONSOLE_LEG[0]` was folded as the literal 8-byte-longer name
# "HIMMEL_CONSOLE_LEG[0]", which never exact-matches the registered
# "HIMMEL_CONSOLE_LEG" in check_invocation. Same fix: word-bounded substring
# match against ALL_SEAM_VARS instead of whole-word capture. ---
assert_deny "read NAME[0] (array-element assignment) assigns the seam"        "$(j "read HIMMEL_CONSOLE_LEG[0] <<< 0; bash $MERGE_ON_GREEN 1")"
assert_deny "printf -v NAME[0] (array-element assignment) writes the seam"    "$(j "printf -v HIMMEL_CONSOLE_LEG[0] 0; bash $MERGE_ON_GREEN 1")"
assert_allow "read NAME_LONGER (word boundary -- shares the PREFIX, not equal)" "$(j "read HIMMEL_CONSOLE_LEGACY <<< 0; bash $MERGE_ON_GREEN 1")"

# --- HIMMEL-2939 CR round 5 (console ruling): the round-4 collapse still
# skipped every dash-prefixed word (`-*) ;;`) in the let/declare/typeset/
# readonly and read arms before scanning, reasoning it was an option/flag.
# That skip is itself an unwanted grammar model: bash's `let` treats a
# LEADING `--` on an operand, after the `--` option-terminator word, as the
# prefix-decrement operator, not a flag -- `let -- '--HIMMEL_CONSOLE_LEG'`
# genuinely decrements the seam (verified live). Fix: delete the skip: every
# remaining word, dash-prefixed or not, goes through the word-bounded scan. ---
assert_deny "let -- '--NAME' (arithmetic prefix-decrement operand; dash-skip hid it)" "$(j "let -- '--HIMMEL_CONSOLE_LEG'; bash $MERGE_ON_GREEN 1")"
assert_allow "let -- x=1 (control -- no seam name present)" "$(j "let -- x=1; bash $MERGE_ON_GREEN 1")"

# --- HIMMEL-2943 (residual deferred off HIMMEL-2939 round 5, codex-1):
# `mapfile`/`readarray` were left unmodelled on the theory that they "target
# arrays, never a scalar seam" -- but `mapfile -t NAME <<< 0` converts a
# scalar seam into an array bash does not export to children, clearing it
# from a later chokepoint's view exactly like `unset` does. Same word-bounded
# scan as the `let`/`read` arms, no option-shape modelling (round 5's STOP
# ruling applies here too): every remaining word after `mapfile`/`readarray`
# goes through the scan unconditionally, so a value-taking option's operand
# (`-C callback`, `-c quantum`) is scanned too, documented over-deny. ---
assert_deny "mapfile -t NAME <<< 0 converts the seam to an array"        "$(j "mapfile -t HIMMEL_CONSOLE_LEG <<< 0; bash $MERGE_ON_GREEN 1")"
assert_deny "readarray NAME <<< 0 (readarray alias) converts the seam"   "$(j "readarray HIMMEL_CONSOLE_LEG <<< 0; bash $MERGE_ON_GREEN 1")"
assert_deny "mapfile -t -n 1 NAME < f (name after value-taking options)" "$(j "mapfile -t -n 1 HIMMEL_CONSOLE_LEG < f; bash $MERGE_ON_GREEN 1")"
assert_deny "mapfile -C cb -c 1 NAME (name after -C/-c and their values)" "$(j "mapfile -C cb -c 1 HIMMEL_CONSOLE_LEG; bash $MERGE_ON_GREEN 1")"
assert_deny "readarray -O 0 -t NAME (name after -O and its value)"       "$(j "readarray -O 0 -t HIMMEL_CONSOLE_LEG; bash $MERGE_ON_GREEN 1")"
assert_allow "mapfile -t lines <<< x (non-seam name) stays allowed"      "$(j "mapfile -t lines <<< x; bash $MERGE_ON_GREEN 1")"
assert_allow "mapfile -t (no name -> default MAPFILE, not a seam)"      "$(j "mapfile -t; bash $MERGE_ON_GREEN 1")"
assert_allow "echo mapfile NAME (word, not the command) stays allowed"  "$(j "echo mapfile HIMMEL_CONSOLE_LEG; bash $MERGE_ON_GREEN 1")"

# --- CR ROUND 1 (HIMMEL-1746): the env-prefix must bind to the chokepoint's
# OWN command segment. The pre-fix predicate tested "path found anywhere"
# AND "assignment found anywhere" over the whole compound, which false-denied
# (assignment in a different segment -- finding 1) and evaded (separator
# defeating the path's end-of-string boundary -- finding 2) as one weakness.
assert_deny "1813 backstop over-deny (console X ruling 07:05): finding 1: seam var on OTHER segment (;)"   "$(j "${MOG_VAR}=x echo ok; bash $MERGE_ON_GREEN")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): finding 1: seam var on OTHER segment (&&)"  "$(j "${MOG_VAR}=x echo ok && bash $MERGE_ON_GREEN")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): finding 1: seam var on OTHER segment (||)"  "$(j "${MOG_VAR}=x echo ok || bash $MERGE_ON_GREEN")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): finding 1: seam var on OTHER segment (|)"   "$(j "${MOG_VAR}=x echo ok | bash $MERGE_ON_GREEN")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): finding 1: seam var on OTHER segment (nl)"  "$(j "${MOG_VAR}=x echo ok
bash $MERGE_ON_GREEN")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): chokepoint, THEN unrelated assignment segment" "$(j "bash $MERGE_ON_GREEN; ${MOG_VAR}=x echo ok")"
assert_deny "finding 2: separator AFTER env-prefixed chokepoint (;)"  "$(j "${MOG_VAR}=x bash $MERGE_ON_GREEN; echo ok")"
assert_deny "finding 2: separator AFTER env-prefixed chokepoint (&&)" "$(j "${MOG_VAR}=x bash $MERGE_ON_GREEN && echo ok")"
assert_deny "finding 2: separator AFTER env-prefixed chokepoint (||)" "$(j "${MOG_VAR}=x bash $MERGE_ON_GREEN || echo ok")"
assert_deny "finding 2: separator AFTER env-prefixed chokepoint (|)"  "$(j "${MOG_VAR}=x bash $MERGE_ON_GREEN | cat")"
assert_deny "finding 2: separator AFTER env-prefixed chokepoint (nl)" "$(j "${MOG_VAR}=x bash $MERGE_ON_GREEN
echo ok")"
assert_deny "env-prefixed chokepoint alone still denied"  "$(j "${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny "quoted separator inside a value never splits" "$(j "${MOG_VAR}='a;b' bash $MERGE_ON_GREEN")"

# --- CR ROUND 2 (HIMMEL-1746): same class, third instance forbidden. The
# INVARIANT (stated at the hook's scanner): a chokepoint is recognized only
# when its path is the invoked-program TOKEN of a segment -- decided by
# tokenizing into shell words, never by substring search -- and a seam
# assignment counts only as a leading assignment word of that SAME segment.
# Finding 3 (evasion): an attached redirection is not a word boundary any
# enumerated character set knew about; the tokenizer ends the word there.
# Finding 4 (false deny): a path in ARGUMENT position is not the
# invoked-program token, wherever in the segment it appears.
assert_deny  "finding 3: attached stdout redirection"      "$(j "${MOG_VAR}=1 bash $MERGE_ON_GREEN>/tmp/h.log")"
assert_deny  "finding 3: attached append redirection"      "$(j "${MOG_VAR}=1 bash $MERGE_ON_GREEN>>/tmp/h.log")"
assert_deny  "finding 3: attached stderr redirection"      "$(j "${MOG_VAR}=1 bash $MERGE_ON_GREEN 2>/dev/null")"
assert_deny  "finding 3 kin: redirect interleaved before interpreter" "$(j "${MOG_VAR}=1 >/tmp/h.log bash $MERGE_ON_GREEN")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): finding 4: path in ARGUMENT position (echo)" "$(j "${MOG_VAR}=1 echo $MERGE_ON_GREEN")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): finding 4: path in ARGUMENT position (cat)"  "$(j "${MOG_VAR}=1 cat $MERGE_ON_GREEN")"

# --- Invariant probes past the four findings: word identity and command
# position come from the tokenizer, so quote/escape splits, continuations,
# groupings ('(' carve-out CLOSED), and re-parsing wrappers all resolve. ---
assert_deny  "backslash-newline continuation"      "$(j "${MOG_VAR}=1 \\
bash $MERGE_ON_GREEN")"
assert_deny  "split-quoted path is one word"       "$(j "${MOG_VAR}=1 bash ${MERGE_ON_GREEN%/*}/'${MERGE_ON_GREEN##*/}'")"
assert_deny  "backslash-escaped interpreter word"  "$(j "${MOG_VAR}=1 \\bash $MERGE_ON_GREEN")"
assert_deny  "subshell-wrapped invocation"         "$(j "(${MOG_VAR}=1 bash $MERGE_ON_GREEN)")"
assert_deny  "substitution inside double quotes"   "$(j "echo \"\$(${MOG_VAR}=1 bash $MERGE_ON_GREEN)\"")"
assert_deny  "eval with a quoted command string"   "$(j "eval \"${MOG_VAR}=1 bash $MERGE_ON_GREEN\"")"
assert_deny  "exec wrapper"                        "$(j "${MOG_VAR}=1 exec bash $MERGE_ON_GREEN")"
assert_deny  "bash -c string carrying the invocation" "$(j "${MOG_VAR}=1 bash -c 'bash $MERGE_ON_GREEN'")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): bash -c: path in \$0 position is not invoked" "$(j "${MOG_VAR}=1 bash -c 'echo hi' $MERGE_ON_GREEN")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): double-quoted literal text is not an invocation" "$(j "echo \"${MOG_VAR}=1 bash $MERGE_ON_GREEN\"")"

# --- HIMMEL-1803: the env -S split-string seam. `env -S 'VAR=x cmd'`
# re-tokenizes the operand into the whole command line (GNU env's documented
# -S / --split-string), so the operand is an eval/-c-shaped string the guard
# re-parses under its depth cap, with names inherited from the outer env
# words (env A=1 -S 'B=2 cmd' exports both). Words AFTER the operand are
# arguments APPENDED to the string's command, never a fresh command
# position; and the pinned interpreter shapes survive inside the string. ---
assert_deny  "env -S split string carries the seam"    "$(j "env -S '${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -S attached operand"                 "$(j "env -S'${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env --split-string long form"            "$(j "env --split-string '${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -S behind a -u flag"                 "$(j "env -u FOO -S '${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -S: seam on the OUTER env words"     "$(j "env ${MOG_VAR}=x -S 'bash $MERGE_ON_GREEN'")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): env -S string WITHOUT a seam var"        "$(j "env -S 'bash $MERGE_ON_GREEN'")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): env -S: words after the string are appended args" "$(j "env -S 'echo hi' bash $MERGE_ON_GREEN")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): env -S: path at \$0 inside the string"   "$(j "env -S '${MOG_VAR}=x bash -c \"echo hi\" $MERGE_ON_GREEN'")"

# --- HIMMEL-1803 round 2: the CLUSTERED short-option spelling. Flags
# clustered ahead of S ("-vS", "-iS", "-ivS") are ONE option word, and env
# still re-tokenizes the operand -- the NEXT word when S ends the cluster,
# the REST of the word when it does not ("-vSstr"). The same getopt rule
# makes an argument-taking letter mid-cluster ("-vu FOO") consume the next
# word as ITS operand. These ratchets were proven RED against the round-1
# hook (a clustered option word was skipped whole, so the split string
# rode into command position as one opaque word). ---
assert_deny  "env -vS cluster carries the seam"        "$(j "env -vS '${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -iS cluster carries the seam"        "$(j "env -iS '${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -ivS multi-flag cluster"             "$(j "env -ivS '${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -vS attached operand"                "$(j "env -vS'${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -ivS attached operand"               "$(j "env -ivS'${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -vS: seam on the OUTER env words"    "$(j "env ${MOG_VAR}=x -vS 'bash $MERGE_ON_GREEN'")"
assert_deny  "env -vu PATH cluster (operand consumed)" "$(j "env -vu PATH ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): env -vS string WITHOUT a seam var"       "$(j "env -vS 'bash $MERGE_ON_GREEN'")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): env -vS: words after the string are appended args" "$(j "env -vS 'echo hi' bash $MERGE_ON_GREEN")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): env -iS: path at \$0 inside the string"  "$(j "env -iS '${MOG_VAR}=x bash -c \"echo hi\" $MERGE_ON_GREEN'")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): env -vSu: mid-cluster S consumes u; rest are appended args" "$(j "env -vSu '${MOG_VAR}=x bash $MERGE_ON_GREEN'")"

# --- HIMMEL-1803 round 3: the OPTION-TABLE class closure. Three CR
# rounds each found a spelling the hand-written option list missed; the
# hook's env arm now DERIVES operand consumption from a grammar table
# (ENV_LONG_OPTS). Proven RED by hand against the round-2 hook (the
# option word was skipped alone, so its separate operand parked in
# command position and the scan never reached the chokepoint):
# --unset / --chdir / --argv0 with a SEPARATE operand, the --uns and
# --spl ABBREVIATIONS, --spl=..., -P, --unset-then- "--", and the
# unrecognised/ambiguous-option defaults. The long-with-= pins and the
# bare "--"/"-" pins were already green under round-2 and are pinned
# against regression. Two verdicts FLIP deny->allow, deliberately,
# because the model now matches env's real grammar: after "--" or "-",
# an option-looking WORD is the first operand (the command of an
# invocation env cannot run -- it fails to exec), never an option --
# "env -- --unset ..." and "env - --unset ..." allow where round-2
# denied. The nested-env cases pin that a fresh env word restarts
# option parsing (the outer "--" must not leak into the inner env). ---
assert_deny  "env --unset separate operand carries the seam"  "$(j "env --unset FOO ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env --chdir separate operand carries the seam"  "$(j "env --chdir /tmp ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env --argv0 separate operand carries the seam"  "$(j "env --argv0 zzz ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env --unset=FOO attached operand"               "$(j "env --unset=FOO ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env --chdir=/tmp attached operand"              "$(j "env --chdir=/tmp ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env --argv0=zzz attached operand"               "$(j "env --argv0=zzz ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env --unset ABBREVIATED (--uns)"                "$(j "env --uns FOO ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env --split-string ABBREVIATED (--spl)"         "$(j "env --spl '${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env --spl=... abbreviated long-with-="          "$(j "env --spl='${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -P alternate path (BSD arg operand)"        "$(j "env -P /bin ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env -- ends options; assignments still bind"     "$(j "env -- ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env --unset FOO then -- then the seam"           "$(j "env --unset FOO -- ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env - (lone dash) ends options; seam still binds" "$(j "env - ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "unrecognised option: seam collected BEFORE it"   "$(j "env ${MOG_VAR}=x --not-an-env-option FOO bash $MERGE_ON_GREEN")"
assert_deny  "unrecognised option: operand does not park command position" "$(j "env --not-an-env-option FOO ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "ambiguous abbreviation (--ig) uses the default too" "$(j "env --ig FOO ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): after --, an option WORD is the command, not an option"      "$(j "env -- --unset ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): after -, an option WORD is the command, not an option"       "$(j "env - --unset ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): optarg long (--ignore-signal) takes no separate word"        "$(j "env --ignore-signal INT ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "nested env carries the seam through its own -S"              "$(j "env ${MOG_VAR}=x env -S 'bash $MERGE_ON_GREEN'")"
assert_deny  "env after --: inner env option parsing restarts"             "$(j "env -- ${MOG_VAR}=x env -S 'bash $MERGE_ON_GREEN'")"

# --- HIMMEL-1803 round 4: the conservative default for SHORT clusters and
# the -S OPTION-state re-entry. Round 3 documented "an option the scanner
# does not recognise must fall to a conservative default that assumes it
# MAY consume an operand" but implemented it for LONG options only:
# env_short_cluster returned "unknown" (a bare word-skip) and had no -a
# (GNU's short spelling of --argv0), so `env -a zzz SEAM=x bash
# <chokepoint>` parked zzz in command position and the scan returned
# before the chokepoint. And a -S operand re-entered a FRESH COMMAND SCAN
# instead of env's own option parsing, so a leading -i/-u/-C inside the
# string was modelled as the invoked program. The seven shapes driven RED
# by hand against the round-3 hook (env -a zzz / -a ignored / -a ignored
# -S / clustered -va zzz / -S '-i ...' / -S '-u X ...' / -S '-C /tmp
# ...') are closed by the same two fixes; the -azzz and -QFOO attached
# spellings already denied via the interpreter arm and are pinned. The
# scan_split_argv model (coreutils parse_split_string): the -S string's
# tokenized argv, with the CLI words after the operand APPENDED, goes
# back through env's OPTION state -- GNU's documented "\_" argument
# separator included; ';' inside the string is a word character, not a
# shell separator. ---
assert_deny  "env -a separate operand carries the seam"    "$(j "env -a zzz ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env -a attached operand"                     "$(j "env -azzz ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env -va cluster: a consumes the next word"   "$(j "env -va zzz ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env -a operand, then a -S split string"      "$(j "env -a ignored -S '${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "unknown short letter uses the conservative default" "$(j "env -Q FOO ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "unknown short letter, attached spelling"     "$(j "env -QFOO ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env -S string: leading -i is an env OPTION"  "$(j "env -S '-i ${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -S string: leading -u consumes its word" "$(j "env -S '-u X ${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -S string: leading -C consumes its word" "$(j "env -S '-C /tmp ${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -S string: leading -- ends its options"  "$(j "env -S '-- ${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -S option-only string; command rides the outer words" "$(j "env -S '-i' ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env -S: \_ is the argument separator"        "$(j "env -S '${MOG_VAR}=x bash\\_$MERGE_ON_GREEN'")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): env -S option state, no seam var"            "$(j "env -S '-u X bash $MERGE_ON_GREEN'")"
# (The former "; inside the string is a word character" ALLOW moved to the
# HIMMEL-1813 block below, now a deny: see the note there.)

# --- HIMMEL-1803 round 7: an unquoted # at argument start discards the
# rest of an env -S string; an escaped \# remains literal word content. ---
assert_deny  "env -S: leading # comment discards the string" "$(j "env -S '# ignored' ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env -S: mid-string # comment discards the rest" "$(j "env -S '-u X # ignored' ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env -S: escaped \# stays literal before a later comment" "$(j "env -S '-u \\# # ignored' ${MOG_VAR}=x bash $MERGE_ON_GREEN")"

# --- HIMMEL-1813: deny-on-unresolvable. Round 7 (GNU's \c "ignore the rest")
# tripped the judgment pass's convergence tripwire, so the -S grammar is no
# longer simulated spelling by spelling: a split string carrying anything
# outside a small resolvable set (a backslash escape other than \_ \\ \" \'
# unquoted or \\ \" double-quoted, any backslash in single quotes, a '#', a
# '$') denies when the split string or its appended words MENTION a
# registered chokepoint. Outside that intersection the guard stays
# fail-open; the pinned ALLOWs below are resolvable and keep their verdict. ---
# The raw backstop runs before the parser (console X ruling at 64bc44b1), so
# where both deny, its message fires instead: either message counts.
assert_deny_unres() {  # assert_deny_unres <label> <json>
    local label="$1"; shift
    run "$@"
    local decision
    decision=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)
    CASES=$((CASES + 1))
    if [ "$RC" = "2" ] && [ "$decision" = "deny" ] \
       && grep -qE "cannot be fully resolved|together with its seam variable or an env -S" <<<"$ERR"; then
        echo "PASS $label (denied as unresolvable)"
    else
        echo "FAIL $label -- expected rc=2 + permissionDecision=deny + unresolvable message, got rc=$RC decision='$decision'"
        FAILED=$((FAILED + 1))
    fi
}
assert_deny_unres "1813: \\c with trailing text"             "$(j "env -S '${MOG_VAR}=1 bash $MERGE_ON_GREEN\\c ignored'")"
assert_deny_unres "1813: \\c at end of string"               "$(j "env -S '${MOG_VAR}=1 bash $MERGE_ON_GREEN\\c'")"
assert_deny_unres "1813: \\c, no seam var"                   "$(j "env -S 'bash $MERGE_ON_GREEN\\c'")"
assert_deny_unres "1813: \\c, chokepoint in appended words"  "$(j "env -S '${MOG_VAR}=1 bash\\c' $MERGE_ON_GREEN")"
assert_deny_unres "1813: \\c via clustered -vS"              "$(j "env -vS '${MOG_VAR}=1 bash $MERGE_ON_GREEN\\c'")"
assert_deny_unres "1813: \\c via --split-string="            "$(j "env --split-string='${MOG_VAR}=1 bash $MERGE_ON_GREEN\\c'")"
assert_deny_unres "1813: \\c on the stop-worker chokepoint"  "$(j "env -S '${SW_VAR}=1 bash $STOP_WORKER\\c'")"
assert_deny_unres "1813: other escape (\\t)"                 "$(j "env -S 'bash $MERGE_ON_GREEN\\t'")"
assert_deny_unres "1813: backslash inside single quotes"     "$(j "env -S \"bash '$MERGE_ON_GREEN\\\\c'\"")"
assert_deny_unres "1813: \\_ inside double quotes"           "$(j "env -S '\"${MOG_VAR}=1\\_\" bash $MERGE_ON_GREEN'")"
# HIMMEL-4157: a mid-word # in a path is a zsh extendedglob operator (go.sh#
# = go.s + zero or more h), so the text layer now denies it first.
assert_deny "1813: mid-word #"                               "$(j "env -S 'bash $MERGE_ON_GREEN#'")"
assert_deny_unres "1813: \${VARNAME} expansion"              "$(j "env -S '\${HM_1813_X} bash $MERGE_ON_GREEN'")"
assert_deny_unres "1813: newline inside the -S string"        "$(j "env -S '${MOG_VAR}=1 bash"$'\n'"$MERGE_ON_GREEN\\c'")"
assert_deny_unres "1813: ; inside the -S string"              "$(j "env -S 'true;bash $MERGE_ON_GREEN\\c'")"
assert_deny_unres "1813: | inside the -S string"              "$(j "env -S 'true|bash $MERGE_ON_GREEN\\c'")"
assert_deny_unres "1813: \\c inside outer double quotes"      "$(j "env -S \"bash $STOP_WORKER\\c\"")"
assert_deny "1813: \\_ inside outer double quotes reaches env" "$(j "env -S \"${SW_VAR}=0\\_bash\\_$STOP_WORKER\"")"
assert_deny_unres "1813: ; alone inside the -S string"        "$(j "env -S '${MOG_VAR}=1 true;bash $MERGE_ON_GREEN'")"
# GNU keeps a literal ';' as a word character, but cmd_flat folds a newline
# (which GNU -S DOES split on) into ';' too, so a ';' in the string is
# ambiguous: formerly an ALLOW row, it denies once a chokepoint is named.
assert_deny_unres "1813: ; inside the string is unresolvable" "$(j "env -S 'echo ok; ${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny_unres "1813: vertical tab inside the -S string"   "$(j "env -S '${MOG_VAR}=1 bash"$'\v'"$MERGE_ON_GREEN'")"
assert_deny_unres "1813: form feed inside the -S string"      "$(j "env -S '${MOG_VAR}=1 bash"$'\f'"$MERGE_ON_GREEN'")"
assert_deny_unres "1813: CR inside the -S string"             "$(j "env -S '${MOG_VAR}=1 bash"$'\r'"$MERGE_ON_GREEN'")"
assert_deny_unres "1813: -S nested past the depth cap"        "$(j "env -S 'env -S env -S env -S env -S env -S env -S env -S env ${MOG_VAR}=1 bash $MERGE_ON_GREEN'")"
assert_deny_unres "1813: backslash-escaped \\-S option"        "$(j "env \\-S 'bash $MERGE_ON_GREEN\\c'")"
assert_deny_unres "1813: backslash inside -\\S option"         "$(j "env -\\S 'bash $MERGE_ON_GREEN\\c'")"
assert_deny_unres "1813: backslash inside --split\\-string="   "$(j "env --split\\-string='bash $MERGE_ON_GREEN\\c'")"
assert_deny_unres "1813: fd redirect 2>&1 before -S"           "$(j "env 2>&1 -S '${MOG_VAR}=1 bash $MERGE_ON_GREEN\\c'")"
assert_deny_unres "1813: fd redirect 2>/dev/null before -S"    "$(j "env 2>/dev/null -S '${MOG_VAR}=1 bash $MERGE_ON_GREEN\\c'")"
assert_deny_unres "1813: fd redirect 0<file before -S"         "$(j "env 0</dev/null -S '${MOG_VAR}=1 bash $MERGE_ON_GREEN\\c'")"
assert_deny_unres "1813: &> redirect before -S"                "$(j "env &>/dev/null -S '${MOG_VAR}=1 bash $MERGE_ON_GREEN\\c'")"
assert_deny_unres "1813: fd redirect before --split-string="   "$(j "env 2>&1 --split-string='${MOG_VAR}=1 bash $MERGE_ON_GREEN\\c'")"
assert_deny "1813: unquoted TAB separates the -S words"        "$(j "env -S ${MOG_VAR}=1"$'\t'"bash"$'\t'"$MERGE_ON_GREEN")"
assert_deny "1813: unquoted TAB, direct chokepoint path"       "$(j "env -S ${MOG_VAR}=1"$'\t'"$MERGE_ON_GREEN")"
assert_deny "1813: \${VAR} splits the chokepoint name"   "$(j "env -S '${SW_VAR}=1 bash ${STOP_WORKER%stop-worker.sh}stop-\${Z}worker.sh'")"
assert_deny_unres "1813: herestring feeds an env -S \\c to bash" "$(j "bash <<< \"env -S '${MOG_VAR}=1 bash $MERGE_ON_GREEN\\c'\"")"
assert_deny_unres "1813: the LAST of two herestrings is scanned" "$(j "bash <<< 'echo ok' <<< \"env -S '${MOG_VAR}=1 bash $MERGE_ON_GREEN\\c'\"")"
# Judge round 3: a redirect word of ANY shape between env and its command
# makes env's options unresolvable, and a here-string naming a chokepoint
# denies unless a non-executing reader consumes it.
assert_deny "1813: >| redirect before -S"                     "$(j "env >|/dev/null -S '${SW_VAR}=1 bash $STOP_WORKER\\c'")"
assert_deny "1813: {fd}>&1 redirect before -S"                "$(j "env {fd}>&1 -S '${SW_VAR}=1 bash $STOP_WORKER\\c'")"
assert_deny "1813: <> redirect before -S"                     "$(j "env <>/dev/null -S '${SW_VAR}=1 bash $STOP_WORKER\\c'")"
assert_deny "1813: source /dev/stdin reads a herestring"      "$(j "source /dev/stdin <<< \"env -S '${SW_VAR}=1 bash $STOP_WORKER\\c'\"")"
assert_deny "1813: . /dev/stdin reads a herestring"           "$(j ". /dev/stdin <<< \"env -S '${SW_VAR}=1 bash $STOP_WORKER\\c'\"")"
assert_deny "1813: an unlisted shell reads a herestring"      "$(j "mksh <<< \"env -S '${SW_VAR}=1 bash $STOP_WORKER\\c'\"")"
assert_deny "1813: source /dev/stdin reads a heredoc"         "$(j "source /dev/stdin <<EOF"$'\n'"env -S '${SW_VAR}=1 bash $STOP_WORKER\\c'"$'\n'"EOF")"
assert_deny "1813: a reader's herestring piped to a shell"     "$(j "cat <<< \"env -S '${SW_VAR}=1 bash $STOP_WORKER\\c'\" | bash")"
assert_deny "1813: a reader's herestring in a substitution"   "$(j "bash -c \"\$(cat <<< \"env -S '${SW_VAR}=1 bash $STOP_WORKER\\c'\")\"")"
assert_deny "1813: a reader's herestring via <(...)"          "$(j "source <(cat <<< \"env -S '${SW_VAR}=1 bash $STOP_WORKER\\c'\")")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): 1813: cat of a herestring is data"              "$(j "cat <<< \"env -S '${SW_VAR}=1 bash $STOP_WORKER\\c'\"")"
assert_allow "1813: a redirect before a plain env command"    "$(j "env >/dev/null FOO=1 ls")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): 1813: herestring fed to a non-shell is data"     "$(j "grep x <<< \"env -S '${MOG_VAR}=1 bash $MERGE_ON_GREEN\\c'\"")"
assert_allow "1813: 2>&1 after a plain command stays allowed"  "$(j "bash $MERGE_ON_GREEN 2>&1")"
assert_deny "1813: an escaped > before & still separates"     "$(j "echo \\>& ${MOG_VAR}=1 bash $MERGE_ON_GREEN")"
assert_allow "1813: unresolvable -S not mentioning a chokepoint" "$(j "env -S '${MOG_VAR}=1 bash scripts/not-registered.sh\\c'")"
assert_allow "1813: \\c outside env -S is shell text"        "$(j "printf '%s\\c' $MERGE_ON_GREEN")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): 1813: resolvable -S keeps the simulation verdict" "$(j "env -S 'bash\\_$MERGE_ON_GREEN'")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): 1813 pinned: bash -c 'str' <path> (path at \$0)" "$(j "${MOG_VAR}=1 bash -c 'echo hi' $MERGE_ON_GREEN")"
assert_allow "1813 pinned: an UNREGISTERED variable"         "$(j "HM_1813_UNREGISTERED=1 bash $MERGE_ON_GREEN")"
assert_allow "1813 pinned: a bare invocation"                "$(j "bash $MERGE_ON_GREEN")"

# --- HIMMEL-1803 round 6: ZERO-LENGTH WORDS keep their argv slot. The
# invariant the whole r1-r6 family violated piecemeal: the scan is a
# positional simulation of the argv each interpreter really receives, so
# every hand-off must preserve word COUNT, ORDER, and CONTENT --
# zero-length words included -- and every consumption decision must come
# from the consuming interpreter's real grammar. Pre-fix, the bare
# newline-delimited word streams could not represent an empty word, so
# '' was silently dropped and every later word's role shifted -- which
# BOTH mis-allowed (env -a '' SEAM=x bash <chokepoint>: the dropped ''
# let -a eat the seam assignment as its operand; GNU env really consumes
# '' and runs the chokepoint with the seam) AND mis-denied (SEAM=x ''
# bash <chokepoint>: the empty word IS the command, exec fails, nothing
# runs). All eight non-redirect shapes below were driven RED by hand
# against the round-5 hook. The kin pins: --split-string= and -S ''
# (verified: GNU env runs the appended CLI words after an EMPTY split
# string) exercise the empty-OPERAND half -- $(...) strips an empty
# second protocol line, which pre-fix parked the verdict word itself in
# command position. ---
assert_deny  "r6: -S string, -a consumes a quoted-empty operand"  "$(j "env -S \"-a '' ${MOG_VAR}=x bash $MERGE_ON_GREEN\"")"
assert_deny  "r6: -S string, -u consumes a quoted-empty operand"  "$(j "env -S \"-u '' ${MOG_VAR}=x bash $MERGE_ON_GREEN\"")"
assert_deny  "r6: plain env -a with quoted-empty operand"         "$(j "env -a '' ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "r6: plain env -u with quoted-empty operand"         "$(j "env -u '' ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "r6: --split-string= empty attached operand"         "$(j "env --split-string= ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "r6: -S '' empty separate operand"                   "$(j "env -S '' ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): r6: empty word IS env's command (exec fails)"       "$(j "env '' ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): r6: empty word IS the shell command"                "$(j "${MOG_VAR}=x '' bash $MERGE_ON_GREEN")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): r6: empty word at command position inside -S"       "$(j "env -S \"${MOG_VAR}=x '' bash $MERGE_ON_GREEN\"")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): r6: -S string of only a quoted empty"               "$(j "env -S \"''\" ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): r6: quoted-empty word attached to a redirect is a word, not an IO number" "$(j "${MOG_VAR}=x ''>/tmp/h.log bash $MERGE_ON_GREEN")"

# --- Round-3 grammar probes (INFORMATIONAL -- echo only, never counted,
# never FAIL): the hook's option table is derived from env's real
# grammar; these print what THIS machine's env does with the load-bearing
# spellings, so a reviewer re-running the suite sees the derivation
# basis. "exit 0" = env accepted and ran `true`; "exit non-zero" = env
# rejected/errored before running anything (e.g. the signal name in the
# --ignore-signal probe parking as the command is the no-separate-word
# rule working). On a machine whose env lacks a spelling the probe just
# prints non-zero -- the table entry stays harmless there. ---
probe_env() {  # probe_env <label> <argv...>
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "PROBE $label: exit 0"
    else echo "PROBE $label: exit non-zero"; fi
}
probe_env "--unset NAME (separate operand)"    env --unset HM_1803_NOEXIST HM_1803_PROBE=1 true
probe_env "--unset=NAME (attached operand)"    env --unset=HM_1803_NOEXIST HM_1803_PROBE=1 true
probe_env "--chdir DIR (separate operand)"     env --chdir . HM_1803_PROBE=1 true
probe_env "--argv0 NAME (separate operand)"    env --argv0 HM_1803 HM_1803_PROBE=1 true
probe_env "--argv0=NAME (attached operand)"    env --argv0=HM_1803 HM_1803_PROBE=1 true
probe_env "-P DIR (BSD-only; GNU rejects)"     env -P /bin HM_1803_PROBE=1 true
probe_env "-a NAME (GNU argv0 short; older env rejects)" env -a HM_1803 HM_1803_PROBE=1 true
probe_env "--uns NAME (unique abbreviation)"   env --uns HM_1803_NOEXIST HM_1803_PROBE=1 true
probe_env "--spl=STR (abbreviated split)"      env --spl=HM_1803_PROBE=1 true
probe_env "--split-string STR (separate)"      env --split-string HM_1803_PROBE=1 true
probe_env "--ignore-signal=INT (= spelling)"   env --ignore-signal=INT HM_1803_PROBE=1 true
probe_env "--debug (long twin of -v)"          env --debug HM_1803_PROBE=1 true
probe_env "--ignore-signal INT (separate word NOT consumed -- non-zero expected)" env --ignore-signal INT HM_1803_PROBE=1 true
probe_env "-- then assignments"                env -- HM_1803_PROBE=1 true
probe_env "- (lone dash; GNU treats as -i and runs, BSD treats as --)" env - HM_1803_PROBE=1 true
probe_env "--ig (ambiguous abbreviation)"      env --ig HM_1803_PROBE=1 true
probe_env "--not-an-env-option (unknown)"      env --not-an-env-option HM_1803_PROBE=1 true
# Round-6 zero-length probes: the two "exit 0" lines are the load-bearing
# ones -- an EMPTY split string still runs the appended CLI words, so a
# seam there must deny; the non-zero lines show the shapes where nothing
# can run (deny stays the conservative union-model verdict for -a/-u '').
probe_env "--split-string= (EMPTY split; appended words RUN)" env --split-string= HM_1803_PROBE=1 true
probe_env "-S '' (EMPTY separate split; appended words RUN)"  env -S '' HM_1803_PROBE=1 true
probe_env "-u '' (empty unset name; GNU rejects)"             env -u '' HM_1803_PROBE=1 true
probe_env "-a '' (empty argv0; env without -a rejects)"       env -a '' HM_1803_PROBE=1 true
probe_env "'' as the command word (exec fails)"               env '' HM_1803_PROBE=1 true

# --- HIMMEL-2929: a seam cleared INSIDE a `( ... )` subshell cannot reach
# the parent shell -- scope the clear to its own subshell span instead of
# folding it forward past the closing paren. Fail-closed: the chokepoint
# invoked in the SAME subshell as the clear, an outer clear reaching INTO a
# later subshell, an unbalanced paren, and every unresolved form ($( ),
# `{ }` groups, `bash -c` strings) all stay denied. ---
# HIMMEL-3921: the raw-text layer cannot model subshell scope, so an unset /
# export -n of a seam or HIMMEL_CONSOLE_LEG beside a chokepoint word now denies
# even when the closing paren would drop it (documented over-deny, deny-leaning).
assert_deny "subshell-scoped unset (dropped at the closing paren)"        "$(j "(unset HIMMEL_CONSOLE_LEG); bash $MERGE_ON_GREEN 1")"
assert_deny "subshell-scoped export -n (dropped at the closing paren)"    "$(j "(export -n HIMMEL_CONSOLE_LEG); bash $MERGE_ON_GREEN 1")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): subshell-scoped bare assignment (dropped at the closing paren)" "$(j "(HIMMEL_CONSOLE_LEG=0); bash $MERGE_ON_GREEN 1")"
assert_deny "subshell-scoped unset then && chokepoint"                    "$(j "(unset HIMMEL_CONSOLE_LEG) && bash $MERGE_ON_GREEN 1")"
# codex-1 rounds 1-2 each found a false ALLOW in a kind-tracking model that
# tried to tell `((`/`$(` apart from a real subshell paren-by-paren (round 1:
# an adjacent `((` run misread as two real subshells; round 2: a grouping
# paren nested inside `((...))` misread as a fresh real subshell). Superseded
# by the positive/whitelist rule (below): `((` is opaque because its first
# paren fails the command-position test's adjacent-`(` disqualifier, and
# anything nested inside an opaque paren is forced opaque too (stack-top
# check) -- round 2's bug structurally, not via a blanket collapse.
assert_deny "\`((VAR=0))\` -- adjacent-paren disqualifier keeps it opaque"    "$(j "((HIMMEL_CONSOLE_LEG=0)); bash $MERGE_ON_GREEN 1")"
assert_deny "adjacent \`((\` -- both parens opaque, not two real subshells"    "$(j "((unset HIMMEL_CONSOLE_LEG)); bash $MERGE_ON_GREEN 1")"
assert_deny "a paren nested inside \`((...))\` inherits opaque from the stack" "$(j "(( (HIMMEL_CONSOLE_LEG=0) )); bash $MERGE_ON_GREEN 1")"
# No longer collapsed: this subshell closes cleanly before the unrelated
# $(...), so real bash never sees the clear outside its own subshell --
# the positive rule now recognizes that precisely instead of over-denying
# every command that also happens to contain a $(...) anywhere else.
assert_deny "a closed subshell clear survives an unrelated sibling \$(...)" "$(j "(unset HIMMEL_CONSOLE_LEG); echo \$(true); bash $MERGE_ON_GREEN 1")"
assert_deny "chokepoint invoked INSIDE the same subshell as the clear"     "$(j "(unset HIMMEL_CONSOLE_LEG; bash $MERGE_ON_GREEN 1)")"
assert_deny "outer clear reaches into a later subshell's chokepoint"       "$(j "unset HIMMEL_CONSOLE_LEG; (bash $MERGE_ON_GREEN 1)")"
assert_deny "outer clear reaches into a nested subshell's chokepoint"      "$(j "(unset HIMMEL_CONSOLE_LEG; (bash $MERGE_ON_GREEN 1))")"
assert_deny "outer clear survives an unrelated sibling subshell"           "$(j "unset HIMMEL_CONSOLE_LEG; ( true ); bash $MERGE_ON_GREEN 1")"
assert_deny "unbalanced open paren (no closing paren) stays fold-forward"  "$(j "(unset HIMMEL_CONSOLE_LEG; bash $MERGE_ON_GREEN 1")"
assert_deny "command substitution \$( ) is not a subshell -- stays denied" "$(j "\$(unset HIMMEL_CONSOLE_LEG); bash $MERGE_ON_GREEN 1")"
assert_deny "bash -c string is an unresolved form -- stays denied"        "$(j "bash -c 'unset HIMMEL_CONSOLE_LEG'; bash $MERGE_ON_GREEN 1")"
assert_deny "a { } group is not a subshell -- stays denied"               "$(j "{ unset HIMMEL_CONSOLE_LEG; }; bash $MERGE_ON_GREEN 1")"
# CodeRabbit (PR #643 @ 5ce5bbed): scan_segment's eval/`-c` recursion calls
# scan_text on just the recursed string, which recomputed no_scope from ONLY
# that substring -- a paren-scoped clear+chokepoint pair with no `((`/`$(`/
# backtick INSIDE the -c/eval string got normal depth tracking and a false
# ALLOW, breaking the ticket's own rule that a -c/eval string is never
# modeled. Fix: any scan_text call at depth > 0 (the -c/eval recursion, the
# only path that ever calls scan_text below depth 0) forces no_scope for
# that whole recursed string, unconditionally.
assert_deny "bash -c string recursion: paren-scoped clear+chokepoint inside the string stays denied" "$(j "bash -c '(unset HIMMEL_CONSOLE_LEG); bash $MERGE_ON_GREEN 1'")"
assert_deny "eval string recursion: paren-scoped clear+chokepoint inside the string stays denied"     "$(j "eval '(unset HIMMEL_CONSOLE_LEG); bash $MERGE_ON_GREEN 1'")"

# --- HIMMEL-2929 round N (leg N190, positive/whitelist rewrite): the
# blacklist ("any (( / $( / backtick anywhere disables scoping for the whole
# call") gave way to a POSITIVE command-position rule -- a `(` opens a real
# subshell (scopes) only when it is the first token of a command: at segment
# start, or immediately after `;`, `&&`, `||`, `|`, `&`, `{`, `(`, or newline.
# Every other paren shape is opaque (does not change pdepth) and must fold
# forward / deny exactly as main does, with NO grammar-shape exception list --
# `[[ ( ) ]]` and `case ... in (x))` are opaque for the mundane reason that the
# word before the paren already consumed command position, not because they
# are special-cased. Rows below are the 20-row probe corpus (RESUME doc);
# literal duplicates of assertions already above are omitted.
assert_deny "1813 backstop over-deny (console X ruling 07:05): whitespace-padded genuine subshell (spaces inside the parens)" "$(j "( HIMMEL_CONSOLE_LEG=0 ); bash $MERGE_ON_GREEN 1")"
assert_deny "prior assignment segment, then a genuine subshell"            "$(j "x=1; (unset HIMMEL_CONSOLE_LEG); bash $MERGE_ON_GREEN 1")"
assert_deny "genuine subshell after && following an unrelated command"    "$(j "true && (unset HIMMEL_CONSOLE_LEG) && bash $MERGE_ON_GREEN 1")"
assert_deny "\$( ) as an argument to a preceding command word stays denied" "$(j "echo \$(unset HIMMEL_CONSOLE_LEG); bash $MERGE_ON_GREEN 1")"
assert_deny "bare backtick command substitution stays denied"              "$(j "\`unset HIMMEL_CONSOLE_LEG\`; bash $MERGE_ON_GREEN 1")"
assert_deny "legacy \$[(...)] arithmetic paren is not a subshell"           "$(j "echo \$[(HIMMEL_CONSOLE_LEG=0)]; bash $MERGE_ON_GREEN 1")"
# --- HIMMEL-2929 (leg N45): a `$[ ... ]` legacy-arithmetic span carrying an
# unquoted `;`/`&`/`|`/NEWLINE was split into segments by segment_cmd before
# scan_segment's `$[` guard could see it -- and a `(` on the far side of that
# split read as a real subshell, scoping the seam assignment out of the deny
# set. Reproduced 4x (Q, N193, N8, console): `main` DENIES, the branch head
# ALLOWED. Fix: `$[` opens an OPAQUE span to its matching `]` (bracket-depth
# balanced, like `$((...))`), so it never splits and never opens scope. The
# whole class stays DENY; the genuine narrowing (a `$[...]` assign INSIDE a
# real closed subshell) stays ALLOW -- verified against real bash (the seam
# never survives the subshell). ---
assert_deny "legacy \$[ ] with an embedded NEWLINE before its paren (the N193/console bypass)" "$(j "$(printf 'echo $[1 +\n(HIMMEL_CONSOLE_LEG=0)]; bash %s 1' "$MERGE_ON_GREEN")")"
assert_deny "legacy \$[ ] with a NEWLINE before its closing bracket" "$(j "$(printf 'echo $[HIMMEL_CONSOLE_LEG=0\n]; bash %s 1' "$MERGE_ON_GREEN")")"
assert_deny "legacy \$[ ] with an embedded semicolon before its paren" "$(j "echo \$[1 ;(HIMMEL_CONSOLE_LEG=0)]; bash $MERGE_ON_GREEN 1")"
assert_deny "second \$[ ] after a newline smuggles the seam"          "$(j "$(printf 'echo $[0]$[\nHIMMEL_CONSOLE_LEG=0]; bash %s 1' "$MERGE_ON_GREEN")")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): a \$[ ] assign INSIDE a real closed subshell is genuinely scoped" "$(j "(echo \$[HIMMEL_CONSOLE_LEG=0]); bash $MERGE_ON_GREEN 1")"
assert_deny "let '(...)' quoted arithmetic paren is not a subshell"        "$(j "let '(HIMMEL_CONSOLE_LEG=0)'; bash $MERGE_ON_GREEN 1")"
assert_deny "array-assignment paren (declare -a a=(...)) is not a subshell" "$(j "declare -a a=( HIMMEL_CONSOLE_LEG=0 ); bash $MERGE_ON_GREEN 1")"
assert_deny "[[ ( ) ]] grouping paren is not a subshell"                    "$(j "[[ ( HIMMEL_CONSOLE_LEG=0 ) ]]; bash $MERGE_ON_GREEN 1")"
assert_deny "process substitution <(...) is not a subshell"                "$(j "cat <(unset HIMMEL_CONSOLE_LEG); bash $MERGE_ON_GREEN 1")"
assert_deny "case pattern paren ( in (x)) is not a subshell"                "$(j "case x in (x) unset HIMMEL_CONSOLE_LEG;; esac; bash $MERGE_ON_GREEN 1")"
assert_deny "function-body paren (f() (...)) is not command-position"      "$(j "f() ( unset HIMMEL_CONSOLE_LEG ); f; bash $MERGE_ON_GREEN 1")"

# --- HIMMEL-3185: an arithmetic COMMAND `(( ... ))` / EXPANSION `$(( ... ))`
# whose body ASSIGNS a registered seam is a current-shell clear, exactly like
# `let` -- but ONLY the spaced spellings escaped: `((NAME=0))` reads as an
# assignment WORD once `(`/`)` split it into its own segment, while
# `(( NAME = 0 ))` leaves the words `NAME`, `=`, `0` and no assignment word.
# Every row below carries a REAL-BASH LEAK ORACLE: the payload runs in a
# scratch dir whose merge-on-green path is a STUB that prints the four
# registered merge-on-green seams as the chokepoint would see them (never the
# real chokepoint), launched with all four = 1. `leak` rows must change one
# (else the row is vacuous -- it would pass a guard that denies everything);
# `noleak` rows must leave all four intact (else the ALLOW is a real bypass).
# The guard's own decision is then asserted against that ground truth. ---
ORACLE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/chokepoint-oracle.XXXXXX") || { echo "FAIL: mktemp for the leak oracle" >&2; exit 1; }
ORACLE_EXPECT='L=1 A=1 H=1 M=1'
mkdir -p "$ORACLE_DIR/$(dirname "$MERGE_ON_GREEN")"
# shellcheck disable=SC2016 # the stub's ${...} must expand in the ORACLE shell, not here
printf '%s\n' 'echo "L=${HIMMEL_CONSOLE_LEG-UNSET} A=${ARMAUTOMERGE-UNSET} H=${HANDOVER_DIR-UNSET} M=${MERGE_ON_GREEN_LOG-UNSET}"' >"$ORACLE_DIR/$MERGE_ON_GREEN"
oracle_line() {  # oracle_line <payload> -> the stub's seam line (empty if the stub never ran)
    (cd "$ORACLE_DIR" && env HIMMEL_CONSOLE_LEG=1 ARMAUTOMERGE=1 HANDOVER_DIR=1 MERGE_ON_GREEN_LOG=1 bash -c "$1" 2>/dev/null) | grep '^L=' | tail -n 1
}
diff_row() {  # diff_row <leak|noleak> <label> <payload with @P@ = the chokepoint call>
    local kind="$1" label="$2" payload="$3" line
    payload=${payload//@P@/bash $MERGE_ON_GREEN 1}
    line=$(oracle_line "$payload")
    if [ -z "$line" ]; then
        CASES=$((CASES + 1)); FAILED=$((FAILED + 1))
        echo "FAIL $label -- oracle: the stub chokepoint never ran (row cannot discriminate)"
        return
    fi
    if [ "$kind" = "residual" ]; then
        # A documented gap: real bash DOES clear a seam and the guard ALLOWS it.
        # Pinned so a future fix flips the row deliberately (change it to `leak`).
        if [ "$line" = "$ORACLE_EXPECT" ]; then
            CASES=$((CASES + 1)); FAILED=$((FAILED + 1))
            echo "FAIL $label -- oracle: real bash did NOT clear a seam (vacuous residual row)"
            return
        fi
        assert_allow "$label [oracle: leaks; documented residual, ALLOW pinned]" "$(j "$payload")"
    elif [ "$kind" = "leak" ]; then
        if [ "$line" = "$ORACLE_EXPECT" ]; then
            CASES=$((CASES + 1)); FAILED=$((FAILED + 1))
            echo "FAIL $label -- oracle: real bash did NOT clear a seam (vacuous leak row)"
            return
        fi
        assert_deny "$label [oracle: leaks]" "$(j "$payload")"
    elif [ "$kind" = "overdeny" ]; then
        # HIMMEL-1813: real bash leaves the seam alone, but the raw backstop
        # denies the literal `SEAM=` text anyway (fail-closed over-deny).
        if [ "$line" != "$ORACLE_EXPECT" ]; then
            CASES=$((CASES + 1)); FAILED=$((FAILED + 1))
            echo "FAIL $label -- oracle: real bash DID change a seam ($line) -- use a leak row"
            return
        fi
        assert_deny "$label [oracle: no leak; 1813 backstop over-deny (console X ruling 07:05)]" "$(j "$payload")"
    else
        if [ "$line" != "$ORACLE_EXPECT" ]; then
            CASES=$((CASES + 1)); FAILED=$((FAILED + 1))
            echo "FAIL $label -- oracle: real bash DID change a seam ($line) -- an ALLOW here is a bypass"
            return
        fi
        assert_allow "$label [oracle: no leak]" "$(j "$payload")"
    fi
}
diff_row leak   "spaced (( NAME = 0 )) (the ticket repro)"          '(( HIMMEL_CONSOLE_LEG = 0 )); @P@'
diff_row leak   "spaced (( NAME += n ))"                            '(( HIMMEL_CONSOLE_LEG += 5 )); @P@'
diff_row leak   "spaced (( NAME -= n ))"                            '(( HIMMEL_CONSOLE_LEG -= 1 )); @P@'
diff_row leak   "spaced (( NAME *= n ))"                            '(( HIMMEL_CONSOLE_LEG *= 2 )); @P@'
diff_row leak   "spaced (( NAME <<= n ))"                           '(( HIMMEL_CONSOLE_LEG <<= 1 )); @P@'
diff_row leak   "spaced (( NAME ^= n ))"                            '(( HIMMEL_CONSOLE_LEG ^= 1 )); @P@'
diff_row leak   "postfix (( NAME++ ))"                              '(( HIMMEL_CONSOLE_LEG++ )); @P@'
diff_row leak   "postfix with a space (( NAME ++ ))"                '(( HIMMEL_CONSOLE_LEG ++ )); @P@'
diff_row leak   "prefix (( ++NAME ))"                               '(( ++HIMMEL_CONSOLE_LEG )); @P@'
diff_row leak   "postfix (( NAME-- ))"                              '(( HIMMEL_CONSOLE_LEG-- )); @P@'
diff_row leak   "prefix (( --NAME ))"                               '(( --HIMMEL_CONSOLE_LEG )); @P@'
diff_row leak   "compound (( a = 1, NAME = 0 ))"                    '(( a = 1, HIMMEL_CONSOLE_LEG = 0 )); @P@'
diff_row leak   "seam assigned inside a ternary"                    '(( 1 ? HIMMEL_CONSOLE_LEG = 0 : 0 )); @P@'
diff_row leak   "grouping parens inside the arithmetic body"        '(( ( HIMMEL_CONSOLE_LEG = 0 ) )); @P@'
diff_row leak   "tabs around the operator"                          "(( HIMMEL_CONSOLE_LEG$(printf '\t')=$(printf '\t')0 )); @P@"
diff_row leak   "array-element form (( NAME[0] = 0 ))"              '(( HIMMEL_CONSOLE_LEG[0] = 0 )); @P@'
diff_row leak   "other seam: ARMAUTOMERGE"                          '(( ARMAUTOMERGE = 0 )); @P@'
diff_row leak   "other seam: HANDOVER_DIR"                          '(( HANDOVER_DIR = 0 )); @P@'
diff_row leak   "other seam: MERGE_ON_GREEN_LOG"                    '(( MERGE_ON_GREEN_LOG = 0 )); @P@'
diff_row leak   "(( )) then && chokepoint"                          '(( HIMMEL_CONSOLE_LEG = 5 )) && @P@'
# shellcheck disable=SC2016 # literal $(( )) payload, must not expand
diff_row leak   "\$(( )) as a bare statement"                       '$(( HIMMEL_CONSOLE_LEG = 0 )); @P@'
# shellcheck disable=SC2016 # literal $(( )) payload, must not expand
diff_row leak   "\$(( )) as an argument"                            'echo $(( HIMMEL_CONSOLE_LEG = 0 )); @P@'
# shellcheck disable=SC2016 # literal $(( )) payload, must not expand
diff_row leak   "\$(( )) inside an assignment word"                 'x=$(( HIMMEL_CONSOLE_LEG = 0 )); @P@'
# shellcheck disable=SC2016 # literal $(( )) payload, must not expand
diff_row leak   "\$(( )) inside double quotes, spaced"              'echo "$(( HIMMEL_CONSOLE_LEG = 0 ))"; @P@'
# shellcheck disable=SC2016 # literal $(( )) payload, must not expand
diff_row leak   "\$(( )) inside double quotes, no spaces"           'echo "$((HIMMEL_CONSOLE_LEG=0))"; @P@'
diff_row leak   "seam cleared in an if condition"                   'if (( HIMMEL_CONSOLE_LEG = 0 )); then :; fi; @P@'
diff_row leak   "seam cleared in a while condition"                 'while (( HIMMEL_CONSOLE_LEG = 0 )); do :; done; @P@'
diff_row leak   "seam cleared in a C-style for init"                'for (( HIMMEL_CONSOLE_LEG = 5; HIMMEL_CONSOLE_LEG < 3; )); do :; done; @P@'
diff_row leak   "inside an eval string (recursion)"                 "eval '(( HIMMEL_CONSOLE_LEG = 0 ))'; @P@"
diff_row leak   "inside a bash -c string, same child shell"         "bash -c '(( HIMMEL_CONSOLE_LEG = 0 )); @P@'"
diff_row leak   "chokepoint inside the SAME subshell as the clear"  '( (( HIMMEL_CONSOLE_LEG = 0 )); @P@ )'
diff_row noleak "non-seam spaced assignment"                        '(( x = 0 )); @P@'
diff_row noleak "seam == comparison"                                '(( HIMMEL_CONSOLE_LEG == 0 )); @P@'
diff_row noleak "seam > comparison"                                 '(( HIMMEL_CONSOLE_LEG > 0 )); @P@'
diff_row noleak "seam >= comparison"                                '(( HIMMEL_CONSOLE_LEG >= 0 )); @P@'
diff_row noleak "seam <= comparison"                                '(( HIMMEL_CONSOLE_LEG <= 1 )); @P@'
diff_row noleak "seam != comparison"                                '(( HIMMEL_CONSOLE_LEG != 0 )); @P@'
diff_row noleak "seam read into another variable"                   '(( x = HIMMEL_CONSOLE_LEG )); @P@'
diff_row noleak "seam in a ternary condition"                       '(( HIMMEL_CONSOLE_LEG ? 1 : 2 )); @P@'
diff_row noleak "seam compared, joined with ||"                     '(( x == 1 || HIMMEL_CONSOLE_LEG == 2 )); @P@'
diff_row noleak "longer name sharing the seam as a prefix"          '(( HIMMEL_CONSOLE_LEG_X = 0 )); @P@'
# shellcheck disable=SC2016 # literal $(( )) payload, must not expand
diff_row noleak "\$(( )) read of the seam"                          'echo $(( HIMMEL_CONSOLE_LEG + 1 )); @P@'
diff_row noleak "seam assigned inside a real closed subshell"       '( (( HIMMEL_CONSOLE_LEG = 0 )) ); @P@'
# --- HIMMEL-3185 CodeRabbit round 1 (PR #853): the arithmetic body sits in the
# SAME segment as the chokepoint call (bash expands `$(( ))` in a word BEFORE it
# execs the command, so the seam is already cleared when the child starts), and
# a NESTED subscript. Every earlier `$(( ))` row put the chokepoint in a LATER
# segment (`echo $(( ... )); @P@`), which is why none of them saw this shape: the
# `;` had already flushed the arithmetic segment before the chokepoint segment
# was scanned. Neighbouring shapes swept with it. ---
# shellcheck disable=SC2016 # literal $(( )) payload, must not expand
diff_row leak   "\$(( )) as an argument of the chokepoint call itself" '@P@ $(( HIMMEL_CONSOLE_LEG = 0 ))'
# shellcheck disable=SC2016 # literal $(( )) payload, must not expand
diff_row leak   "\$(( )) argument, no spaces"                       '@P@ $((HIMMEL_CONSOLE_LEG=0))'
# shellcheck disable=SC2016 # literal $(( )) payload, must not expand
diff_row leak   "\$(( )) in double quotes as the chokepoint argument" '@P@ "$(( HIMMEL_CONSOLE_LEG = 0 ))"'
# shellcheck disable=SC2016 # literal $(( )) payload, must not expand
diff_row leak   "\$(( )) in a prefix assignment word before the call" 'x=$(( HIMMEL_CONSOLE_LEG = 0 )) @P@'
# shellcheck disable=SC2016 # literal $(( )) payload, must not expand
diff_row leak   "\$(( )) argument, other seam: ARMAUTOMERGE"        '@P@ $(( ARMAUTOMERGE = 0 ))'
# shellcheck disable=SC2016 # literal $(( )) payload, must not expand
diff_row leak   "\$(( )) argument inside a bash -c string"          "bash -c '@P@ \$(( HIMMEL_CONSOLE_LEG = 0 ))'"
# shellcheck disable=SC2016 # literal $(( )) payload, must not expand
diff_row leak   ": \$(( )) no-op command carrying the clear"         ': $(( HIMMEL_CONSOLE_LEG = 0 )); @P@'
# shellcheck disable=SC2016 # literal $(( )) payload, must not expand
diff_row leak   ": \$(( )) no-op, chokepoint chained with &&"        ': $((HIMMEL_CONSOLE_LEG=0)) && @P@'
diff_row leak   "nested subscript (( NAME[idx[0]] = 0 ))"            'idx=2; (( HIMMEL_CONSOLE_LEG[idx[0]] = 0 )); @P@'
diff_row leak   "doubly nested subscript"                            'a=0; b=0; (( HIMMEL_CONSOLE_LEG[a[b[0]]] = 0 )); @P@'
diff_row leak   "nested subscript, compound operator"                'idx=2; (( HIMMEL_CONSOLE_LEG[idx[0]] += 1 )); @P@'
diff_row leak   "seam assigned INSIDE another element's subscript"   '(( x[ HIMMEL_CONSOLE_LEG = 0 ] = 1 )); @P@'
# shellcheck disable=SC2016 # literal $[ ] payload, must not expand
diff_row leak   "legacy \$[ ] arithmetic as the chokepoint argument"  '@P@ $[ HIMMEL_CONSOLE_LEG = 0 ]'
# shellcheck disable=SC2016 # literal $[ ] payload, must not expand
diff_row leak   "legacy \$[ ] arithmetic as a bare statement"        ': $[ HIMMEL_CONSOLE_LEG = 0 ]; @P@'
# `${NAME:=v}` / `${NAME=v}` assign only when the variable is UNSET (or null for
# `:=`): the armed seam is set to a non-empty value, so real bash leaves it
# alone -- no leak (verified by the oracle, not assumed).
# shellcheck disable=SC2016 # literal ${ } payload, must not expand
diff_row noleak "\${NAME:=0} default-assignment of the SET seam"     ': ${HIMMEL_CONSOLE_LEG:=0}; @P@'
# shellcheck disable=SC2016 # literal ${ } payload, must not expand
diff_row overdeny "\${NAME=0} default-assignment of the SET seam"    ': ${HIMMEL_CONSOLE_LEG=0}; @P@'
# shellcheck disable=SC2016 # literal ${ } payload, must not expand
diff_row noleak "\${NAME:=0} as the chokepoint argument"             '@P@ ${HIMMEL_CONSOLE_LEG:=0}'
# shellcheck disable=SC2016 # literal $(( )) payload, must not expand
diff_row noleak "\$(( )) read of the seam as the chokepoint argument" '@P@ $(( HIMMEL_CONSOLE_LEG + 1 ))'
# shellcheck disable=SC2016 # literal $(( )) payload, must not expand
diff_row noleak "\$(( )) == comparison as the chokepoint argument"   '@P@ $(( HIMMEL_CONSOLE_LEG == 1 ))'
# shellcheck disable=SC2016 # literal $(( )) payload, must not expand
diff_row noleak "non-seam \$(( )) assignment as the chokepoint argument" '@P@ $(( x = 0 ))'
# --- HIMMEL-3195 DOCUMENTED RESIDUAL (operator ruling 2026-09-19: accept as a
# gap, no structural fix). A bare variable in `(( ))` has its VALUE evaluated as
# arithmetic, so `x=SEAM=0; (( x ))` assigns the seam through a value the static
# fold cannot follow (the value could equally come from a file, `read` or the
# env). Real bash clears the seam; the guard ALLOWS. Same class as the header's
# string-reconstruction residual. If a future change closes this, flip the row
# to `leak` deliberately. HIMMEL-1813 did: the raw backstop denies the literal
# `SEAM=` text (1813 backstop over-deny (console X ruling 07:05)). ---
diff_row leak "indirect: x=SEAM=0; (( x )) assigns via the VALUE (HIMMEL-3195)" 'x=HIMMEL_CONSOLE_LEG=0; (( x )); @P@'
rm -rf "$ORACLE_DIR"

# --- Seam-var env-prefix denies onto the suite chokepoints (unrelated to any
# invoked-program check; these are ordinary registered chokepoints). ---
QR="scripts/quiet-run.sh"
assert_deny "HIMMEL_SUITE_SLOT_HELD= prefix on quiet-run suite" "$(j "HIMMEL_SUITE_SLOT_HELD=/tmp/x bash $QR suite -- bash scripts/test-quiet-run.sh")"
assert_deny "HIMMEL_SUITE_SLOTS= prefix on quiet-run suite"     "$(j "HIMMEL_SUITE_SLOTS=9 bash $QR suite -- bun test")"
assert_deny "HIMMEL_SUITE_SLOTS= prefix on run-shell-tests"     "$(j "HIMMEL_SUITE_SLOTS=9 bash scripts/ci/run-shell-tests.sh .")"
assert_allow "SUITE_LOCK_WAIT= prefix on quiet-run suite"      "$(j "SUITE_LOCK_WAIT=60 bash $QR suite -- bash scripts/test-quiet-run.sh")"
assert_allow "run-shell-tests.sh (the CI chokepoint)"          "$(j "bash scripts/ci/run-shell-tests.sh --shard 1/8 .")"

# --- HIMMEL-1813 raw-string backstop (console X ruling at b8ae2143): before
# any parsing, a raw command naming a registered chokepoint AND, anywhere in
# the same raw string, that chokepoint's seam var or an env -S /
# --split-string denies. Comments, quotes, functions and depth do not matter.
# Each deny row was an ALLOW before the backstop. ---
BS_SEAM="${SW_VAR}=1 bash $STOP_WORKER"
BS_NEST=$BS_SEAM
for _ in 1 2 3 4 5 6 7; do BS_NEST="bash -c $(printf '%q' "$BS_NEST")"; done
assert_deny "1813 backstop: quoted heredoc to bash, apostrophe comment" "$(j "bash <<'EOF'"$'\n'"# don't worry"$'\n'"$BS_SEAM"$'\n'"EOF")"
assert_deny "1813 backstop: apostrophe comment line before the seam"   "$(j "# don't"$'\n'"$BS_SEAM")"
assert_deny "1813 backstop: heredoc opener with an apostrophe comment" "$(j "bash <<EOF # it's"$'\n'"$BS_SEAM"$'\n'"EOF")"
assert_deny "1813 backstop: cat() redefined, here-string"              "$(j "cat(){ bash; }; cat <<< '$BS_SEAM'")"
assert_deny "1813 backstop: function cat redefined, here-string"       "$(j "function cat { bash; }; cat <<< '$BS_SEAM'")"
assert_deny "1813 backstop: PATH= prefix on a reader here-string"      "$(j "PATH=/x cat <<< '$BS_SEAM'")"
assert_deny "1813 backstop: reader writes a file a shell then runs"    "$(j "cat <<< '$BS_SEAM' > /tmp/f; bash /tmp/f")"
assert_deny "1813 backstop: tee writes a file sh then runs"            "$(j "tee /tmp/f <<< '$BS_SEAM'; sh /tmp/f")"
assert_deny "1813 backstop: bash -c nested past the depth cap"         "$(j "$BS_NEST")"
BS_NEST="bash $STOP_WORKER"
for _ in 1 2 3 4 5 6 7; do BS_NEST="bash -c $(printf '%q' "$BS_NEST")"; done
assert_deny "1813 backstop: past the depth cap, a bare mention denies" "$(j "$BS_NEST")"
assert_allow "1813 backstop control: env ls with 2>&1"                 "$(j "env FOO=1 ls 2>&1")"
# shellcheck disable=SC2016 # literal $y payload, must not expand
assert_allow "1813 backstop control: grep here-string of a variable"   "$(j 'grep x <<< "$y"')"
assert_allow "1813 backstop control: ls piped to tee"                  "$(j "ls 2>&1 | tee out.txt")"
assert_allow "1813 backstop control: env -S naming no chokepoint"      "$(j "env -S 'echo hi'")"
# A redirect-only here-string leaves no command word; the reader lookup must
# not abort the hook under nounset (rc=1 is a hook error, not a deny).
assert_allow "1813 redirect-only here-string (no command word)"       "$(j "<<< hello")"
assert_deny  "1813 redirect-only here-string, then a seam segment"    "$(j "<<< hello; ${SW_VAR}=1 bash $STOP_WORKER")"
# NAME+= is a real prefix assignment too (judge r5, console X NO-GO at 64bc44b1).
assert_deny  "1813 append-assignment SEAM+= prefix"                   "$(j "STOP_WORKER_GRACE_SECS+=1 bash scripts/lanes/stop-worker.sh")"
assert_deny  "1813 append-assignment SEAM+= prefix through env"       "$(j "HIMMEL_CONSOLE_LEG+=1 env bash $MERGE_ON_GREEN 1")"
assert_allow "1813 backstop control: bare chokepoint, no seam, no -S"  "$(j "bash $STOP_WORKER")"

# --- HIMMEL-3904: process wrappers (nice/timeout/stdbuf/ionice/chrt) re-enter
# command position; `<wrapper> env SEAM=x bash <chokepoint>` must be examined,
# not stopped at the wrapper's name. ---
assert_deny  "3904 nice env seam chokepoint"               "$(j "nice env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 nice -n 5 env seam chokepoint"          "$(j "nice -n 5 env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 nice -5 env seam chokepoint"            "$(j "nice -5 env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 nice --adjustment=5 env seam chokepoint" "$(j "nice --adjustment=5 env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 timeout DUR env seam chokepoint"        "$(j "timeout 60 env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 timeout -s KILL -k 5 DUR env seam"      "$(j "timeout -s KILL -k 5 60 env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 timeout --signal=KILL --foreground -v"  "$(j "timeout --signal=KILL --foreground -v 60 env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 stdbuf -o0 env seam chokepoint"         "$(j "stdbuf -o0 env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 stdbuf --output=L -e 0 env seam"        "$(j "stdbuf --output=L -e 0 env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 ionice -c 3 env seam chokepoint"        "$(j "ionice -c 3 env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 ionice -c2 -n 7 env seam chokepoint"    "$(j "ionice -c2 -n 7 env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 chrt -b 0 env seam chokepoint"          "$(j "chrt -b 0 env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 chrt 10 env seam chokepoint"            "$(j "chrt 10 env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 chrt -b omitted priority"               "$(j "chrt -b env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 chrt priority then --"                  "$(j "chrt -b 0 -- env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 path-qualified /usr/bin/nice"           "$(j "/usr/bin/nice env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 stacked nice timeout env"               "$(j "nice -n 5 timeout 5 env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 stacked timeout stdbuf ionice env"      "$(j "timeout 5 stdbuf -o0 ionice -c 3 env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 wrapper after benign prefix assignment" "$(j "BENIGN_TOKEN=1 nice env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 unset seam, then nice chokepoint"       "$(j "unset ${MOG_VAR}; nice bash $MERGE_ON_GREEN")"
assert_deny  "3904 export -n seam, then timeout chokepoint" "$(j "export -n ${MOG_VAR}; timeout 60 bash $MERGE_ON_GREEN")"
assert_deny  "3904 nice env --unset= seam"                 "$(j "nice env --unset=${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 wrapper after -- terminator"            "$(j "nice -- env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 wrapper inside bash -c"                 "$(j "bash -c 'nice env -u ${MOG_VAR} bash $MERGE_ON_GREEN'")"
assert_deny  "3904 fail closed: nice unknown option"       "$(j "nice --bogus-opt env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 fail closed: timeout unknown option"    "$(j "timeout --bogus-opt 5 env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 fail closed: stdbuf unknown option"     "$(j "stdbuf -Z env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 fail closed: ionice unknown option"     "$(j "ionice --bogus env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_deny  "3904 fail closed: chrt unknown option"       "$(j "chrt --bogus 0 env -u ${MOG_VAR} bash $MERGE_ON_GREEN")"
assert_allow "3904 control: nice around a non-chokepoint"       "$(j "nice env -u ${MOG_VAR} ls")"
assert_allow "3904 control: timeout around a non-chokepoint"    "$(j "timeout 60 env -u ${MOG_VAR} ls")"
assert_allow "3904 control: stdbuf around a non-chokepoint"     "$(j "stdbuf -o0 env -u ${MOG_VAR} ls")"
assert_allow "3904 control: ionice around a non-chokepoint"     "$(j "ionice -c 3 env -u ${MOG_VAR} ls")"
assert_allow "3904 control: chrt around a non-chokepoint"       "$(j "chrt -b 0 env -u ${MOG_VAR} ls")"
assert_allow "3904 control: nice around chokepoint, no seam"    "$(j "nice env bash $MERGE_ON_GREEN")"
assert_allow "3904 control: timeout around chokepoint, no seam" "$(j "timeout 60 env bash $MERGE_ON_GREEN")"
assert_allow "3904 control: stdbuf around chokepoint, no seam"  "$(j "stdbuf -o0 env bash $MERGE_ON_GREEN")"
assert_allow "3904 control: ionice around chokepoint, no seam"  "$(j "ionice -c 3 env bash $MERGE_ON_GREEN")"
assert_allow "3904 control: chrt around chokepoint, no seam"    "$(j "chrt -b 0 env bash $MERGE_ON_GREEN")"
assert_allow "3904 control: chrt -b omitted priority, non-chokepoint" "$(j "chrt -b env -u ${MOG_VAR} ls")"
assert_allow "3904 control: stacked wrappers, no seam"          "$(j "nice -n 5 timeout 5 bash $MERGE_ON_GREEN")"
assert_allow "3904 control: unknown option, no chokepoint named" "$(j "nice --bogus-opt env -u ${MOG_VAR} ls")"
assert_deny "3904 control: seam of a different chokepoint (3921 r3 over-deny: env option beside a chokepoint)" "$(j "nice env -u ${MOG_VAR} bash $STOP_WORKER --list")"

# --- ALLOWED: fail-open proofs ---
assert_allow "bare sanctioned invocation (no prefix)"  "$(j "bash $MERGE_ON_GREEN")"
assert_allow "bare invocation, other chokepoint"         "$(j "bash $STOP_WORKER --list")"
assert_allow "env wrapper WITHOUT a seam var"            "$(j "env bash $MERGE_ON_GREEN")"
assert_allow "registered var, UNREGISTERED script"       "$(j "${SW_VAR}=9 bash scripts/some/unregistered-script.sh")"
assert_allow "UNREGISTERED var, registered chokepoint"   "$(j "TOTALLY_UNRELATED_VAR=1 bash $MERGE_ON_GREEN")"
assert_allow "seam var of a DIFFERENT chokepoint"        "$(j "${MOG_VAR}=1 bash $STOP_WORKER --list")"
assert_allow "longer var name sharing a prefix"          "$(j "${MOG_VAR}X=1 bash $MERGE_ON_GREEN")"
assert_deny "1813 backstop over-deny (console X ruling 07:05): assignment as an ARGUMENT, not a prefix"   "$(j "bash $STOP_WORKER --dry-run ${SW_VAR}=9")"
assert_allow "non-Bash/PowerShell tool"                  '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'
assert_allow "bypass: ENV_PREFIX_GUARD_OK=1 in the hook env" "$(j "${MOG_VAR}=1 bash $MERGE_ON_GREEN")" "ENV_PREFIX_GUARD_OK=1"

# --- ALLOWED: fail-open on unresolvable inputs (belt posture) ---
TMPDIR_F=$(mktemp -d)
assert_allow "registry file missing"        "$(j "${MOG_VAR}=1 bash $MERGE_ON_GREEN")" "CHOKEPOINT_REGISTRY=$TMPDIR_F/nope.json"
printf '[1,2,3]\n' >"$TMPDIR_F/bad.json"
assert_allow "registry not a JSON object"   "$(j "${MOG_VAR}=1 bash $MERGE_ON_GREEN")" "CHOKEPOINT_REGISTRY=$TMPDIR_F/bad.json"
rm -rf "$TMPDIR_F"
assert_allow "empty stdin"                  ''

# --- Soft drift check: the guard should be wired in .claude/settings.json.
# WARN-only (not a FAIL) because the wiring may land in a later commit than
# the hook (review lanes cannot always edit settings.json) -- a hard gate
# here would turn that sequencing into a false red. The hookspath-misconfig
# pre-commit hook validates settings.json hook references independently.
# --- HIMMEL-3914: the basename backstops (raw_mention, split_mention) match a
# WHOLE path component, so a longer file name that merely ends in a
# registered basename (cargo.sh vs go.sh) no longer over-denies. The quote-
# stripped `$x"go.sh"` (x empty runs go.sh) still denies: a `$`+identifier
# run on the left counts as a boundary. ---
assert_allow "3914 word boundary: seam prefix + tools/cargo.sh is not go.sh" "$(j "HIMMEL_REPO=/x bash tools/cargo.sh")"
assert_allow "3914 word boundary: env -S naming tools/cargo.sh" "$(j "env -S 'bash tools/cargo.sh'")"
assert_deny "3914 word boundary control: seam prefix + ./go.sh" "$(j "HIMMEL_REPO=/x bash ./go.sh")"
assert_deny "3914 word boundary control: seam prefix + \$x\"go.sh\" (x empty)" "$(j "HIMMEL_REPO=/x bash \$x\"go.sh\"")"
assert_deny "3914 word boundary control: env -S naming go.sh" "$(j "env -S 'bash scripts/handover/console-kit/go.sh'")"

# --- HIMMEL-3921: the text layer for detached / non-Linux launches. A seam
# write (VAR=, export, env, read, printf -v) beside a program word under a
# chokepoint directory that carries a glob/brace metachar, an ANSI-C $' or a
# $var piece is denied even when setsid -f / at / a double-fork hides the
# program position; BASH_ENV, BASH_FUNC_*, SHELLOPTS, BASHOPTS and extdebug are
# refused beside a chokepoint word; and CLEARING a seam or HIMMEL_CONSOLE_LEG
# (env -u / unset) beside a chokepoint word is refused too. The obfuscated seam
# NAME (export "$n=1") stays a documented residual. ---
GOK='scripts/handover/console-kit'
assert_deny "3921 setsid -f: VAR= prefix, globbed go.sh"          "$(j "HIMMEL_CONSOLE_LEG=1 setsid -f bash $GOK/g*.sh")"
assert_deny "3921 setsid -f: export, ? glob"                      "$(j "export HIMMEL_CONSOLE_LEG=1; setsid -f bash $GOK/g?.sh")"
assert_deny "3921 setsid -f: env assignment, [] glob"             "$(j "env HIMMEL_CONSOLE_LEG=1 setsid -f bash $GOK/go.s[h]")"
assert_deny "3921 setsid -f: read, brace"                         "$(j "read -r HIMMEL_CONSOLE_LEG <<<1; setsid -f bash $GOK/{go}.sh")"
assert_deny "3921 setsid -f: printf -v, ANSI-C word"              "$(j "printf -v HIMMEL_CONSOLE_LEG 1; setsid -f bash $GOK/"'$'"'go.sh'")"
assert_deny "3921 setsid -f: \$var piece in the path word"        "$(j "HIMMEL_CONSOLE_LEG=1 setsid -f bash $GOK/\$n.sh")"
assert_deny "3921 at: VAR= prefix, globbed go.sh"                 "$(j "echo 'HIMMEL_CONSOLE_LEG=1 bash $GOK/g*.sh' | at now")"
assert_deny "3921 at: export, ? glob"                             "$(j "echo 'export HIMMEL_CONSOLE_LEG=1; bash $GOK/g?.sh' | at now")"
assert_deny "3921 at: env assignment, [] glob"                    "$(j "echo 'env HIMMEL_CONSOLE_LEG=1 bash $GOK/go.s[h]' | at now")"
assert_deny "3921 at: read, brace"                                "$(j "echo 'read -r HIMMEL_CONSOLE_LEG <<<1; bash $GOK/{go}.sh' | at now")"
assert_deny "3921 at: printf -v, \$var piece"                     "$(j "echo 'printf -v HIMMEL_CONSOLE_LEG 1; bash $GOK/\$n.sh' | at now")"
assert_deny "3921 double-fork: seam write + globbed merge"        "$(j "( (sleep 1; HIMMEL_CONSOLE_LEG=1 exec bash scripts/handover/merge-on-g*.sh) & )")"
assert_deny "3921 codex-1: unset marker beside globbed go.sh"     "$(j "unset HIMMEL_CONSOLE_LEG; setsid -f bash $GOK/g*.sh")"
assert_deny "3921 codex-1: BASH_ENV beside globbed go.sh"         "$(j "BASH_ENV=/tmp/x setsid -f bash $GOK/g*.sh")"
assert_deny "3921 codex-1: extdebug beside globbed merge"         "$(j "setsid -f bash -O extdebug scripts/handover/merge-on-g*.sh")"
assert_deny "3921 r2: env -u (one space) beside a chokepoint"     "$(j "setsid -f env -u HIMMEL_CONSOLE_LEG bash $MERGE_ON_GREEN")"
assert_deny "3921 r2: env --unset= beside a chokepoint"           "$(j "setsid -f env --unset=HIMMEL_CONSOLE_LEG bash $MERGE_ON_GREEN")"
assert_deny "3921 r3: env -uNAME (attached) beside a chokepoint"  "$(j "setsid -f env -uHIMMEL_CONSOLE_LEG bash $MERGE_ON_GREEN")"
assert_deny "3921 r3: env -iu NAME (clustered) beside a chokepoint" "$(j "setsid -f env -iu HIMMEL_CONSOLE_LEG bash $MERGE_ON_GREEN")"
assert_deny "3921 r3: env --unset NAME beside a chokepoint"       "$(j "setsid -f env --unset HIMMEL_CONSOLE_LEG bash $MERGE_ON_GREEN")"
assert_deny "3921 r3: env -C dir beside a chokepoint"             "$(j "setsid -f env -C / bash $MERGE_ON_GREEN")"
assert_allow "3921 r3: plain chokepoint call, no env option"      "$(j "bash $MERGE_ON_GREEN --jira-transition")"
assert_allow "3921 r3: env NAME=v (no option) with chokepoint flag" "$(j "env FOO=1 bash $MERGE_ON_GREEN --jira-transition")"
assert_deny "3921 BASH_ENV beside a chokepoint"                   "$(j "BASH_ENV=/tmp/x bash $MERGE_ON_GREEN")"
assert_deny "3921 exported BASH_FUNC_ beside a chokepoint"        "$(j "export 'BASH_FUNC_printf%%=() { :; }'; bash $MERGE_ON_GREEN")"
assert_deny "3921 SHELLOPTS beside a chokepoint"                  "$(j "SHELLOPTS=xtrace bash $MERGE_ON_GREEN")"
assert_deny "3921 BASHOPTS beside a chokepoint"                   "$(j "BASHOPTS=extdebug bash $MERGE_ON_GREEN")"
assert_deny "3921 extdebug (shopt) beside a chokepoint"           "$(j "shopt -s extdebug; bash $MERGE_ON_GREEN")"
assert_deny "3921 extdebug (-O) beside a chokepoint"              "$(j "bash -O extdebug $MERGE_ON_GREEN")"
assert_deny "3921 clear: env -u HIMMEL_CONSOLE_LEG + merge"       "$(j "env -u HIMMEL_CONSOLE_LEG setsid -f bash $MERGE_ON_GREEN")"
assert_deny "3921 clear: double-fork env -u marker + merge"       "$(j "( (sleep 1; env -u HIMMEL_CONSOLE_LEG bash $MERGE_ON_GREEN) & )")"
assert_deny "3921 clear: unset marker then detached merge"        "$(j "unset HIMMEL_CONSOLE_LEG; setsid -f bash $MERGE_ON_GREEN")"
assert_deny "3921 clear: env --unset=seam inside at"              "$(j "echo 'env --unset=HIMMEL_CONSOLE_LEG bash $GOK/go.sh' | at now")"
assert_allow "3921 literal merge, no seam write"                  "$(j "bash $MERGE_ON_GREEN")"
assert_allow "3921 literal merge --jira-transition"               "$(j "bash $MERGE_ON_GREEN --jira-transition")"
assert_allow "3921 literal go.sh as the console kit calls it"     "$(j "bash $GOK/go.sh 1515 0123456789abcdef0123456789abcdef01234567")"
assert_allow "3921 setsid -f literal merge"                       "$(j "setsid -f bash $MERGE_ON_GREEN")"
assert_allow "3921 at literal merge"                              "$(j "echo 'bash $MERGE_ON_GREEN' | at now")"
assert_allow "3921 a glob over scripts with no seam write"        "$(j "ls scripts/handover/*.sh")"
# Over-deny by design (codex-1 sweep): any unset beside a globbed scripts/ word is refused.
assert_deny "3921 unset beside a globbed scripts/ word (over-deny)" "$(j "unset FOO; ls scripts/handover/*.sh")"
assert_allow "3921 unset of an unrelated var, no scripts/ glob"    "$(j "unset FOO; ls docs")"

# 3921 judge C1: ordinary commands are not obfuscated chokepoint paths.
assert_allow "3921 C1 printf with an ANSI-C tab/newline"      "$(j 'printf $'"'"'a\tb\n'"'")"
# shellcheck disable=SC2016
assert_allow "3921 C1 IFS=ANSI-C tab in a read loop"         "$(j 'while IFS=$'"'"'\t'"'"' read -r a b; do echo $a; done < f')"
assert_allow "3921 C1 cut -d ANSI-C tab then export"          "$(j 'cut -d$'"'"'\t'"'"' -f1 f; export LC_ALL=C')"
# r11 (console ruling): the prefix compare is gone, so a scripts/ glob beside a
# write verb now denies even when unrelated to a chokepoint (over-deny, HIMMEL-3955).
assert_deny "3921 r11 (was C1 allow) printf over a scripts glob"  "$(j "printf '%s\\n' scripts/hooks/*.sh")"
assert_allow "3921 r11 (was C1 allow) grep env over a scripts glob" "$(j "grep -ln env scripts/hooks/*.sh")"
assert_deny "3921 r11 (was C1 allow) git log glob then read"       "$(j "git log -- scripts/hooks/*.sh; read -r x")"
# 3921 judge I1: clear spellings the first arm missed, beside a chokepoint word.
assert_deny "3921 I1 declare +x then setsid merge"   "$(j "declare +x HIMMEL_CONSOLE_LEG; setsid -f bash $MERGE_ON_GREEN")"
assert_deny "3921 I1 typeset +x"                     "$(j "typeset +x HIMMEL_CONSOLE_LEG; setsid -f bash $MERGE_ON_GREEN")"
assert_deny "3921 I1 declare +rx"                    "$(j "declare +rx HIMMEL_CONSOLE_LEG; setsid -f bash $MERGE_ON_GREEN")"
assert_deny "3921 I1 env \$x -u NAME"                "$(j "env \$x -u HIMMEL_CONSOLE_LEG bash $MERGE_ON_GREEN")"
assert_deny "3921 I1 env \$x-uNAME"                  "$(j "env \$x-uHIMMEL_CONSOLE_LEG bash $MERGE_ON_GREEN")"
assert_deny "3921 I1 globbed env binary -u"          "$(j "/usr/bin/en? -u HIMMEL_CONSOLE_LEG bash $MERGE_ON_GREEN")"
assert_deny "3921 I1 unset \${!PREFIX*} in a subshell" "$(j "( (unset \${!HIMMEL_CON*}; exec bash $MERGE_ON_GREEN) & )")"
assert_deny "3921 I1 export -n \${!PREFIX@}"         "$(j "export -n \${!HIMMEL_@}; bash $MERGE_ON_GREEN")"
assert_deny "3921 I1 exec -c"                        "$(j "( (exec -c bash $MERGE_ON_GREEN) & )")"
assert_deny "3921 r5 detached exec -c beside a globbed kit path" "$(j "setsid -f exec -c bash scripts/handover/console-kit/g*.sh")"
# 3921 judge r2: any unset, and long-option / bare-dash env spellings.
assert_deny "3921 r2 I-A unset of an ANSI-C-split name"   "$(j "setsid -f bash -c 'unset HIMMEL_CON\$'\"'\"'SOLE_LEG'\"'\"'; bash $MERGE_ON_GREEN'")"
assert_deny "3921 r2 I-A unset of a command-substituted name" "$(j "unset \$(echo HIMMEL_CONSOLE_LEG); setsid -f bash $MERGE_ON_GREEN")"
assert_deny "3921 r2 I-A unset of a concatenated name"    "$(j "n=HIMMEL_CONSOLE; unset \${n}_LEG; setsid -f bash $MERGE_ON_GREEN")"
assert_deny "3921 r2 I-B globbed env --ignore-environment" "$(j "/usr/bin/en? --ignore-environment bash $MERGE_ON_GREEN")"
assert_deny "3921 r2 I-B globbed env --unset=NAME"         "$(j "/usr/bin/en? --unset=HIMMEL_CONSOLE_LEG bash $MERGE_ON_GREEN")"
assert_deny "3921 r2 I-B env bare dash"                    "$(j "\$e - bash $MERGE_ON_GREEN")"
assert_allow "3921 r2 unset with no chokepoint word"       "$(j "unset FOO; echo hi")"
# 3921 judge r3: ANSI-C escapes are an allowlist (whitespace/quote only).
assert_deny "3921 r3 fully \\U-encoded path word"  "$(j "setsid -f env FOO=1 \$'\\U0000002fbin\\U0000002fsh'")"
assert_deny "3921 r3 \\c control escape word"      "$(j "setsid -f env FOO=1 \$'\\cAx'")"
assert_deny "3921 r3 \\e escape word"              "$(j "setsid -f env FOO=1 \$'\\e[0m'")"
assert_allow "3921 r3 printf ANSI-C newline/tab/quote" "$(j "printf \$'a\\tb\\n\\'c\\\\'; export LC_ALL=C")"
# 3921 r8: an env-clearing token beside a globbed kit path needs no write verb.
assert_deny "3921 r8 held env -i then a globbed kit path"  "$(j "e=/usr/bin/env; setsid -f \"\$e\" -i bash scripts/handover/console-kit/g*.sh")"
assert_deny "3921 r8 held env -u X then a globbed kit path" "$(j "setsid -f \"\$e\" -u X scripts/handover/console-kit/g*.sh")"
# 3921 r9: dot-segment / double-slash spellings of a scripts/ path (blunt deny).
assert_deny "3921 r9 lanes .. segment + glob"      "$(j "STOP_WORKER_GRACE_SECS=0 setsid -f bash scripts/lanes/../lanes/stop-w*.sh")"
assert_deny "3921 r9 lanes /./ segment + glob"     "$(j "STOP_WORKER_GRACE_SECS=0 setsid -f bash scripts/lanes/./stop-w*.sh")"
assert_deny "3921 r9 scripts// double slash"       "$(j "STOP_WORKER_GRACE_SECS=0 setsid -f bash scripts//lanes/stop-w*.sh")"
assert_deny "3921 r9 lib .. segment + glob"        "$(j "FLEET_CAP_OK=1 setsid -f bash scripts/lib/../lib/bank-pre*.sh")"
assert_deny "3921 r9 env -i quiet-run .. glob"     "$(j "setsid -f env -i bash scripts/x/../quiet-r*.sh")"
assert_deny "3921 r9 handover .. segment + glob"   "$(j "setsid -f env FOO=1 bash scripts/handover/../handover/console-kit/g*.sh")"
assert_deny "3921 r10 absolute path .. segment + glob"  "$(j "STOP_WORKER_GRACE_SECS=0 setsid -f bash /abs/himmel/scripts/lanes/../lanes/stop-w*.sh")"
assert_deny "3921 r10 leading dir scripts// + glob"     "$(j "STOP_WORKER_GRACE_SECS=0 setsid -f bash x/scripts//lanes/stop-w*.sh")"
assert_deny "3921 r10 absolute path /./ segment + glob" "$(j "FLEET_CAP_OK=1 setsid -f bash /abs/scripts/lib/./bank-pre*.sh")"
# 3921 r11: any glob after scripts/ beside a write/clear token denies, no prefix compare.
assert_deny "3921 r11 quote-split segment before a glob"  "$(j "HIMMEL_CONSOLE_LEG=1 setsid -f bash scripts/handover/con\"sole\"-kit/g*.sh")"
assert_deny "3921 r11 backslash-split segment before a glob" "$(j "HIMMEL_CONSOLE_LEG=1 setsid -f bash scripts/handover/con\\sole-kit/g*.sh")"
assert_deny "3921 r11 \$v piece before a glob"            "$(j "HIMMEL_CONSOLE_LEG=1 setsid -f bash scripts/handover/\$v/g*.sh")"
assert_allow "3921 r11 ls of a scripts glob, no write token"   "$(j "ls scripts/*.sh")"
assert_allow "3921 r11 grep over a scripts glob, no write token" "$(j "grep x scripts/cr/*")"
assert_allow "3921 I1 control: plain chokepoint call" "$(j "bash $MERGE_ON_GREEN --jira-transition")"
# HIMMEL-3955: the standalone -u*/-i*/--u*/--i*/bare - token counts only in env
# position (after an env-like word), so these ordinary commands stop over-denying.
# HIMMEL-4095: this was denied only because --id read as --i*; it is not env-clearing.
assert_allow "4095 no relief (glob/quote): ledger-append amend: --id, --set k=v, ? in the reason" "$(j "bash scripts/cr/ledger-append.sh amend --id 4 --set verdict=deferred --set deferred_to=HIMMEL-3929 --reason \"see scripts/hooks/x? why?\"")"
# HIMMEL-4779: these were the 3955 "no relief, main verdict" pins; the
# pobf_relief stages now place each -i/-u in a read-only stage or among sed's
# own options, so none of them clears an environment.
assert_allow "4779 grep -i over a scripts glob"      "$(j "grep -i foo scripts/hooks/*.sh")"
assert_allow "4779 sed -i over a scripts glob (not a seam or env write)" "$(j "sed -i s/a/b/ scripts/hooks/*.sh")"
assert_allow "4779 diff -u over a scripts glob"      "$(j "diff -u scripts/a.sh scripts/b*.sh")"
assert_allow "4779 ls -i / sort -u over a scripts glob" "$(j "ls -i scripts/hooks/*.sh; sort -u scripts/hooks/*.sh")"
assert_allow "4779 grep -n -i with a quoted pattern beside a chokepoint word" "$(j "grep -n -i 'title' $MERGE_ON_GREEN")"
assert_allow "4779 sed -n beside a chokepoint word, piped into grep -i -E" "$(j "sed -n 1,60p $MERGE_ON_GREEN | grep -i -E '^#'")"
assert_allow "4779 sed -i on a scratch file, then a scripts glob" "$(j "sed -i 's/a/b/' /tmp/scratch.txt; ls scripts/hooks/g*.sh")"
assert_allow "4779 python3 - heredoc reading a chokepoint file" "$(j "python3 - $MERGE_ON_GREEN <<'EOF'
import sys
print(open(sys.argv[1]).read()[:80])
EOF")"
assert_allow "4779 gh api -i beside a scripts glob" "$(j "gh api -i repos/o/r; ls scripts/hooks/g*.sh")"
# 4779 keep-denied twins: the nearest real env-clear for each relief above.
assert_deny "4779 sed e command running env -i over a scripts glob" "$(j "sed '1e env -i bash' scripts/hooks/x*.sh")"
# shellcheck disable=SC2016 # the $E is probe text, not an expansion
assert_deny "4779 sed e command running \$E -i (no env word)" "$(j 'sed -n "1e $E -i bash" scripts/hooks/x*.sh')"
assert_deny "4779 sed e command running env -i beside a chokepoint word" "$(j "sed '1e env -i bash x' $MERGE_ON_GREEN")"
assert_deny "4779 grep -i into a file that is then run" "$(j "grep -i x scripts/hooks/*.sh > /tmp/r.sh; bash /tmp/r.sh")"
assert_deny "4779 grep -i piped into sh" "$(j "grep -i x scripts/hooks/*.sh | sh")"
assert_deny "4779 sudo -u before grep -i" "$(j "sudo -u root grep -i x scripts/hooks/*.sh")"
assert_deny "4779 xargs -i over a scripts glob" "$(j "ls f | xargs -i bash scripts/hooks/g*.sh")"
assert_deny "4779 sudo -i beside a chokepoint word" "$(j "grep -n x f; sudo -i bash $MERGE_ON_GREEN")"
assert_deny "4779 an assignment prefix voids the git relief" "$(j "PAGER='env -i' git log -i scripts/hooks/*.sh")"
assert_deny "4779 an exec-capable interpreter keeps its -i counted" "$(j "python3 -c 'import os; os.execvp(\"x\", [])' -i $MERGE_ON_GREEN")"
# shellcheck disable=SC2016 # the $( is probe text, not an expansion
assert_deny "4779 -i in a substitution's output stage" "$(j 'cat $(grep -il x f) scripts/hooks/*.sh; $(echo env) -i bash scripts/hooks/g*.sh')"
# HIMMEL-4572: a verb joined into a name on BOTH sides (- or / left, - . or /
# right: block-chokepoint-env-prefix, scripts/eval/, block-read-secrets,
# pr-check-env.sh) is a filename, not the verb; a verb at /usr/bin/env still
# counts, and one joined side is not enough (judge on PR 2032): -printf and
# --printf= read escapes, .env is an interpreter's environment object.
assert_allow "4572 env inside a hyphenated file name beside a scripts glob" "$(j "git grep -l block-chokepoint-env-prefix -- 'scripts/*test*'")"
assert_allow "4572 eval as a directory name" "$(j "cat scripts/eval/*.sh")"
assert_allow "4572 read inside a hyphenated file name" "$(j "ls scripts/hooks/block-read-secrets*")"
assert_allow "4572 env inside a dotted file name beside a scripts glob" "$(j "cat scripts/cr/pr-check-env.sh scripts/hooks/g*.sh")"
assert_allow "4572 find -printf beside a scripts glob" "$(j "find scripts/hooks/g*.sh -printf '%p'")"
assert_allow "4572 stat --printf= beside a scripts glob" "$(j "stat --printf='%n' scripts/hooks/g*.sh")"
assert_allow "4572 a -printf at a word end beside a scripts glob" "$(j "find scripts/hooks/g*.sh -printf")"
assert_deny "4572 process.env beside a scripts glob" "$(j "node -e 'process.env.FOO=1' scripts/hooks/g*.sh")"
assert_allow "4572 a bare .env beside a scripts glob" "$(j "cat .env scripts/hooks/g*.sh")"
assert_allow "4572 .env.example (data in a read-only stage; HIMMEL-4933)" "$(j "cat .env.example scripts/hooks/g*.sh")"
assert_deny "4572 /usr/bin/env still counts as the env verb" "$(j "/usr/bin/env FOO=1 bash scripts/hooks/g*.sh")"
assert_deny "4572 eval after a separator still counts" "$(j "true;eval bash scripts/hooks/g*.sh")"
# HIMMEL-4933: a glob-only scripts/ word whose only seam trigger is a verb word
# in ARGUMENT position of read-only stages is data, not a seam write. A verb
# heading a stage, a real NAME= assignment, an env-clearing token or a hard
# word ($var, //, /., ANSI-C, paren) keeps the deny (fail-closed on any parse
# the relief cannot prove).
assert_allow "4933 grep -l export over a scripts glob" "$(j "grep -l export scripts/hooks/*.sh | sort")"
assert_allow "4933 git grep read over a scripts glob" "$(j "git grep -n read -- 'scripts/*/x.sh'")"
assert_allow "4933 cat piped to grep eval over a scripts glob" "$(j "cat scripts/hooks/g*.sh | grep eval")"
# sed keeps the deny: its own options (-i, e) can act on the glob.
# ponytail: sed over-denies here, the relief for it needs the HIMMEL-3930 structural parse
assert_deny "4933 control: sed beside a scripts glob keeps the deny" "$(j "sed 1d scripts/hooks/g*.sh | grep eval")"
assert_allow "4933 grep printf over a scripts glob" "$(j "grep printf scripts/hooks/*.sh | sort")"
assert_deny "4933 control: real env prefix, quoted glob path" "$(j "BASH_ENV=x bash 'scripts/hooks/g*.sh'")"
assert_deny "4933 control: real env prefix, ./ glob path" "$(j "BASH_ENV=x bash ./scripts/hooks/g*.sh")"
assert_deny "4933 control: real env prefix, absolute glob path" "$(j "BASH_ENV=x bash /home/u/h/scripts/hooks/g*.sh")"
assert_deny "4933 control: export heading a stage beside a scripts glob" "$(j "export FOO=1; ls scripts/hooks/*.sh")"
assert_deny "4933 control: printf heading a stage beside a scripts glob" "$(j "ls scripts/hooks/*.sh | printf x")"
# shellcheck disable=SC2016 # the $D is the literal command text under test
assert_deny "4933 control: a hard \$var path word keeps the deny" "$(j 'grep env scripts/$D/x.sh')"
assert_deny "4933 control: a // path word keeps the deny" "$(j "grep env scripts//hooks/x.sh")"
assert_deny "4933 control: a grouped path word keeps the deny" "$(j "grep env scripts/(a|b)/x.sh")"
assert_deny "4933 control: env -u clear beside a glob keeps the deny" "$(j "grep x scripts/hooks/*.sh; env -u BASH_ENV true")"
# HIMMEL-4954: vcmd must see a verb that heads a stage after a newline or a
# keyword/precommand head ({ then do else command builtin time \verb). With a
# decoy glob-read clause each of these was allowed at the #2133 head: the verb
# was classed as data and the glob-only relief cleared the call.
NL=$'\n'
H4954='n=HIMMEL_CONSOLE_LEG; ls scripts/hooks/*.sh'
T4954='bash scripts/handover/merge-on-green.sh'
# shellcheck disable=SC2016 # $n and $x are the literal command text under test
{
assert_deny "4954 newline, export \$n=1"          "$(j "${H4954}${NL}export \"\$n=1\"${NL}${T4954}")"
assert_deny "4954 newline, brace group export"    "$(j "${H4954}${NL}{ export \"\$n=1\"; }${NL}${T4954}")"
assert_deny "4954 newline, command export"        "$(j "${H4954}${NL}command export \"\$n=1\"${NL}${T4954}")"
assert_deny "4954 newline, backslash-escaped export" "$(j "${H4954}${NL}\\export \"\$n=1\"${NL}${T4954}")"
assert_deny "4954 newline, printf -v"             "$(j "${H4954}${NL}printf -v \"\$n\" 1${NL}${T4954}")"
assert_deny "4954 newline, eval"                  "$(j "${H4954}${NL}eval \"\$x\"${NL}${T4954}")"
assert_deny "4954 newline, env \$x bash"          "$(j "${H4954}${NL}env \"\$x\" ${T4954}")"
assert_deny "4954 same line, command export"      "$(j "${H4954}; command export \"\$n=1\"; ${T4954}")"
assert_deny "4954 same line, builtin export"      "$(j "${H4954}; builtin export \"\$n=1\"; ${T4954}")"
assert_deny "4954 same line, time eval"           "$(j "${H4954}; time eval \"\$x\"; ${T4954}")"
assert_deny "4954 same line, brace group export"  "$(j "${H4954}; { export \"\$n=1\"; }; ${T4954}")"
assert_deny "4954 same line, backslash-escaped export" "$(j "${H4954}; \\export \"\$n=1\"; ${T4954}")"
assert_deny "4954 then export"                    "$(j "${H4954}; if true; then export \"\$n=1\"; fi; ${T4954}")"
assert_deny "4954 do export"                      "$(j "${H4954}; for i in 1; do export \"\$n=1\"; done; ${T4954}")"
assert_deny "4954 negated export"                 "$(j "${H4954}; ! export \"\$n=1\"; ${T4954}")"
assert_deny "4954 if negated export"              "$(j "${H4954}; if ! export \"\$n=1\"; then :; fi; ${T4954}")"
assert_deny "4954 escaped command wrapper"        "$(j "${H4954}; \\command export \"\$n=1\"; ${T4954}")"
assert_deny "4954 case arm export"               "$(j "${H4954}; case x in x) export \"\$n=1\";; esac; ${T4954}")"
assert_deny "4954 else export"                  "$(j "${H4954}; if false; then :; else export \"\$n=1\"; fi; ${T4954}")"
}
# GREEN controls: a verb word in argument position stays data after the new heads.
assert_allow "4954 control: grep export after a newline" "$(j "ls scripts/hooks/*.sh${NL}grep -l export scripts/hooks/g*.sh")"
assert_allow "4954 control: command grep export"         "$(j "command grep -l export scripts/hooks/*.sh | sort")"
assert_deny "4572 printf -v still counts" "$(j "printf -v X 1; bash scripts/hooks/x*.sh")"
# 4572's own probe shape stays denied by design: the heredoc is written and run
# in one call, so its printf is live code that can feed a shell. The refusal
# now names the trigger.
# shellcheck disable=SC2016 # the $h, $P and $f are probe text, not expansions
assert_deny "4572 a heredoc probe that is then run stays denied" "$(j 'cat > /tmp/hookprobe.sh <<'"'"'EOF'"'"'
h=block-x
f="scripts/hooks/$h.sh"
printf '"'"'%s'"'"' "$P" | timeout 30 bash "$f"
EOF
bash /tmp/hookprobe.sh')"
CASES=$((CASES + 1))
if grep -q "it matched the word printf" <<<"$ERR"; then
    echo "PASS 4572 the probe refusal names its trigger"
else
    echo "FAIL 4572 the probe refusal names its trigger -- got: $ERR"
    FAILED=$((FAILED + 1))
fi
assert_allow "3955 grep -n of a chokepoint file"     "$(j "grep -n deferred scripts/cr/clear-cr-marker.sh")"
assert_allow "3955 grep -i beside a chokepoint word" "$(j "grep -i deferred scripts/cr/clear-cr-marker.sh")"
assert_allow "3955 diff -u beside a chokepoint word" "$(j "diff -u $MERGE_ON_GREEN /tmp/x.sh")"
assert_deny "3955 no relief (glob/quote), main verdict: --long-option VAR=x argument, no chokepoint named" "$(j "bash scripts/cr/ledger-append.sh amend --set ${MOG_VAR}=1 --reason \"scripts/hooks/x?\"")"
# 3955 controls: env position still denies, including beside a plain program word.
assert_deny "3955 env -i, then a globbed kit path"       "$(j "setsid -f env -i bash scripts/handover/console-kit/g*.sh")"
assert_deny "3955 env -i after grep in another segment"  "$(j "grep x f; env -i bash scripts/handover/console-kit/g*.sh")"
assert_deny "3955 env -i in a subshell after grep"       "$(j "grep x \$(env -i bash scripts/handover/console-kit/g*.sh)")"
assert_deny "3955 env with an option beside grep -i"     "$(j "grep -i x f; env -u HIMMEL_CONSOLE_LEG bash $MERGE_ON_GREEN")"
assert_deny "3955 env -i beside a chokepoint word"       "$(j "env -i bash $MERGE_ON_GREEN")"
assert_deny "3955 seam assignment beside a globbed kit path" "$(j "${MOG_VAR}=1 setsid -f bash scripts/handover/console-kit/g*.sh")"
assert_deny "3955 env VAR=x (no long option) then a globbed kit path" "$(j "setsid -f env --ignore-environment ${MOG_VAR}=1 bash scripts/handover/console-kit/g*.sh")"
assert_deny "3955 env option operand then -i (--chdir /tmp -i)" "$(j "/usr/bin/en? --chdir /tmp -i bash scripts/handover/console-kit/g*.sh")"
assert_deny "3955 env option operand then -i beside a chokepoint word" "$(j "/usr/bin/en? --chdir /tmp -i bash $MERGE_ON_GREEN")"
BSNL=$'\\\n'
assert_deny "3955 globbed env, backslash-newline, then -i"   "$(j "/usr/bin/en? ${BSNL}-i bash scripts/handover/console-kit/g*.sh")"
assert_deny "3955 globbed env, backslash-newline, -i beside a chokepoint word" "$(j "/usr/bin/en? ${BSNL}-i bash $MERGE_ON_GREEN")"
assert_deny "3955 env short option operand then -u"    "$(j "/usr/bin/en? -C /tmp -u HIMMEL_CONSOLE_LEG bash scripts/handover/console-kit/g*.sh")"
# Judge round (HIMMEL-4031): a redirection, a $(..)/backtick word, a zsh glob
# group or a split word between the env word and -i must not end env position.
assert_deny "3955 env, 2>/dev/null, -i"   "$(j '/usr/bin/en? 2>/dev/null -i bash scripts/handover/console-kit/go.sh')"
assert_deny "3955 env, 2>&1, -i"          "$(j '/usr/bin/en? 2>&1 -i bash scripts/handover/console-kit/go.sh')"
assert_deny "3955 env, >&2, -u PATH"      "$(j '/usr/bin/en? >&2 -u PATH bash scripts/handover/console-kit/go.sh')"
assert_deny "3955 env, </dev/null, -i"    "$(j '/usr/bin/en? </dev/null -i bash scripts/handover/console-kit/go.sh')"
assert_deny "3955 env, > file (spaced), -i" "$(j '/usr/bin/en? > /tmp/o -i bash scripts/handover/console-kit/go.sh')"
# shellcheck disable=SC2016 # the $( and backtick are the probe text, not expansions
assert_deny "3955 env, \$(true), -i"    "$(j '/usr/bin/en? $(true) -i bash scripts/handover/merge-on-green.sh')"
# shellcheck disable=SC2016 # the backtick is the probe text, not an expansion
assert_deny "3955 env, backticks, -i"   "$(j '/usr/bin/en? `true` -i bash scripts/handover/merge-on-green.sh')"
assert_deny "3955 zsh en(v|x) -i"         "$(j '/usr/bin/en(v|x) -i bash scripts/handover/console-kit/go.sh')"
assert_deny "3955 zsh (env) -i"           "$(j '/usr/bin/(env) -i bash scripts/handover/console-kit/go.sh')"
assert_deny "3955 env name split by backslash-newline" "$(j "/usr/bin/e${BSNL}nv -i bash scripts/handover/console-kit/g*.sh")"
assert_deny "3955 seam arm after 2>/dev/null --debug" "$(j '/usr/bin/en? 2>/dev/null --debug ARMAUTOMERGE=1 bash scripts/h*/m*.sh')"
# The relief also needs a read-only first program (grep diff ls cat ...): other
# env-clearing launchers keep main's anywhere-match deny.
assert_deny "3955 bwrap --unsetenv leg var" "$(j 'bwrap --unsetenv HIMMEL_CONSOLE_LEG --dev-bind / / bash scripts/handover/console-kit/go.sh')"
assert_deny "3955 bwrap --unsetenv seam"    "$(j "bwrap --unsetenv ${MOG_VAR} --dev-bind / / bash $MERGE_ON_GREEN")"
assert_deny "3955 flatpak-spawn --unset-env" "$(j 'flatpak-spawn --unset-env=HIMMEL_CONSOLE_LEG bash scripts/handover/console-kit/go.sh')"
assert_deny "3955 systemd-run --unset-environment" "$(j 'systemd-run --user --unset-environment=HIMMEL_CONSOLE_LEG bash scripts/handover/console-kit/go.sh')"
assert_deny "3955 nix develop -i -c"        "$(j 'nix develop -i -c bash scripts/handover/console-kit/go.sh')"
assert_deny "3955 sudo -i"                  "$(j 'sudo -i bash scripts/handover/console-kit/go.sh')"
assert_deny "3955 su - root -c"             "$(j 'su - root -c scripts/handover/console-kit/go.sh')"
assert_deny "3955 ENV -i (any case)"        "$(j 'ENV -i bash scripts/handover/console-kit/go.sh')"
# A leading assignment can swap the program (PATH) or its behaviour: no relief.
assert_deny "3955 PATH= before grep"        "$(j 'PATH=/attacker/bin grep -i scripts/handover/merge-on-green.sh')"
assert_deny "3955 LD_PRELOAD= before grep"  "$(j 'LD_PRELOAD=/x/y.so grep -i scripts/handover/merge-on-green.sh')"
assert_deny "3955 GREP_OPTIONS= before grep" "$(j 'GREP_OPTIONS=--foo grep -i scripts/handover/merge-on-green.sh')"
# The relief is an ALLOWLIST: only plain unquoted words, no glob, redirection or
# separator. Anything else takes main's plain match.
assert_deny "3955 attached redirection hides the env word" "$(j '/usr/bin/en?>/dev/null -i bash scripts/handover/console-kit/g*.sh')"
assert_deny "3955 quoted operand with a space, then -i" "$(j '/usr/bin/en? --chdir "/tmp/a b" -i bash scripts/handover/console-kit/g*.sh')"
# Substitution shapes fail closed (main's plain match): the relief never runs there.
# shellcheck disable=SC2016 # the $( is probe text, not an expansion
assert_deny "3955 env, \$(true; true), -i" "$(j '/usr/bin/en? $(true; true) -i bash scripts/handover/console-kit/g*.sh')"
# shellcheck disable=SC2016 # the $( is probe text, not an expansion
assert_deny "3955 seam in \$( ) after long option" "$(j 'echo --flag $(ARMAUTOMERGE=1 bash scripts/h*/m*.sh)')"

# HIMMEL-4095: a long option merely STARTING with i or u is not env-clearing.
# The leg N997 shape (unchanged environment) was denied as --impacted = --i*.
assert_allow "4095 quiet-run suite -- run-shell-tests.sh --impacted" "$(j "bash $QR suite -- bash scripts/ci/run-shell-tests.sh --impacted 5b0decc27..HEAD")"
assert_allow "4095 run-shell-tests.sh --impacted (bare)"            "$(j "bash scripts/ci/run-shell-tests.sh --impacted origin/main..HEAD")"
assert_allow "4095 --update beside a chokepoint word"               "$(j "bash $QR suite -- bash scripts/x.sh --update")"
assert_allow "4095 --unsorted / --ignored beside a chokepoint word" "$(j "bash $QR suite -- bash scripts/x.sh --unsorted --ignored")"
# Counter-examples: every env-clearing spelling stays denied, abbreviated,
# attached, quoted or split included (GNU getopt_long accepts any unique prefix).
assert_deny "4095 env --ignore-environment beside quiet-run"      "$(j "env --ignore-environment bash $QR suite -- bash scripts/x.sh")"
assert_deny "4095 env --ignore (abbrev) beside quiet-run"         "$(j "/usr/bin/en? --ignore bash $QR suite -- bash scripts/x.sh")"
assert_deny "4095 env --i (abbrev) beside quiet-run"              "$(j "/usr/bin/en? --i bash $QR suite -- bash scripts/x.sh")"
assert_deny "4095 env --unset=X beside quiet-run"                 "$(j "/usr/bin/en? --unset=HIMMEL_SUITE_SLOTS bash $QR suite -- bash scripts/x.sh")"
assert_deny "4095 env --unset X beside quiet-run"                 "$(j "/usr/bin/en? --unset HIMMEL_SUITE_SLOTS bash $QR suite -- bash scripts/x.sh")"
assert_deny "4095 env --un=X (abbrev) beside quiet-run"           "$(j "/usr/bin/en? --un=HIMMEL_SUITE_SLOTS bash $QR suite -- bash scripts/x.sh")"
assert_deny "4095 env -u X beside quiet-run"                      "$(j "/usr/bin/en? -u HIMMEL_SUITE_SLOTS bash $QR suite -- bash scripts/x.sh")"
assert_deny "4095 env -i beside quiet-run"                        "$(j "/usr/bin/en? -i bash $QR suite -- bash scripts/x.sh")"
assert_deny "4095 env -iu X (combined short) beside quiet-run"    "$(j "/usr/bin/en? -iu HIMMEL_SUITE_SLOTS bash $QR suite -- bash scripts/x.sh")"
assert_deny "4095 env bare - beside quiet-run"                    "$(j "/usr/bin/en? - bash $QR suite -- bash scripts/x.sh")"
assert_deny "4095 --ig\"\"nore-environment (quote split)"         "$(j "/usr/bin/en? --ig\"\"nore-environment bash $QR suite -- bash scripts/x.sh")"
# shellcheck disable=SC2016 # the ${x} is probe text, not an expansion
assert_deny "4095 --ig\${x}nore-environment (var split)"          "$(j '/usr/bin/en? --ig${x}nore-environment bash scripts/quiet-run.sh suite -- bash scripts/x.sh')"
assert_deny "4095 --i* glob beside quiet-run"                     "$(j "/usr/bin/en? --i* bash $QR suite -- bash scripts/x.sh")"
assert_deny "4095 --unsetenv beside quiet-run"                    "$(j "bwrap --unsetenv HIMMEL_SUITE_SLOTS --dev-bind / / bash $QR suite -- bash scripts/x.sh")"
assert_deny "4095 --impacted does not mask a later env -i"        "$(j "bash scripts/ci/run-shell-tests.sh --impacted a..b; /usr/bin/en? -i bash $QR suite -- bash scripts/x.sh")"

# HIMMEL-4130: the worktree dot directory /.claude/worktrees/ is not a
# traversal, so a plain absolute worktree path is not obfuscated.
WT=/home/u/himmel/.claude/worktrees/fix+x
assert_allow "4130 worktree ledger-append amend, exec in a quoted reason" "$(j "bash $WT/scripts/cr/ledger-append.sh amend --id 3 --set verdict=fixed --reason 'the exec line moved'")"
assert_allow "4130 grep beside unset/exec in a .claude worktree path" "$(j "grep -n 'unset exec' $WT/scripts/hooks/x.sh")"
# Only /.claude/worktrees/ is relieved; any other dot directory still counts.
assert_deny "4130 read beside a .git dir path is not relieved"   "$(j "read -r l; cat /r/.git/x/scripts/y.sh")"
assert_deny "4130 a .x dot dir is not relieved"                  "$(j "printf x; bash /r/.x/scripts/y.sh")"
assert_deny "4130 a .a.b dot dir is not relieved"                "$(j "printf x; bash /r/.a.b/scripts/y.sh")"
assert_deny "4130 /.claude/ without worktrees/ is not relieved"  "$(j "printf x; bash /r/.claude/scripts/y.sh")"
# zsh grouping, alternation and glob qualifiers carry no extglob opener, but
# tr splits the word at `(` so it looked plain (judge J1663b NO-GO): any `(`
# in the text turns the relief off.
WT2=/home/u/r/.claude/worktrees/fix+a
assert_deny "4130 zsh grouping g(o).sh + env -u, worktree path"       "$(j "env -u HIMMEL_CONSOLE_LEG $WT2/scripts/handover/console-kit/g(o).sh")"
assert_deny "4130 zsh grouping (go).sh + env -u, worktree path"       "$(j "env -u HIMMEL_CONSOLE_LEG $WT2/scripts/handover/console-kit/(go).sh")"
assert_deny "4130 zsh alternation g(o|zz).sh + env -u, worktree path" "$(j "env -u HIMMEL_CONSOLE_LEG $WT2/scripts/handover/console-kit/g(o|zz).sh")"
assert_deny "4130 zsh glob flag (#i)GO.sh + env -u, worktree path"    "$(j "env -u HIMMEL_CONSOLE_LEG $WT2/scripts/handover/console-kit/(#i)GO.sh")"
assert_deny "4130 zsh grouping m(erge-on-green).sh + seam prefix"     "$(j "${MOG_VAR}=1 bash $WT2/scripts/handover/m(erge-on-green).sh")"
# Every traversal spelling still counts, beside a seam write, with no glob.
assert_deny "4130 scripts/./ beside a write verb"     "$(j "printf x; bash scripts/./x.sh")"
assert_deny "4130 scripts/../ beside a write verb"    "$(j "printf x; bash scripts/../x.sh")"
assert_deny "4130 scripts// beside a write verb"      "$(j "printf x; bash scripts//x.sh")"
assert_deny "4130 scripts/a/../b beside a write verb" "$(j "printf x; bash scripts/a/../b.sh")"
assert_deny "4130 scripts/ trailing /. beside a write verb"  "$(j "printf x; ls scripts/a/.")"
assert_deny "4130 scripts/ trailing /.. beside a write verb" "$(j "printf x; ls scripts/a/..")"
assert_deny "4130 worktree path with a /../ segment"  "$(j "printf x; bash $WT/scripts/a/../x.sh")"
assert_deny "4130 /.claude/../ is a traversal"        "$(j "printf x; bash /r/.claude/../scripts/x.sh")"
assert_deny "4130 /. then a quote can join to /./"    "$(j "printf x; bash scripts/.'/'x.sh")"
assert_deny "4130 /. then a backslash"                "$(j "printf x; bash scripts/.\\/x.sh")"
# shellcheck disable=SC2016 # the $v is probe text, not an expansion
assert_deny "4130 /. then a \$var (empty -> /./)"     "$(j 'printf x; bash scripts/.$v/x.sh')"
assert_deny "4130 /. then a brace"                    "$(j "printf x; bash /r/.{a,}/scripts/x.sh")"
assert_deny "4130 worktree path beside a seam assignment and /./" "$(j "${MOG_VAR}=1 setsid -f bash $WT/scripts/./x.sh")"
# Only a LITERAL dot-directory segment is relieved: an expansion, glob or
# quote inside the segment (before scripts/) can still resolve anywhere.
# shellcheck disable=SC2016 # the $s / ${s} are probe text, not expansions
assert_deny "4130 \${var} inside a dot-dir segment"    "$(j 'printf x; bash /r/.claude${s}/scripts/x.sh')"
# shellcheck disable=SC2016
assert_deny "4130 \$var inside a dot-dir segment"      "$(j 'printf x; bash /r/.claude$s/scripts/x.sh')"
assert_deny "4130 glob inside a dot-dir segment"       "$(j "printf x; bash /r/.c*/scripts/x.sh")"
assert_deny "4130 quote inside a dot-dir segment"      "$(j "printf x; bash /r/.cl'a'ude/scripts/x.sh")"
# shellcheck disable=SC2016
assert_deny "4130 tainted dot-dir before an identical literal one" "$(j 'printf x; bash /.ab$x/.ab/scripts/x.sh')"
# The relief applies only when the whole scripts/ word is otherwise plain
# ([A-Za-z0-9_./-]): an extglob, backslash or quote in the basename was denied
# on main only through the incidental /.claude match (judge J1663 NO-GO).
WP=/r/.claude/worktrees/w/scripts/handover
assert_deny "4130 extglob @() basename + export seam, worktree path" "$(j "shopt -s extglob
export ${MOG_VAR}=1; bash $WP/@(merge-on-green).sh")"
assert_deny "4130 extglob @() basename + seam prefix, worktree path"  "$(j "${MOG_VAR}=1 bash $WP/@(merge-on-green).sh")"
assert_deny "4130 extglob @() basename + env -u, worktree path"       "$(j "env -u HIMMEL_CONSOLE_LEG bash $WP/@(merge-on-green).sh")"
assert_deny "4130 extglob +() basename + export seam, worktree path"  "$(j "export ${MOG_VAR}=1; bash $WP/+(merge-on-green).sh")"
assert_deny "4130 extglob !() basename + export seam, worktree path"  "$(j "export ${MOG_VAR}=1; bash $WP/!(x).sh")"
assert_deny "4130 extglob +() basename under a fix+slug worktree"     "$(j "export ${MOG_VAR}=1; bash $WT/scripts/handover/+(merge-on-green).sh")"
assert_deny "4130 extglob @() split at its paren under a fix+slug worktree" "$(j "${MOG_VAR}=1 bash $WT/scripts/handover/@(merge-on-green).sh")"
# shellcheck disable=SC2016 # ${n} is probe text, not an expansion
assert_deny "4130 backslash basename + split seam name, worktree path" "$(j 'n=ARMAUTO; export "${n}MERGE=1"; bash '"$WP"'/merge-on-gr\een.sh')"
# shellcheck disable=SC2016
assert_deny "4130 dquote basename + split seam name, worktree path"    "$(j 'n=ARMAUTO; export "${n}MERGE=1"; bash '"$WP"'/merge-on-g"r"een.sh')"
# shellcheck disable=SC2016
assert_deny "4130 squote basename + split seam name, worktree path"    "$(j "n=ARMAUTO; export \"\${n}MERGE=1\"; bash $WP/merge-on-g'r'een.sh")"

# HIMMEL-4148: zsh (this station's Bash) globs a grouping / alternation /
# glob-flag basename -- g(o).sh runs go.sh -- but tr split the word at `(`,
# so on a PLAIN path neither the glob scan nor the basename backstop saw it
# (judge J1663b). A `(` after scripts/ in a word now counts as obfuscation.
PP=/r/w/scripts
assert_deny "4148 zsh grouping g(o).sh + env -u, plain path"          "$(j "env -u HIMMEL_CONSOLE_LEG $PP/handover/console-kit/g(o).sh")"
assert_deny "4148 zsh grouping (go).sh + env -u, plain path"          "$(j "env -u HIMMEL_CONSOLE_LEG $PP/handover/console-kit/(go).sh")"
assert_deny "4148 zsh alternation g(o|zz).sh + env -u, plain path"    "$(j "env -u HIMMEL_CONSOLE_LEG $PP/handover/console-kit/g(o|zz).sh")"
assert_deny "4148 zsh glob flag (#i)GO.sh + env -u, plain path"       "$(j "env -u HIMMEL_CONSOLE_LEG $PP/handover/console-kit/(#i)GO.sh")"
assert_deny "4148 zsh grouping go.s(h) + env -u, plain path"          "$(j "env -u HIMMEL_CONSOLE_LEG $PP/handover/console-kit/go.s(h)")"
assert_deny "4148 zsh grouping, relative scripts/ path"               "$(j "env -u HIMMEL_CONSOLE_LEG scripts/handover/console-kit/g(o).sh")"
assert_deny "4148 zsh grouping m(erge-on-green).sh + seam prefix"     "$(j "${MOG_VAR}=1 bash $PP/handover/m(erge-on-green).sh")"
assert_deny "4148 zsh grouping q(uiet-run).sh + seam prefix"          "$(j "HIMMEL_SUITE_SLOTS=9 bash $PP/q(uiet-run).sh suite -- bash x")"
assert_deny "4148 zsh grouping s(top-worker).sh + seam prefix"        "$(j "${SW_VAR}=0 bash $PP/lanes/s(top-worker).sh")"
assert_deny "4148 zsh grouping q(uiet-run).sh + seam prefix, worktree path"  "$(j "HIMMEL_SUITE_SLOTS=9 bash $WT2/scripts/q(uiet-run).sh suite -- bash x")"
assert_deny "4148 zsh grouping s(top-worker).sh + seam prefix, worktree path" "$(j "${SW_VAR}=0 bash $WT2/scripts/lanes/s(top-worker).sh")"
assert_deny "4148 zsh grouping g(o).sh + env -u, /./ dot path"        "$(j "env -u HIMMEL_CONSOLE_LEG /r/w/./scripts/handover/console-kit/g(o).sh")"
# Controls: a `(` with no write verb, or one before scripts/ only, stays allowed.
assert_allow "4148 grouping basename with no seam write"              "$(j "bash $PP/handover/console-kit/g(o).sh 1 abc")"
assert_allow "4148 grep alternation under scripts/ with no write"     "$(j "grep -E 'scripts/(a|b)' notes.txt")"
# shellcheck disable=SC2016 # $(pwd) is probe text, not an expansion
assert_allow "4148 \$(pwd) before scripts/ beside printf"             "$(j 'printf x; bash "$(pwd)/scripts/x.sh"')"

# HIMMEL-4157 (judge J1677): a glob or grouping can hide the scripts/ anchor
# itself, and zsh extendedglob has non-paren operators (# ## ^ ~). Each was
# execution-verified under zsh -c to run go.sh with HIMMEL_CONSOLE_LEG dropped.
# A metachar in ANY segment of a path word now counts, scripts/ or not.
CK=handover/console-kit
UL="env -u HIMMEL_CONSOLE_LEG"
XG="setopt extendedglob; $UL"
for P in /r/w /r/w/. "$WT2" ./x; do
    assert_deny "4157 scr(ipts)/ hides the anchor under $P"     "$(j "$UL $P/scr(ipts)/$CK/g(o).sh")"
    assert_deny "4157 (scripts)/ hides the anchor under $P"     "$(j "$UL $P/(scripts)/$CK/g(o).sh")"
    assert_deny "4157 {scripts,x}/ hides the anchor under $P"   "$(j "$UL $P/{scripts,x}/$CK/g(o).sh")"
    assert_deny "4157 scrip?s/ + g?.sh under $P"                "$(j "$UL $P/scrip?s/$CK/g?.sh")"
    assert_deny "4157 scrip#ts/ (extendedglob) under $P"        "$(j "$XG $P/scrip#ts/$CK/go.sh")"
    assert_deny "4157 extendedglob gg#o.sh under $P"            "$(j "$XG $P/scripts/$CK/gg#o.sh")"
    assert_deny "4157 extendedglob g#o.sh under $P"             "$(j "$XG $P/scripts/$CK/g#o.sh")"
    assert_deny "4157 extendedglob go##.sh under $P"            "$(j "$XG $P/scripts/$CK/go##.sh")"
    assert_deny "4157 extendedglob ^x.sh under $P"              "$(j "$XG $P/scripts/$CK/^x.sh")"
    assert_deny "4157 extendedglob g*~x.sh under $P"            "$(j "$XG $P/scripts/$CK/g*~x.sh")"
done
assert_deny "4157 cd then ./g?.sh (no scripts/ in the word)"   "$(j "cd scripts/$CK; $UL ./g?.sh")"
assert_deny "4157 cd then ./g(o).sh"                           "$(j "cd scripts/$CK; $UL ./g(o).sh")"
for F in "bash g?.sh" "bash g(o).sh" "bash *o.sh" "sh -e {g,x}o.sh" "zsh ^x.sh" \
         "/bin/bash g?.sh" "/usr/bin/zsh g(o).sh" "'bash' g?.sh" "\"sh\" g*.sh"; do
    assert_deny "4157 cd then slash-less glob: $F" "$(j "cd scripts/$CK; $UL $F")"
done
# A long option (--norc, --rcfile X, --restricted, --) before the operand is
# skipped too: only a short cluster holding c runs a command string (J1685).
for F in "bash --norc g?.sh" "bash --rcfile /dev/null g?.sh" "bash --init-file x g?.sh" \
         "bash --restricted g?.sh" "bash --noprofile g?.sh" "bash -- g?.sh" "bash -e --norc g?.sh" \
         "bash --norc ./g?.sh"; do
    assert_deny "4157 cd then long option, slash-less glob: $F" "$(j "cd scripts/$CK; $UL $F")"
done
BP_VAR=$(reg_entry "bank-preflight.sh" | cut -f2 | awk '{print $1}')
QR_VAR=$(reg_entry "quiet-run.sh" | cut -f2 | awk '{print $1}')
assert_deny "4157 J1685: --norc before a stop-worker glob" "$(j "cd scripts/lanes; ${SW_VAR}=0 bash --norc st?p-worker.sh")"
assert_deny "4157 J1685: --norc before a bank-preflight glob" "$(j "cd scripts/lib; ${BP_VAR}=99 bash --norc bank-pre*.sh")"
assert_deny "4157 J1685: --rcfile X before a quiet-run glob" "$(j "cd scripts; ${QR_VAR}=99 bash --rcfile /dev/null qu?et-run.sh")"
assert_allow "4157 -c with a glob command string is not a script operand" "$(j "cd scripts/$CK; $UL sh -c 'g?.sh'")"
assert_allow "4157 --norc on a plain basename" "$(j "export FOO=1; bash --norc go.sh")"
# A quoted option value is still one value (codex-1, round 4).
for F in "bash -o \"errexit\" g?.sh" "bash -o 'errexit' g?.sh" "bash +o \"errexit\" g?.sh" \
         "bash -O \"extglob\" g?.sh" "bash --rcfile '/dev/null x' g?.sh" "bash --init-file \"a b\" g?.sh"; do
    assert_deny "4157 cd then quoted option value, slash-less glob: $F" "$(j "cd scripts/$CK; $UL $F")"
done
assert_allow "4157 quoted -o value on a plain basename" "$(j "export FOO=1; bash -o \"errexit\" go.sh")"
# Each o/O in a short cluster takes its own value (codex-1, round 5).
for F in "bash -eo errexit g?.sh" "bash +eo errexit g?.sh" "bash -Oe extglob g?.sh" "bash -eO extglob g?.sh" \
         "bash -oo errexit nounset g?.sh" "bash -oO errexit extglob g?.sh" "bash -xo 'errexit' g?.sh"; do
    assert_deny "4157 cd then clustered -o value, slash-less glob: $F" "$(j "cd scripts/$CK; $UL $F")"
done
assert_allow "4157 clustered -o value on a plain basename" "$(j "export FOO=1; bash -eo errexit go.sh")"
# CR round 10: an interpreter stage inside $( ) or backticks prints a word the
# shell then globs and runs, so its tokens are scanned (class 1 -> 0).
GP="/r/w/scrip?s/$CK/g?.sh"
for pre in "unset HIMMEL_CONSOLE_LEG;" "$UL"; do
    # shellcheck disable=SC2016 # the $( ) is probe text, not an expansion
    {
    assert_deny "4157 CR10 python3 in \$( ) prints a glob [$pre]"  "$(j "$pre \$(python3 -c 'print(\"$GP\")')")"
    assert_deny "4157 CR10 python3 in backticks prints a glob [$pre]" "$(j "$pre \`python3 -c 'print(\"$GP\")'\`")"
    assert_deny "4157 CR10 perl -e print in \$( ) [$pre]"          "$(j "$pre \$(perl -e 'print \"$GP\"')")"
    assert_deny "4157 CR10 node -e console.log in \$( ) [$pre]"    "$(j "$pre \$(node -e 'console.log(\"$GP\")')")"
    }
done
# CR round 11: ANY stage inside $( ) or backticks can print the glob, so every
# stage there is scanned, not only interpreters (find -printf, awk, git config).
for pre in "unset HIMMEL_CONSOLE_LEG;" "$UL"; do
    # shellcheck disable=SC2016 # the $( ) is probe text, not an expansion
    {
    assert_deny "4157 CR11 find -printf in \$( ) [$pre]"        "$(j "$pre \$(find /r/w -maxdepth 0 -printf '$GP')")"
    assert_deny "4157 CR11 find -printf in backticks [$pre]"    "$(j "$pre \`find /r/w -maxdepth 0 -printf '$GP'\`")"
    assert_deny "4157 CR11 awk BEGIN print in \$( ) [$pre]"     "$(j "$pre \$(awk 'BEGIN{print \"$GP\"}')")"
    assert_deny "4157 CR11 git config arg in \$( ) [$pre]"      "$(j "$pre \$(git config --get x.y '$GP')")"
    assert_deny "4157 CR11 nested \$( ) find -printf [$pre]"    "$(j "$pre \$(echo \$(find /r/w -maxdepth 0 -printf '$GP'))")"
    assert_deny "4157 CR11 \$( ) in double quotes, find [$pre]" "$(j "$pre \"\$(find /r/w -maxdepth 0 -printf '$GP')\"")"
    }
done
# shellcheck disable=SC2016 # the $( ) is probe text, not an expansion
assert_allow "4157 CR11 plain git rev-parse in \$( ) beside the seam name" "$(j 'unset HIMMEL_CONSOLE_LEG; x=$(git rev-parse HEAD); echo $x')"
# shellcheck disable=SC2016 # the $( ) is probe text, not an expansion
assert_allow "4157 CR10 interpreter in \$( ), no glob word, beside the seam name" "$(j 'unset HIMMEL_CONSOLE_LEG; x=$(python3 -c '"'"'print(1)'"'"'); echo $x')"
# J1685d: a glob word that cannot run (an inert reader's argument, a quoted
# rg script) beside a seam name is everyday text, not a hidden anchor. A sed
# or awk script gets no relief (it can run a program; a parse that tells the
# inert ones apart is HIMMEL-3930), so these still deny as on main.
assert_deny "4157 queue-lock sweep piped to a sed regex (HIMMEL-3930)" "$(j "HANDOVER_DIR=/home/u/handovers bash /home/u/himmel/scripts/handover/queue-lock.sh status --sweep /home/u/handovers | sed 's/.*session=//'")"
assert_allow "4157 export seam then ls glob" "$(j 'export HANDOVER_DIR=/tmp/h; ls docs/*.md')"
# shellcheck disable=SC2016 # $HIMMEL_CONSOLE_LEG is probe text, not an expansion
assert_allow "4157 echo the leg marker then ls glob" "$(j 'echo $HIMMEL_CONSOLE_LEG; ls src/*.ts')"
assert_allow "4157 grep the leg marker, grep -v a quoted pattern" "$(j "grep -rn HIMMEL_CONSOLE_LEG docs/ | grep -v '^./docs/'")"
assert_deny "4157 awk program with a path regex (HIMMEL-3930)" "$(j "unset HIMMEL_CONSOLE_LEG; awk '/x\\/(y|z)*/ {print}' f")"
SWEEP="HANDOVER_DIR=/home/u/handovers bash /home/u/himmel/scripts/handover/queue-lock.sh status --sweep /home/u/handovers"
assert_allow "4157 sweep, grep -oE a quoted alternation" "$(j "$SWEEP 2>&1 | grep -oE 'N1(4[89]|5[0-4])[^ ]* session=[^ ]+'")"
assert_deny "4157 sweep, sed -E capture groups (HIMMEL-3930)" "$(j "$SWEEP | sed -E 's/.*(N2[0-9]+).*session=([^ ]*).*/\\1 \\2/'")"
assert_allow "4157 sweep beside an unquoted ls glob" "$(j "ls /tmp/s/N27[67].launch.log; $SWEEP")"
assert_allow "4157 sweep inside a function definition" "$(j "S() { $SWEEP 2>&1; }; S | grep -E 'N27[67]'")"
assert_allow "4157 heredoc prose append beside the sweep" "$(j "cat >> /tmp/h.md <<'EOF'
- ran \`x*.sh\` (gr(ouping)) and \$(y?)
EOF
$SWEEP")"
assert_allow "4157 python reading quoted globs beside a seam" "$(j "unset HIMMEL_CONSOLE_LEG; python3 -c 'print(\"a/*.md\")'")"
assert_allow "4157 bash on a literal script with a backtick message" "$(j "HANDOVER_DIR=/h bash /r/w/scripts/handover/auto-commit.sh \"x: \`N38\` merged (y) a/*\"")"
assert_allow "4157 a log written then grepped beside a shell" "$(j "HANDOVER_DIR=/h bash /r/x.sh > /t/out.log 2>&1; grep -E 'a|b*' /t/out.log")"
assert_allow "4157 find with quoted -name patterns" "$(j "unset HIMMEL_CONSOLE_LEG; find /r -path '*.locks/go*' -iname '*.md'")"
assert_allow "4157 git grep with a quoted alternation" "$(j "unset HIMMEL_CONSOLE_LEG; git grep -n -iE 'a|/home/[a-z]+' -- docs")"
# ... but an inert reader's output that becomes code still counts, as does
# a hidden-anchor word in command position or an unquoted sed/rg operand.
for F in "echo /r/w/scrip?s/$CK/g?.sh | sh" "printf %s /r/w/scrip?s/$CK/g?.sh | env bash" \
         "\$(echo /r/w/scrip?s/$CK/g?.sh)" "\`ls /r/w/scrip?s/$CK/g?.sh\`" "eval \$(echo /r/w/scrip?s/$CK/g?.sh)" \
         "source <(cat /r/w/scrip?s/$CK/g?.sh)" "ls /r/w/scrip?s/$CK/g?.sh | xargs bash" \
         "rg --pre /r/w/scrip?s/$CK/g?.sh x ." "(/r/w/scrip?s/$CK/g?.sh)" "nohup /r/w/scrip?s/$CK/g?.sh" \
         "true && /r/w/scrip?s/$CK/g?.sh" "cat x; FOO=1 /r/w/scr(ipts)/$CK/g(o).sh" \
         "(ls /r/w/scrip?s/$CK/g?.sh) | sh" "{ echo /r/w/scrip?s/$CK/g?.sh; } | sh" \
         "for f in x; do echo /r/w/scrip?s/$CK/g?.sh; done | sh" "ls /r/w/scrip?s/$CK/g?.sh | while read f; do \$f; done" \
         "printf -v c %s /r/w/scrip?s/$CK/g?.sh; \$c" "bash -c '/r/w/scrip?s/$CK/g?.sh'" \
         "echo /r/w/scrip?s/$CK/g?.sh > /t/r.sh; bash /t/r.sh" "echo /r/w/scrip?s/$CK/g?.sh > /t/r.sh; . /t/r.sh" \
         "echo /r/w/scrip?s/$CK/g?.sh > /t/r.sh; chmod +x /t/r.sh; /t/r.sh" \
         "sed 's|^|/r/w/scrip?s/$CK/|;e' f" "awk 'BEGIN{system(\"/r/w/scrip?s/$CK/g?.sh\")}'" \
         "T=\$(ls /r/w/scrip?s/$CK/g?.sh); \$T" "x=\$(echo '/r/w/scrip?s/$CK/g?.sh'); \$x" \
         "cat <<EOF | bash /dev/stdin
/r/w/scrip?s/$CK/g?.sh
EOF" "cat <<EOF | sh
/r/w/scrip?s/$CK/g?.sh
EOF" "python3 -c 'import os; os.system(\"/r/w/scrip?s/$CK/g?.sh\")'" \
         "grep() { bash \"\$@\"; }; grep /r/w/scrip?s/$CK/g?.sh" "PATH=/t:\$PATH; ls /r/w/scrip?s/$CK/g?.sh" \
         "find /r/w -path '/r/w/scrip?s/$CK/g?.sh' -exec sh {} \\;" "/usr/bin/env /r/w/scrip?s/$CK/g?.sh"; do
    assert_deny "4157 inert-reader exemption does not reach: $F" "$(j "$UL true; $F")"
done
# CR round 8 on 730941fe: a file written by a relieved stage and then run
# with no shell word (the redirect scan ran only beside one). A file write
# beside a path command word or an unrelieved one now voids every relief.
assert_deny "4157 written file run directly (CR round 8 verbatim)" "$(j "unset HIMMEL_CONSOLE_LEG; echo /r/w/scrip?s/$CK/g?.sh > /t/run; /t/run")"
WR="echo /r/w/scrip?s/$CK/g?.sh > /t/run"
for F in "$WR; /t/run" "cd /t; $WR; ./run" "$WR; . /t/run" "$WR; source /t/run" "$WR; exec /t/run" \
         "$WR; env /t/run" "$WR; command /t/run" "$WR; nohup /t/run" "$WR; echo /t/run | xargs -I{} {}" \
         "$WR; find /t -name run -exec {} \\;" "echo /r/w/scrip?s/$CK/g?.sh > /usr/local/bin/run; run" \
         "echo /r/w/scrip?s/$CK/g?.sh > /t/a; cp /t/a /t/run; /t/run" \
         "echo /r/w/scrip?s/$CK/g?.sh | tee /t/run; /t/run" \
         "echo /r/w/scrip?s/$CK/g?.sh > /t/a; dd if=/t/a of=/t/run; /t/run"; do
    assert_deny "4157 write-then-execute without a shell word: $F" "$(j "unset HIMMEL_CONSOLE_LEG; $F")"
done
# CR round on 51d82af1: a relief entry that can run a program gets none.
# sed/awk lose relief outright (sed e, awk pipes); git -O and gh alias/config
# name a program; an assignment prefix can name a pager or browser.
for F in "sed 's|.*|/r/w/scrip?s/$CK/g?.sh|e' f" \
         "awk 'BEGIN { c=\"/r/w/scrip?s/$CK/g?.sh\"; print \"\" | c }'" \
         "sed '1e/r/w/scrip?s/$CK/g?.sh' f" "gsed 'e /r/w/scrip?s/$CK/g?.sh' f" \
         "ls x | sed 's|.*|/r/w/scrip?s/$CK/g?.sh|e'" "sed -f /r/w/scrip?s/$CK/g?.sed f" \
         "awk -f /r/w/scrip?s/$CK/g?.awk f" "gawk -l /r/w/scrip?s/$CK/g?.so 'BEGIN{}'" \
         "mawk 'BEGIN{print \"x\" > \"/r/w/scrip?s/$CK/g?.sh\"}'" \
         "git grep -O/r/w/scrip?s/$CK/g?.sh x" "git grep -nO /r/w/scrip?s/$CK/g?.sh x" \
         "git grep --open-files-in-pager=/r/w/scrip?s/$CK/g?.sh x" \
         "git -c core.pager=/r/w/scrip?s/$CK/g?.sh log" \
         "gh alias set x '!/r/w/scrip?s/$CK/g?.sh'" "gh config set pager /r/w/scrip?s/$CK/g?.sh" \
         "GIT_PAGER=/r/w/scrip?s/$CK/g?.sh git log" "PAGER='/r/w/scrip?s/$CK/g?.sh' git show" \
         "GH_BROWSER=/r/w/scrip?s/$CK/g?.sh gh pr view" \
         "test -v 'a[\$(/r/w/scrip?s/$CK/g?.sh)]'" "[ -v 'a[\$(/r/w/scrip?s/$CK/g?.sh)]' ]"; do
    assert_deny "4157 exec-capable relief entry refused: $F" "$(j "unset HIMMEL_CONSOLE_LEG; $F")"
done
# A keyword, precommand, assignment prefix or $( also puts source/. in
# command position (CR on #1685: then source g*.sh).
for F in "source g*.sh" ". g?.sh" "if true; then source g*.sh; fi" "while :; do . g?.sh; done" \
         "if :; then :; else . g?.sh; fi" "{ . g?.sh; }" "! . g?.sh" "x=\$(. g?.sh)" \
         "FOO=1 . g?.sh" "builtin source g*.sh" "command . g?.sh" "eval . g?.sh" "time . g?.sh"; do
    assert_deny "4157 cd then sourced slash-less glob: $F" "$(j "cd scripts/$CK; unset HIMMEL_CONSOLE_LEG; $F")"
done
assert_allow "4157 a prose '. (' is not a sourced glob" "$(j "echo 'unset HIMMEL_CONSOLE_LEG, done . (see x)'")"
assert_allow "4157 bash on a plain basename" "$(j "export FOO=1; bash go.sh")"
# shellcheck disable=SC2016 # $D is probe text, not an expansion
assert_deny "4157 \$D/g*.sh (anchor in a variable)"            "$(j 'D=scripts/handover/console-kit; env -u HIMMEL_CONSOLE_LEG $D/g*.sh')"
assert_deny "4157 m(erge-on-green).sh + seam prefix, hidden anchor" "$(j "${MOG_VAR}=1 bash /r/w/scr(ipts)/handover/m(erge-on-green).sh")"
# Controls: no seam write, or a metachar outside any path word, stays allowed.
# The anchor-less arm: each writer form of a seam NAME, and each env-clearing
# form, denies beside a hidden-anchor path; a READ of the name does not.
HP="bash /r/w/scr(ipts)/handover/m(erge-on-green).sh"
for F in "unset $MOG_VAR" "unset -v $MOG_VAR" "export $MOG_VAR=x" "declare -x $MOG_VAR=1" \
         "mapfile -t $MOG_VAR < f" "read $MOG_VAR < f" "printf -v $MOG_VAR x" "(( $MOG_VAR = 1 ))" \
         ": \${$MOG_VAR:=x}" "for $MOG_VAR in x; do :; done" "n=$MOG_VAR; unset \$n" \
         "n=$MOG_VAR; env -u \$n true" "env -i true" "env - true" "export -n $MOG_VAR" \
         "env --unset=$MOG_VAR true" "n=x; export \"\${n}Y=1\"" "n=x; declare -x \$n=1" \
         "n=x; printf -v \"\$n\" 1"; do
    assert_deny "4157 anchor-less arm: $F" "$(j "$F; $HP")"
done
assert_allow "4157 anchor-less arm: a \$NAME read is not a write" "$(j "echo \$$MOG_VAR; $HP")"
assert_allow "4157 anchor-less arm: a == test is not a write"     "$(j "[[ \$$MOG_VAR == x ]] && $HP")"
assert_allow "4157 anchor-less arm: export X=\$(...) is not a dynamic name" "$(j "export FOO=\$(date); $HP")"
assert_allow "4157 hidden anchor with no seam write"           "$(j "bash /r/w/scr(ipts)/$CK/g(o).sh 1 abc")"
assert_allow "4157 HEAD^ beside export"                        "$(j "export FOO=1; git show HEAD^")"
assert_allow "4157 ~/ home path beside export"                 "$(j "export FOO=1; ls ~/notes")"
assert_allow "4157 a # comment beside export"                  "$(j "export FOO=1 # set foo")"
# HIMMEL-4442 (CR round 13 on #1685): a function shadowing a relief name kept
# relief when spelled `ls ()`, `ls ( )`, with a subshell or compound body, or
# with a newline before the brace; only `ls() {` was caught.
for pre in "unset HIMMEL_CONSOLE_LEG;" "HIMMEL_CONSOLE_LEG=;"; do
    for D in "ls () { bash \"\$@\"; }" "ls ( ) { bash \"\$@\"; }" "ls () ( bash \"\$@\" )" \
             "ls ()
{ bash \"\$@\"; }" "ls () if true; then bash \"\$@\"; fi"; do
        assert_deny "4442 relief name shadowed: $D [$pre]" "$(j "$D; $pre ls $GP")"
    done
    # Judge J1871: zsh defines EVERY name before the parens (`ls foo () {`
    # shadows ls; bash rejects it), and `foo (){` was a DENY on main via `){`.
    for D in "ls foo () { bash \"\$@\"; }" "ls foo (){ bash \"\$@\"; }" \
             "ls foo() { bash \"\$@\"; }" "foo ls () { bash \"\$@\"; }"; do
        assert_deny "4442 J1871 multi-name definition: $D [$pre]" "$(j "$D; $pre ls $GP")"
    done
    # Judge J1871b: zsh defines a function or alias with no parens through its
    # special parameters (`functions[ls]=...` shadows ls); bash has BASH_ALIASES.
    for N in functions dis_functions aliases dis_aliases galiases saliases BASH_ALIASES; do
        for D in "${N}[ls]='bash \"\$@\"; '" "$N=(ls 'bash \"\$@\"')"; do
            assert_deny "4442 J1871b special-parameter definition: $D [$pre]" "$(j "$D; $pre ls $GP")"
        done
    done
    assert_deny "4442 J1871b += definition [$pre]" "$(j "functions[ls]+='bash \"\$@\"; '; $pre ls $GP")"
    assert_deny "4442 J1871b judge input [$pre]" \
        "$(j "functions[ls]='bash \"\$@\"; '; $pre ls /r/w/scrip?s/handover/console-kit/g?.sh")"
    # Judge J1871c: any word naming a shadow table, enable/autoload, or set -A/+A
    # gets no relief, whatever the syntax around it.
    for D in "set -A functions ls 'bash \"\$@\"; '" "set -A dis_functions ls x; enable -f ls" \
             "commands+=( ls /usr/bin/bash )" "set -A commands ls /usr/bin/bash" \
             "set -A aliases ls 'bash \"\$@\"'" "fpath=(/tmp/f \$fpath); functions -u ls" \
             "fpath=(/tmp/f); autoload -U ls" "FPATH=/tmp/f" "enable -f ls" "autoload ls" \
             "set +A x ls" "set -A x ls" "BASH_CMDS[ls]=/usr/bin/bash" "dis_galiases[ls]=x" \
             "dis_saliases[sh]=x" "com''mands+=( ls /usr/bin/bash )" "echo \$functions" \
             "fun''ctions[ls]=x"; do
        assert_deny "4442 J1871c shadow-table word: $D [$pre]" "$(j "$D; $pre ls $GP")"
    done
    assert_deny "4442 J1871c judge input [$pre]" \
        "$(j "functions[ls]=x; $pre ls /r/w/scrip?s/handover/console-kit/g?.sh")"
    assert_allow "4442 control: myfunctions= is not functions= [$pre]" "$(j "myfunctions=1; $pre ls /r/w/docs/*.md")"
    assert_allow "4442 control: mycommands is not commands [$pre]" "$(j "mycommands=1; $pre ls /r/w/docs/*.md")"
    assert_allow "4442 control: a quoted 'functions' is not a word [$pre]" "$(j "$pre ls /r/w/docs/*.md | grep 'functions'")"
    assert_allow "4442 control: commands_x/enabled are other words [$pre]" "$(j "commands_x=1; enabled=1; $pre ls /r/w/docs/*.md")"
    assert_allow "4442 control: relieved ls, no function [$pre]" "$(j "$pre ls /r/w/docs/*.md")"
done

# HIMMEL-4454 (judge J1871 on #1871): a definition built at run time (eval, or
# a here-string / here-doc / process substitution fed to `.` or source) is
# invisible to the text scan above, so it shadowed a relief name and kept relief.
for pre in "unset HIMMEL_CONSOLE_LEG;" "HIMMEL_CONSOLE_LEG=;"; do
    assert_deny "4454 eval-defined shadow [$pre]" "$(j "eval 'ls () { bash \"\$@\"; }'; $pre ls $GP")"
    assert_deny "4454 eval with a \$var body [$pre]" "$(j "d='ls () { bash \"\$@\"; }'; eval \"\$d\"; $pre ls $GP")"
    assert_deny "4454 . /dev/stdin here-string [$pre]" "$(j ". /dev/stdin <<<'ls () { bash \"\$@\"; }'; $pre ls $GP")"
    assert_deny "4454 source /dev/stdin here-string [$pre]" "$(j "source /dev/stdin <<<'ls () { bash \"\$@\"; }'; $pre ls $GP")"
    assert_deny "4454 source process substitution [$pre]" "$(j "source <(echo 'ls () { bash \"\$@\"; }'); $pre ls $GP")"
    assert_deny "4454 . /dev/stdin here-doc [$pre]" "$(j ". /dev/stdin <<'EOT'
ls () { bash \"\$@\"; }
EOT
$pre ls $GP")"
    assert_deny "4454 source /dev/fd/0 here-string [$pre]" "$(j "source /dev/fd/0 <<<'ls () { bash \"\$@\"; }'; $pre ls $GP")"
    assert_deny "4454 . /dev/stdin after a keyword [$pre]" "$(j "if true; then . /dev/stdin <<<'ls () { bash \"\$@\"; }'; fi; $pre ls $GP")"
    assert_deny "4454 negated eval [$pre]" "$(j "! eval 'ls () { bash \"\$@\"; }'; $pre ls $GP")"
    assert_deny "4454 coproc eval [$pre]" "$(j "coproc eval 'ls () { bash \"\$@\"; }'; $pre ls $GP")"
    assert_deny "4454 negated . /dev/stdin [$pre]" "$(j "! . /dev/stdin <<<'ls () { bash \"\$@\"; }'; $pre ls $GP")"
    assert_deny "4454 source a plain file [$pre]" "$(j "source /tmp/shadow.sh; $pre ls $GP")"
    assert_deny "4454 . a plain file [$pre]" "$(j ". /tmp/shadow.sh; $pre ls $GP")"
    assert_allow "4454 control: a quoted 'eval' is not a word [$pre]" "$(j "$pre ls /r/w/docs/*.md | grep 'eval'")"
    assert_allow "4454 control: evaluate/medieval are other words [$pre]" "$(j "evaluate=1; medieval=1; $pre ls /r/w/docs/*.md")"
done

# HIMMEL-4454 (judge j2236a NO-GO): the run-time definers must be refused in ANY
# command position (after if/while/until/case arms, assignment and redirect
# prefixes, precommand options), however the command word is spelled (quoted,
# escaped, expanded), and through the other run-time hooks (trap DEBUG/ERR/
# ZERR/RETURN, mapfile/readarray -C, zsh emulate -c). Each was run under bash
# and zsh and defined the shadow.
# shellcheck disable=SC2016 # SH is probe text, not an expansion
SH='ls () { bash "$@"; }'
for pre in "unset HIMMEL_CONSOLE_LEG;" "HIMMEL_CONSOLE_LEG=;"; do
    while IFS= read -r form; do
        [ -n "$form" ] || continue
        assert_deny "4454b $form [$pre]" "$(j "${form//@@/$SH}; $pre ls $GP")"
    done <<'FORMS'
if eval '@@'; then :; fi
while eval '@@'; do break; done
until eval '@@'; do break; done
case x in x) eval '@@';; esac
a=1 eval '@@'
</dev/null eval '@@'
2>/dev/null eval '@@'
time -p eval '@@'
command -p eval '@@'
builtin -- eval '@@'
repeat 1 eval '@@'
if . /dev/stdin <<<'@@'; then :; fi
a=1 . /dev/stdin <<<'@@'
</dev/null . /dev/stdin <<<'@@'
command -p . /dev/stdin <<<'@@'
case x in x) . /dev/stdin <<<'@@';; esac
\eval '@@'
"eval" '@@'
$'eval' '@@'
ev\al '@@'
"e"val '@@'
${x:-eval} '@@'
x=eval; $x '@@'
y=al; ev${y} '@@'
{,eval} '@@'
"." /dev/stdin <<<'@@'
'.' /dev/stdin <<<'@@'
\. /dev/stdin <<<'@@'
$'.' /dev/stdin <<<'@@'
${x:-.} /dev/stdin <<<'@@'
"source" /dev/stdin <<<'@@'
so\urce /dev/stdin <<<'@@'
trap '@@' DEBUG
trap '@@' ERR
trap '@@' ZERR
trap '@@' RETURN
mapfile -C '@@' -c 1 a </dev/null
readarray -C '@@' -c 1 a </dev/null
emulate zsh -c '@@'
0<&0 ev\al '@@'
2>&1 ev\al '@@'
>&/dev/null ev\al '@@'
&>/dev/null ev\al '@@'
<&- ev\al '@@'
>&2 . /dev/stdin <<<'@@'
if [[ -n x ]] then "eval" '@@'; fi
if [[ -n x ]] then $'.' /dev/stdin <<<'@@'; fi
while [[ -n x ]] do \eval '@@'; break; done
until [[ -z x ]] do ev\al '@@'; break; done
if [[ -n x ]] then trap '@@' DEBUG; :; fi
coproc N { \eval '@@'; }
coproc N { "eval" '@@'; }
coproc N { $'.' /dev/stdin <<<'@@'; }
if [[ -n x ]] eval '@@'
if [[ -n x ]] { \eval '@@' }
while [[ -n x ]] { \eval '@@'; break }
until [[ -z x ]] { \eval '@@'; break }
{ :; } always { \eval '@@'; }
if [[ -n x ]] then . /dev/stdin <<<'@@'; fi
elif [[ -n x ]] { \eval '@@' }
if (( 1 )) then \eval '@@'; fi
for i in 1; do \eval '@@'; done
select i in 1; do \eval '@@'; break; done
foreach i (1) \eval '@@' end
f() { \eval '@@'; }
function f { \eval '@@'; }
! \eval '@@'
d="$(true)" $(echo eval) '@@'
d="$(true)" \eval '@@'
"$(echo eval)" '@@'
d="$(true)" "eval" '@@'
d="$(true)" "$(echo eval)" '@@'
echo "$(true)" ; d="$(true)" ev\al '@@'
FORMS
    assert_allow "4454b control: quoted command substitution assigned [$pre]" "$(j "d=\"\$(git rev-parse --show-toplevel)\"; $pre ls /r/w/docs/*.md")"
    assert_allow "4454b control: quoted wc substitution assigned [$pre]" "$(j "n=\"\$(wc -l < a)\"; $pre ls /r/w/docs/*.md")"
    assert_allow "4454b control: two quoted substitutions as arguments [$pre]" "$(j "echo \"\$(date)\" \"\$(pwd)\"; $pre ls /r/w/docs/*.md")"
    assert_allow "4454b control: trap on EXIT is not a run-time definer [$pre]" "$(j "trap 'echo bye' EXIT; $pre ls /r/w/docs/*.md")"
    assert_allow "4454b control: mapfile without -C [$pre]" "$(j "mapfile -t a </dev/null; $pre ls /r/w/docs/*.md")"
    # Judge j2236f: the whole ALLOW set of the j2236c forms (81 distinct forms), pinned so
    # it is reviewable in the diff. env, nice and nohup execvp() their operand, and eval,
    # source, ., trap, mapfile, readarray and emulate are shell builtins with no executable
    # on PATH, so none of these runs the quoted text and the shadow is never defined.
    while IFS= read -r form; do
        [ -n "$form" ] || continue
        assert_allow "4454b wrapper-exec ALLOW set $form [$pre]" "$(j "${form//@@/$SH}; $pre ls $GP")"
    done <<'FORMS'
env "." /dev/stdin <<<'@@'
env "e"val '@@'
env "eval" '@@'
env "source" /dev/stdin <<<'@@'
env $'.' /dev/stdin <<<'@@'
env $'eval' '@@'
env ${x:-.} /dev/stdin <<<'@@'
env ${x:-eval} '@@'
env '.' /dev/stdin <<<'@@'
env . /dev/stdin <<<'@@'
env \. /dev/stdin <<<'@@'
env \eval '@@'
env e''val '@@'
env emulate sh -c '@@'
env emulate zsh -c '@@'
env ev\al '@@'
env eval '@@'
env mapfile -C '@@' -c 1 a <<<x
env readarray -C '@@' -c 1 a <<<x
env so\urce /dev/stdin <<<'@@'
env trap '@@' DEBUG; :
env trap '@@' ERR; false
env trap '@@' ZERR; false
env {,eval} '@@'
nice "." /dev/stdin <<<'@@'
nice "e"val '@@'
nice "eval" '@@'
nice "source" /dev/stdin <<<'@@'
nice $'.' /dev/stdin <<<'@@'
nice $'eval' '@@'
nice ${x:-.} /dev/stdin <<<'@@'
nice ${x:-eval} '@@'
nice '.' /dev/stdin <<<'@@'
nice . /dev/stdin <<<'@@'
nice \. /dev/stdin <<<'@@'
nice \eval '@@'
nice e''val '@@'
nice emulate sh -c '@@'
nice emulate zsh -c '@@'
nice ev\al '@@'
nice eval '@@'
nice mapfile -C '@@' -c 1 a <<<x
nice readarray -C '@@' -c 1 a <<<x
nice so\urce /dev/stdin <<<'@@'
nice trap '@@' DEBUG; :
nice trap '@@' ERR; false
nice trap '@@' ZERR; false
nice {,eval} '@@'
nohup "." /dev/stdin <<<'@@'
nohup "e"val '@@'
nohup "eval" '@@'
nohup "source" /dev/stdin <<<'@@'
nohup $'.' /dev/stdin <<<'@@'
nohup $'eval' '@@'
nohup ${x:-.} /dev/stdin <<<'@@'
nohup ${x:-eval} '@@'
nohup '.' /dev/stdin <<<'@@'
nohup . /dev/stdin <<<'@@'
nohup \. /dev/stdin <<<'@@'
nohup \eval '@@'
nohup e''val '@@'
nohup emulate sh -c '@@'
nohup emulate zsh -c '@@'
nohup ev\al '@@'
nohup eval '@@'
nohup mapfile -C '@@' -c 1 a <<<x
nohup readarray -C '@@' -c 1 a <<<x
nohup so\urce /dev/stdin <<<'@@'
nohup trap '@@' DEBUG; :
nohup trap '@@' ERR; false
nohup trap '@@' ZERR; false
nohup {,eval} '@@'
x=.; env $x /dev/stdin <<<'@@'
x=.; nice $x /dev/stdin <<<'@@'
x=.; nohup $x /dev/stdin <<<'@@'
x=eval; env $x '@@'
x=eval; nice $x '@@'
x=eval; nohup $x '@@'
y=al; env ev${y} '@@'
y=al; nice ev${y} '@@'
y=al; nohup ev${y} '@@'
FORMS
done

# HIMMEL-4157 (judge J1685 NO-GO): the relief pass was super-linear -- per
# redirect it walked every stage, forking per token expansion. 200 redirects
# took 13 s against a 15 s hook budget; a 10 KB line of quoted stages 5 s.
# A hook timeout fails CLOSED inside the hook chain, so a slow allow shows up
# as an over-deny. Same verdicts, in
# time (EPOCHREALTIME is bash 5+). The 10 KB row times the relief alone: the
# same text without the seam name never reaches it, and the rest of the
# hook costs over a second on that text on main too.
rep_text() {  # rep_text <text> <count> -> <text> repeated <count> times
    local i=0 out=''
    while [ "$i" -lt "$2" ]; do out="$out$1"; i=$((i + 1)); done
    printf '%s' "$out"
}
if [ -n "${EPOCHREALTIME:-}" ]; then
    T0=${EPOCHREALTIME/[.,]/}
    run "$(j "HIMMEL_CONSOLE_LEG=1; ls a/*.sh; $(rep_text 'echo x >f; ' 200)")"
    T1=${EPOCHREALTIME/[.,]/}
    CASES=$((CASES + 1))
    if [ "$RC" = "0" ] && [ $((T1 - T0)) -lt 1000000 ]; then
        echo "PASS 4157 J1685: 200 redirects beside a seam name finish in $(((T1 - T0) / 1000)) ms"
    else
        echo "FAIL 4157 J1685: 200 redirects beside a seam name -- expected rc=0 under 1000 ms, got rc=$RC in $(((T1 - T0) / 1000)) ms"
        FAILED=$((FAILED + 1))
    fi
    P1K=$(rep_text "echo 'a'; " 1000)
    T0=${EPOCHREALTIME/[.,]/}
    run "$(j "FOO=1; ls a/*.sh; $P1K")"
    T1=${EPOCHREALTIME/[.,]/}
    run "$(j "HIMMEL_CONSOLE_LEG=1; ls a/*.sh; $P1K")"
    T2=${EPOCHREALTIME/[.,]/}
    CASES=$((CASES + 1))
    # Bound 2500 ms relief: loaded x4 max 287 ms (x2 = 574), but CI shard 4 read 1063 ms on a slower runner, so x2 of that, rounded; pre-rework 631b80f2 took 3660-5374 ms, still red.
    if [ "$RC" = "0" ] && [ $((T2 - T1 - (T1 - T0))) -lt 2500000 ]; then
        echo "PASS 4157 J1685: 10 KB of quoted stages beside a seam name, relief in $(((T2 - T1 - (T1 - T0)) / 1000)) ms (total $(((T2 - T1) / 1000)) ms)"
    else
        echo "FAIL 4157 J1685: 10 KB of quoted stages beside a seam name -- expected rc=0 with relief under 2500 ms, got rc=$RC, relief $(((T2 - T1 - (T1 - T0)) / 1000)) ms (total $(((T2 - T1) / 1000)) ms)"
        FAILED=$((FAILED + 1))
    fi
    # HIMMEL-4447: an all-digit redirect target ('1') made pobf_exp walk every
    # token index per redirect -- redirects x tokens. ~19.5 KB of them: base
    # grows quadratically and head close to linearly, so at this size the two
    # stay apart on a CI-speed runner too (12 KB did not).
    R20K=$(rep_text "echo x >'1'; " 1500)
    T0=${EPOCHREALTIME/[.,]/}
    run "$(j "FOO=1; ls a/*.sh; $R20K")"
    T1=${EPOCHREALTIME/[.,]/}
    run "$(j "HIMMEL_CONSOLE_LEG=1; ls a/*.sh; $R20K")"
    T2=${EPOCHREALTIME/[.,]/}
    CASES=$((CASES + 1))
    # Bound 8500 ms relief: local alone 1139-1198 ms, 3 concurrent max 1234 ms; CI shard 5 ran this row 3.4x local (1973 vs 582 ms at 12 KB), so 1234 x 3.4 x 2 = 8392, rounded. Base 4579fc21 took 12655 ms locally (12 KB: 3875), still red.
    if [ "$RC" = "0" ] && [ $((T2 - T1 - (T1 - T0))) -lt 8500000 ]; then
        echo "PASS 4447: 19.5 KB of digit-token redirects beside a seam name, relief in $(((T2 - T1 - (T1 - T0)) / 1000)) ms (total $(((T2 - T1) / 1000)) ms)"
    else
        echo "FAIL 4447: 19.5 KB of digit-token redirects beside a seam name -- expected rc=0 with relief under 8500 ms, got rc=$RC, relief $(((T2 - T1 - (T1 - T0)) / 1000)) ms (total $(((T2 - T1) / 1000)) ms)"
        FAILED=$((FAILED + 1))
    fi
    # HIMMEL-4192: quote-heavy 1.3 KB and 4 KB heredocs timed out the guard
    # chain in practice. Alone this hook takes 0.5 s (1.3 KB) and 1.4 s (4 KB)
    # on the worst shape ($(...) and quotes), so a 6 s bound is the 4 KB figure
    # x4 for fleet load, still far under the 15 s hook budget.
    # shellcheck disable=SC2016 # literal $ and ` bytes are the payload
    QH_UNIT='it'\''s "q" `x` $(y '\''z'\'') ${w} "$(d)" (a) '
    for sz in 1300 4000; do
        QH_BODY=$(rep_text "$QH_UNIT" $((sz / ${#QH_UNIT} + 1)))
        T0=${EPOCHREALTIME/[.,]/}
        run "$(j "cat > /tmp/n.md <<'EOF'
$QH_BODY
EOF")"
        T1=${EPOCHREALTIME/[.,]/}
        CASES=$((CASES + 1))
        if [ "$RC" = "0" ] && [ $((T1 - T0)) -lt 6000000 ]; then
            echo "PASS 4192: quote-heavy $sz-byte heredoc allowed in $(((T1 - T0) / 1000)) ms"
        else
            echo "FAIL 4192: quote-heavy $sz-byte heredoc -- expected rc=0 under 6000 ms, got rc=$RC in $(((T1 - T0) / 1000)) ms"
            FAILED=$((FAILED + 1))
        fi
    done
else
    echo "WARN 4157 J1685 timing rows skipped: no EPOCHREALTIME (bash < 5)"
fi
# A lone trailing backslash looped the relief pass forever (a hook timeout,
# which fails open); it now gets no relief.
if command -v timeout >/dev/null 2>&1; then
    CASES=$((CASES + 1))
    # shellcheck disable=SC1003 # the payload ends in a literal backslash
    printf '%s' "$(j 'HIMMEL_CONSOLE_LEG=1; ls a/*.sh; echo a\')" \
        | env -u ENV_PREFIX_GUARD_OK -u CHOKEPOINT_REGISTRY timeout 10 bash "$HOOK" >/dev/null 2>&1
    RC=$?
    if [ "$RC" = "2" ]; then
        echo "PASS 4157 trailing backslash beside a seam name denies (no loop)"
    else
        echo "FAIL 4157 trailing backslash beside a seam name -- expected rc=2, got rc=$RC (124 = looped)"
        FAILED=$((FAILED + 1))
    fi
else
    echo "WARN 4157 trailing-backslash row skipped: no timeout(1)"
fi

# HIMMEL-4130 (HIMMEL-3986 sweep): a PRESENT non-string .command must not
# fall through to .cmd -- `//` treats false like null, so the hook judged
# the benign .cmd text. A non-string .command now fails closed; a null or
# absent one still falls back to .cmd.
jc() { printf '{"tool_name":"Bash","tool_input":{"command":%s,"cmd":%s}}' "$1" "$(printf '%s' "$2" | jq -Rs .)"; }
assert_deny  "4130 command:false with a benign cmd fails closed"  "$(jc false 'echo ok')"
assert_deny  "4130 command:0 with a benign cmd fails closed"      "$(jc 0 'echo ok')"
assert_deny  "4130 command:[...] fails closed"                    "$(jc '["echo ok"]' 'echo ok')"
assert_deny  "4130 command:{} fails closed"                       "$(jc '{}' 'echo ok')"
assert_deny  "4130 command:null falls back to a seam-prefixed cmd" "$(jc null "${MOG_VAR}=1 bash $MERGE_ON_GREEN")"
assert_allow "4130 command:null falls back to a benign cmd"       "$(jc null 'echo ok')"
assert_allow "4130 string command wins over a seam-prefixed cmd"  "$(jc '"echo ok"' "${MOG_VAR}=1 bash $MERGE_ON_GREEN")"
# A CRLF-emitting jq (Git Bash) must not turn the non-string flag `x` into
# `x\r` and fall through to the benign .cmd (judge J1663 note 1).
CRLF_JQ_DIR=$(mktemp -d) || { echo "FAIL: mktemp for the CRLF jq shim" >&2; exit 1; }
REAL_JQ=$(command -v jq)
printf '#!/bin/bash\n"%s" "$@" | sed "s/\\$/\\r/"\n' "$REAL_JQ" >"$CRLF_JQ_DIR/jq"
chmod +x "$CRLF_JQ_DIR/jq"
assert_allow "4130 CRLF jq: string command still allowed (shim control)" "$(jc '"echo ok"' 'echo ok')" "PATH=$CRLF_JQ_DIR:$PATH"
assert_deny  "4130 CRLF jq: command:false still fails closed"            "$(jc false 'echo ok')" "PATH=$CRLF_JQ_DIR:$PATH"
rm -rf "$CRLF_JQ_DIR"

# --- HIMMEL-4399: assignment-only segments made UNSET_NAMES append itself
# (scan_segment's names already carried the inherited UNSET_NAMES), so it
# doubled per segment and `a=;` x 30 pinned a CPU for hours. The list is now
# deduped and capped at 256 distinct names; past the cap the hook DENIES.
# Every row here runs the hook under a CPU ceiling where prlimit exists, so a
# regression shows up as a kill, never a hang. ---
NL=$'\n'
if command -v prlimit >/dev/null 2>&1; then HOOK_WRAP='nice -n 10 prlimit --cpu=10'; fi
rep() {  # rep <text> <count> -> <text> repeated <count> times
    local i=0 out=''
    while [ "$i" -lt "$2" ]; do out="$out$1"; i=$((i + 1)); done
    printf '%s' "$out"
}
distinct_asg() {  # distinct_asg <count> -> "v1=; v2=; ... v<count>=; "
    local i=1 out=''
    while [ "$i" -le "$1" ]; do out="${out}v$i=; "; i=$((i + 1)); done
    printf '%s' "$out"
}
assert_allow "4399 a=; x 30 finishes and stays allowed"                 "$(j "$(rep 'a=;' 30)")"
assert_allow "4399 A=1 x 40 newline-joined finishes and stays allowed"  "$(j "echo ok$(rep "${NL}A=1" 40)")"
HD="cat > cases.txt <<'EOF'$(rep "${NL}LD_PRELOAD=/x.so${NL}GCONV_PATH=/x${NL}NODE_PATH=/x${NL}a=1" 8)
EOF
echo ok"
assert_allow "4399 heredoc of 32 NAME=value lines finishes and stays allowed" "$(j "$HD")"
assert_deny  "4399 a=; x 30 then a seam assignment still denies"        "$(j "$(rep 'a=;' 30) HIMMEL_CONSOLE_LEG=0; bash $MERGE_ON_GREEN 1")"
assert_deny  "4399 unset SEAM; A=1; B=2; then the chokepoint still denies" "$(j "unset HIMMEL_CONSOLE_LEG; A=1; B=2; bash $MERGE_ON_GREEN 1")"
assert_deny  "4399 SEAM=0; then 30 assignment-only segments; then the chokepoint" "$(j "HIMMEL_CONSOLE_LEG=0; $(rep 'a=;' 30) bash $MERGE_ON_GREEN 1")"
assert_allow "4399 256 distinct assignment names (at the cap) stay allowed" "$(j "$(distinct_asg 256)echo ok")"
# Past the cap: fail closed with the cap's own reason.
run "$(j "$(distinct_asg 257)echo ok")"
CASES=$((CASES + 1))
if [ "$RC" = "2" ] && [ "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" = "deny" ] \
   && grep -q "more than 256 distinct" <<<"$ERR"; then
    echo "PASS 4399 257 distinct assignment names deny (cap fails closed)"
else
    echo "FAIL 4399 257 distinct assignment names -- expected rc=2 + deny + cap reason, got rc=$RC"
    FAILED=$((FAILED + 1))
fi
# Timing: 200 assignment-only segments in under 1 s (EPOCHREALTIME is bash 5+).
if [ -n "${EPOCHREALTIME:-}" ]; then
    T0=${EPOCHREALTIME/[.,]/}
    run "$(j "$(rep 'a=;' 200)")"
    T1=${EPOCHREALTIME/[.,]/}
    CASES=$((CASES + 1))
    if [ "$RC" = "0" ] && [ $((T1 - T0)) -lt 1000000 ]; then
        echo "PASS 4399 a=; x 200 finishes in $(((T1 - T0) / 1000)) ms"
    else
        echo "FAIL 4399 a=; x 200 -- expected rc=0 under 1000 ms, got rc=$RC in $(((T1 - T0) / 1000)) ms"
        FAILED=$((FAILED + 1))
    fi
else
    echo "WARN 4399 timing row skipped: no EPOCHREALTIME (bash < 5)"
fi

# --- HIMMEL-4529 / HIMMEL-4414: linear time. arith_body rescanned to EOF per
# unclosed `((` (1500 openers = 40 s, past the chain window, so a big command
# timed out the guard) and unset_add re-split the whole list on every add.
# Timing rows: allow + rc=0 under a stated bound; the deny rows pin that the
# linear scan decides exactly like the old one. The nice/prlimit wrapper above
# turns a regression into a kill, never a hang. ---
timed_row() {  # timed_row <label> <json> <expect rc> <bound ms>
    local T0 T1 ms
    T0=${EPOCHREALTIME/[.,]/}
    run "$2"
    T1=${EPOCHREALTIME/[.,]/}
    ms=$(((T1 - T0) / 1000))
    CASES=$((CASES + 1))
    if [ "$RC" = "$3" ] && [ "$ms" -lt "$4" ]; then
        echo "PASS $1 rc=$RC in $ms ms (bound $4 ms)"
    else
        echo "FAIL $1 -- expected rc=$3 under $4 ms, got rc=$RC in $ms ms"
        FAILED=$((FAILED + 1))
    fi
}
# shellcheck disable=SC2016 # '$((' is the literal text under test, not an expansion
if [ -n "${EPOCHREALTIME:-}" ]; then
    timed_row "4529 echo + (( x1500 (unclosed) finishes"      "$(j "echo $(rep '((' 1500)")" 0 3000
    timed_row "4529 echo + \$(( x1000 (unclosed) finishes"    "$(j "echo $(rep '$((' 1000)")" 0 3000
    timed_row "4529 echo \"\$(( x1000 (unclosed, quoted) finishes" "$(j "echo \"$(rep '$((' 1000)")" 0 3000
    timed_row "4414 256 distinct assignment names finish"     "$(j "$(distinct_asg 256)echo ok")" 0 2000
    timed_row "4414 257 distinct assignment names deny fast"  "$(j "$(distinct_asg 257)echo ok")" 2 2000
else
    echo "WARN 4529/4414 timing rows skipped: no EPOCHREALTIME (bash < 5)"
fi
# UNSET_COUNT is restored with UNSET_NAMES when a subshell closes: 200 names in
# a subshell, then 200 different ones outside, never stand at once (<= 256).
SUBQ=$(distinct_asg 200)
OUTQ=$(distinct_asg 200 | sed 's/v\([0-9]*\)=/w\1=/g')
assert_allow "4414 200 names in a subshell then 200 outside: count restored, allowed" "$(j "( $SUBQ); ${OUTQ}echo ok")"
run "$(j "( $(distinct_asg 257)); echo ok")"
CASES=$((CASES + 1))
if [ "$RC" = "2" ] && grep -q "more than 256 distinct" <<<"$ERR"; then
    echo "PASS 4414 257 names inside one subshell still deny at the cap"
else
    echo "FAIL 4414 257 names inside one subshell -- expected rc=2 + cap reason, got rc=$RC"
    FAILED=$((FAILED + 1))
fi
assert_deny  "4529 unclosed ((, then a closed \$(( )) seam assignment, still denies" "$(j "echo (( x; bash $MERGE_ON_GREEN \$(( HIMMEL_CONSOLE_LEG = 0 ))")"
assert_allow "4529 balanced (( )) comparison stays allowed after unclosed openers" "$(j "echo (( x; (( HIMMEL_CONSOLE_LEG == 0 )); echo ok")"
HOOK_WRAP=''

# --- HIMMEL-4729 (judge j2299a): a Unicode space is a word separator once IFS
# is set to it, so `export<U+3000>-n<U+3000>NAME` really un-exports NAME. The
# class regexes must run in the CALLER's UTF-8 locale ([[:space:]] matches
# U+3000 there, not under C); only raw_mention's ASCII strip steps run under C.
# The fixtures need a UTF-8 locale to mean anything, so no locale = a SKIP line,
# never a vacuous pass.
U8_LOCALES=$(locale -a 2>/dev/null)
U8=''
for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    if grep -qx -- "$l" <<<"$U8_LOCALES"; then U8=$l; break; fi
done
if [ -n "$U8" ]; then
    SP3=$(printf '\343\200\200')
    export LC_ALL="$U8"
    assert_deny "4729 U+3000 IFS: export -n of the console marker, then the chokepoint" "$(j "IFS='${SP3}'; c='export${SP3}-n${SP3}HIMMEL_CONSOLE_LEG'; \$c; bash $STOP_WORKER --list")"
    assert_deny "4729 U+3000 IFS: declare +x of a seam, then the chokepoint"            "$(j "IFS='${SP3}'; c='declare${SP3}+x${SP3}${MOG_VAR}'; \$c; bash $MERGE_ON_GREEN 1")"
    assert_deny "4729 U+3000 IFS: exec -c with the chokepoint"                          "$(j "IFS='${SP3}'; c='exec${SP3}-c${SP3}bash $STOP_WORKER --list'; \$c")"
    unset LC_ALL
else
    echo "SKIP 4729 U+3000 IFS rows: no UTF-8 locale installed (tried C.UTF-8, C.utf8, en_US.UTF-8, en_US.utf8)"
fi

# --- HIMMEL-5152 (judge j2299b): bash splits on ANY IFS character, not only
# iswspace ones, so an IFS of U+00A0 / U+0085 / U+200B / U+FEFF or the ANSI-C
# tab form un-exports a seam the text layer cannot see. Any IFS assignment
# beside a chokepoint word denies. Run under C so no locale helps the match.
export LC_ALL=C
for hex in '\0302\0240:U+00A0' '\0302\0205:U+0085' '\0342\0200\0213:U+200B' '\0357\0273\0277:U+FEFF'; do
    SPX=$(printf '%b' "${hex%%:*}")
    assert_deny "5152 ${hex##*:} IFS: export -n of the console marker, then the chokepoint" "$(j "IFS='${SPX}'; c='export${SPX}-n${SPX}HIMMEL_CONSOLE_LEG'; \$c; bash $STOP_WORKER --list")"
done
assert_deny "5152 ANSI-C tab IFS: export -n of the console marker, then the chokepoint" "$(j "IFS=\$'\\t'; c=\$'export\\t-n\\tHIMMEL_CONSOLE_LEG'; \$c; bash $STOP_WORKER --list")"
assert_deny "5152 IFS+= append beside a chokepoint word"                                "$(j "IFS+=x; bash $MERGE_ON_GREEN 1")"
assert_deny "5152 IFS= built from quoted fragments beside a chokepoint word"             "$(j "I'F'S=x; bash $MERGE_ON_GREEN 1")"
assert_allow "5152 IFS assignment with no chokepoint word stays allowed"                  "$(j "IFS=: read -r a b <<< 'x:y'; echo \$a")"

# --- HIMMEL-5153: matching must not depend on the ambient locale. Under C/POSIX
# [[:space:]] misses U+3000 and the other Unicode spaces (16 of 36 rows passed).
# Unicode spaces map to ASCII before matching, so C and UTF-8 agree.
for hex in '\0343\0200\0200:U+3000' '\0302\0240:U+00A0' '\0342\0200\0203:U+2003' '\0341\0232\0200:U+1680' '\0342\0200\0250:U+2028' '\0302\0205:U+0085'; do
    SPX=$(printf '%b' "${hex%%:*}")
    assert_deny "5153 C locale ${hex##*:}: export -n with a literal separator" "$(j "export${SPX}-n${SPX}HIMMEL_CONSOLE_LEG; bash $STOP_WORKER --list")"
    assert_deny "5153 C locale ${hex##*:}: env -i with a literal separator"    "$(j "env${SPX}-i${SPX}bash $STOP_WORKER --list")"
    assert_deny "5153 C locale ${hex##*:}: declare +x with a literal separator" "$(j "declare${SPX}+x${SPX}${MOG_VAR}; bash $MERGE_ON_GREEN 1")"
done
unset LC_ALL

CASES=$((CASES + 1))
if grep -q "block-chokepoint-env-prefix.sh" "$REPO_ROOT/.claude/settings.json" 2>/dev/null; then
    echo "PASS settings.json wiring present"
else
    echo "WARN settings.json does not reference block-chokepoint-env-prefix.sh yet (not counted as a failure)"
    CASES=$((CASES - 1))
fi

if [ "$FAILED" -eq 0 ]; then
    echo "OK: all $CASES cases passed"
    exit 0
fi
echo "FAILED: $FAILED of $CASES cases failed"
exit 1
