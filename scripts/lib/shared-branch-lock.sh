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
# HIMMEL-1558 added the acquire-wait verb and the namespace knob. Both are
# ADDITIVE: the frozen acquire/release/status behaviour the lane
# implementations depend on is unchanged (they pass no namespace, so they keep
# the default lock root, and `acquire` still never steals a lock).
#
# USAGE (invoke as a script, one verb per call):
#   bash shared-branch-lock.sh acquire <worktree-or-repo-dir> <branch> <lane>
#   bash shared-branch-lock.sh acquire-wait <worktree-or-repo-dir> <branch> <lane> <wait-secs> <ttl-secs>
#   bash shared-branch-lock.sh release <worktree-or-repo-dir> <branch>
#   bash shared-branch-lock.sh release-if-owner <worktree-or-repo-dir> <branch> <expected-owner-json>
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
#   acquire-wait (HIMMEL-1558): same codes as acquire, except 11 means "still
#             held after <wait-secs>" -- the holder info and a timeout line are
#             printed to stderr. A lock whose recorded age exceeds <ttl-secs>
#             is RECLAIMED (released, then re-acquired) with a loud stderr
#             trail. <ttl-secs> 0 disables reclamation.
#   status:   0  free -- nothing printed to stdout beyond "free"
#             11 held -- owner.json contents printed to stdout
#             2  usage error
#
# LOCK LOCATION: the lock is a DIRECTORY (mkdir is atomic -- no TOCTOU race
# between "check" and "create") at:
#   <git-common-dir>/<namespace>/<slug>.lock
# where <slug> is the branch name with every character outside
# [a-zA-Z0-9-] replaced by "-". The git COMMON dir (not the per-worktree
# .git file) is shared by every worktree of the same repo, so a worktree
# path and the primary checkout path resolve to the SAME lock -- that is
# what makes the lock effective across `git worktree add` clones.
#
# NAMESPACE (HIMMEL-1558): <namespace> is "himmel-shared-branch" unless
# SHARED_BRANCH_LOCK_NS names a different single path segment. A second
# concern that needs branch-scoped mutual exclusion (the CR marker lock, which
# serializes clear-cr-marker.sh against the pre-push marker writer) reuses this
# primitive under its OWN namespace instead of duplicating a lock library --
# sharing one namespace would make an offload lane holding the shared-branch
# COMMIT lock block an unrelated marker write for the whole wait.
#
# NOTE (coarse slugging, intentional): distinct branch names that collapse
# to the same slug (e.g. "feat/x.y_z" and "feat-x-y-z") share ONE lock. This
# is accepted coarseness, not a bug -- a false "already held" is safe (it
# just blocks two unrelated branches from running concurrently); a false
# "free" would not be.
#
# NO AUTO-STEAL, NO PID-LIVENESS PROBING: this file deliberately does not
# try to detect a crashed holder itself. Windows-native PIDs under MSYS bash
# do not map cleanly onto the POSIX pid space `kill -0` expects, so that check
# belongs to the cross-namespace reconciler (reconcile-workers.sh). Acquire
# records SHARED_BRANCH_LOCK_HOLDER_PID when its dispatcher supplies one;
# otherwise it preserves the historical diagnostic fallback of this shell's
# pid. Stale locks are cleared by the reconciler or an explicit release.
#
# TTL RECLAMATION (acquire-wait only, HIMMEL-1558): reclamation is driven by
# the acquired_epoch owner.json records at acquire time -- a timestamp WE
# wrote -- never by pid liveness, for the reason the note above gives. An
# unknown age (no owner.json, unparseable epoch, clock moved backwards) is
# never stale: the safe direction is to keep waiting, since a false "stale"
# steals a LIVE holder's lock while a false "fresh" only costs a wait. `acquire`
# itself is unchanged and still never steals.
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

