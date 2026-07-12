#!/usr/bin/env bash
# wire-caveman-node.sh — rewrite the caveman SessionStart/UserPromptSubmit hook
# commands in a settings.json to route through the runtime node wrapper
# (scripts/lib/run-node.sh) instead of a bare `node` / a dangling `<node-path>` /
# a setup-time-frozen absolute path. Heals existing macOS/Linux installs and is
# the shared wiring used by ubuntu.sh on fresh installs.
#
#   bash wire-caveman-node.sh <settings.json> [himmel_path] [claude_dir]
#
# Defaults: himmel_path = $HIMMEL_REPO or this script's repo root;
#           claude_dir  = ${CLAUDE_DIR:-$HOME/.claude}.
# Idempotent (re-running is a byte-for-byte no-op). Matches caveman hooks by the
# script basename in the command string, so it converges from any prior form and
# leaves sibling hooks (check-update-available.sh, …) untouched.
#
# Windows: refuses (no-op). win11.ps1 owns Windows wiring and the
# C:\Program Files\nodejs path is stable across winget in-place updates.
set -uo pipefail

SETTINGS="${1:-}"
if [ -z "$SETTINGS" ] || [ ! -f "$SETTINGS" ]; then
    echo "wire-caveman-node: usage: wire-caveman-node.sh <settings.json> [himmel_path] [claude_dir]" >&2
    exit 2
fi

case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*)
        echo "wire-caveman-node: Windows detected — node path is stable, nothing to wire (win11.ps1 owns this)." >&2
        exit 0 ;;
esac

_self_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
HIMMEL_PATH="${2:-${HIMMEL_REPO:-$_self_root}}"
CLAUDE_DIR_RESOLVED="${3:-${CLAUDE_DIR:-${HOME:-}/.claude}}"

command -v jq >/dev/null 2>&1 || { echo "wire-caveman-node: jq is required" >&2; exit 1; }

# Count caveman hook commands so a direct (standalone) invocation gets a clear
# signal instead of a silent no-op when nothing matched.
n_caveman="$(jq '[.hooks.SessionStart[]?.hooks[]?, .hooks.UserPromptSubmit[]?.hooks[]?]
    | map(.command? // "") | map(select(test("caveman-(activate|mode-tracker)\\.js"))) | length' "$SETTINGS" 2>/dev/null || echo 0)"

tmp="$(mktemp)" || { echo "wire-caveman-node: mktemp failed" >&2; exit 1; }
if jq \
    --arg hp "$HIMMEL_PATH" \
    --arg cd "$CLAUDE_DIR_RESOLVED" '
  def rw:
    if ((.command? // "") | test("caveman-(activate|mode-tracker)\\.js"))
    then .command = ("bash \"" + $hp + "/scripts/lib/run-node.sh\" \"" + $cd
        + "/hooks/" + ((.command | capture("(?<b>caveman-(activate|mode-tracker)\\.js)")).b) + "\"")
    else . end;
  def rwgroups: map(.hooks = ((.hooks // []) | map(rw)));
  if (.hooks | type) == "object"
  then .hooks.SessionStart = ((.hooks.SessionStart // []) | rwgroups)
     | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) | rwgroups)
  else . end
' "$SETTINGS" > "$tmp"; then
    if [ -s "$tmp" ] && jq -e . "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$SETTINGS"
        if [ "${n_caveman:-0}" = 0 ]; then
            echo "wire-caveman-node: no caveman hook commands found to wire (no-op)" >&2
        else
            echo "wire-caveman-node: normalized $n_caveman caveman hook command(s) to the runtime wrapper" >&2
        fi
    else
        rm -f "$tmp"; echo "wire-caveman-node: refusing to write empty/invalid JSON" >&2; exit 1
    fi
else
    rm -f "$tmp"; echo "wire-caveman-node: jq transform failed" >&2; exit 1
fi
