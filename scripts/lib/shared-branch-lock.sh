#!/usr/bin/env bash
# shared-branch-lock.sh -- serialize commits onto one caller-named shared
# branch across parallel offload-lane dispatchers (HIMMEL-800).
#
# WHY: HIMMEL-800 lets an offload lane run in an opt-in "shared branch" mode
# where multiple workers commit serially onto ONE existing branch instead of
# each getting its own throwaway branch. That only stays safe if exactly one
# worker writes at a time (the single-writer invariant, CLAUDE.md Subagent
# policy). This file is the FROZEN serialization primitive both lane
# implementations call before touching the shared branch -- it owns nothing
# about git itself (no commit/push), only "am I allowed to write right now".
#
# USAGE (invoke as a script, one verb per call):
#   bash shared-branch-lock.sh acquire <worktree-or-repo-dir> <branch> <lane>
#   bash shared-branch-lock.sh release <worktree-or-repo-dir> <branch>
#   bash shared-branch-lock.sh status  <worktree-or-repo-dir> <branch>
#
# EXIT CODES:
#   acquire:  0  lock acquired, owner.json written
#             11 already held by another lane/process -- holder info + the
#                manual-release recovery hint are printed to stderr
#             2  usage error (missing arg), the dir is not resolvable to a git
#                common dir, OR the lock dir could not be created for a reason
#                other than "already held" (unwritable/absent lock root,
#                permission error) -- the real mkdir error is printed to stderr
#   release:  0  the lock is gone (removed now, or was already absent -- idempotent)
#             3  the lock dir still exists after rm (e.g. an open handle on
#                Windows, or a permission problem) -- the lock is NOT released,
#                a loud error is printed to stderr
#             2  usage error
#   status:   0  free -- nothing printed to stdout beyond "free"
#             11 held -- owner.json contents printed to stdout
#             2  usage error
#
# LOCK LOCATION: the lock is a DIRECTORY (mkdir is atomic -- no TOCTOU race
# between "check" and "create") at:
#   <git-common-dir>/himmel-shared-branch/<slug>.lock
# where <slug> is the branch name with every character outside
# [a-zA-Z0-9-] replaced by "-". The git COMMON dir (not the per-worktree
# .git file) is shared by every worktree of the same repo, so a worktree
# path and the primary checkout path resolve to the SAME lock -- that is
# what makes the lock effective across `git worktree add` clones.
#
# NOTE (coarse slugging, intentional): distinct branch names that collapse
# to the same slug (e.g. "feat/x.y_z" and "feat-x-y-z") share ONE lock. This
# is accepted coarseness, not a bug -- a false "already held" is safe (it
# just blocks two unrelated branches from running concurrently); a false
# "free" would not be.
#
# NO AUTO-STEAL, NO PID-LIVENESS PROBING: this file deliberately does not
# try to detect a crashed holder (no `kill -0`). Windows-native PIDs under
# MSYS bash do not map cleanly onto the POSIX pid space `kill -0` expects,
# so a liveness probe would be unreliable in exactly the environment this
# repo runs on -- a false "the holder is dead, steal the lock" is a
# single-writer violation, which is worse than a false "still held". Stale
# locks (crashed dispatcher, killed session) are cleared by a human or a
# supervising process running `release` explicitly. `acquire`'s rc-11
# message says so.
#
# CONVENTIONS: bash 3.2-safe (no associative arrays, no ${var,,}, no
# mapfile). `set -uo pipefail`, not -e -- callers care about specific exit
# codes, so failures are checked explicitly rather than aborting the script.
# ASCII only in this file (ASCII-only rule, HIMMEL repo convention; a
# non-ASCII char on a line a shellcheck finding lands on crashes shellcheck).

set -uo pipefail

