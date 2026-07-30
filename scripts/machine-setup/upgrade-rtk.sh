#!/usr/bin/env bash
# upgrade-rtk.sh — upgrade the installed rtk binary (rtk-ai/rtk) to the latest
# GitHub release (HIMMEL-1323 drift-fix cadence; the "upgrade.command" on the
# "rtk" entry in scripts/upstreams.json points here).
#
# WHY this exists: rtk is tracked kind=tag_release/mode=probe — there is no
# in-repo version pin, only `rtk --version` on whatever machine has it
# installed. "Repairing" rtk drift therefore means upgrading the actual
# installed binary, not editing a file, and there is no `rtk self-update`
# verb. himmel installs rtk only as a side effect of full machine
# provisioning (scripts/machine-setup/ubuntu.sh / win11.ps1, "Install RTK"
# step) — this script reuses those exact artifact sources (the GitHub
# release .deb / zip) instead of upstream's `curl | sh` one-liner, which
# himmel does not run unattended.
#
# This is an UPGRADER, not an installer: a machine with no rtk installed is
# rc=2, not a fresh install. Safety is the whole point:
#   1. record the current version (rtk --version)
#   2. back up the current binary before touching anything
#   3. replace it
#   4. smoke-test the replacement — --version must parse strictly newer, PLUS
#      one trivial functional probe (`rtk ls <tmpdir>`, verified by hand
#      against the real 0.43.0 install before this script was written)
#   5. ANY smoke-test failure restores the backup and exits 4 — a machine
#      must never be left with a broken rtk.
#
# Usage:
#   bash scripts/machine-setup/upgrade-rtk.sh [--dry-run]
#
# Test seams (env vars; all unset in production — see test-upgrade-rtk.sh):
#   RTK_UPGRADE_PLATFORM  force windows|linux|macos instead of deriving from
#                         OSTYPE. Lets the Linux backup/smoke/rollback logic
#                         run hermetically under Windows Git-Bash, and lets
#                         the "unsupported platform" path be exercised
#                         without an actual Mac.
#   RTK_BIN               command name resolved via `command -v` for
#                         --version / the functional probe (default: rtk).
#   RTK_LATEST_TAG         skip the GitHub releases/latest API call and use
#                         this tag directly (e.g. v0.44.0).
#   RTK_INSTALL_DIR        scratch dir for the downloaded .deb + the
#                         pre-upgrade backup (default: a fresh mktemp -d).
#   RTK_DOWNLOAD_CMD       replace the entire fetch+install step with this
#                         shell command (env RTK_TARGET_VERSION,
#                         RTK_TARGET_TAG, RTK_BIN_PATH, RTK_INSTALL_DIR are
#                         exported to it). Unset in production: does the
#                         real curl-the-deb + `sudo apt install -y` flow
#                         ubuntu.sh uses.
#   RTK_PWSH_BIN           pwsh/powershell.exe override for the Windows
#                         dispatch (default: resolved from PATH).
#   RTK_UPGRADE_LOCK_TTL   seconds after which a held concurrency lock is
#                         presumed abandoned and reclaimed (default: 1800).
#
# Exit codes:
#   0  upgraded, or already current (both are a clean no-op on re-run)
#   2  environment unusable — no rtk installed, unsupported platform, no
#      curl/jq, or the release tag is malformed / asset could not be resolved
#   3  another upgrade already holds the concurrency lock — refused, never
#      queued (a stacked nightly cadence run must fail fast, not wait)
#   4  the upgrade was attempted and FAILED; the pre-upgrade backup was
#      restored (announced explicitly)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Named PS1_TWIN, not PS1 (CR glm-4): bare `PS1` is bash's prompt variable.
# Harmless in a non-interactive script, misleading the moment anyone sources it.
PS1_TWIN="$SCRIPT_DIR/upgrade-rtk.ps1"

# Same version shape as scripts/upstreams.json's rtk `version_regex`.
VERSION_RE='[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.-]*'

DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "upgrade-rtk: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# is_newer <candidate> <baseline> -- true if candidate is strictly newer than
# baseline. Bash-native component-wise numeric compare on the leading
# dotted-numeric run (a trailing suffix like -rc1 is ignored) -- NOT `sort -V`,
# which the stock BSD `sort` on macOS does not support at all (this suite
# deliberately forces the Linux code path onto every host OS, macOS CI
# runners included, per the header comment above), so a GNU-only flag here
# broke the suite on that leg. Same discipline upgrade-rtk.ps1's Test-IsNewer
# uses, so the two platforms cannot quietly diverge on a suffixed tag (CR).
is_newer() {
  [ "$1" = "$2" ] && return 1
  local c="" b=""
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)* ]] && c="${BASH_REMATCH[0]}"
  [[ "$2" =~ ^[0-9]+(\.[0-9]+)* ]] && b="${BASH_REMATCH[0]}"
  if [ -z "$c" ] || [ -z "$b" ]; then return 1; fi
  local ca cb i n cv bv
  IFS=. read -r -a ca <<< "$c"
  IFS=. read -r -a cb <<< "$b"
  n=${#ca[@]}
  [ "${#cb[@]}" -gt "$n" ] && n=${#cb[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    cv=${ca[$i]:-0}
    bv=${cb[$i]:-0}
    if [ "$cv" -ne "$bv" ]; then
      [ "$cv" -gt "$bv" ]
      return $?
    fi
    i=$((i + 1))
  done
  return 1
}

_platform() {
  if [ -n "${RTK_UPGRADE_PLATFORM:-}" ]; then
    printf '%s\n' "$RTK_UPGRADE_PLATFORM"
    return
  fi
  case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    msys*|cygwin*|win32*|MINGW*|MSYS*) echo windows ;;
    linux*|Linux*) echo linux ;;
    darwin*|Darwin*) echo macos ;;
    *) echo unknown ;;
  esac
}

PLATFORM="$(_platform)"

case "$PLATFORM" in
  windows)
    PWSH_BIN="${RTK_PWSH_BIN:-}"
    if [ -z "$PWSH_BIN" ]; then
      for c in pwsh pwsh.exe powershell.exe; do
        if command -v "$c" >/dev/null 2>&1; then PWSH_BIN="$c"; break; fi
      done
    fi
    if [ -z "$PWSH_BIN" ]; then
      echo "upgrade-rtk: pwsh not found on PATH -- run scripts/machine-setup/upgrade-rtk.ps1 directly." >&2
      exit 2
    fi
    ps_args=()
    [ "$DRY_RUN" -eq 1 ] && ps_args+=("-DryRun")
    "$PWSH_BIN" -NoProfile -ExecutionPolicy Bypass -File "$PS1_TWIN" ${ps_args[@]+"${ps_args[@]}"}
    exit $?
    ;;
  linux) : ;;
  *)
    echo "upgrade-rtk: unsupported on this platform ($PLATFORM) -- upgrade rtk manually (see rtk-ai/rtk releases)." >&2
    exit 2
    ;;
esac

# ---- Linux flow -------------------------------------------------------------

RTK_BIN="${RTK_BIN:-rtk}"
RTK_BIN_PATH="$(command -v "$RTK_BIN" 2>/dev/null || true)"
if [ -z "$RTK_BIN_PATH" ]; then
  echo "upgrade-rtk: '$RTK_BIN' is not installed -- this is an upgrader, not an installer. Run the machine-setup provisioning first." >&2
  exit 2
fi

CURRENT_RAW="$("$RTK_BIN_PATH" --version 2>&1)" || {
  echo "upgrade-rtk: '$RTK_BIN_PATH --version' failed to run -- can't establish a baseline, refusing to upgrade." >&2
  exit 2
}
CURRENT_VERSION="$(printf '%s\n' "$CURRENT_RAW" | grep -oE "$VERSION_RE" | head -1)"
if [ -z "$CURRENT_VERSION" ]; then
  echo "upgrade-rtk: could not parse a version from: $CURRENT_RAW" >&2
  exit 2
