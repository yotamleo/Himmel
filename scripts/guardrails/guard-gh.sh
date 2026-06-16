#!/usr/bin/env bash
# scripts/guardrails/guard-gh.sh - verb/state dispatcher for himmel-gh.
#
# Usage:
#   guard-gh.sh pr-create [--allow-dirty] [--allow-merged-base] [other gh args...]
#   guard-gh.sh pr-push   [--allow-stale]                       [other gh args...]
#   guard-gh.sh pr-merge  [--admin] <PR-N>                       [other gh args...]
#
# Exit codes:
#   0 - proceed (no message on stderr; cleaned argv on stdout)
#   1 - proceed-with-warning (stderr explains; cleaned argv on stdout)
#   2 - refuse (stderr explains; stdout empty; do NOT run the underlying gh)
#
# Predicate errors (rc=2 from lib.sh) propagate as a fail-closed exit 2.
#
# Flag semantics:
#   --allow-dirty       : skip is_dirty refusal for pr-create
#   --allow-merged-base : skip is_merged_into_main refusal for pr-create
#   --allow-stale       : skip is_behind_origin_main warning for pr-push
#   GH_ADMIN_MERGE_OK=1 : env bypass for `pr-merge --admin` refusal
#
# Unknown flags pass through unchanged in the cleaned argv on stdout -
# `gh` handles them. The dispatcher inspects only the flags listed above,
# strips the `--allow-*` ones, and emits the remainder one-per-line.
# `--admin` is INSPECTED for the refusal decision but FORWARDED unchanged.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"

verb="${1:-}"
if [ -z "$verb" ]; then
    echo "guard-gh: missing verb (pr-create | pr-push | pr-merge)" >&2
    exit 2
fi
shift

# Parse known guard flags out; preserve unknown flags verbatim for forwarding.
allow_dirty=0
allow_merged_base=0
allow_stale=0
has_admin=0
forward=()
for arg in "$@"; do
    case "$arg" in
        --allow-dirty)        allow_dirty=1 ;;
        --allow-merged-base)  allow_merged_base=1 ;;
        --allow-stale)        allow_stale=1 ;;
        --admin)              has_admin=1; forward+=("$arg") ;;
        *)                    forward+=("$arg") ;;
    esac
done

# Emit cleaned argv on stdout (guard `--allow-*` flags stripped). One per
# line so callers can read with `mapfile -t`. Empty stdout = no forward args.
# `${forward[@]+"${forward[@]}"}` is the bash-3.2-safe expansion that handles
# `set -u` + empty arrays correctly (required for macOS default bash).
emit_forward() {
    for a in "${forward[@]+"${forward[@]}"}"; do
        printf '%s\n' "$a"
    done
}

# pred_check NAME [ARGS...] - evaluate a predicate fail-closed.
# Returns the predicate's rc (0 true / 1 false). rc=2 (internal error) is
# converted to an immediate exit 2 with a verb-tagged diagnostic so the
# dispatcher never silently fails-OPEN when git is broken or `main` is
# missing.
pred_check() {
    local name="$1"; shift
    "$name" "$@"
    local rc=$?
    if [ "$rc" -eq 2 ]; then
        echo "guard-gh: refusing $verb - $name returned rc=2 (cannot evaluate git state)" >&2
        exit 2
    fi
    return "$rc"
}

case "$verb" in
    pr-create)
        if pred_check is_on_main; then
            cat >&2 <<EOF
guard-gh: refusing pr-create - HEAD is on main.
Create a worktree and branch first:
    /clean_garden feat/<scope>
EOF
            exit 2
        fi
        if pred_check is_merged_into_main && [ "$allow_merged_base" -eq 0 ]; then
            cat >&2 <<EOF
guard-gh: refusing pr-create - current branch is already merged into main.
You may be opening a PR from stale code. To override, re-issue with --allow-merged-base.
EOF
            exit 2
        fi
        if pred_check is_dirty && [ "$allow_dirty" -eq 0 ]; then
            cat >&2 <<EOF
guard-gh: WARN pr-create from dirty worktree (uncommitted/untracked changes present).
The PR will be opened against your last commit; uncommitted work will NOT be included.
To proceed without this warning, re-issue with --allow-dirty.
EOF
            emit_forward
            exit 1
        fi
        emit_forward
        exit 0
        ;;
    pr-push)
        # pr-push has no slash command surfacing it today; the predicate is
        # wired so a future wrapper drops in cleanly. The matrix row for
        # "target == main" is enforced by check-push-target.sh at the git
        # layer, so this verb only adds the is_behind warning.
        if pred_check is_behind_origin_main && [ "$allow_stale" -eq 0 ]; then
            cat >&2 <<EOF
guard-gh: WARN pr-push - branch is behind origin/main.
Rebase or merge main first to avoid stale PR diffs. To proceed, re-issue with --allow-stale.
EOF
            emit_forward
            exit 1
        fi
        emit_forward
        exit 0
        ;;
    pr-merge)
        if [ "$has_admin" -eq 1 ] && [ "${GH_ADMIN_MERGE_OK:-0}" != "1" ]; then
            cat >&2 <<EOF
guard-gh: refusing pr-merge --admin - admin-merge bypasses branch protection.
To allow this session-wide, restart Claude with: GH_ADMIN_MERGE_OK=1 claude
(Claude cannot inject env vars into hook processes, so per-call prefix syntax does not work.)
EOF
            exit 2
        fi
        emit_forward
        exit 0
        ;;
    *)
        echo "guard-gh: unknown verb '$verb' (expected pr-create | pr-push | pr-merge)" >&2
        exit 2
        ;;
esac
