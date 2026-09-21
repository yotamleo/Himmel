#!/usr/bin/env bash
# memory-index-state-notice.sh — SessionStart hook: report when the auto-memory
# index MEMORY.md violates the form rules guard-memory-capture.sh enforces
# (HIMMEL-3314).
#
# WHY A STATE CHECK. guard-memory-capture.sh is a PreToolUse guard on
# Edit|Write|MultiEdit|NotebookEdit: it inspects a proposed Write/Edit PAYLOAD.
# Auto-mode tells agents to make file changes with sed, heredocs or short
# scripts, so the default way of working never reaches it — MEMORY.md grew from
# 74 to 134 pointer lines against a ceiling of 60 while the guard logged
# line-ceiling DENIES for the writes it could see. A Bash command line is opaque
# (a heredoc, a `sed -i`, a script that writes three calls later), so gating
# Bash would be leaky and noisy. The invariant is about the FILE, not about how
# it was written, so this reads the file.
#
# WHY SESSIONSTART. That is the moment the harm lands: the always-loaded index
# is cut at load, so an over-long index silently drops its NEWEST routing lines
# in every session. Reporting there costs one file read per session and reaches
# the next session after the write, whichever tool made it.
#
# WHAT IT IS NOT. An advisory: it DETECTS and REPORTS the violated invariant, it
# does not prevent the write and does not repair the file. The PreToolUse guard
# stays as the earlier, preventive layer where it applies. Residual gap: a
# non-Write/Edit writer is still free to break the ceiling within a session; it
# is caught at the next session start, not at the write.
#
# SILENT ON THE HEALTHY PATH — every line a SessionStart hook emits is paid for
# in every session forever. Output only when a rule is broken.
#
# FAILS OPEN, ALWAYS. This runs on every session on the machine, including
# consoles and legs; a memory advisory that could block a session from
# starting would be a far worse failure than the ceiling being exceeded. No
# `set -e`, every step is guarded, and the only exit is 0. A missing or
# unreadable MEMORY.md, no git, no awk, a garbage env knob: silent, session
# starts. (Contrast the guard, which fails closed because it is a fence.)
#
# CHEAP. One `git rev-parse` (skipped when MEMDIR is set) and one awk pass over
# at most the first 256 KiB of MEMORY.md. It never walks the memory tree.
#
# Same rules, same knobs, same defaults as the guard: MEMORY_LINE_CEIL (60),
# MEMORY_LINE_MAX (200). Whole-file, not diff-scoped like the guard: a state
# report about a legacy over-length line SHOULD keep ringing until the file is
# fixed — that is the point, and it fires nothing but text.
#
# MEMDIR override (also the test seam) mirrors scripts/memory/audit-memory-capture.sh.
set -uo pipefail
export LC_ALL=C   # byte locale; chars are counted explicitly below (see the guard)

LINE_MAX="${MEMORY_LINE_MAX:-200}"
LINE_CEIL="${MEMORY_LINE_CEIL:-60}"
case "$LINE_MAX$LINE_CEIL" in ''|*[!0-9]*) exit 0 ;; esac  # garbage knob: stay silent, never fail
# All-digit is not enough: `[ "$n" -gt "$LINE_CEIL" ]` below prints "integer
# expected" to stderr past the shell's integer range. Clamp — a ceiling that
# large is "never exceeded" — so the healthy path stays silent on stderr too.
[ "${#LINE_CEIL}" -le 9 ] || LINE_CEIL=999999999

if [ -z "${MEMDIR:-}" ]; then
    # Memory lives under the PRIMARY checkout's project slug, not a worktree's:
    # --git-common-dir points every worktree back at the shared .git dir.
    gcd="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
    [ -n "$gcd" ] || exit 0
    slug="$(printf '%s' "$(dirname "$gcd")" | sed 's/[^A-Za-z0-9]/-/g')"
    MEMDIR="${HOME:-}/.claude/projects/$slug/memory"
fi
idx="$MEMDIR/MEMORY.md"
[ -f "$idx" ] && [ -r "$idx" ] || exit 0

# `- ` pointer lines, exactly the guard's definition; CRLF stripped first so a
# CRLF index does not read 1 char longer; continuation bytes dropped so the
# length is characters, not bytes. Prints: <pointers> <n-too-long> <first line numbers…>
res="$(head -c 262144 "$idx" 2>/dev/null | awk -v m="$LINE_MAX" '
    { sub(/\r$/, "") }
    /^- / {
        n++
        s = $0; gsub(/[\200-\277]/, "", s)
        if (length(s) > m) { k++; if (k <= 5) l = l " " NR }
    }
    END { print n + 0, k + 0 l }' 2>/dev/null)" || exit 0
[ -n "$res" ] || exit 0
# shellcheck disable=SC2086  # word-splitting the three awk fields is the point
set -- $res
n="${1:-0}"; k="${2:-0}"; shift 2 2>/dev/null || true
lines="$*"
case "$n$k" in ''|*[!0-9]*) exit 0 ;; esac

over_ceil=0; [ "$n" -gt "$LINE_CEIL" ] && over_ceil=1
[ "$over_ceil" -eq 1 ] || [ "$k" -gt 0 ] || exit 0

printf '<system-reminder>\n'
printf 'MEMORY.md (the always-loaded auto-memory index) violates its form rules (HIMMEL-3314 state check):\n'
if [ "$over_ceil" -eq 1 ]; then
    printf -- '- line-ceiling: %s pointer lines (ceiling %s). An over-long index is cut at session load, so its NEWEST routing lines are silently dropped.\n' "$n" "$LINE_CEIL"
fi
if [ "$k" -gt 0 ]; then
    printf -- '- line-too-long: %s pointer line(s) exceed %s chars (line%s %s).\n' "$k" "$LINE_MAX" "$([ "$k" -gt 1 ] && printf s)" "$lines"
fi
printf '\nfile: %s\n' "$idx"
printf 'guard-memory-capture.sh only sees Write/Edit; a heredoc, sed or script write reaches the file unseen, so this reads the file itself.\n'
printf 'Tell the operator in your first reply. Do NOT append more lines; evict facts to their theme topic files (himmel-ops:memory-compound).\n'
printf '</system-reminder>\n'
exit 0