# _sbl_common_dir <dir> -- print the absolute git COMMON dir for <dir> to
# stdout. Works whether <dir> is the primary checkout or any of its
# worktrees. Returns 1 if <dir> is not inside a git repo.
_sbl_common_dir() {
    _sbl_dir="$1"
    _sbl_out="$(git -C "$_sbl_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    if [ -n "$_sbl_out" ]; then
        printf '%s\n' "$_sbl_out"
        return 0
    fi
    # Fallback for git versions that predate --path-format (2.31-).
    _sbl_out="$(git -C "$_sbl_dir" rev-parse --git-common-dir 2>/dev/null)"
    if [ -z "$_sbl_out" ]; then
        return 1
    fi
    case "$_sbl_out" in
        /*|[A-Za-z]:/*|[A-Za-z]:\\*)
            # Already absolute.
            printf '%s\n' "$_sbl_out"
            return 0
            ;;
    esac
    # Relative result (e.g. ".git" or "../otherrepo/.git") -- resolve it
    # relative to <dir> via cd + pwd -P (no readlink -f on all platforms).
    _sbl_resolved="$(cd "$_sbl_dir" 2>/dev/null && cd "$_sbl_out" 2>/dev/null && pwd -P)"
    if [ -z "$_sbl_resolved" ]; then
        return 1
    fi
    printf '%s\n' "$_sbl_resolved"
    return 0
}

# _sbl_slug <branch> -- print the filesystem-safe lock slug for <branch>.
_sbl_slug() {
    printf '%s' "$1" | tr -c 'a-zA-Z0-9-' '-'
}

# _sbl_json_escape <str> -- minimal JSON string escaping (backslash, quote).
_sbl_json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# _sbl_lockdir <dir> <branch> -- print the absolute lock directory path for
# <branch> as seen from <dir>. Returns 1 if <dir> does not resolve to a git
# common dir.
_sbl_lockdir() {
    _sbl_ldir_repo="$1"
    _sbl_ldir_branch="$2"
    _sbl_ldir_common="$(_sbl_common_dir "$_sbl_ldir_repo")" || return 1
    _sbl_ldir_slug="$(_sbl_slug "$_sbl_ldir_branch")"
    printf '%s/himmel-shared-branch/%s.lock\n' "$_sbl_ldir_common" "$_sbl_ldir_slug"
}

# shared_branch_lock_acquire <dir> <branch> <lane>
shared_branch_lock_acquire() {
    _sbl_a_dir="${1:-}"
    _sbl_a_branch="${2:-}"
    _sbl_a_lane="${3:-}"
    if [ -z "$_sbl_a_dir" ] || [ -z "$_sbl_a_branch" ] || [ -z "$_sbl_a_lane" ]; then
        echo "usage: shared-branch-lock.sh acquire <worktree-or-repo-dir> <branch> <lane>" >&2
        return 2
    fi

    _sbl_a_lockdir="$(_sbl_lockdir "$_sbl_a_dir" "$_sbl_a_branch")"
    if [ -z "$_sbl_a_lockdir" ]; then
        echo "shared-branch-lock: could not derive git common dir for '$_sbl_a_dir'" >&2
        return 2
    fi

    _sbl_a_lockroot="$(dirname "$_sbl_a_lockdir")"
    # An unchecked mkdir -p here would let a failure (unwritable/absent lock
    # root, or a FILE sitting where the lock root should be) surface only as a
    # false "already held" below; instead let it fall through to the mkdir of
    # the lock dir, whose captured error drives the rc-2 real-failure path.
    mkdir -p "$_sbl_a_lockroot" 2>/dev/null

    # Capture the mkdir stderr rather than discarding it: on failure we must
    # tell "already held" (EEXIST -- keep rc 11) apart from a genuine error
    # (rc 2, C2), and the operator needs the real message for the latter.
    if _sbl_a_mkerr="$(mkdir "$_sbl_a_lockdir" 2>&1)"; then
        _sbl_a_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        # owner.json is DIAGNOSTIC -- the lock is held by the dir itself. A
        # write failure here does not un-hold the lock, so warn and keep rc 0
        # (I4) rather than failing an acquire that actually succeeded.
        if ! printf '{"pid":%s,"lane":"%s","branch":"%s","acquired_at":"%s"}\n' \
            "$$" \
            "$(_sbl_json_escape "$_sbl_a_lane")" \
            "$(_sbl_json_escape "$_sbl_a_branch")" \
            "$_sbl_a_now" \
            > "$_sbl_a_lockdir/owner.json" 2>/dev/null; then
            echo "shared-branch-lock: owner.json write failed (lock held anyway)" >&2
        fi
        return 0
    fi

    # mkdir failed. If the lock dir now exists it is a genuine "already held"
    # (another writer owns it); if it does NOT exist the mkdir failed for a
    # real reason (unwritable/absent lock root, permission) -- surface that
    # distinctly as rc 2 with the captured error, not a misleading rc 11.
    if [ -d "$_sbl_a_lockdir" ]; then
        echo "shared-branch-lock: already held for branch '$_sbl_a_branch':" >&2
        if [ -f "$_sbl_a_lockdir/owner.json" ]; then
            cat "$_sbl_a_lockdir/owner.json" >&2
        else
            echo "(owner.json missing -- lock dir exists but is mid-acquire or corrupt)" >&2
        fi
        echo "recovery: if the holder is a crashed/stale dispatcher, clear it manually with:" >&2
        echo "  bash shared-branch-lock.sh release '$_sbl_a_dir' '$_sbl_a_branch'" >&2
        return 11
    fi
    echo "shared-branch-lock: cannot create lock dir '$_sbl_a_lockdir': ${_sbl_a_mkerr:-mkdir failed}" >&2
    return 2
}

# shared_branch_lock_release <dir> <branch> -- idempotent, always rc 0 on
# valid args (rc 2 only on usage/derivation errors).
shared_branch_lock_release() {
    _sbl_r_dir="${1:-}"
    _sbl_r_branch="${2:-}"
    if [ -z "$_sbl_r_dir" ] || [ -z "$_sbl_r_branch" ]; then
        echo "usage: shared-branch-lock.sh release <worktree-or-repo-dir> <branch>" >&2
        return 2
    fi

    _sbl_r_lockdir="$(_sbl_lockdir "$_sbl_r_dir" "$_sbl_r_branch")"
    if [ -z "$_sbl_r_lockdir" ]; then
        echo "shared-branch-lock: could not derive git common dir for '$_sbl_r_dir'" >&2
        return 2
    fi

    rm -rf "$_sbl_r_lockdir" 2>/dev/null
    # rm -rf on an absent path is rc 0 (idempotent), but a rm that FAILED to
    # remove an existing dir (open handle on Windows, permission) must not be
    # reported as a successful release -- the branch would still be blocked
    # while callers believe it freed (C1). Distinguish by re-checking existence.
    if [ -d "$_sbl_r_lockdir" ]; then
        echo "shared-branch-lock: failed to remove lock dir '$_sbl_r_lockdir' -- it still exists (likely an open handle on Windows, or a permission problem); the lock is NOT released" >&2
        return 3
    fi
    return 0
}

# shared_branch_lock_status <dir> <branch>
shared_branch_lock_status() {
    _sbl_s_dir="${1:-}"
    _sbl_s_branch="${2:-}"
    if [ -z "$_sbl_s_dir" ] || [ -z "$_sbl_s_branch" ]; then
        echo "usage: shared-branch-lock.sh status <worktree-or-repo-dir> <branch>" >&2
        return 2
    fi

    _sbl_s_lockdir="$(_sbl_lockdir "$_sbl_s_dir" "$_sbl_s_branch")"
    if [ -z "$_sbl_s_lockdir" ]; then
        echo "shared-branch-lock: could not derive git common dir for '$_sbl_s_dir'" >&2
        return 2
    fi

    if [ -d "$_sbl_s_lockdir" ]; then
        if [ -f "$_sbl_s_lockdir/owner.json" ]; then
            cat "$_sbl_s_lockdir/owner.json"
        else
            echo "(owner.json missing -- lock dir exists but is mid-acquire or corrupt)"
        fi
        return 11
    fi

    echo "free"
    return 0
}

# _sbl_main <verb> <args...> -- CLI dispatch. Only runs when this file is
# executed directly (not sourced), so tests can source it and call the
# shared_branch_lock_* functions in-process.
_sbl_main() {
    _sbl_verb="${1:-}"
    if [ -n "$_sbl_verb" ]; then
        shift
    fi
    case "$_sbl_verb" in
        acquire)
            shared_branch_lock_acquire "$@"
            ;;
        release)
            shared_branch_lock_release "$@"
            ;;
        status)
            shared_branch_lock_status "$@"
            ;;
        *)
            echo "usage: shared-branch-lock.sh <acquire|release|status> <worktree-or-repo-dir> <branch> [lane]" >&2
            return 2
            ;;
    esac
}

# Sourcing guard (bash 3.2-safe form of "is this file executed, not sourced").
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    _sbl_main "$@"
    exit $?
fi
