#!/usr/bin/env bash
# scripts/handover/console-kit/residual-lines.sh - sourced by write-verdict.sh,
# verdict-go.sh and leg-event.sh: the one definition of an unfiled residual, so
# a deferred item cannot live only as verdict or wrap prose. Each function
# prints the offending lines (CR stripped), nothing when all are filed.
#
#   unfiled_residual_section_lines <file>   evidence file: a bullet under a
#       Non-blocking / Follow-ups / Residuals heading, or a `residual:` line
#   unfiled_residual_mention_lines <file>   wrap message: any line that
#       mentions deferred / follow-up / residual
#
# A line is filed when it carries a HIMMEL-<n> key or `no-ticket: <reason>`.
# A mention that is negated within one word ("no residuals", "nothing
# deferred") is not a residual.
#
# Platform guard: POSIX awk, bash 3.2+.

unfiled_residual_section_lines() {
    awk '
    { sub(/\r$/, "") }
    function lead(s) { gsub(/^[ \t]*(#+[ \t]+)?(\*\*)?/, "", s); gsub(/(\*\*)?[ \t]*:?(\*\*)?[ \t]*$/, "", s); return tolower(s) }
    tolower($0) ~ /^[ \t]*([-*+][ \t]+)?residuals?:[ \t]*[^ \t]/ {
        if ($0 !~ /HIMMEL-[0-9]+/ && $0 !~ /no-ticket:[ \t]*[^ \t]/) print
        next
    }
    /^#+[ \t]/ || /^\*\*.*\*\*:?[ \t]*$/ || /^[A-Za-z-]+:[ \t]*$/ {
        l = lead($0); sec = (l ~ /^(non-blocking|follow-ups?|residuals?)$/); items = 0; next
    }
    sec && /^[ \t]*$/ { next }
    sec && /^[ \t]*([-*+]|[0-9]+[.)])[ \t]+/ {
        items = 1
        if ($0 !~ /HIMMEL-[0-9]+/ && $0 !~ /no-ticket:[ \t]*[^ \t]/) print
        next
    }
    sec && items && /^[^ \t]/ { sec = 0 }' "$1"
}

unfiled_residual_mention_lines() {
    awk '
    { sub(/\r$/, "") }
    {
        l = tolower($0)
        gsub(/(^|[^a-z])(no|none|nothing|zero)[ \t]+((further|more|other|remaining|open|outstanding|known|new)[ \t]+)?(deferred|follow-?ups?|residuals?)([ \t,]+(or|and)[ \t]+(deferred|follow-?ups?|residuals?))*/, " ", l)
    }
    l ~ /(deferred|follow-?ups?|residuals?)/ {
        if ($0 !~ /HIMMEL-[0-9]+/ && $0 !~ /no-ticket:[ \t]*[^ \t]/) print
    }' "$1"
}
