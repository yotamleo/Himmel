#!/usr/bin/env bash
# Gate regression: bot.pid (and the stale-kill) must fire ONLY when
# TELEGRAM_OWN_POLLER=1. A non-owner session must not write bot.pid, so it
# can never steal the single getUpdates slot from the owner.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v bun >/dev/null || { echo "SKIP: bun not on PATH"; exit 0; }

# server.ts imports grammy + the MCP SDK. A fresh checkout (and the CI shard)
# has no node_modules under the plugin, so bun would die on import: the owner
# case would then read NO_PID and the reap case would read a vacuous REAPED
# (both servers dead). Use the plugin's own node_modules when present, else
# install the lockfile into a throwaway copy — never into the tree — and FAIL
# loudly if that install fails rather than skipping.
SERVER_DIR="$HERE"
if [ ! -d "$HERE/node_modules" ]; then
  SERVER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/poller-gate-deps.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
  trap 'rm -rf "$SERVER_DIR"' EXIT
  cp "$HERE/server.ts" "$HERE/package.json" "$HERE/bun.lock" "$SERVER_DIR/"
  ( cd "$SERVER_DIR" && bun install --frozen-lockfile --no-summary >/dev/null 2>&1 ) \
    || { echo "FAIL: bun install of the plugin deps failed (needs network)"; exit 1; }
fi

# The dummy token must never reach api.telegram.org: point every proxy variable
# at a closed port so each Telegram call fails locally. The pid file is written
# before the first API call, so the gate cases below are unaffected.
export HTTPS_PROXY="http://127.0.0.1:9" HTTP_PROXY="http://127.0.0.1:9" ALL_PROXY="http://127.0.0.1:9"
export https_proxy="$HTTPS_PROXY" http_proxy="$HTTP_PROXY" all_proxy="$ALL_PROXY"
unset NO_PROXY no_proxy

run_case() {
  # $1 = own_poller value ("" or "1"); echoes "<before-kill>/<after-kill>":
  # before = PID_WRITTEN|NO_PID, after = REMOVED|LEFT.
  # bot.pid is sampled BEFORE the kill: the server's SIGTERM/EOF shutdown
  # removes its own bot.pid (server.ts shutdown()), so checking after the kill
  # always read NO_PID. The after-kill half asserts that shutdown contract.
  # stdin is held open with `< <(sleep 5)` so the EOF-driven shutdown does NOT
  # fire before the sample; we sample at 2s, then kill.
  local own="$1" tmp pid before after
  tmp="$(mktemp -d)"
  TELEGRAM_STATE_DIR="$tmp" TELEGRAM_BOT_TOKEN="123:DUMMY" \
    TELEGRAM_OWN_POLLER="$own" bun "$SERVER_DIR/server.ts" < <(sleep 5) >/dev/null 2>&1 &
  pid=$!
  sleep 2
  # A server that already died (import error, crash) proves nothing about the gate.
  kill -0 "$pid" 2>/dev/null || { echo "DEAD/DEAD"; rm -rf "$tmp"; return; }
  if [ -f "$tmp/bot.pid" ]; then before="PID_WRITTEN"; else before="NO_PID"; fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if [ -f "$tmp/bot.pid" ]; then after="LEFT"; else after="REMOVED"; fi
  rm -rf "$tmp"
  echo "$before/$after"
}

reap_case() {
  # HIMMEL-1858 regression: a second owner must actually REAP the first.
  # Upstream 0.0.7 gates the SIGTERM on `execFileSync('ps', …)`; MSYS ps does
  # not support `-o args=`, so on Windows it throws, the broad catch swallows
  # it, the kill is skipped and bot.pid is overwritten anyway — two live
  # getUpdates consumers. This is the behavioural half of that guard (the
  # code-shape half is tests/poller-gate-shape.test.ts). Echoes "REAPED" or
  # "ALIVE" (or "B_DEAD" when the second server itself died, which would make
  # a REAPED verdict vacuous). Both servers share ONE state dir so the second
  # sees the first's bot.pid.
  local tmp a b verdict
  tmp="$(mktemp -d)"
  TELEGRAM_STATE_DIR="$tmp" TELEGRAM_BOT_TOKEN="123:DUMMY" \
    TELEGRAM_OWN_POLLER=1 bun "$SERVER_DIR/server.ts" < <(sleep 25) >/dev/null 2>&1 &
  a=$!
  sleep 3
  TELEGRAM_STATE_DIR="$tmp" TELEGRAM_BOT_TOKEN="123:DUMMY" \
    TELEGRAM_OWN_POLLER=1 bun "$SERVER_DIR/server.ts" < <(sleep 25) >/dev/null 2>&1 &
  b=$!
  sleep 4
  if ! kill -0 "$b" 2>/dev/null; then verdict="B_DEAD"
  elif kill -0 "$a" 2>/dev/null; then verdict="ALIVE"
  else verdict="REAPED"; fi
  kill "$a" "$b" 2>/dev/null || true
  wait "$a" "$b" 2>/dev/null || true
  rm -rf "$tmp"
  echo "$verdict"
}

owner="$(run_case 1)"
nonowner="$(run_case '')"
reaped="$(reap_case)"

fail=0
[ "$owner" = "PID_WRITTEN/REMOVED" ] || { echo "FAIL: owner (OWN_POLLER=1) must write bot.pid and remove it on shutdown (got $owner)"; fail=1; }
[ "$nonowner" = "NO_PID/REMOVED" ]   || { echo "FAIL: non-owner (OWN_POLLER unset) wrote bot.pid (got $nonowner) — would steal the slot"; fail=1; }
[ "$reaped" = "REAPED" ]     || { echo "FAIL: a second owner did NOT reap the stale poller (got $reaped) — two live getUpdates consumers (HIMMEL-1858)"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS: poller gate writes bot.pid only for the owner, and a second owner reaps the first"
exit "$fail"
