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
#   vm_guest_quote_root <root>       the root as ONE guest-shell word (spaces quoted)
#   vm_guest_scan_cmd <root> <prof>  the portable scan command string
#   vm_guest_scan <root> <prof>      run it locally; rc 0 = clean
#   vm_guest_scan_hits <root> <out>  scan output minus `scan-skipped:` notes (count -> stderr)
#   vm_guest_assert_clean <runner> <root> <prof>
#       <runner> is a function taking ONE shell-command string and running it
#       on the guest (e.g. `ssh_vm`). Returns non-zero and prints REFUSING on any
#       hit OR if the guest cannot be scanned — fail closed: a guest that could
#       not be verified is not a clean guest.
# CLI (untracked builders): vm-guest-excludes.sh excludes tar|rsync
#                           vm-guest-excludes.sh scan <root> [full|env]
#
# ponytail: the snapshot scan (vmsdk.snapshot) covers ONLY the guest home dir and the
# two fixed staging dirs the tracked scripts use (/tmp/himmel-symmetry-vm,
# /tmp/himmel-luna-upgrade-vm), and never crosses filesystems (find -xdev, so a
# separate mount beneath a root is skipped). All of /tmp is not scanned: find exits
# non-zero on root-owned 0700 dirs (systemd-private-*), refusing every clean guest.
# Nested DIRECTORY symlinks are followed (HIMMEL-3236), one resolved target at a time
# and each with its own `find -xdev`, bounded: a target already on the chain (loop) is
# skipped, and so is one that resolves into a system tree (/ /proc /sys /dev /run /usr
# /bin /sbin /lib* /etc /boot /snap /var) — those never receive a host checkout and hold
# root-owned 0700 dirs that would refuse every guest. A secret planted under a system
# tree is therefore NOT covered. A directory target that stat's but cannot be entered
# fails closed; a link whose target cannot be stat'ed (EACCES behind an unsearchable
# ancestor) is indistinguishable in POSIX sh from a dangling link and is SKIPPED, not
# failed closed (HIMMEL-3238). Every link left UNSCANNED (file, dangling, system-tree or
# unstat-able target) is reported as a read-only `scan-skipped:` line and counted by the
# consumers (never a refusal); a loop skip is NOT reported, its target is an ancestor
# already on the scan chain and so is being scanned. Consumers filter
# that prefix out of the hit list; find prints absolute paths, so a real hit cannot start
# with it unless a directory name embeds a newline followed by the prefix (a hostile
# guest could then hide one hit line — an accepted residual, not a host-secret carrier).
# The untracked base builder (/tmp/m2457-rebuild.sh) stages wherever it likes and is
# NOT covered — it must call this CLI itself (operator item, HIMMEL-2540).
#
# bash 3.2-safe (sourced by scripts that run on macOS): no mapfile, no assoc arrays.

# Keep in step with SECRET_EXCLUDES in scripts/lib/vmsdk.py (parity-tested).
VM_GUEST_SECRET_GLOBS='.env .env.* *.local.json'

vm_guest_tar_excludes() {
  # Subshell: the noglob needed to split the unexpanded globs must not leak into
  # (or clobber) the caller's own `set -f` state.
  (
    set -f
    for g in $VM_GUEST_SECRET_GLOBS; do printf '%s\n' "--exclude=$g"; done
  )
}

vm_guest_rsync_excludes() {
  printf '%s\n' '--include=.env.example'   # first match wins in rsync
  vm_guest_tar_excludes
}

# A root as ONE guest-shell word (HIMMEL-3228): a space is allowed and single-quoted
# (a leading '~/' stays outside the quotes so the guest shell still expands it).
# Nothing that could end a word or start an option gets through: no leading '-' (it
# would become a find expression), no quote, ';', '$', newline, ...
# Byte-identical to _guest_path in vmsdk.py (parity-tested).
vm_guest_quote_root() {
  local root="$1"
  case "$root" in
    ''|[!A-Za-z0-9._/~+]*|*[!A-Za-z0-9._/~+\ -]*)
      echo "vm_guest_scan_cmd: unsafe root '$root' (guest-path characters only; a space is allowed, not first)" >&2
      return 2 ;;
    *' '*)
      # shellcheck disable=SC2088  # the tilde is meant literally: the GUEST shell expands it
      case "$root" in
        '~/'*) printf "~/'%s'" "${root#'~/'}" ;;
        '~'*) echo "vm_guest_scan_cmd: unsafe root '$root' (a ~user root cannot contain a space)" >&2; return 2 ;;
        *) printf "'%s'" "$root" ;;
      esac ;;
    *) printf '%s' "$root" ;;
  esac
}

