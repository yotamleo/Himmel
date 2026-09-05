#!/usr/bin/env bash
# shellcheck disable=SC2034 # CAF_* configure the sourced arg filter.
# shellcheck disable=SC2016 # QUOTA_SCRIPT is intentionally single-quoted for in-distro bash.
# shellcheck disable=SC1003 # the '\' clone-path glob arm is an intentional single-quoted backslash, not a quote-escape.
# scripts/codex/dispatch-codex-wsl.sh - the codex WSL lane's dispatch
# chokepoint (HIMMEL-999; sibling of dispatch-codex-exec.sh / HIMMEL-741).
#
# WHY: the proven WSL impl flow (ext4 clone in-distro + raw codex exec)
# bypassed every lane invariant. This wrapper is the single entry point:
#   1. Clone containment IN-DISTRO: physical path (pwd -P) under
#      ${CODEX_WSL_CLONE_ROOT:-$HOME/work}, never under /mnt/ (write-reach
#      containment + the HIMMEL-939 perf cliff), must be a git work tree.
#   2. Shared flag filter (codex-arg-filter.sh): same allow-list as the
#      exec lane, WSL-parameterized messages.
#   3. Per-clone mutex keyed on distro + RESOLVED physical path: the lane
#      dispatches into ONE long-lived clone - concurrent dispatches collide.
#      Stale locks (dead holder pid) auto-break with a stderr note.
#   4. Quota preflight (fail-OPEN cost guard): in-distro newest rollout's
#      last rate_limits row; live (resets_at un-expired, file mtime within
#      CODEX_WSL_QUOTA_MAX_AGE_SECS) weekly used_percent >= HARD refuses.
#   5. Pins: gpt-5.5 unless caller-named; explicit --sandbox
#      workspace-write unless caller-named; --reasoning-effort translated
#      to a trusted -c model_reasoning_effort override.
#   6. Ledger: flow-runs.jsonl start/end rows (flow=codex-wsl) - the
#      HIMMEL-654 feed AND the egress-matrix brief-scoped audit line.
#   7. Brief delivery: --brief-file crosses as the backgrounded child's
#      EXPLICITLY-redirected stdin and is materialized into the positional
#      prompt in-distro via "$(cat)" (bare stdin briefs silently no-op).
#
# Usage:
#   dispatch-codex-wsl.sh --distro <name> --clone <in-distro-abs-path> \
#       [--brief-file <path>] [--reasoning-effort <enum>] [codex args...]
#
# Environment:
#   CODEX_WSL_BIN                 wsl binary override (tests; default wsl.exe)
#   CODEX_WSL_CLONE_ROOT          in-distro containment root (default $HOME/work,
#                                 resolved IN-DISTRO)
#   CODEX_WSL_LOCKS_DIR           lock root (default ~/.himmel/state/codex-wsl-locks)
#   CODEX_WSL_QUOTA_HARD/WARN     percent thresholds (default 85/65)
#   CODEX_WSL_QUOTA_MAX_AGE_SECS  rollout freshness bound (default 86400)
#   CODEX_WSL_QUOTA_OK=1          bypass a quota HARD refusal
#   HIMMEL_FLOW_RUNS_LEDGER       ledger path override (the flow-run-ledger
#                                 lib's own var; tests point it at a temp file)
#
# Exit: 0 codex rc | 2 usage/refusal | 3 quota-hard | 4 lock held | 127 no wsl
# Bash 3.2 safe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WSL="${CODEX_WSL_BIN:-wsl.exe}"
LOCKS_DIR="${CODEX_WSL_LOCKS_DIR:-$HOME/.himmel/state/codex-wsl-locks}"

# shellcheck source=codex-arg-filter.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/codex-arg-filter.sh"
# shellcheck source=../lib/flow-run-ledger.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/flow-run-ledger.sh"

usage() {
    echo "usage: dispatch-codex-wsl.sh --distro <name> --clone <in-distro-abs-path> [--brief-file <path>] [--reasoning-effort <enum>] [codex exec args...]" >&2
    exit 2
}

