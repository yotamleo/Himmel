#!/usr/bin/env bash
# HIMMEL-4089 ask 3: scratch reservations only, no real sessions.
# PLATFORM GUARD: fleet admission uses the POSIX shell/tmpfs path.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
W="$(mktemp -d)" || exit 1
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
  env "$@" HOME="$W/home" HIMMEL_FLEET_CAP=1 HIMMEL_FLEET_SLOTS="$W/$slots" FLEET_PS_CMD="$W/ps" FLEET_PROC="$W/proc" PS_DATA="$W/ps.data" CADENCE_BANK_LEDGER="$W/ledger" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LANE=openrouter CADENCE_BANK_LEG=HIMMEL-9001-test CADENCE_BANK_CALLER_PID="$$" FLEET_CAP_OK= bash "$W/repo/scripts/lib/bank-preflight.sh" 2>"$W/err"
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
printf 'test-bank-preflight-dead-owner: %s failures\n' "$fails"
[ "$fails" -eq 0 ]
