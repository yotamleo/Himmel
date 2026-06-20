#!/usr/bin/env bash
# Smoke test for scripts/overnight/morning-report.sh (HIMMEL-258).
#
# Strategy: feed canned TSV rows via --rows / stdin; assert report
# structure, decisions-first ordering, and handover-path resolution.
#
# Covers:
#   1. Basic report shape: header, summary, decisions block, ticket table.
#   2. Decisions-first ordering: decision row sorts above done row;
#      blocked sorts above partial/done within no-decision group.
#   3. No decisions -> "_None" placeholder.
#   4. Default output path resolves via HANDOVER_DIR (Mode B,
#      handover-path.sh resolver) when --out is not passed.
#   5. Invalid status -> exit 1.
#   6. Too few fields -> exit 1.
#   7. Empty input -> exit 1.
#   8. --dry-run prints body, touches no file.
#   9. Pipe chars in fields are escaped in the table.
#  10. Too many fields (NF>6, e.g. literal tab inside OUTCOME) -> exit 1.
#  11. --rows / --out missing or empty value -> exit 1 + diagnostic.
#  12. Broken HANDOVER_DIR + no --out -> exit 2, no fallback write.
#  13. Mode A (HANDOVER_DIR unset, temp git repo): default path lands
#      under <repo>/handovers/.
#  14. Mode A --dry-run previews <repo>/handovers/ path (no placeholder)
#      and creates NO handovers/ dir.
#  15. Broken HANDOVER_DIR + --dry-run -> exit 2 (preview matches the
#      real run's fail-closed behavior), resolver diagnostic visible.
#  16. Empty KEY / empty BRANCH rows -> exit 1 + diagnostic.
#  17. CRLF row file -> parsed clean (no \r polluting the last field).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/morning-report.sh"

PASS=0
FAIL=0
TMP_ROOT=""

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
# Assert needle1 appears on an earlier line than needle2.
assert_before() {
    local name="$1" first="$2" second="$3" haystack="$4"
    local l1 l2
    l1=$(printf '%s\n' "$haystack" | grep -nF -- "$first"  | head -1 | cut -d: -f1 || true)
    l2=$(printf '%s\n' "$haystack" | grep -nF -- "$second" | head -1 | cut -d: -f1 || true)
    if [ -n "$l1" ] && [ -n "$l2" ] && [ "$l1" -lt "$l2" ]; then
        pass "$name"
    else
        fail "$name" "first='$first' line=${l1:-missing}, second='$second' line=${l2:-missing}"
    fi
}

TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi

ROWS="$TMP_ROOT/rows.tsv"

# Hermetic default root: tests that exercise default-path resolution (or
# could fall through to it) pin HANDOVER_DIR so results never depend on
# the repo this suite runs from.
hroot="$TMP_ROOT/handover-root"
mkdir -p "$hroot"

# Test 1+2: report shape + decisions-first ordering --------------------

echo "TEST: basic report shape + decisions-first ordering"
printf '%s\n' \
    $'HIMMEL-301\tfeat/HIMMEL-301-widget-a\thttps://example.com/pr/1\tdone\tShipped widget A' \
    $'HIMMEL-302\tfix/HIMMEL-302-broken-x\thttps://example.com/pr/2\tblocked\tMerge conflict vs main' \
    $'HIMMEL-303\tfeat/HIMMEL-303-widget-b\thttps://example.com/pr/3\tpartial\tTests red on CI\tPick retry vs revert' \
    > "$ROWS"
