#!/usr/bin/env bash
# Tests for scripts/handover/breadcrumb.sh (HIMMEL-477, C3).
#
# Hermetic: every test pins HANDOVER_DIR to a temp root and operates on a temp
# git repo — never touches real handover state or the live repo (standing rule).
#
# Covers:
#   write
#     1.  auto-detect branch/head/base from git → breadcrumb JSON written.
#     2.  explicit flags + --completed (multi) → fields round-trip.
#     3.  --out override path.
#     4.  missing --ticket → exit 1.
#   resolve
#     5.  FRESH: head_sha == current HEAD → exit 0, deterministic NEXT STEP.
#     6.  MISSING breadcrumb → exit 3, DEGRADED, reconstruct from git + jira.
#     7.  STALE: repo advanced (HEAD moved) → exit 3, DEGRADED, head-mismatch.
#     8.  STALE: branch diverged → exit 3, DEGRADED, branch-mismatch.
#     9.  CORRUPT breadcrumb → exit 3, DEGRADED corrupt.
#    10.  ticket derived from branch when --ticket omitted.
#    11.  --jira-cmd stub enriches; --no-jira skips; jira failure → git-only.
#    12.  never silently degrades to raw repo state (degraded ALWAYS flags + exit 3).
#   epic-done resume self-test
#    13.  deleted breadcrumb → flagged recovery; valid breadcrumb → deterministic.
#   usage
#    14.  missing/unknown subcommand → exit 1.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/breadcrumb.sh"

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

TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi

HROOT="$TMP_ROOT/handover"; mkdir -p "$HROOT"
export HANDOVER_DIR="$HROOT"

# Temp git repo with a commit naming the ticket, on a ticket branch.
REPO="$TMP_ROOT/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@e.x
git -C "$REPO" config user.name tester
printf 'seed\n' > "$REPO/a.txt"; git -C "$REPO" add a.txt
git -C "$REPO" commit -qm "chore: seed"
git -C "$REPO" checkout -q -b feat/himmel-477-resolver
printf 'work\n' > "$REPO/b.txt"; git -C "$REPO" add b.txt
git -C "$REPO" commit -qm "feat: [HIMMEL-477] resume resolver wip"
HEAD1=$(git -C "$REPO" rev-parse HEAD)

# Jira stub: prints a canned line for `get HIMMEL-477`.
JSTUB="$TMP_ROOT/jira-stub.sh"
cat > "$JSTUB" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "get" ]; then
  echo "$2	Story	In Progress	C3: Durable handover/resume resolver"
fi
STUB
chmod +x "$JSTUB"
JCMD="bash \"$JSTUB\""

BC="$HROOT/breadcrumbs/HIMMEL-477.json"

# === write ===============================================================

echo "TEST 1: write auto-detects git facts"
out=$(bash "$SCRIPT" write --ticket HIMMEL-477 --cwd "$REPO" --next-step "run /pr-check" 2>&1)
assert_contains "write reports path" "breadcrumbs/HIMMEL-477.json" "$out"
if [ -f "$BC" ]; then pass "breadcrumb file created"; else fail "breadcrumb not created"; fi
body=$(cat "$BC")
assert_contains "records branch" '"branch": "feat/himmel-477-resolver"' "$body"
assert_contains "records head_sha" "$HEAD1" "$body"
assert_contains "records next_step" '"next_step": "run /pr-check"' "$body"
assert_contains "versioned" '"version": 1' "$body"

echo "TEST 2: explicit flags + multi --completed round-trip"
bash "$SCRIPT" write --ticket HIMMEL-477 --cwd "$REPO" \
    --branch feat/x --head-sha deadbeef --base-sha cafe \
    --completed "dispatched A" --completed "dispatched B" \
    --next-step "merge" >/dev/null 2>&1
body=$(cat "$BC")
assert_contains "explicit branch" '"branch": "feat/x"' "$body"
assert_contains "completed A" "dispatched A" "$body"
assert_contains "completed B" "dispatched B" "$body"

echo "TEST 3: --out override"
alt="$TMP_ROOT/alt.json"
bash "$SCRIPT" write --ticket HIMMEL-477 --cwd "$REPO" --out "$alt" --next-step "x" >/dev/null 2>&1
if [ -f "$alt" ]; then pass "--out path honored"; else fail "--out not honored"; fi

