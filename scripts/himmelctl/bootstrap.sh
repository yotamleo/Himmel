#!/usr/bin/env bash
# scripts/himmelctl/bootstrap.sh — node-less bootstrap shim for himmelctl
# (HIMMEL-887 T7). For a genuinely node-less clean machine: detect node
# absent, install node (+ bun on darwin — apt has no bun package, so linux
# gets node+npm and bun stays an optional post-bootstrap step) via the
# platform package manager (darwin: brew, linux: apt), then hand off to
# `node scripts/himmelctl/bin.js install`. Nothing else — himmelctl's own
# preflight covers every other hard-gate tool. win32 machines use
# bootstrap.ps1 instead (winget).
#
# Usage:
#   bash scripts/himmelctl/bootstrap.sh [--dry-run]
#
# HIMMELCTL_REPO_ROOT overrides where bin.js is looked up (same seam bin.js
# itself honors) so a hermetic test can point the hand-off at a stub.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${HIMMELCTL_REPO_ROOT:-$(cd -- "$script_dir/../.." && pwd)}"
bin_js="$repo_root/scripts/himmelctl/bin.js"

dry_run=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    *) echo "bootstrap: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

handoff_cmd="node \"$bin_js\" install"

# install_plan — the package-manager line for this platform. darwin: brew
# (node+bun both brew-installable); everything else (linux, and any posix
# host running this .sh): apt — bun is not an apt package, so apt installs
# node via `nodejs npm` only (npm satisfies bin.js's hard gate) and bun stays
# a separate, optional, post-bootstrap step (see the note echoed below).
install_plan() {
  case "$(uname -s)" in
    Darwin) echo "brew install node bun" ;;
    *)      echo "sudo apt-get install -y nodejs npm" ;;
  esac
}

run_install() {
  case "$(uname -s)" in
    Darwin) brew install node bun ;;
    *)
      # Non-Darwin assumes apt (the only posix plan this shim carries). Do NOT
      # add distro-specific package managers (yum/dnf/pacman/zypper) — fail
      # closed with a manual-install pointer naming the detected platform so a
      # non-apt host never silently mis-runs `sudo apt-get` (HIMMEL-935 / CR #1126).
      if ! command -v apt-get >/dev/null 2>&1; then
        echo "bootstrap: no apt-get on this host ($(uname -s) $(uname -r)) -- install Node.js >=18 manually (see https://nodejs.org), put it on PATH, then re-run bootstrap" >&2
        return 1
      fi
      # Refresh the package index first: a fresh host's lists are often
      # empty/stale and the install fails outright (CodeRabbit r2, #1140).
      sudo apt-get update && sudo apt-get install -y nodejs npm
      ;;
  esac
}

# bun is optional (needed later for qmd/telegram features); apt has no bun
# package, so it is never part of the non-Darwin plan above. Point the
# operator at the upstream installer instead of silently dropping it.
note_bun_optional() {
  case "$(uname -s)" in
    Darwin) : ;; # brew installs bun above -- nothing to note
    *)      echo "bootstrap: bun not installed (optional -- needed later for qmd/telegram features; install from https://bun.sh)" ;;
  esac
}

if command -v node >/dev/null 2>&1; then
  # node-present short-circuit: straight to the hand-off, no install step.
  echo "bootstrap: node found -- handing off to: $handoff_cmd"
  [ "$dry_run" -eq 1 ] && exit 0
  exec node "$bin_js" install
fi

plan="$(install_plan)"
echo "bootstrap: node not found -- install plan: $plan"
echo "bootstrap: hand-off after install: $handoff_cmd"
[ "$dry_run" -eq 1 ] && exit 0

if ! run_install; then
  echo "bootstrap: node install failed" >&2
  exit 1
fi
note_bun_optional

if command -v node >/dev/null 2>&1; then
  echo "bootstrap: node installed -- handing off to: $handoff_cmd"
  exec node "$bin_js" install
fi

# PATH-refresh trap (Draft-A §6): the fresh install's PATH edit is invisible
# to this process. Print the ONE re-run line rather than chaining blindly.
echo "bootstrap: node installed but not resolvable in this shell -- open a new terminal and re-run: bash \"$script_dir/bootstrap.sh\"" >&2
exit 1