out=$(bash "$SCRIPT" --rows "$ROWS" --out "$TMP_ROOT/report.md")
report=$(cat "$TMP_ROOT/report.md")
assert_contains "header present"        "# Overnight shift report"     "$report"
assert_contains "summary counts"        "**3 tickets**: 1 done, 1 partial, 1 blocked — decisions needed: **1**." "$report"
assert_contains "decisions section"     "## Decisions needed (1)"      "$report"
assert_contains "decision item"         "**HIMMEL-303** — Pick retry vs revert" "$report"
assert_contains "tickets section"       "## Tickets (3)"               "$report"
assert_contains "table header"          "| Ticket | Branch | PR | Status | Outcome |" "$report"
assert_contains "done row"              $'| HIMMEL-301 | `feat/HIMMEL-301-widget-a` | https://example.com/pr/1 | done | Shipped widget A |' "$report"
assert_contains "wrote confirmation"    "morning-report: wrote"        "$out"
table=$(printf '%s\n' "$report" | sed -n '/## Tickets/,$p')
assert_before "decision row sorts first"   "HIMMEL-303" "HIMMEL-302" "$table"
assert_before "blocked sorts before done"  "HIMMEL-302" "HIMMEL-301" "$table"

# Test 3: no decisions -> placeholder ----------------------------------

echo "TEST: no decisions -> placeholder"
printf '%s\n' $'HIMMEL-310\tfeat/HIMMEL-310-thing\thttps://example.com/pr/9\tdone\tShipped' > "$ROWS"
report=$(HANDOVER_DIR="$hroot" bash "$SCRIPT" --rows "$ROWS" --dry-run)
assert_contains "zero-decision heading" "## Decisions needed (0)" "$report"
assert_contains "none placeholder"      "_None — no ticket needs a human decision._" "$report"

# Test 4: default path resolves via HANDOVER_DIR (Mode B) --------------

echo "TEST: default output path via handover-path resolver (Mode B)"
out=$(HANDOVER_DIR="$hroot" bash "$SCRIPT" --rows "$ROWS")
expected="$hroot/overnight-report-$(date -u +%F).md"
if [ -f "$expected" ]; then
    pass "report written under HANDOVER_DIR ($expected)"
else
    fail "default path not under HANDOVER_DIR" "out=$out"
fi

# Test 5: invalid status -> exit 1 -------------------------------------

echo "TEST: invalid status rejected"
printf '%s\n' $'HIMMEL-320\tfeat/x\tpr\tshipped\tOops' > "$ROWS"
rc=0
out=$(HANDOVER_DIR="$hroot" bash "$SCRIPT" --rows "$ROWS" --dry-run 2>&1) || rc=$?
case "$rc" in
    1) pass "exit 1 on invalid status" ;;
    *) fail "expected rc=1, got $rc" "$out" ;;
esac
assert_contains "status diagnostic" 'invalid status "shipped"' "$out"

# Test 6: too few fields -> exit 1 -------------------------------------

echo "TEST: too few fields rejected"
printf '%s\n' $'HIMMEL-321\tfeat/x\tdone' > "$ROWS"
rc=0
out=$(HANDOVER_DIR="$hroot" bash "$SCRIPT" --rows "$ROWS" --dry-run 2>&1) || rc=$?
case "$rc" in
    1) pass "exit 1 on missing columns" ;;
    *) fail "expected rc=1, got $rc" "$out" ;;
esac
assert_contains "field-count diagnostic" "expected >=5 tab-separated fields" "$out"

# Test 7: empty input -> exit 1 ----------------------------------------

echo "TEST: empty input rejected"
rc=0
out=$(bash "$SCRIPT" --dry-run </dev/null 2>&1) || rc=$?
case "$rc" in
    1) pass "exit 1 on empty input" ;;
    *) fail "expected rc=1, got $rc" "$out" ;;
esac

# Test 8: --dry-run touches no file ------------------------------------

