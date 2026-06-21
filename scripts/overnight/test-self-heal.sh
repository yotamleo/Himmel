#!/usr/bin/env bash
# Tests for scripts/overnight/self-heal.sh (HIMMEL-476, C2).
#
# Covers:
#   classify
#     1.  done row passes through unchanged (no dispatch spec).
#     2.  substantive failure → triage row with DECISION, no dispatch spec.
#     3.  lint (shellcheck) failure → dispatch spec, HELD out of rows.
#     4.  encoding (BOM) failure → dispatch spec, class=encoding.
#     5.  mixed lint + substantive (AssertionError) → substantive (fail-safe).
#     6.  pre-commit "shellcheck....Failed" (lint + "Failed") → lint (mechanical).
#     7.  non-done with empty/missing logfile → triage "no failure detail".
#     8.  diff-range failure → dispatch spec, class=diff-range.
#     9.  bad input: invalid status / too few fields / empty → exit 1.
#    10.  no --dispatch-out but mechanical failures → warn on stderr.
#   reconcile
#    11.  fixed=done → green `done` row.
#    12.  fixed=still-failing → blocker row ("still failing").
#    13.  branch dispatched but absent from --fixed → "did not return" blocker.
#    14.  empty plan → final == rows-in passthrough.
#    15.  --fixed file absent entirely → all dispatched branches escalate.
#   integration (EPIC-DONE swarm sim)
#    16.  3-ticket fanout (done + auto-fixable lint + substantive) → classify →
#         reconcile (lint fixed green) → morning-report.sh: lint ticket DONE,
#         substantive ticket a DECISION, all three present, no run stopped.
#   usage
#    17.  missing subcommand / unknown subcommand / missing required args → exit 1.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/self-heal.sh"
REPORT="$SCRIPT_DIR/morning-report.sh"
TAB="$(printf '\t')"

PASS=0; FAIL=0; TMP_ROOT=""

# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then pass "$name"; else fail "$name" "missing: $needle"; fi
}
refute_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then fail "$name" "unexpected: $needle"; else pass "$name"; fi
}
assert_before() {
    local name="$1" first="$2" second="$3" haystack="$4" l1 l2
    l1=$(printf '%s\n' "$haystack" | grep -nF -- "$first"  | head -1 | cut -d: -f1 || true)
    l2=$(printf '%s\n' "$haystack" | grep -nF -- "$second" | head -1 | cut -d: -f1 || true)
    if [ -n "$l1" ] && [ -n "$l2" ] && [ "$l1" -lt "$l2" ]; then pass "$name"
    else fail "$name" "first='$first' line=${l1:-missing}, second='$second' line=${l2:-missing}"; fi
}

TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi

LEDGER="$TMP_ROOT/ledger.tsv"
ROWS="$TMP_ROOT/rows.tsv"
PLAN="$TMP_ROOT/plan.tsv"

# Helper: write a logfile, echo its path.
mklog() { local p="$TMP_ROOT/log-$1.txt"; printf '%s\n' "$2" > "$p"; echo "$p"; }

# === classify ============================================================

echo "TEST 1: done row passes through"
printf '%s\n' "HIMMEL-1${TAB}feat/h1${TAB}https://pr/1${TAB}done${TAB}Shipped${TAB}" > "$LEDGER"
bash "$SCRIPT" classify --rows-in "$LEDGER" --rows-out "$ROWS" --dispatch-out "$PLAN" 2>/dev/null
rows=$(cat "$ROWS"); plan=$(cat "$PLAN")
assert_contains "done row carried through" "HIMMEL-1${TAB}feat/h1${TAB}https://pr/1${TAB}done${TAB}Shipped" "$rows"
if [ -s "$PLAN" ]; then fail "done row produced a dispatch spec"; else pass "no dispatch spec for done row"; fi

echo "TEST 2: substantive failure → triage row, no dispatch spec"
lf=$(mklog sub "ERROR: implementation incomplete, logic error in retry path")
printf '%s\n' "HIMMEL-2${TAB}fix/h2${TAB}-${TAB}blocked${TAB}Build failed${TAB}$lf" > "$LEDGER"
bash "$SCRIPT" classify --rows-in "$LEDGER" --rows-out "$ROWS" --dispatch-out "$PLAN" 2>/dev/null
rows=$(cat "$ROWS")
assert_contains "substantive triage decision" "operator-gated blocker: substantive failure" "$rows"
assert_contains "substantive keeps status" "HIMMEL-2${TAB}fix/h2" "$rows"
if [ -s "$PLAN" ]; then fail "substantive produced a dispatch spec"; else pass "no dispatch spec for substantive"; fi

