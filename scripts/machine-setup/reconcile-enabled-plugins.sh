#!/usr/bin/env bash
# reconcile-enabled-plugins.sh — enforce the lean plugin floor (HIMMEL-1032).
#
# WHY this exists: the lean plugin profile (HIMMEL-816) was ADDITIVE-ONLY —
# install-plugins installs the template's `true`-flagged plugins but never
# writes the `false` ones, so nothing is ever subtractive. Once a plugin is
# enabled (a manual /plugin toggle, an older template, himmelctl full-set, a
# "turn it back on" doc step) it stays enabled forever, and /himmel-update
# re-syncs + reports but never reconciles the live enabled-set DOWN to the
# template floor. Result: drift-back after every update (~44 plugins, ~10%
# context spent at session start).
#
# This is the plugin analog of `--strict-mcp-config`: it makes the template the
# authoritative floor and reconciles the live settings.json down to it.
#
# WHITELIST model: only plugins the template flags `true` survive. Every other
# spec — template `false` entries AND any live-enabled spec absent from the
# template (a future/unknown plugin that shipped enabled) — is forced `false`.
# The template's own true/false map is written verbatim, then unknown live
# specs are appended as false.
#
# settings.local.json is NEVER touched: Claude Code layers it OVER settings.json,
# so a per-machine `"<plugin>": true` there wins and is the intended escape hatch
# for a plugin you want on ONE machine (mirrors the operator's github:false).
#
# Idempotent + best-effort: re-running yields the same map; a missing/!JSON
# template or settings file is reported and skipped (exit non-zero standalone so
# a broken file is loud; himmel-update wraps this call non-fatally).
#
# Usage:
#   bash reconcile-enabled-plugins.sh [--dry-run] [--scope user|project|local]
#                                     [--settings PATH] [--template PATH]
#
#   --dry-run        Print the plan (what would flip) without writing.
#   --scope SCOPE    Resolve the default settings file: user (~/.claude,
#                    default), project (./.claude/settings.json), local
#                    (./.claude/settings.local.json — rarely the target; the
#                    floor belongs in settings.json, but supported for symmetry).
#   --settings PATH  Target settings file directly (overrides --scope; used by
#                    himmel-update and the hermetic tests).
#   --template PATH  Override the template (default: repo settings-template.json).
#
# Cross-platform: pure bash + jq (Git-Bash on Windows), matching
# install-plugins.sh. The install-plugins.ps1 twin has a PowerShell reconciler
# (reconcile-enabled-plugins.ps1) — keep the whitelist logic in lockstep.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

DRY_RUN=0
SCOPE="user"
SETTINGS=""
TEMPLATE="$REPO_ROOT/docs/setup/settings-template.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=1; shift ;;
    --scope)     SCOPE="$2"; shift 2 ;;
    --settings)  SETTINGS="$2"; shift 2 ;;
    --template)  TEMPLATE="$2"; shift 2 ;;
    -h|--help)   sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1; exit 0 ;;
    *) echo "reconcile-enabled-plugins: unknown flag: $1" >&2; exit 2 ;;
  esac
done

case "$SCOPE" in
  user|project|local) ;;
  *) echo "reconcile-enabled-plugins: invalid --scope: $SCOPE (expected user|project|local)" >&2; exit 2 ;;
esac

# Resolve the target settings file (--settings wins over --scope).
if [[ -z "$SETTINGS" ]]; then
  case "$SCOPE" in
    user)    SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" ;;
    project) SETTINGS="$PWD/.claude/settings.json" ;;
    local)   SETTINGS="$PWD/.claude/settings.local.json" ;;
  esac
fi

command -v jq >/dev/null 2>&1 || { echo "reconcile-enabled-plugins: jq required" >&2; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "reconcile-enabled-plugins: template not found: $TEMPLATE" >&2; exit 1; }
jq -e . "$TEMPLATE" >/dev/null 2>&1 || { echo "reconcile-enabled-plugins: template is not valid JSON: $TEMPLATE" >&2; exit 1; }

# The template's enabledPlugins map is the authoritative floor. Its keys are
# plugin@marketplace specs (no <himmel-path> placeholder), so no expansion.
TMPL_EP=$(jq -c '.enabledPlugins // {}' "$TEMPLATE")
if [[ "$TMPL_EP" == "{}" ]]; then
  echo "reconcile-enabled-plugins: template has no enabledPlugins — refusing to blank the live set" >&2
  exit 1
fi

if [[ ! -f "$SETTINGS" ]]; then
  echo "reconcile-enabled-plugins: settings file not found ($SETTINGS) — nothing to reconcile."
  exit 0
