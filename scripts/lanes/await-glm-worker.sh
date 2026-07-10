#!/usr/bin/env bash
# await-glm-worker.sh - canonical bounded await for a GLM lane worker (HIMMEL-883).
#
# WHY: dispatchers repeatedly ended their turn promising "a background monitor
# will re-invoke me when the worker finishes"; that monitor can die silently
# and the parent session strands (observed 2026-07-10: worker done at 10:15Z,
# parent idled ~4h). This script is the structural replacement: a FOREGROUND,
# bounded poll of the worker session's meta.json that the dispatcher repeats
# inside its own turn until the worker reaches a terminal status.
#
# Usage:
#   await-glm-worker.sh [--session-dir <dir> | --slug <slug>] [--max-mins <n>]
#
#   --session-dir  exact worker session dir (contains meta.json)
#   --slug         worker slug; resolves the NEWEST session dir matching
#                  glm-<slug>-* under the glm-sessions root
#                  (BRIDGE_ROOT or ~/.claude/handover/bridge, + /glm-sessions)
#   --max-mins     how long THIS invocation polls before giving up (default 8;
#                  keep <= 8 so a Bash-tool call stays under its 10-min cap)
#
# Exit codes:
#   0  worker reached a terminal status (meta.json + outbox tail printed)
#   2  no session dir / meta.json found
#   3  worker still running when the window closed (caller loops: re-invoke)
set -u

POLL_SECS=10

session_dir=""
slug=""
max_mins=8
while [ $# -gt 0 ]; do
    case "$1" in
        # Guard the value: a bare `--slug` (value missing) would make `shift 2`
        # fail under set -u without set -e, leaving $# unchanged → infinite loop.
        # Fail fast like the unknown-arg case instead.
        --session-dir) [ $# -ge 2 ] || { echo "await-glm-worker: $1 needs a value" >&2; exit 2; }; session_dir="$2"; shift 2 ;;
        --slug) [ $# -ge 2 ] || { echo "await-glm-worker: $1 needs a value" >&2; exit 2; }; slug="$2"; shift 2 ;;
        --max-mins) [ $# -ge 2 ] || { echo "await-glm-worker: $1 needs a value" >&2; exit 2; }; max_mins="$2"; shift 2 ;;
        *) echo "await-glm-worker: unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$session_dir" ] && [ -z "$slug" ]; then
    echo "await-glm-worker: need --session-dir or --slug" >&2
    exit 2
fi

resolve_session_dir() {
    # newest glm-<slug>-* dir; the trailing component is a millisecond epoch,
    # so lexical sort of equal-length stamps orders by recency
    find "$GLM_SESSIONS_ROOT" -maxdepth 1 -type d -name "glm-${slug}-*" 2>/dev/null | sort | tail -1
}

GLM_SESSIONS_ROOT="${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}/glm-sessions"

deadline=$(( $(date +%s) + max_mins * 60 ))
while :; do
    d="$session_dir"
    if [ -z "$d" ]; then
        d="$(resolve_session_dir)"
    fi
    if [ -n "$d" ] && [ -f "$d/meta.json" ]; then
        # Positively require a KNOWN terminal status (the finalMeta set in
        # spawn-glm.ts) before completing. Anything else — "running", an
        # unrecognized status, or a torn read mid-rewrite — is treated as
        # not-yet-terminal and falls through to the deadline check, so we keep
        # polling instead of falsely completing on a partial write. This is the
        # exact strand (premature terminal) the watchdog exists to prevent.
        # Whitespace-tolerant because a producer reformat must not silently
        # break detection (producer currently emits JSON.stringify(...,null,2)).
        if grep -qE '"status"[[:space:]]*:[[:space:]]*"(done|failed|capped|blocked|timeout)"' "$d/meta.json"; then
            echo "await-glm-worker: TERMINAL: $d"
            cat "$d/meta.json"
            echo
            if [ -f "$d/outbox.jsonl" ]; then
                echo "--- outbox tail ---"
                tail -3 "$d/outbox.jsonl"
            fi
            exit 0
        fi
        # not terminal yet — fall through to the deadline check
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
        if [ -z "$d" ] || [ ! -f "$d/meta.json" ]; then
            echo "await-glm-worker: no session found (slug=${slug:-} dir=${session_dir:-}) under $GLM_SESSIONS_ROOT" >&2
            exit 2
        fi
        echo "await-glm-worker: still running after ${max_mins}m: $d (re-invoke to keep waiting)"
        exit 3
    fi
    sleep "$POLL_SECS"
done
