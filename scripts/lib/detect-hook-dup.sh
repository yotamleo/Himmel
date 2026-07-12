#!/usr/bin/env bash
# detect-hook-dup.sh -- ADVISORY warning when a himmel UNIVERSAL hook is wired at
# BOTH user scope AND a project's settings.json, so it fires twice (R4,
# HIMMEL-460). The double-fire is benign + idempotent (SC11: two auto-approve
# passes = same allow; two block passes = same block), so this is advisory (always
# rc 0), never an error.
#
# SUPPRESSED when the project IS the himmel repo itself: its devs are EXPECTED to
# carry the committed project-scope hooks AND the user-scope wiring -- nagging them
# every setup run would be noise. Warn only for OTHER adopted projects.
#
# Usage:
#   bash detect-hook-dup.sh <user-settings> <project-settings> <himmel-root>
#
# Prints the remediation (`unwire-pretooluse-hooks --scope project --target`) the
# operator runs IF they accept the advice. Requires jq (no-ops without it).
set -uo pipefail

_DHD_UNIVERSAL="auto-approve-safe-bash block-edit-on-main block-read-secrets inject-initiative"

# Forward-slash + strip a trailing slash so the in-repo self-compare is robust to
# backslash paths (Windows) without needing realpath on a maybe-absent file.
_dhd_norm() { local s="${1//\\//}"; printf '%s' "${s%/}"; }

# Echo "yes" when <settings> wires a hook whose command path contains
# scripts/hooks/<basename>.sh anywhere (PreToolUse stanza or SessionStart array).
_dhd_has_hook() {
  local settings="$1" base="$2" pat
  [ -f "$settings" ] || { echo no; return; }
  command -v jq >/dev/null 2>&1 || { echo no; return; }
  jq -e . "$settings" >/dev/null 2>&1 || { echo no; return; }
  pat="scripts/hooks/${base}[.]sh"
  if jq -e --arg pat "$pat" 'any(.. | (.command? // empty) | strings; test($pat))' "$settings" >/dev/null 2>&1; then
    echo yes
  else
    echo no
  fi
}

detect_hook_dup() {
  local user="$1" project="$2" himmel="$3"
  # In-repo suppression: project settings IS himmel's own settings.json.
  if [ "$(_dhd_norm "$project")" = "$(_dhd_norm "$himmel/.claude/settings.json")" ]; then
    return 0
  fi
  local dups="" b
  for b in $_DHD_UNIVERSAL; do
    if [ "$(_dhd_has_hook "$user" "$b")" = yes ] && [ "$(_dhd_has_hook "$project" "$b")" = yes ]; then
      dups="$dups $b"
    fi
  done
  if [ -n "$dups" ]; then
    echo "  NOTE: these himmel UNIVERSAL hooks are wired at BOTH user and project scope (they fire twice):" >&2
    for b in $dups; do echo "    - $b" >&2; done
    echo "  The double-fire is benign + idempotent. To remove the redundant project copy, run:" >&2
    echo "    bash $himmel/scripts/lib/unwire-pretooluse-hooks.sh --scope project --target $(dirname "$(dirname "$project")")" >&2
  fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  [ "$#" -eq 3 ] || { echo "usage: detect-hook-dup.sh <user-settings> <project-settings> <himmel-root>" >&2; exit 2; }
  detect_hook_dup "$1" "$2" "$3"
fi