echo "TEST 4: missing --ticket → exit 1"
rc=0; out=$(bash "$SCRIPT" write --cwd "$REPO" 2>&1) || rc=$?
case "$rc" in 1) pass "exit 1 without --ticket";; *) fail "want rc=1, got $rc" "$out";; esac

# Re-establish a clean valid breadcrumb at HEAD1 for resolve tests.
bash "$SCRIPT" write --ticket HIMMEL-477 --cwd "$REPO" --next-step "run /pr-check" \
    --completed "built self-heal" >/dev/null 2>&1

# === resolve =============================================================

echo "TEST 5: FRESH — head matches → deterministic resume (exit 0)"
rc=0; out=$(bash "$SCRIPT" resolve --ticket HIMMEL-477 --cwd "$REPO" --no-jira 2>&1) || rc=$?
case "$rc" in 0) pass "exit 0 on fresh breadcrumb";; *) fail "want rc=0, got $rc" "$out";; esac
assert_contains "fresh status" "STATUS: FRESH" "$out"
assert_contains "fresh prints NEXT STEP" "NEXT STEP: run /pr-check" "$out"
assert_contains "fresh deterministic note" "resume is deterministic" "$out"

echo "TEST 6: MISSING breadcrumb → DEGRADED, reconstruct from git + jira (exit 3)"
rm -f "$BC"
rc=0; out=$(bash "$SCRIPT" resolve --ticket HIMMEL-477 --cwd "$REPO" --jira-cmd "$JCMD" 2>&1) || rc=$?
case "$rc" in 3) pass "exit 3 on missing breadcrumb";; *) fail "want rc=3, got $rc" "$out";; esac
assert_contains "degraded status" "STATUS: DEGRADED" "$out"
assert_contains "missing reason" "breadcrumb missing" "$out"
assert_contains "confirm-before-proceeding flag" "confirm before proceeding" "$out"
assert_contains "git reconstruction (commit naming ticket)" "resume resolver wip" "$out"
assert_contains "jira enrichment via stub" "C3: Durable handover/resume resolver" "$out"
assert_contains "explicitly NOT silent" "did NOT silently degrade" "$out"

echo "TEST 7: STALE — repo advanced (HEAD moved) → DEGRADED (exit 3)"
bash "$SCRIPT" write --ticket HIMMEL-477 --cwd "$REPO" --next-step "old step" >/dev/null 2>&1
printf 'more\n' > "$REPO/c.txt"; git -C "$REPO" add c.txt
git -C "$REPO" commit -qm "feat: [HIMMEL-477] more work"
rc=0; out=$(bash "$SCRIPT" resolve --ticket HIMMEL-477 --cwd "$REPO" --no-jira 2>&1) || rc=$?
case "$rc" in 3) pass "exit 3 on stale breadcrumb";; *) fail "want rc=3, got $rc" "$out";; esac
assert_contains "stale reason (head mismatch)" "stale — breadcrumb head" "$out"
assert_contains "stale still surfaces recorded next step" "old step" "$out"

echo "TEST 8: STALE — branch diverged → DEGRADED (exit 3)"
# breadcrumb on this branch but resolve from a different branch HEAD that still
# carries the ticket-derived lookup. Write a breadcrumb at the CURRENT head, then
# checkout a different branch with the same HEAD content but different name.
HEADX=$(git -C "$REPO" rev-parse HEAD)
bash "$SCRIPT" write --ticket HIMMEL-477 --cwd "$REPO" --branch feat/himmel-477-resolver --head-sha "$HEADX" --next-step "s" >/dev/null 2>&1
git -C "$REPO" checkout -q -b feat/himmel-477-other
rc=0; out=$(bash "$SCRIPT" resolve --ticket HIMMEL-477 --cwd "$REPO" --no-jira 2>&1) || rc=$?
case "$rc" in 3) pass "exit 3 on branch divergence";; *) fail "want rc=3, got $rc" "$out";; esac
assert_contains "branch-mismatch reason" "!= current branch" "$out"
git -C "$REPO" checkout -q feat/himmel-477-resolver

echo "TEST 9: CORRUPT breadcrumb → DEGRADED (exit 3)"
printf '{ not valid json' > "$BC"
rc=0; out=$(bash "$SCRIPT" resolve --ticket HIMMEL-477 --cwd "$REPO" --no-jira 2>&1) || rc=$?
case "$rc" in 3) pass "exit 3 on corrupt breadcrumb";; *) fail "want rc=3, got $rc" "$out";; esac
assert_contains "corrupt reason" "breadcrumb corrupt" "$out"

