#!/usr/bin/env bash
# HIMMEL-4024: install step for the CLIs of the opt-in `code` kit (ast-grep, shfmt, bats).
# Opt-in, never run by the base bootstrap: these cost 0 listing tokens but are only needed
# by legs that restructure code or touch shell. The `code` / `code-ui` plugin profiles
# (scripts/lanes/plugin-profiles.json) cover the plugin half of the kit.
#   ast-grep  npm @ast-grep/cli, pinned below (drift row `ast-grep` in scripts/upstreams.json
#             rewrites the pin literal on a bump, version_pin)
#   shfmt, bats  the system package manager (apt / brew / pacman); distro-versioned, so their
#             drift rows are probe-only and report, never bump
# Usage: install-code-kit-clis.sh [--dry-run]
set -euo pipefail

AST_GREP_VERSION="${AST_GREP_VERSION:-0.45.3}"
DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  '') ;;
  *) echo "usage: install-code-kit-clis.sh [--dry-run]" >&2; exit 2 ;;
esac

run() {
  if [ "$DRY" = 1 ]; then echo "would run: $*"; else "$@"; fi
}

if command -v ast-grep >/dev/null 2>&1 && ast-grep --version 2>/dev/null | grep -qF "$AST_GREP_VERSION"; then
  echo "ast-grep $AST_GREP_VERSION already installed"
elif command -v npm >/dev/null 2>&1; then
  run npm install -g "@ast-grep/cli@${AST_GREP_VERSION}"
else
  echo "install-code-kit-clis: npm not found, skipping ast-grep" >&2
fi

missing=""
for tool in shfmt bats; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -z "$missing" ]; then
  echo "shfmt and bats already installed"
elif command -v apt-get >/dev/null 2>&1; then
  # shellcheck disable=SC2086 # $missing is a deliberate word list of package names
  run sudo apt-get install -y $missing
elif command -v brew >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  run brew install $missing
elif command -v pacman >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  run sudo pacman -S --needed --noconfirm $missing
else
  echo "install-code-kit-clis: no supported package manager, install${missing} by hand" >&2
fi
