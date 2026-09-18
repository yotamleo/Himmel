#!/usr/bin/env bash
# test-fleet-reservation-key.sh — HIMMEL-3014 + HIMMEL-3017. Pins the ONE
# source of truth for a fleet reservation's on-disk key
# (scripts/lib/fleet-reservation-key.sh): bank-preflight.sh reserves under it
# and arm-resume.sh releases by it, so the two can never disagree.
#
# No .ps1 twin: the reservation dir is a POSIX tmpfs construct (same
# rationale as test-bank-preflight-fleet.sh).
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO/scripts/lib/fleet-reservation-key.sh"
PREFLIGHT="$REPO/scripts/lib/bank-preflight.sh"
PASS=0; FAIL=0
W="$(mktemp -d -t fleet-resv-key.XXXXXX)" || { echo "FAIL - could not create scratch dir via mktemp" >&2; exit 1; }
if [ -z "$W" ] || [ ! -d "$W" ]; then echo "FAIL - mktemp returned an empty/invalid scratch dir" >&2; exit 1; fi
trap 'rm -rf "$W"' EXIT

check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }

# --- (a) sourcing the helper has NO side effects: prints nothing, reserves
# nothing, and touches no slot dir (arm-resume sources it mid-run).
mkdir -p "$W/slots-a"
if [ ! -f "$LIB" ]; then
  FAIL=$((FAIL+1)); echo "FAIL - (a) $LIB does not exist"
  echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi
a_out="$(HIMMEL_FLEET_SLOTS="$W/slots-a" bash -c '. "$1"' _ "$LIB" 2>&1)"
check "(a) sourcing prints nothing" "" "$a_out"
check "(a) sourcing reserves nothing" "0" "$(find "$W/slots-a" -mindepth 1 | wc -l | tr -d ' ')"
# shellcheck source=/dev/null
. "$LIB"

# --- (b) key derivation
hash_of() { printf '%s' "$1" | cksum | awk '{print $1}'; }
check "(b) a plain name is its own key" "HIMMEL-1234-leg" "$(fleet_reservation_key HIMMEL-1234-leg)"
check "(b) a name containing '/' hashes" "$(hash_of a/b)" "$(fleet_reservation_key a/b)"
check "(b) a leading-'.' name hashes" "$(hash_of .hidden)" "$(fleet_reservation_key .hidden)"
n255="$(printf 'x%.0s' $(seq 1 255))"
n256="${n255}x"
check "(b) a 255-byte name (NAME_MAX) keeps its own key" "$n255" "$(fleet_reservation_key "$n255")"
check "(b) a 256-byte name hashes" "$(hash_of "$n256")" "$(fleet_reservation_key "$n256")"
# 200 two-byte characters = 400 bytes: length is judged in BYTES, not chars.
mb="$(printf 'é%.0s' $(seq 1 200))"
check "(b) a multibyte name over 255 BYTES hashes (byte length, not char length)" "$(hash_of "$mb")" "$(LC_ALL=en_US.UTF-8 fleet_reservation_key "$mb")"
check "(b) fleet_hash_key is the plain cksum" "$(hash_of abc)" "$(fleet_hash_key abc)"

# --- (c) bank-preflight.sh RESERVES under exactly that key — one source of
# truth, so a drift in either copy fails here rather than in production.
NOW="$(date +%s)"
printf '{"five_hour":{"utilization":10},"seven_day":{"utilization":20},"primaries_refreshed_at":%s}' "$NOW" > "$W/c.json"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$W/ps"; chmod +x "$W/ps"
mkdir -p "$W/proc"
reserve_under() { # <leg> -> prints the directory names left in a fresh slot dir
  local slots="$W/slots-$RANDOM$RANDOM"
  mkdir -p "$slots"
  FLEET_PROC="$W/proc" CADENCE_BANK_SKIP_REFRESH=1 FLEET_CAP_OK='' \
    CADENCE_BANK_CACHE="$W/c.json" CADENCE_BANK_LEDGER=/dev/null CADENCE_BANK_LAUNCH=1 \
    CADENCE_BANK_LEG="$1" HIMMEL_FLEET_SLOTS="$slots" HIMMEL_FLEET_CAP=4 FLEET_PS_CMD="$W/ps" \
    bash "$PREFLIGHT" </dev/null >/dev/null 2>&1
  (cd "$slots" && ls -A)
}
long="$(printf 'y%.0s' $(seq 1 300))"
check "(c) bank-preflight reserves an over-length leg under fleet_reservation_key" "$(fleet_reservation_key "$long")" "$(reserve_under "$long")"
check "(c) bank-preflight reserves a dot-prefixed leg under fleet_reservation_key" "$(fleet_reservation_key .dot)" "$(reserve_under .dot)"
check "(c) bank-preflight reserves a plain leg under its own name" "plain-leg" "$(reserve_under plain-leg)"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
