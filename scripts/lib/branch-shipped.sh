#!/usr/bin/env bash
# branch-shipped.sh — shared predicate: has this branch been merged via a PR?
#
# Purpose:
#   Provide branch_has_merged_pr <branch> <primary_worktree_dir>, a
#   fail-open, timeout-bounded predicate consumed by:
#     - the PreToolUse merged-PR commit guard (HIMMEL-512)
#     - the worktree-create path (skip creating a worktree for a merged branch)
#     - /himmel-doctor (C-series check)
#
# Contract:
#   rc 0 — forge reports >= 1 merged PR for the branch (definitely shipped)
#   rc 1 — forge reports 0 merged PRs, OR branch is main/master/HEAD/empty
#           (short-circuit; no forge call made)
#   rc 2 — uncertainty (fail-OPEN): forge call failed, timed out, or returned
#           a non-numeric payload; caller MUST treat this as "unknown, allow"
#
# Fail-open rationale:
#   This predicate is used as a PRUNE signal.  A false positive (pruning a
#   live worktree) is worse than a false negative (keeping a merged one).
#   On forge outage / offline use, rc 2 lets the caller continue safely.
#
# Seams (test overrides):
#   FORGE=github      bypass origin detection (test + mixed-remote use)
#   GH_CMD=<path>     override the `gh` binary
#   BRANCH_SHIPPED_TIMEOUT=N  timeout in seconds (default 10)
#   Note: FORGE / GH_CMD must be exported to propagate into the
#   timeout-wrapper subprocess (not merely set in shell scope).
#
# DO NOT add set -e / set -euo pipefail at file scope — this is a sourced
# library; that would leak into the sourcing shell.  Guard internally.

# Resolve dir of this file so we can source forge.sh regardless of cwd.
_BS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib/forge.sh
# shellcheck disable=SC1091
. "$_BS_LIB_DIR/forge.sh"

# _bs_timeout_cmd — pick the best available timeout command name.
# Prints the command name to stdout; prints nothing if none is available.
_bs_timeout_cmd() {
    if command -v timeout >/dev/null 2>&1; then
        printf 'timeout'
    elif command -v gtimeout >/dev/null 2>&1; then
        printf 'gtimeout'
    fi
}

# branch_has_merged_pr <branch> <primary_worktree_dir>
#
# Returns:
#   0  — branch has at least one merged PR
#   1  — branch has no merged PRs, or is a protected/empty name (no forge call)
#   2  — uncertain (fail-open): forge unavailable, timed out, or bad payload
branch_has_merged_pr() {
    local branch="${1:-}"
    local primary="${2:-}"

    # Short-circuit FIRST for protected / vacuous branch names — no forge call.
    # Empty branch is a special case of "no meaningful branch" → rc 1.
    case "$branch" in
        ""|main|master|HEAD)
            return 1
            ;;
    esac

    # Require primary_worktree_dir (only checked after short-circuit so that
    # empty-branch callers don't need to supply it).
    if [ -z "$primary" ]; then
        echo "branch_has_merged_pr: requires <primary_worktree_dir> as second arg" >&2
        return 2
    fi

    local timeout_secs="${BRANCH_SHIPPED_TIMEOUT:-10}"
    local tcmd
    tcmd="$(_bs_timeout_cmd)"

    # Build a small inline script that sources forge.sh and calls
    # forge_pr_has_merged.  This lets `timeout` wrap it as an external
    # process while still inheriting FORGE / GH_CMD from the environment.
    # The FORGE and GH_CMD env vars propagate automatically to the child
    # process because they are already exported (the test harness does
    # `export FORGE=github GH_CMD=...`).
    local wrapper_script
    wrapper_script="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f \"$wrapper_script\"" RETURN
    cat > "$wrapper_script" <<WRAPPER_EOF
#!/usr/bin/env bash
. "$_BS_LIB_DIR/forge.sh"
forge_pr_has_merged "\$1"
WRAPPER_EOF
    chmod +x "$wrapper_script"

    # Call the wrapper inside the primary worktree dir so forge_detect can
    # read the origin remote when FORGE is not set.
    # stderr suppressed (network noise / auth messages).
    local out rc
    if [ -n "$tcmd" ]; then
        out=$( ( cd "$primary" && "$tcmd" "$timeout_secs" bash "$wrapper_script" "$branch" ) 2>/dev/null )
        rc=$?
        # timeout/gtimeout exit 124 on expiry; any nonzero → rc 2 below.
    else
        # No timeout available — run unguarded (best-effort).
        out=$( ( cd "$primary" && bash "$wrapper_script" "$branch" ) 2>/dev/null )
        rc=$?
    fi

    # Map the result.
    # rc 2 unless (rc==0 AND out matches ^[0-9]+$); then rc 0 iff out > 0 else rc 1.
    if [ "$rc" -ne 0 ]; then
        return 2
    fi
    # Strip trailing whitespace so "2\n" or "2 " still match the numeric guard.
    out="${out%%[[:space:]]*}"
    if ! printf '%s' "$out" | grep -qE '^[0-9]+$' 2>/dev/null; then
        # Non-numeric or empty payload — defensive rc 2.
        return 2
    fi

    if [ "$out" -gt 0 ]; then
        return 0
    else
        return 1
    fi
}