echo "TEST 3: lint (shellcheck) failure → dispatch spec, held out of rows"
lf=$(mklog lint "In foo.sh line 4: SC2086: Double quote to prevent globbing. shellcheck found issues")
printf '%s\n' "HIMMEL-3${TAB}feat/h3${TAB}-${TAB}blocked${TAB}precommit failed${TAB}$lf" > "$LEDGER"
bash "$SCRIPT" classify --rows-in "$LEDGER" --rows-out "$ROWS" --dispatch-out "$PLAN" 2>/dev/null
rows=$(cat "$ROWS"); plan=$(cat "$PLAN")
assert_contains "lint dispatch spec emitted" "HIMMEL-3${TAB}feat/h3${TAB}lint${TAB}" "$plan"
assert_contains "lint fix instruction scoped to branch" "On branch feat/h3 ONLY" "$plan"
refute_contains "lint NOT a report row (held)" "HIMMEL-3" "$rows"

echo "TEST 4: encoding (BOM) failure → dispatch spec class=encoding"
lf=$(mklog enc "shell-lint: [BOM] UTF-8 byte-order mark at file start — strip it (SC1082)")
printf '%s\n' "HIMMEL-4${TAB}fix/h4${TAB}-${TAB}blocked${TAB}precommit failed${TAB}$lf" > "$LEDGER"
bash "$SCRIPT" classify --rows-in "$LEDGER" --dispatch-out "$PLAN" --rows-out "$ROWS" 2>/dev/null
plan=$(cat "$PLAN")
assert_contains "encoding dispatch spec" "HIMMEL-4${TAB}fix/h4${TAB}encoding${TAB}" "$plan"

echo "TEST 5: mixed lint + substantive → substantive (fail-safe, no auto-fix)"
lf=$(mklog mixed "foo.sh line 2: SC2086 note. AssertionError: expected 3 got 4 in tests")
printf '%s\n' "HIMMEL-5${TAB}feat/h5${TAB}-${TAB}blocked${TAB}failed${TAB}$lf" > "$LEDGER"
bash "$SCRIPT" classify --rows-in "$LEDGER" --rows-out "$ROWS" --dispatch-out "$PLAN" 2>/dev/null
rows=$(cat "$ROWS"); plan=$(cat "$PLAN")
assert_contains "mixed → substantive triage" "operator-gated blocker: substantive failure" "$rows"
if [ -s "$PLAN" ]; then fail "mixed log got an auto-fix dispatch spec (unsafe)"; else pass "mixed log NOT auto-fixed"; fi

echo "TEST 6: pre-commit 'shellcheck....Failed' (lint + Failed word) → lint"
lf=$(mklog precommit "shellcheck...............Failed - hook id: shellcheck. SC2034 unused var")
printf '%s\n' "HIMMEL-6${TAB}feat/h6${TAB}-${TAB}blocked${TAB}precommit${TAB}$lf" > "$LEDGER"
bash "$SCRIPT" classify --rows-in "$LEDGER" --rows-out "$ROWS" --dispatch-out "$PLAN" 2>/dev/null
plan=$(cat "$PLAN")
assert_contains "pre-commit shellcheck-Failed is mechanical" "HIMMEL-6${TAB}feat/h6${TAB}lint${TAB}" "$plan"

echo "TEST 7: non-done with empty logfile path → triage 'no failure detail'"
printf '%s\n' "HIMMEL-7${TAB}fix/h7${TAB}-${TAB}blocked${TAB}died${TAB}" > "$LEDGER"
bash "$SCRIPT" classify --rows-in "$LEDGER" --rows-out "$ROWS" --dispatch-out "$PLAN" 2>/dev/null
rows=$(cat "$ROWS")
assert_contains "no-detail → manual triage" "no failure detail captured — manual triage" "$rows"

echo "TEST 8: diff-range failure → dispatch spec class=diff-range"
lf=$(mklog dr "propagation step failed: wrong base, use merge-base range not two-dot")
printf '%s\n' "HIMMEL-8${TAB}chore/h8${TAB}-${TAB}blocked${TAB}prop${TAB}$lf" > "$LEDGER"
bash "$SCRIPT" classify --rows-in "$LEDGER" --rows-out "$ROWS" --dispatch-out "$PLAN" 2>/dev/null
plan=$(cat "$PLAN")
assert_contains "diff-range dispatch spec" "HIMMEL-8${TAB}chore/h8${TAB}diff-range${TAB}" "$plan"

