#!/usr/bin/env bash
# scripts/handover/console-kit/leg-jira-status.sh - HIMMEL-4419: move a leg's
# ticket along its Jira status as the leg progresses (LIVE -> In Progress,
# PR open -> In Review), so a version's progress reads in Jira and on the board.
#
# Usage: leg-jira-status.sh <TICKET> <target-status> [--allow-back]
#
# Idempotent and forward-only: it reads the ticket's current status first and
# moves it only when the target ranks strictly higher on
#   To Do < In Progress < In Review < IN CI < Done
# (--allow-back lets the post-merge `completes-ticket: no` step go In Review ->
# In Progress). A ticket already Done/Closed, or in a status outside that
# ladder (Backlog, Planning, wont do, ...), is never touched.
#
# Best-effort by design: every failure (no CLI build, get/transition error)
# prints a WARN on stderr and exits 0, so a Jira problem never blocks a leg.
#
# Env: LEG_JIRA_CLI overrides the Jira CLI (an executable, or a .js run under
# node) - the test seam. Default: scripts/jira/dist/index.js in the PRIMARY
# checkout (an untracked build artifact a worktree lacks).
#
# Platform guard: POSIX bash 3.2+, no .ps1 twin by design (shell-only harness).
set -u

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "usage: leg-jira-status.sh <TICKET> <target-status> [--allow-back]" >&2
    exit 2
fi
KEY="$1"
TARGET="$2"
ALLOW_BACK=0
if [ "$#" -eq 3 ]; then
    [ "$3" = "--allow-back" ] || { echo "usage: leg-jira-status.sh <TICKET> <target-status> [--allow-back]" >&2; exit 2; }
    ALLOW_BACK=1
fi

# shellcheck source=../../lib/git-clean.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/git-clean.sh"
git_env_scrub

warn() { echo "WARN leg-jira-status: $* (continuing; the leg is not blocked)" >&2; exit 0; }

[ "${LEG_JIRA_STATUS:-1}" != 0 ] || exit 0   # operator opt-out, honoured on a direct call too

# ponytail: the get-then-transition pair is not atomic, so a status change landing between
# the two can be overwritten; Jira offers no conditional transition, upgrade path = none needed
# while a leg is the only writer of its own ticket.
case "$KEY" in
    [A-Za-z]*-[0-9]*) ;;
    *) warn "'$KEY' is not a ticket key" ;;
esac

rank() {
    case "$1" in
        "To Do") echo 0 ;;
        "In Progress") echo 1 ;;
        "In Review") echo 2 ;;
        "IN CI") echo 3 ;;
        *) echo -1 ;;
    esac
}
target_rank="$(rank "$TARGET")"
[ "$target_rank" -ge 0 ] || warn "target '$TARGET' is not a leg status"

CLI="${LEG_JIRA_CLI:-}"
if [ -z "$CLI" ]; then
    common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || warn "no repo root for $KEY"
    CLI="$(dirname "$common")/scripts/jira/dist/index.js"
fi
[ -e "$CLI" ] || warn "Jira CLI '$CLI' not found for $KEY"
jira() {
    case "$CLI" in
        *.js) node "$CLI" "$@" ;;
        *) "$CLI" "$@" ;;
    esac
}

json="$(jira get "$KEY" --json 2>/dev/null)" || warn "cannot read $KEY"
current="$(printf '%s' "$json" | node -e '
    try {
        const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
        process.stdout.write((d.fields && d.fields.status && d.fields.status.name) || "");
    } catch {}
' 2>/dev/null)"
[ -n "$current" ] || warn "cannot read the status of $KEY"

current_rank="$(rank "$current")"
[ "$current_rank" -ge 0 ] || exit 0                # Done, Closed, Backlog, ...: not ours to move
[ "$current_rank" -ne "$target_rank" ] || exit 0   # already there
if [ "$target_rank" -lt "$current_rank" ] && [ "$ALLOW_BACK" -ne 1 ]; then
    exit 0
fi

out="$(jira transition "$KEY" "$TARGET" 2>&1)" || warn "transition $KEY '$current' -> '$TARGET' failed: $(printf '%s' "$out" | tr '\n' ' ')"
echo "leg-jira-status: $KEY $current -> $TARGET"
exit 0