fi

if [ -n "${RTK_LATEST_TAG:-}" ]; then
  TARGET_TAG="$RTK_LATEST_TAG"
else
  command -v curl >/dev/null 2>&1 || { echo "upgrade-rtk: curl required to resolve the latest rtk release" >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || { echo "upgrade-rtk: jq required to resolve the latest rtk release" >&2; exit 2; }
  TARGET_TAG="$(curl -s --max-time 30 https://api.github.com/repos/rtk-ai/rtk/releases/latest | jq -r .tag_name)"
  if [ -z "$TARGET_TAG" ] || [ "$TARGET_TAG" = "null" ]; then
    echo "upgrade-rtk: could not resolve the latest rtk release tag from the GitHub API" >&2
    exit 2
  fi
fi
TARGET_VERSION="${TARGET_TAG#v}"
if ! [[ "$TARGET_VERSION" =~ ^${VERSION_RE}$ ]]; then
  echo "upgrade-rtk: invalid release tag '$TARGET_TAG' -- expected a version like v0.44.0." >&2
  exit 2
fi

if ! is_newer "$TARGET_VERSION" "$CURRENT_VERSION"; then
  echo "upgrade-rtk: already current (installed $CURRENT_VERSION, latest $TARGET_VERSION) -- nothing to do."
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY upgrade-rtk: $RTK_BIN_PATH  $CURRENT_VERSION -> $TARGET_VERSION (tag $TARGET_TAG)"
  echo "DRY would back up $RTK_BIN_PATH, install the new rtk_amd64.deb, smoke-test, and roll back on any failure."
  exit 0
fi

# --------------------------------------------------------------------------
# Concurrency lock (CR round 4, HIMMEL-1323): nothing else here serializes
# overlapping invocations, and this repo genuinely runs several concurrent
# Claude sessions (HIMMEL-1338) — two overlapping upgrades sharing the same
# INSTALL_DIR (the Windows twin's DEFAULT is shared, $env:TEMP\rtk-upgrade,
# not a fresh mktemp -d) can overwrite each other's backup or roll back to a
# stale binary. Same lock-directory idiom as scripts/ci/run-shell-tests.sh's
# suite lock (HIMMEL-1338): mkdir is atomic, and an owner file (pid/host/
# started) lets a crashed holder's lock be told apart from a live one via a
# TTL. Scaled down from that lock: this one never queues — a stacked nightly
# upgrade must fail fast (exit 3), not wait — so it skips the takeover-claim
# CAS dance that lock needs only to make a RECLAIM race-safe under
# contention this script never sees (one nightly cadence + occasional manual
# runs, not fifteen nested test-runner invocations).
RTK_LOCK_DIR=""
RTK_LOCK_OWNED=0

_rtk_lock_host() {
  printf '%s' "${HOSTNAME:-${COMPUTERNAME:-$(hostname 2>/dev/null || echo unknown)}}"
}

# _rtk_lock_field <owner-file> <key> -> value, or "" if absent/unreadable.
_rtk_lock_field() {
  local k v
  while IFS='=' read -r k v; do
    [ "$k" = "$2" ] && { printf '%s' "$v"; return 0; }
  done < "$1" 2>/dev/null
  return 0
}

# shellcheck disable=SC2329,SC2317  # invoked via the EXIT trap
rtk_lock_release() {
  [ "$RTK_LOCK_OWNED" -eq 1 ] || return 0
  rm -f "$RTK_LOCK_DIR/owner" 2>/dev/null
  rmdir "$RTK_LOCK_DIR" 2>/dev/null
  RTK_LOCK_OWNED=0
}

# rtk_lock_acquire <dir> — 0 once this process holds the lock; 1 to refuse
# (caller exits 3). Never waits — see header comment above.
rtk_lock_acquire() {
  local dir="$1" ttl="${RTK_UPGRADE_LOCK_TTL:-1800}"
  RTK_LOCK_DIR="$dir"
  if mkdir "$dir" 2>/dev/null; then
    if ( set -C; printf 'pid=%s\nhost=%s\nstarted=%s\n' "$$" "$(_rtk_lock_host)" "$(date +%s)" > "$dir/owner" ) 2>/dev/null; then
      RTK_LOCK_OWNED=1
      trap rtk_lock_release EXIT
      return 0
    fi
    [ -e "$dir/owner" ] || rmdir "$dir" 2>/dev/null
    return 1
  fi

  local o_pid o_host o_started now age=-1 this_host stale=0
  o_pid=$(_rtk_lock_field "$dir/owner" pid)
  o_host=$(_rtk_lock_field "$dir/owner" host)
  o_started=$(_rtk_lock_field "$dir/owner" started)
  this_host=$(_rtk_lock_host)
  now=$(date +%s)
  case "$o_started" in
    ''|*[!0-9]*) ;;
    *) age=$(( now - 10#$o_started )) ;;
  esac
  if [ -n "$o_pid" ] && [ "$o_host" = "$this_host" ]; then
    kill -0 "$o_pid" 2>/dev/null || stale=1
  fi
  [ "$age" -ge "$ttl" ] && stale=1

  if [ "$stale" -eq 1 ]; then
    rm -f "$dir/owner" 2>/dev/null
    rmdir "$dir" 2>/dev/null
    if mkdir "$dir" 2>/dev/null \
       && ( set -C; printf 'pid=%s\nhost=%s\nstarted=%s\n' "$$" "$this_host" "$(date +%s)" > "$dir/owner" ) 2>/dev/null; then
      echo "upgrade-rtk: cleared an abandoned lock (pid=${o_pid:-?} host=${o_host:-?} age=${age}s) at $dir" >&2
      RTK_LOCK_OWNED=1
      trap rtk_lock_release EXIT
      return 0
    fi
  fi

  echo "upgrade-rtk: another upgrade already holds the lock (pid=${o_pid:-unknown} host=${o_host:-unknown} age=${age}s) -- $dir" >&2
  echo "    refusing to queue -- the nightly cadence never stacks concurrent upgrades. Re-run once it finishes." >&2
  return 1
}

INSTALL_DIR="${RTK_INSTALL_DIR:-$(mktemp -d)}"
rtk_lock_acquire "${INSTALL_DIR}.lock" || exit 3
mkdir -p "$INSTALL_DIR"
BACKUP="$INSTALL_DIR/rtk.pre-upgrade.bak"
if ! cp -p "$RTK_BIN_PATH" "$BACKUP" 2>/dev/null && ! cp "$RTK_BIN_PATH" "$BACKUP"; then
  echo "upgrade-rtk: could not back up $RTK_BIN_PATH to $BACKUP -- refusing to upgrade without a backup." >&2
  exit 2
fi

# Returns 0 only when the binary was ACTUALLY restored (CR codex-1). The deb
# path installs through `sudo apt`, which can leave a root-owned binary an
# unprivileged `cp` cannot overwrite — so retry through sudo (non-interactive:
# an unattended cadence has nobody to answer a password prompt) before giving
# up, and report the failure rather than swallowing it.
restore_backup() {
  if cp -p "$BACKUP" "$RTK_BIN_PATH" 2>/dev/null || cp "$BACKUP" "$RTK_BIN_PATH" 2>/dev/null; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 \
     && sudo -n cp -p "$BACKUP" "$RTK_BIN_PATH" 2>/dev/null; then
    return 0
  fi
  return 1
}

# The ONLY place a rollback outcome is announced. The previous shape —
# `restore_backup; echo "ROLLED BACK"` at four call sites — printed the success
# line unconditionally because restore_backup's status was discarded, so a
# failed restore claimed the machine was safe while leaving rtk broken. That is
# the exact failure the backup exists to prevent, so the claim now follows the
# result (CR codex-1).
announce_rollback() {
  if restore_backup; then
    echo "upgrade-rtk: ROLLED BACK -- $RTK_BIN_PATH restored to $CURRENT_VERSION." >&2
    return 0
  fi
  echo "upgrade-rtk: ROLLBACK FAILED -- could NOT restore $RTK_BIN_PATH from $BACKUP." >&2
  echo "    The installed rtk may be broken or absent. Restore it by hand:" >&2
  echo "        sudo cp -p '$BACKUP' '$RTK_BIN_PATH'" >&2
  return 1
}

if [ -n "${RTK_DOWNLOAD_CMD:-}" ]; then
  if ! env RTK_TARGET_VERSION="$TARGET_VERSION" RTK_TARGET_TAG="$TARGET_TAG" \
        RTK_BIN_PATH="$RTK_BIN_PATH" RTK_INSTALL_DIR="$INSTALL_DIR" \
        sh -c "$RTK_DOWNLOAD_CMD"; then
    echo "upgrade-rtk: install step (RTK_DOWNLOAD_CMD) failed -- restoring the pre-upgrade backup." >&2
    announce_rollback
    exit 4
  fi
else
  # Real flow (mirrors ubuntu.sh's "Install RTK" step): the unversioned
  # rtk_amd64.deb alias survives both version AND debian-revision bumps —
  # see ubuntu.sh's comment on the same derivation. Assumes sudo credentials
  # are already usable in this shell, same assumption ubuntu.sh makes.
  DEB="$INSTALL_DIR/rtk_amd64.deb"
  if ! curl -fL --max-time 120 "https://github.com/rtk-ai/rtk/releases/download/${TARGET_TAG}/rtk_amd64.deb" -o "$DEB"; then
    echo "upgrade-rtk: download of rtk_amd64.deb ($TARGET_TAG) failed -- $RTK_BIN_PATH was never touched." >&2
    exit 2
  fi
  # -n: non-interactive. Plain `sudo` would prompt for a password and hang an
  # unattended cadence run indefinitely (HIMMEL-1323) if NOPASSWD isn't
  # configured for this user -- fail fast with a clear message instead.
  if ! sudo -n apt install -y "$DEB"; then
    echo "upgrade-rtk: 'sudo apt install' of the new rtk failed (or sudo needs a password -- NOPASSWD is not configured for this user) -- restoring the pre-upgrade backup." >&2
    announce_rollback
    exit 4
  fi
fi

NEW_RAW="$("$RTK_BIN_PATH" --version 2>&1)"
NEW_RC=$?
NEW_VERSION="$(printf '%s\n' "$NEW_RAW" | grep -oE "$VERSION_RE" | head -1)"
if [ "$NEW_RC" -ne 0 ] || [ -z "$NEW_VERSION" ] || ! is_newer "$NEW_VERSION" "$CURRENT_VERSION"; then
  echo "upgrade-rtk: smoke test FAILED ('$RTK_BIN_PATH --version' -> rc=$NEW_RC, parsed='$NEW_VERSION', expected > $CURRENT_VERSION) -- restoring the pre-upgrade backup." >&2
  announce_rollback
  exit 4
fi

# Functional probe: `rtk ls <tmpdir>` -- verified by hand against the real
# 0.43.0 install (rc=0, prints a compact file listing) before this script was
# written, so a rc!=0 here is a genuine functional regression, not a fluke.
PROBE_DIR="$(mktemp -d)"
: > "$PROBE_DIR/probe.txt"
if ! "$RTK_BIN_PATH" ls "$PROBE_DIR" >/dev/null 2>&1; then
  echo "upgrade-rtk: functional smoke test FAILED ('$RTK_BIN_PATH ls <tmpdir>' did not exit 0) -- restoring the pre-upgrade backup." >&2
  rm -rf "$PROBE_DIR"
  announce_rollback
  exit 4
fi
rm -rf "$PROBE_DIR"

echo "upgrade-rtk: OK -- $RTK_BIN_PATH  $CURRENT_VERSION -> $NEW_VERSION"
exit 0
