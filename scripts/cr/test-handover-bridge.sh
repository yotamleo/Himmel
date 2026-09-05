#!/usr/bin/env bash
# Smoke test for scripts/cr/handover-bridge.sh (HIMMEL-2321).
#
# Hermetic: every test sets CR_LEDGER to a private temp file, so
# ledger-append.sh/handover-bridge.sh's git-common-dir default is never
# reached and the real ledger/HOME are never touched. --head/--branch never
# need a real git repo either (handover-bridge.sh does plain string equality
# on the ledger's own "head" field, it never re-derives or resolves via git).
#
# Usage: bash scripts/cr/test-handover-bridge.sh
#
# Exit codes:
#   0 -- all cases passed
#   1 -- at least one case failed
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/handover-bridge.sh"
BUG_SH="$DIR/../handover/bug.sh"

FAILED=0
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label -- expected '$expected', got '$actual'"
        FAILED=$((FAILED + 1))
    fi
}
assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *) echo "FAIL $label -- expected to find '$needle' in: $haystack"; FAILED=$((FAILED + 1)) ;;
    esac
}
assert_not_contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) echo "FAIL $label -- unexpectedly found '$needle' in: $haystack"; FAILED=$((FAILED + 1)) ;;
        *) echo "PASS $label" ;;
    esac
}
assert_file_absent() {
    local label="$1" path="$2"
    if [ -e "$path" ]; then
        echo "FAIL $label -- $path unexpectedly exists"
        FAILED=$((FAILED + 1))
    else
        echo "PASS $label"
    fi
}

