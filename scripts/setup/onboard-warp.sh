#!/usr/bin/env bash
# onboard-warp.sh — Warp integration onboarding for a fresh machine
# (HIMMEL-360, split out of onboard-telegram.sh). Called from
# scripts/setup.sh as a standalone onboarding step; also safe to run
# standalone:
#   bash scripts/setup/onboard-warp.sh
#
# VERIFY-ONLY, by design:
#   The Warp integration is repo-local skills (.claude/commands/open-warp.md +
#   oz-offload.md — present with the clone, nothing to install) + the
#   warp@claude-code-warp plugin (installed by
#   scripts/machine-setup/install-plugins.sh from docs/setup/settings-template.json)
#   + the Warp app itself. This script only verifies the Warp binary and prints
#   install hints.
#
# Env overrides (tests):
#   WARP_EXE — default %LOCALAPPDATA%/Programs/Warp/warp.exe
#
# Exit codes:
#   0 — ok (a missing Warp binary is EXPECTED on a fresh machine: reported as
#       a next-step, not failed on — the warp skills simply no-op without it)
set -uo pipefail

echo "-- Warp integration onboarding (verify-only) --"
echo "  skills: /open-warp + /oz-offload are repo-local (.claude/commands/) — ship with the clone"
echo "  plugin: warp@claude-code-warp installs via scripts/machine-setup/install-plugins.sh"
WARP_EXE="${WARP_EXE:-${LOCALAPPDATA:-$HOME/AppData/Local}/Programs/Warp/warp.exe}"
if command -v warp >/dev/null 2>&1; then
  echo "  warp binary: $(command -v warp)"
elif [ -f "$WARP_EXE" ]; then
  echo "  warp binary: $WARP_EXE"
else
  echo "  warp binary: MISSING — install from https://www.warp.dev (warp skills no-op without it)"
fi

exit 0
