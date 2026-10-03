#!/usr/bin/env bash
# hook-copy-reaper.sh — find (and, opt-in, kill) orphaned hook copies that are
# spinning a core (HIMMEL-4183).
#
# On 2026-10-03, eight copies of a guard hook ran at ~89 % CPU for 4–7 hours
# and pushed load to 150. Judge harnesses had copied the hooks under
# /tmp/claude-<uid>/… and then died. Each copy had been reparented to the
# user subreaper (`systemd --user`), so no session owned it, and doctor C47
# (HIMMEL-3959) missed it: that check matches `hook.sh`, not an arbitrarily
# named copy. This script counts a process when ALL of these hold:
#   * it belongs to the current user, its comm is a shell (bash/sh/dash/zsh)
#     and one of its words is a `.sh` path under /tmp/claude-*/;
#   * it is reparented: its parent is pid 1, or its parent's comm is
#     `systemd` (the user subreaper);
#   * it is older than --min minutes (default 30) and at or above --cpu %
#     (default 50; ps pcpu is the lifetime average).
#
# Output: one `pid=<pid> age=<n>m cpu=<pct> script=<path>` row per copy, then
# `hook-copies=<n>`; `hook-copies=none` when there are none, or
# `hook-copies=?` when the process table cannot be read.
# Exit status: 0 none, 1 found, 2 usage, 3 the process table could not be read.
#
# REPORT-ONLY by default. --kill (opt-in) SIGKILLs each counted copy together
# with its descendants (its looping $(…) subshells are children of it, not
# reparented yet), then prints `killed=<pid,…>`. Only processes that pass
# every test above, or that descend from one, are ever signalled.
# Seam: HOOK_REAPER_KILL (the kill command; default `kill`).
# PLATFORM GUARD: no .ps1 twin, by design. Linux-only (procps ps), like the
# rest of the console kit. Bash 3.2-compatible.
set -uo pipefail

usage() {
    cat <<'USAGE'
usage: hook-copy-reaper.sh [--min MINUTES] [--cpu PERCENT] [--kill]
USAGE
}

min=30
cpu=50
do_kill=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --min|--cpu)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            case "$2" in ''|*[!0-9]*) usage >&2; exit 2 ;; esac
            if [ "$1" = --min ]; then min=$((10#$2)); else cpu=$((10#$2)); fi
            shift 2 ;;
        --kill) do_kill=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

table=$(ps -u "$(id -u)" -o pid=,ppid=,etimes=,pcpu=,comm=,args= 2>/dev/null) || {
    echo 'hook-copies=?'; exit 3
}

# The select logic needs the whole table (a parent's comm, a copy's
# descendants), so it runs as one awk pass. It prints the report rows, then
# one `kill <pid…>` line naming every copy and its descendants.
result=$(printf '%s\n' "$table" | awk -v min="$min" -v cpu="$cpu" '
    $1 ~ /^[0-9]+$/ {
        pid = $1; ppid[pid] = $2; age[pid] = $3; pc[pid] = $4; comm[pid] = $5
        order[++n] = pid
        script[pid] = ""
        for (i = 6; i <= NF; i++)
            if ($i ~ /^\/tmp\/claude-[^\/]*\/.*\.sh$/) { script[pid] = $i; break }
        kids[$2] = kids[$2] " " pid
    }
    function tree(p,    k, m, i) {
        out = out " " p
        m = split(kids[p], k, " ")
        for (i = 1; i <= m; i++) tree(k[i])
    }
    END {
        for (j = 1; j <= n; j++) {
            p = order[j]
            if (comm[p] !~ /^(bash|sh|dash|zsh)$/ || script[p] == "") continue
            if (!(ppid[p] == 1 || comm[ppid[p]] == "systemd")) continue
            if (age[p] < min * 60 || pc[p] + 0 < cpu) continue
            printf "pid=%s age=%dm cpu=%s script=%s\n", p, age[p] / 60, pc[p], script[p]
            tree(p)
        }
        print "kill" out
    }')

rows=$(printf '%s\n' "$result" | sed '$d')
targets=$(printf '%s\n' "$result" | sed -n '$s/^kill *//p')
if [ -z "$rows" ]; then
    echo 'hook-copies=none'
    exit 0
fi
printf '%s\n' "$rows"
echo "hook-copies=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"
if [ "$do_kill" = 1 ]; then
    # shellcheck disable=SC2086  # targets is a list of pids, split on purpose
    "${HOOK_REAPER_KILL:-kill}" -KILL $targets
    echo "killed=$(printf '%s' "$targets" | tr ' ' ',')"
fi
exit 1
