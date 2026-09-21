#!/usr/bin/env bash
# claude-config-dir.sh — the Claude Code config dir, resolved the way the HUD's
# own getClaudeConfigDir() does (marketplace/plugins/claude-hud/src/claude-config-dir.ts).
# Sourced, never run. Shared by wire-statusline.sh and the other settings.json
# recorders (wire-himmel-repo/-luna-vault/-handover-dir, wire-pretooluse-hooks)
# so a leading `~` in CLAUDE_CONFIG_DIR is expanded in ONE place (HIMMEL-3352).
#
# claude_config_dir — print the directory: CLAUDE_CONFIG_DIR wins, with a leading
# `~` expanded; otherwise $HOME/.claude.
#
# The value is TRIMMED first, exactly as the consumer does
# (`process.env.CLAUDE_CONFIG_DIR?.trim()`), and a whitespace-only value is
# therefore treated as UNSET. Without the trim the two disagree: the installer
# would write the hud config under a padded — i.e. different — directory from
# the one the hud reads it back from, and a whitespace-only value would make
# bash resolve a RELATIVE directory literally named with spaces. The
# PowerShell twin already had this via IsNullOrWhiteSpace.
claude_config_dir() {
  local d="${CLAUDE_CONFIG_DIR:-}"
  # Strip leading and trailing whitespace (bash 3.2-safe: no ${var@Q}, no =~).
  d="${d#"${d%%[![:space:]]*}"}"
  d="${d%"${d##*[![:space:]]}"}"
  if [ -z "$d" ]; then
    printf '%s\n' "$HOME/.claude"
    return 0
  fi
  # shellcheck disable=SC2088  # matching/stripping a literal '~/' prefix, not expanding one
  case "$d" in
    '~') d="$HOME" ;;
    '~/'*) d="$HOME/${d#\~/}" ;;
  esac
  printf '%s\n' "$d"
}
