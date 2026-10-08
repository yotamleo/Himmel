#!/usr/bin/env bash
# memory-line-check.sh — the ONE definition of the MEMORY.md routing-line length
# rule (HIMMEL-4891). Shared by guard-memory-capture.sh (Write/Edit payloads)
# and memory-bash-line-check.sh (Bash writes, checked on the file afterwards).
#
# Usage: <text on stdin> | bash memory-line-check.sh
# Reads MEMORY_LINE_MAX (default 200). Prints the number of every `- ` pointer
# line longer than the limit, one per line; exit 1 if any, else 0.
#
# Char count, not byte count: under the pinned C locale `length()` is bytes and
# a UTF-8 char is 1 lead byte + N continuation bytes (\200-\277), so dropping
# the continuation bytes leaves exactly the character count (HIMMEL-2011). CRLF
# is stripped first so a CRLF index does not read 1 char longer.
export LC_ALL=C
exec awk -v m="${MEMORY_LINE_MAX:-200}" '
    { sub(/\r$/, "") }
    /^- / {
        s = $0; gsub(/[\200-\277]/, "", s)
        if (length(s) > m) { print NR; bad = 1 }
    }
    END { exit bad }'
