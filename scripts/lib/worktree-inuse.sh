#!/usr/bin/env bash
# worktree-inuse.sh — shared predicate: is a live process holding a directory
# inside this worktree, and did a failed `git worktree remove` leave it whole?
#
# HIMMEL-2227. A plain `git worktree remove` is NOT atomic on Windows:
# git-for-Windows deletes with POSIX semantics, so an open handle does not
# stop the delete. MEASURED, in a throwaway repo:
#
#   holder kind                 rename probe    remove   dir    .git       entries  adminrows
#   control (nothing holding)   OK              OK       no     GONE       0        0
#   bash holding cwd at root    OK              OK       no     GONE       0        0
#   pwsh holding cwd at root    BLOCKED         FAIL     yes    GONE       0        0
#   pwsh holding cwd in subdir  BLOCKED         FAIL     yes    GONE       2        0
#
# With a NATIVE Windows process (pwsh/node) holding a directory inside the
# tree, `git worktree remove` deletes the CONTENTS, removes the `.git` file,
# removes the `git worktree list` admin row, and only THEN fails the final
# rmdir. Two consequences:
#   * A non-zero rc does NOT mean "refused up front, tree unchanged". It
#     usually means the tree is GUTTED and already deregistered.
#   * An MSYS bash holder does NOT trip this. It takes a native Windows
#     child. That is why a pure-bash caller never sees it and a full
#     test-suite run does.
# An atomic rename probe (`mv <wt> <wt>.probe`, rename straight back)
# predicted the outcome 4/4 and is strictly MORE conservative than git's
# rmdir.
#
# Provides two functions for any caller about to attempt (or that just
# attempted) a `git worktree remove`:
#   worktree_in_use <path>            -- probe BEFORE the remove
#   worktree_intact <primary> <path>  -- verify AFTER a FAILED remove
#
# DO NOT add set -e / set -euo pipefail at file scope — this is a sourced
# library; that would leak into the sourcing shell.

# shellcheck disable=SC2034  # WORKTREE_INUSE_RESULT and WORKTREE_INUSE_DETAIL are output contract globals, read by sourcing scripts