# The scan is one POSIX-sh function (HIMMEL-3236): find the secret set under a dir,
# then recurse into each nested DIRECTORY symlink's resolved target. Bounds: a
# target already on the chain (loop) or in a system tree is skipped; every target is
# scanned by its own `find -xdev`; any find/cd failure exits non-zero (fail closed).
# Byte-identical to _SCAN_FN_HEAD/_SCAN_FN_TAIL in vmsdk.py (parity-tested).
# shellcheck disable=SC2016  # literal guest-shell text: nothing may expand HERE
VM_GUEST_SCAN_FN_HEAD='_s() ( d=$(cd -P -- "$1" && pwd -P) || exit 1; shift; for a; do [ "$a" = "$d" ] && exit 0; done; if [ $# -gt 0 ]; then case "$d/" in //|/proc/*|/sys/*|/dev/*|/run/*|/usr/*|/bin/*|/sbin/*|/lib/*|/lib32/*|/lib64/*|/libx32/*|/etc/*|/boot/*|/snap/*|/var/*) printf "scan-skipped: %s\n" "$d" >&2; exit 0;; esac; fi; find -H "$d" -xdev \( '
# shellcheck disable=SC2016  # literal guest-shell text: nothing may expand HERE
VM_GUEST_SCAN_FN_TAIL=' \) ! -name '\''.env.example'\'' ! -type d -print || exit 1; find -H "$d" -xdev -type l ! -exec test -d {} \; -print | while IFS= read -r x; do printf "scan-skipped: %s\n" "$x" >&2; done; l=$(find -H "$d" -xdev -type l -exec test -d {} \; -print) || exit 1; [ -n "$l" ] || exit 0; printf '\''%s\n'\'' "$l" | while IFS= read -r x; do _s "$x" "$d" "$@" || exit 1; done ); '

vm_guest_scan_cmd() {
  local root="$1" prof="${2:-full}" globs q
  q=$(vm_guest_quote_root "$root") || return 2
  case "$prof" in
    full) globs="-name '.env' -o -name '.env.*' -o -name '*.local.json'" ;;
    env)  globs="-name '.env' -o -name '.env.*'" ;;
    *) echo "vm_guest_scan_cmd: unknown profile '$prof' (full|env)" >&2; return 2 ;;
  esac
  # ! -type d: a directory named .env is a virtualenv convention, not a secret file.
  # -H: follow the ROOT if it is a symlink (find lists only the link otherwise, so a
  # root linking to a tree holding a .env would scan clean); nested directory
  # symlinks are followed by the `_s` recursion.
  printf '%s%s%s_s %s' "$VM_GUEST_SCAN_FN_HEAD" "$globs" "$VM_GUEST_SCAN_FN_TAIL" "$q"
}

# Split scan output into hits (stdout) and the read-only `scan-skipped:` notes the
# command prints for a nested link it did not follow (stderr count: a skip is
# visible, never a refusal — HIMMEL-3236). Find prints absolute paths, so a hit
# cannot start with the note prefix.
vm_guest_scan_hits() {
  local root="$1" out="$2" skipped
  skipped=$(printf '%s\n' "$out" | grep -c '^scan-skipped: ') || true
  if [ "${skipped:-0}" -gt 0 ]; then
    echo "vm_guest_scan: $root: secret scan did not follow $skipped nested link(s) (system tree, non-directory or unstat-able target)" >&2
  fi
  printf '%s\n' "$out" | grep -v -e '^scan-skipped: ' -e '^$' || true
}

vm_guest_scan() {
  local cmd out rc
  cmd=$(vm_guest_scan_cmd "$1" "${2:-full}") || return 2
  out=$(sh -c "$cmd" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "vm_guest_scan: scan of $1 failed (find rc=$rc): $out" >&2
    return 1
  fi
  out=$(vm_guest_scan_hits "$1" "$out")
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
  out=$(vm_guest_scan_hits "$root" "$out")
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
