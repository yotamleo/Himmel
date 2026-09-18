#!/usr/bin/env bash
# test-fleet-slots-shield.sh — HIMMEL-3103. The arm-resume test suites source
# scripts/lib/fleet-slots-shield.sh so a suite run never reserves a slot in the
# PRODUCTION fleet dir (${XDG_RUNTIME_DIR}/himmel-fleet-<uid>) that the live
# fleet's FLEET_CAP counts. This suite is the RED control for that guard: the
# shield must PASS when the slots dir is inside the suite's TMP and must FAIL
# when it resolves to the default production path (or anywhere else outside
# TMP) — a guard that cannot fail proves nothing.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }

W="$(mktemp -d -t fleet-slots-shield.XXXXXX)" || { echo "FAIL - mktemp -d failed" >&2; exit 1; }
if [ -z "$W" ] || [ ! -d "$W" ]; then echo "FAIL - mktemp returned an empty/invalid scratch dir" >&2; exit 1; fi
trap 'rm -rf "$W"' EXIT

LIB="$REPO/scripts/lib/fleet-slots-shield.sh"
if [ ! -f "$LIB" ]; then
  echo "FAIL - $LIB missing"; exit 1
fi
# shellcheck source=fleet-slots-shield.sh
. "$LIB"

# Pin a fake XDG dir so the "default production path" is deterministic and the
# controls never depend on (or touch) the operator's real /run/user state.
FAKE_XDG="$W/fake-xdg"
DEFAULT_PATH="$FAKE_XDG/himmel-fleet-$(id -u)"
TMP_SUITE="$W/suite-tmp"
mkdir -p "$TMP_SUITE"

# T1: the resolver mirrors bank-preflight.sh:390 / arm-resume.sh:1221.
out=$(env -u HIMMEL_FLEET_SLOTS XDG_RUNTIME_DIR="$FAKE_XDG" bash -c ". '$LIB'; fleet_slots_resolve")
check "T1a default resolves to XDG/himmel-fleet-uid" "$DEFAULT_PATH" "$out"
out=$(HIMMEL_FLEET_SLOTS="$W/x" XDG_RUNTIME_DIR="$FAKE_XDG" bash -c ". '$LIB'; fleet_slots_resolve")
check "T1b HIMMEL_FLEET_SLOTS override wins" "$W/x" "$out"
out=$(HIMMEL_FLEET_SLOTS="" XDG_RUNTIME_DIR="$FAKE_XDG" bash -c ". '$LIB'; fleet_slots_resolve")
check "T1c empty override falls back to the default (same :- as bank-preflight)" "$DEFAULT_PATH" "$out"

# T2: the shield exports a per-run dir inside TMP and passes.
out=$(env -u HIMMEL_FLEET_SLOTS XDG_RUNTIME_DIR="$FAKE_XDG" bash -c ". '$LIB'; fleet_slots_shield '$TMP_SUITE' && printf %s \"\$HIMMEL_FLEET_SLOTS\"" 2>&1)
rc=$?
check "T2a shield rc=0" "0" "$rc"
check "T2b shield exports <TMP>/fleet-slots" "$TMP_SUITE/fleet-slots" "$out"

# T3 (RED controls): the isolation assertion must FAIL on every shape that
# would let a suite reserve outside its TMP.
env -u HIMMEL_FLEET_SLOTS XDG_RUNTIME_DIR="$FAKE_XDG" bash -c ". '$LIB'; fleet_slots_assert_isolated '$TMP_SUITE'" >/dev/null 2>"$W/err.default"
check "T3a unset override (default production path) is refused" "1" "$?"
if grep -q "$DEFAULT_PATH" "$W/err.default"; then r=named; else r=silent; fi
check "T3b the refusal names the offending default path" "named" "$r"
HIMMEL_FLEET_SLOTS="$DEFAULT_PATH" XDG_RUNTIME_DIR="$FAKE_XDG" bash -c ". '$LIB'; fleet_slots_assert_isolated '$TMP_SUITE'" >/dev/null 2>&1
check "T3c override pointed AT the default production path is refused" "1" "$?"
HIMMEL_FLEET_SLOTS="$W/elsewhere/fleet" bash -c ". '$LIB'; fleet_slots_assert_isolated '$TMP_SUITE'" >/dev/null 2>&1
check "T3d override outside TMP is refused" "1" "$?"
HIMMEL_FLEET_SLOTS="${TMP_SUITE}-lookalike/fleet" bash -c ". '$LIB'; fleet_slots_assert_isolated '$TMP_SUITE'" >/dev/null 2>&1
check "T3e sibling dir sharing TMP's name prefix is refused" "1" "$?"
HIMMEL_FLEET_SLOTS="$TMP_SUITE" bash -c ". '$LIB'; fleet_slots_assert_isolated '$TMP_SUITE'" >/dev/null 2>&1
check "T3f TMP itself (not a dir strictly inside it) is refused" "1" "$?"

# T4: an XDG_RUNTIME_DIR already pinned under TMP is isolated with no override
# (the identity/queue-lock/long-gap/worker-lifecycle shape).
env -u HIMMEL_FLEET_SLOTS XDG_RUNTIME_DIR="$TMP_SUITE/xdg" bash -c ". '$LIB'; fleet_slots_assert_isolated '$TMP_SUITE'" >/dev/null 2>&1
check "T4 XDG pinned under TMP passes without an override" "0" "$?"

echo "== fleet-slots-shield: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
