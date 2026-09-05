#!/usr/bin/env bash
# test-worktree-inuse.sh — self-contained tests for worktree_in_use /
# worktree_intact (scripts/lib/worktree-inuse.sh, HIMMEL-2227).
#
# Usage: bash scripts/lib/test-worktree-inuse.sh
# Exit:  0 = all pass, 1 = one or more failures.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMPDIR_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/worktree-inuse.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline (a here-string, not a pipe), so `set -o pipefail` never turns a
# SUCCESSFUL early-match into a reported failure (see test-merge-on-green.sh's
# own grepq for the same trap).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

_pass=0
_fail=0
pass() { echo "PASS: $1"; _pass=$((_pass + 1)); }
fail() { echo "FAIL: $1"; _fail=$((_fail + 1)); }

WT_INUSE_LIB="$SCRIPT_DIR/worktree-inuse.sh"
# shellcheck source=scripts/lib/worktree-inuse.sh
# shellcheck disable=SC1091
if ! . "$WT_INUSE_LIB" 2>/dev/null; then
    echo "SKIP: $WT_INUSE_LIB not found — tests would all fail with source error"
    echo "      Create scripts/lib/worktree-inuse.sh, then re-run this test."
    exit 1
fi

# ── T1: worktree_in_use on a free directory -> free, renamed straight back ──
# Carries a `.git` stub because every REAL caller only ever passes a worktree
# path (which always has one) -- the FIX 1 post-verify below requires it to
# confirm the rename-back actually landed at $path rather than nesting inside
# a directory something else created there in the interim (see T5).
t1_dir="$TMPDIR_ROOT/t1-wt"
mkdir -p "$t1_dir"
touch "$t1_dir/.git"
if worktree_in_use "$t1_dir"; then
    fail "T1: a free directory was reported in-use"
else
    pass "T1: a free directory is reported free (rc 1)"
fi
if [ -d "$t1_dir" ]; then
    pass "T1: the original path exists after the probe"
else
    fail "T1: the original path is gone after the probe"
fi
if [ -e "$t1_dir.worktree-inuse-probe" ]; then
    fail "T1: a stranded probe path was left behind"
else
    pass "T1: no probe path left behind"
fi

# ── T2: worktree_in_use when a probe path already exists -> probe-stranded ──
t2_dir="$TMPDIR_ROOT/t2-wt"
mkdir -p "$t2_dir"
mkdir -p "$t2_dir.worktree-inuse-probe"
if worktree_in_use "$t2_dir"; then
    pass "T2: a pre-existing stray probe is reported in-use (rc 0)"
else
    fail "T2: a pre-existing stray probe was NOT reported in-use"
fi
if [ "$WORKTREE_INUSE_RESULT" = "probe-stranded" ]; then
    pass "T2: result is probe-stranded"
else
    fail "T2: result was '$WORKTREE_INUSE_RESULT', expected probe-stranded"
fi
## Both the probe AND the original path exist here, so the mv-back advice
## would be destructive (it would nest the probe inside $path) -- the detail
## must name both paths and tell the operator to inspect by hand instead.
if grepq "$WORKTREE_INUSE_DETAIL" -F "$t2_dir.worktree-inuse-probe" && grepq "$WORKTREE_INUSE_DETAIL" -F "$t2_dir" && ! grepq "$WORKTREE_INUSE_DETAIL" -F "mv '"; then
    pass "T2: detail names both paths and does not advise mv"
else
    fail "T2: detail did not name both paths without an mv command: $WORKTREE_INUSE_DETAIL"
fi
rm -rf "$t2_dir.worktree-inuse-probe"

# ── T3: worktree_in_use on a genuinely held tree (Windows-gated) ────────────
# A native Windows process holding a directory is the only thing MEASURED to
# block the rename probe (see worktree-inuse.sh's own repro table) — an MSYS
# bash holder does not, so this case is not constructible on other platforms.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        PWSH=$(command -v pwsh || command -v powershell || true)
        if [ -z "$PWSH" ]; then
            echo "  SKIP: T3 — no pwsh/powershell on PATH, cannot hold a directory natively"
        else
            t3_dir="$TMPDIR_ROOT/t3-wt"
            mkdir -p "$t3_dir"
            # Ready marker lives OUTSIDE the worktree (a sibling path): an
            # extra untracked file INSIDE it would perturb the very rename
            # behaviour under test. cygpath -m (not a bare argv pass) so a
            # native pwsh.exe gets the real Windows path, not MSYS's naive
            # /tmp -> C:\tmp argv mangling (a different, wrong root).
            ready="$t3_dir.test-ready"
            ready_win=$(cygpath -m "$ready" 2>/dev/null || printf '%s' "$ready")
            rm -f "$ready"
            ( cd "$t3_dir" && "$PWSH" -NoProfile -Command "New-Item -ItemType File '$ready_win' | Out-Null; Start-Sleep 30" ) &
            HOLDER=$!
            tries=0
            while [ ! -f "$ready" ] && [ "$tries" -lt 100 ]; do
                sleep 0.1
                tries=$((tries + 1))
            done
            if [ ! -f "$ready" ]; then
                fail "T3: the pwsh holder never signaled ready — cannot exercise the in-use case"
            else
                if worktree_in_use "$t3_dir"; then
                    pass "T3: a directory held by a native process is reported in-use"
                else
                    fail "T3: a directory held by a native process was NOT reported in-use"
                fi
                if [ "$WORKTREE_INUSE_RESULT" = "in-use-skipped" ]; then
                    pass "T3: result is in-use-skipped"
                else
                    fail "T3: result was '$WORKTREE_INUSE_RESULT', expected in-use-skipped"
                fi
                if [ -d "$t3_dir" ]; then
                    pass "T3: the held directory survives the probe"
                else
                    fail "T3: the held directory is gone after the probe"
                fi
            fi
            # ALWAYS kill the holder, pass or fail, or the suite leaves an
            # orphan pwsh process behind.
            kill "$HOLDER" 2>/dev/null
            wait "$HOLDER" 2>/dev/null
        fi
        ;;
    *)
        echo "  SKIP: T3 — not Windows; a held cwd blocks neither rename nor rmdir on POSIX (HIMMEL-2227)"
        ;;
