#!/usr/bin/env bash
# test-usage-fetch-scheduled.sh — HIMMEL-1841 GATE: prove the OAuth usage
# fetch reaches the network and finds a credential from the UNATTENDED
# scheduler context, not merely an operator shell (spec A5).
# NETWORK + CREDENTIAL required -> SKIP_LIST on bare CI.
set -uo pipefail
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required to validate the unattended usage fetch" >&2
  exit 1
fi
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PRODUCER="$REPO/scripts/statusline/usage-cache-producer.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/usage-fetch-scheduled.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT

# BOTH overrides are required: without HUD_USAGE_SNAPSHOT the probe writes
# the real HUD snapshot. The knob is CLAUDE_USAGE_CACHE (not USAGE_CACHE_FILE,
# which does not exist).
export CLAUDE_USAGE_CACHE="$WORK/cache.json"
export HUD_USAGE_SNAPSHOT="$WORK/hud.json"
export USAGE_OAUTH_TTL=0
unset USAGE_OAUTH_CMD

printf '%s' '{"model":{"display_name":"Claude"}}' \
  | bash "$PRODUCER" >"$WORK/out.log" 2>"$WORK/err.log"

if [ ! -f "$CLAUDE_USAGE_CACHE" ]; then
  echo "FAIL: producer wrote no cache. stderr:"; cat "$WORK/err.log"; exit 1
fi
if ! util=$(jq -er '.five_hour.utilization | select(type == "number")' "$CLAUDE_USAGE_CACHE"); then
  echo "FAIL: five_hour.utilization absent or non-numeric — fetch did not land. stderr:"
  cat "$WORK/err.log"; exit 1
fi
echo "PASS: five_hour.utilization=$util fetched unattended"