echo "TEST 9: bad input rejected (exit 1)"
printf '%s\n' "HIMMEL-9${TAB}feat/x${TAB}-${TAB}shipped${TAB}o${TAB}" > "$LEDGER"
rc=0; out=$(bash "$SCRIPT" classify --rows-in "$LEDGER" --rows-out "$ROWS" 2>&1) || rc=$?
case "$rc" in 1) pass "exit 1 on invalid status";; *) fail "want rc=1, got $rc" "$out";; esac
assert_contains "status diagnostic" 'invalid status "shipped"' "$out"
printf '%s\n' "HIMMEL-9${TAB}feat/x${TAB}done" > "$LEDGER"
rc=0; out=$(bash "$SCRIPT" classify --rows-in "$LEDGER" 2>&1) || rc=$?
case "$rc" in 1) pass "exit 1 on too few fields";; *) fail "want rc=1, got $rc" "$out";; esac
: > "$LEDGER"
rc=0; out=$(bash "$SCRIPT" classify --rows-in "$LEDGER" 2>&1) || rc=$?
case "$rc" in 1) pass "exit 1 on empty input";; *) fail "want rc=1, got $rc" "$out";; esac

echo "TEST 10: mechanical failure but no --dispatch-out → warn on stderr"
lf=$(mklog l10 "SC2086 shellcheck issue")
printf '%s\n' "HIMMEL-10${TAB}feat/h10${TAB}-${TAB}blocked${TAB}f${TAB}$lf" > "$LEDGER"
rc=0; err=$(bash "$SCRIPT" classify --rows-in "$LEDGER" --rows-out "$ROWS" 2>&1 >/dev/null) || rc=$?
assert_contains "warns when dispatch spec uncaptured" "no --dispatch-out given" "$err"

# === reconcile ===========================================================

# Build a stable plan + rows for reconcile tests.
mkplan() { printf '%s\n' "$1" > "$PLAN"; }
mkrows() { printf '%s\n' "$1" > "$ROWS"; }

echo "TEST 11: fixed=done → green done row"
mkplan "HIMMEL-3${TAB}feat/h3${TAB}lint${TAB}fix it"
mkrows "HIMMEL-1${TAB}feat/h1${TAB}https://pr/1${TAB}done${TAB}Shipped"
FIXED="$TMP_ROOT/fixed.tsv"
printf '%s\n' "HIMMEL-3${TAB}feat/h3${TAB}https://pr/3${TAB}done${TAB}Lint fixed, green" > "$FIXED"
final=$(bash "$SCRIPT" reconcile --plan "$PLAN" --fixed "$FIXED" --rows-in "$ROWS" 2>/dev/null)
assert_contains "carried done row" "HIMMEL-1${TAB}feat/h1" "$final"
assert_contains "auto-fixed → done" "HIMMEL-3${TAB}feat/h3${TAB}https://pr/3${TAB}done${TAB}Lint fixed, green" "$final"
refute_contains "green row has no decision tail" "auto-fix attempted" "$final"

echo "TEST 12: fixed still failing → blocker row"
printf '%s\n' "HIMMEL-3${TAB}feat/h3${TAB}-${TAB}blocked${TAB}still red" > "$FIXED"
final=$(bash "$SCRIPT" reconcile --plan "$PLAN" --fixed "$FIXED" --rows-in "$ROWS" 2>/dev/null)
assert_contains "still-failing escalated" "auto-fix attempted, still failing — manual triage" "$final"

echo "TEST 13: dispatched branch absent from --fixed → did-not-return blocker"
printf '%s\n' "HIMMEL-99${TAB}feat/other${TAB}-${TAB}done${TAB}unrelated" > "$FIXED"
final=$(bash "$SCRIPT" reconcile --plan "$PLAN" --fixed "$FIXED" --rows-in "$ROWS" 2>/dev/null)
assert_contains "no-return surfaced" "fix subagent did not return — manual triage" "$final"

echo "TEST 14: empty plan → final == rows-in"
: > "$PLAN"
final=$(bash "$SCRIPT" reconcile --plan "$PLAN" --fixed "$FIXED" --rows-in "$ROWS" 2>/dev/null)
assert_contains "rows passthrough" "HIMMEL-1${TAB}feat/h1" "$final"
refute_contains "no reconciled rows added" "did not return" "$final"