# _sbl_ns -- print the lock-root namespace (see NAMESPACE above). A namespace
# is one path segment: anything containing a separator (or . / ..) would let a
# caller point the lock root outside the git common dir, so it is refused.
_sbl_ns() {
    _sbl_ns_val="${SHARED_BRANCH_LOCK_NS:-himmel-shared-branch}"
    case "$_sbl_ns_val" in
        ''|*/*|*\\*|.|..)
            echo "shared-branch-lock: invalid SHARED_BRANCH_LOCK_NS '$_sbl_ns_val' -- must be a single path segment" >&2
            return 1
            ;;
    esac
    printf '%s' "$_sbl_ns_val"
}

# _sbl_lockdir <dir> <branch> -- print the absolute lock directory path for
# <branch> as seen from <dir>. Returns 1 if <dir> does not resolve to a git
# common dir, or the namespace is invalid.
_sbl_lockdir() {
    _sbl_ldir_repo="$1"
    _sbl_ldir_branch="$2"
    _sbl_ldir_common="$(_sbl_common_dir "$_sbl_ldir_repo")" || return 1
    _sbl_ldir_ns="$(_sbl_ns)" || return 1
    _sbl_ldir_slug="$(_sbl_slug "$_sbl_ldir_branch")"
    printf '%s/%s/%s.lock\n' "$_sbl_ldir_common" "$_sbl_ldir_ns" "$_sbl_ldir_slug"
}

# _sbl_owner_age <owner-json> -- print the age in seconds of the holder record
# passed IN, derived from the acquired_epoch it carries. Returns 1 when the age
# cannot be established (see TTL RECLAMATION above); an unknown age is never
# stale.
#
# The record is passed in rather than re-read from disk (CR round 3, codex-1):
# the caller acts on BOTH the age ("is it stale") and the identity ("whose is
# it"), so they must come from ONE read. Re-reading let the lock change hands
# in between, after which the FRESH owner's record was handed to _sbl_reclaim
# as the record judged stale -- and a live lock was deleted.
_sbl_owner_age() {
    _sbl_age_owner="$1"
    [ -n "$_sbl_age_owner" ] || return 1
    _sbl_age_epoch="$(printf '%s' "$_sbl_age_owner" | sed -n 's/.*"acquired_epoch":\([0-9][0-9]*\).*/\1/p' | head -1)"
    case "$_sbl_age_epoch" in ''|*[!0-9]*) return 1 ;; esac
    _sbl_age_now="$(date +%s 2>/dev/null)"
    case "$_sbl_age_now" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_sbl_age_now" -ge "$_sbl_age_epoch" ] || return 1
    printf '%s' $((_sbl_age_now - _sbl_age_epoch))
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
        _sbl_a_holder_pid="${SHARED_BRANCH_LOCK_HOLDER_PID:-$$}"
        case "$_sbl_a_holder_pid" in
            ''|*[!0-9]*|0) _sbl_a_holder_pid="$$" ;;
        esac
        # owner.json is DIAGNOSTIC -- the lock is held by the dir itself. A
        # write failure here does not un-hold the lock, so warn and keep rc 0
        # (I4) rather than failing an acquire that actually succeeded.
        # acquired_epoch is the machine-readable twin of acquired_at: TTL
        # reclamation must not parse an ISO timestamp (`date -d` is GNU-only,
        # macOS ships BSD date). An unavailable clock OMITS the field, which
        # _sbl_owner_age reads as an unknown (never stale) age rather than as
        # epoch 0, i.e. instantly reclaimable.
        _sbl_a_epoch="$(date +%s 2>/dev/null)"
        case "$_sbl_a_epoch" in ''|*[!0-9]*) _sbl_a_epoch="" ;; esac
        if ! printf '{"pid":%s,"lane":"%s","branch":"%s","acquired_at":"%s"%s}\n' \
            "$_sbl_a_holder_pid" \
            "$(_sbl_json_escape "$_sbl_a_lane")" \
            "$(_sbl_json_escape "$_sbl_a_branch")" \
            "$_sbl_a_now" \
            "${_sbl_a_epoch:+,\"acquired_epoch\":$_sbl_a_epoch}" \
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

# _sbl_reclaim <lockdir> <expected-owner-json> -- take a lock judged stale away
# from its holder, but ONLY if it is still the SAME holder. Returns 0 when the
# stale lock is gone and the caller may try to acquire; 1 otherwise.
#
# NOT a plain rm (HIMMEL-1558 CR, codex-1): between the age check and the
# removal the stale holder can release and ANOTHER writer acquire, and an
# unconditional rm would then delete that live lock -- two writers on the
# marker, the exact failure this lock exists to prevent. So the removal is a
# RENAME: rename is atomic, so of two racing reclaimers exactly one wins and
# the loser's mv fails instead of deleting the winner's fresh lock. After the
# rename the directory is ours alone, so the holder record can finally be
# verified; a record that is NOT the one judged stale means the lock changed
# hands, and it is put BACK untouched.
#
# RESIDUAL (documented, not hidden -- HIMMEL-1558 CR round 2, codex-1): the
# owner can only be verified AFTER the rename, because verifying it requires
# exclusive possession of the directory, and no filesystem primitive here
# offers compare-and-swap. So for the instant between the rename and a failed
# verification's restore, the canonical path is free and a third writer can
# acquire it. This cannot be closed at this layer; it is closed at the layer
# above, by the rule every caller follows: A HOLDER RE-VERIFIES THAT IT STILL
# OWNS THE LOCK IMMEDIATELY BEFORE ITS DECISIVE ACTION and aborts if it does
# not (clear-cr-marker.sh before the unlink, check-cr-before-push.sh around
# the marker write). A displaced holder therefore refuses instead of acting,
# so "displaced" degrades to a refused operation, never to two writers
# proceeding. Every path in this function fails toward "keep waiting".
_sbl_reclaim() {
    _sbl_rc_lockdir="$1"
    _sbl_rc_expect="$2"
    _sbl_rc_q="${_sbl_rc_lockdir}.stale.$$"
    rm -rf "$_sbl_rc_q" 2>/dev/null
    # A leftover quarantine (our own pid's, from a crash) would make the mv
    # below nest the lock INSIDE it instead of renaming it. Refuse instead.
    if [ -e "$_sbl_rc_q" ]; then
        return 1
    fi
    mv "$_sbl_rc_lockdir" "$_sbl_rc_q" 2>/dev/null || return 1
    _sbl_rc_got="$(cat "$_sbl_rc_q/owner.json" 2>/dev/null)"
    if [ "$_sbl_rc_got" != "$_sbl_rc_expect" ]; then
        mv "$_sbl_rc_q" "$_sbl_rc_lockdir" 2>/dev/null || rm -rf "$_sbl_rc_q" 2>/dev/null
        return 1
    fi
    rm -rf "$_sbl_rc_q" 2>/dev/null
    if [ -d "$_sbl_rc_q" ]; then
        return 1
    fi
    return 0
}

