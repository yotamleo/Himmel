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
# PLATFORM GUARD: no .ps1 twin, by design -- Linux-only, reads pgrep the
# same way tick.sh does. Bash 3.2-compatible; no associative arrays or
# mapfile.
#
# Verdict rule, per live `-n <name>` claude session:
#   - a leg (the process line contains -leg and the -n name does not end
#     -console) must carry --autocompact 200000; anything else is DRIFT.
#   - a console (-n name ends -console) is exempt -- 1m/auto is its design.
#   - anything else (an operator relaunch, any other -n name) is DRIFT if
#     its ceiling is auto or unset.
# A process with no -n token is not a tracked session and is skipped.
#
# Output: one `<name> <ceiling>` line per tracked session, then a last line
# of `ceiling=ok` or `ceiling=DRIFT:<name1>,<name2>`. Exit 0 either way --
# this is a report, not a gate.
set -u

proc_out="$(pgrep -af 'claude' 2>/dev/null)"
pgrep_rc=$?
# pgrep rc=1 means "no processes matched" -- a legitimate empty table, still
# ceiling=ok. Any other nonzero rc (bad invocation, permission, OOM) means the
# scan itself failed, and reporting ceiling=ok on top of that would silently
# mask exactly the drift this script exists to catch (HIMMEL-2974 round 1).
if [ "$pgrep_rc" -gt 1 ]; then
    echo "ceiling=?"
    exit 0
fi

printf '%s\n' "$proc_out" | awk '
/claude / && / -n [^ ]+/ {
    name = ""
    ceiling = "unset"
    for (i = 1; i <= NF; i++) {
        if ($i == "-n" && (i + 1) <= NF) name = $(i + 1)
        if ($i == "--autocompact" && (i + 1) <= NF) ceiling = $(i + 1)
    }
    if (name == "") next

    is_console = (name ~ /-console$/)
    is_leg = ($0 ~ /-leg/) && !is_console

    if (is_leg)          { drift = (ceiling != "200000") }
    else if (is_console) { drift = 0 }
    else                 { drift = (ceiling == "auto" || ceiling == "unset") }

    print name, ceiling
    if (drift) drifted = drifted (drifted == "" ? "" : ",") name
}
END {
    if (drifted == "") print "ceiling=ok"
    else print "ceiling=DRIFT:" drifted
}'
exit 0