echo "TEST 15: --fixed absent entirely → all dispatched branches escalate"
mkplan "HIMMEL-3${TAB}feat/h3${TAB}lint${TAB}fix it"
final=$(bash "$SCRIPT" reconcile --plan "$PLAN" --fixed "$TMP_ROOT/nope.tsv" --rows-in "$ROWS" 2>/dev/null)
assert_contains "missing fixed file → no-return blocker" "fix subagent did not return" "$final"

# === integration: EPIC-DONE swarm sim ====================================

echo "TEST 16: swarm sim (classify → reconcile → morning-report) — epic-done test"
ssroot="$TMP_ROOT/swarm"; mkdir -p "$ssroot"
sledger="$ssroot/ledger.tsv"; srows="$ssroot/rows.tsv"; splan="$ssroot/plan.tsv"
sfixed="$ssroot/fixed.tsv"; sfinal="$ssroot/final.tsv"
# (a) auto-fixable lint failure, (b) substantive failure, plus one clean done.
lf_a=$(mklog swarm_a "In tool.sh line 9: SC2086: Double quote to prevent globbing. shellcheck found 1 issue")
lf_b=$(mklog swarm_b "Subagent error: 3 unit tests failing; logic error needs rework")
printf '%s\n' \
    "HIMMEL-201${TAB}feat/HIMMEL-201-ok${TAB}https://pr/201${TAB}done${TAB}Shipped widget${TAB}" \
    "HIMMEL-202${TAB}feat/HIMMEL-202-lint${TAB}-${TAB}blocked${TAB}pre-commit failed${TAB}$lf_a" \
    "HIMMEL-203${TAB}fix/HIMMEL-203-logic${TAB}-${TAB}blocked${TAB}impl failed${TAB}$lf_b" \
    > "$sledger"
# Phase 1: classify.
csum=$(bash "$SCRIPT" classify --rows-in "$sledger" --rows-out "$srows" --dispatch-out "$splan" 2>&1)
assert_contains "classify summary: 1 done 1 sub 1 mech" "1 done, 1 substantive (triaged), 1 mechanical" "$csum"
assert_contains "lint branch dispatched" "feat/HIMMEL-202-lint${TAB}lint" "$(cat "$splan")"
assert_contains "substantive triaged in rows" "HIMMEL-203" "$(cat "$srows")"
refute_contains "lint NOT yet a row" "HIMMEL-202" "$(cat "$srows")"
# Phase 2: the parent dispatched a fresh fix subagent for the lint branch; it
# returns green. Model that re-collected result:
printf '%s\n' "HIMMEL-202${TAB}feat/HIMMEL-202-lint${TAB}https://pr/202${TAB}done${TAB}Lint auto-fixed, green" > "$sfixed"
bash "$SCRIPT" reconcile --plan "$splan" --fixed "$sfixed" --rows-in "$srows" --rows-out "$sfinal" 2>/dev/null
# Phase 3: feed the FINAL rows into the (unchanged) morning report.
hroot="$ssroot/handover"; mkdir -p "$hroot"
report=$(HANDOVER_DIR="$hroot" bash "$REPORT" --rows "$sfinal" --dry-run)
assert_contains "report: all 3 tickets" "**3 tickets**" "$report"
assert_contains "report: 1 decision needed" "decisions needed: **1**" "$report"
assert_contains "report: lint ticket auto-fixed green (done)" "HIMMEL-202" "$report"
assert_contains "report: lint shows done status" "Lint auto-fixed, green" "$report"
assert_contains "report: substantive is the decision" "**HIMMEL-203**" "$report"
assert_contains "report: done ticket present" "HIMMEL-201" "$report"
# Faithfulness: the substantive failure was NEVER auto-fixed.
refute_contains "substantive never got a fix spec" "HIMMEL-203${TAB}fix/HIMMEL-203-logic${TAB}" "$(cat "$splan")"

# === usage ===============================================================

