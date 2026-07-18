#!/usr/bin/env bash
# install-himmel-codex.sh (HIMMEL-597)
#
# Provision himmel under the Codex CLI by managing user-global plugin state in
# ~/.codex/config.toml the SAME way scripts/hermes/install-himmel-profile.sh
# provisions the hermes side. This is the codex-CLI half of the split:
#   hermes side : scripts/hermes/install-himmel-profile.{sh,ps1}  (CR/model profile)
#   codex side  : scripts/codex/install-himmel-codex.{sh,ps1}     (this file)
#
# It drives the `codex` CLI (codex plugin marketplace add / codex plugin add) —
# never hand-edits config.toml — so Codex owns all config writes (trust hashes,
# MCP secrets, long-path marketplace sources). NON-DESTRUCTIVE + idempotent: it
# only registers the himmel marketplace when absent and enables the himmel plugin
# set; it never removes or disables anything, and re-runs are no-ops.
#
#   install-himmel-codex.sh                 # register marketplace + enable default set
#   install-himmel-codex.sh --all           # also enable luna-correlate + pr-review-toolkit-himmel
#   install-himmel-codex.sh --plugins=himmel-ops,handover
#   install-himmel-codex.sh --dry-run       # report intended changes, mutate nothing
#
# Default plugin set (all @himmel): himmel-ops handover obsidian-triage telegram-himmel.
# Env overrides: CODEX_BIN (codex CLI path).
set -euo pipefail

MARKET="himmel"   # the himmel marketplace name (per marketplace/.claude-plugin/marketplace.json)
DRY_RUN=0
ALL=0
PLUGINS_OVERRIDE=""

for arg in "$@"; do
  case "$arg" in
    --dry-run)        DRY_RUN=1 ;;
    --all)            ALL=1 ;;
    --plugins=*)      PLUGINS_OVERRIDE="${arg#*=}" ;;
    -h|--help)        sed -n '2,/^set /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERR: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MARKET_PATH="$REPO_ROOT/marketplace"

# --- resolve the codex CLI ---------------------------------------------------
resolve_codex() {
  if [ -n "${CODEX_BIN:-}" ]; then
    [ -x "$CODEX_BIN" ] && { echo "$CODEX_BIN"; return 0; }
    return 1   # explicitly overridden but unusable -> hard error (no silent PATH fallback)
  fi
  command -v codex 2>/dev/null && return 0
  return 1
}
CODEX="$(resolve_codex)" || { echo "ERR: codex CLI not found (set CODEX_BIN, or install Codex)" >&2; exit 1; }

[ -d "$MARKET_PATH" ] || { echo "ERR: himmel marketplace dir not found at $MARKET_PATH" >&2; exit 1; }

# --- resolve the plugin set --------------------------------------------------
if [ -n "$PLUGINS_OVERRIDE" ]; then
  PLUGINS="$(printf '%s' "$PLUGINS_OVERRIDE" | tr ',' ' ')"
else
  PLUGINS="himmel-ops handover obsidian-triage telegram-himmel"
  [ "$ALL" = "1" ] && PLUGINS="$PLUGINS luna-correlate pr-review-toolkit-himmel"
fi

echo "codex CLI   : $CODEX"
echo "marketplace : $MARKET ($MARKET_PATH)"
[ "$DRY_RUN" = "1" ] && echo "mode        : DRY-RUN (no changes will be made)"

changed=0

# --- 1. register the himmel marketplace if absent ----------------------------
if "$CODEX" plugin marketplace list 2>/dev/null | awk -v n="$MARKET" '$1==n{f=1} END{exit f?0:1}'; then
  echo "UNCHANGED   : marketplace '$MARKET' already registered"
else
  if [ "$DRY_RUN" = "1" ]; then
    echo "WOULD ADD   : marketplace '$MARKET' -> $MARKET_PATH"
  else
    "$CODEX" plugin marketplace add "$MARKET_PATH" >/dev/null
    echo "CHANGED     : registered marketplace '$MARKET' -> $MARKET_PATH"
  fi
  changed=$((changed + 1))
fi

# --- 2. enable each plugin in the set if not already installed+enabled --------
# `codex plugin list` groups rows per-marketplace; each plugin row's first column
# is the FULL selector `name@marketplace` (verified live: `himmel-ops@himmel`),
# and the status column reads "installed, enabled". Match the exact selector
# (so a same-named plugin in another marketplace can't false-match) AND enabled.
plugin_list="$("$CODEX" plugin list 2>/dev/null || true)"
for p in $PLUGINS; do
  sel="$p@$MARKET"
  if printf '%s\n' "$plugin_list" | awk -v s="$sel" '$1==s && index($0,"installed, enabled"){f=1} END{exit f?0:1}'; then
    echo "UNCHANGED   : $sel (installed, enabled)"
  else
    if [ "$DRY_RUN" = "1" ]; then
      echo "WOULD ADD   : $sel"
    else
      "$CODEX" plugin add "$sel" >/dev/null
      echo "CHANGED     : enabled $sel"
    fi
    changed=$((changed + 1))
  fi
done

# --- 3. sanitize external-plugin hooks.json (HIMMEL-651) ---------------------
# Codex versions BEFORE rust-v0.143.0 reject a top-level `description` key that
# several external plugins ship in their hooks.json ("unknown field
# description") and skip those hooks at boot. Strip it so `codex` boots clean.
# Idempotent + non-fatal (cosmetic cleanup must never fail the install).
# DEPRECATED (HIMMEL-1104): upstream fixed this in rust-v0.143.0 (PR #30229), so
# on that version or newer this phase mutates external plugin files for no
# benefit. Removing the phase is tracked in HIMMEL-1114.
echo ""
echo "--- 3. sanitize external-plugin hooks.json (codex strict-parser workaround) ---"
if [ "$DRY_RUN" = "1" ]; then
  bash "$SCRIPT_DIR/sanitize-plugin-hooks.sh" --dry-run || echo "WARN: sanitize step failed (non-fatal)" >&2
else
  bash "$SCRIPT_DIR/sanitize-plugin-hooks.sh" || echo "WARN: sanitize step failed (non-fatal)" >&2
fi

echo ""
if [ "$DRY_RUN" = "1" ]; then
  echo "DRY-RUN: $changed change(s) would be made. Re-run without --dry-run to apply."
elif [ "$changed" -eq 0 ]; then
  echo "OK: himmel already provisioned under Codex (nothing to do)."
else
  echo "OK: himmel provisioned under Codex ($changed change(s))."
  echo "    Restart Codex so the newly-enabled plugins load; new project hooks are"
  echo "    trust-hashed on first use (interactive Codex prompts once)."
fi
