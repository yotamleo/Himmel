#!/usr/bin/env bash
# vm-guest-excludes.sh — the ONE definition of what must not cross the host->guest
# boundary, and the assertion that a guest is clean (HIMMEL-2540).
#
# Platform guard (gitbash-only): POSIX bash 3.2+ (no mapfile/assoc arrays). The
# only consumers are the VM-driving shell scripts and vmsdk.py, all gitbash-only
# already; no .ps1 twin.
#
# Why: HIMMEL-2457's base builder rsynced a host checkout into the guest and
# excluded only .git/hooks; the gitignored-but-present .env (116 live keys) and
# .claude/settings.local.json rode along into a durable snapshot. A hand-kept
# denylist per copy site grows one incident at a time, so every tracked
# host->guest copy (vmsdk.sync_repo, test-install-symmetry-vm.sh,
# test-luna-upgrade-vm.sh) sources THIS file instead, and the untracked base
# builder can call it as a CLI (see below).
#
# Secret set (basename globs, matched at ANY depth):
#   .env   .env.*   *.local.json      (covers .claude/settings.local.json)
# .env.example is a public placeholder template, not a secret (the luna template
# ships one as a template-owned file the upgrade engine overwrites): the scan
# exempts it. rsync keeps it via a leading --include; tar cannot express an
# exemption, so a tar caller that needs it copies that one literal file itself.
#
# Scan profiles:
#   full — the whole set. For a tree STAGED from the host: nothing in the set
#          may exist there, ever.
#   env  — .env / .env.* only. For a guest IMAGE (~ before a snapshot): the guest
#          legitimately grows its own *.local.json (claude writes
#          .claude/settings.local.json on approval), but a .env is exactly the
#          host-secret carrier this ticket is about.
#
# API (source this file):
#   vm_guest_tar_excludes            one tar flag per line
#   vm_guest_rsync_excludes          one rsync flag per line
#   vm_guest_scan_cmd <root> <prof>  the portable `find` command string
#   vm_guest_scan <root> <prof>      run it locally; rc 0 = clean
#   vm_guest_assert_clean <runner> <root> <prof>
#       <runner> is a function taking ONE shell-command string and running it
#       on the guest (e.g. `ssh_vm`). Returns non-zero and prints REFUSING on any
#       hit OR if the guest cannot be scanned — fail closed: a guest that could
#       not be verified is not a clean guest.
# CLI (untracked builders): vm-guest-excludes.sh excludes tar|rsync
#                           vm-guest-excludes.sh scan <root> [full|env]
#
# bash 3.2-safe (sourced by scripts that run on macOS): no mapfile, no assoc arrays.

# Keep in step with SECRET_EXCLUDES in scripts/lib/vmsdk.py (parity-tested).
VM_GUEST_SECRET_GLOBS='.env .env.* *.local.json'

vm_guest_tar_excludes() {
  local g
  set -f
  for g in $VM_GUEST_SECRET_GLOBS; do printf '%s\n' "--exclude=$g"; done
  set +f
}

vm_guest_rsync_excludes() {
  printf '%s\n' '--include=.env.example'   # first match wins in rsync
  vm_guest_tar_excludes
}

vm_guest_scan_cmd() {
  local root="$1" prof="${2:-full}" globs
  case "$root" in
    ''|*[!A-Za-z0-9._/~+-]*)
      echo "vm_guest_scan_cmd: unsafe root '$root' (guest-path characters only)" >&2
      return 2 ;;
  esac
  case "$prof" in
    full) globs="-name '.env' -o -name '.env.*' -o -name '*.local.json'" ;;
    env)  globs="-name '.env' -o -name '.env.*'" ;;
    *) echo "vm_guest_scan_cmd: unknown profile '$prof' (full|env)" >&2; return 2 ;;
  esac
  # ! -type d: a directory named .env is a virtualenv convention, not a secret file.
  printf "find %s -xdev \\( %s \\) ! -name '.env.example' ! -type d -print" "$root" "$globs"
}

vm_guest_scan() {
  local cmd out rc
  cmd=$(vm_guest_scan_cmd "$1" "${2:-full}") || return 2
  out=$(sh -c "$cmd" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "vm_guest_scan: scan of $1 failed (find rc=$rc): $out" >&2
    return 1
  fi
  [ -z "$out" ] && return 0
  printf '%s\n' "$out"
  return 1
}

vm_guest_assert_clean() {
  local runner="$1" root="$2" prof="${3:-full}" cmd out rc
  cmd=$(vm_guest_scan_cmd "$root" "$prof") || return 2
  out=$("$runner" "$cmd"); rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "REFUSING: could not scan the guest under $root for secrets (rc=$rc) — an unverified guest is not a clean guest" >&2
    return 1
  fi
  if [ -n "$out" ]; then
    echo "REFUSING: secret-bearing files present on the guest under $root:" >&2
    printf '%s\n' "$out" | sed 's/^/  /' >&2
    return 1
  fi
  return 0
}

# CLI mode (not when sourced).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    excludes)
      case "${2:-}" in
        tar) vm_guest_tar_excludes ;;
        rsync) vm_guest_rsync_excludes ;;
        *) echo "usage: vm-guest-excludes.sh excludes tar|rsync" >&2; exit 2 ;;
      esac ;;
    scan)
      [ -n "${2:-}" ] || { echo "usage: vm-guest-excludes.sh scan <root> [full|env]" >&2; exit 2; }
      vm_guest_scan "$2" "${3:-full}" ;;
    *) echo "usage: vm-guest-excludes.sh excludes tar|rsync | scan <root> [full|env]" >&2; exit 2 ;;
  esac
fi
