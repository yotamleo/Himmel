#!/usr/bin/env bash
# unwire-user-claude-md.sh -- strip himmel's "working principles" block from a
# user-scope rule file (the inverse of wire_user_claude_md in user-claude-md.sh;
# HIMMEL-3251). Installed once per harness: ~/.claude/CLAUDE.md and
# ~/.codex/AGENTS.md.
#
# Usage:
#   bash unwire-user-claude-md.sh <rule-file-path> [dry_run]
#   bash unwire-user-claude-md.sh --probe <rule-file-path>
#
# Removes ONLY the marker range (the exact BEGIN line through the exact END
# line) plus the one blank line install put in front of it when it appended to
# an existing file. Every other byte is left as it was; the file's own line
# endings and trailing-newline state are never "fixed". Before the file is
# edited, a copy of it as found goes to <file>.himmel-uninstall-backup (the
# error and DRY lines name it), so a surprise can be undone by hand.
#
# The empty case is DECIDED, not emergent (HIMMEL-3333). wire_user_claude_md
# writes the block alone into a file it creates, and a blank line + the block
# when it appends to a file that already existed, so the blank line is the
# provenance record install left us:
#   - nothing left AND no blank line before BEGIN -> install created this
#     file; it is removed (a 0-byte config and no config read the same to
#     Claude Code and Codex, and the file was never the operator's).
#   - nothing left BUT install's blank line was there -> the operator had an
#     empty file before install; it is given back EMPTY, never deleted.
#   - anything else left -> written back exactly, be it whitespace or text.
#   - a symlink is never deleted (a dotfile manager owns the link); its target
#     is written through, empty if that is what remains.
#
# Marker lines are matched whole (no substring hits on prose) and OUTSIDE fenced
# code blocks only: a file ABOUT himmel that quotes the block inside ``` or ~~~
# is not wired and is left alone. A marker line found with a CRLF ending (an
# editor converted the file; himmel writes LF), a fence that never closes above
# a marker, or any count but exactly one BEGIN followed by one END is REFUSED:
# the file is left untouched and the message says what was found and to remove
# the block by hand. Guessing which range is himmel's would eat the operator's
# own text, and that loss is silent and unrecoverable for them.
#
# Exit codes: 0 = block removed, or there was none (no marker, no file);
# 1 = refused (malformed markers, CRLF markers, open fence), OR the file cannot
# be read, OR the backup / temp-file / write / remove step failed (disk full,
# read-only target); a failed write-through can leave the target truncated,
# since it is written in place to keep a symlink and the mode (ponytail: no
# atomic rename) -- the stripped content is then kept in the temp file the
# error names and the pre-edit copy sits in the backup, neither deleted;
# 2 = wrong argument count.
# --probe: 0 = no himmel marker line outside a fence (nothing wired);
# 3 = at least one marker line (a block, a fragment, or a CRLF one) is present;
# 1 = unreadable. Read by uninstall.sh's read-back, which must agree with the
# strip about what counts as a marker or a documented block trips it.
# Source it to call unwire_user_claude_md directly.
set -euo pipefail

_UNWIRE_UCM_MARKER="HIMMEL:working-principles"

# _ucm_scan <file> -- one awk pass; prints "nb ne lb le crlf openfence fm":
# nb/ne = exact BEGIN/END lines outside fenced code, lb/le = line of the first
# of each (0 = none), crlf = marker lines carrying a trailing CR, openfence = 1
# when a fence is still open at EOF, fm = marker lines inside THAT unclosed fence
# (reset when a fence closes, so an earlier balanced quote does not count: a
# real block below an unclosed fence looks quoted, and reading it as "nothing
# to strip" would leave the operator silently wired).
# rc 2 when the file cannot be read.
# Fences follow CommonMark far enough for a rule file: up to three leading
# spaces, three or more of the same backtick/tilde, closed by a run of the same
# char at least as long with nothing but whitespace after it; a backtick
# opener's info string may not itself contain a backtick (inline code).
_ucm_scan() {
  awk -v b="<!-- BEGIN ${_UNWIRE_UCM_MARKER} -->" -v e="<!-- END ${_UNWIRE_UCM_MARKER} -->" '
    BEGIN { nb = 0; ne = 0; lb = 0; le = 0; crlf = 0; fm = 0; fc = ""; fl = 0 }
    {
      if (match($0, /^ ? ? ?(```+|~~~+)/)) {
        run = substr($0, RSTART, RLENGTH); sub(/^ */, "", run)
        ch = substr(run, 1, 1); n = length(run); rest = substr($0, RSTART + RLENGTH)
        if (fc == "") { if (ch == "~" || rest !~ /`/) { fc = ch; fl = n; next } }
        else if (ch == fc && n >= fl && rest ~ /^[ \t\r]*$/) { fc = ""; fl = 0; fm = 0; next }
      }
      if (fc != "") { if ($0 == b || $0 == e || $0 == b "\r" || $0 == e "\r") fm++; next }
      if ($0 == b) { nb++; if (!lb) lb = NR; next }
      if ($0 == e) { ne++; if (!le) le = NR; next }
      if ($0 == b "\r" || $0 == e "\r") crlf++
    }
    END { printf "%d %d %d %d %d %d %d\n", nb, ne, lb, le, crlf, (fc != ""), fm }
  ' "$1"
}

