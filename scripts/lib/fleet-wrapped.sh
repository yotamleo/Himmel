#!/usr/bin/env bash
# scripts/lib/fleet-wrapped.sh — HIMMEL-3095. Sourced by
# scripts/lib/bank-preflight.sh's fleet census: a leg that has WRAPPED
# (queue lock released, its handover doc's last status bullet reads
# WRAPPED) but whose process is still alive should not hold a FLEET_CAP
# slot. This defines the read-only check that decides that; it mutates
# nothing.
#
# Console ruling (HIMMEL-nextleg-2026-09-23J-console, 2026-09-23): exclude a
# process only when BOTH the queue lock is free AND the last status bullet
# is WRAPPED. Any lookup that fails or is ambiguous counts the process —
# fail toward the cap, never toward an undercount that could push the fleet
# over it.
#
# Defines functions only; sourcing prints nothing and touches no file.
# Bash 3.2-safe; no .ps1 twin (reads /proc, a POSIX-only construct — the
# Windows launcher has no equivalent process table to resolve this from).

# fleet_doc_for_pid <pid> — prints the leg's handover doc path on stdout
# (rc 0) when <pid>'s /proc cmdline carries one. leg-claude-launcher.sh
# always launches a leg with a trailing prompt argv element of the exact
# shape `load <DOC> and continue` (see its own header comment), so this
# is the cheap, unambiguous resolution path the console asked to try
# first, before any directory glob. rc 1 when cmdline is unreadable, has
# no such element, or the path it names does not exist.
fleet_doc_for_pid() {
  local _fdp_file="${FLEET_PROC:-/proc}/$1/cmdline" _fdp_arg
  [ -r "$_fdp_file" ] || return 1
  while IFS= read -r -d '' _fdp_arg || [ -n "$_fdp_arg" ]; do
    case "$_fdp_arg" in
      "load "*" and continue")
        _fdp_arg="${_fdp_arg#load }"
        _fdp_arg="${_fdp_arg% and continue}"
        if [ -f "$_fdp_arg" ]; then
          printf '%s\n' "$_fdp_arg"
          return 0
        fi
        ;;
    esac
  done <"$_fdp_file" 2>/dev/null
  return 1
}

# fleet_doc_for_name <name> — glob fallback used only when
# fleet_doc_for_pid fails. Searches the handover root (handover-path.sh's
# handover_root, or $FLEET_HANDOVER_ROOT_OVERRIDE for tests) for exactly
# one *.md file whose basename contains <name>. Prints the path (rc 0) on
# exactly one hit; rc 1 on zero or on more than one (ambiguous — fail
# toward counting the process rather than guessing which doc is its own).
fleet_doc_for_name() {
  local _fdn_name="$1" _fdn_root _fdn_hits _fdn_n
  if [ -n "${FLEET_HANDOVER_ROOT_OVERRIDE:-}" ]; then
    _fdn_root="$FLEET_HANDOVER_ROOT_OVERRIDE"
  else
    # shellcheck source=scripts/lib/handover-path.sh
    . "${FLEET_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/handover-path.sh" 2>/dev/null || return 1
    _fdn_root="$(handover_root 2>/dev/null)" || return 1
  fi
  [ -n "$_fdn_root" ] && [ -d "$_fdn_root" ] || return 1
  _fdn_hits="$(find "$_fdn_root" -type f -iname "*${_fdn_name}*.md" 2>/dev/null)"
  _fdn_n="$(printf '%s\n' "$_fdn_hits" | grep -c .)"
  [ "$_fdn_n" -eq 1 ] || return 1
  printf '%s\n' "$_fdn_hits"
}

# fleet_doc_last_status <doc> — prints the status token (WRAPPED, READY,
# ...) of the LAST `## Results` bullet in <doc> that carries one, matching
# the same marker vocabulary console-kit/fleet.mjs's STATUS_RE reads.
# Empty output (still rc 0) when no bullet carries a recognized marker.
fleet_doc_last_status() {
  grep -E '^- ([0-9]{1,2}:[0-9]{2}[[:space:]]+)?(\*\*)?(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE)([^A-Za-z0-9_]|$)' "$1" 2>/dev/null \
    | tail -n 1 \
    | sed -E 's/^- ([0-9]{1,2}:[0-9]{2}[[:space:]]+)?(\*\*)?(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE).*/\3/'
}

# fleet_process_is_wrapped_and_free <pid> <name> — rc 0 (EXCLUDE: wrapped
# and lock-free) or rc 1 (COUNT: everything else, including a failed or
# ambiguous doc/lock lookup). Read-only: a queue-lock `status` call and two
# file reads, nothing is written or moved.
fleet_process_is_wrapped_and_free() {
  local _fpw_pid="$1" _fpw_name="$2" _fpw_doc _fpw_lock_out _fpw_lock_rc _fpw_status
  _fpw_doc="$(fleet_doc_for_pid "$_fpw_pid")" || _fpw_doc="$(fleet_doc_for_name "$_fpw_name")" || return 1
  [ -f "$_fpw_doc" ] || return 1
  _fpw_lock_out="$("${FLEET_QUEUE_LOCK:-$(dirname "${BASH_SOURCE[0]}")/../handover/queue-lock.sh}" status "$_fpw_doc" 2>/dev/null)"
  _fpw_lock_rc=$?
  [ "$_fpw_lock_rc" -eq 0 ] && [ "$_fpw_lock_out" = "free" ] || return 1
  _fpw_status="$(fleet_doc_last_status "$_fpw_doc")"
  [ "$_fpw_status" = "WRAPPED" ] || return 1
  return 0
}
