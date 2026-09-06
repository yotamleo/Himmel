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
# Set once this process has printed the Darwin no-/proc WARN below, so a
# sweep over many worktrees (clean-garden's normal shape) prints it ONCE per
# run, not once per tree.
WORKTREE_INUSE_DARWIN_WARNED=""
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

    # HIMMEL-2602 -- the rename probe below is a NO-OP on Linux. POSIX rename
    # does not care about open file handles or a process's cwd, so `mv "$path"
    # "$probe"` succeeds unconditionally there even with a live holder inside
    # $path -- MEASURED on this station:
    #   p=$(mktemp -d "${TMPDIR:-/tmp}/wt-inuse-repro.XXXXXX"); mkdir -p "$p/held/sub"
    #   setsid nohup bash -c "cd $p/held/sub && sleep 60" &
    #   mv "$p/held" "$p/held.probe"     ->  RENAME SUCCEEDED
    # so on Linux the rename probe alone always reports "free to remove",
    # holder or not. worktree_has_live_suite_run (merge-on-green.sh,
    # HIMMEL-2517) already proved the fix for one narrow population -- a live
    # process whose argv names run-shell-tests.sh/quiet-run.sh -- by scanning
    # /proc/*/cwd, because `ps` reports argv but not cwd. This generalizes
    # that same technique to ANY live process: the underlying gap is not
    # specific to suite runners, it is that a rename can't see a POSIX holder
    # at all. Run BEFORE the rename below: once a holder is confirmed here,
    # actually renaming the tree buys nothing (it will succeed regardless)
    # and would just be a pointless mutation.
    #
    # CONTRACT (revised 2026-09-06, same day as the first post-HIMMEL-2584
    # merge): a live process's cwd inside $path is only a FOREIGN holder --
    # and therefore blocks the remove -- when it is NOT in the CALLING
    # process's own ancestry (this process, its parent, its parent's parent,
    # ..., up to pid 1). A process in that chain is not a hazard sitting in
    # the tree; it IS the chain that asked for this removal, and refusing on
    # it would break the exact auto-prune (HIMMEL-1970) this whole mechanism
    # exists to make safe -- merge-on-green's own armed chain leg sits in the
    # tree it just merged, and that leg is this process's own ancestor.
    #
    # This is a BROADER exclusion than "skip this shell's own pid/cwd" (an
    # earlier draft of this fix): {self} is a subset of the ancestry chain,
    # so ancestry excludes more processes, not fewer. HIMMEL-2517 was
    # written when a merge was always LEG-run, so the merge process's own
    # ancestry naturally included the leg holding the tree and no exclusion
    # was needed. Merges are now CONSOLE-run while the leg still holds its
    # tree, and the very first post-HIMMEL-2584 merge (PR #2179) showed why
    # the scan must exist at all -- a FOREIGN holder OUTSIDE the merge
    # process's ancestry must still block the prune, or it removes a tree
    # out from under a live leg -- not why ancestry beats self-only. The
    # real reason: merge-on-green's own armed chain leg holds the tree as
    # this process's ANCESTOR, and a self-only exclusion would misclassify
    # that ancestor as foreign, refusing the prune and breaking
    # HIMMEL-1970's auto-prune. T10 and 11k14 pin that case; T9 covers the
    # trivial hop-0 self case.
    #
    # HIMMEL-2602 CR fix -- gate on Linux AND /proc/self, not /proc/self alone.
    # A bare `[ -d /proc/self ]` does not establish Linux: MSYS2/Cygwin (Git
    # Bash for Windows) also expose a /proc, so that test alone could let this
    # branch run on Windows. This scan's /proc/<pid>/cwd walk is written
    # against Linux's procfs specifically -- on MSYS/Cygwin there is no
    # guarantee the per-pid cwd symlinks resolve the way it expects, and if
    # they silently don't, every pid fails to resolve, inuse_found_cwd stays
    # 0, and the fail-closed arm below ("in-use-scan-failed") refuses EVERY
    # prune on Windows -- exactly the "blanket-refusing every removal on
    # every non-Linux station" outcome the comment further below says must
    # not happen, because Windows must keep the rename probe, which is the
    # only MEASURED detector there (see the repro table at the top of this
    # file). Requiring `uname -s` = Linux closes that gap while the /proc/self
    # test still guards a Linux kernel with no procfs mounted -- that host
    # still falls through to the rename probe rather than crashing.
    if [ "$(uname -s 2>/dev/null)" = "Linux" ] && [ -d /proc/self ]; then
        # Resolve to the PHYSICAL path with `pwd -P`, not plain `cd`+`pwd` and
        # not a raw string compare -- because a fixture path under /tmp can
        # itself be a symlink on some hosts, and /proc/<pid>/cwd (below) is
        # always the fully-resolved physical path. `cd` is LOGICAL by default
        # and plain `pwd` prints $PWD with symlink components preserved, so
        # `cd "$path" && pwd` still returns a path carrying $path's own
        # symlink components -- comparing THAT against a resolved /proc cwd
        # would never match, and a worktree addressed through a symlinked
        # ancestor would report NO holder even with one present, i.e. free
        # to remove. `pwd -P` resolves symlinks the same way `readlink -f`
        # does, so both sides of the comparison are physical.
        local inuse_path_real
        inuse_path_real=$(cd "$path" 2>/dev/null && pwd -P) || inuse_path_real="$path"

        # Ancestry set, this process included: " pid1 pid2 pid3 ... " with a
        # bounding space on every side, so `case ... in *" $x "*)` is an exact
        # token match rather than a substring match against neighbouring pids.
        #
        # $BASHPID, not $$: $$ reports the TOP-LEVEL shell's pid even from
        # inside a command-substitution subshell -- a bash quirk, not a bug,
        # but this is a sourced library with no control over whether its
        # caller invokes it from one, and the actually-running process is the
        # one whose ancestry matters. Falls back to $$ if BASHPID is somehow
        # unset (only reachable outside bash, which this /proc-gated branch
        # never is).
        #
        # /proc/<pid>/status's "PPid:" line, not /proc/<pid>/stat's positional
        # field: stat's 2nd field (comm) is the process name IN PARENTHESES
        # and can itself contain spaces or parentheses, shifting every field
        # after it -- status's line-per-field form has no such hazard, and
        # awk splitting on its default whitespace handles the field's
        # tab-or-space separator either way.
        local inuse_self_pid="${BASHPID:-$$}"
        local inuse_ancestry=" $inuse_self_pid "
        local inuse_walk_pid="$inuse_self_pid" inuse_ppid inuse_walk_i=0
        while [ "$inuse_walk_pid" != "1" ] && [ "$inuse_walk_i" -lt 200 ]; do
            inuse_walk_i=$((inuse_walk_i + 1))
            inuse_ppid=$(awk '/^PPid:/{print $2; exit}' "/proc/$inuse_walk_pid/status" 2>/dev/null)
            [ -n "$inuse_ppid" ] || break
            case "$inuse_ancestry" in
                *" $inuse_ppid "*) break ;;  # cycle guard -- should be impossible, never loop forever
            esac
            inuse_ancestry="$inuse_ancestry$inuse_ppid "
            inuse_walk_pid="$inuse_ppid"
        done

        local inuse_entry inuse_pid inuse_cwd inuse_found_cwd=0
        for inuse_entry in /proc/[0-9]*; do
            inuse_pid="${inuse_entry#/proc/}"
            # Gated on /proc/self above, i.e. Linux only.
            inuse_cwd=$(readlink -f "$inuse_entry/cwd" 2>/dev/null) || continue  # gnu-ok: /proc is Linux-only, where readlink -f is coreutils' own and always present
            # A failed readlink on OTHER users' processes (permission denied)
            # is normal and expected -- tolerate it per-pid. It is only a
            # TOTAL failure to resolve anything, across every pid, that is
            # suspicious (checked below, after the loop).
            inuse_found_cwd=1
            case "$inuse_cwd" in
                "$inuse_path_real"|"$inuse_path_real"/*)
                    case "$inuse_ancestry" in
                        *" $inuse_pid "*)
                            # In the calling process's own ancestry -- the
                            # chain that ASKED for this removal, not a
                            # foreign holder. Keep scanning: a DIFFERENT,
                            # genuinely foreign process could still be
                            # holding the same tree.
                            continue
                            ;;
                    esac
                    WORKTREE_INUSE_RESULT="in-use-confirmed"
                    WORKTREE_INUSE_DETAIL="Process $inuse_pid has its working directory at '$inuse_cwd', inside '$path' -- confirmed via /proc, not inferred from a blocked rename."
                    return 0
                    ;;
            esac
        done
        if [ "$inuse_found_cwd" -eq 0 ]; then
            # /proc is present and readable but not ONE pid's cwd resolved --
            # not what an ordinary permission-restricted scan looks like (this
            # process's own cwd always resolves). Fail CLOSED rather than
            # trust an ordinary rename probe that is already known to be a
            # no-op on this platform.
            WORKTREE_INUSE_RESULT="in-use-scan-failed"
            WORKTREE_INUSE_DETAIL="/proc is present but no process cwd could be resolved across ANY pid, which is not how a normal scan looks -- treating this as unable to confirm the tree is free rather than trusting the rename probe, which is a known no-op on this platform. Refusing to remove '$path' out of caution."
            return 0
        fi
    fi
    # Not Linux, or no procfs: fall through to the rename probe below
    # UNCHANGED. Do not fail closed here -- on Windows the rename probe is a
    # real, MEASURED detector (see the repro table at the top of this file), so
    # blanket-refusing every removal on every non-Linux station would disable
    # pruning everywhere for no safety gain. A POSIX host without /proc
    # (macOS) keeps today's pre-existing weak behaviour -- a known gap, not
    # one this change closes.
    #
    # Darwin gets a one-time WARN naming that gap: it has no /proc to scan,
    # and (like Linux) POSIX rename does not care about open handles or a
    # process's cwd either -- so the rename probe below is just as weak there
    # as it always was, and a macOS operator pruning would otherwise get a
    # silent skip-the-check rather than a real detector. Windows/MSYS is
    # explicitly NOT warned: there the rename probe IS a real, measured
    # detector (the 4/4 table above), so there is nothing to warn about.
    # lsof/fuser as an actual Darwin detector is the tracked follow-up on
    # HIMMEL-2602, not implemented here.
    if [ -z "$WORKTREE_INUSE_DARWIN_WARNED" ] && [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
        WORKTREE_INUSE_DARWIN_WARNED=1
        echo "worktree-inuse: this platform (Darwin) has no /proc to scan for a live holder -- in-use detection here falls back to the rename probe alone, which does NOT detect a holder (POSIX rename ignores open handles/cwd, same as Linux). See HIMMEL-2602." >&2
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
