# shellcheck shell=bash
# cr-default-base.sh — HIMMEL-3107: the ONE ref a CR floor review's diff base
# must be an ancestor of. Sourced by scripts/cr/claude-floor-review.sh (the
# producer) and scripts/cr/clear-cr-marker.sh (the gate), so both bind the same
# ref. Only the REMOTE default branch counts: a local main can hold commits that
# are still mid-PR, and a base on it would validate a partial-range review.

# cr_default_base_ref — print origin/HEAD's target, else refs/remotes/origin/main.
# Returns 1 when neither resolves to a commit; callers refuse (fail-closed).
cr_default_base_ref() {
    local ref
    if ref=$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) &&
        git rev-parse --verify -q "$ref^{commit}" >/dev/null 2>&1; then
        printf '%s\n' "$ref"; return 0
    fi
    git rev-parse --verify -q 'refs/remotes/origin/main^{commit}' >/dev/null 2>&1 || return 1
    printf '%s\n' refs/remotes/origin/main
}