echo "TEST: --dry-run prints body, writes nothing"
printf '%s\n' $'HIMMEL-330\tfeat/HIMMEL-330-dry\thttps://example.com/pr/4\tdone\tShipped dry' > "$ROWS"
dry_out_dir="$TMP_ROOT/dry-root"
mkdir -p "$dry_out_dir"
out=$(HANDOVER_DIR="$dry_out_dir" bash "$SCRIPT" --rows "$ROWS" --dry-run)
assert_contains "dry-run marker" "DRY morning-report: would write to" "$out"
assert_contains "dry-run body"   "HIMMEL-330"                         "$out"
if find "$dry_out_dir" -name 'overnight-report-*.md' | grep -q .; then
    fail "--dry-run wrote a file"
else
    pass "no file written under --dry-run"
fi

# Test 9: pipe chars escaped in table ----------------------------------

echo "TEST: pipe chars in outcome are escaped"
printf '%s\n' $'HIMMEL-340\tfeat/HIMMEL-340-pipes\thttps://example.com/pr/5\tdone\tA | B outcome' > "$ROWS"
report=$(HANDOVER_DIR="$hroot" bash "$SCRIPT" --rows "$ROWS" --dry-run)
assert_contains "escaped pipe" 'A \| B outcome' "$report"

# Test 10: too many fields (NF>6) -> exit 1 ----------------------------

echo "TEST: too many fields rejected (literal tab inside a field)"
printf '%s\n' $'HIMMEL-350\tfeat/x\tpr\tdone\tOutcome with\ttab\tDecision' > "$ROWS"
rc=0
out=$(HANDOVER_DIR="$hroot" bash "$SCRIPT" --rows "$ROWS" --dry-run 2>&1) || rc=$?
case "$rc" in
    1) pass "exit 1 on too many fields" ;;
    *) fail "expected rc=1, got $rc" "$out" ;;
esac
assert_contains "field-overflow diagnostic" "expected <=6 tab-separated fields, got 7" "$out"

# Test 11: --rows / --out missing or empty value -> exit 1 --------------

echo "TEST: --rows / --out missing or empty value rejected"
rc=0
out=$(bash "$SCRIPT" --rows 2>&1) || rc=$?
case "$rc" in
    1) pass "exit 1 on --rows as last arg" ;;
    *) fail "expected rc=1, got $rc" "$out" ;;
esac
assert_contains "--rows diagnostic" "--rows requires a FILE" "$out"
rc=0
out=$(bash "$SCRIPT" --rows "" 2>&1 </dev/null) || rc=$?
case "$rc" in
    1) pass "exit 1 on empty --rows value" ;;
    *) fail "expected rc=1, got $rc" "$out" ;;
esac
rc=0
out=$(bash "$SCRIPT" --out 2>&1 </dev/null) || rc=$?
case "$rc" in
    1) pass "exit 1 on --out as last arg" ;;
    *) fail "expected rc=1, got $rc" "$out" ;;
esac
assert_contains "--out diagnostic" "--out requires a PATH" "$out"

# Test 12: broken HANDOVER_DIR -> exit 2, no fallback -------------------

echo "TEST: broken HANDOVER_DIR fails closed (exit 2)"
printf '%s\n' $'HIMMEL-360\tfeat/HIMMEL-360-x\thttps://example.com/pr/6\tdone\tShipped' > "$ROWS"
rc=0
out=$(HANDOVER_DIR="$TMP_ROOT/does-not-exist" bash "$SCRIPT" --rows "$ROWS" 2>&1) || rc=$?
case "$rc" in
    2) pass "exit 2 on unusable HANDOVER_DIR" ;;
    *) fail "expected rc=2, got $rc" "$out" ;;
esac
assert_contains "fail-closed diagnostic" "fix HANDOVER_DIR or pass --out" "$out"
if printf '%s' "$out" | grep -qi "falling back"; then
    fail "broken HANDOVER_DIR fell back instead of failing closed" "$out"
else
    pass "no fallback on broken HANDOVER_DIR"
fi

# Test 13: Mode A default path lands under <repo>/handovers/ ------------

