#!/usr/bin/env bash
# cr-reset.sh <pr> — reset a PR branch's /pr-check review-round counters
# (HIMMEL-5047, the Telegram /cr-reset break-glass op).
#
# A PR parks at the round-4 cap (review-round.sh, HIMMEL-2780/4600) until the
# operator resets it by hand. This is that reset as one checked-in step: it maps
# the PR to its head branch with gh, refuses a fork and a branch with no
# review-round state, takes the review-counter lock (the same namespace
# review-round.sh start uses), and MOVES <branch>.head/.round/.delta to
# <file>.bak-<timestamp> — a backup and a reset in one rename each.
#
# Reached from the trusted bridge (auto-action.sh, behind the operator's
# one-time /confirm code). An agent can reach it through the classifier too,
# so the agent marker refuses here (rc 19), as in cr-grant-delta.
#
# Exit: 0 reset / 1 bad input / 5 lock or state error / 12 not resettable
# (closed, fork, or no review-round state for the branch) / 13 gh failed /
# 19 agent marker.
# Seams: CR_RESET_GH (gh), CR_RESET_PRIMARY (the checkout whose git common dir
# holds the state; default this script's own), CR_RESET_LOCK_LIB.
set -uo pipefail

PR="${1:-}"
case "$PR" in ''|*[!0-9]*) echo "ERR cr-reset: usage: cr-reset.sh <pr-number>" >&2; exit 1 ;; esac
if [ -n "${CLAUDECODE:-}" ]; then
    echo "ERR cr-reset: refusing from inside a Claude session (CLAUDECODE set)" >&2
    exit 19
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/git-clean.sh
. "$HERE/../lib/git-clean.sh"
git_env_scrub
PRIMARY="${CR_RESET_PRIMARY:-$HERE/../..}"
GH="${CR_RESET_GH:-gh}"
LOCK_LIB="${CR_RESET_LOCK_LIB:-$PRIMARY/scripts/lib/shared-branch-lock.sh}"

view="$(cd "$PRIMARY" && "$GH" pr view "$PR" --json headRefName,isCrossRepository,state 2>/dev/null)" \
    || { echo "ERR cr-reset: gh pr view $PR failed" >&2; exit 13; }
branch="$(printf '%s' "$view" | jq -r '.headRefName // empty')"
fork="$(printf '%s' "$view" | jq -r '.isCrossRepository')"
state="$(printf '%s' "$view" | jq -r '.state // empty')"
if [ "$fork" != "false" ]; then
    echo "ERR cr-reset: PR $PR is from a fork; refusing" >&2
    exit 12
fi
if [ "$state" != "OPEN" ]; then
    echo "ERR cr-reset: PR $PR is $state, not OPEN" >&2
    exit 12
fi
if ! [[ "$branch" =~ ^[a-z]+/[A-Za-z0-9._+-]+$ ]]; then
    echo "ERR cr-reset: PR $PR head branch '$branch' is not a type/slug branch" >&2
    exit 12
fi

common="$(git -C "$PRIMARY" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || { echo "ERR cr-reset: cannot resolve the git common dir" >&2; exit 5; }
dir="$common/cr-review-rounds"
if [ ! -f "$dir/$branch.round" ] && [ ! -f "$dir/$branch.head" ] && [ ! -f "$dir/$branch.delta" ]; then
    echo "ERR cr-reset: no review-round state for $branch; nothing to reset" >&2
    exit 12
fi

[ -f "$LOCK_LIB" ] || { echo "ERR cr-reset: counter lock library missing at $LOCK_LIB" >&2; exit 5; }
if ! (cd "$PRIMARY" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round SHARED_BRANCH_LOCK_HOLDER_PID=$$ \
        bash "$LOCK_LIB" acquire-wait "." "$branch" "cr-reset" 10 60 >/dev/null 2>&1); then
    echo "ERR cr-reset: cannot acquire the review-counter lock for $branch" >&2
    exit 5
fi
owner="$(cd "$PRIMARY" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round bash "$LOCK_LIB" status "." "$branch" 2>/dev/null)"
# As review-round.sh: no readable holder record means the lock cannot be
# released as ours, so nothing moves.
case "$owner" in
    '{"pid":'*) ;;
    *) echo "ERR cr-reset: counter lock holder state for $branch is missing or unreadable; refusing" >&2; exit 5 ;;
esac

# The pid suffix keeps two resets in the same second from overwriting a backup.
ts="$(date +%Y%m%dT%H%M%S)-$$"
rc=0
moved=""
for f in head round delta; do
    [ -f "$dir/$branch.$f" ] || continue
    if mv "$dir/$branch.$f" "$dir/$branch.$f.bak-$ts"; then
        moved="$moved .$f"
    else
        echo "ERR cr-reset: could not back up $branch.$f; restoring the rest" >&2
        rc=5
        break
    fi
done
if [ "$rc" -ne 0 ]; then
    # All or nothing: put back what already moved so no half-reset is left.
    for f in $moved; do
        mv "$dir/$branch$f.bak-$ts" "$dir/$branch$f" || echo "ERR cr-reset: could not restore $branch$f" >&2
    done
fi
(cd "$PRIMARY" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
    bash "$LOCK_LIB" release-if-owner "." "$branch" "$owner" >/dev/null 2>&1) || true
[ "$rc" -eq 0 ] || exit "$rc"
echo "reset $branch (PR $PR):$moved backed up as .bak-$ts"
exit 0
