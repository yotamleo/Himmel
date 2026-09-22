#!/usr/bin/env bash
# Hermetic test for `clean-garden.sh --health` and the STUCK state a real sweep
# records (HIMMEL-3405). Temp git repo + real worktrees + a stub gh that reports
# every feat/* branch as a merged PR at its tip (both the REST cache the prune
# loop reads and the `pr list` JSON unlanded-work.sh reads). Reporting only: the
# suite also proves --health never prunes and a sweep's prune decision is
# unchanged. Pattern follows scripts/test-clean-only.sh.
set -uo pipefail

# grepq <text> [grep-args...] — `grep -q` against <text> with NO pipeline
# (pipefail + early-exit grep = false negatives; HIMMEL-1430).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEAN_GARDEN="$SCRIPT_DIR/clean-garden.sh"

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2317,SC2329  # invoked indirectly via `trap cleanup EXIT`
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
expect() {
    local label="$1" out="$2"; shift 2
    if "$@"; then pass "$label"; else fail "$label" "$out"; fi
}
expect_not() {
    local label="$1" out="$2" rc=0; shift 2
    "$@" || rc=$?
    if [ "$rc" -eq 1 ]; then pass "$label"; else fail "$label" "status=$rc: $out"; fi
}
is_dir() { [ -d "$1" ]; }
is_gone() { [ ! -d "$1" ]; }
rc_of() { printf '%s\n' "$1" | sed -n 's/^rc=//p' | tail -1; }
rc_is() { [ "$(rc_of "$1")" = "$2" ]; }
# body_of <run output> — everything before the trailing rc= line.
body_of() { printf '%s\n' "$1" | sed '/^rc=[0-9]*$/d'; }
is_empty() { [ -z "$(printf '%s' "$1")" ]; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/himmel-sweep-health.XXXXXX")
# shellcheck source=scripts/lib/canon-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/canon-path.sh"
CANON_ROOT=$(canon_path "$TMP_ROOT") || { echo "setup: canon_path failed" >&2; exit 1; }
TMP_ROOT="$CANON_ROOT"
TMP_ROOT_UNIX="$TMP_ROOT"
if command -v cygpath >/dev/null 2>&1; then
    TMP_ROOT=$(cygpath -m "$TMP_ROOT")
fi

REPO="$TMP_ROOT/repo"
git init -q --initial-branch=main "$REPO" 2>/dev/null || {
    git init -q "$REPO"
    git -C "$REPO" symbolic-ref HEAD refs/heads/main || true
}
git -C "$REPO" config user.email t@test.com
git -C "$REPO" config user.name t
git -C "$REPO" config maintenance.auto false
printf 'base\n' > "$REPO/README"
git -C "$REPO" add README
git -C "$REPO" commit -q -m "base"
git -C "$REPO" branch -m main 2>/dev/null || true
git -C "$REPO" remote add origin https://github.com/owner/repo.git
# unlanded-work.sh compares against origin/main; the fixture has no real remote.
git -C "$REPO" update-ref refs/remotes/origin/main main

# Stub gh. feat/* branches are merged PRs at their current tip. `api-fail`
# makes the REST walk fail (a blind sweep); `pr-list-fail` makes `pr list` fail.
STUB_DIR="$TMP_ROOT_UNIX/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
args="\$*"
if echo "\$args" | grep -q "auth status"; then exit 0; fi
if echo "\$args" | grep -q "repo view"; then echo "owner/repo"; exit 0; fi
if echo "\$args" | grep -q "api --paginate repos/owner/repo/pulls"; then
    [ -f "$STUB_DIR/api-fail" ] && exit 1
    while IFS=' ' read -r branch sha; do
        printf 'owner/repo\t%s\tmerged\t%s\n' "\$branch" "\$sha"
    done < <(git for-each-ref --format='%(refname:short) %(objectname)' refs/heads/feat)
    exit 0
fi
if echo "\$args" | grep -q "pr list"; then
    [ -f "$STUB_DIR/pr-list-fail" ] && exit 1
    git for-each-ref --format='%(refname:short) %(objectname)' refs/heads/feat \\
        | jq -Rn '[inputs | split(" ") | {headRefName: .[0], number: 1, state: "MERGED", headRefOid: .[1], baseRefName: "main"}]'
    exit 0
fi
exit 0
STUB
chmod +x "$STUB_DIR/gh"

mk_wt() {
    local name="$1" branch="$2"
    git -C "$REPO" worktree add -q "$TMP_ROOT/$name" -b "$branch" >/dev/null 2>&1
    echo "$TMP_ROOT/$name"
}

# run_clean <args...> — runs from inside the fixture repo; prints combined
# output then a final "rc=<n>" line. Extra env comes from the caller's `env`.
run_clean() {
    (
        export PATH="${STUB_DIR}:${PATH}"
        cd "$REPO" || exit 1
        set +e
        out=$(bash "$CLEAN_GARDEN" "$@" 2>&1)
        rc=$?
        printf '%s\nrc=%s\n' "$out" "$rc"
    )
}
STATE="$REPO/.git/sweep-health/stuck.tsv"
state_count() { awk -F'\t' -v k="$1" '$1==k{print $3}' "$STATE" 2>/dev/null; }

WT_DIRTY=$(mk_wt wt-dirty feat/dirty)        # merged, tracked change -> skipped every sweep
printf 'changed\n' >> "$WT_DIRTY/README"
WT_OPEN=$(mk_wt wt-open wip/open)            # ACTIVE: no merged PR -> never a stuck candidate
printf 'work\n' > "$WT_OPEN/work.txt"
git -C "$WT_OPEN" add work.txt
git -C "$WT_OPEN" commit -q -m "wip work"

# ── case 1: a healthy repo prints nothing and exits 0 ────────────────────────
echo "CASE 1: --health on a repo with no skipped sweep"
out=$(run_clean --health)
expect "1: rc=0" "$out" rc_is "$out" 0
expect "1: no output at all" "$(body_of "$out")" is_empty "$(body_of "$out")"

# ── case 2: STUCK only after N sweeps ────────────────────────────────────────
echo "CASE 2: STUCK after the sweep threshold"
run_clean --prune-only >/dev/null
run_clean --prune-only >/dev/null
out=$(run_clean --health)
expect "2a: two skipped sweeps are below the default threshold (3): no alarm" "$out" rc_is "$out" 0
expect "2a: output empty" "$(body_of "$out")" is_empty "$(body_of "$out")"
run_clean --prune-only >/dev/null
out=$(run_clean --health)
expect "2b: the third skipped sweep raises STUCK, rc=1" "$out" rc_is "$out" 1
expect "2b: STUCK line names the path, a reason and a since-timestamp" "$out" \
    grepq "$out" -E "^STUCK $WT_DIRTY .*uncommitted.* since [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z$"
expect_not "2c: the ACTIVE open-PR worktree is never reported" "$out" grepq "$out" "wt-open"
expect "2d: --health pruned nothing" "$out" is_dir "$WT_DIRTY"
expect "2d: --health left the ACTIVE worktree alone" "$out" is_dir "$WT_OPEN"

# ── case 3: SWEEP_STUCK_SWEEPS is the knob ───────────────────────────────────
echo "CASE 3: threshold knob"
out=$(SWEEP_STUCK_SWEEPS=5 run_clean --health)
expect "3: threshold 5 with 3 sweeps -> quiet" "$out" rc_is "$out" 0

# ── case 4: STUCK after 24h even on the first sweeps ─────────────────────────
echo "CASE 4: STUCK by age"
awk -F'\t' -v OFS='\t' -v old="$(( $(date +%s) - 90000 ))" '{ $2 = old; $3 = 1; print }' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
out=$(run_clean --health)
expect "4: a 25h-old entry with 1 sweep is STUCK" "$out" rc_is "$out" 1
expect "4: names the worktree" "$out" grepq "$out" "^STUCK $WT_DIRTY "
out=$(SWEEP_STUCK_HOURS=48 run_clean --health)
expect "4: SWEEP_STUCK_HOURS=48 -> quiet" "$out" rc_is "$out" 0

# ── case 5: --dry-run neither advances nor clears the state ──────────────────
echo "CASE 5: --dry-run does not touch the state"
before="$(cat "$STATE")"
run_clean --prune-only --dry-run >/dev/null
expect "5: state file byte-identical after a dry run" "" test "$before" = "$(cat "$STATE")"

# ── case 6: a blind sweep (forge unreachable) does not reset the evidence ────
echo "CASE 6: blind sweep leaves the state alone"
: > "$STUB_DIR/api-fail"
run_clean --prune-only >/dev/null
rm -f "$STUB_DIR/api-fail"
expect "6: state file byte-identical after a forge-blind sweep" "" test "$before" = "$(cat "$STATE")"

# ── case 7: --only scopes the state to its target ────────────────────────────
echo "CASE 7: --only leaves other rows alone"
WT_ONE=$(mk_wt wt-one feat/one)
count_before="$(state_count "$WT_DIRTY")"
run_clean --only "$WT_ONE" >/dev/null
expect "7: the --only target was pruned" "" is_gone "$WT_ONE"
expect "7: the other row's count is unchanged" "" test "$count_before" = "$(state_count "$WT_DIRTY")"

# ── case 8: resolving the cause clears the alarm ─────────────────────────────
echo "CASE 8: prune succeeds -> STUCK clears"
printf 'base\n' > "$WT_DIRTY/README"
out=$(run_clean --prune-only)
expect "8: the now-clean merged worktree is pruned (decision unchanged)" "$out" is_gone "$WT_DIRTY"
out=$(run_clean --health)
expect "8: --health is quiet again" "$out" rc_is "$out" 0
expect "8: output empty" "$(body_of "$out")" is_empty "$(body_of "$out")"
expect "8: ACTIVE worktree still there" "$out" is_dir "$WT_OPEN"

# ── case 9: an entry whose path no longer exists is not reported ─────────────
echo "CASE 9: vanished path"
mkdir -p "$REPO/.git/sweep-health"
printf '%s\t%s\t%s\t%s\n' "$TMP_ROOT/wt-gone" "$(( $(date +%s) - 200000 ))" 9 "uncommitted changes" > "$STATE"
out=$(run_clean --health)
expect "9: a path that no longer exists is not STUCK" "$out" rc_is "$out" 0

# ── case 10: --health folds in unlanded-work.sh SWEEP-ERROR ──────────────────
echo "CASE 10: SWEEP-ERROR from the branch scan"
rm -f "$STATE"
git -C "$REPO" checkout -q --orphan fix/unrelated-root >/dev/null 2>&1
git -C "$REPO" rm -rf -q . >/dev/null 2>&1 || true
printf 'other\n' > "$REPO/other.txt"
git -C "$REPO" add other.txt
git -C "$REPO" commit -q -m "unrelated root"
git -C "$REPO" checkout -q main
out=$(run_clean --health)
expect "10: rc=1" "$out" rc_is "$out" 1
expect "10: readable no-merge-base cause, not a bare rc" "$out" grepq "$out" "^SWEEP-ERROR fix/unrelated-root no merge base with origin/main"
expect_not "10: no 'rc=128' noise" "$out" grepq "$out" "rc=128"

# ── case 11: flag hygiene ────────────────────────────────────────────────────
echo "CASE 11: --health takes no other flag"
out=$(run_clean --health --dry-run)
expect "11a: --health --dry-run refused" "$out" test "$(rc_of "$out")" != 0
out=$(run_clean --health feat/newone)
expect "11b: --health with a create branch refused" "$out" test "$(rc_of "$out")" != 0
out=$(run_clean --health --only feat/x)
expect "11c: --health --only refused" "$out" test "$(rc_of "$out")" != 0

echo
echo "test-sweep-health: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
