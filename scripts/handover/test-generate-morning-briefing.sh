#!/usr/bin/env bash
# Smoke test for scripts/handover/generate-morning-briefing.sh (HIMMEL-135).
#
# Covers:
#   1. Default run produces well-formed briefing with all 4 sections.
#   2. --since SHA limits the commit window.
#   3. --out PATH writes to the requested location.
#   4. PR section absent → renders helpful "no merged PRs" line.
#   5. jira unavailable → renders "ticket keys detected, jira unavailable" line.
#   6. --dry-run touches no files.
#   7. Cross-ref: Done ticket appearing in both gh AND commits surfaces in Done block.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/generate-morning-briefing.sh"

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

TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi

# Fake gh + jira CLIs --------------------------------------------------

FAKE_GH="$TMP_ROOT/gh-fake.sh"
cat >"$FAKE_GH" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
    "pr list")
        printf '%s\n' "${FAKE_GH_PR_JSON:-[]}"
        ;;
esac
exit 0
FAKE
chmod +x "$FAKE_GH"

FAKE_JIRA="$TMP_ROOT/jira-fake.sh"
cat >"$FAKE_JIRA" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
    list)
        printf '%s\n' "${FAKE_JIRA_OUT:-}"
        ;;
esac
exit 0
FAKE
chmod +x "$FAKE_JIRA"

# Setup a tmp git repo with a marker SHA + 3 commits referencing tickets.
REPO="$TMP_ROOT/repo"
git init -q --initial-branch=main "$REPO" 2>/dev/null || {
    git init -q "$REPO"
    git -C "$REPO" symbolic-ref HEAD refs/heads/main || true
}
(
    cd "$REPO"
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "init"
    git branch -m main 2>/dev/null || true
    MARKER=$(git rev-parse HEAD)
    echo "$MARKER" > "$TMP_ROOT/MARKER"
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "feat(scope): HIMMEL-901 add A"
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "fix(scope): HIMMEL-902 bug B"
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "chore: nothing"
)
MARKER=$(cat "$TMP_ROOT/MARKER")

run_script() {
    (
        cd "$REPO"
        # shellcheck disable=SC2030
        export GH_CMD="$FAKE_GH"
        # shellcheck disable=SC2030
        export JIRA_CMD="$FAKE_JIRA"
        bash "$SCRIPT" "$@"
    )
}

# Test 1: default run, all sections -----------------------------------

echo "TEST: default run produces all 4 sections"
OUT_DEFAULT="$TMP_ROOT/out1.md"
out=$(FAKE_GH_PR_JSON='[{"number":42,"title":"feat(scope): HIMMEL-901 add A","mergedAt":"2026-05-25T00:00:00Z"}]' \
    FAKE_JIRA_OUT=$'HIMMEL-901\tTask\tDone\tAdd A' \
    run_script --since "$MARKER" --out "$OUT_DEFAULT")
file=$(cat "$OUT_DEFAULT")
assert_contains "header date"        "# Overnight + Day Session Summary"  "$file"
assert_contains "code shipped section" "## Code shipped"                  "$file"
assert_contains "commits section"    "## Commits"                          "$file"
assert_contains "done section"       "## Tickets transitioned to Done"     "$file"
assert_contains "review section"     "## Items for operator review"        "$file"
assert_contains "PR row #42"         "#42"                                 "$file"
assert_contains "commit cited"       "HIMMEL-901"                          "$file"
assert_contains "marker echoed"      "$MARKER"                             "$file"

# Test 2: --since SHA limits window -----------------------------------

echo "TEST: --since SHA limits the commit window"
# Use the latest commit as the since marker → no commits should land.
LATEST=$(git -C "$REPO" rev-parse HEAD)
OUT2="$TMP_ROOT/out2.md"
out=$(run_script --since "$LATEST" --out "$OUT2")
file=$(cat "$OUT2")
assert_contains "no-commits message" "No commits found since" "$file"

# Test 3: --out writes to requested location --------------------------

echo "TEST: --out PATH respected"
OUT3="$TMP_ROOT/sub/path/out3.md"
# Note: --out must create parent dirs.
out=$(run_script --since "$MARKER" --out "$OUT3")
if [ -f "$OUT3" ]; then pass "wrote $OUT3"; else fail "did not create parent dir for --out"; fi

# Test 4: PR section absent (empty gh result) -------------------------

echo "TEST: empty gh PR list renders helpful message"
OUT4="$TMP_ROOT/out4.md"
out=$(FAKE_GH_PR_JSON='[]' run_script --since "$MARKER" --out "$OUT4")
file=$(cat "$OUT4")
assert_contains "empty PR fallback" "No merged PRs found" "$file"

# Test 5: jira unavailable -------------------------------------------

echo "TEST: jira unavailable yields ticket-keys-only fallback"
OUT5="$TMP_ROOT/out5.md"
out=$(
    cd "$REPO"
    GH_CMD="$FAKE_GH" JIRA_CMD="/no/such/binary" bash "$SCRIPT" --since "$MARKER" --out "$OUT5"
)
file=$(cat "$OUT5")
assert_contains "ticket keys listed in fallback" "HIMMEL-901" "$file"

# Test 6: --dry-run touches no files ----------------------------------

echo "TEST: --dry-run touches no files"
OUT6="$TMP_ROOT/out6.md"
out=$(run_script --since "$MARKER" --out "$OUT6" --dry-run)
if [ -f "$OUT6" ]; then
    fail "--dry-run created $OUT6"
else
    pass "--dry-run did not write file"
fi
assert_contains "dry-run prints body" "Overnight + Day Session Summary" "$out"

# Test 7: cross-ref Done block ---------------------------------------

echo "TEST: Done block cross-references commits"
OUT7="$TMP_ROOT/out7.md"
out=$(FAKE_GH_PR_JSON='[]' \
    FAKE_JIRA_OUT=$'HIMMEL-901\tTask\tDone\tA
HIMMEL-902\tTask\tDone\tB
HIMMEL-999\tTask\tDone\tNot in commits' \
    run_script --since "$MARKER" --out "$OUT7")
file=$(cat "$OUT7")
assert_contains "Done block has HIMMEL-901" "HIMMEL-901 — Task — A" "$file"
assert_contains "Done block has HIMMEL-902" "HIMMEL-902 — Task — B" "$file"
if printf '%s' "$file" | grep -q 'HIMMEL-999'; then
    fail "Done block leaked unrelated ticket HIMMEL-999"
else
    pass "Done block filtered out HIMMEL-999 (not in commits)"
fi

# Summary --------------------------------------------------------------

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
