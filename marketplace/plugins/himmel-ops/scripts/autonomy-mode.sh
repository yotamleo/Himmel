#!/usr/bin/env bash
# autonomy-mode.sh — print "autonomous" if any autonomy flag is set, else "interactive".
# Signals (HIMMEL-428): initiative mode (HIMMEL_INITIATIVE, HIMMEL-425) and its overnight
# part (HIMMEL_INITIATIVE_OVERNIGHT). HIMMEL_INITIATIVE is a CHAIN SPEC (e.g. "pr,ticket"),
# not a boolean, so treat any non-empty, non-falsy value as active (blocklist, not allowlist).
set -euo pipefail
active() { case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in ""|0|false|off|no) return 1;; *) return 0;; esac; }
if active "${HIMMEL_INITIATIVE:-}" || active "${HIMMEL_INITIATIVE_OVERNIGHT:-}"; then
  echo "autonomous"
else
  echo "interactive"
fi
