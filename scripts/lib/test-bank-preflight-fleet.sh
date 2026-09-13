#!/usr/bin/env bash
# test-bank-preflight-fleet.sh — HIMMEL-2774. RED-first suite for the atomic
# admission + reservation mechanism that closes the arm-time TOCTOU race:
# two concurrent declared launches both observing the fleet under cap and
# both proceeding, pushing the fleet over HIMMEL_FLEET_CAP (deferred from
# HIMMEL-2765's /pr-check).
#
# SUT is a variable (FLEET_SUT) — not a hardcoded path — so this SAME suite
# can run unmodified against the pre-fix script to produce genuine RED
# evidence (both concurrent launches PROCEED there: no reservation mechanism
# exists to make the second call see the first's claim) and against the
# fixed script for GREEN. Console ruling (HIMMEL-nextleg-2026-09-13D,
# 2026-09-13): write case (a) first, run it RED against the pre-fix copy,
# THEN implement — RED and GREEN both go in the PR body side by side.
#
# No .ps1 twin: the atomic mkdir admission/reservation mechanism it exercises
# is a POSIX tmpfs (${XDG_RUNTIME_DIR:-/tmp}/himmel-fleet-<uid>) construct
# with no Windows equivalent in bank-preflight.sh (project convention: a
# documented platform guard suffices for a test harness).
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="${FLEET_SUT:-$REPO/scripts/lib/bank-preflight.sh}"
PASS=0; FAIL=0
W="$(mktemp -d -t bank-preflight-fleet.XXXXXX)"; trap 'rm -rf "$W"' EXIT
NOW="$(date +%s)"
HEALTHY_CACHE="{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$NOW}"
printf '%s' "$HEALTHY_CACHE" > "$W/c.json"

check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }

# mk_ps_stub <dir> <pid:comm:argv> ... — same shape as test-bank-preflight.sh's
# own fixture builder, kept independent here (this suite must run standalone
# and unmodified against the pre-fix script, which predates that helper's
# current form).
mk_ps_stub() {
  local dir="$1"; shift
  mkdir -p "$dir/proc"
  local data="$dir/ps.data" entry pid comm argv
  : > "$data"
  for entry in "$@"; do
    pid="${entry%%:*}"; entry="${entry#*:}"
    comm="${entry%%:*}"; argv="${entry#*:}"
    printf '%s %s\n' "$pid" "$argv" >> "$data"
    mkdir -p "$dir/proc/$pid"
    printf '%s' "$comm" > "$dir/proc/$pid/comm"
  done
  printf '%s\n' '#!/usr/bin/env bash' "cat '$data'" > "$dir/ps"
  chmod +x "$dir/ps"
}

# run_pf <slots-dir> <proc-dir> <extra env assignments...> — invokes the SUT
# with a healthy bank cache (so a PROCEED/SKIPPED-FLEET verdict is never
# masked by an unrelated BANK-* verdict) and prints its stdout verdict.
run_pf() {
  local slots="$1" dir="$2"; shift 2
  env "$@" HIMMEL_FLEET_SLOTS="$slots" FLEET_PS_CMD="$dir/ps" FLEET_PROC="$dir/proc" \
    CADENCE_BANK_CACHE="$W/c.json" CADENCE_BANK_SKIP_REFRESH=1 CADENCE_BANK_LEDGER="$W/ledger.jsonl" \
    bash "$SUT" </dev/null 2>>"$W/err.log"
}

p0="$W/ps0"; mk_ps_stub "$p0"
p3="$W/ps3"; mk_ps_stub "$p3" \
  '9001:claude:--model claude-opus-5 -n HIMMEL-1000-leg load doc' \
  '9002:claude:--model claude-opus-5 -n HIMMEL-1001-leg load doc' \
  '9003:claude:--model claude-opus-5 -n HIMMEL-1002-leg load doc'

