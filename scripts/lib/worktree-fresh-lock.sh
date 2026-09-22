#!/usr/bin/env bash
# worktree-fresh-lock.sh — HIMMEL-3297 (option B): is a worktree's leg still
# holding a FRESH scripts/handover/queue-lock.sh lock on its own handover doc?
#
# WHY: a leg's handover doc records the worktree it runs in as `resume_cwd:`
# in its frontmatter, and the leg holds queue-lock.sh's lock on that SAME doc
# for its whole life (released only at wrap). clean-garden.sh's fleet-wide
# prune already refuses a worktree that is some live process's CWD
# (worktree_in_use, lib/worktree-inuse.sh, HIMMEL-2227) — but a leg's cwd can
# fall back to the primary checkout while the leg is still mid-wrap, and the
# window between that and the lock's actual release is exactly when a
# fleet-wide sweep pruned a live leg's tree out from under it (HIMMEL-3297).
# The lock, not the process cwd, is the leg's real "done with it" signal.
#
# HOW: reverse the normal doc -> lock lookup. For every lock dir under every
# handover root queue-lock.sh itself knows about, read the doc path straight
# out of its owner.json (the field queue-lock.sh treats as authoritative),
# read that doc's `resume_cwd:` frontmatter, and compare it to the worktree
# under consideration. A match whose lock is FRESH — queue-lock.sh's own
# `status` verdict, never re-derived here — blocks the prune.
#
# Provides one function for any caller about to attempt a `git worktree
# remove`:
#   worktree_fresh_locked <path>   -- probe BEFORE the remove
#
# DO NOT add set -e / set -euo pipefail at file scope — this is a sourced
# library; that would leak into the sourcing shell. queue-lock.sh itself sets
# `set -uo pipefail` when executed, which is why it is sourced inside a
# command-substitution subshell below rather than at this file's top level.

# shellcheck disable=SC2034  # WORKTREE_FRESH_LOCK_DETAIL is an output contract global, read by sourcing scripts
WORKTREE_FRESH_LOCK_DETAIL=""

_WFL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_WFL_QUEUE_LOCK="$_WFL_SCRIPT_DIR/../handover/queue-lock.sh"

# _wfl_resume_cwd <doc> — the doc's `resume_cwd:` frontmatter value, or
# empty. Frontmatter is the block between the first two `---` lines; a
# `resume_cwd:` found outside it (prose, a code block) must never match.
_wfl_resume_cwd() {
    awk '
        /^---[[:space:]]*$/ { fm++; if (fm == 2) exit; next }
        fm == 1 && /^resume_cwd:[[:space:]]*/ {
            sub(/^resume_cwd:[[:space:]]*/, "")
            print
            exit
        }
    ' "$1" 2>/dev/null
}

# _wfl_find_fresh_doc <normalized-worktree-path> — prints the handover doc
# path on a match (its lock is FRESH), else prints nothing and returns 1.
# Runs inside the command-substitution subshell worktree_fresh_locked forks,
# so sourcing queue-lock.sh here (for _ql_lock_roots / _ql_json_field /
# queue_lock_status — its own documented in-process sourcing contract) never
# changes the calling script's shell options.
_wfl_find_fresh_doc() {
    local wt_norm="$1" root lockdir doc rcwd rcwd_norm out
    # shellcheck source=../handover/queue-lock.sh
    . "$_WFL_QUEUE_LOCK"
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        [ -d "$root/.locks/queue" ] || continue
        for lockdir in "$root"/.locks/queue/*.lock; do
            [ -d "$lockdir" ] || continue
            [ -f "$lockdir/owner.json" ] || continue
            doc=$(_ql_json_field "$lockdir/owner.json" handover)
            [ -n "$doc" ] || continue
            [ -f "$doc" ] || continue
            rcwd=$(_wfl_resume_cwd "$doc")
            [ -n "$rcwd" ] || continue
            rcwd_norm=$(cd "$rcwd" 2>/dev/null && pwd) || rcwd_norm="$rcwd"
            [ "$rcwd_norm" = "$wt_norm" ] || continue
            out=$(queue_lock_status "$doc" 2>/dev/null) || true
            case "$out" in
                *"status: FRESH"*)
                    printf '%s\n' "$doc"
                    return 0
                    ;;
            esac
        done
    done <<EOF
$(_ql_lock_roots)
EOF
    return 1
}

# worktree_fresh_locked <path> — 0 = a FRESH lock's leg doc names this
# worktree as its resume_cwd, do not prune; 1 = no such lock (free, STALE,
# or no match at all). Sets WORKTREE_FRESH_LOCK_DETAIL naming the leg doc on
# a true return.
worktree_fresh_locked() {
    local wt="$1" wt_norm doc
    WORKTREE_FRESH_LOCK_DETAIL=""
    wt_norm=$(cd "$wt" 2>/dev/null && pwd) || wt_norm="$wt"
    doc=$(_wfl_find_fresh_doc "$wt_norm") || return 1
    [ -n "$doc" ] || return 1
    WORKTREE_FRESH_LOCK_DETAIL="its leg's handover doc still holds a FRESH queue lock: $doc"
    return 0
}
