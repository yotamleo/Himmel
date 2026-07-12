#!/usr/bin/env bash
# tests/fixtures/ci-queue/atomicity-probe.sh
# HIMMEL-502 P2.2 — O_APPEND atomicity probe (mirrors the quota-gauge probe).
#
# The ci-queue ledger design (P2.1) rests on atomic single-line O_APPEND: POSIX
# guarantees a single write < PIPE_BUF (4096) is atomic; Windows Git Bash — the
# platform the VM/worker tooling runs on — is verified by this probe. It drives W
# concurrent writers, each appending R ~150-byte JSON lines to ONE file, then
# asserts every line landed whole: no loss, no merge, no interleave. This guards
# the INHERITED O_APPEND property; it is NOT the claim-race test (that is P3.3 at
# the HTTP layer — in-process JS appends under the single-writer model never race).
#
# Output: "PASS" (rc 0) or "FAIL: <reason>" (rc 1). Interleave is probabilistic.
# bash 3.2-safe (no associative arrays, no mapfile).
set -euo pipefail

W=8 R=500
f=$(mktemp)
trap 'rm -f "$f"' EXIT
w() { local id=$1 i=0; while [ "$i" -lt "$R" ]; do
  printf '{"v":1,"jobId":"job-%d","pad":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' "$id" >> "$f"
  i=$((i+1)); done; }
i=0; while [ "$i" -lt "$W" ]; do w "$i" & i=$((i+1)); done; wait
total=$(wc -l < "$f" | tr -d ' ')
[ "$total" -eq $((W*R)) ] || { echo "FAIL: line count $total != $((W*R))"; exit 1; }
bad=$(grep -c -v -E '^\{"v":1,"jobId":"job-[0-9]+","pad":"a+"\}$' "$f" || true)
[ "$bad" -eq 0 ] || { echo "FAIL: $bad malformed/interleaved lines"; exit 1; }
echo PASS
