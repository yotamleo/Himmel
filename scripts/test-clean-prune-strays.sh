#!/usr/bin/env bash
# Hermetic test for the merged-worktree untracked-stray prune logic in
# clean-garden.sh (HIMMEL-431). Temp git repo + real worktrees + a stub gh
# whose merged-PR query returns >0 so the dirty check is reached. Follows the
# pattern of scripts/test-cr-marker-sweep.sh.
set -euo pipefail

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

# ── shared setup ─────────────────────────────────────────────────────────────
TMP_ROOT=$(mktemp -d)
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
# A tracked file so a worktree can carry a tracked modification (case 4).
printf 'base\n' > "$REPO/README"
git -C "$REPO" add README
git -C "$REPO" commit -q -m "base"
git -C "$REPO" branch -m main 2>/dev/null || true
git -C "$REPO" remote add origin https://github.com/owner/repo.git

# Stub gh: auth ok, repo view -> owner/repo, merged query -> count 1 (so every
# test branch is "merged"), open query -> empty.
STUB_DIR="$TMP_ROOT_UNIX/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
if echo "$args" | grep -q "auth status"; then exit 0; fi
if echo "$args" | grep -q "repo view"; then echo "owner/repo"; exit 0; fi
if echo "$args" | grep -q -- "--state merged"; then echo "1"; exit 0; fi
if echo "$args" | grep -q -- "--state open"; then exit 0; fi
exit 0
STUB
chmod +x "$STUB_DIR/gh"

# Helper: create a worktree on a branch and return its path.
mk_wt() {
    local name="$1" branch="$2"
    git -C "$REPO" worktree add -q "$TMP_ROOT/$name" -b "$branch" >/dev/null 2>&1
    echo "$TMP_ROOT/$name"
}

WT_LOCK=$(mk_wt wt-lock     feat/lock)     # case 1/6: untracked package-lock.json
WT_CODEX=$(mk_wt wt-codex   feat/codex)    # case 2: .codex/ + AGENTS.md
WT_NOTES=$(mk_wt wt-notes   feat/notes)    # case 3: untracked notes.txt (non-stray)
WT_WIP=$(mk_wt wt-wip       feat/wip)      # case 4: tracked mod + stray
WT_CLEAN=$(mk_wt wt-clean   feat/clean)    # case 5: fully clean
WT_NESTED=$(mk_wt wt-nested feat/nested)   # case 8: nested package-lock.json (depth invariance)
WT_MIXED=$(mk_wt wt-mixed   feat/mixed)    # case 9: stray + non-stray (forgotten wins)
WT_BAK=$(mk_wt wt-bak       feat/bak)      # case 10: AGENTS.md.bak (allowlist boundary)
WT_SCAN=$(mk_wt wt-scan     feat/scan)     # case 11: broken .git -> scanfail (fail-closed)

printf 'lock\n' > "$WT_LOCK/package-lock.json"
mkdir -p "$WT_CODEX/.codex"; printf 'x\n' > "$WT_CODEX/.codex/config.toml"; printf 'x\n' > "$WT_CODEX/AGENTS.md"
printf 'x\n' > "$WT_NOTES/notes.txt"
printf 'changed\n' >> "$WT_WIP/README"; printf 'lock\n' > "$WT_WIP/package-lock.json"
# WT_CLEAN: no changes.
mkdir -p "$WT_NESTED/pkg/sub"; printf 'lock\n' > "$WT_NESTED/pkg/sub/package-lock.json"
printf 'lock\n' > "$WT_MIXED/package-lock.json"; printf 'x\n' > "$WT_MIXED/notes.txt"
mkdir -p "$WT_BAK/docs"; printf 'x\n' > "$WT_BAK/docs/AGENTS.md.bak"
# WT_SCAN: break the worktree's gitdir pointer so `git -C status` fails (rc!=0)
# -> classify_worktree returns "scanfail" -> conservative skip (fail-closed).
rm -f "$WT_SCAN/.git"

run_clean() {
    (
        export PATH="${STUB_DIR}:${PATH}"
        cd "$REPO" || exit 1
        bash "$CLEAN_GARDEN" --prune-only "$@" 2>&1
    )
}

# ── Run A: dry-run mutates nothing (case 6) ──────────────────────────────────
echo "RUN A: --dry-run"
dry_out=$(run_clean --dry-run)
case "$dry_out" in
    *"would prune feat/lock"*) pass "6: dry-run reports would-prune feat/lock" ;;
    *) fail "6: expected 'would prune feat/lock'" "$dry_out" ;;
esac
case "$dry_out" in
    *"discarding untracked strays"*) pass "6: dry-run names discarded strays" ;;
    *) fail "6: expected 'discarding untracked strays' in dry output" "$dry_out" ;;
esac
if [ -d "$WT_LOCK" ] && [ -d "$WT_CLEAN" ]; then
    pass "6: dry-run mutated nothing (worktrees still present)"
else
    fail "6: dry-run removed a worktree" "$dry_out"
fi
# D4 dry-run parity across non-stray branches: nothing mutated, regardless of verdict.
if [ -d "$WT_NOTES" ] && [ -d "$WT_WIP" ] && [ -d "$WT_NESTED" ] && [ -d "$WT_MIXED" ] && [ -d "$WT_BAK" ] && [ -d "$WT_SCAN" ]; then
    pass "6: dry-run mutated nothing across all branch types (forgotten/tracked/nested/mixed/bak/scanfail)"
else
    fail "6: dry-run removed a non-stray worktree" "$dry_out"