# --- (a) cap 4, 3 live, TWO CONCURRENT declared launches -> exactly one
# PROCEED, one SKIPPED-FLEET. This is the case the console asked to see RED
# first: on the pre-fix script there is no serialisation/reservation at all,
# so both concurrent calls independently read the SAME static 3-live count,
# both find it under cap, and both PROCEED — the fleet then actually lands
# at 5 once both go live. The fixed script's atomic `.admit` critical section
# makes the SECOND caller observe the FIRST caller's reservation.
slots_a="$(mktemp -d "$W/slots-a.XXXXXX")"
out_a="$W/out_a"; out_b="$W/out_b"
( run_pf "$slots_a" "$p3" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LEG=HIMMEL-9001-fleetA HIMMEL_FLEET_CAP=4 > "$out_a" ) &
pid_a=$!
( run_pf "$slots_a" "$p3" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LEG=HIMMEL-9002-fleetB HIMMEL_FLEET_CAP=4 > "$out_b" ) &
pid_b=$!
wait "$pid_a" "$pid_b"
va="$(cat "$out_a")"; vb="$(cat "$out_b")"
proceeds=0; skips=0
for v in "$va" "$vb"; do
  case "$v" in
    PROCEED) proceeds=$((proceeds+1)) ;;
    SKIPPED-FLEET) skips=$((skips+1)) ;;
  esac
done
check "(a) cap 4, 3 live, two concurrent declared launches -> exactly one PROCEED, one SKIPPED-FLEET (leg-a=$va leg-b=$vb)" "1 1" "$proceeds $skips"

# --- (b) a reservation is consumed once a live session with its name
# appears — the count must not double (live session + its own now-stale
# reservation both counted would silently shrink real headroom).
slots_b="$(mktemp -d "$W/slots-b.XXXXXX")"
p2="$W/ps2"; mk_ps_stub "$p2" \
  '9001:claude:--model claude-opus-5 -n HIMMEL-1000-leg load doc' \
  '9002:claude:--model claude-opus-5 -n HIMMEL-1001-leg load doc'
before_b="$(run_pf "$slots_b" "$p2" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LEG=HIMMEL-9003-consumeme HIMMEL_FLEET_CAP=4)"
check "(b) setup: declared launch under cap -> PROCEED, reservation created" PROCEED "$before_b"
p3live="$W/ps3live"; mk_ps_stub "$p3live" \
  '9001:claude:--model claude-opus-5 -n HIMMEL-1000-leg load doc' \
  '9002:claude:--model claude-opus-5 -n HIMMEL-1001-leg load doc' \
  '9003:claude:--model claude-opus-5 -n HIMMEL-9003-consumeme load doc'
: > "$W/err.log"
after_b="$(run_pf "$slots_b" "$p3live" HIMMEL_FLEET_CAP=4)"
check "(b) informational read after the reserved leg goes live -> PROCEED" PROCEED "$after_b"
if grep -q 'FLEET native=3 claudex=0 reserved=0 total=3/4' "$W/err.log" 2>/dev/null; then
  PASS=$((PASS+1)); echo "ok - (b) live session consumes its own reservation (reserved=0, not double-counted)"
else
  FAIL=$((FAIL+1)); echo "FAIL - (b) reservation not consumed by the matching live session"; grep 'FLEET ' "$W/err.log" || true
fi

# --- (c) an expired reservation is pruned, not counted forever.
slots_c="$(mktemp -d "$W/slots-c.XXXXXX")"
mkdir -p "$slots_c/HIMMEL-9004-expiredleg"
printf '%s\n' "$((NOW - 10))" > "$slots_c/HIMMEL-9004-expiredleg/expires"
printf '%s\n' "$$" > "$slots_c/HIMMEL-9004-expiredleg/pid"
: > "$W/err.log"
c_out="$(run_pf "$slots_c" "$p0" HIMMEL_FLEET_CAP=4)"
check "(c) expired reservation present, 0 live, cap 4 -> PROCEED" PROCEED "$c_out"
if grep -q 'FLEET native=0 claudex=0 reserved=0 total=0/4' "$W/err.log" 2>/dev/null; then
  PASS=$((PASS+1)); echo "ok - (c) expired reservation pruned from the count"