echo "TEST: Mode A (HANDOVER_DIR unset) default path under <repo>/handovers/"
repo_a="$TMP_ROOT/mode-a-repo"
mkdir -p "$repo_a"
git -C "$repo_a" init -q
printf '%s\n' $'HIMMEL-370\tfeat/HIMMEL-370-a\thttps://example.com/pr/7\tdone\tShipped A' > "$ROWS"
out=$(cd "$repo_a" && env -u HANDOVER_DIR bash "$SCRIPT" --rows "$ROWS")
expected_a="$repo_a/handovers/overnight-report-$(date -u +%F).md"
if [ -f "$expected_a" ]; then
    pass "Mode A report written under <repo>/handovers/"
else
    fail "Mode A default path missing ($expected_a)" "out=$out"
fi

# Test 14: Mode A --dry-run previews real path, creates NO handovers/ ---

echo "TEST: Mode A --dry-run previews <repo>/handovers/ path, creates nothing"
repo_dry="$TMP_ROOT/mode-a-dry-repo"
mkdir -p "$repo_dry"
git -C "$repo_dry" init -q
out=$(cd "$repo_dry" && env -u HANDOVER_DIR bash "$SCRIPT" --rows "$ROWS" --dry-run)
assert_contains "dry-run still prints body" "HIMMEL-370" "$out"
assert_contains "previews real <repo>/handovers/ path" "mode-a-dry-repo/handovers/overnight-report-" "$out"
if printf '%s' "$out" | grep -qF '<unresolved-handover-root>'; then
    fail "Mode A --dry-run printed the placeholder instead of the real path" "$out"
else
    pass "no placeholder in Mode A --dry-run preview"
fi
if [ -d "$repo_dry/handovers" ]; then
    fail "Mode A --dry-run created handovers/"
else
    pass "no handovers/ dir created under Mode A --dry-run"
fi

# Test 15: broken HANDOVER_DIR + --dry-run -> exit 2 ---------------------

echo "TEST: broken HANDOVER_DIR + --dry-run fails closed (exit 2)"
printf '%s\n' $'HIMMEL-371\tfeat/HIMMEL-371-x\thttps://example.com/pr/8\tdone\tShipped' > "$ROWS"
rc=0
out=$(HANDOVER_DIR="$TMP_ROOT/does-not-exist" bash "$SCRIPT" --rows "$ROWS" --dry-run 2>&1) || rc=$?
case "$rc" in
    2) pass "exit 2 on unusable HANDOVER_DIR under --dry-run" ;;
    *) fail "expected rc=2, got $rc" "$out" ;;
esac
assert_contains "fail-closed diagnostic (dry-run)" "fix HANDOVER_DIR or pass --out" "$out"
assert_contains "resolver diagnostic not suppressed" "is not a directory" "$out"

# Test 16: empty KEY / empty BRANCH rows -> exit 1 -----------------------

echo "TEST: empty KEY / empty BRANCH rows rejected"
printf '%s\n' $'\tfeat/HIMMEL-372-x\thttps://example.com/pr/9\tdone\tShipped' > "$ROWS"
rc=0
out=$(HANDOVER_DIR="$hroot" bash "$SCRIPT" --rows "$ROWS" --dry-run 2>&1) || rc=$?
case "$rc" in
    1) pass "exit 1 on empty KEY" ;;
    *) fail "expected rc=1, got $rc" "$out" ;;
esac
assert_contains "empty-KEY diagnostic" "empty KEY field" "$out"
printf '%s\n' $'HIMMEL-373\t\thttps://example.com/pr/10\tdone\tShipped' > "$ROWS"
rc=0
out=$(HANDOVER_DIR="$hroot" bash "$SCRIPT" --rows "$ROWS" --dry-run 2>&1) || rc=$?
case "$rc" in
    1) pass "exit 1 on empty BRANCH" ;;
    *) fail "expected rc=1, got $rc" "$out" ;;
esac
assert_contains "empty-BRANCH diagnostic" "empty BRANCH field" "$out"

