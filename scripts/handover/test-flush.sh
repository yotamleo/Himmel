#!/usr/bin/env bash
# Smoke test for scripts/handover/flush.sh (HIMMEL-143).
#
# Covers:
#   1. 3 unpushed handover branches → flush pushes all 3, opens 3 PRs.
#   2. In-sync branch → reports as in-sync, no push.
#   3. Merged-into-main branch (via squash-cherry) → reported as merged.
#   4. --cleanup deletes a merged local branch.
#   5. --dry-run touches nothing.
#   6. gh unavailable → falls back to command dumps + still pushes.
#   7. No handover/* branches → "nothing to do" + exit 0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUSH="$SCRIPT_DIR/flush.sh"

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
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then pass "$name"; else fail "$name" "needle '$needle' missing"; fi
}

# Setup ---------------------------------------------------------------

TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi
echo "test: TMP_ROOT=$TMP_ROOT"

# Fake gh that pretends auth is OK and returns canned responses.
FAKE_GH="$TMP_ROOT/gh-fake.sh"
cat >"$FAKE_GH" <<'FAKEGH'
#!/usr/bin/env bash
echo "gh $*" >> "${FAKE_GH_LOG:-/dev/null}"
case "$1 $2" in
    "auth status")
        if [ "${FAKE_GH_AUTH:-ok}" = "ok" ]; then exit 0; else exit 1; fi
        ;;
    "pr list")
        printf '%s\n' "${FAKE_GH_PR_LIST:-}"; exit 0
        ;;
    "pr create"|"pr edit")
        echo "https://github.com/test/test/pull/42"; exit 0
        ;;
esac
exit 0
FAKEGH
chmod +x "$FAKE_GH"

# Bare origin + working clone act as the handover repo.
ORIGIN="$TMP_ROOT/origin.git"
HANDOVER="$TMP_ROOT/handover"
git init -q --bare --initial-branch=main "$ORIGIN" 2>/dev/null || git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$HANDOVER" 2>/dev/null
(
    cd "$HANDOVER"
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "init"
    git branch -m main 2>/dev/null || true
    git -c user.email=t@test.com -c user.name=test push -q -u origin main 2>/dev/null \
      || git -c user.email=t@test.com -c user.name=test push -q -u origin HEAD:main
)

mkdir -p "$HANDOVER/handovers/yotam"

# A "himmel" repo for cwd context (flush.sh needs handover-path.sh's
# resolver — which only requires HANDOVER_DIR + an existing dir).
HIMMEL="$TMP_ROOT/himmel"
git init -q "$HIMMEL"
(
    cd "$HIMMEL"
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "init"
)

# Helper: invoke flush.sh from HIMMEL with HANDOVER_DIR pointed at
# HANDOVER/handovers.
run_flush() {
    (
        cd "$HIMMEL"
        # shellcheck disable=SC2030
        export HANDOVER_DIR="$HANDOVER/handovers"
        # shellcheck disable=SC2030
        export FAKE_GH_LOG="$TMP_ROOT/gh.log"
        : > "$FAKE_GH_LOG"
        GH_CMD="$FAKE_GH" bash "$FLUSH" "$@" 2>&1
    )
}

# Seed 3 unpushed handover branches with content.
make_branch_with_commit() {
    local branch="$1" file="$2" body="$3"
    (
        cd "$HANDOVER"
        git checkout -q main 2>/dev/null || true
        git checkout -q -b "$branch"
        mkdir -p handovers/yotam
        printf '%s\n' "$body" > "handovers/yotam/$file"
        git -c user.email=t@test.com -c user.name=test add "handovers/yotam/$file"
        git -c user.email=t@test.com -c user.name=test commit -q -m "handover: $branch seed"
    )
}

# Test 1: 3 unpushed branches -> flush pushes all 3, opens 3 PRs ------

echo "TEST: 3 unpushed handover branches → push + open PR for each"
make_branch_with_commit "handover/HIMMEL-901-one" "one.md"   "one"
make_branch_with_commit "handover/HIMMEL-902-two" "two.md"   "two"
make_branch_with_commit "handover/HIMMEL-903-three" "three.md" "three"

out=$(run_flush)
printf '%s\n' "$out" | awk '{print "  > "$0}'

for n in 901 902 903; do
    if git -C "$ORIGIN" show-ref --verify --quiet "refs/heads/handover/HIMMEL-$n-${n/901/one}"; then :; fi
done
# Direct branch-existence checks
for b in handover/HIMMEL-901-one handover/HIMMEL-902-two handover/HIMMEL-903-three; do
    if git -C "$ORIGIN" show-ref --verify --quiet "refs/heads/$b"; then
        pass "branch $b pushed to origin"
    else
        fail "branch $b not on origin"
    fi