# shared_branch_lock_acquire_wait <dir> <branch> <lane> <wait-secs> <ttl-secs>
# Bounded-wait acquire with TTL reclamation (HIMMEL-1558). Polls once a second
# until <wait-secs> has elapsed. The holder block `acquire` prints is captured
# per attempt and emitted ONCE (on the final failure) instead of every second.
shared_branch_lock_acquire_wait() {
    _sbl_w_dir="${1:-}"
    _sbl_w_branch="${2:-}"
    _sbl_w_lane="${3:-}"
    _sbl_w_wait="${4:-}"
    _sbl_w_ttl="${5:-}"
    case "$_sbl_w_wait" in ''|*[!0-9]*) _sbl_w_wait="" ;; esac
    case "$_sbl_w_ttl" in ''|*[!0-9]*) _sbl_w_ttl="" ;; esac
    if [ -z "$_sbl_w_dir" ] || [ -z "$_sbl_w_branch" ] || [ -z "$_sbl_w_lane" ] ||
       [ -z "$_sbl_w_wait" ] || [ -z "$_sbl_w_ttl" ]; then
        echo "usage: shared-branch-lock.sh acquire-wait <worktree-or-repo-dir> <branch> <lane> <wait-secs> <ttl-secs>" >&2
        return 2
    fi

    _sbl_w_lockdir="$(_sbl_lockdir "$_sbl_w_dir" "$_sbl_w_branch")"
    if [ -z "$_sbl_w_lockdir" ]; then
        echo "shared-branch-lock: could not derive git common dir for '$_sbl_w_dir'" >&2
        return 2
    fi

    _sbl_w_started="$(date +%s 2>/dev/null)"
    case "$_sbl_w_started" in ''|*[!0-9]*) _sbl_w_started="" ;; esac
    while :; do
        _sbl_w_err="$(shared_branch_lock_acquire "$_sbl_w_dir" "$_sbl_w_branch" "$_sbl_w_lane" 2>&1)"
        _sbl_w_rc=$?
        if [ "$_sbl_w_rc" -eq 0 ]; then
            [ -z "$_sbl_w_err" ] || printf '%s\n' "$_sbl_w_err" >&2
            return 0
        fi
        if [ "$_sbl_w_rc" -ne 11 ]; then
            # A real failure (unwritable lock root, bad namespace) is not
            # something waiting can fix -- surface it immediately.
            [ -z "$_sbl_w_err" ] || printf '%s\n' "$_sbl_w_err" >&2
            return "$_sbl_w_rc"
        fi

        # ONE read of the holder record; both the staleness verdict and the
        # identity _sbl_reclaim verifies against come from it (CR round 3).
        _sbl_w_owner="$(cat "$_sbl_w_lockdir/owner.json" 2>/dev/null)"
        if [ "$_sbl_w_ttl" -gt 0 ] && _sbl_w_age="$(_sbl_owner_age "$_sbl_w_owner")" &&
           [ "$_sbl_w_age" -gt "$_sbl_w_ttl" ]; then
            echo "shared-branch-lock: RECLAIMING a stale lock for branch '$_sbl_w_branch' (held ${_sbl_w_age}s, ttl ${_sbl_w_ttl}s) -- its holder is gone or wedged:" >&2
            [ -z "$_sbl_w_owner" ] || printf '%s\n' "$_sbl_w_owner" >&2
            if _sbl_reclaim "$_sbl_w_lockdir" "$_sbl_w_owner"; then
                # Retry at once; if another waiter took it first its lock is
                # fresh again and this falls back to the ordinary wait below.
                continue
            fi
            # Not stolen (it changed hands, or another reclaimer won the
            # rename). Fall through to the wait -- never `continue`, which
            # would skip the deadline check and spin.
            echo "shared-branch-lock: the stale lock for branch '$_sbl_w_branch' changed hands while it was being reclaimed -- not stealing it; still waiting." >&2
        fi

        if [ -z "$_sbl_w_started" ]; then
            break
        fi
        _sbl_w_now="$(date +%s 2>/dev/null)"
        case "$_sbl_w_now" in ''|*[!0-9]*) break ;; esac
        [ $((_sbl_w_now - _sbl_w_started)) -lt "$_sbl_w_wait" ] || break
        sleep 1
    done

    [ -z "$_sbl_w_err" ] || printf '%s\n' "$_sbl_w_err" >&2
    echo "shared-branch-lock: timed out after ${_sbl_w_wait}s waiting for the lock on branch '$_sbl_w_branch'" >&2
    return 11
}

