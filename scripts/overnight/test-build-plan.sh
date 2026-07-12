#!/usr/bin/env bash
# Smoke test for scripts/overnight/build-plan.sh (HIMMEL-134).
#
# Strategy: replace JIRA_CMD with a fake that emits canned TSV; assert
# the plan structure + content.
#
# Covers:
#   1. Default filter produces well-formed plan with N tickets.
#   2. --limit clamps the listed count.
#   3. Epics are marked SKIP, non-epics get worktree + subagent rows.
#   4. No tickets matched -> exit 3 + helpful message.
#   5. --out PATH writes plan to file AND stdout (idempotent).
#   6. Invalid --limit rejected (exit 1).
#   7. Slug derivation: special chars + length cap.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/build-plan.sh"

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
assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then fail "$name" "unexpected: $needle"; else pass "$name"; fi
}

REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
PROVISION_REAL="node $REPO_ROOT/scripts/where-are-we/provision.mjs"

TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi

# Fake jira CLI: prints canned TSV based on env vars.
FAKE_JIRA="$TMP_ROOT/jira-fake.sh"
cat >"$FAKE_JIRA" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
    list)
        # FAKE_JIRA_OUT is a multi-line string already in TSV form.
        printf '%s\n' "${FAKE_JIRA_OUT:-}"
        ;;
    *) exit 0 ;;
esac
FAKE
chmod +x "$FAKE_JIRA"

# Test 1: default plan shape ------------------------------------------

echo "TEST: default plan shape with 3 tickets"
plan=$(JIRA_CMD="$FAKE_JIRA" FAKE_JIRA_OUT=$'HIMMEL-101\tTask\tTo Do\tWidget A
HIMMEL-102\tStory\tIn Progress\tWidget B
HIMMEL-103\tBug\tTo Do\tBroken X' bash "$SCRIPT" --project HIMMEL --limit 3)
assert_contains "header present"      "# Overnight shift plan"  "$plan"
assert_contains "filter section"      "## Filter"               "$plan"
assert_contains "tickets section"     "## Tickets"              "$plan"
assert_contains "dispatch tree"       "## Dispatch tree"        "$plan"
assert_contains "after section"       "## After all subagents"  "$plan"
assert_contains "morning report step" "morning-report.sh"       "$plan"
assert_contains "ticket 1 HIMMEL-101" "HIMMEL-101"              "$plan"
assert_contains "ticket 2 HIMMEL-102" "HIMMEL-102"              "$plan"
assert_contains "ticket 3 HIMMEL-103" "HIMMEL-103"              "$plan"
assert_contains "bug -> fix worktree" "worktree: \`fix/HIMMEL-103-broken-x\`" "$plan"
assert_contains "story -> feat"       "worktree: \`feat/HIMMEL-102-widget-b\`" "$plan"

# Test 2: --limit truncates -------------------------------------------

echo "TEST: --limit shows in filter block"
plan=$(JIRA_CMD="$FAKE_JIRA" FAKE_JIRA_OUT=$'HIMMEL-1\tTask\tTo Do\tOne' bash "$SCRIPT" --limit 1)
assert_contains "limit echoed"     "limit: \`1\`"   "$plan"

# Test 3: Epic gets SKIP ----------------------------------------------

echo "TEST: Epic is marked SKIP"
plan=$(JIRA_CMD="$FAKE_JIRA" FAKE_JIRA_OUT=$'HIMMEL-200\tEpic\tIn Progress\tBig effort' bash "$SCRIPT")
assert_contains "epic mentioned"   "HIMMEL-200"     "$plan"
assert_contains "epic marked SKIP" "SKIP"           "$plan"

# Test 4: no tickets -> exit 3 ----------------------------------------

echo "TEST: empty result exits 3"
rc=0
out=$(JIRA_CMD="$FAKE_JIRA" FAKE_JIRA_OUT="" bash "$SCRIPT") || rc=$?
case "$rc" in
    3) pass "exit 3 on empty match" ;;
    *) fail "expected rc=3, got $rc" "out=$out" ;;
esac
assert_contains "empty result has heading" "Overnight shift plan" "$out"
assert_contains "empty result hint"        "No tickets matched"   "$out"

# Test 5: --out writes to file ----------------------------------------

echo "TEST: --out writes file in addition to stdout"
out_file="$TMP_ROOT/plan.md"
plan=$(JIRA_CMD="$FAKE_JIRA" FAKE_JIRA_OUT=$'HIMMEL-9\tTask\tTo Do\tThing' bash "$SCRIPT" --out "$out_file")
if [ -f "$out_file" ]; then
    pass "file written at $out_file"
