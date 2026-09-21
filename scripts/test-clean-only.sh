#!/usr/bin/env bash
# Hermetic test for `clean-garden.sh --only <worktree-path|branch>` (HIMMEL-3297):
# prune exactly ONE worktree, so a console wrapping one leg cannot reach across
# a fleet-wide sweep and remove another live leg's cwd. Temp git repo + real
# worktrees + a stub gh that reports every feat/* branch as merged at its tip.
# Pattern follows scripts/test-clean-prune-strays.sh.
set -uo pipefail

# grepq <text> [grep-args...] — `grep -q` against <text> with NO pipeline
# (pipefail + early-exit grep = false negatives; HIMMEL-1430).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEAN_GARDEN="$SCRIPT_DIR/clean-garden.sh"
CLEAN_SH="$SCRIPT_DIR/clean.sh"

PASS=0
FAIL=0
TMP_ROOT=""
HOLDER_PID=""

# shellcheck disable=SC2317,SC2329  # invoked indirectly via `trap cleanup EXIT`
cleanup() {
    if [ -n "$HOLDER_PID" ]; then kill "$HOLDER_PID" 2>/dev/null || true; fi
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
# expect <label> <output> <command...> — pass when the command succeeds.
expect() {
    local label="$1" out="$2"; shift 2
    if "$@"; then pass "$label"; else fail "$label" "$out"; fi
}
# expect_not <label> <output> <command...> — pass when the command FAILS.
expect_not() {
    local label="$1" out="$2"; shift 2
    if "$@"; then fail "$label" "$out"; else pass "$label"; fi
}
is_dir() { [ -d "$1" ]; }
is_gone() { [ ! -d "$1" ]; }
rc_is() { [ "$(rc_of "$1")" = "$2" ]; }
rc_nonzero() { [ "$(rc_of "$1")" != "0" ]; }
has_branch() { git -C "$REPO" rev-parse --verify -q "refs/heads/$1" >/dev/null; }

# ── shared setup ─────────────────────────────────────────────────────────────
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/himmel-clean-only.XXXXXX")
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

# Stub gh: every feat/* branch is a merged PR at its current tip; any other
# branch has no PR row (kept as "PR not merged").
STUB_DIR="$TMP_ROOT_UNIX/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
if echo "$args" | grep -q "auth status"; then exit 0; fi
if echo "$args" | grep -q "repo view"; then echo "owner/repo"; exit 0; fi
if echo "$args" | grep -q "api --paginate repos/owner/repo/pulls"; then
    while IFS=' ' read -r branch sha; do
        printf 'owner/repo\t%s\tmerged\t%s\n' "$branch" "$sha"
    done < <(git for-each-ref --format='%(refname:short) %(objectname)' refs/heads/feat)
    exit 0
fi
if echo "$args" | grep -q -- "--state merged"; then echo "1"; exit 0; fi
if echo "$args" | grep -q -- "--state open"; then exit 0; fi
exit 0
STUB
chmod +x "$STUB_DIR/gh"

mk_wt() {
    local name="$1" branch="$2"
    git -C "$REPO" worktree add -q "$TMP_ROOT/$name" -b "$branch" >/dev/null 2>&1
    echo "$TMP_ROOT/$name"
}

# run_clean <script> <args...> — runs from inside the fixture repo; prints
# combined output then a final "rc=<n>" line.
run_clean() {
    local script="$1"; shift
    (
        export PATH="${STUB_DIR}:${PATH}"
        cd "$REPO" || exit 1
        set +e
        out=$(bash "$script" "$@" 2>&1)
        rc=$?
        printf '%s\nrc=%s\n' "$out" "$rc"
    )
}
rc_of() { printf '%s\n' "$1" | sed -n 's/^rc=//p' | tail -1; }

WT_A=$(mk_wt wt-a feat/a)          # the --only target (path form)
WT_B=$(mk_wt wt-b feat/b)          # merged sibling — must SURVIVE an --only run
WT_C=$(mk_wt wt-c feat/c)          # --only target (branch form)
WT_D=$(mk_wt wt-d feat/d)          # merged sibling — must survive
WT_OPEN=$(mk_wt wt-open wip/open)  # no merged PR — --only must refuse
WT_DIRTY=$(mk_wt wt-dirty feat/dirty)
printf 'changed\n' >> "$WT_DIRTY/README"   # tracked change — --only must refuse
WT_HELD=$(mk_wt wt-held feat/held) # a live process's cwd — --only must refuse
WT_DRY=$(mk_wt wt-dry feat/dry)

# ── case 1: --only <path> prunes that worktree ONLY ──────────────────────────
echo "CASE 1: --only <path>"
out=$(run_clean "$CLEAN_GARDEN" --only "$WT_A")
expect "1: rc=0" "$out" rc_is "$out" 0
expect "1: target worktree pruned" "$out" is_gone "$WT_A"
# RED core: a fleet-wide sweep would have taken every merged sibling.
expect "1: merged sibling wt-b survived" "$out" is_dir "$WT_B"
expect "1: merged sibling wt-d survived" "$out" is_dir "$WT_D"
expect "1: merged sibling wt-held survived" "$out" is_dir "$WT_HELD"
expect "1: sibling branch feat/b kept" "$out" has_branch feat/b
expect_not "1: target branch feat/a deleted with its worktree" "$out" has_branch feat/a

# ── case 2: --only <branch> ──────────────────────────────────────────────────
echo "CASE 2: --only <branch>"
out=$(run_clean "$CLEAN_GARDEN" --only feat/c)
expect "2: rc=0" "$out" rc_is "$out" 0
expect "2: target worktree pruned by branch name" "$out" is_gone "$WT_C"
expect "2: siblings survived" "$out" is_dir "$WT_B"

# ── case 3: refuses a non-candidate, non-zero, worktree kept ─────────────────
echo "CASE 3: refusals"
out=$(run_clean "$CLEAN_GARDEN" --only "$WT_OPEN")
expect "3a: un-merged target refused non-zero" "$out" rc_nonzero "$out"
expect "3a: un-merged target kept" "$out" is_dir "$WT_OPEN"
expect "3a: message names the refusal" "$out" grepq "$out" "not a prune candidate"

out=$(run_clean "$CLEAN_GARDEN" --only feat/dirty)
expect "3b: dirty target refused non-zero" "$out" rc_nonzero "$out"
expect "3b: dirty target kept" "$out" is_dir "$WT_DIRTY"
expect "3b: dirty check still fires under --only" "$out" grepq "$out" "uncommitted changes"

out=$(run_clean "$CLEAN_GARDEN" --only "$REPO")
expect "3c: primary refused non-zero" "$out" rc_nonzero "$out"
expect "3c: primary untouched" "$out" is_dir "$REPO/.git"

out=$(run_clean "$CLEAN_GARDEN" --only feat/no-such-branch)
expect "3d: unknown target refused non-zero" "$out" rc_nonzero "$out"
expect "3d: message names the refusal" "$out" grepq "$out" "not a registered worktree"

# ── case 4: a live process's cwd still blocks --only (worktree_in_use) ───────
echo "CASE 4: live cwd holder"
( cd "$WT_HELD" && exec sleep 60 ) &
HOLDER_PID=$!
sleep 0.3
out=$(run_clean "$CLEAN_GARDEN" --only "$WT_HELD")
expect "4: live-cwd target refused non-zero" "$out" rc_nonzero "$out"
expect "4: live-cwd target kept" "$out" is_dir "$WT_HELD"
expect "4: message says in use" "$out" grepq "$out" "in use"
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=""
out=$(run_clean "$CLEAN_GARDEN" --only "$WT_HELD")
expect "4 control: same target with no holder is pruned" "$out" is_gone "$WT_HELD"

# ── case 5: --dry-run under --only mutates nothing ───────────────────────────
echo "CASE 5: --only --dry-run"
out=$(run_clean "$CLEAN_GARDEN" --only "$WT_DRY" --dry-run)
expect "5: rc=0" "$out" rc_is "$out" 0
expect "5: dry-run names the target" "$out" grepq "$out" "would prune feat/dry"
expect_not "5: dry-run plans no sibling" "$out" grepq "$out" "would prune feat/b"
expect "5: dry-run removed nothing" "$out" is_dir "$WT_DRY"

# ── case 6: flag hygiene ─────────────────────────────────────────────────────
echo "CASE 6: flag hygiene"
out=$(run_clean "$CLEAN_GARDEN" --only)
expect "6a: --only with no value refused" "$out" rc_nonzero "$out"
expect "6a: usage error names the flag" "$out" grepq "$out" -e "--only needs"
out=$(run_clean "$CLEAN_GARDEN" feat/newone --only feat/b)
expect "6b: --only with a create branch refused" "$out" rc_nonzero "$out"
expect "6b: nothing pruned" "$out" is_dir "$WT_B"
out=$(run_clean "$CLEAN_GARDEN" --only feat/b --no-prune)
expect "6c: --only with --no-prune refused" "$out" rc_nonzero "$out"
expect "6c: nothing pruned" "$out" is_dir "$WT_B"

# ── case 7: clean.sh forwards --only ─────────────────────────────────────────
echo "CASE 7: clean.sh passthrough"
out=$(run_clean "$CLEAN_SH" --only feat/d)
expect "7: rc=0" "$out" rc_is "$out" 0
expect "7: clean.sh --only pruned the target" "$out" is_gone "$WT_D"
expect "7: sibling feat/b survived" "$out" is_dir "$WT_B"

# ── control: the plain (fleet-wide) run still prunes every merged sibling ────
echo "CONTROL: plain --prune-only"
out=$(run_clean "$CLEAN_GARDEN" --prune-only)
expect "control: plain prune still takes the merged sibling feat/b" "$out" is_gone "$WT_B"

echo
echo "test-clean-only: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
