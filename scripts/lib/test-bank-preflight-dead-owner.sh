#!/usr/bin/env bash
# HIMMEL-4089 ask 3: scratch reservations only, no real sessions.
# PLATFORM GUARD: fleet admission uses the POSIX shell/tmpfs path.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/bank-dead-owner.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/repo/scripts/lib" "$W/repo/scripts/lanes" "$W/home" "$W/proc"
cp "$REPO/scripts/lib/"*.sh "$W/repo/scripts/lib/"
printf '%s\n' '#!/usr/bin/env bash' 'echo "balance=10.00:credit spend=?"' > "$W/repo/scripts/lanes/openrouter-cost.sh"
cat > "$W/ps" <<'STUB'
#!/usr/bin/env bash
if [ -n "${PS_COUNTER:-}" ]; then
  n="$(cat "$PS_COUNTER" 2>/dev/null)"; n="${n:-0}"
  n=$((n+1)); printf '%s\n' "$n" > "$PS_COUNTER"
  [ "$n" -ne 3 ] || printf '%s\n' "$PS_OWNER" > "$PS_SWAP/pid"
fi
cat "$PS_DATA"
STUB
chmod +x "$W/ps"
: > "$W/ps.data"
# A completed child gives a real dead PID, not an assumed-unused constant.
true & dead=$!; wait "$dead"
fails=0
seed() {
  local dir="$W/$1/HIMMEL-9001-test"
  mkdir -p "$dir"
  printf '%s\n' "$2" > "$dir/pid"
  printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$dir/expires"
  printf '%s\n' HIMMEL-9001-test > "$dir/name"
}
run() {
  local slots="$1"; shift
  # Grace 0 keeps the pre-HIMMEL-4115 cases about identity, not timing; the
  # grace cases below pass their own value ("$@" comes later, so it wins).
  env FLEET_RECLAIM_GRACE_SECS=0 "$@" HOME="$W/home" HIMMEL_FLEET_CAP=1 HIMMEL_FLEET_SLOTS="$W/$slots" FLEET_PS_CMD="$W/ps" FLEET_PROC="$W/proc" PS_DATA="$W/ps.data" CADENCE_BANK_LEDGER="$W/ledger" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LANE=openrouter CADENCE_BANK_LEG=HIMMEL-9001-test CADENCE_BANK_CALLER_PID="$$" FLEET_CAP_OK= bash "$W/repo/scripts/lib/bank-preflight.sh" 2>"$W/err"
}
check() {
  if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: expected $2 got $3"; fails=$((fails+1)); fi
}
seed dead "$dead"
check 'dead owner same-name relaunch admits despite cap one' PROCEED "$(run dead)"
check 'replacement reservation belongs to current caller' "$$" "$(cat "$W/dead/HIMMEL-9001-test/pid")"
seed live "$$"
check 'live owner same-name launch still refuses' SKIPPED-FLEET "$(run live)"
check 'live owner unchanged' "$$" "$(cat "$W/live/HIMMEL-9001-test/pid")"
seed invalid invalid
check 'unverifiable owner is not reclaimed early' SKIPPED-FLEET "$(run invalid)"
# Reused PID must conservatively protect the slot even if not a claude owner.
seed reused "$$"
check 'reused live PID keeps reservation' SKIPPED-FLEET "$(run reused)"
seed census-swap "$dead"
check 'owner changed during fresh census keeps reservation' SKIPPED-FLEET "$(run census-swap PS_COUNTER="$W/ps-counter" PS_OWNER="$$" PS_SWAP="$W/census-swap/HIMMEL-9001-test")"
check 'live replacement owner remains on disk' "$$" "$(cat "$W/census-swap/HIMMEL-9001-test/pid")"
cat > "$W/swap-name" <<'STUB'
#!/usr/bin/env bash
[ "$1" = reservation-pre-verify ] || exit 0
printf '%s\n' HIMMEL-9002-other > "$2/name"
printf '%s\n' '9002 claude -n HIMMEL-9002-other work' > "$PS_DATA"
STUB
chmod +x "$W/swap-name"
mkdir -p "$W/proc/9002"
printf '%s\n' claude > "$W/proc/9002/comm"
printf 'claude\0-n\0HIMMEL-9002-other\0work\0' > "$W/proc/9002/cmdline"
seed changed "$dead"
run changed FLEET_ADMIT_TEST_HOOK="$W/swap-name" >/dev/null
if [ -d "$W/changed/HIMMEL-9001-test" ]; then
  echo 'ok - changed reservation identity is not reclaimed'
else
  echo 'FAIL - changed reservation identity was reclaimed'; fails=$((fails+1))
