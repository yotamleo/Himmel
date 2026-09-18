#!/usr/bin/env bash
# scripts/lib/fleet-slots-shield.sh — HIMMEL-3103. Sourced by the arm-resume
# test suites (scripts/handover/test-arm-resume*.sh, test-worker-lifecycle.sh).
#
# Every non-dry-run arm-resume.sh calls bank-preflight.sh, which reserves a
# FLEET_CAP slot in ${HIMMEL_FLEET_SLOTS:-${XDG_RUNTIME_DIR:-/tmp}/himmel-fleet-<uid>}
# — the SAME per-user tmpfs dir the live fleet counts. A suite that does not
# redirect it makes a test fixture (a mktemp handover path) hold a real slot
# for the life of the arm, and a killed or --force run for the full TTL
# (observed 2026-09-16: a live leg launch refused by a test fixture).
#
#   fleet_slots_shield <tmp>            export HIMMEL_FLEET_SLOTS=<tmp>/fleet-slots
#                                       and assert it; rc 1 = not isolated
#   fleet_slots_assert_isolated <tmp>   assert only (suites that already pin
#                                       XDG_RUNTIME_DIR under <tmp>)
#
# Bash 3.2-safe; no twin needed (the slot dir is a POSIX tmpfs construct).

# Same expansion as bank-preflight.sh:390 and arm-resume.sh:1221 — keep in step.
fleet_slots_resolve() {
  printf '%s' "${HIMMEL_FLEET_SLOTS:-${XDG_RUNTIME_DIR:-/tmp}/himmel-fleet-$(id -u)}"
}

# rc 0 iff the resolved slot dir is strictly inside <tmp>; otherwise the arm
# under test would reserve outside it, so the caller must refuse to run.
fleet_slots_assert_isolated() {
  local tmp="${1:?fleet_slots_assert_isolated: suite TMP required}" resolved
  resolved="$(fleet_slots_resolve)"
  case "$resolved" in
    "$tmp"/?*) return 0 ;;
  esac
  echo "FAIL fleet-slots isolation: bank-preflight would reserve in '$resolved', outside the suite TMP '$tmp' — a test run must never take a real FLEET_CAP slot (HIMMEL-3103)" >&2
  return 1
}

fleet_slots_shield() {
  local tmp="${1:?fleet_slots_shield: suite TMP required}"
  export HIMMEL_FLEET_SLOTS="$tmp/fleet-slots"
  fleet_slots_assert_isolated "$tmp"
}