else
  FAIL=$((FAIL+1)); echo "FAIL - (c) expired reservation still counted"; grep 'FLEET ' "$W/err.log" || true
fi
if [ -d "$slots_c/HIMMEL-9004-expiredleg" ]; then
  FAIL=$((FAIL+1)); echo "FAIL - (c) expired reservation directory not removed from disk"
else
  PASS=$((PASS+1)); echo "ok - (c) expired reservation directory removed from disk"
fi

# --- (d) a stale .admit (mtime > FLEET_ADMIT_STALE_SECS) is reclaimed via
# rename-then-verify, not left to wedge every future call permanently.
slots_d="$(mktemp -d "$W/slots-d.XXXXXX")"
mkdir -p "$slots_d/.admit"
printf '%s\n' "$((NOW - 61))" > "$slots_d/.admit/acquired"
: > "$W/err.log"
d_out="$(run_pf "$slots_d" "$p0" HIMMEL_FLEET_CAP=4)"
check "(d) stale .admit (61s old), 0 live, cap 4 -> PROCEED (reclaimed, not wedged)" PROCEED "$d_out"
if grep -q 'could not acquire the fleet admission lock' "$W/err.log" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "FAIL - (d) stale .admit was not reclaimed (lock-acquire failure logged)"
else
  PASS=$((PASS+1)); echo "ok - (d) stale .admit reclaimed without a lock-acquire failure"
fi
if [ -d "$slots_d/.admit" ]; then
  FAIL=$((FAIL+1)); echo "FAIL - (d) .admit left behind after the call completed"
else
  PASS=$((PASS+1)); echo "ok - (d) .admit released after the call completed"
fi

# --- (e) an informational run (no CADENCE_BANK_LAUNCH) counts reservations
# in the FLEET line but must never CREATE one of its own.
slots_e="$(mktemp -d "$W/slots-e.XXXXXX")"
e_out="$(run_pf "$slots_e" "$p3" CADENCE_BANK_LEG=HIMMEL-9005-infoleg HIMMEL_FLEET_CAP=4)"
check "(e) informational read (no CADENCE_BANK_LAUNCH), 3 live, cap 4 -> PROCEED" PROCEED "$e_out"
e_entries="$(find "$slots_e" -mindepth 1 -maxdepth 1 -type d ! -name .admit 2>/dev/null | wc -l | tr -d ' ')"
check "(e) informational read creates no reservation directory" 0 "$e_entries"

# --- (f) a second declared launch of the SAME name is refused as a
# duplicate — with HEADROOM available (distinct from the at/over-cap
# refusal in case (a)), exercising the dedicated `mkdir $SLOTS/$LEG`
# duplicate-name branch specifically.
slots_f="$(mktemp -d "$W/slots-f.XXXXXX")"
f_first="$(run_pf "$slots_f" "$p0" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LEG=HIMMEL-9006-dupleg HIMMEL_FLEET_CAP=4)"
check "(f) setup: first declared launch, 0 live, cap 4 -> PROCEED" PROCEED "$f_first"
: > "$W/err.log"
f_second="$(run_pf "$slots_f" "$p0" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LEG=HIMMEL-9006-dupleg HIMMEL_FLEET_CAP=4)"
check "(f) same-name second declared launch, well under cap -> SKIPPED-FLEET (duplicate)" SKIPPED-FLEET "$f_second"
if grep -q 'already exists — refusing as a duplicate declared launch' "$W/err.log" 2>/dev/null; then
  PASS=$((PASS+1)); echo "ok - (f) refused via the duplicate-reservation-name branch, not the at/over-cap branch"
else
  FAIL=$((FAIL+1)); echo "FAIL - (f) duplicate refusal did not name the duplicate-reservation reason"
fi

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