done
assert_contains "summary mentions pushed: 3"     "pushed           : 3" "$out"
assert_contains "summary mentions PR opened: 3"  "PR opened        : 3" "$out"

# Test 2: in-sync branch reports as in-sync ---------------------------

echo "TEST: in-sync branch reports as in-sync"
out=$(run_flush)
assert_contains "in-sync count incremented" "in-sync          : 3" "$out"

# Test 3: merged-into-main branch reported as merged -----------------

echo "TEST: squash-merged branch reported as merged"
# Simulate squash: cherry-pick the branch tip onto main on the origin.
(
    cd "$HANDOVER"
    git checkout -q main
    git pull -q origin main 2>/dev/null || true
    # Squash-merge handover/HIMMEL-901-one into main.
    git merge --squash handover/HIMMEL-901-one
    git -c user.email=t@test.com -c user.name=test commit -q -m "squash merge of #901"
    git push -q origin main
)
out=$(run_flush)
printf '%s\n' "$out" | grep -E '(901|merged|HIMMEL)' | awk '{print "  > "$0}'
assert_contains "merged count at least 1" "merged           : 1" "$out"

# Test 4: --cleanup deletes the merged local branch ------------------

echo "TEST: --cleanup deletes merged local branch"
out=$(run_flush --cleanup)
if git -C "$HANDOVER" show-ref --verify --quiet "refs/heads/handover/HIMMEL-901-one"; then
    fail "merged local branch still present after --cleanup"
else
    pass "merged local branch deleted by --cleanup"
fi

# Test 5: --dry-run touches nothing -----------------------------------

echo "TEST: --dry-run touches nothing"
# Add a new unpushed branch.
make_branch_with_commit "handover/HIMMEL-904-four" "four.md" "four"
out=$(run_flush --dry-run)
if git -C "$ORIGIN" show-ref --verify --quiet "refs/heads/handover/HIMMEL-904-four"; then
    fail "--dry-run pushed a branch to origin"
else
    pass "--dry-run did not push"
fi
assert_contains "dry-run mentions would-push" "would-push       : 1" "$out"

# Test 6: gh unavailable → command dumps ------------------------------

echo "TEST: gh unavailable → command dumps + still pushes"
# Reset state by pushing 904 first so its push step is a no-op next call.
( cd "$HANDOVER" && git checkout -q handover/HIMMEL-904-four && git push -q -u origin handover/HIMMEL-904-four )
# Add yet another unpushed branch.
make_branch_with_commit "handover/HIMMEL-905-five" "five.md" "five"
out=$(
    cd "$HIMMEL"
    # shellcheck disable=SC2030,SC2031
    export HANDOVER_DIR="$HANDOVER/handovers"
    # shellcheck disable=SC2030,SC2031
    export FAKE_GH_LOG="$TMP_ROOT/gh.log"
    : > "$FAKE_GH_LOG"
    GH_CMD="$FAKE_GH" FAKE_GH_AUTH="fail" bash "$FLUSH" 2>&1
)
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_contains "warning about gh unusable"   "gh CLI not usable" "$out"
assert_contains "summary lists PR command dumps" "PR command dumps" "$out"
if git -C "$ORIGIN" show-ref --verify --quiet "refs/heads/handover/HIMMEL-905-five"; then
    pass "push still happened despite gh unavailable"
else
    fail "push did not happen when gh unavailable"
fi

# Test 7: no handover branches → nothing to do ------------------------

echo "TEST: no handover/* branches → nothing to do"
# Fresh handover repo with no handover/* branches.
HANDOVER2="$TMP_ROOT/handover-empty"
ORIGIN2="$TMP_ROOT/origin-empty.git"
git init -q --bare --initial-branch=main "$ORIGIN2" 2>/dev/null || git init -q --bare "$ORIGIN2"
git clone -q "$ORIGIN2" "$HANDOVER2" 2>/dev/null
(
    cd "$HANDOVER2"
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "init"
    git -c user.email=t@test.com -c user.name=test push -q -u origin HEAD:main
)
mkdir -p "$HANDOVER2/handovers/yotam"
out=$(
    cd "$HIMMEL"
    # shellcheck disable=SC2031
    export HANDOVER_DIR="$HANDOVER2/handovers"
    GH_CMD="$FAKE_GH" bash "$FLUSH" 2>&1
)
assert_contains "empty repo says nothing to do" "no local handover/* branches" "$out"

# Summary --------------------------------------------------------------

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
