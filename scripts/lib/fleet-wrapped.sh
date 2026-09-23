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
# over it. Revised same day: this must never exec another script (a
# fleet-wrapped.sh -> queue-lock.sh call edge pulled queue-lock.sh, and its
# own deps, into scripts/cr's guarded reachability closure unallowlisted —
# see test-cr-guarded-closure.sh). The lock check below reads
# queue-lock.sh's on-disk lock dir / owner.json directly instead; see
# fleet_lock_dir_for_doc's ponytail note for exactly how much of
# queue-lock.sh's own root/slug resolution this replicates.
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

# fleet_lock_slug_for_root <doc> <root> — prints the queue-lock slug <doc>
# would get under <root>, exactly as scripts/handover/queue-lock.sh's own
# _ql_slug_for_root computes it: strip ".md", relativize against <root> when
# <doc> falls under it, fold "/" to "__", then fold every remaining
# non-[A-Za-z0-9_-] character to "-".
fleet_lock_slug_for_root() {
  local _fls_p="${1%.md}" _fls_root="${2:-}"
  case "$_fls_p" in
    "$_fls_root"/*) _fls_p="${_fls_p#"$_fls_root"/}" ;;
  esac
  _fls_p="$(printf '%s' "$_fls_p" | sed 's#/#__#g')"
  printf '%s' "$_fls_p" | tr -c 'A-Za-z0-9_-' '-'
}

# fleet_lock_dir_for_doc <doc> — prints the canonical queue-lock directory
# for <doc> (rc 0) under the first root <doc> resolves under, out of
# $HANDOVER_DIR and handover-path.sh's handover_root (or
# $FLEET_HANDOVER_ROOT_OVERRIDE alone, for tests) — the same two roots
# fleet_doc_for_name already searches. rc 1 when <doc> falls under neither.
#
# ponytail: HIMMEL-3095, this covers only the two-root case queue-lock.sh's
# own _ql_roots_all resolves without a registry read (HANDOVER_DIR +
# handover_root — the common HIMMEL-2861 cross-root pair). It does not
# reimplement the full registry-scanned candidate-root list, nor the
# pre-HIMMEL-3290 legacy-mis-keyed-lock / namesake scan queue-lock.sh falls
# back to when the canonical dir is absent. A doc locked only under a
# registry root, or only under a legacy-keyed dir, reads as a missing lock
# dir here and this function returns 1 (ambiguous), which the caller below
# already treats as COUNT — fail-toward-cap, never a false exclude. Upgrade
# path: if that undercount-by-caution is ever measured to actually cost a
# fleet slot in practice, port _ql_candidate_roots' registry parse (or call
# queue-lock.sh's own root/slug helpers if they get exposed sourceable
# without pulling in acquire/release's write paths) rather than widening
# this by hand.
fleet_lock_dir_for_doc() {
  local _fld_doc="$1" _fld_root _fld_slug
  if [ -n "${FLEET_HANDOVER_ROOT_OVERRIDE:-}" ]; then
    set -- "$FLEET_HANDOVER_ROOT_OVERRIDE"
  else
    # shellcheck source=scripts/lib/handover-path.sh
    . "${FLEET_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/handover-path.sh" 2>/dev/null
    set -- "${HANDOVER_DIR:-}" "$(handover_root 2>/dev/null)"
  fi
  for _fld_root in "$@"; do
    if [ -z "$_fld_root" ] || [ ! -d "$_fld_root" ]; then continue; fi
    _fld_root="$(cd "$_fld_root" 2>/dev/null && pwd)" || continue
    case "$_fld_doc" in
      "$_fld_root"/*) : ;;
      *) continue ;;
    esac
    _fld_slug="$(fleet_lock_slug_for_root "$_fld_doc" "$_fld_root")"
    printf '%s\n' "$_fld_root/.locks/queue/$_fld_slug.lock"
    return 0
  done
  return 1
}

# fleet_process_is_wrapped_and_free <pid> <name> — rc 0 (EXCLUDE: wrapped
# and lock-free) or rc 1 (COUNT: everything else, including a failed or
# ambiguous doc/lock lookup). Read-only: no exec, just file/directory
# reads — see fleet_lock_dir_for_doc's ponytail note for the on-disk-format
# coupling this implies.
fleet_process_is_wrapped_and_free() {
  local _fpw_pid="$1" _fpw_name="$2" _fpw_doc _fpw_lockdir _fpw_status
  _fpw_doc="$(fleet_doc_for_pid "$_fpw_pid")" || _fpw_doc="$(fleet_doc_for_name "$_fpw_name")" || return 1
  [ -f "$_fpw_doc" ] || return 1
  _fpw_lockdir="$(fleet_lock_dir_for_doc "$_fpw_doc")" || return 1
  [ -e "$_fpw_lockdir" ] && return 1
  _fpw_status="$(fleet_doc_last_status "$_fpw_doc")"
  [ "$_fpw_status" = "WRAPPED" ] || return 1
  return 0
}