echo "TEST 17: usage errors"
rc=0; out=$(bash "$SCRIPT" 2>&1) || rc=$?
case "$rc" in 1) pass "exit 1 on missing subcommand";; *) fail "want rc=1, got $rc" "$out";; esac
rc=0; out=$(bash "$SCRIPT" bogus 2>&1) || rc=$?
case "$rc" in 1) pass "exit 1 on unknown subcommand";; *) fail "want rc=1, got $rc" "$out";; esac
assert_contains "unknown-subcommand diagnostic" "unknown subcommand" "$out"
rc=0; out=$(bash "$SCRIPT" classify 2>&1) || rc=$?
case "$rc" in 1) pass "exit 1 when --rows-in missing";; *) fail "want rc=1, got $rc" "$out";; esac
rc=0; out=$(bash "$SCRIPT" reconcile --rows-in "$ROWS" 2>&1) || rc=$?
case "$rc" in 1) pass "exit 1 when --plan missing";; *) fail "want rc=1, got $rc" "$out";; esac

# === regression + precedence coverage (CR round) =========================

echo "TEST 18: word-boundary substantive signals survive on GNU grep (regression)"
# GNU sed drops the backslash in \b replacements; a buggy normalization made
# \bCONFLICT\b / \bcritical\b / \bCR\b...  into bCONFLICTb etc., which never
# match on GNU grep — silently auto-fixing a CR blocker. Pin all three.
lf=$(mklog conflict "CONFLICT (content): both modified foo.sh during the merge")
printf '%s\n' "HIMMEL-18a${TAB}fix/h18a${TAB}-${TAB}blocked${TAB}merge${TAB}$lf" > "$LEDGER"
bash "$SCRIPT" classify --rows-in "$LEDGER" --rows-out "$ROWS" --dispatch-out "$PLAN" 2>/dev/null
assert_contains "CONFLICT → substantive triage" "operator-gated blocker: substantive failure" "$(cat "$ROWS")"
if [ -s "$PLAN" ]; then fail "CONFLICT got an auto-fix spec (boundary bug)"; else pass "CONFLICT not auto-fixed"; fi
# The dangerous case: a CR blocker whose log ALSO mentions shellcheck.
lf=$(mklog crmix "CR finding: blocker in retry logic. (pre-commit also ran shellcheck SC2086)")
printf '%s\n' "HIMMEL-18b${TAB}fix/h18b${TAB}-${TAB}blocked${TAB}cr${TAB}$lf" > "$LEDGER"
bash "$SCRIPT" classify --rows-in "$LEDGER" --rows-out "$ROWS" --dispatch-out "$PLAN" 2>/dev/null
assert_contains "CR-finding+shellcheck → substantive (not auto-fixed)" "operator-gated blocker: substantive failure" "$(cat "$ROWS")"
if [ -s "$PLAN" ]; then fail "CR blocker with shellcheck text got auto-fixed (fail-safe defeated)"; else pass "CR blocker not auto-fixed despite shellcheck mention"; fi
# 'critical' is bounded — 'criticality' must NOT trip the substantive signal.
lf=$(mklog crit "shellcheck SC2034: criticality metric var unused")
printf '%s\n' "HIMMEL-18c${TAB}feat/h18c${TAB}-${TAB}blocked${TAB}lint${TAB}$lf" > "$LEDGER"
bash "$SCRIPT" classify --rows-in "$LEDGER" --rows-out "$ROWS" --dispatch-out "$PLAN" 2>/dev/null
assert_contains "'criticality' does not trip substantive (bounded)" "feat/h18c${TAB}lint" "$(cat "$PLAN")"

echo "TEST 19: multiple mechanical failures in one fanout → N dispatch specs"
lf1=$(mklog m1 "foo.sh SC2086 shellcheck finding")
lf2=$(mklog m2 "bar.sh: [BOM] byte-order mark at file start")
printf '%s\n' \
    "HIMMEL-19a${TAB}feat/h19a${TAB}-${TAB}blocked${TAB}f${TAB}$lf1" \
    "HIMMEL-19b${TAB}fix/h19b${TAB}-${TAB}blocked${TAB}f${TAB}$lf2" \
    > "$LEDGER"
sum=$(bash "$SCRIPT" classify --rows-in "$LEDGER" --rows-out "$ROWS" --dispatch-out "$PLAN" 2>&1 >/dev/null)
plan=$(cat "$PLAN")
assert_contains "first mechanical dispatched (lint)" "feat/h19a${TAB}lint" "$plan"
assert_contains "second mechanical dispatched (encoding)" "fix/h19b${TAB}encoding" "$plan"
assert_contains "summary counts 2 mechanical" "2 mechanical" "$sum"
n_specs=$(grep -c . "$PLAN")
if [ "$n_specs" -eq 2 ]; then pass "exactly 2 dispatch specs (append, not overwrite)"; else fail "want 2 specs, got $n_specs"; fi