fi
if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
  echo "reconcile-enabled-plugins: $SETTINGS is not valid JSON — refusing to patch" >&2
  exit 1
fi

# Per-machine escape hatch: the sibling settings.local.json wins in BOTH
# directions (a `true` there keeps an operator-personal plugin like
# codex@openai-codex enabled; a `false` disables a template-floor plugin the
# operator doesn't want, e.g. playwright). Honored HERE — baked into the result
# — rather than left to runtime layering, so the override provably holds even if
# load-order semantics change. Only consulted when the target IS settings.json
# (basename guard avoids a settings.local target reading itself).
LOCAL_OVERRIDES="{}"
if [[ "$(basename "$SETTINGS")" == "settings.json" ]]; then
  LOCAL_FILE="$(dirname "$SETTINGS")/settings.local.json"
  if [[ -f "$LOCAL_FILE" ]]; then
    # Fail LOUD on an invalid local file: silently treating it as no-override
    # would reconcile the base settings and disable the very plugins the
    # operator kept in settings.local.json (the exact harm this file prevents).
    if jq -e . "$LOCAL_FILE" >/dev/null 2>&1; then
      LOCAL_OVERRIDES=$(jq -c '.enabledPlugins // {}' "$LOCAL_FILE")
    else
      echo "reconcile-enabled-plugins: $LOCAL_FILE exists but is not valid JSON — refusing to reconcile (its overrides would be lost, disabling wanted plugins)" >&2
      exit 1
    fi
  fi
fi

# newMap = { liveKey: false | liveKey NOT in template } + template + localOverrides
# (rightmost wins: template beats the unknown-false catch-all; settings.local.json
# beats the template floor.)
LIVE_EP=$(jq -c '.enabledPlugins // {}' "$SETTINGS")
NEW_EP=$(jq -cn --argjson tmpl "$TMPL_EP" --argjson live "$LIVE_EP" --argjson local "$LOCAL_OVERRIDES" '
  ($live | to_entries | map(. as $e | select(($tmpl | has($e.key)) | not) | {key: $e.key, value: false}) | from_entries) as $unknown
  | ($unknown + $tmpl + $local)
')

# Report: specs the reconcile flips from live-`true` to `false` — the actual
# drift being cleared. (A template `false` for a spec that was absent/already
# off is written to the floor but is NOT drift, so it is not reported.)
DISABLED=$(jq -rn --argjson b "$LIVE_EP" --argjson a "$NEW_EP" '
  [ $a | to_entries[] | select(.value == false) | select(($b[.key]) == true) | .key ] | .[]
' || true)
# Specs kept enabled (the surviving lean floor).
KEPT=$(jq -rn --argjson a "$NEW_EP" '[ $a | to_entries[] | select(.value == true) | .key ] | length')

echo "==> plugin-set reconcile ($SETTINGS)"
echo "    lean floor: $KEPT plugin(s) enabled."
if [[ -n "$DISABLED" ]]; then
  echo "    forcing OFF (drift cleared):"
  while IFS= read -r k; do [[ -n "$k" ]] && echo "      - $k"; done <<< "$DISABLED"
else
  echo "    no drift — already at the lean floor."
fi

if [[ "$LIVE_EP" == "$NEW_EP" ]]; then
  echo "    settings unchanged."
  exit 0
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "    DRY: would write reconciled enabledPlugins to $SETTINGS"
  exit 0
fi

# Preserve the target's mode: seed the temp file as a perms-preserving copy of
# $SETTINGS (cp -p) so the truncate-write keeps that mode and the mv can't
# downgrade a restrictive settings file (e.g. 0600) to the umask default. cp -p
# is best-effort — a filesystem without perm bits (Windows) falls back to plain
# cp, harmless there.
TMP="$SETTINGS.reconcile.tmp"
cp -p "$SETTINGS" "$TMP" 2>/dev/null || cp "$SETTINGS" "$TMP"
# if/else (not `&& mv`): a bare `jq ... && mv` trips set -e on a jq failure and
# aborts before cleanup; mirror install-plugins.sh's tolerant temp+move.
if jq --argjson ep "$NEW_EP" '.enabledPlugins = $ep' "$SETTINGS" > "$TMP"; then
  mv "$TMP" "$SETTINGS"
  echo "    reconciled: enabledPlugins written to $SETTINGS"
else
  rm -f "$TMP"
  echo "reconcile-enabled-plugins: jq patch failed — $SETTINGS left unchanged" >&2
  exit 1
fi
