#!/usr/bin/env bash
# test-legs.sh — HIMMEL-4405. scripts/config-ui/legs.sh composes the existing
# owners (handover_root, fleet-manifest.sh list, leg_tail_status) and parses
# nothing itself: the newest manifest wins, each leg's status IS
# leg_tail_status, an empty root prints no manifest, no root exits 3, and a root
# that only the primary checkout's .env names (HANDOVER_DIR unset in the env,
# as `himmelctl ui` runs) is found.
#
# Fixture: a scratch git repo laid out as a checkout (scripts/config-ui/legs.sh,
# scripts/lib/*, scripts/handover/console-kit/fleet-manifest.sh copied verbatim)
# so legs.sh's anchor resolution lands on it and reads its fixture .env only.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
PASS=0; FAIL=0
W="$(mktemp -d -t config-ui-legs.XXXXXX)" || { echo "FAIL - mktemp" >&2; exit 1; }
if [ -z "$W" ] || [ ! -d "$W" ]; then echo "FAIL - mktemp returned an invalid dir" >&2; exit 1; fi
trap 'rm -rf "$W"' EXIT
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1"; else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }

co="$W/checkout"
mkdir -p "$co/scripts/config-ui" "$co/scripts/lib" "$co/scripts/handover/console-kit"
cp "$REPO/scripts/config-ui/legs.sh" "$co/scripts/config-ui/legs.sh"
for f in load-dotenv.sh handover-path.sh leg-tail-status.sh; do cp "$REPO/scripts/lib/$f" "$co/scripts/lib/$f"; done
cp "$REPO/scripts/handover/console-kit/fleet-manifest.sh" "$co/scripts/handover/console-kit/fleet-manifest.sh"
git -C "$co" init -q
LEGS="$co/scripts/config-ui/legs.sh"

# A handover root with two manifests (the newer one wins) and two leg docs.
root="$W/root"; mkdir -p "$root/himmel"
live="$root/himmel/HIMMEL-1-N1-live-RESUME.md"; wrapped="$root/himmel/HIMMEL-2-N2-done-RESUME.md"
printf '## Results\n- 01:00 LIVE — a\n' > "$live"
printf '## Results\n- 01:00 LIVE — a\n- 02:00 WRAPPED — done\n' > "$wrapped"
printf '{"schema":1,"legs":[{"doc":"%s","label":"old"}]}' "$wrapped" > "$root/himmel/old.fleet.json"
touch -d '2020-01-01' "$root/himmel/old.fleet.json"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N1"},{"doc":"%s","label":"N2"}]}' "$live" "$wrapped" > "$root/himmel/new.fleet.json"

# shellcheck source=../../lib/leg-tail-status.sh
. "$REPO/scripts/lib/leg-tail-status.sh"
out=$(HANDOVER_DIR="$root" bash "$LEGS"); rc=$?
check "rc 0 with a root and manifests" 0 "$rc"
check "the newer manifest is picked" "$root/himmel/new.fleet.json" "$(printf '%s' "$out" | jq -r .manifest)"
check "legs are the manifest's, in order" "$live
$wrapped" "$(printf '%s' "$out" | jq -r '.legs[].doc')"
check "a LIVE doc's status equals leg_tail_status" "$(leg_tail_status "$live")" "$(printf '%s' "$out" | jq -r --arg d "$live" '.legs[] | select(.doc==$d) | .status')"
check "a WRAPPED doc's status equals leg_tail_status" "$(leg_tail_status "$wrapped")" "$(printf '%s' "$out" | jq -r --arg d "$wrapped" '.legs[] | select(.doc==$d) | .status')"
check "the LIVE doc reads LIVE (not vacuous)" LIVE "$(printf '%s' "$out" | jq -r --arg d "$live" '.legs[] | select(.doc==$d) | .status')"
check "the WRAPPED doc reads WRAPPED (not vacuous)" WRAPPED "$(printf '%s' "$out" | jq -r --arg d "$wrapped" '.legs[] | select(.doc==$d) | .status')"

empty="$W/empty"; mkdir -p "$empty"
out=$(HANDOVER_DIR="$empty" bash "$LEGS"); rc=$?
check "an empty root exits 0" 0 "$rc"
check "an empty root prints no manifest and no legs" '{"manifest":null,"legs":[]}' "$(printf '%s' "$out" | jq -c '{manifest, legs}')"

# No HANDOVER_DIR in the env: the root comes from the checkout's own .env.
printf 'HANDOVER_DIR=%s\n' "$root" > "$co/.env"
out=$(env -u HANDOVER_DIR bash "$LEGS"); rc=$?
check "a root named only by the checkout .env is found" "$root/himmel/new.fleet.json" "$(printf '%s' "$out" | jq -r .manifest)"

# No env, no .env, no inline handovers/: no root, exit 3.
rm -f "$co/.env"
env -u HANDOVER_DIR bash "$LEGS" >/dev/null 2>&1; rc=$?
check "no handover root exits 3" 3 "$rc"

echo "legs: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
