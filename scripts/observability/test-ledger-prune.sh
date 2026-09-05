#!/usr/bin/env bash
# Smoke test for scripts/observability/ledger-prune.sh (HIMMEL-2149).
# NEVER touches the live ~/.himmel/flow-runs.jsonl — every case runs against
# a scratch --ledger fixture under a mktemp dir.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/ledger-prune.sh"

fail=0
check() { [ "$1" = "$2" ] || { echo "FAIL: $3 — got '$1' want '$2'"; fail=1; }; }

tmp="$(mktemp -d -t ledger-prune.XXXXXX)"; trap 'rm -rf "$tmp"' EXIT

# now() for the fixture rows below: HIMMEL_TEST_NOW is not read by the
# script (it always uses wall-clock time), so rows are timestamped relative
# to the REAL current time via `date -u -d`. GNU date's -d is available in
# Git Bash's coreutils; skip the whole suite on a platform without it rather
# than fabricate a wrong result.
if ! date -u -d '-1 hour' >/dev/null 2>&1; then
  # gnu-ok: this IS the portability probe — BSD/macOS `date` has no GNU -d
  # flag, and the whole suite is skipped (not failed) on such a platform.
  echo "SKIP test-ledger-prune (GNU date unsupported on this platform)"
  exit 0
fi
recent="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"     # 1h old: inside the 30h default cutoff
old="$(date -u -d '-40 hours' +%Y-%m-%dT%H:%M:%SZ)"      # 40h old: past the 30h default cutoff

# 1. Unpaired start older than the cutoff is dropped; a recent unpaired
# start, a paired start (has a matching end row), and end rows are kept.
ledger1="$tmp/ledger1.jsonl"
cat >"$ledger1" <<EOF
{"v":1,"ev":"start","flow":"hermes-invoke","run_id":"old-unpaired","fired_at":"$old"}
{"v":1,"ev":"start","flow":"hermes-invoke","run_id":"recent-unpaired","fired_at":"$recent"}
{"v":1,"ev":"start","flow":"hermes-invoke","run_id":"old-paired","fired_at":"$old"}
{"v":1,"ev":"end","flow":"hermes-invoke","run_id":"old-paired","ended_at":"$recent","outcome":"complete"}
EOF
bash "$SCRIPT" --ledger "$ledger1" >"$tmp/out1.txt" 2>&1
check "$?" "0" "T1 rc"
grep -q 'old-unpaired' "$ledger1" && { echo "FAIL: T1 old unpaired start not dropped"; fail=1; }
grep -q 'recent-unpaired' "$ledger1" || { echo "FAIL: T1 recent unpaired start wrongly dropped"; fail=1; }
grep -q '"old-paired"' "$ledger1" || { echo "FAIL: T1 paired start wrongly dropped"; fail=1; }
[ "$(wc -l <"$ledger1" | tr -d ' ')" = "3" ] || { echo "FAIL: T1 expected 3 remaining lines, got $(wc -l <"$ledger1")"; fail=1; }
ls "$tmp"/ledger1.jsonl.bak-* >/dev/null 2>&1 || { echo "FAIL: T1 no backup file written"; fail=1; }

# 2. --dry-run reports the drop but writes nothing (ledger unchanged,
# no backup).
ledger2="$tmp/ledger2.jsonl"
cat >"$ledger2" <<EOF
{"v":1,"ev":"start","flow":"hermes-invoke","run_id":"old-unpaired","fired_at":"$old"}
EOF
before="$(cat "$ledger2")"
out="$(bash "$SCRIPT" --dry-run --ledger "$ledger2")"
check "$?" "0" "T2 rc"
check "$(cat "$ledger2")" "$before" "T2 ledger untouched"
grep -q 'would drop 1 of 1' <<< "$out" || { echo "FAIL: T2 missing dry-run count in '$out'"; fail=1; }
compgen -G "$tmp/ledger2.jsonl.bak-*" >/dev/null && { echo "FAIL: T2 dry-run wrote a backup"; fail=1; }

# 3. --cutoff-hours override: the same "1h old" row is dropped under a 30m
# cutoff even though it survives the 24h default.
ledger3="$tmp/ledger3.jsonl"
cat >"$ledger3" <<EOF
{"v":1,"ev":"start","flow":"hermes-invoke","run_id":"one-hour-old","fired_at":"$recent"}
EOF
bash "$SCRIPT" --cutoff-hours 0.5 --ledger "$ledger3" >/dev/null
check "$?" "0" "T3 rc"
[ "$(wc -c <"$ledger3" | tr -d ' ')" = "0" ] || { echo "FAIL: T3 expected an empty ledger, got: $(cat "$ledger3")"; fail=1; }

# 4. Malformed JSON line and a row with an unparseable fired_at are both kept
# untouched — the script must never guess at a row it cannot judge.
ledger4="$tmp/ledger4.jsonl"
cat >"$ledger4" <<EOF
not valid json at all
{"v":1,"ev":"start","flow":"hermes-invoke","run_id":"bad-ts","fired_at":"not-a-timestamp"}
EOF
bash "$SCRIPT" --ledger "$ledger4" >/dev/null
check "$?" "0" "T4 rc"
[ "$(wc -l <"$ledger4" | tr -d ' ')" = "2" ] || { echo "FAIL: T4 expected both unjudgeable rows kept, got: $(cat "$ledger4")"; fail=1; }

# 5. Missing ledger is a clean no-op (rc=0, no backup, no crash).
bash "$SCRIPT" --ledger "$tmp/does-not-exist.jsonl" >"$tmp/out5.txt" 2>&1
check "$?" "0" "T5 rc"
grep -q 'nothing to prune' "$tmp/out5.txt" || { echo "FAIL: T5 missing nothing-to-prune message"; fail=1; }

# 6. --cutoff-hours needs a value.
bash "$SCRIPT" --cutoff-hours >"$tmp/out6.txt" 2>&1
check "$?" "2" "T6 rc"

# 7. CR round 1 (codex-3): "0", ".", and "1.2.3" are not meaningful positive
# cutoffs and must be refused rc=2, not silently accepted (a "0" cutoff would
# have pruned every unpaired start regardless of age).
for bad in 0 . 1.2.3; do
  bash "$SCRIPT" --cutoff-hours "$bad" --ledger "$tmp/does-not-exist.jsonl" >"$tmp/out7.txt" 2>&1
  check "$?" "2" "T7 rc (--cutoff-hours '$bad')"
done

# 8. CR round 1 (codex-1): the DEFAULT cutoff (30h) must not prune a row that
# is still inside the exporter's own alerting window for the DEFAULT 6h
# stall deadline (deadline + FLOW_STALLED_ALERT_TTL_SECONDS = 6h + 24h =
# 30h) — a 25h-old unpaired start is well past the 6h deadline (so it IS
# "stalled") but well inside the 30h alert-TTL window, so this helper must
# not silence it early.
still_alerting="$(date -u -d '-25 hours' +%Y-%m-%dT%H:%M:%SZ)"
ledger8="$tmp/ledger8.jsonl"
cat >"$ledger8" <<EOF
{"v":1,"ev":"start","flow":"hermes-invoke","run_id":"still-alerting","fired_at":"$still_alerting"}
EOF
bash "$SCRIPT" --ledger "$ledger8" >/dev/null
check "$?" "0" "T8 rc"
grep -q 'still-alerting' "$ledger8" || { echo "FAIL: T8 a row still inside the exporter's alert TTL window was pruned early"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS test-ledger-prune" || exit 1
