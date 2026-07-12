#!/usr/bin/env bash
# Gate regression: bot.pid (and the stale-kill) must fire ONLY when
# TELEGRAM_OWN_POLLER=1. A non-owner session must not write bot.pid, so it
# can never steal the single getUpdates slot from the owner.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v bun >/dev/null || { echo "SKIP: bun not on PATH"; exit 0; }

run_case() {
  # $1 = own_poller value ("" or "1"); echoes "PID_WRITTEN" or "NO_PID".
  # stdin is held open with `< <(sleep 5)` so the server's EOF-driven shutdown
  # (which rmSync's bot.pid) does NOT fire before the check; we kill at 2s.
  local own="$1" tmp pid
  tmp="$(mktemp -d)"
  TELEGRAM_STATE_DIR="$tmp" TELEGRAM_BOT_TOKEN="123:DUMMY" \
    TELEGRAM_OWN_POLLER="$own" bun "$HERE/server.ts" < <(sleep 5) >/dev/null 2>&1 &
  pid=$!
  sleep 2
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if [ -f "$tmp/bot.pid" ]; then echo "PID_WRITTEN"; else echo "NO_PID"; fi
  rm -rf "$tmp"
}

owner="$(run_case 1)"
nonowner="$(run_case '')"

fail=0
[ "$owner" = "PID_WRITTEN" ] || { echo "FAIL: owner (OWN_POLLER=1) did not write bot.pid (got $owner)"; fail=1; }
[ "$nonowner" = "NO_PID" ]   || { echo "FAIL: non-owner (OWN_POLLER unset) wrote bot.pid (got $nonowner) — would steal the slot"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS: poller gate writes bot.pid only for the owner"
exit "$fail"
