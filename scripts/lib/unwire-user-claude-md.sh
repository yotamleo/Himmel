#!/usr/bin/env bash
# unwire-user-claude-md.sh -- strip himmel's "working principles" block from a
# user-scope rule file (the inverse of wire_user_claude_md in user-claude-md.sh;
# HIMMEL-3251). Installed once per harness: ~/.claude/CLAUDE.md and
# ~/.codex/AGENTS.md.
#
# Usage:
#   bash unwire-user-claude-md.sh <rule-file-path> [dry_run]
#
# Removes ONLY the marker range (the exact BEGIN line through the exact END
# line) plus the one blank line install put in front of it when it appended to
# an existing file. Every other byte is left as it was. A file that then holds
# nothing at all is the file install created, and is removed.
#
# Exit codes: 0 = block removed, or there was none (no marker, no file);
# 1 = the markers are not exactly one BEGIN followed by one END -- the file is
# left untouched, because guessing which range is himmel's would eat the
# operator's own text -- OR a temp-file / write / remove step failed (disk full,
# read-only target); a failed write-through can leave the target truncated,
# since it is written in place to keep a symlink and the mode (ponytail: no
# atomic rename) -- the stripped content is then kept in the temp file the
# error names, never deleted; 2 = wrong argument count. Source it to call
# unwire_user_claude_md directly.
set -euo pipefail

_UNWIRE_UCM_MARKER="HIMMEL:working-principles"

unwire_user_claude_md() {
  local target="$1" dry="${2:-0}"
  local begin="<!-- BEGIN ${_UNWIRE_UCM_MARKER} -->" end="<!-- END ${_UNWIRE_UCM_MARKER} -->"
  local nb ne lb le start tmp
  if [ ! -f "$target" ]; then
    echo "  no $target -- nothing to strip"
    return 0
  fi
  nb=$(grep -cxF -- "$begin" "$target" || true)
  ne=$(grep -cxF -- "$end" "$target" || true)
  if [ "$nb" -eq 0 ] && [ "$ne" -eq 0 ]; then
    echo "  no himmel working-principles block in $target -- nothing to strip"
    return 0
  fi
  lb=$(grep -nxF -- "$begin" "$target" | head -n 1 | cut -d: -f1 || true)
  le=$(grep -nxF -- "$end" "$target" | head -n 1 | cut -d: -f1 || true)
  if [ "$nb" -ne 1 ] || [ "$ne" -ne 1 ] || [ "$lb" -gt "$le" ]; then
    echo "unwire-user-claude-md: $target has $nb BEGIN and $ne END markers (want exactly one BEGIN then one END) -- refusing to guess; remove the block by hand" >&2
    return 1
  fi
  if [ "$dry" = "1" ]; then
    echo "DRY: would strip himmel working-principles block from $target"
    return 0
  fi
  # The blank line before BEGIN is install's only when it is really empty; a
  # text line there is the operator's own (file lacked a trailing newline).
  start="$lb"
  if [ "$lb" -gt 1 ] && [ -z "$(sed -n "$((lb - 1))p" "$target")" ]; then start=$((lb - 1)); fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/unwire-ucm.XXXXXX") || return 1
  { head -n $((start - 1)) "$target"; tail -n +$((le + 1)) "$target"; } > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ ! -s "$tmp" ] && [ ! -L "$target" ]; then
    rm -f "$tmp"
    rm -f -- "$target" || return 1
    echo "  stripped working-principles block; removed $target (it held nothing else)"
    return 0
  fi
  # Write THROUGH the path (not mv over it): a dotfile manager's symlink and the
  # file's mode survive.
  # A failed write can leave $target truncated, so on failure $tmp -- the file
  # minus himmel's block, i.e. all of the operator's text -- is KEPT and named.
  if ! cat "$tmp" > "$target"; then
    echo "unwire-user-claude-md: could not write $target -- the stripped content is preserved at $tmp; copy it over $target by hand" >&2
    return 1
  fi
  rm -f "$tmp"
  echo "  stripped working-principles block from $target"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: unwire-user-claude-md.sh <rule-file-path> [dry_run]" >&2
    exit 2
  fi
  unwire_user_claude_md "$@"
fi
