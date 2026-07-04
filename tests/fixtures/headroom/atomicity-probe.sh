#!/usr/bin/env bash
# tests/fixtures/headroom/atomicity-probe.sh
# WS9 (HIMMEL-654) — BLOCKING atomicity gate (AC0/T0).
#
# The entire single-file headroom ledger design (D2 primary) rests on
# atomic single-line O_APPEND. POSIX guarantees a single write < PIPE_BUF
# (4096) is atomic; Windows Git Bash is UNVERIFIED and is the platform
# the GLM worker fleet runs on. This probe drives W concurrent writers,
# each appending R ~150-byte JSON lines to ONE file, then asserts every
# line landed whole: no loss, no merge, no interleave.
#
# Output: "PASS" (rc 0) or "FAIL: <reason>" (rc 1). Run 5x in the main
# session before Task 1 — interleave is probabilistic.
#
# bash 3.2-safe (no associative arrays, no mapfile). Plain integer JSON
# per writer so a partial write is detectable as a malformed line.
set -euo pipefail

W=8 R=500
f=$(mktemp)
trap 'rm -f "$f"' EXIT
w() { local id=$1 i=0; while [ "$i" -lt "$R" ]; do
  printf '{"v":1,"lane":"glm","seq":%d,"pad":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' "$id" >> "$f"
  i=$((i+1)); done; }
i=0; while [ "$i" -lt "$W" ]; do w "$i" & i=$((i+1)); done; wait
total=$(wc -l < "$f" | tr -d ' ')
[ "$total" -eq $((W*R)) ] || { echo "FAIL: line count $total != $((W*R))"; exit 1; }
# every line whole: exactly one "seq" per line, and each parses
bad=$(grep -c -v -E '^\{"v":1,"lane":"glm","seq":[0-9]+,"pad":"a+"\}$' "$f" || true)
[ "$bad" -eq 0 ] || { echo "FAIL: $bad malformed/interleaved lines"; exit 1; }
echo PASS
