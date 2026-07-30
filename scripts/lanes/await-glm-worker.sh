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
#   --stall-mins   HIMMEL-1378: no-output threshold before declaring a
#                  "running" session STALLED (default 6; see exit code 4)
#
# Exit codes:
#   0  worker reached a terminal status (meta.json + outbox tail printed)
#   2  no session dir / meta.json found
#   3  worker still running when the window closed (caller loops: re-invoke)
#   4  STALLED (HIMMEL-1378): status is "running", the recorded pid is alive
#      (or unknown), but no stdout/stderr byte has arrived for >= --stall-mins.
#      Exits the poll loop EARLY (before --max-mins) instead of burning the
#      full window blind — the caller decides whether to keep waiting
#      (re-invoke) or escalate/retry. Never kills the worker.
#   5  PHANTOM (HIMMEL-1378): status is "running" but the recorded pid is
#      confirmed DEAD — the process exited/crashed without spawn-glm.ts ever
#      writing a terminal meta.json. Distinct from 4: this one is not
#      recoverable by waiting.
#
# 4/5 are evaluated ONLY when meta.json carries "started_at" (every real
# spawn-glm.ts session does, from the first "running" write onward) — a
# bare/minimal meta.json (as used by hermetic fixtures) skips both checks and
# falls through to the pre-existing running/deadline (rc 3) behavior
# unchanged.
set -u

POLL_SECS=10

session_dir=""
slug=""
max_mins=8
stall_mins=6
while [ $# -gt 0 ]; do
    case "$1" in
        # Guard the value: a bare `--slug` (value missing) would make `shift 2`
        # fail under set -u without set -e, leaving $# unchanged → infinite loop.
        # Fail fast like the unknown-arg case instead.
        --session-dir) [ $# -ge 2 ] || { echo "await-glm-worker: $1 needs a value" >&2; exit 2; }; session_dir="$2"; shift 2 ;;
        --slug) [ $# -ge 2 ] || { echo "await-glm-worker: $1 needs a value" >&2; exit 2; }; slug="$2"; shift 2 ;;
        --max-mins) [ $# -ge 2 ] || { echo "await-glm-worker: $1 needs a value" >&2; exit 2; }; max_mins="$2"; shift 2 ;;
        --stall-mins) [ $# -ge 2 ] || { echo "await-glm-worker: $1 needs a value" >&2; exit 2; }; stall_mins="$2"; shift 2 ;;
        *) echo "await-glm-worker: unknown arg: $1" >&2; exit 2 ;;
    esac
done

# True (rc 0) if PID names a live process; rc 1 if CONFIRMED dead; rc 2 if
# unknown/can't tell (never escalated to "phantom" on rc 2 — pid 0 is the
# spawn-glm.ts sentinel for "not yet known", not a dead process, and a
# broken/absent tasklist must not misreport a live worker as dead).
# Windows twin of arm-resume.sh's _pid_alive (same tasklist/MSYS_NO_PATHCONV
# shape; same "No tasks" clean-miss vs error-output distinction) — POSIX uses
# `kill -0` directly. Kept local to this script rather than sourced: the two
# call sites diverge on what "ambiguous" should mean (arm-resume treats
# ambiguous as dead — the safe direction for refusing a risky arm; this script
# treats ambiguous as unknown/non-escalating — the safe direction for NOT
# declaring a live worker phantom on a flaky tasklist).
pid_alive() {
    local pid="$1" out rc
    [ -n "$pid" ] && [ "$pid" != "0" ] || return 2
    case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
        msys*|cygwin*|win32*|MINGW*)
            out=$(MSYS_NO_PATHCONV=1 tasklist /FI "PID eq $pid" 2>&1); rc=$?
            case "$out" in
                *"No tasks"*) return 1 ;;
                *"$pid"*) [ "$rc" -eq 0 ] && return 0 ;;
            esac
            return 2
            ;;
        *)
            if kill -0 "$pid" 2>/dev/null; then return 0; else return 1; fi
            ;;
    esac
}

# Extract a JSON string/number field's value from a small meta.json (no jq
# dependency — this script has none today; matches the existing status-regex
# style above). head -1 takes the first match (meta.json is a flat object, no
# nesting under these key names).
extract_json_str() { grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" | head -1 | sed -E 's/^"[^"]+"[[:space:]]*:[[:space:]]*"//; s/"$//'; }
extract_json_num() { grep -oE "\"$2\"[[:space:]]*:[[:space:]]*[0-9]+" "$1" | head -1 | sed -E 's/.*:[[:space:]]*//'; }

# ISO-8601 timestamp -> epoch seconds. GNU `date -d` handles the format
# directly (incl. fractional seconds + trailing Z); BSD/macOS `date` lacks
# -d, so the fallback strips the fractional-seconds+Z suffix (everything from
# the first '.') and parses with -j -f against the whole-second format. Same
# GNU-first/BSD-fallback shape as scripts/statusline/lib/all-sessions-index.sh.
iso_to_epoch() {
    date -d "$1" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${1%%.*}" +%s 2>/dev/null
}

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
        # not terminal yet (still "running", or an unrecognized/torn status).
        # HIMMEL-1378 process-liveness check: gated on "started_at" being
        # present so a bare/minimal fixture meta.json (no started_at) is
        # untouched by this block and falls straight to the pre-existing
        # deadline check below, unchanged.
        started_at=$(extract_json_str "$d/meta.json" started_at)
        if [ -n "$started_at" ]; then
            last_out=$(extract_json_str "$d/meta.json" last_output_at)
            [ -n "$last_out" ] || last_out="$started_at"
            last_epoch=$(iso_to_epoch "$last_out")
            if [ -n "$last_epoch" ]; then
                pid=$(extract_json_num "$d/meta.json" pid)
                pid_alive "$pid"; palive=$?
                if [ "$palive" -eq 1 ]; then
                    echo "await-glm-worker: PHANTOM: $d (recorded pid ${pid:-<none>} is not alive; meta.json still says running)"
                    cat "$d/meta.json"
                    echo
                    exit 5
                fi
                elapsed=$(( $(date +%s) - last_epoch ))
                stall_secs=$(( stall_mins * 60 ))
                if [ "$elapsed" -ge "$stall_secs" ]; then
                    echo "await-glm-worker: STALLED: $d (no output for ${elapsed}s >= --stall-mins ${stall_mins}m; last activity $last_out; pid ${pid:-<none>})"
                    cat "$d/meta.json"
                    echo
                    exit 4
                fi
            fi
        fi
        # fall through to the deadline check
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