TMP=$(mktemp -d -t handover-bridge.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
# Every test reassigns CR_LEDGER below; export it once so the child bash
# process running $SCRIPT actually sees each reassignment (a bare VAR=value
# statement is local to this shell, never inherited by a later child unless
# exported -- this caught a real bug in an earlier draft of this suite: every
# test silently ran against an unset CR_LEDGER).
export CR_LEDGER=""

# new_item <name> -> sets ITEM/NOTES/BUGS for a fresh, empty handover item dir.
new_item() {
    ITEM="$TMP/item-$1"
    mkdir -p "$ITEM"
    NOTES="$ITEM/reviewer-notes.md"
    BUGS="$ITEM/bugs.md"
}

# run_bridge <args...> -> sets OUT, ERR, RC. CR_LEDGER must already be set by
# the caller (a hermetic per-test path, never unset -- see header comment).
run_bridge() {
    OUT=$(bash "$SCRIPT" "$@" 2>"$TMP/err.txt")
    RC=$?
    ERR=$(cat "$TMP/err.txt")
}

bug_status() { # bugs_file id -> resolved|open|fixing|wontfix|MISSING
    local bugs="$1" id="$2"
    grep -oE "^### ${id} .*<!-- status: [a-z]+ -->" "$bugs" 2>/dev/null | grep -oE 'status: [a-z]+' | awk '{print $2}' || true
}

# -- T1: apostrophe + $(...) title survives byte-intact; nothing executes --
new_item t1
CR_LEDGER="$TMP/ledger-t1.jsonl"
cat > "$CR_LEDGER" <<'EOF'
{"kind":"finding","head":"headt1","branch":"b","model":"codex","finding_id":"codex-1","severity":"crit","file":"a.py","line":10,"verdict":"","artifact":"diff","perspective":"off","text":"It's broken: $(touch MARKER_T1) -- fix it"}
EOF
# T9 (negative control, folded into T1's setup): prove the fixture genuinely
# produced a ledger row before trusting any assertion about what the bridge
# did with it -- a suite that never checks this could pass against an empty
# ledger and prove nothing.
assert_contains "T9 negative control: fixture ledger is non-empty" "$(cat "$CR_LEDGER")" "codex-1"
run_bridge --head headt1 --branch b --notes "$NOTES"
assert_eq "T1 rc" "0" "$RC"
notes_content="$(cat "$NOTES" 2>/dev/null || true)"
assert_contains "T1 title survives byte-intact (apostrophe + \$(...))" "$notes_content" "It's broken: \$(touch MARKER_T1) -- fix it"
assert_file_absent "T1 no command execution occurred" "$TMP/MARKER_T1"
assert_file_absent "T1 no command execution occurred (cwd)" "MARKER_T1"
assert_not_contains "T1 stderr has no unexpected error" "$ERR" "unexpected error"

# -- T2: amend supersession -- empty verdict, then amended to deferred --
new_item t2
CR_LEDGER="$TMP/ledger-t2.jsonl"
cat > "$CR_LEDGER" <<'EOF'
{"kind":"finding","head":"headt2","branch":"b","model":"codex","finding_id":"codex-1","severity":"imp","file":"a.py","line":1,"verdict":"","artifact":"diff","perspective":"off","text":"amend me"}
{"kind":"amend","target_head":"headt2","finding_id":"codex-1","artifact":"diff","perspective":"off","set":{"verdict":"deferred"}}
EOF
run_bridge --head headt2 --branch b --notes "$NOTES"
assert_contains "T2 amended verdict (deferred) surfaces, not empty" "$(cat "$NOTES")" "(deferred)"
assert_not_contains "T2 does not show the pre-amend empty verdict as ()" "$(cat "$NOTES")" "codex-1] a.py:1  --  amend me ()"

# -- T3: disproved/deferred findings excluded from the 4.7 findings file --
new_item t3
bash "$BUG_SH" add --bugs "$BUGS" --symptom "disproved sym" --finding-id codex-3 >/dev/null
bash "$BUG_SH" add --bugs "$BUGS" --symptom "deferred sym" --finding-id codex-4 >/dev/null
CR_LEDGER="$TMP/ledger-t3.jsonl"
cat > "$CR_LEDGER" <<'EOF'
{"kind":"finding","head":"headt3","branch":"b","model":"codex","finding_id":"codex-3","severity":"crit","file":"a.py","line":1,"verdict":"","artifact":"diff","perspective":"off","text":"disproved finding"}
{"kind":"amend","target_head":"headt3","finding_id":"codex-3","artifact":"diff","perspective":"off","set":{"verdict":"disproved"}}
{"kind":"finding","head":"headt3","branch":"b","model":"codex","finding_id":"codex-4","severity":"imp","file":"b.py","line":2,"verdict":"","artifact":"diff","perspective":"off","text":"deferred finding"}
{"kind":"amend","target_head":"headt3","finding_id":"codex-4","artifact":"diff","perspective":"off","set":{"verdict":"deferred"}}
{"kind":"avail","head":"headt3","branch":"b","model":"codex","status":"ok","artifact":"diff","perspective":"off"}
EOF
run_bridge --head headt3 --branch b --bugs "$BUGS"
# If codex-3/codex-4 had leaked into the findings file, bug.sh would see them
# as PRESENT and leave the already-open bug untouched (no status change). The
# only way either bug flips to resolved is via part 2 of append-cr-bugs.sh:
# absent-this-run + critic ok in avail -- which only happens if the exclusion
# worked.
assert_eq "T3 disproved finding excluded -> its tracked bug resolves" "resolved" "$(bug_status "$BUGS" BUG-1)"
assert_eq "T3 deferred finding excluded -> its tracked bug resolves" "resolved" "$(bug_status "$BUGS" BUG-2)"

# -- T4: sug findings reach reviewer-notes (4.6) but not bugs.md (4.7) --
new_item t4
bash "$BUG_SH" add --bugs "$BUGS" --symptom "sug sym" --finding-id codex-5 >/dev/null
CR_LEDGER="$TMP/ledger-t4.jsonl"
cat > "$CR_LEDGER" <<'EOF'
{"kind":"finding","head":"headt4","branch":"b","model":"codex","finding_id":"codex-5","severity":"sug","file":"a.py","line":1,"verdict":"","artifact":"diff","perspective":"off","text":"just a suggestion"}
{"kind":"avail","head":"headt4","branch":"b","model":"codex","status":"ok","artifact":"diff","perspective":"off"}
EOF
run_bridge --head headt4 --branch b --notes "$NOTES" --bugs "$BUGS"
assert_contains "T4 sug finding reaches reviewer-notes.md" "$(cat "$NOTES")" "codex-5"
assert_eq "T4 sug finding excluded from bugs.md -> its tracked bug resolves" "resolved" "$(bug_status "$BUGS" BUG-1)"

# -- T5: clean review (0 findings) still calls append-cr-bugs.sh with an --
# empty findings file; avail rows are still passed through.
new_item t5
bash "$BUG_SH" add --bugs "$BUGS" --symptom "vanished sym" --finding-id codex-9 >/dev/null
CR_LEDGER="$TMP/ledger-t5.jsonl"
cat > "$CR_LEDGER" <<'EOF'
{"kind":"avail","head":"headt5","branch":"b","model":"codex","status":"ok","artifact":"diff","perspective":"off"}
EOF
run_bridge --head headt5 --branch b --bugs "$BUGS"
assert_eq "T5 rc" "0" "$RC"
assert_contains "T5 stdout reports the empty findings file was still processed" "$OUT" "0 blocking"
assert_eq "T5 clean review still resolves a vanished tracked bug (proves the bridge ran)" "resolved" "$(bug_status "$BUGS" BUG-1)"

# -- T6: uncitable finding (empty file/line) is recorded, not skipped --
new_item t6
CR_LEDGER="$TMP/ledger-t6.jsonl"
cat > "$CR_LEDGER" <<'EOF'
{"kind":"finding","head":"headt6","branch":"b","model":"codex","finding_id":"codex-6","severity":"imp","file":"","line":"","verdict":"","artifact":"diff","perspective":"off","text":"no citation available"}
EOF
run_bridge --head headt6 --branch b --notes "$NOTES"
assert_contains "T6 uncitable finding recorded (dedup marker present)" "$(cat "$NOTES")" "<!-- cr:headt6:codex-6 -->"
assert_contains "T6 uncitable finding title present" "$(cat "$NOTES")" "no citation available"

# -- T7: argument errors -> exit 2 --
run_bridge --branch b --notes "$TMP/x.md"
assert_eq "T7a missing --head -> rc" "2" "$RC"
assert_contains "T7a stderr names the missing flag" "$ERR" "--head"
run_bridge --head headt7 --notes "$TMP/x.md"
assert_eq "T7b missing --branch -> rc" "2" "$RC"
assert_contains "T7b stderr names the missing flag" "$ERR" "--branch"
run_bridge --head headt7 --branch b
assert_eq "T7c neither --notes nor --bugs -> rc" "2" "$RC"
assert_contains "T7c stderr explains the missing flag" "$ERR" "--notes/--bugs"

# -- T8: best-effort posture -- a ledger path that does not exist -> rc 0 --
new_item t8
CR_LEDGER="$TMP/does-not-exist-t8.jsonl"
run_bridge --head headt8 --branch b --notes "$NOTES"
assert_eq "T8 missing ledger -> rc 0 (best effort)" "0" "$RC"
assert_contains "T8 missing ledger -> 0 findings reported" "$OUT" "0 finding(s)"

# -- T9 (CR round 1, codex-1): an UNPARSEABLE ledger row must not let a bug be
# auto-resolved. append-cr-bugs.sh resolves an open bug whose finding-id is
# absent this run, licensed by that critic's `ok` avail row. If the finding's
# own line is corrupt, "absent" and "unreadable" are indistinguishable -- so
# the avail rows are withheld and nothing is resolved. The open/reopen
# direction is unaffected (it only ever ADDs).
new_item t9
bash "$BUG_SH" add --bugs "$BUGS" --symptom "still open sym" --finding-id codex-9 >/dev/null
CR_LEDGER="$TMP/ledger-t9.jsonl"
cat > "$CR_LEDGER" <<'EOF'
{"kind":"avail","head":"headt9","branch":"b","model":"codex","status":"ok","artifact":"diff","perspective":"off"}
{"kind":"finding","head":"headt9","branch":"b","model":"codex","finding_id":"codex-9","severity":"crit"  <<< CORRUPT NOT JSON
EOF
run_bridge --head headt9 --branch b --bugs "$BUGS"
assert_eq "T9 rc still 0 (best effort)" "0" "$RC"
assert_contains "T9 warns that a ledger row was unparseable" "$ERR" "unparseable ledger row"
assert_contains "T9 says the avail rows were withheld" "$ERR" "withholding"
assert_eq "T9 the still-open bug is NOT auto-resolved on an incomplete finding set" "open" "$(bug_status "$BUGS" BUG-1)"
# The relayed summary must report what was FORWARDED, not what was found
# (CR round 3, codex-3): this line goes verbatim into the /pr-check report, so
# naming the original avail count would claim evidence reached bugs.md that
# was deliberately withheld.
assert_contains "T9 summary reports 0 avail rows forwarded, not the count found" "$OUT" "0 avail row(s) -> bugs.md"
assert_contains "T9 summary names the withheld count explicitly" "$OUT" "(1 withheld)"

# T9b negative control: the SAME fixture with a well-formed finding line
# resolves normally, so T9 pins the corruption and not merely "this bridge
# never resolves anything".
new_item t9b
bash "$BUG_SH" add --bugs "$BUGS" --symptom "vanished sym" --finding-id codex-9 >/dev/null
CR_LEDGER="$TMP/ledger-t9b.jsonl"
cat > "$CR_LEDGER" <<'EOF'
{"kind":"avail","head":"headt9b","branch":"b","model":"codex","status":"ok","artifact":"diff","perspective":"off"}
EOF
run_bridge --head headt9b --branch b --bugs "$BUGS"
assert_eq "T9b control: a PARSEABLE ledger still resolves the vanished bug" "resolved" "$(bug_status "$BUGS" BUG-1)"

# -- T12 (CodeRabbit App, PR 2097): a row that PARSES but is missing
# finding_id (or severity) is unusable evidence, and unusable is not absent.
# Dropping it silently would delete a REAL finding from the findings file
# while its critic avail row still says ok — exactly the licence
# append-cr-bugs.sh needs to resolve that bug. It must count into the same
# incomplete-ledger state, so the avail rows are withheld and nothing resolves.
new_item t12
bash "$BUG_SH" add --bugs "$BUGS" --symptom "still open sym" --finding-id codex-12 >/dev/null
CR_LEDGER="$TMP/ledger-t12.jsonl"
cat > "$CR_LEDGER" <<'EOF'
{"kind":"avail","head":"headt12","branch":"b","model":"codex","status":"ok","artifact":"diff","perspective":"off"}
{"kind":"finding","head":"headt12","branch":"b","model":"codex","severity":"crit","file":"a.py","line":1,"verdict":"","artifact":"diff","perspective":"off","text":"valid JSON but no finding_id"}
EOF
run_bridge --head headt12 --branch b --bugs "$BUGS"
assert_eq "T12 rc still 0 (best effort)" "0" "$RC"
assert_contains "T12 warns the row is unusable" "$ERR" "missing finding_id or severity"
assert_contains "T12 treats it as an incomplete ledger and withholds avail" "$ERR" "withholding"
assert_eq "T12 the still-open bug is NOT resolved off an unusable finding row" "open" "$(bug_status "$BUGS" BUG-1)"

# -- T10 (CR round 1, codex-2): rows are selected on (head, branch), never head
# alone. Two branches can sit at the SAME commit, so a SHA does not identify
# whose review this is; the other branch's finding must not be copied in.
new_item t10
CR_LEDGER="$TMP/ledger-t10.jsonl"
cat > "$CR_LEDGER" <<'EOF'
{"kind":"finding","head":"headt10","branch":"mine","model":"codex","finding_id":"codex-10","severity":"imp","file":"a.py","line":1,"verdict":"","artifact":"diff","perspective":"off","text":"belongs to this branch"}
{"kind":"finding","head":"headt10","branch":"theirs","model":"codex","finding_id":"codex-11","severity":"imp","file":"b.py","line":2,"verdict":"","artifact":"diff","perspective":"off","text":"belongs to another branch"}
{"kind":"finding","head":"headt10","model":"codex","finding_id":"codex-12","severity":"imp","file":"c.py","line":3,"verdict":"","artifact":"diff","perspective":"off","text":"legacy row with no branch field"}
EOF
run_bridge --head headt10 --branch mine --notes "$NOTES"
assert_contains "T10 this branch's finding is recorded" "$(cat "$NOTES")" "belongs to this branch"
assert_not_contains "T10 the other branch's same-head finding is NOT copied in" "$(cat "$NOTES")" "belongs to another branch"
assert_contains "T10 a legacy row with no branch field is still accepted (head pins the commit)" "$(cat "$NOTES")" "legacy row with no branch field"

# -- T11 (CR round 1, codex-3): the relayed summary counts WRITES, not
# attempts. This line goes verbatim into the /pr-check report, so counting a
# failed append as delivered is the report claiming evidence that does not
# exist. Forced with an unwritable --notes target: its parent dir does not
# exist, which append-cr-findings.sh refuses with exit 2.
new_item t11
CR_LEDGER="$TMP/ledger-t11.jsonl"
cat > "$CR_LEDGER" <<'EOF'
{"kind":"finding","head":"headt11","branch":"b","model":"codex","finding_id":"codex-13","severity":"imp","file":"a.py","line":1,"verdict":"","artifact":"diff","perspective":"off","text":"will not land"}
EOF
run_bridge --head headt11 --branch b --notes "$TMP/no-such-dir-t11/reviewer-notes.md"
assert_eq "T11 rc still 0 (best effort)" "0" "$RC"
assert_contains "T11 the failed write is reported as FAILED, not as delivered" "$OUT" "(1 FAILED)"
assert_contains "T11 summary does not claim the finding reached reviewer-notes" "$OUT" "0 finding(s) -> reviewer-notes"

# -- t13: avail rows are NOT branch-scoped (gate identity is (head, model),
# HIMMEL-1613/1640). clear-cr-marker.sh (the gate) selects avail rows by
# (head, model) only, never branch, because availability is a property of the
# critic+commit pair, not of which review arm probed it. An avail row stamped
# with a DIFFERENT branch than this invocation must still count, or this
# bridge sees fewer avail rows than the gate does and the handover trail
# disagrees with the gate about what covered a head (HIMMEL-2405).
new_item t13
bash "$BUG_SH" add --bugs "$BUGS" --symptom "vanished sym" --finding-id codex-13b >/dev/null
CR_LEDGER="$TMP/ledger-t13.jsonl"
cat > "$CR_LEDGER" <<'EOF'
{"kind":"avail","head":"headt13","branch":"other","model":"codex","status":"ok","artifact":"diff","perspective":"off"}
EOF
run_bridge --head headt13 --branch b --bugs "$BUGS"
assert_eq "t13 avail row from a different branch is still counted -> vanished bug resolves" "resolved" "$(bug_status "$BUGS" BUG-1)"

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
