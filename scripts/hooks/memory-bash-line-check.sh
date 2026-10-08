#!/usr/bin/env bash
# PostToolUse Bash hook (HIMMEL-4891): re-check the auto-memory MEMORY.md line
# rule after a Bash command that names it.
#
# guard-memory-capture.sh only sees Write/Edit payloads; a heredoc, `sed -i`,
# `tee` or `printf >>` reaches the index unseen, and an over-long routing line
# was only caught a session later by the SessionStart state check (HIMMEL-3314).
# A Bash command line is opaque, so this reads the FILE after the call, with
# the same rule the guard uses (memory-line-check.sh, one definition).
#
# Cheap: exits 0 at once unless the command text names MEMORY.md. A WORKFLOW
# NUDGE, not a fence: it fails open on its own infrastructure errors (no jq,
# unparseable payload, unreadable file). It warns (exit 2 -> stderr reaches the
# model) because PostToolUse cannot undo the write; the remedy is to fix the
# named line in place with the Edit tool, which the PreToolUse guard checks.
#
# Whole-file, not diff-scoped: it names every over-long line, so a legacy line
# keeps ringing until fixed. Bypass: MEMORY_CAPTURE_OK=1 in the launching shell
# (same as the guard).
set -uo pipefail

payload="$(cat)"   # drain stdin before any early exit (no SIGPIPE on the writer)
[ "${MEMORY_CAPTURE_OK:-0}" = "1" ] && exit 0
case "$payload" in *MEMORY.md*) ;; *) exit 0 ;; esac
command -v jq >/dev/null 2>&1 || exit 0
[ "$(printf '%s' "$payload" | jq -r '.tool_name // ""' 2>/dev/null)" = "Bash" ] || exit 0
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)" || exit 0

here="$(cd "$(dirname "$0")" && pwd)"
LINE_MAX="${MEMORY_LINE_MAX:-200}"
bad=""
# Every absolute auto-memory MEMORY.md path the command names (a `~` or `$HOME`
# spelling expands to one in the shell, so only the literal path is matched here
# plus the two common home spellings, resolved below).
# Read line by line (an unquoted $(...) would glob a `*` in the command text) and
# dedupe, so a command naming one path 5000 times checks it once.
paths="$(printf '%s' "$cmd" | grep -oE '[^[:space:]"'"'"'=<>|;&()]*/\.claude/projects/[^[:space:]"'"'"'/]+/memory/MEMORY\.md' | sort -u)"
while IFS= read -r p; do
    [ -n "$p" ] || continue
    # shellcheck disable=SC2088,SC2016  # literal command TEXT, deliberately unexpanded
    case "$p" in
        '~/'*) p="${HOME:-}/${p#\~/}" ;;
        '$HOME/'*) p="${HOME:-}/${p#\$HOME/}" ;;
        '${HOME}/'*) p="${HOME:-}/${p#\$\{HOME\}/}" ;;
    esac
    [ -r "$p" ] || continue
    nums="$(bash "$here/memory-line-check.sh" < "$p" 2>/dev/null)" && continue
    [ -n "$nums" ] || continue
    bad="$bad$p: line $(printf '%s' "$nums" | tr '\n' ' ')
"
done <<EOF
$paths
EOF
[ -n "$bad" ] || exit 0

{
    printf 'MEMORY INDEX LINE TOO LONG (HIMMEL-4891): a Bash write left MEMORY.md with a routing line over %s chars.\n' "$LINE_MAX"
    printf '%s' "$bad"
    printf 'The index routes; it does not store. Move the fact into its theme topic file and shorten the line\n'
    printf 'in place with the Edit tool (guard-memory-capture.sh checks that path). Bypass: MEMORY_CAPTURE_OK=1 in the launching shell.\n'
} >&2
exit 2
