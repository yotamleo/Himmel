#!/usr/bin/env bash
# scripts/lanes/ceiling-conformance.sh - HIMMEL-2974: does every live claude
# session carry the --autocompact ceiling its kind requires?
#
# WHY. A leg that loses --autocompact 200000 silently runs the 1m window at
# ~250k context/turn (the cost audit that opened this ticket) instead of
# refusing at launch (headed-arm.sh:391 makes the leg invariant explicit;
# this script is the runtime-side check that nothing already running has
# drifted from it). A console is exempt by design (HIMMEL-2658: 1m/auto is
# the console's own context tier, not a leak).
#
# PLATFORM GUARD: no .ps1 twin, by design -- Linux-only, reads real argv the
# same way tick.sh does. Bash 3.2-compatible; no associative arrays or
# mapfile.
#
# Verdict rule, per live `-n <name>` claude session:
#   - a leg (the real -n name contains -leg and does not end -console) must
#     carry --autocompact 200000; anything else is DRIFT.
#   - a console (-n name ends -console) is exempt -- 1m/auto is its design.
#   - anything else (an operator relaunch, any other -n name) is DRIFT if
#     its ceiling is auto or unset.
# A process with no -n token is not a tracked session and is skipped.
#
# HIMMEL-2999: name/model/ceiling come from claude_sessions() (real
# /proc/<pid>/cmdline argv, NUL-delimited), never a flattened `pgrep -af`
# line -- free-text argv (a -p/--append-system-prompt value containing the
# literal substring "-n X" or "--autocompact 200000") can no longer spoof
# the detected name or ceiling.
#
# Output: one `<name> <ceiling>` line per tracked session, then a last line
# of `ceiling=ok` or `ceiling=DRIFT:<name1>,<name2>`. HIMMEL-3002: if any live
# session had an unreadable cmdline, an extra `scan-degraded:<pid1>,<pid2>`
# line precedes a final `ceiling=?` -- an incomplete scan cannot certify
# ok/DRIFT over the sessions it never got to read. Exit 0 in every case --
# this is a report, not a gate.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/claude-sessions.sh
. "$HERE/lib/claude-sessions.sh"

sessions_out="$(claude_sessions)"
sessions_rc=$?
# claude_sessions() rc>1 means the underlying pgrep scan itself failed (bad
# invocation, permission, OOM), not "no processes matched" (rc<=1, a
# legitimate empty table, still ceiling=ok). Reporting ceiling=ok on top of a
# failed scan would silently mask exactly the drift this script exists to
# catch (HIMMEL-2974 round 1). rc=3 is ambiguous by itself (HIMMEL-3002):
# pgrep's own documented fatal-error rc is ALSO 3, forwarded verbatim and
# printing nothing first, whereas a genuine degraded scan (an unreadable
# cmdline) always echoes at least one row/comment before returning 3 -- so
# empty output at rc=3 means pgrep itself failed, not a degraded census.
if [ "$sessions_rc" -gt 1 ] && { [ "$sessions_rc" -ne 3 ] || [ -z "$sessions_out" ]; }; then
    echo "ceiling=?"
    exit 0
fi

printf '%s\n' "$sessions_out" | awk -F'\t' '
$1 ~ /^# unreadable / {
    pid = $1
    sub(/^# unreadable /, "", pid)
    degraded = degraded (degraded == "" ? "" : ",") pid
    next
}
$1 ~ /^#/ { next }
NF < 4 { next }
{
    name = $2
    if (name == "") next
    ceiling = $4
    if (ceiling == "") ceiling = "unset"

    is_console = (name ~ /-console$/)
    is_leg = (name ~ /-leg/) && !is_console

    if (is_leg)          { drift = (ceiling != "200000") }
    else if (is_console) { drift = 0 }
    else                 { drift = (ceiling == "auto" || ceiling == "unset") }

    print name, ceiling
    if (drift) drifted = drifted (drifted == "" ? "" : ",") name
}
END {
    # HIMMEL-3002: an incomplete scan cannot certify conformance -- report
    # which pids it could not judge and fall back to the same "cannot tell"
    # summary the pgrep-failure path above already uses, instead of ok/DRIFT
    # over a partial table.
    if (degraded != "") {
        print "scan-degraded:" degraded
        print "ceiling=?"
    } else if (drifted == "") {
        print "ceiling=ok"
    } else {
        print "ceiling=DRIFT:" drifted
    }
}'
exit 0