DISTRO=""
CLONE=""
BRIEF_FILE=""
LOCK_DIR=""
WSL_CHILD_PID=""
RUN_ID=""
EFFECTIVE_MODEL=""
TASK_NAME=""
LEDGER_STARTED=""

# shellcheck disable=SC2329,SC2317 # invoked indirectly via `trap ... EXIT` (sibling dispatch-codex-exec.sh idiom)
_cleanup() {
    if [ -n "$WSL_CHILD_PID" ]; then
        wait "$WSL_CHILD_PID" 2>/dev/null
    fi
    if [ -n "$LEDGER_STARTED" ]; then
        _emit_end_row "${CODEX_RC:-1}"
    fi
    if [ -n "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ]; then
        rm -rf "$LOCK_DIR"
    fi
}
trap _cleanup EXIT

_emit_end_row() {
    local rc="$1" outcome="complete"
    [ "$rc" -eq 0 ] 2>/dev/null || outcome="error"
    flow_run_append "$(flow_run_row_end "codex-wsl" "$RUN_ID" "" "$rc" "$outcome" 1 "")"
    LEDGER_STARTED=""
}

while [ $# -gt 0 ]; do
    case "$1" in
        --distro)     [ -n "${2:-}" ] || usage; DISTRO="$2"; shift 2 ;;
        --clone)      [ -n "${2:-}" ] || usage; CLONE="$2"; shift 2 ;;
        --brief-file) [ -n "${2:-}" ] || usage; BRIEF_FILE="$2"; shift 2 ;;
        *) break ;;
    esac
done
if [ -z "$DISTRO" ] || [ -z "$CLONE" ]; then usage; fi

case "$DISTRO" in
    *[!A-Za-z0-9._-]*) echo "dispatch-codex-wsl.sh: distro name '$DISTRO' has characters outside [A-Za-z0-9._-] - refused" >&2; exit 2 ;;