unwire_ucm_probe() {
  local target="$1" scan nb ne lb le crlf openfence fm
  [ -f "$target" ] || return 0
  scan=$(_ucm_scan "$target" 2>/dev/null) || return 1
  read -r nb ne lb le crlf openfence fm <<< "$scan"
  [ "$openfence" -eq 1 ] || fm=0
  [ "$((nb + ne + crlf + fm))" -eq 0 ] || return 3
  return 0
}

unwire_user_claude_md() {
  local target="$1" dry="${2:-0}"
  local scan nb ne lb le crlf openfence fm start tmp backup
  if [ ! -f "$target" ]; then
    echo "  no $target -- nothing to strip"
    return 0
  fi
  backup="$target.himmel-uninstall-backup"
  # awk exits 2 on a read failure: an unreadable file must fail, not read as
  # "no block".
  if ! scan=$(_ucm_scan "$target" 2>/dev/null); then
    echo "unwire-user-claude-md: cannot read $target -- left untouched" >&2
    return 1
  fi
  read -r nb ne lb le crlf openfence fm <<< "$scan"
  # A marker under a fence that never closes may be the real block: refuse
  # before it can read as "nothing to strip". Balanced fences make fm moot.
  if [ "$openfence" -eq 1 ] && [ "$((nb + ne + crlf + fm))" -gt 0 ]; then
    echo "unwire-user-claude-md: $target opens a code fence that never closes, so a marker line cannot be told from quoted text -- refusing to guess; close the fence or remove the block by hand" >&2
    return 1
  fi
  if [ "$crlf" -gt 0 ]; then
    echo "unwire-user-claude-md: $target carries himmel marker lines with CRLF line endings (himmel writes LF; an editor converted the file) -- refusing to edit a file whose bytes are not the ones install wrote; remove the block by hand, or convert the file back to LF and re-run" >&2
    return 1
  fi
  if [ "$nb" -eq 0 ] && [ "$ne" -eq 0 ]; then
    echo "  no himmel working-principles block in $target -- nothing to strip"
    return 0
  fi
  if [ "$nb" -ne 1 ] || [ "$ne" -ne 1 ] || [ "$lb" -gt "$le" ]; then
    echo "unwire-user-claude-md: $target has $nb BEGIN and $ne END markers$( [ "$nb" -eq 1 ] && [ "$ne" -eq 1 ] && printf ' with END above BEGIN' ) (want exactly one BEGIN then one END) -- refusing to guess; remove the block by hand" >&2
    return 1
  fi
  if [ "$dry" = "1" ]; then
    echo "DRY: would strip himmel working-principles block from $target (a copy of the file as found goes to $backup first, unless the file held nothing else)"
    return 0
  fi
  # The blank line before BEGIN is install's only when it is really empty; a
  # text line there is the operator's own (file lacked a trailing newline).
  start="$lb"
  if [ "$lb" -gt 1 ] && [ -z "$(sed -n "$((lb - 1))p" "$target")" ]; then start=$((lb - 1)); fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/unwire-ucm.XXXXXX") || return 1
  # && not ;: a group's status is its LAST command's, so a failed head must not
  # hide behind a succeeding tail and pass a short temp file off as the result.
  { head -n $((start - 1)) "$target" && tail -n +$((le + 1)) "$target"; } > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ ! -s "$tmp" ] && [ ! -L "$target" ] && [ "$start" -eq "$lb" ]; then
    # No blank line before BEGIN: install CREATED this file (see header). It
    # held nothing of the operator's, so there is nothing to back up.
    rm -f "$tmp"
    rm -f -- "$target" || return 1
    echo "  stripped working-principles block; removed $target (install created it and it held nothing else)"
    return 0
  fi
  # Everything from here edits a file the operator had: copy it as found first.
  if ! cp -p -- "$target" "$backup"; then
    rm -f "$tmp"
    echo "unwire-user-claude-md: could not write the backup $backup -- $target left untouched" >&2
    return 1
  fi
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    # Install appended to an EMPTY file (its blank line was there), or the
    # target is a symlink: give the operator back an empty file, never delete.
    : > "$target" || { echo "unwire-user-claude-md: could not write $target -- the file as found is preserved at $backup" >&2; return 1; }
    echo "  stripped working-principles block; $target is empty again, as it was before install appended the block (backup: $backup)"
    return 0
  fi
  # Write THROUGH the path (not mv over it): a dotfile manager's symlink and the
  # file's mode survive.
  # A failed write can leave $target truncated, so on failure $tmp -- the file
  # minus himmel's block, i.e. all of the operator's text -- is KEPT and named.
  if ! cat "$tmp" > "$target"; then
    echo "unwire-user-claude-md: could not write $target -- the stripped content is preserved at $tmp and the file as found at $backup; copy one over $target by hand" >&2
    return 1
  fi
  rm -f "$tmp"
  echo "  stripped working-principles block from $target (backup: $backup)"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "${1:-}" = "--probe" ]; then
    if [ "$#" -ne 2 ]; then
      echo "usage: unwire-user-claude-md.sh --probe <rule-file-path>" >&2
      exit 2
    fi
    unwire_ucm_probe "$2"
    exit $?
  fi
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: unwire-user-claude-md.sh <rule-file-path> [dry_run]" >&2
    exit 2
  fi
  unwire_user_claude_md "$@"
fi