esac

# ── T4: worktree_intact ──────────────────────────────────────────────────────
mk_wt() {
    # echoes: <repo> <worktree>
    local root repo wt
    root=$(mktemp -d "$TMPDIR_ROOT/worktree-inuse-fx.XXXXXX") || return 1
    repo="$root/repo"
    git init -q --initial-branch=main "$repo" 2>/dev/null || {
        git init -q "$repo"; git -C "$repo" symbolic-ref HEAD refs/heads/main || true
    }
    git -C "$repo" config user.email t@test.com
    git -C "$repo" config user.name t
    printf 'base\n' > "$repo/README"
    git -C "$repo" add README
    git -C "$repo" commit -q -m base
    wt="$root/wt"
    git -C "$repo" worktree add -q "$wt" -b feat/wt-inuse-test >/dev/null 2>&1
    printf '%s %s\n' "$repo" "$wt"
}

# T4a: a whole worktree (both .git and its admin row present) is intact.
read -r T4A_REPO T4A_WT <<< "$(mk_wt)"
if worktree_intact "$T4A_REPO" "$T4A_WT"; then
    pass "T4a: a whole worktree is intact"
else
    fail "T4a: a whole worktree was reported NOT intact"
fi

# T4b: still registered in `worktree list`, but its own .git link is gone.
read -r T4B_REPO T4B_WT <<< "$(mk_wt)"
rm -f "$T4B_WT/.git"
if worktree_intact "$T4B_REPO" "$T4B_WT"; then
    fail "T4b: a worktree missing its .git was reported intact"
else
    pass "T4b: a worktree missing its .git is NOT intact"
fi

# T4c: the measured HIMMEL-2227 wreck shape — contents removed, admin row
# pruned away, then the directory reappears empty (the same reproduction
# test-merge-on-green.sh's 11k3 case drives through a git-remove shim).
read -r T4C_REPO T4C_WT <<< "$(mk_wt)"
rm -rf "$T4C_WT"
git -C "$T4C_REPO" worktree prune >/dev/null 2>&1
mkdir -p "$T4C_WT"
if worktree_intact "$T4C_REPO" "$T4C_WT"; then
    fail "T4c: a worktree with its admin row pruned was reported intact"
else
    pass "T4c: a worktree with its admin row pruned is NOT intact"
fi

# ── T5: rename-back NESTS the tree instead of restoring it (codex-1) ───────
# If a directory gets created at $path in the window between the two renames,
# `mv "$probe" "$path"` still returns 0 -- but it moves the probe INSIDE that
# new directory instead of onto it, so a naive "mv succeeded -> free" verdict
# would report a tree that is no longer at $path as free to remove (the exact
# data-loss shape this probe exists to prevent). Deterministic via a shell
# function shadowing `mv`: bash resolves a function before PATH, so the
# sourced worktree_in_use() calls THIS `mv`, letting the test inject the race
# at the exact right instant instead of trying to win a real one.
t5_dir="$TMPDIR_ROOT/t5-wt"
mkdir -p "$t5_dir"
touch "$t5_dir/.git"
t5_mv_calls=0
mv() {
    t5_mv_calls=$((t5_mv_calls + 1))
    if [ "$t5_mv_calls" -eq 2 ]; then
        # Simulate a concurrent process creating a directory at $2 (the
        # rename-back target) between the two renames.
        mkdir -p "$2"
    fi
    command mv "$@"
}
if worktree_in_use "$t5_dir"; then
    pass "T5: a rename-back that nests the tree is reported in-use (rc 0), not free"
else
    fail "T5: a rename-back that nested the tree was reported FREE -- data-loss shape"
fi
if [ "$WORKTREE_INUSE_RESULT" = "probe-stranded" ]; then
    pass "T5: result is probe-stranded"
else
    fail "T5: result was '$WORKTREE_INUSE_RESULT', expected probe-stranded"
fi
if grepq "$WORKTREE_INUSE_DETAIL" -F "$t5_dir" \
    && grepq "$WORKTREE_INUSE_DETAIL" -F "$t5_dir.worktree-inuse-probe" \
    && ! grepq "$WORKTREE_INUSE_DETAIL" -F "mv '" \
    && ! grepq "$WORKTREE_INUSE_DETAIL" -F "rm '"; then
    pass "T5: detail names both paths and contains no mv/rm command"
else
    fail "T5: detail did not name both paths without an mv/rm command: $WORKTREE_INUSE_DETAIL"
fi
unset -f mv

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
