#!/usr/bin/env bash
# unwire-pretooluse-hooks.sh -- remove himmel's UNIVERSAL hooks from a Claude Code
# settings.json (the inverse of wire-pretooluse-hooks.sh). Used by:
#   - uninstall.sh [6/6] to tear down user-scope wiring (install/uninstall symmetry),
#   - R4 duplication remediation: `--scope project --target <repo>` removes the
#     redundant project-scope copy when a project ALSO has user-scope wiring.
#
# Removes ONLY the UNIVERSAL himmel hooks (by BASENAME) -- preserving every
# non-himmel hook and the HIMMEL-DEV-ONLY hooks (check-cr-marker, block-backend-tier,
# auto-arm, check-update-available, ...):
#   PreToolUse: auto-approve-safe-bash, block-edit-on-main, block-read-secrets
#               (drop the hook object; prune a stanza only when it becomes empty)
#   SessionStart: inject-initiative (splice out the hook OBJECT; prune the wrapper
#                 stanza ONLY if its hooks[] becomes empty -- never delete a
#                 sibling like check-update-available.sh, SC12)
#
# Usage:
#   bash unwire-pretooluse-hooks.sh <settings-json-path> [<dry_run>]
#   bash unwire-pretooluse-hooks.sh --scope project --target <repo> [--dry-run]
#
# Idempotent (absent -> no-op), atomic (temp file + mv), refuses invalid JSON,
# preserves siblings. Requires jq. Source it to call unwire_pretooluse_hooks
# directly, or invoke via bash.
set -euo pipefail

# Regexes (extended) matching the UNIVERSAL hook commands by basename path.
_UNWIRE_PRE_PAT='scripts/hooks/(auto-approve-safe-bash|block-edit-on-main|block-read-secrets)[.]sh'
_UNWIRE_SS_PAT='scripts/hooks/inject-initiative[.]sh'

unwire_pretooluse_hooks() {
  local settings="$1" dry_run="${2:-0}"
  command -v jq >/dev/null 2>&1 || { echo "unwire-pretooluse-hooks: jq required" >&2; return 1; }
  if [ ! -f "$settings" ]; then
    [ "$dry_run" -eq 1 ] && echo "DRY: $settings absent -> no-op"
    return 0
  fi
  local base
  base=$(cat "$settings")
  if [ -z "$(printf '%s' "$base" | tr -d '[:space:]')" ]; then
    [ "$dry_run" -eq 1 ] && echo "DRY: $settings empty -> no-op"
    return 0
  fi
  if ! printf '%s' "$base" | jq -e . >/dev/null 2>&1; then
    echo "unwire-pretooluse-hooks: $settings is not valid JSON -- refusing to modify" >&2
    return 1
  fi
  if [ "$dry_run" -eq 1 ]; then
    echo "DRY: remove UNIVERSAL himmel hooks (PreToolUse trio + SessionStart inject-initiative) from $settings"
    return 0
  fi
  printf '%s' "$base" | jq --arg pre "$_UNWIRE_PRE_PAT" --arg ss "$_UNWIRE_SS_PAT" '
    if (.hooks // {} | has("PreToolUse")) then
      .hooks.PreToolUse = ((.hooks.PreToolUse)
        | map(.hooks = ((.hooks // []) | map(select((.command // "") | test($pre) | not))))
        | map(select((.hooks | length) > 0)))
    else . end
    | if (.hooks // {} | has("SessionStart")) then
        .hooks.SessionStart = ((.hooks.SessionStart)
          | map(.hooks = ((.hooks // []) | map(select((.command // "") | test($ss) | not))))
          | map(select((.hooks | length) > 0)))
      else . end
  ' > "$settings.unwirehooks.tmp" && mv "$settings.unwirehooks.tmp" "$settings"
  echo "  removed UNIVERSAL himmel hooks -> $settings"
}

# Allow both `source` and direct invocation (incl. --scope project --target).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  _settings=""; _scope=""; _target=""; _dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --scope)   _scope="$2"; shift 2 ;;
      --target)  _target="$2"; shift 2 ;;
      --dry-run) _dry=1; shift ;;
      -h|--help) echo "usage: unwire-pretooluse-hooks.sh <settings> [<dry_run>] | --scope project --target <repo> [--dry-run]" >&2; exit 0 ;;
      *)         if [ -z "$_settings" ]; then _settings="$1"; else _dry="$1"; fi; shift ;;
    esac
  done
  if [ "$_scope" = "project" ]; then
    [ -n "$_target" ] || { echo "unwire-pretooluse-hooks: --scope project requires --target <repo>" >&2; exit 2; }
    _settings="$_target/.claude/settings.json"
  fi
  [ -n "$_settings" ] || { echo "usage: unwire-pretooluse-hooks.sh <settings> [<dry_run>] | --scope project --target <repo> [--dry-run]" >&2; exit 2; }
  unwire_pretooluse_hooks "$_settings" "$_dry"
fi
