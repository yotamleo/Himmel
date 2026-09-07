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

# ── T6-T10: HIMMEL-2602 -- the /proc-based live-holder detector on Linux ─────
# The rename probe (T3, above) is Windows-only in what it can catch: on POSIX
# a process's cwd blocks neither the rename nor the rmdir, so it always
# reports "free to remove" there, holder or not. These rows exercise the
# separate /proc scan that now runs BEFORE that probe on Linux.
case "$(uname -s)" in
    Linux)
        # wait_cwd <pid> <expected-dir> -- block until /proc/<pid>/cwd resolves
        # to <expected-dir>, so the probe below never races the holder's own
        # `cd`. Bounded (5s) so a holder that never starts fails loud, not by
        # hanging the suite -- returns 1 if the holder never anchored so every
        # call site can `fail` the control instead of silently proceeding to
        # assert against a holder that was never actually there (codex-2: a
        # holder that never starts would otherwise make a negative control
        # pass for the wrong reason).
        wait_cwd() {
            local pid="$1" want="$2" tries=0
            while [ "$(readlink -f "/proc/$pid/cwd" 2>/dev/null)" != "$want" ] && [ "$tries" -lt 50 ]; do  # gnu-ok: this whole T6-T10 block is uname-gated to Linux, where /proc exists and readlink -f is coreutils' own
                sleep 0.1
                tries=$((tries + 1))
            done
            [ "$(readlink -f "/proc/$pid/cwd" 2>/dev/null)" = "$want" ]  # gnu-ok: same Linux-only gate as the loop above
        }

        # ── T6: a live process's cwd INSIDE the tree -> in-use, pid named ───
        t6_dir="$TMPDIR_ROOT/t6-wt"
        mkdir -p "$t6_dir/sub"
        touch "$t6_dir/.git"
        # shellcheck disable=SC2016  # $1 is the CHILD bash's own positional arg (set via the trailing `_ "$t6_dir/sub"`), not meant to expand in this shell
        setsid nohup bash -c 'cd "$1" || exit 1; sleep 30' _ "$t6_dir/sub" >/dev/null 2>&1 &
        T6_HOLDER=$!
        if ! wait_cwd "$T6_HOLDER" "$(cd "$t6_dir/sub" 2>/dev/null && pwd -P)"; then
            fail "T6: the holder never anchored its cwd -- control not established"
        else
            if worktree_in_use "$t6_dir"; then
                pass "T6: a directory held by a live process cwd is reported in-use (rc 0)"
            else
                fail "T6: a directory held by a live process cwd was NOT reported in-use"
            fi
            if [ "$WORKTREE_INUSE_RESULT" = "in-use-confirmed" ]; then
                pass "T6: result is in-use-confirmed"
            else
                fail "T6: result was '$WORKTREE_INUSE_RESULT', expected in-use-confirmed"
            fi
            if grepq "$WORKTREE_INUSE_DETAIL" -F "$T6_HOLDER"; then
                pass "T6: detail names the holder pid"
            else
                fail "T6: detail did not name pid $T6_HOLDER: $WORKTREE_INUSE_DETAIL"
            fi
            if [ -d "$t6_dir" ]; then
                pass "T6: the held directory survives the probe (no rename was attempted)"
            else
                fail "T6: the held directory is gone after the probe"
            fi
        fi
        # ALWAYS kill the holder, pass or fail, or the suite leaves an orphan
        # sleeper behind.
        kill "$T6_HOLDER" 2>/dev/null
        wait "$T6_HOLDER" 2>/dev/null

        # ── T7: control -- the SAME fixture shape with NO holder -> free ────
        # Guards against a blanket "always in-use" fix that would disable
        # pruning entirely rather than actually detecting a holder.
        t7_dir="$TMPDIR_ROOT/t7-wt"
        mkdir -p "$t7_dir"
        touch "$t7_dir/.git"
        if worktree_in_use "$t7_dir"; then
            fail "T7: an unheld directory was reported in-use"
        else
            pass "T7: an unheld directory is reported free (rc 1)"
        fi

        # ── T8: boundary -- a holder in a SIBLING path sharing a prefix ─────
        # "<wt>-sibling" is not inside "<wt>"; only an exact match or a
        # "<wt>/"-prefixed cwd may count.
        t8_dir="$TMPDIR_ROOT/t8-wt"
        t8_sibling="${t8_dir}-sibling"
        mkdir -p "$t8_dir" "$t8_sibling"
        touch "$t8_dir/.git"
        # shellcheck disable=SC2016  # $1 is the CHILD bash's own positional arg (set via the trailing `_ "$t8_sibling"`), not meant to expand in this shell
        setsid nohup bash -c 'cd "$1" || exit 1; sleep 30' _ "$t8_sibling" >/dev/null 2>&1 &
        T8_HOLDER=$!
        if ! wait_cwd "$T8_HOLDER" "$(cd "$t8_sibling" 2>/dev/null && pwd -P)"; then
            fail "T8: the holder never anchored its cwd -- control not established"
        else
            if worktree_in_use "$t8_dir"; then
                fail "T8: a holder in a SIBLING path was reported in-use -- boundary broken"
            else
                pass "T8: a holder in a sibling path sharing a prefix is reported free (rc 1) -- boundary respected"
            fi
        fi
        kill "$T8_HOLDER" 2>/dev/null
        wait "$T8_HOLDER" 2>/dev/null

        # ── T9: the CALLING process's own cwd inside the tree -> PRUNABLE ───
        # HIMMEL-2602 contract revision (2026-09-06): worktree_in_use now
        # excludes the calling process's own ANCESTRY (this process, its
        # parent, ... up to pid 1) from what counts as a foreign holder -- a
        # process in that chain is the one that ASKED for the removal, not a
        # hazard sitting in the tree (merge-on-green's own armed chain leg is
        # exactly this shape: it sits in the tree it just merged). A subshell
        # whose own cwd IS the fixture is, by definition, its own ancestry --
        # this row therefore INVERTS from the earlier "in-use" expectation to
        # "prunable" (rc 1, no RESULT/DETAIL set -- the ordinary free-to-remove
        # path). Nothing to reap, no background sleeper needed: the subshell
        # itself is the live process under test.
        t9_dir="$TMPDIR_ROOT/t9-wt"
        mkdir -p "$t9_dir"
        touch "$t9_dir/.git"
        t9_out=$(cd "$t9_dir" && worktree_in_use "$t9_dir"; echo "rc=$?"; echo "RESULT=$WORKTREE_INUSE_RESULT"; echo "DETAIL=$WORKTREE_INUSE_DETAIL")
        if grepq "$t9_out" -F "rc=1"; then
            pass "T9: the calling process's own cwd inside the worktree is reported prunable (rc 1) -- own ancestry excluded"
        else
            fail "T9: own-cwd-inside case was not reported prunable: $t9_out"
        fi
        if grepq "$t9_out" -Fx "RESULT="; then
            pass "T9: no RESULT tag set for the own-ancestry free path"
        else
            fail "T9: expected an EMPTY RESULT (the ordinary free-to-remove path never sets one): $t9_out"
        fi

        # ── T10: a PARENT (not self) has cwd inside the tree -> PRUNABLE ────
        # T9 only exercises the trivial hop-0 case (the caller's OWN cwd). This
        # proves the actual PPid WALK: a child process, whose OWN cwd is
        # elsewhere, must still recognize its PARENT sitting in the tree as
        # its own ancestry -- the real shape of "merge-on-green's own armed
        # chain leg", where the leg (an ancestor) holds the tree and the
        # in-process merge itself has already cd'd elsewhere.
        t10_dir="$TMPDIR_ROOT/t10-wt"
        t10_elsewhere="$TMPDIR_ROOT"
        mkdir -p "$t10_dir"
        touch "$t10_dir/.git"
        t10_out=$(
            cd "$t10_dir" || exit 1
            # Backgrounded, so this is a GENUINE fork (never optimized into an
            # exec-in-place of the parent) -- the child's PPid really is this
            # cd'd-in subshell, not itself.
            bash -c '
                cd "$1" || exit 1
                # shellcheck source=scripts/lib/worktree-inuse.sh
                # shellcheck disable=SC1091
                . "$2"
                worktree_in_use "$3"
                echo "rc=$?"; echo "RESULT=$WORKTREE_INUSE_RESULT"; echo "DETAIL=$WORKTREE_INUSE_DETAIL"
            ' _ "$t10_elsewhere" "$WT_INUSE_LIB" "$t10_dir" &
            t10_child=$!
            wait "$t10_child"
        )
        if grepq "$t10_out" -F "rc=1"; then
            pass "T10: a PARENT process's cwd inside the tree is reported prunable (rc 1) -- ancestry walk, not just self"
        else
            fail "T10: parent-in-tree case was not reported prunable: $t10_out"
        fi
        if grepq "$t10_out" -Fx "RESULT="; then
            pass "T10: no RESULT tag set for the parent-ancestry free path"
        else
            fail "T10: expected an EMPTY RESULT: $t10_out"
        fi

        # ── T11: HIMMEL-2602 fix 1 (codex-1) -- a worktree addressed through a
        # SYMLINKED ancestor component, held by a live process cwd -> in-use ──
        # worktree_in_use resolves $path with `pwd -P` (physical) before
        # comparing it against /proc/<pid>/cwd (always physical). A plain
        # `cd "$path" && pwd` (LOGICAL, preserves symlink components) would
        # never match a physical /proc cwd whenever $path passes through a
        # symlink, silently reporting the tree free even with a live holder
        # inside it -- the exact data-loss direction this whole fix exists to
        # close. RC-1 above already proves the /proc arm itself is load-
        # bearing; this row proves the canonicalization inside that arm is
        # physical, not logical -- it must FAIL against a pre-fix plain `pwd`
        # and PASS with `pwd -P` (measured directly, not asserted, in the
        # scratch-mutant check this ticket's verification step runs).
        t11_root="$TMPDIR_ROOT/t11-root"
        mkdir -p "$t11_root/real/wt/sub"
        touch "$t11_root/real/wt/.git"
        ln -s "$t11_root/real" "$t11_root/link"
        # shellcheck disable=SC2016  # $1 is the CHILD bash's own positional arg (set via the trailing `_ "$t11_root/link/wt/sub"`), not meant to expand in this shell
        setsid nohup bash -c 'cd "$1" || exit 1; sleep 30' _ "$t11_root/link/wt/sub" >/dev/null 2>&1 &
        T11_HOLDER=$!
        if ! wait_cwd "$T11_HOLDER" "$(cd "$t11_root/real/wt/sub" 2>/dev/null && pwd -P)"; then
            fail "T11: the holder never anchored its cwd -- control not established"
        else
            if worktree_in_use "$t11_root/link/wt"; then
                pass "T11: a symlink-addressed worktree held by a live process is reported in-use (rc 0)"
            else
                fail "T11: a symlink-addressed worktree held by a live process was NOT reported in-use -- logical/physical path mismatch"
            fi
            if [ "$WORKTREE_INUSE_RESULT" = "in-use-confirmed" ]; then
                pass "T11: result is in-use-confirmed"
            else
                fail "T11: result was '$WORKTREE_INUSE_RESULT', expected in-use-confirmed"
            fi
            if grepq "$WORKTREE_INUSE_DETAIL" -F "$T11_HOLDER"; then
                pass "T11: detail names the holder pid"
            else
                fail "T11: detail did not name pid $T11_HOLDER: $WORKTREE_INUSE_DETAIL"
            fi
        fi
        # ALWAYS kill the holder, pass or fail, or the suite leaves an orphan
        # sleeper behind.
        kill "$T11_HOLDER" 2>/dev/null
        wait "$T11_HOLDER" 2>/dev/null

        unset -f wait_cwd
        ;;
    *)
        echo "  SKIP: T6-T10 — /proc-based live-holder detection is Linux-only (HIMMEL-2602)"
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

