#!/usr/bin/env bash
# scripts/lib/fleet-reservation-key.sh — HIMMEL-3014 + HIMMEL-3017. Sourced by
# scripts/lib/bank-preflight.sh (which RESERVES a fleet slot) and
# scripts/handover/arm-resume.sh (which RELEASES it on exit): the ONE place a
# leg name becomes the on-disk key of its reservation directory, so the
# reserver and the releaser cannot disagree about where the reservation lives.
#
# Defines functions only — sourcing prints nothing, reserves nothing and
# touches no slot dir (pinned by scripts/lib/test-fleet-reservation-key.sh).
# Bash 3.2-safe; no .ps1 twin (the slot dir is a POSIX tmpfs construct).
#
#   fleet_hash_key <leg>         bounded deterministic key (POSIX cksum): always
#                                a valid directory component
#   fleet_reservation_key <leg>  the key the reservation dir is created under:
#                                the name itself, unless it cannot be one
#                                directory component ('/', a leading '.', or
#                                longer than NAME_MAX = 255 BYTES), in which
#                                case fleet_hash_key. Two callers with the same
#                                unusable name derive the same key, so mkdir's
#                                own EEXIST still catches a duplicate launch.

fleet_hash_key() { printf '%s' "$1" | cksum | awk '{print $1}'; }

fleet_reservation_key() {
  case "$1" in
    */*|.*) fleet_hash_key "$1"; return 0 ;;
  esac
  # Bytes, not characters: NAME_MAX is a byte limit, and a multibyte name is
  # shorter in ${#1} than on disk. wc -c under LC_ALL=C counts bytes.
  if [ "$(printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' ')" -gt 255 ]; then
    fleet_hash_key "$1"
  else
    printf '%s' "$1"
  fi
}