# shared_branch_lock_release_if_owner <dir> <branch> <expected-owner-json>
# Release ONLY if the lock is still held by the owner the caller recorded when
# it acquired (HIMMEL-1558 CR round 2, codex-3). Plain `release` is an
# unconditional rm, so a holder that reads the owner record and then releases
# has a check-then-act window: the lock can be reclaimed and re-acquired in
# between, and the release then deletes the NEW holder's lock. This verb has
# no such window -- it reuses the same rename-then-verify removal reclamation
# uses, so the record is compared while the directory is exclusively ours.
#   0  released: the lock was ours right up to the moment it was removed
#   3  NOT ours: still held by someone else, OR already ABSENT
#   2  usage error / underivable lock dir
#
# rc 0 is PROOF OF EXCLUSION, which is why an absent lock is rc 3 and not an
# idempotent success (HIMMEL-1558 CR round 8, codex-1). A caller that still
# held the lock would find the directory present -- it never released it. An
# absent directory therefore means someone ELSE removed it: the lock was
# TTL-reclaimed, and the reclaimer already finished and released. Reporting
# that as success told check-cr-before-push.sh its marker write had been
# mutually excluded when it had not, letting a starved writer's push proceed
# after clobbering a newer certificate. Both callers release exactly once
# behind a held-flag, so nothing here relies on a second release returning 0.
shared_branch_lock_release_if_owner() {
    _sbl_ro_dir="${1:-}"
    _sbl_ro_branch="${2:-}"
    _sbl_ro_expect="${3:-}"
    if [ -z "$_sbl_ro_dir" ] || [ -z "$_sbl_ro_branch" ] || [ -z "$_sbl_ro_expect" ]; then
        echo "usage: shared-branch-lock.sh release-if-owner <worktree-or-repo-dir> <branch> <expected-owner-json>" >&2
        return 2
    fi
    _sbl_ro_lockdir="$(_sbl_lockdir "$_sbl_ro_dir" "$_sbl_ro_branch")"
    if [ -z "$_sbl_ro_lockdir" ]; then
        echo "shared-branch-lock: could not derive git common dir for '$_sbl_ro_dir'" >&2
        return 2
    fi
    if [ ! -d "$_sbl_ro_lockdir" ]; then
        echo "shared-branch-lock: the lock for branch '$_sbl_ro_branch' is already GONE -- this run cannot have been holding it, so its critical section was not mutually excluded." >&2
        return 3
    fi
    if _sbl_reclaim "$_sbl_ro_lockdir" "$_sbl_ro_expect"; then
        return 0
    fi
    echo "shared-branch-lock: NOT releasing the lock for branch '$_sbl_ro_branch' -- it is no longer held by the expected owner (it was reclaimed and re-acquired); the current holder keeps it." >&2
    return 3
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
        acquire-wait)
            shared_branch_lock_acquire_wait "$@"
            ;;
        release)
            shared_branch_lock_release "$@"
            ;;
        release-if-owner)
            shared_branch_lock_release_if_owner "$@"
            ;;
        status)
            shared_branch_lock_status "$@"
            ;;
        *)
            echo "usage: shared-branch-lock.sh <acquire|acquire-wait|release|release-if-owner|status> <worktree-or-repo-dir> <branch> [lane|owner-json] [wait-secs] [ttl-secs]" >&2
            return 2
            ;;
    esac
}

# Sourcing guard (bash 3.2-safe form of "is this file executed, not sourced").
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    _sbl_main "$@"
    exit $?
fi