# ── RC-1: RED control — revert the /proc arm, T6's own fixture must flip ─────
# T6 above asserts the HIMMEL-2602 detector reports a live holder as in-use.
# That assertion is only load-bearing if the /proc arm is what produces it, so
# revert the real fix (never a stub) and show the SAME fixture shape flips back
# to the pre-fix answer: FREE. Neutralise the arm's gate with `false &&` rather
# than deleting the block — the diff is then exactly one line (verified below),
# the minimal faithful "the /proc arm never runs" mutation rather than a
# differently-shaped script. With the arm gone, control falls through to the
# rename probe, which is precisely the no-op this ticket exists to fix.
case "$(uname -s)" in
    Linux)
        # shellcheck disable=SC2016  # these are LITERAL text of the library's own gate line, matched verbatim against the file below -- not meant to expand here
        rc1_gate='    if [ "$(uname -s 2>/dev/null)" = "Linux" ] && [ -d /proc/self ]; then'
        # shellcheck disable=SC2016  # same as above -- literal text, not meant to expand here
        rc1_neutered='    if false && [ "$(uname -s 2>/dev/null)" = "Linux" ] && [ -d /proc/self ]; then'
        # Templated + shape-checked before anything is built on it: this path
        # feeds an `rm -rf` below, and an empty root there is the HIMMEL-2518
        # hazard. `fail` rather than `exit 1` — a scratch-dir failure must not
        # abort the suite mid-run and strand the summary.
        rc1_dir=$(mktemp -d "${TMPDIR:-/tmp}/worktree-inuse-rc1.XXXXXX")
        if [ -z "$rc1_dir" ] || [ ! -d "$rc1_dir" ]; then
            fail "RC-1 setup: mktemp -d produced no mutant sandbox — refusing to build fixture paths on an empty root"
        else
            rc1_mutant="$rc1_dir/worktree-inuse.mutant.sh"
            awk -v line="$rc1_gate" -v repl="$rc1_neutered" \
                '$0==line{print repl; next}{print}' "$WT_INUSE_LIB" > "$rc1_mutant"
            rc1_pre=$(grep -Fc -- "$rc1_gate" "$WT_INUSE_LIB")
            rc1_post=$(grep -Fc -- "$rc1_gate" "$rc1_mutant")
            # A one-line REPLACEMENT shows up in `diff` as a two-line hunk —
            # one `<` (the original) and one `>` (the neutered line) — so 2,
            # not 1, is the clean-single-line-substitution count here.
            rc1_diff=$(diff "$WT_INUSE_LIB" "$rc1_mutant" | grep -c '^[<>]')
            if [ "$rc1_pre" -eq 1 ] && [ "$rc1_post" -eq 0 ] && [ "$rc1_diff" -eq 2 ]; then
                rc1_wt="$rc1_dir/rc1-wt"
                mkdir -p "$rc1_wt/sub"
                touch "$rc1_wt/.git"
                # shellcheck disable=SC2016  # $1 is the CHILD bash's own positional arg (set via the trailing `_ "$rc1_wt/sub"`), not meant to expand in this shell
                setsid nohup bash -c 'cd "$1" || exit 1; sleep 30' _ "$rc1_wt/sub" >/dev/null 2>&1 &
                RC1_HOLDER=$!
                rc1_want=$(cd "$rc1_wt/sub" 2>/dev/null && pwd -P)
                rc1_tries=0
                while [ "$(readlink -f "/proc/$RC1_HOLDER/cwd" 2>/dev/null)" != "$rc1_want" ] && [ "$rc1_tries" -lt 50 ]; do  # gnu-ok: RC-1 is inside the same Linux-only case arm; /proc and readlink -f are guaranteed there
                    sleep 0.1
                    rc1_tries=$((rc1_tries + 1))
                done
                if [ "$(readlink -f "/proc/$RC1_HOLDER/cwd" 2>/dev/null)" != "$rc1_want" ]; then  # gnu-ok: same Linux-only gate as the loop above
                    fail "RC-1: the holder never anchored its cwd -- control not established"
                else
                    # Subshell: the mutant defines the SAME function name, and
                    # the real worktree_in_use must survive this block intact.
                    rc1_out=$(
                        # shellcheck source=scripts/lib/worktree-inuse.sh
                        # shellcheck disable=SC1090,SC1091
                        . "$rc1_mutant"
                        worktree_in_use "$rc1_wt"
                        echo "rc=$?"
                        echo "RESULT=$WORKTREE_INUSE_RESULT"
                    )
                    if grepq "$rc1_out" -Fx "rc=1"; then
                        pass "RC-1 RED confirmed: with the /proc arm reverted the SAME held fixture reports FREE (rc 1) — the pre-fix answer T6 exists to overturn, so T6 is not vacuously true"
                    elif grepq "$rc1_out" -Fx "rc=0"; then
                        fail "RC-1: the mutant STILL reported in-use ($rc1_out) — T6 is not proving what it claims; something other than the /proc arm answers here"
                    else
                        fail "RC-1: the mutant produced no usable rc ($rc1_out) — proves nothing"
                    fi
                fi
                # ALWAYS reap, pass or fail, or the suite leaves an orphan.
                kill "$RC1_HOLDER" 2>/dev/null
                wait "$RC1_HOLDER" 2>/dev/null
            else
                fail "RC-1 setup: mutation of the /proc arm gate was not reproduced cleanly (pre=$rc1_pre post=$rc1_post diff_lines=$rc1_diff)"
            fi
            rm -rf "$rc1_dir"
        fi
        ;;
    *)
        echo "  SKIP: RC-1 — the /proc arm it reverts is Linux-only (HIMMEL-2602)"
        ;;
esac

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