# HIMMEL-2227 — is a live process holding a directory inside this worktree?
# A `git worktree remove` is NOT atomic on Windows (see the repro table
# above): a held directory does not stop the delete, it only stops the FINAL
# rmdir, after the contents and the `worktree list` admin entry are already
# gone. This probe runs BEFORE the remove and predicts its outcome: renaming
# the worktree directory needs exactly the same precondition (nothing has it
# open) that the final rmdir needs, the rename is atomic, and it mutates
# nothing when it fails. Deliberately CONSERVATIVE, not a lock system:
# anything that blocks a rename also blocks the rmdir, so this can only
# over-skip, never under-skip, a remove that would otherwise fail partway.
# Best-effort by design: on POSIX a process's cwd blocks neither the rename
# nor the rmdir, so the probe is a no-op there and the ordinary remove path
# decides — which is fine, because on POSIX the remove itself succeeds
# cleanly (see the repro table above).
#
# This is still probe-then-act, not a lock: a successful round-trip proves
# only that nothing held the tree AT THAT MOMENT. A native process that opens
# a handle in the window between the probe returning and the caller's
# `git worktree remove` reproduces the exact failure this probe exists to
# predict. Closing that window needs a lock held across probe+remove, which
# this deliberately does not do — tracked as HIMMEL-2229. worktree_intact
# (below) is the backstop for that residual: a tree lost to this race is
# reported as gutted with a recovery recipe, never silently.
# Sets WORKTREE_INUSE_RESULT (a caller-facing outcome tag) and
# WORKTREE_INUSE_DETAIL (one sentence appended to the operator message).
# Returns 0 = in use, do not touch; 1 = free to remove.
WORKTREE_INUSE_RESULT=""
WORKTREE_INUSE_DETAIL=""
worktree_in_use() {
    local path="$1"
    local probe="${path}.worktree-inuse-probe"
    WORKTREE_INUSE_RESULT=""
    WORKTREE_INUSE_DETAIL=""

    if [ -e "$probe" ]; then
        WORKTREE_INUSE_RESULT="probe-stranded"
        # The mv-back advice is only safe when $path is empty (vacated) --
        # if $path ALSO exists, `mv "$probe" "$path"` moves the probe INSIDE
        # $path instead of restoring it, compounding the mess. Only name the
        # command when it is actually correct to run.
        if [ -e "$path" ]; then
            WORKTREE_INUSE_DETAIL="Both '$probe' and '$path' exist: the probe directory is a leftover from an earlier interrupted probe. Do not run mv or rm -- inspect both paths and reconcile them by hand."
        else
            WORKTREE_INUSE_DETAIL="A previous in-use probe never renamed back: '$probe' still exists. Recover with: mv '$probe' '$path'"
        fi
        return 0
    fi

    if ! mv "$path" "$probe" 2>/dev/null; then
        WORKTREE_INUSE_RESULT="in-use-skipped"
        # The rename block is OBSERVED; a live process holding the tree is the
        # LIKELY cause (same precondition the final rmdir needs), not one this
        # probe can actually confirm -- a permissions error or a vanished path
        # blocks the same mv.
        WORKTREE_INUSE_DETAIL="Renaming the worktree directory was blocked, which means the final removal step git needs would be blocked too -- most likely because a live process still has it open, though that was not directly confirmed."
        return 0
    fi

    if ! mv "$probe" "$path" 2>/dev/null; then
        # Should be impossible (we just renamed the other way), but never
        # silently leave a moved tree behind if it somehow happens.
        WORKTREE_INUSE_RESULT="probe-stranded"
        # Same reasoning as the stranded-probe branch above: the mv-back
        # advice is only safe when $path is vacated. $path being absent AT
        # THE MOMENT this message is generated does not mean it is still
        # absent when the operator reads it and runs the command -- so still
        # guard on it here rather than handing over an unconditional mv.
        if [ -e "$path" ]; then
            WORKTREE_INUSE_DETAIL="The in-use probe renamed the worktree to '$probe' and then failed to rename it back -- and '$path' is now occupied by something else. Do not run mv or rm -- inspect both '$probe' and '$path' and reconcile them by hand."
        else
            WORKTREE_INUSE_DETAIL="The in-use probe renamed the worktree to '$probe' and then failed to rename it BACK. Recover with: mv '$probe' '$path'"
        fi
        return 0
    fi

    # A successful `mv "$probe" "$path"` is NOT sufficient evidence the tree
    # was actually restored: if another process created a directory at $path
    # in the window between the two renames, this mv still returns 0 -- but
    # mv's into-existing-directory semantics mean it moved the worktree INSIDE
    # that new directory rather than restoring it at $path. Falling through to
    # "free to remove" here would hand the caller a `git worktree remove
    # "$path"` against something that is no longer the worktree. A git
    # worktree always has a `.git` entry at its root (worktree_intact below
    # relies on the same fact), so require it before trusting the round-trip.
    if [ ! -e "$path/.git" ]; then
        WORKTREE_INUSE_RESULT="probe-stranded"
        WORKTREE_INUSE_DETAIL="The in-use probe renamed the worktree to '$probe' and the rename back to '$path' reported success, but '$path/.git' is missing -- the worktree may now be nested inside '$path' rather than restored (something likely created a directory at '$path' during the probe). Do not run mv or rm -- inspect '$path' and '$probe' and reconcile them by hand."
        return 0
    fi

    return 1
}

# HIMMEL-2227 — after a failed `git worktree remove`, is the tree still
# WHOLE, or did the remove get partway through (delete contents + deregister,
# then fail the final rmdir)? Call this only on the failure path — it must
# never itself fail the caller's script.
#
# Scope: this checks two METADATA markers only -- the worktree's own `.git`
# link and its `git worktree list --porcelain` admin row. It does NOT inspect
# CONTENTS. A partial removal that deleted tracked files but left both
# markers behind still reads as "whole" here. A content check (e.g.
# `git ls-files --deleted`) was considered and deliberately rejected: a
# legitimately DIRTY worktree where the user themselves deleted a tracked
# file would then be misreported as gutted -- a worse error, and one that
# would break the "a genuinely dirty worktree is refused untouched" guarantee
# this whole HIMMEL-2227 fix exists to preserve. So "whole" here means "still
# registered with its .git link present", not "contents intact" -- callers
# must not claim more than that.
#
# Paths are normalised (cd + pwd) before comparing, because that porcelain
# listing can print a different-but-equivalent spelling of the same path
# (drive-letter case, slashes) on Windows; if the path no longer resolves,
# fall back to a plain string compare.
worktree_intact() {
    local primary="$1" path="$2"
    [ -e "$path/.git" ] || return 1

    local path_pwd
    path_pwd=$(cd "$path" 2>/dev/null && pwd) || path_pwd="$path"

    local line wt wt_pwd
    while IFS= read -r line; do
        case "$line" in
            "worktree "*)
                wt="${line#worktree }"
                wt_pwd=$(cd "$wt" 2>/dev/null && pwd) || wt_pwd="$wt"
                if [ "$wt_pwd" = "$path_pwd" ] || [ "$wt" = "$path" ]; then
                    return 0
                fi
                ;;
        esac
    done < <(git -C "$primary" worktree list --porcelain 2>/dev/null)
    return 1
}
