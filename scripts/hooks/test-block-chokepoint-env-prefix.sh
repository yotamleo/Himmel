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

# run <json> [ENV=VAL ...] -> runs the hook, sets OUT/ERR/RC.
run() {
    local input="$1"; shift
    local outf errf
    outf=$(mktemp); errf=$(mktemp)
    printf '%s' "$input" | env -u ENV_PREFIX_GUARD_OK -u CHOKEPOINT_REGISTRY "$@" bash "$HOOK" >"$outf" 2>"$errf"
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
       && printf '%s' "$ERR" | grep -q "LAUNCHING shell"; then
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
assert_allow "env -u UNREGISTERED name stays allowed"             "$(j "env -u SOME_OTHER_VAR bash $MERGE_ON_GREEN 1")"
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
assert_allow "chokepoint FIRST; bare assignment in a LATER segment" "$(j "bash $MERGE_ON_GREEN 1; HIMMEL_CONSOLE_LEG=0")"

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
assert_allow "finding 1: seam var on OTHER segment (;)"   "$(j "${MOG_VAR}=x echo ok; bash $MERGE_ON_GREEN")"
assert_allow "finding 1: seam var on OTHER segment (&&)"  "$(j "${MOG_VAR}=x echo ok && bash $MERGE_ON_GREEN")"
assert_allow "finding 1: seam var on OTHER segment (||)"  "$(j "${MOG_VAR}=x echo ok || bash $MERGE_ON_GREEN")"
assert_allow "finding 1: seam var on OTHER segment (|)"   "$(j "${MOG_VAR}=x echo ok | bash $MERGE_ON_GREEN")"
assert_allow "finding 1: seam var on OTHER segment (nl)"  "$(j "${MOG_VAR}=x echo ok
bash $MERGE_ON_GREEN")"
assert_allow "chokepoint, THEN unrelated assignment segment" "$(j "bash $MERGE_ON_GREEN; ${MOG_VAR}=x echo ok")"
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
assert_allow "finding 4: path in ARGUMENT position (echo)" "$(j "${MOG_VAR}=1 echo $MERGE_ON_GREEN")"
assert_allow "finding 4: path in ARGUMENT position (cat)"  "$(j "${MOG_VAR}=1 cat $MERGE_ON_GREEN")"

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
assert_allow "bash -c: path in \$0 position is not invoked" "$(j "${MOG_VAR}=1 bash -c 'echo hi' $MERGE_ON_GREEN")"
assert_allow "double-quoted literal text is not an invocation" "$(j "echo \"${MOG_VAR}=1 bash $MERGE_ON_GREEN\"")"

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
assert_allow "env -S string WITHOUT a seam var"        "$(j "env -S 'bash $MERGE_ON_GREEN'")"
assert_allow "env -S: words after the string are appended args" "$(j "env -S 'echo hi' bash $MERGE_ON_GREEN")"
assert_allow "env -S: path at \$0 inside the string"   "$(j "env -S '${MOG_VAR}=x bash -c \"echo hi\" $MERGE_ON_GREEN'")"

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
assert_allow "env -vS string WITHOUT a seam var"       "$(j "env -vS 'bash $MERGE_ON_GREEN'")"
assert_allow "env -vS: words after the string are appended args" "$(j "env -vS 'echo hi' bash $MERGE_ON_GREEN")"
assert_allow "env -iS: path at \$0 inside the string"  "$(j "env -iS '${MOG_VAR}=x bash -c \"echo hi\" $MERGE_ON_GREEN'")"
assert_allow "env -vSu: mid-cluster S consumes u; rest are appended args" "$(j "env -vSu '${MOG_VAR}=x bash $MERGE_ON_GREEN'")"

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
assert_allow "after --, an option WORD is the command, not an option"      "$(j "env -- --unset ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_allow "after -, an option WORD is the command, not an option"       "$(j "env - --unset ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_allow "optarg long (--ignore-signal) takes no separate word"        "$(j "env --ignore-signal INT ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
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
assert_allow "env -S option state, no seam var"            "$(j "env -S '-u X bash $MERGE_ON_GREEN'")"
assert_allow "env -S: ; inside the string is a word character" "$(j "env -S 'echo ok; ${MOG_VAR}=x bash $MERGE_ON_GREEN'")"

