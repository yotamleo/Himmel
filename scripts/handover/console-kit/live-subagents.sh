#!/usr/bin/env bash
# scripts/handover/console-kit/live-subagents.sh - HIMMEL-5071: list a Claude
# Code session's in-process subagents (Agent-tool children) that are still
# running, from OUTSIDE that session, so a console never wraps, and a successor
# never closes it, while a judge call's result is still in flight.
#
# Usage: live-subagents.sh [--session <session-id>] [--projects <dir>]
#   --session   defaults to $CLAUDE_CODE_SESSION_ID (the caller's own session:
#               the wrap gate a console runs on itself)
#   --projects  defaults to ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects
#
# The signal (chosen 2026-10-09, evidence in the HIMMEL-5071 PR body):
#   - The registry: Claude Code writes <projects>/<proj>/<sid>/subagents/
#     agent-<id>.meta.json when it LAUNCHES a child (its toolUseId, its
#     requestShape) and appends the child's own transcript beside it.
#   - Completion: the instant a background child stops, the PARENT transcript
#     <projects>/<proj>/<sid>.jsonl gets a `queue-operation` enqueue of a
#     <task-notification> carrying <task-id><agent-id>, whether or not the
#     parent ever reads it (the CF case: j2212a finished, its notice never
#     reached CF). A foreground child completes with a tool_result for its
#     toolUseId instead.
#   - A resumed child (SendMessage to a stopped agent) runs again under the
#     same agent id, and its notice then names the SendMessage's tool-use-id
#     (why the match is on <task-id>). A child counts as finished only when its
#     newest completion record is no older than the newest record in its own
#     transcript.
# Rejected: the process tree (an in-process subagent is not a process; only the
# Bash tools it runs are, and wrap-subtree-check.sh already covers those), the
# tasks/<id>.output symlinks (they persist after the child finishes), and the
# child transcript's final record alone (its terminal shape varies: a
# SubagentHandback tool_result, an interrupt line, a plain end_turn).
#
# Output: one `LIVE-SUBAGENT <agent-id> <agent-type> <description>` line per
# running child, then `live-subagents=<n>`.
# Exit codes: 0 none running; 1 at least one running; 2 cannot decide (no
# session id, no parent transcript, or an unreadable registry entry). A gating
# caller treats 2 as "not proven idle", never as idle.
set -u

SID="${CLAUDE_CODE_SESSION_ID:-}"
PROJECTS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --session|--projects)
            [ "$#" -ge 2 ] || { echo "live-subagents: $1 needs a value" >&2; exit 2; }
            if [ "$1" = --session ]; then SID="$2"; else PROJECTS="$2"; fi
            shift 2 ;;
        *) echo "usage: live-subagents.sh [--session <session-id>] [--projects <dir>]" >&2; exit 2 ;;
    esac
done

case "$SID" in
    # hex only: a `?` would admit '/' and walk the path out of <projects>
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) echo "live-subagents: no usable session id '${SID}' - cannot decide" >&2; exit 2 ;;
esac

parent=""
for f in "$PROJECTS"/*/"$SID".jsonl; do
    [ -f "$f" ] || continue
    if [ -n "$parent" ]; then
        echo "live-subagents: more than one transcript for session $SID - cannot decide" >&2
        exit 2
    fi
    parent="$f"
done
if [ -z "$parent" ]; then
    echo "live-subagents: no transcript for session $SID under $PROJECTS - cannot decide" >&2
    exit 2
fi

subdir="${parent%.jsonl}/subagents"
live=0
for meta in "$subdir"/agent-*.meta.json; do
    [ -f "$meta" ] || continue
    if ! fields=$(jq -r '[.toolUseId // "", .requestShape // "", .agentType // "?", .description // ""] | @tsv' "$meta" 2>/dev/null); then
        echo "live-subagents: unreadable registry entry $meta - cannot decide" >&2
        exit 2
    fi
    IFS=$'\t' read -r tuid shape atype desc <<EOF
$fields
EOF
    if [ -z "$tuid" ]; then
        echo "live-subagents: registry entry $meta names no toolUseId - cannot decide" >&2
        exit 2
    fi
    aid="$(basename "$meta" .meta.json)"
    aid="${aid#agent-}"
    # newest completion record for this child in the parent transcript
    done_at=$(grep -F -e "$aid" -e "$tuid" "$parent" | jq -r --arg a "$aid" --arg t "$tuid" --arg s "$shape" '
        select(
            (.type == "queue-operation" and .operation == "enqueue"
                and ((.content // "") | tostring | contains("<task-id>" + $a + "</task-id>")))
            or ($s == "foreground" and .type == "user"
                and any(.message.content[]?; .type == "tool_result" and .tool_use_id == $t))
        ) | .timestamp // empty' 2>/dev/null | sort | tail -n 1)
    child_at=""
    if [ -f "${meta%.meta.json}.jsonl" ]; then
        # a parse failure could hide a resumed child's newest record: refuse
        if ! child_ts=$(jq -r '.timestamp // empty' "${meta%.meta.json}.jsonl" 2>/dev/null); then
            echo "live-subagents: unreadable child transcript ${meta%.meta.json}.jsonl - cannot decide" >&2
            exit 2
        fi
        child_at=$(printf '%s\n' "$child_ts" | sort | tail -n 1)
    fi
    # ISO-8601 UTC stamps from one writer compare correctly as strings
    if [ -n "$done_at" ] && { [ -z "$child_at" ] || ! [[ "$child_at" > "$done_at" ]]; }; then
        continue
    fi
    echo "LIVE-SUBAGENT $aid $atype $desc"
    live=$((live + 1))
done

echo "live-subagents=$live"
[ "$live" -eq 0 ]
