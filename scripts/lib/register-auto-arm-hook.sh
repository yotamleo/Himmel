#!/usr/bin/env bash
# register-auto-arm-hook.sh <settings.json> <hook-command> [--assume-yes]
#
# Idempotently register the auto-arm-on-cap PreToolUse hook (matcher "*") in a
# Claude Code settings.json. Adapted from ubuntu.sh's inline registration block
# (HIMMEL-594) and used by macos.sh, with a hermetic test of its own. ubuntu.sh
# keeps its own copy (surgical — not refactored), so the two can drift; keep this
# jq idempotency logic in sync if ubuntu.sh's changes. bash-3.2-safe, atomic
# write (temp + mv), validates jq output before write.
#
# --assume-yes skips the interactive confirm (used by hermetic tests + the
# MACOS_ASSUME_YES installer seam). Without it the script prompts [Y]/n.
#
# Exit: 0 = registered OR already present OR user declined; 1 = error.
set -euo pipefail

SETTINGS="${1:?usage: register-auto-arm-hook.sh <settings.json> <hook-cmd> [--assume-yes]}"
HOOK_CMD="${2:?hook command required}"
ASSUME_YES=0
[ "${3:-}" = "--assume-yes" ] && ASSUME_YES=1

[ -f "$SETTINGS" ] || { echo "  ERROR: settings.json not found: $SETTINGS" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "  ERROR: jq required" >&2; exit 1; }

# Idempotent: already registered → no-op.
if jq -e '.hooks.PreToolUse // [] | map(.hooks // [] | map(.command) | join(" ")) | join(" ") | contains("auto-arm-on-cap.sh")' "$SETTINGS" >/dev/null 2>&1; then
    echo "  Already registered — skipping (idempotent)."
    exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    read -r -p "Register auto-arm-on-cap PreToolUse hook (auto-arms a resume at 90% usage)? [Y]es/[n]o [default: Y]: " ARM_CHOICE
    ARM_CHOICE="${ARM_CHOICE:-Y}"
    if [[ "$ARM_CHOICE" =~ ^[Nn] ]]; then
        echo "  Skipped auto-arm registration. Re-run this script or edit $SETTINGS manually."
        exit 0
    fi
fi

ENTRY=$(jq -n --arg cmd "$HOOK_CMD" '{matcher: "*", hooks: [{type: "command", command: $cmd}]}')
UPDATED=$(jq --argjson e "$ENTRY" '.hooks.PreToolUse = ((.hooks.PreToolUse // []) + [$e])' "$SETTINGS")
if [ -z "$UPDATED" ] || ! printf '%s\n' "$UPDATED" | jq -e . >/dev/null 2>&1; then
    echo "  ERROR: hook-register jq transform produced empty/invalid JSON — refusing to write" >&2
    exit 1
fi
printf '%s\n' "$UPDATED" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
echo "  Registered auto-arm-on-cap (PreToolUse, matcher *). Hook command: $HOOK_CMD"
