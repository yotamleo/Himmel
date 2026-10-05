#!/usr/bin/env bash
# qmd-daemon-switch.sh - operator on/off for the shared qmd daemon (HIMMEL-4494).
#
#   qmd-daemon-switch.sh off   create the opt-out flag and stop the daemon
#   qmd-daemon-switch.sh on    remove the flag and run ensure-qmd-daemon.sh
#
# While the flag exists, ensure-qmd-daemon.sh (the SessionStart hook) exits 0
# without launching. Flag path: $QMD_DAEMON_OFF_FLAG (default
# ~/.himmel/state/qmd-daemon.off). The daemon pid comes from qmd's own pidfile
# ($XDG_CACHE_HOME or ~/.cache)/qmd/mcp.pid, the same one ensure-qmd-daemon.sh
# reads. bash 3.2-safe, ASCII-only.
set -u

QMD_DAEMON_OFF_FLAG="${QMD_DAEMON_OFF_FLAG:-$HOME/.himmel/state/qmd-daemon.off}"
pidfile="${XDG_CACHE_HOME:-$HOME/.cache}/qmd/mcp.pid"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  off)
    mkdir -p "$(dirname -- "$QMD_DAEMON_OFF_FLAG")" || exit 1
    : > "$QMD_DAEMON_OFF_FLAG" || exit 1
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    case "$pid" in
      ''|*[!0-9]*|0) echo "qmd-daemon-switch: flag set; no running daemon found (no pid in $pidfile)" ;;
      *)
        # Same identity check as ensure-qmd-daemon.sh's recycler: a stale pid
        # may now belong to an unrelated process, so only a qmd mcp one is stopped.
        row="$("${QMD_PS:-ps}" -o args= -p "$pid" 2>/dev/null || true)"
        case "$row" in
          *qmd*mcp*)
            kill -TERM "$pid" 2>/dev/null
            echo "qmd-daemon-switch: flag set; sent SIGTERM to daemon pid $pid"
            ;;
          *) echo "qmd-daemon-switch: flag set; pid $pid in $pidfile is not a qmd mcp process, left alone" ;;
        esac
        ;;
    esac
    echo "qmd stays off across sessions until: bash \"$here/qmd-daemon-switch.sh\" on"
    ;;
  on)
    rm -f "$QMD_DAEMON_OFF_FLAG" || exit 1
    if [ "${QMD_DAEMON_DISABLED:-}" = "1" ]; then
      echo "qmd-daemon-switch: flag removed, but QMD_DAEMON_DISABLED=1 is still set in this environment; the daemon will not start until it is unset"
    else
      echo "qmd-daemon-switch: flag removed; starting the daemon"
    fi
    exec bash "$here/ensure-qmd-daemon.sh"
    ;;
  *)
    echo "usage: qmd-daemon-switch.sh on|off" >&2
    exit 2
    ;;
esac