# Test 17: CRLF row file -> parsed clean ---------------------------------

echo "TEST: CRLF row file parsed clean"
printf 'HIMMEL-374\tfeat/HIMMEL-374-crlf\thttps://example.com/pr/11\tdone\tShipped CRLF\r\n' > "$ROWS"
report=$(HANDOVER_DIR="$hroot" bash "$SCRIPT" --rows "$ROWS" --dry-run)
assert_contains "CRLF row renders clean last field" '| done | Shipped CRLF |' "$report"
if printf '%s' "$report" | grep -q $'\r'; then
    fail "report output contains a stray CR"
else
    pass "no CR chars leak into the report"
fi

# Test 18: standing operator actions appended from --actions -------------

echo "TEST: standing operator actions appended (verbatim, after tickets)"
printf '%s\n' $'HIMMEL-380\tfeat/HIMMEL-380-x\thttps://example.com/pr/12\tdone\tShipped' > "$ROWS"
acts="$TMP_ROOT/operator-actions.md"
printf '🔴 SINGLE-SESSION-ONLY:\n- Run the leak history rewrite.\n' > "$acts"
report=$(HANDOVER_DIR="$hroot" bash "$SCRIPT" --rows "$ROWS" --actions "$acts" --dry-run)
assert_contains "standing-actions heading" "## Standing operator actions" "$report"
assert_contains "standing-actions content" "Run the leak history rewrite." "$report"
assert_before "tickets before standing actions" "## Tickets" "## Standing operator actions" "$report"

# Test 19: blank/whitespace-only actions file -> no section --------------

echo "TEST: blank actions file -> no standing-actions section"
printf '   \n\n' > "$acts"
report=$(HANDOVER_DIR="$hroot" bash "$SCRIPT" --rows "$ROWS" --actions "$acts" --dry-run)
if printf '%s' "$report" | grep -qF "## Standing operator actions"; then
    fail "blank actions file produced a section"
else
    pass "blank actions file -> no section"
fi

# Test 20: --actions missing value -> exit 1 ----------------------------

echo "TEST: --actions missing value rejected"
rc=0
out=$(bash "$SCRIPT" --actions 2>&1 </dev/null) || rc=$?
case "$rc" in
    1) pass "exit 1 on --actions as last arg" ;;
    *) fail "expected rc=1, got $rc" "$out" ;;
esac
assert_contains "--actions diagnostic" "--actions requires a FILE" "$out"

# Test 21: default actions path resolves next to OUT_FILE ----------------

echo "TEST: default actions path = <dirname OUT_FILE>/operator-actions.md"
out_dir="$TMP_ROOT/acts-default"
mkdir -p "$out_dir"
printf '%s\n' $'HIMMEL-381\tfeat/HIMMEL-381-y\thttps://example.com/pr/13\tdone\tShipped' > "$ROWS"
printf -- '- Default-path standing action.\n' > "$out_dir/operator-actions.md"
report=$(bash "$SCRIPT" --rows "$ROWS" --out "$out_dir/report.md" --dry-run)
assert_contains "default actions path picked up" "Default-path standing action." "$report"

# Test 22: actions body is appended VERBATIM (not pipe-escaped) ----------
# Locks the verbatim contract so a future "let's escape it" refactor breaks here.

echo "TEST: actions body appended verbatim (markdown/pipes un-escaped)"
printf -- '- Action with a | pipe and **bold**.\n' > "$acts"
printf '%s\n' $'HIMMEL-382\tfeat/HIMMEL-382-z\thttps://example.com/pr/14\tdone\tShipped' > "$ROWS"
report=$(HANDOVER_DIR="$hroot" bash "$SCRIPT" --rows "$ROWS" --actions "$acts" --dry-run)
assert_contains "actions body verbatim (pipe un-escaped)" "Action with a | pipe and **bold**." "$report"

# Summary --------------------------------------------------------------

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
