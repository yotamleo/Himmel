#!/usr/bin/env bash
# ensure-tools.sh -- best-effort install of missing REQUIRED tools via the
# platform package manager (R6, HIMMEL-460). setup.sh's [0/10] preflight calls
# this so a missing git (etc.) is FETCHED, not just flagged. The fallback is
# always honest: on an unknown platform, no package manager, no root/sudo, or a
# failed install, the tool simply stays missing and the CALLER fails loud with
# the manual hint -- ensure_tools never claims success it didn't achieve.
#
# Tools with a known package name are attempted via the package manager (git,
# jq, python3). bun has no homebrew-core/apt/dnf package, so it is bootstrapped
# via its official installer (HIMMEL-548). Tools that still need a bespoke
# installer (node, gh) are left to the caller's hint.
#
# Usage:  source ensure-tools.sh; ensure_tools git jq ...   (re-check after).
#         bash ensure-tools.sh git jq ...                   (direct).
set -uo pipefail

# tool -> package name. Identity for the ones we handle; an empty result means
# "not auto-installable here" (caller keeps its manual hint).
_ensure_pkg_for() {
  case "$1" in
    git)     echo git ;;
    jq)      echo jq ;;
    python3) echo python3 ;;
    *)       echo "" ;;
  esac
}

# Echo the first supported package manager on PATH, or "" (rc 1) if none.
_ensure_detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then echo apt-get; return 0; fi
  if command -v dnf     >/dev/null 2>&1; then echo dnf;     return 0; fi
  if command -v brew    >/dev/null 2>&1; then echo brew;    return 0; fi
  echo ""; return 1
}

# bun bootstrap -- bun is not in homebrew-core / apt / dnf, so the official
# installer is the portable path (mac + linux, no tap). It lands the binary in
# $HOME/.bun/bin, which is NOT on PATH in this subprocess -- the CALLER (setup.sh)
# adds ~/.bun/bin to PATH and re-checks. The installer source is captured first
# (then piped to bash) so a curl failure is detected directly rather than masked
# by `bash` succeeding on empty stdin. Honest fallback: if curl is absent or the
# fetch fails, bun stays missing and the caller fails loud with the manual hint.
_ensure_install_bun() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "  ensure-tools: 'bun' needs curl to bootstrap (curl not found) -- install bun manually: https://bun.sh" >&2
    return 1
  fi
  echo "  ensure-tools: installing 'bun' via the official installer (https://bun.sh/install)..."
  local installer
  installer=$(curl -fsSL https://bun.sh/install 2>/dev/null) || installer=""
  if [ -n "$installer" ] && printf '%s' "$installer" | bash >/dev/null 2>&1; then
    return 0
  fi
  echo "  ensure-tools: bun official installer failed -- install bun manually: https://bun.sh" >&2
  return 1
}

# Echo the sudo prefix needed for apt/dnf: "" when root, "sudo" when a sudo
# binary exists, "__NOSUDO__" (rc 1) when neither (caller skips that tool).
_ensure_sudo_prefix() {
  if [ "$(id -u 2>/dev/null || echo 0)" = "0" ]; then echo ""; return 0; fi
  if command -v sudo >/dev/null 2>&1; then echo "sudo"; return 0; fi
  echo "__NOSUDO__"; return 1
}

# ensure_tools <tool>... -- attempt to install the auto-installable missing ones.
# Always returns 0; the caller re-checks `command -v` to see what truly remains.
ensure_tools() {
  [ "$#" -gt 0 ] || return 0
  local pm t pkg sudo_pfx
  pm=$(_ensure_detect_pm) || pm=""   # bun needs no pm; others fall through below
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 && continue
    # bun: no system package -- bootstrap via its official installer (mac + linux),
    # independent of any package manager.
    if [ "$t" = bun ]; then
      _ensure_install_bun
      continue
    fi
    if [ -z "$pm" ]; then
      echo "  ensure-tools: no supported package manager (apt-get/dnf/brew) found -- cannot auto-install '$t'; install it manually." >&2
      continue
    fi
    pkg=$(_ensure_pkg_for "$t")
    if [ -z "$pkg" ]; then
      echo "  ensure-tools: no known $pm package for '$t' -- install it manually." >&2
      continue
    fi
    if [ "$pm" = brew ]; then
      echo "  ensure-tools: installing '$t' via brew..."
      brew install "$pkg" >/dev/null 2>&1 || echo "  ensure-tools: 'brew install $pkg' failed -- install '$t' manually." >&2
      continue
    fi
    # apt-get / dnf need root.
    if ! sudo_pfx=$(_ensure_sudo_prefix); then
      echo "  ensure-tools: '$t' needs $pm but no root/sudo available -- install it manually." >&2
      continue
    fi
    echo "  ensure-tools: installing '$t' via $pm..."
    if [ "$pm" = apt-get ]; then
      $sudo_pfx apt-get update >/dev/null 2>&1 || true
      $sudo_pfx apt-get install -y "$pkg" >/dev/null 2>&1 \
        || echo "  ensure-tools: 'apt-get install $pkg' failed -- install '$t' manually." >&2
    else
      $sudo_pfx dnf install -y "$pkg" >/dev/null 2>&1 \
        || echo "  ensure-tools: 'dnf install $pkg' failed -- install '$t' manually." >&2
    fi
  done
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  ensure_tools "$@"
fi
