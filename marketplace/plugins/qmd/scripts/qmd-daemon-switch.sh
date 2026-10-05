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
      ''|*[!0-9]*) echo "qmd-daemon-switch: flag set; no running daemon found (no pid in $pidfile)" ;;
      *)
        if kill -TERM "$pid" 2>/dev/null; then
          echo "qmd-daemon-switch: flag set; sent SIGTERM to daemon pid $pid"
        else
          echo "qmd-daemon-switch: flag set; daemon pid $pid was not running"
        fi
        ;;
    esac
    echo "qmd stays off across sessions until: bash \"$here/qmd-daemon-switch.sh\" on"
    ;;
  on)
    rm -f "$QMD_DAEMON_OFF_FLAG" || exit 1
    echo "qmd-daemon-switch: flag removed; starting the daemon"
    exec bash "$here/ensure-qmd-daemon.sh"
    ;;
  *)
    echo "usage: qmd-daemon-switch.sh on|off" >&2
    exit 2
    ;;
esac