fi
# A fully-clean worktree's dry-run line must NOT carry stray text.
if printf '%s\n' "$dry_out" | grep -F "feat/clean" | grep -q "discarding"; then
    fail "6: dry-run clean worktree wrongly shows strays text" "$dry_out"
else
    pass "6: dry-run clean worktree plain would-prune (no strays text)"
fi

# ── Run B: real prune (cases 1-5) ────────────────────────────────────────────
echo "RUN B: real prune"
out=$(run_clean)

# case 1: package-lock.json stray -> pruned + NOTE
# (grep per-line so the NOTE for feat/lock is matched on a single line, not
# across worktree boundaries.)
if [ ! -d "$WT_LOCK" ]; then pass "1: lock-stray worktree pruned (force-remove worked)"; else fail "1: lock-stray worktree NOT pruned" "$out"; fi
if printf '%s\n' "$out" | grep -F "feat/lock" | grep -q "discarding untracked strays: package-lock.json"; then
    pass "1: NOTE names package-lock.json"
else
    fail "1: expected strays NOTE naming package-lock.json for feat/lock" "$out"
fi

# case 2: codex strays -> pruned
if [ ! -d "$WT_CODEX" ]; then pass "2: codex-stray worktree pruned"; else fail "2: codex-stray worktree NOT pruned" "$out"; fi

# case 3: non-stray notes.txt -> skipped + warn
if [ -d "$WT_NOTES" ]; then pass "3: non-stray worktree kept"; else fail "3: non-stray worktree was pruned" "$out"; fi
case "$out" in *"not known strays"*"notes.txt"*) pass "3: WARN names notes.txt" ;; *) fail "3: expected 'not known strays' WARN naming notes.txt" "$out" ;; esac

# case 4: tracked mod -> skipped (existing protection). Tracked (D1) wins over
# the stray classification (D2) even though a package-lock.json stray coexists.
if [ -d "$WT_WIP" ]; then pass "4: tracked-WIP worktree kept"; else fail "4: tracked-WIP worktree was pruned" "$out"; fi
case "$out" in *"feat/wip has uncommitted changes"*) pass "4: WARN reports uncommitted changes" ;; *) fail "4: expected 'has uncommitted changes' for feat/wip" "$out" ;; esac
# negative: tracked-precedence means feat/wip must NOT be reported as a stray discard.
if printf '%s\n' "$out" | grep -F "feat/wip" | grep -q "discarding untracked strays"; then
    fail "4: tracked-WIP wrongly took the strays path (D1 precedence broken)" "$out"
else
    pass "4: tracked-WIP did NOT take the strays path (D1 wins over D2)"
fi

# case 5: fully clean -> pruned via plain remove (no strays NOTE for feat/clean)
# (grep per-line: a feat/clean strays NOTE would be one line carrying BOTH the
# branch and the strays text — checking the whole blob would false-match other
# worktrees' NOTEs.)
if [ ! -d "$WT_CLEAN" ]; then pass "5: clean worktree pruned"; else fail "5: clean worktree NOT pruned" "$out"; fi
if printf '%s\n' "$out" | grep -F "feat/clean" | grep -q "discarding untracked strays"; then
    fail "5: clean worktree wrongly took the strays/force path" "$out"
else
    pass "5: clean worktree took plain-remove path (no strays NOTE)"
fi

# case 8: nested package-lock.json (depth invariance) -> pruned
if [ ! -d "$WT_NESTED" ]; then pass "8: nested-lockfile worktree pruned (depth invariance)"; else fail "8: nested-lockfile worktree NOT pruned" "$out"; fi
if printf '%s\n' "$out" | grep -F "feat/nested" | grep -q "discarding untracked strays:.*package-lock.json"; then
    pass "8: NOTE names the nested package-lock.json"
else
    fail "8: expected strays NOTE naming pkg/sub/package-lock.json" "$out"
fi

# case 9: stray + non-stray together -> kept + WARN names only the non-stray
if [ -d "$WT_MIXED" ]; then pass "9: mixed (stray+non-stray) worktree kept"; else fail "9: mixed worktree was pruned (a coexisting stray must not mask forgotten work)" "$out"; fi
if printf '%s\n' "$out" | grep -F "feat/mixed" | grep -q "not known strays.*notes.txt"; then
    pass "9: WARN names the non-stray notes.txt"
else
    fail "9: expected 'not known strays' WARN naming notes.txt for feat/mixed" "$out"
fi

# case 10: AGENTS.md.bak is NOT AGENTS.md -> non-stray -> kept (allowlist boundary)
if [ -d "$WT_BAK" ]; then pass "10: AGENTS.md.bak worktree kept (boundary: .bak != AGENTS.md)"; else fail "10: AGENTS.md.bak wrongly classified as stray and pruned" "$out"; fi
if printf '%s\n' "$out" | grep -F "feat/bak" | grep -q "not known strays.*AGENTS.md.bak"; then
    pass "10: kept AS forgotten — WARN names AGENTS.md.bak"
else
    fail "10: expected 'not known strays' WARN naming AGENTS.md.bak for feat/bak" "$out"
fi

# case 11: broken gitdir -> scanfail -> conservative skip (fail-closed)
if [ -d "$WT_SCAN" ]; then pass "11: scanfail worktree kept (fail-closed on unknown state)"; else fail "11: scanfail worktree was pruned (must fail closed)" "$out"; fi
case "$out" in *"feat/scan working-tree scan failed"*) pass "11: WARN reports working-tree scan failed" ;; *) fail "11: expected 'working-tree scan failed' for feat/scan" "$out" ;; esac

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