echo "TEST 20: classification precedence ladder"
# encoding + lint (BOM + SC####) → encoding (more specific wins).
lf=$(mklog el "SC1082 byte-order mark; also SC2086 shellcheck note")
printf '%s\n' "HIMMEL-20a${TAB}feat/h20a${TAB}-${TAB}blocked${TAB}f${TAB}$lf" > "$LEDGER"
bash "$SCRIPT" classify --rows-in "$LEDGER" --rows-out "$ROWS" --dispatch-out "$PLAN" 2>/dev/null
assert_contains "encoding wins over lint" "feat/h20a${TAB}encoding" "$(cat "$PLAN")"
# encoding + substantive → substantive (substantive always wins).
lf=$(mklog es "byte-order mark found; AssertionError: 2 != 3 in tests")
printf '%s\n' "HIMMEL-20b${TAB}fix/h20b${TAB}-${TAB}blocked${TAB}f${TAB}$lf" > "$LEDGER"
bash "$SCRIPT" classify --rows-in "$LEDGER" --rows-out "$ROWS" --dispatch-out "$PLAN" 2>/dev/null
assert_contains "substantive wins over encoding" "operator-gated blocker: substantive failure" "$(cat "$ROWS")"
if [ -s "$PLAN" ]; then fail "encoding+substantive got auto-fixed (unsafe)"; else pass "encoding+substantive not auto-fixed"; fi

echo "TEST 21: reconcile — only 'done' is green; 'partial' escalates"
mkplan "HIMMEL-21${TAB}feat/h21${TAB}lint${TAB}fix it"
mkrows "HIMMEL-1${TAB}feat/h1${TAB}https://pr/1${TAB}done${TAB}Shipped"
FIXED="$TMP_ROOT/fixed.tsv"
printf '%s\n' "HIMMEL-21${TAB}feat/h21${TAB}-${TAB}partial${TAB}half-fixed" > "$FIXED"
final=$(bash "$SCRIPT" reconcile --plan "$PLAN" --fixed "$FIXED" --rows-in "$ROWS" 2>/dev/null)
assert_contains "partial fix → still-failing blocker" "auto-fix attempted, still failing" "$final"

echo "TEST 22: reconcile — orphan fix result (branch not in plan) warned on stderr"
mkplan "HIMMEL-21${TAB}feat/h21${TAB}lint${TAB}fix it"
printf '%s\n' \
    "HIMMEL-21${TAB}feat/h21${TAB}https://pr/21${TAB}done${TAB}fixed" \
    "HIMMEL-ZZ${TAB}feat/orphan${TAB}-${TAB}done${TAB}who dispatched this" \
    > "$FIXED"
err=$(bash "$SCRIPT" reconcile --plan "$PLAN" --fixed "$FIXED" --rows-in "$ROWS" --rows-out "$TMP_ROOT/f22.tsv" 2>&1 >/dev/null)
assert_contains "orphan fix result surfaced on stderr" "un-dispatched branch" "$err"
refute_contains "orphan not silently in the report" "feat/orphan" "$(cat "$TMP_ROOT/f22.tsv")"

echo "TEST 23: stray tab in OUTCOME on a non-done row still fails SAFE (triaged, not auto-fixed)"
# A literal tab in OUTCOME shifts the real LOGFILE; the row degrades to a
# 'no detail' triage rather than ever being auto-fixed — fail-safe holds.
lf=$(mklog st "SC2086 shellcheck")
printf '%s\n' "HIMMEL-23${TAB}feat/h23${TAB}-${TAB}blocked${TAB}oops${TAB}$lf" > "$LEDGER"
# inject a stray tab by rebuilding with OUTCOME containing a tab (NF becomes 7 -> rejected loudly)
printf '%s\n' "HIMMEL-23${TAB}feat/h23${TAB}-${TAB}blocked${TAB}part${TAB}one${TAB}$lf" > "$LEDGER"
rc=0; out=$(bash "$SCRIPT" classify --rows-in "$LEDGER" --rows-out "$ROWS" 2>&1) || rc=$?
case "$rc" in 1) pass "stray tab → loud reject (NF>6), never a silent auto-fix";; *) fail "want rc=1, got $rc" "$out";; esac

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
