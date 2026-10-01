#!/usr/bin/env bash
# reconcile-cadence.sh -- periodic seat-liveness runner (HIMMEL-1880).
#
# reconcile-workers.sh used to run only when a dispatch or an arm triggered it,
# so an idle fleet never noticed a dead seat. This puts it on a fixed cadence:
# every tick runs `reconcile-workers.sh --report`, which classifies each
# running seat DIED / NEVER-STARTED / STILL-RUNNING and orphans only rows whose
# pid is confirmed dead past the grace window. A dead seat is therefore
# reported within one interval (plus the 120s grace when its meta.json was
# written less than that before it died).
#
# Usage:
#   bash scripts/handover/reconcile-cadence.sh run
#   bash scripts/handover/reconcile-cadence.sh arm [--interval-min N]   # default 10
#   bash scripts/handover/reconcile-cadence.sh disarm
#   bash scripts/handover/reconcile-cadence.sh status
#
# arm/disarm/status manage ONE crontab entry tagged `# HIMMEL-ReconcileCadence`
# (Linux/macOS). Arming replaces any existing tagged entry, so arming twice
# yields one job. On Windows use the twin: pwsh -File reconcile-cadence.ps1.
#
# Env:
#   RECONCILE_CADENCE_LOG     Log file `run` appends to (default:
#                             ~/.claude/handover/reconcile-cadence.log;
#                             rotated to .prev past 1 MiB).
#   RECONCILE_CADENCE_TIMEOUT_SECS  Hard bound on one tick (default 110). arm
#                             refuses an interval that would let ticks overlap.
#   RECONCILE_CADENCE_CRONTAB Test seam: command used instead of `crontab`.
#   RECONCILE_GRACE_SECS      Passed through to reconcile-workers.sh; arm
#                             refuses an interval shorter than it.
#
# Exit: 0 ok; 2 usage/refusal; otherwise reconcile-workers.sh's rc (run) or a
# crontab failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="HIMMEL-ReconcileCadence"
CRONTAB_BIN="${RECONCILE_CADENCE_CRONTAB:-crontab}"
LOG="${RECONCILE_CADENCE_LOG:-$HOME/.claude/handover/reconcile-cadence.log}"
TIMEOUT_SECS="${RECONCILE_CADENCE_TIMEOUT_SECS:-110}"
GRACE_SECS="${RECONCILE_GRACE_SECS:-120}"

die() { echo "ERR reconcile-cadence: $*" >&2; exit 2; }

for v in TIMEOUT_SECS GRACE_SECS; do
    case "${!v}" in ''|*[!0-9]*) die "$v must be a non-negative integer" ;; esac
done

cmd_run() {
    mkdir -p "$(dirname "$LOG")" || die "cannot create log dir for $LOG"
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1048576 ]; then
        mv -f "$LOG" "$LOG.prev"
    fi
    local rc
    {
        echo "[fired $(date '+%Y-%m-%d %H:%M:%S')]"
        if command -v timeout >/dev/null 2>&1; then
            timeout "$TIMEOUT_SECS" bash "$SCRIPT_DIR/reconcile-workers.sh" --report
        else
            bash "$SCRIPT_DIR/reconcile-workers.sh" --report
        fi
        rc=$?
        echo "[exit rc=$rc]"
    } >> "$LOG" 2>&1
    return "$rc"
}

windows_refuse() {
    case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
        msys*|cygwin*|win32*|MINGW*)
            die "Windows uses the schtasks twin: pwsh -File $SCRIPT_DIR/reconcile-cadence.ps1 -Action ${1}" ;;
    esac
}

CRON_TAB=""
cron_read() {
    local err rc
    err=$(mktemp -t reconcile-cadence.err.XXXXXX) || die "mktemp failed"
    CRON_TAB=$(LC_ALL=C "$CRONTAB_BIN" -l 2>"$err")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 1 ] && { [ ! -s "$err" ] || grep -qi 'no crontab' "$err"; }; then
            CRON_TAB=""
        else
            echo "ERR reconcile-cadence: crontab -l failed (rc=$rc); refusing to treat it as empty:" >&2
            cat "$err" >&2
            rm -f "$err"
            exit 2
        fi
    fi
    rm -f "$err"
}

# cron_write <new-entry-or-empty> -- install the current crontab minus every
# tagged line, plus the new entry if given.
cron_write() {
    local tab
    tab=$(mktemp -t reconcile-cadence.tab.XXXXXX) || die "mktemp failed"
    { [ -z "$CRON_TAB" ] || printf '%s\n' "$CRON_TAB" | grep -vF "# $TAG"
      [ -z "$1" ] || printf '%s\n' "$1"; } > "$tab"
    if ! "$CRONTAB_BIN" - < "$tab"; then
        echo "ERR reconcile-cadence: crontab install failed; rejected crontab left at $tab" >&2
        exit 4
    fi
    rm -f "$tab"
}

cron_escape() {
    local s
    s=$(printf '%q' "$1")
    printf '%s' "${s//%/\\%}"
}

cmd_arm() {
    local interval=10
    while [ $# -gt 0 ]; do
        case "$1" in
            --interval-min) [ $# -ge 2 ] || die "--interval-min needs a value"; interval="$2"; shift 2 ;;
            *) die "unknown arm arg: $1" ;;
        esac
    done
    case "$interval" in ''|*[!0-9]*) die "--interval-min must be an integer" ;; esac
    [ "$interval" -ge 1 ] && [ "$interval" -le 59 ] || die "--interval-min must be 1..59"
    # A tick shorter than the grace window cannot confirm a death any sooner,
    # and one shorter than the tick timeout could overlap the previous tick.
    [ $((interval * 60)) -ge "$GRACE_SECS" ] || die "--interval-min $interval is shorter than RECONCILE_GRACE_SECS=${GRACE_SECS}s"
    [ $((interval * 60)) -gt "$TIMEOUT_SECS" ] || die "--interval-min $interval does not exceed the ${TIMEOUT_SECS}s tick timeout"
    windows_refuse Arm

    # Bake the arming shell's PATH: cron's minimal PATH lacks node, which
    # reconcile-workers.sh needs.
    local bash_bin entry
    bash_bin=$(command -v bash) || die "bash not on PATH"
    entry="*/$interval * * * * PATH=$(cron_escape "$PATH") $(cron_escape "$bash_bin") $(cron_escape "$SCRIPT_DIR/reconcile-cadence.sh") run # $TAG"
    cron_read
    cron_write "$entry"
    echo "reconcile-cadence: armed every ${interval}m (log: $LOG)"
}

cmd_disarm() {
    windows_refuse Disarm
    cron_read
    cron_write ""
    echo "reconcile-cadence: disarmed"
}

cmd_status() {
    windows_refuse Status
    cron_read
    local line
    line=$(printf '%s\n' "$CRON_TAB" | grep -F "# $TAG" || true)
    if [ -n "$line" ]; then
        echo "reconcile-cadence: armed: $line"
    else
        echo "reconcile-cadence: not armed"
    fi
}

case "${1:-}" in
    run) shift; cmd_run "$@" ;;
    arm) shift; cmd_arm "$@" ;;
    disarm) shift; cmd_disarm ;;
    status) shift; cmd_status ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "usage: reconcile-cadence.sh run|arm [--interval-min N]|disarm|status" ;;
esac
