#!/usr/bin/env bash
# test-claude-lane.sh — HIMMEL-4082. Hermetic: no claude launch.
# Pins the HIMMEL_CLAUDE_LANE resolver (scripts/lib/claude-lane.sh) and that the
# headless claude spawn sites honour it with a stubbed launcher.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO/scripts/lib/claude-lane.sh"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }

[ -r "$LIB" ] || { echo "FAIL - $LIB missing"; echo "pass=0 fail=1"; exit 1; }
# shellcheck source=claude-lane.sh
# shellcheck disable=SC1091
. "$LIB"

resolve() { # <lane|__unset__> -> prints "rc|cmd words"
  local out rc
  if [ "$1" = __unset__ ]; then
    out="$( (unset HIMMEL_CLAUDE_LANE; claude_lane_resolve "$REPO" && echo "${CLAUDE_LANE_CMD[*]}") 2>/dev/null )"; rc=$?
  else
    out="$( (HIMMEL_CLAUDE_LANE="$1"; export HIMMEL_CLAUDE_LANE; claude_lane_resolve "$REPO" && echo "${CLAUDE_LANE_CMD[*]}") 2>/dev/null )"; rc=$?
  fi
  echo "$rc|$out"
}

check "unset = plain claude"        "0|claude" "$(resolve __unset__)"
check "native = plain claude"       "0|claude" "$(resolve native)"
check "empty = plain claude"        "0|claude" "$(resolve '')"
check "openrouter launcher"         "0|$REPO/scripts/claude-openrouter" "$(resolve openrouter)"
check "claudex launcher"            "0|$REPO/scripts/claude-codex" "$(resolve claudex)"
bad="$(resolve bogus)"
check "unknown refuses (rc)"        "2" "${bad%%|*}"
err="$( (HIMMEL_CLAUDE_LANE=bogus; export HIMMEL_CLAUDE_LANE; claude_lane_resolve "$REPO") 2>&1 >/dev/null )"
case "$err" in *bogus*native*openrouter*claudex*) r=ok;; *) r="got: $err";; esac
check "unknown refusal names value + valid lanes" "ok" "$r"

# Spawn-site coverage with stubbed launchers: scripts/lib/test-claude-headless.sh case 17
# and scripts/cr/test-hermes-critic.sh case 8c.

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