# --- HIMMEL-1803 round 7: an unquoted # at argument start discards the
# rest of an env -S string; an escaped \# remains literal word content. ---
assert_deny  "env -S: leading # comment discards the string" "$(j "env -S '# ignored' ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env -S: mid-string # comment discards the rest" "$(j "env -S '-u X # ignored' ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env -S: escaped \# stays literal before a later comment" "$(j "env -S '-u \\# # ignored' ${MOG_VAR}=x bash $MERGE_ON_GREEN")"

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
assert_allow "r6: empty word IS env's command (exec fails)"       "$(j "env '' ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_allow "r6: empty word IS the shell command"                "$(j "${MOG_VAR}=x '' bash $MERGE_ON_GREEN")"
assert_allow "r6: empty word at command position inside -S"       "$(j "env -S \"${MOG_VAR}=x '' bash $MERGE_ON_GREEN\"")"
assert_allow "r6: -S string of only a quoted empty"               "$(j "env -S \"''\" ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_allow "r6: quoted-empty word attached to a redirect is a word, not an IO number" "$(j "${MOG_VAR}=x ''>/tmp/h.log bash $MERGE_ON_GREEN")"

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
assert_allow "subshell-scoped unset (dropped at the closing paren)"        "$(j "(unset HIMMEL_CONSOLE_LEG); bash $MERGE_ON_GREEN 1")"
assert_allow "subshell-scoped export -n (dropped at the closing paren)"    "$(j "(export -n HIMMEL_CONSOLE_LEG); bash $MERGE_ON_GREEN 1")"
assert_allow "subshell-scoped bare assignment (dropped at the closing paren)" "$(j "(HIMMEL_CONSOLE_LEG=0); bash $MERGE_ON_GREEN 1")"
assert_allow "subshell-scoped unset then && chokepoint"                    "$(j "(unset HIMMEL_CONSOLE_LEG) && bash $MERGE_ON_GREEN 1")"
assert_deny "codex-1: \`((VAR=0))\` arithmetic assignment is same-shell, not a scoped subshell" "$(j "((HIMMEL_CONSOLE_LEG=0)); bash $MERGE_ON_GREEN 1")"
assert_deny "adjacent \`((\` is the arithmetic command, not two real subshells" "$(j "((unset HIMMEL_CONSOLE_LEG)); bash $MERGE_ON_GREEN 1")"
assert_deny "codex-1 round 2: a grouping paren nested inside \`((...))\` inherits neutrality, not real-subshell scoping" "$(j "(( (HIMMEL_CONSOLE_LEG=0) )); bash $MERGE_ON_GREEN 1")"
assert_deny "chokepoint invoked INSIDE the same subshell as the clear"     "$(j "(unset HIMMEL_CONSOLE_LEG; bash $MERGE_ON_GREEN 1)")"
assert_deny "outer clear reaches into a later subshell's chokepoint"       "$(j "unset HIMMEL_CONSOLE_LEG; (bash $MERGE_ON_GREEN 1)")"
assert_deny "outer clear reaches into a nested subshell's chokepoint"      "$(j "(unset HIMMEL_CONSOLE_LEG; (bash $MERGE_ON_GREEN 1))")"
assert_deny "outer clear survives an unrelated sibling subshell"           "$(j "unset HIMMEL_CONSOLE_LEG; ( true ); bash $MERGE_ON_GREEN 1")"
assert_deny "unbalanced open paren (no closing paren) stays fold-forward"  "$(j "(unset HIMMEL_CONSOLE_LEG; bash $MERGE_ON_GREEN 1")"
assert_deny "command substitution \$( ) is not a subshell -- stays denied" "$(j "\$(unset HIMMEL_CONSOLE_LEG); bash $MERGE_ON_GREEN 1")"
assert_deny "bash -c string is an unresolved form -- stays denied"        "$(j "bash -c 'unset HIMMEL_CONSOLE_LEG'; bash $MERGE_ON_GREEN 1")"
assert_deny "a { } group is not a subshell -- stays denied"               "$(j "{ unset HIMMEL_CONSOLE_LEG; }; bash $MERGE_ON_GREEN 1")"

# --- ALLOWED: fail-open proofs ---
assert_allow "bare sanctioned invocation (no prefix)"    "$(j "bash $MERGE_ON_GREEN")"
assert_allow "bare invocation, other chokepoint"         "$(j "bash $STOP_WORKER --list")"
assert_allow "env wrapper WITHOUT a seam var"            "$(j "env bash $MERGE_ON_GREEN")"
assert_allow "registered var, UNREGISTERED script"       "$(j "${SW_VAR}=9 bash scripts/some/unregistered-script.sh")"
assert_allow "UNREGISTERED var, registered chokepoint"   "$(j "TOTALLY_UNRELATED_VAR=1 bash $MERGE_ON_GREEN")"
assert_allow "seam var of a DIFFERENT chokepoint"        "$(j "${MOG_VAR}=1 bash $STOP_WORKER --list")"
assert_allow "longer var name sharing a prefix"          "$(j "${MOG_VAR}X=1 bash $MERGE_ON_GREEN")"
assert_allow "assignment as an ARGUMENT, not a prefix"   "$(j "bash $STOP_WORKER --dry-run ${SW_VAR}=9")"
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