else
    fail "--out did not write file"
fi
file_content=$(cat "$out_file" 2>/dev/null || true)
assert_contains "file content has HIMMEL-9" "HIMMEL-9" "$file_content"
assert_contains "stdout still has plan"     "HIMMEL-9" "$plan"

# Test 6: invalid --limit -> exit 1 -----------------------------------

echo "TEST: invalid --limit rejected"
rc=0
out=$(JIRA_CMD="$FAKE_JIRA" FAKE_JIRA_OUT=$'HIMMEL-1\tTask\tTo Do\tA' bash "$SCRIPT" --limit foo 2>&1) || rc=$?
case "$rc" in
    1) pass "exit 1 on non-numeric --limit" ;;
    *) fail "expected rc=1, got $rc" "$out" ;;
esac

# Test 7: slug normalisation ------------------------------------------

echo "TEST: slug strips special chars + caps at 30"
plan=$(JIRA_CMD="$FAKE_JIRA" FAKE_JIRA_OUT=$'HIMMEL-77\tTask\tTo Do\t Lots Of !!! Special @ Characters & More & Even MORE Padding Here' bash "$SCRIPT")
# Expected slug: lots-of-special-characters-mo (30 chars, trailing dash trimmed)
assert_contains "slug applied" "feat/HIMMEL-77-lots-of-special-characters" "$plan"
# Confirm no `!` or `@` leaked into the worktree slug specifically
# (the original title is shown verbatim in the heading row — only the
# slug needs to be clean).
slug_line=$(printf '%s' "$plan" | grep 'worktree: `feat/HIMMEL-77')
if printf '%s' "$slug_line" | grep -q '[!@]'; then
    fail "special chars in worktree slug" "$slug_line"
else
    pass "no special chars in worktree slug"
fi

# Test 8: empty-title fallback ---------------------------------------

echo "TEST: empty title falls back to 'ticket' slug"
plan=$(JIRA_CMD="$FAKE_JIRA" FAKE_JIRA_OUT=$'HIMMEL-50\tTask\tTo Do\t' bash "$SCRIPT")
assert_contains "empty title slug uses fallback" "feat/HIMMEL-50-ticket" "$plan"

# Test 9: L3 push-side provisioning — seeded ledger embeds the slice ---
# (HIMMEL-517). A substantive record for HIMMEL-101 → the plan gains a
# "prior ledger state:" block with that ticket's card.

echo "TEST: seeded ledger embeds the prior slice in the subagent prompt"
L3_LEDGER="$TMP_ROOT/wa-ledger.jsonl"
{
    printf '%s\n' '{"ts":"2026-06-22T10:00:00Z","source":"jira","key":"HIMMEL-101","kind":"ticket","status":"in-progress"}'
    printf '%s\n' '{"ts":"2026-06-22T10:05:00Z","source":"handover","key":"HIMMEL-101","kind":"ticket","next_action":"write the dock tests"}'
} >"$L3_LEDGER"
plan=$(JIRA_CMD="$FAKE_JIRA" FAKE_JIRA_OUT=$'HIMMEL-101\tTask\tTo Do\tWidget A
HIMMEL-102\tStory\tIn Progress\tWidget B' \
    WHERE_ARE_WE_LEDGER="$L3_LEDGER" PROVISION_CMD="$PROVISION_REAL" \
    bash "$SCRIPT" --project HIMMEL --limit 2)
assert_contains "provisioning block present"   "prior ledger state:"        "$plan"
assert_contains "slice shows the ticket card"  "# HIMMEL-101"               "$plan"
assert_contains "slice shows the next_action"  "- next: write the dock tests" "$plan"
# HIMMEL-102 has no ledger record → no slice block for it (miss is silent).

# Test 10: no ledger -> no provisioning block (fail-open, plan unchanged) ---

echo "TEST: absent ledger emits no provisioning block"
plan=$(JIRA_CMD="$FAKE_JIRA" FAKE_JIRA_OUT=$'HIMMEL-101\tTask\tTo Do\tWidget A' \
    WHERE_ARE_WE_LEDGER="$TMP_ROOT/does-not-exist.jsonl" PROVISION_CMD="$PROVISION_REAL" \
    bash "$SCRIPT" --project HIMMEL --limit 1)
assert_contains     "plan still builds"            "HIMMEL-101"          "$plan"
assert_not_contains "no provisioning block w/o ledger" "prior ledger state:" "$plan"

# Summary --------------------------------------------------------------

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