fi
# Existing consumption behavior stays unchanged: no double-counting live name.
printf '%s\n' '9001 claude -n HIMMEL-9001-test work' > "$W/ps.data"
mkdir -p "$W/proc/9001"
printf '%s\n' claude > "$W/proc/9001/comm"
printf 'claude\0-n\0HIMMEL-9001-test\0work\0' > "$W/proc/9001/cmdline"
seed session "$dead"
check 'dead owner with a live named session never admits past cap' SKIPPED-FLEET "$(run session)"
# HIMMEL-4115: a launcher that exits 7 ("claude not visible yet") leaves a dead
# owner whose session can still come up seconds later. Inside the grace window
# (counted from the first pass that sees the owner dead) the slot stays held.
: > "$W/ps.data"
( exit 7 ) & exited7=$!; wait "$exited7"
seed grace "$exited7"
check 'exit-7 owner inside the default grace window refuses at cap' SKIPPED-FLEET "$(run grace FLEET_RECLAIM_GRACE_SECS=)"
check 'exit-7 reservation kept inside grace' "$exited7" "$(cat "$W/grace/HIMMEL-9001-test/pid" 2>/dev/null)"
printf '%s\n' "$(( $(date +%s) - 30 ))" > "$W/grace/HIMMEL-9001-test/dead_seen"
check 'owner dead for 30s of a 60s grace still refuses' SKIPPED-FLEET "$(run grace FLEET_RECLAIM_GRACE_SECS=60)"
printf '%s\n' "$(( $(date +%s) - 61 ))" > "$W/grace/HIMMEL-9001-test/dead_seen"
check 'owner dead past the grace window is reclaimed and admits' PROCEED "$(run grace FLEET_RECLAIM_GRACE_SECS=)"
check 'post-grace reservation belongs to current caller' "$$" "$(cat "$W/grace/HIMMEL-9001-test/pid")"
seed grace-bad "$exited7"
check 'non-numeric grace falls back to the default and refuses' SKIPPED-FLEET "$(run grace-bad FLEET_RECLAIM_GRACE_SECS=abc)"
seed grace-corrupt "$exited7"
printf '%s\n' garbage > "$W/grace-corrupt/HIMMEL-9001-test/dead_seen"
check 'corrupt death stamp restarts the grace window' SKIPPED-FLEET "$(run grace-corrupt FLEET_RECLAIM_GRACE_SECS=60)"
seed grace-octal "$exited7"
printf '%s\n' 08 > "$W/grace-octal/HIMMEL-9001-test/dead_seen"
check 'leading-zero stamp reads as decimal, not octal' PROCEED "$(run grace-octal FLEET_RECLAIM_GRACE_SECS=08)"
check 'leading-zero stamp raises no arithmetic error' absent "$(if grep -q 'value too great' "$W/err"; then echo present; else echo absent; fi)"
# Exercise the reclaim helper with a large fresh census: grep must drain it.
awk '/^_fleet_reclaim_dead_reservation\(\)/,/^}/' "$REPO/scripts/lib/bank-preflight.sh" > "$W/reclaim.sh" || exit 1
seed large-census "$dead"
(
  source "$W/reclaim.sh" || exit 2
  declare -F _fleet_reclaim_dead_reservation >/dev/null || exit 2
  SLOTS="$W/large-census"
  export FLEET_RECLAIM_GRACE_SECS=0
  mkdir -p "$SLOTS/.admit"
  printf '%s\n' "$$" > "$SLOTS/.admit/pid"
  _fleet_live_names="$(printf '%s\n' HIMMEL-9001-test; seq 1 30000)"
  # Invoked indirectly by the extracted production helper.
  # shellcheck disable=SC2317,SC2329
  _fleet_census() { return 0; }
  # shellcheck disable=SC2317,SC2329
  _fleet_admit_hook() { :; }
  # shellcheck disable=SC2317,SC2329
  _fleet_gate_take() { _fleet_gate_fence="$W/fence"; mkdir -p "$_fleet_gate_fence"; }
  # shellcheck disable=SC2317,SC2329
  _fleet_gate_drop() { rm -rf "$W/fence"; }
  _fleet_reclaim_dead_reservation "$SLOTS/HIMMEL-9001-test/" "$dead" "$(cat "$SLOTS/HIMMEL-9001-test/expires")" HIMMEL-9001-test HIMMEL-9001-test
)
reclaim_rc=$?
check 'large census helper returns expected refusal' 1 "$reclaim_rc"
check 'large census live name keeps reservation' present "$(if [ -d "$W/large-census/HIMMEL-9001-test" ]; then echo present; else echo absent; fi)"
printf 'test-bank-preflight-dead-owner: %s failures\n' "$fails"
[ "$fails" -eq 0 ]