esac
case "$CLONE" in
    /mnt/*) echo "dispatch-codex-wsl.sh: refusing clone under /mnt/ - the lane dispatches only into in-distro ext4 clones (HIMMEL-939: /mnt is both the write-reach risk and the measured perf cliff)" >&2; exit 2 ;;
    /*) ;;
    *) echo "dispatch-codex-wsl.sh: --clone must be an absolute in-distro POSIX path: $CLONE" >&2; exit 2 ;;
esac
case "$CLONE" in
    *[[:space:]]*|*"'"*|*'"'*) echo "dispatch-codex-wsl.sh: clone path contains whitespace or quote characters - refused (single-quoted in-distro script)" >&2; exit 2 ;;
    *'$'*|*'`'*|*'\'*) echo "dispatch-codex-wsl.sh: clone path contains a shell metacharacter (\$, backtick, or backslash) - refused; the path is re-evaluated inside the in-distro bash -lc string (cd \"\$CLONE\"), where these command-substitute (codex-adv HIMMEL-999)" >&2; exit 2 ;;
esac
if [ -n "$BRIEF_FILE" ] && [ ! -f "$BRIEF_FILE" ]; then
    echo "dispatch-codex-wsl.sh: brief file not found: $BRIEF_FILE" >&2
    exit 2
fi

# Shared filter, WSL-parameterized messages (HIMMEL-999 B1).
CAF_SELF_NAME="dispatch-codex-wsl.sh"
CAF_SCOPE_NOUN="clone"
CAF_CONTAINER_FLAG="--clone"
CAF_ADDDIR_HINT="the containment check covers only the dispatched clone"
if ! codex_filter_passthrough_args "$@"; then
    exit 2
fi

command -v "$WSL" >/dev/null 2>&1 || { echo "dispatch-codex-wsl.sh: wsl binary not found: $WSL (set CODEX_WSL_BIN)" >&2; exit 127; }

# --- In-distro verification (spec B2.3): containment resolves IN-DISTRO. ---
# The check logic lives in codex-wsl-verify.sh (a standalone, locally
# unit-testable script); it crosses the boundary as `bash -s` stdin with
# clone + optional root as ARGS, so nothing is string-interpolated.
if [ -n "${CODEX_WSL_CLONE_ROOT:-}" ]; then
    case "${CODEX_WSL_CLONE_ROOT}" in
        *[[:space:]]*|*"'"*|*'"'*) echo "dispatch-codex-wsl.sh: CODEX_WSL_CLONE_ROOT contains whitespace or quotes - refused" >&2; exit 2 ;;
    esac
fi
PHYS="$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$WSL" -d "$DISTRO" -- bash -s -- "$CLONE" "${CODEX_WSL_CLONE_ROOT:-}" < "$SCRIPT_DIR/codex-wsl-verify.sh" 2>&1)"
VERIFY_RC=$?
if [ "$VERIFY_RC" -ne 0 ]; then
    echo "dispatch-codex-wsl.sh: clone verification failed (rc=$VERIFY_RC) for $DISTRO:$CLONE - $PHYS" >&2
    exit 2
fi
PHYS="$(printf '%s\n' "$PHYS" | tail -1)"

# --- Per-clone mutex on the RESOLVED physical path (spec B2.4). ---
LOCK_KEY="$(printf '%s_%s' "$DISTRO" "$PHYS" | tr '/:| .' '_____')"
LOCK_CAND="$LOCKS_DIR/$LOCK_KEY"
mkdir -p "$LOCKS_DIR" 2>/dev/null
if mkdir "$LOCK_CAND" 2>/dev/null; then
    # Won the lock. Write our pid IMMEDIATELY (before any other work) so a
    # racing contender never reads an EMPTY pid and mistakes a live
    # acquisition-in-progress for a stale lock (codex-adv HIMMEL-999: the
    # mkdir/echo gap let a racer rm -rf a live lock and both proceed).
    echo "$$" > "$LOCK_CAND/pid"
else
    # Lock exists. An empty pid means a racer just mkdir'd but has not yet
    # written its pid - a LIVE acquisition in progress, NOT stale. Read with
    # a bounded grace window before deciding; only a present-AND-dead pid is
    # genuinely stale and breakable.
    HOLDER=""
    for _try in 1 2 3 4 5; do
        HOLDER="$(cat "$LOCK_CAND/pid" 2>/dev/null || true)"
        [ -n "$HOLDER" ] && break
        sleep 0.2
    done
    if [ -z "$HOLDER" ]; then
        echo "dispatch-codex-wsl.sh: per-clone lock for $DISTRO:$PHYS exists with no pid after a grace window - treating as a live acquisition in progress, exit 4 (retry)" >&2
        exit 4
    fi
    if kill -0 "$HOLDER" 2>/dev/null; then
        echo "dispatch-codex-wsl.sh: per-clone lock held by live pid $HOLDER for $DISTRO:$PHYS - exit 4 (concurrent dispatch into one clone collides; wait or investigate the holder)" >&2
        exit 4
    fi
    echo "dispatch-codex-wsl.sh: breaking stale lock for $DISTRO:$PHYS (holder pid '$HOLDER' not alive)" >&2
    rm -rf "$LOCK_CAND"
    if mkdir "$LOCK_CAND" 2>/dev/null; then
        echo "$$" > "$LOCK_CAND/pid"
    else
        echo "dispatch-codex-wsl.sh: lock re-acquire lost a race for $DISTRO:$PHYS - exit 4" >&2
        exit 4
    fi
fi
LOCK_DIR="$LOCK_CAND"
date -u +%Y-%m-%dT%H:%M:%SZ > "$LOCK_DIR/acquired_at" 2>/dev/null

# --- Quota preflight (spec B2.5): fail-OPEN cost guard. One in-distro probe
# prints "used_percent resets_at_epoch rollout_mtime_epoch" for the WEEKLY
# (largest window_minutes) limit of the newest rollout's last rate_limits
# row; any probe failure or unparseable output is fail-open (WARN+proceed).
QUOTA_HARD="${CODEX_WSL_QUOTA_HARD:-85}"
QUOTA_WARN="${CODEX_WSL_QUOTA_WARN:-65}"
QUOTA_MAX_AGE="${CODEX_WSL_QUOTA_MAX_AGE_SECS:-86400}"
QUOTA_SCRIPT='f=$(find "$HOME/.codex/sessions" -name "rollout-*.jsonl" -type f 2>/dev/null | sort | tail -1); [ -n "$f" ] || exit 9; command -v jq >/dev/null 2>&1 || exit 9; row=$(grep "\"rate_limits\"" "$f" 2>/dev/null | tail -1); [ -n "$row" ] || exit 9; printf "%s" "$row" | jq -r "[.payload.rate_limits.primary, .payload.rate_limits.secondary] | map(select(. != null and (.used_percent|type==\"number\") and .window_minutes == 10080)) | first | select(. != null) | \"\(.used_percent) \(.resets_at // 0)\"" 2>/dev/null | { read -r up ra; [ -n "$up" ] || exit 9; mt=$(stat -c %Y "$f" 2>/dev/null || echo 0); printf "%s %s %s\n" "$up" "$ra" "$mt"; }'
# window_minutes == 10080 selects the WEEKLY bank explicitly (spec B2.5);
# a rollout row carrying only the 5h window (300) must NOT gate the weekly
# decision - no weekly entry -> empty jq output -> exit 9 -> fail-open WARN.
QUOTA_OUT="$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$WSL" -d "$DISTRO" -- bash -lc "$QUOTA_SCRIPT" 2>/dev/null)"
QUOTA_RC=$?
if [ "$QUOTA_RC" -ne 0 ] || [ -z "$QUOTA_OUT" ]; then
    echo "dispatch-codex-wsl.sh: WARN codex quota telemetry unavailable in $DISTRO (rc=$QUOTA_RC) - proceeding fail-open" >&2
else
    QUOTA_OUT="$(printf '%s\n' "$QUOTA_OUT" | tail -1)"
    USED_PCT="$(printf '%s' "$QUOTA_OUT" | awk '{print $1}')"
    RESETS_AT="$(printf '%s' "$QUOTA_OUT" | awk '{print $2}')"
    ROLLOUT_MT="$(printf '%s' "$QUOTA_OUT" | awk '{print $3}')"
    NOW_EPOCH="$(date +%s)"
    # Float-safe compares via awk (HIMMEL-392 lesson: never bash [ -ge ] on floats).
    IS_NUM="$(printf '%s' "$USED_PCT" | awk '/^[0-9]+([.][0-9]+)?$/{print "y"}')"
    if [ "$IS_NUM" != "y" ]; then
        echo "dispatch-codex-wsl.sh: WARN unparseable quota reading '$QUOTA_OUT' - proceeding fail-open" >&2
    elif [ "$(awk -v r="$RESETS_AT" -v n="$NOW_EPOCH" 'BEGIN{print (r+0 <= n) ? "y" : "n"}')" = "y" ] \
      || [ "$(awk -v m="$ROLLOUT_MT" -v n="$NOW_EPOCH" -v a="$QUOTA_MAX_AGE" 'BEGIN{print (n - m > a) ? "y" : "n"}')" = "y" ]; then
        echo "dispatch-codex-wsl.sh: WARN stale quota reading (used=$USED_PCT%, window expired or rollout over-age) - never hard-denying on stale data, proceeding" >&2
    elif [ "$(awk -v u="$USED_PCT" -v h="$QUOTA_HARD" 'BEGIN{print (u >= h) ? "y" : "n"}')" = "y" ]; then
        if [ "${CODEX_WSL_QUOTA_OK:-0}" = "1" ]; then
            echo "dispatch-codex-wsl.sh: WARN codex weekly bank at ${USED_PCT}% (>= hard $QUOTA_HARD) - proceeding on CODEX_WSL_QUOTA_OK=1" >&2
        else
            echo "dispatch-codex-wsl.sh: codex weekly bank at ${USED_PCT}% (>= hard threshold $QUOTA_HARD) - dispatch refused; a capped worker dies mid-run (s52). Override: CODEX_WSL_QUOTA_OK=1" >&2
            exit 3
        fi
    elif [ "$(awk -v u="$USED_PCT" -v w="$QUOTA_WARN" 'BEGIN{print (u >= w) ? "y" : "n"}')" = "y" ]; then
        echo "dispatch-codex-wsl.sh: WARN codex weekly bank at ${USED_PCT}% (>= warn $QUOTA_WARN) - sizing note: prefer short briefs" >&2
    fi
fi

# --- Pins (spec B2.6; sibling Invariant 2 + sandbox pin + Invariant 7). ---
pin_args=""
if [ "$CAF_HAVE_MODEL" -eq 1 ]; then
    echo "dispatch-codex-wsl.sh: WARN caller-named model overrides the gpt-5.5 pin (codex-variant names 400 on ChatGPT auth)" >&2
    EFFECTIVE_MODEL="caller-named"
else
    pin_args="--model gpt-5.5"
    EFFECTIVE_MODEL="gpt-5.5"
fi
if [ "$CAF_HAVE_SANDBOX" -eq 0 ]; then
    pin_args="$pin_args --sandbox workspace-write"
fi
if [ -n "$CAF_REASONING_EFFORT" ]; then
    pin_args="$pin_args -c model_reasoning_effort=\"$CAF_REASONING_EFFORT\""
fi

# --- Ledger start row (spec B2.7; fixed schema, task_name is the audit). ---
RUN_ID="codex-wsl-$(date +%s)-$$"
TASK_NAME="$DISTRO:$PHYS"
if [ -n "$BRIEF_FILE" ]; then
    TASK_NAME="$TASK_NAME:brief=$(basename "$BRIEF_FILE")"
fi
flow_run_append "$(flow_run_row_start "codex-wsl" "$RUN_ID" "" "$(hostname 2>/dev/null || echo unknown)" "codex-wsl" "$EFFECTIVE_MODEL" "$TASK_NAME" "" "$$")"
LEDGER_STARTED=1

# --- Dispatch (spec B2.8). Args were validated by the shared filter; the
# in-distro command is wrapper-built. Prompt: brief -> "$(cat)" positional;
# else the filtered caller words. NEW_ARGS join: each was allow-listed
# (no quotes/whitespace beyond word boundaries survive the filter set).
IN_ARGS=""
if [ "${#CAF_NEW_ARGS[@]}" -gt 0 ]; then
    for a in "${CAF_NEW_ARGS[@]}"; do
        case "$a" in
            *"'"*) echo "dispatch-codex-wsl.sh: passthrough arg contains a single quote - refused (single-quoted in-distro script): $a" >&2; exit 2 ;;
        esac
        IN_ARGS="$IN_ARGS '$a'"
    done
fi
# CLONE is SINGLE-quoted in the in-distro string (codex-adv + coderabbit
# HIMMEL-999): inside 'single quotes' no $()/backtick/$var substitutes, so a
# metacharacter path can never command-execute when bash -lc re-parses this.
# Safe because the validation above rejects a single quote in CLONE (and the
# metachar refusal is the belt-and-suspenders early gate). Matches the
# per-word single-quoting of IN_ARGS.
if [ -n "$BRIEF_FILE" ]; then
    IN_CMD="cd '$CLONE' && codex exec $pin_args$IN_ARGS \"\$(cat)\""
else
    IN_CMD="cd '$CLONE' && codex exec $pin_args$IN_ARGS"
fi

if [ -n "$BRIEF_FILE" ]; then
    # EXPLICIT stdin redirect onto the backgrounded child (sibling's <&0
    # lesson): default background stdin is /dev/null -> "$(cat)" reads empty
    # -> silent no-op prompt.
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$WSL" -d "$DISTRO" -- bash -lc "$IN_CMD" < "$BRIEF_FILE" &
else
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$WSL" -d "$DISTRO" -- bash -lc "$IN_CMD" <&0 &
fi
WSL_CHILD_PID=$!
wait "$WSL_CHILD_PID"
CODEX_RC=$?
WSL_CHILD_PID=""
_emit_end_row "$CODEX_RC"
exit "$CODEX_RC"