echo "TEST 10: ticket derived from branch when --ticket omitted"
rm -f "$BC"
rc=0; out=$(bash "$SCRIPT" resolve --cwd "$REPO" --no-jira 2>&1) || rc=$?
assert_contains "derived ticket HIMMEL-477" "resume resolver: HIMMEL-477" "$out"

echo "TEST 11: jira modes — stub / --no-jira / failure"
# stub enriches
out=$(bash "$SCRIPT" resolve --ticket HIMMEL-477 --cwd "$REPO" --jira-cmd "$JCMD" 2>&1 || true)
assert_contains "jira stub line present" "C3: Durable handover/resume resolver" "$out"
# --no-jira skips
out=$(bash "$SCRIPT" resolve --ticket HIMMEL-477 --cwd "$REPO" --no-jira 2>&1 || true)
assert_contains "no-jira note" "skipped — --no-jira" "$out"
# failing jira-cmd → git-only, no crash
out=$(bash "$SCRIPT" resolve --ticket HIMMEL-477 --cwd "$REPO" --jira-cmd "bash \"$TMP_ROOT/nope.sh\"" 2>&1 || true)
assert_contains "jira failure degrades to git-only" "jira lookup failed" "$out"

echo "TEST 12: degraded NEVER silently degrades (flag + exit 3 are coupled)"
rm -f "$BC"
rc=0; out=$(bash "$SCRIPT" resolve --ticket HIMMEL-477 --cwd "$REPO" --no-jira 2>&1) || rc=$?
if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -qF "DEGRADED — confirm before proceeding"; then
    pass "degraded couples exit 3 + explicit flag"
else
    fail "degraded did not couple flag+exit3 (rc=$rc)" "$out"
fi

# === epic-done resume self-test ==========================================

echo "TEST 13: EPIC-DONE resume self-test (deleted → flagged recovery; valid → deterministic)"
# (a) valid breadcrumb at current HEAD → deterministic.
HEADV=$(git -C "$REPO" rev-parse HEAD)
bash "$SCRIPT" write --ticket HIMMEL-477 --cwd "$REPO" --head-sha "$HEADV" \
    --branch feat/himmel-477-resolver --next-step "open the PR" --completed "CR clean" >/dev/null 2>&1
rc=0; out=$(bash "$SCRIPT" resolve --ticket HIMMEL-477 --cwd "$REPO" --no-jira 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF "NEXT STEP: open the PR"; then
    pass "valid breadcrumb → deterministic resume (exit 0)"
else
    fail "valid breadcrumb not deterministic (rc=$rc)" "$out"
fi
# (b) delete it → resolver reconstructs + flags degraded (never silent).
rm -f "$BC"
rc=0; out=$(bash "$SCRIPT" resolve --ticket HIMMEL-477 --cwd "$REPO" --jira-cmd "$JCMD" 2>&1) || rc=$?
if [ "$rc" -eq 3 ] \
   && printf '%s' "$out" | grep -qF "DEGRADED" \
   && printf '%s' "$out" | grep -qF "RECONSTRUCTED" \
   && printf '%s' "$out" | grep -qF "HIMMEL-477"; then
    pass "deleted breadcrumb → flagged recovery from git+jira (exit 3)"
else
    fail "deleted breadcrumb recovery not flagged (rc=$rc)" "$out"
fi

# === CR round regressions ================================================

echo "TEST 15: FRESH must be POSITIVELY verified — empty current HEAD degrades"
# A valid breadcrumb but resolve from a NON-git cwd → cur_head empty → must NOT
# be blessed FRESH (the silent-degrade the ticket exists to prevent).
HEADN=$(git -C "$REPO" rev-parse HEAD)
bash "$SCRIPT" write --ticket HIMMEL-477 --cwd "$REPO" --head-sha "$HEADN" \
    --branch feat/himmel-477-resolver --next-step "go" >/dev/null 2>&1
nogit="$TMP_ROOT/nogit"; mkdir -p "$nogit"
rc=0; out=$(bash "$SCRIPT" resolve --ticket HIMMEL-477 --cwd "$nogit" --no-jira 2>&1) || rc=$?
case "$rc" in 3) pass "empty current HEAD → DEGRADED (exit 3)";; *) fail "want rc=3, got $rc" "$out";; esac
assert_contains "reason names unverifiable HEAD" "cannot read current HEAD" "$out"
refute_contains "did NOT falsely claim deterministic" "resume is deterministic" "$out"

echo "TEST 16: parseable-but-incomplete breadcrumb (no head_sha) degrades"
printf '{"branch":"feat/himmel-477-resolver","next_step":"go"}\n' > "$BC"
rc=0; out=$(bash "$SCRIPT" resolve --ticket HIMMEL-477 --cwd "$REPO" --no-jira 2>&1) || rc=$?
case "$rc" in 3) pass "no-head_sha breadcrumb → DEGRADED";; *) fail "want rc=3, got $rc" "$out";; esac
assert_contains "incomplete reason" "no head_sha" "$out"

echo "TEST 17: non-object JSON ([] / bare string) → DEGRADED corrupt"
printf '[]\n' > "$BC"
rc=0; out=$(bash "$SCRIPT" resolve --ticket HIMMEL-477 --cwd "$REPO" --no-jira 2>&1) || rc=$?
case "$rc" in 3) pass "array breadcrumb → DEGRADED";; *) fail "want rc=3, got $rc" "$out";; esac
assert_contains "non-object → corrupt" "breadcrumb corrupt" "$out"
printf '"just a string"\n' > "$BC"
rc=0; out=$(bash "$SCRIPT" resolve --ticket HIMMEL-477 --cwd "$REPO" --no-jira 2>&1) || rc=$?
case "$rc" in 3) pass "string breadcrumb → DEGRADED";; *) fail "want rc=3, got $rc" "$out";; esac

echo "TEST 18: invalid --ticket rejected (path traversal / empty filename guard)"
rc=0; out=$(bash "$SCRIPT" write --ticket "../../etc/x" --cwd "$REPO" 2>&1) || rc=$?
case "$rc" in 1) pass "write rejects path-traversal ticket";; *) fail "want rc=1, got $rc" "$out";; esac
rc=0; out=$(bash "$SCRIPT" resolve --ticket "bad ticket" --cwd "$REPO" --no-jira 2>&1) || rc=$?
case "$rc" in 1) pass "resolve rejects malformed ticket";; *) fail "want rc=1, got $rc" "$out";; esac

echo "TEST 19: glob chars in a field are NOT expanded (set -f around the split)"
# next_step is a literal "*"; resolve's field-split runs in the process cwd, so
# without set -f the "*" would expand to that dir's entries. Run from a dir with
# a sentinel file and assert the "*" survives verbatim.
bash "$SCRIPT" write --ticket HIMMEL-477 --cwd "$REPO" --head-sha "$HEADN" \
    --branch feat/himmel-477-resolver --next-step "*" >/dev/null 2>&1
globdir="$TMP_ROOT/globdir"; mkdir -p "$globdir"; : > "$globdir/sentinel-file"
out=$(cd "$globdir" && bash "$SCRIPT" resolve --ticket HIMMEL-477 --cwd "$REPO" --no-jira 2>&1) || true
assert_contains "glob '*' kept literal in NEXT STEP" "NEXT STEP: *" "$out"
refute_contains "glob did NOT expand to a filename" "sentinel-file" "$out"

echo "TEST 20: atomic write leaves no .tmp artifact"
bash "$SCRIPT" write --ticket HIMMEL-477 --cwd "$REPO" --next-step "x" >/dev/null 2>&1
if find "$HROOT/breadcrumbs" -name '*.tmp.*' 2>/dev/null | grep -q .; then
    fail "write left a .tmp.* artifact"
else
    pass "no .tmp.* leftover after atomic write"
fi

# === usage ===============================================================

echo "TEST 14: usage errors"
rc=0; out=$(bash "$SCRIPT" 2>&1) || rc=$?
case "$rc" in 1) pass "exit 1 on missing subcommand";; *) fail "want rc=1, got $rc" "$out";; esac
rc=0; out=$(bash "$SCRIPT" bogus 2>&1) || rc=$?
case "$rc" in 1) pass "exit 1 on unknown subcommand";; *) fail "want rc=1, got $rc" "$out";; esac
assert_contains "unknown-subcommand diagnostic" "unknown subcommand" "$out"

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
