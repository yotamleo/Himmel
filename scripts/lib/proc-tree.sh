#!/usr/bin/env bash
# scripts/lib/proc-tree.sh -- terminate a background job AND everything it
# spawned, on POSIX and on Git Bash / MSYS (HIMMEL-1338).
#
# WHY: signalling a bare pid reaches the wrapper and nothing else. A shell
# suite that leaves a wedged descendant behind is exactly how OVERLORD8
# accumulated 202 live bash.exe on 2026-07-28 -- the caps fired, the
# grandchildren survived, and the churn slowed every other run on the box.
#
# THE PRIMITIVE: a process GROUP signal (`kill -TERM -<pgid>`). It only works
# if the job HAS its own group, which is why callers MUST spawn under `set -m`
# -- see the USAGE block below for the exact shape. GNU `timeout` does the
# same thing by default; its --foreground flag is documented as the opt-out
# ("in this mode, children of COMMAND will not be timed out").
#
# MEASURED, not assumed (HIMMEL-1338 probe, Git Bash 2.x / Windows 11 26200):
# a three-deep chain bash -> bash -> sleep spawned under `set -m` was fully
# reaped by ONE `kill -TERM -<pgid>`; `ps` confirmed all three shared the
# leader's PGID. The concern carried into this ticket -- that on Git Bash the
# group signal returns 0 while killing nothing (the open Major CR finding on
# HIMMEL-1286 / PR #1428) -- did NOT reproduce for a job spawned this way. It
# is still not TRUSTED: this helper VERIFIES the outcome instead of believing
# the return code, and falls back to Windows `taskkill` for anything that
# survived. An rc of 0 is not evidence; an empty group is.
#
# USAGE (source it, then call):
#   . scripts/lib/proc-tree.sh
#   set -m; some_command & pid=$!; set +m
#   proc_tree_terminate "$pid" [grace-seconds]
#   wait "$pid" 2>/dev/null    # caller reaps; this helper never does
#
# proc_tree_terminate returns 0 when the group is gone by the time it returns
# and 1 when something survived every escalation (a caller that cares can say
# so in its report; there is no further lever to pull).
#
# COVERAGE lives in scripts/ci/test-suite-concurrency.sh (cases 5 and 5b: a
# wedged descendant is reaped, and a TERM-ignoring suite is still killed),
# exercised through the one caller rather than duplicated here. A standalone
# unit suite would have to spawn and reap its own processes a second time, and
# the ticket this helper comes from is about shell suites taking too long.
#
# CONVENTIONS: bash 3.2-safe (no associative arrays, no mapfile). ASCII only,
# because a non-ASCII char on a line a finding lands on crashes the linter --
# same convention as scripts/handover/queue-lock.sh. Note that no comment line
# here may BEGIN with the linter's name either: it parses that as a directive
# and fails the file with SC1073.

# proc_tree_is_windows -- 0 when this is an MSYS/Cygwin bash, where /proc
# exposes the Windows pid of a process and `taskkill` exists as a last resort.
proc_tree_is_windows() {
    [ -r "/proc/$$/winpid" ]
}

# proc_tree_winpid <msys-pid> -- print the Windows pid, or nothing.
proc_tree_winpid() {
    cat "/proc/$1/winpid" 2>/dev/null
}

# proc_tree_group_members <pgid> -- print the pids still in a process group,
# one per line. Prints nothing when the group is empty OR when neither `ps`
# form works -- callers treat "no members" as "cannot see any", which is why
# proc_tree_terminate escalates unconditionally rather than only when it can
# observe a survivor.
#
# NOT `ps -g <pgid>`: POSIX defines -g as select-by-SESSION-leader, and procps
# overloads it with effective-group-name, so it is the wrong axis on Linux and
# ambiguous everywhere. Selecting every process and filtering on an explicit
# pgid= column is unambiguous on Linux and macOS; Git Bash has no -o at all,
# and its bare table (PID PPID PGID WINPID ...) is parsed positionally.
#
# The working form is resolved ONCE. Probing both on every call meant three
# forks per liveness check, and this runs in a grace loop on a box whose
# process table is the reason the caller exists.
# ZOMBIES ARE NOT SURVIVORS. A killed child stays in the process table as a
# defunct entry until its parent waits on it, and our caller waits AFTER this
# helper returns -- so counting a zombie as alive would report a successful
# termination as a failure and send us down the taskkill path for a process
# that is already dead. The posix form therefore selects `stat=` too and drops
# anything in state Z. The Git Bash table form has no state column and cannot
# filter; the cost there is a spurious warning, never a missed kill, and MSYS
# reaps quickly enough that it has not been observed.
_PROC_TREE_PS_MODE=""
proc_tree_group_members() {
    local pgid="$1"
    if [ -z "$_PROC_TREE_PS_MODE" ]; then
        # The probe asks only whether the FORM works: this shell is always in
        # the table, so an empty result means unsupported, not "no processes".
        if [ -n "$(ps -e -o pid=,pgid=,stat= 2>/dev/null)" ]; then
            _PROC_TREE_PS_MODE="posix"
        else
            _PROC_TREE_PS_MODE="table"
        fi
    fi
    if [ "$_PROC_TREE_PS_MODE" = "posix" ]; then
        ps -e -o pid=,pgid=,stat= 2>/dev/null |
            awk -v g="$pgid" '$2==g && $3 !~ /^Z/ { print $1 }'
        return 0
    fi
    ps 2>/dev/null | awk -v g="$pgid" 'NR>1 && $3==g { print $1 }'
}

# proc_tree_group_alive <pgid> -- 0 when at least one process is still in the
# group. Deliberately NOT `kill -0 -<pgid>`: our own not-yet-reaped child is a
# zombie, and a zombie answers signal 0 with success on Linux, so that test
# reports "alive" for a process that has already exited. The process table
# does not have that ambiguity.
proc_tree_group_alive() {
    [ -n "$(proc_tree_group_members "$1")" ]
}

# proc_tree_terminate <pid> [grace-seconds] -- TERM the group, wait out the
# grace period, KILL the group, and only THEN check whether anything is left.
# On Windows a survivor gets one more pass through `taskkill /F` on its
# Windows pid, which does not go through the MSYS signal layer at all.
#
# The escalation is unconditional up to KILL: a group signal that silently
# reached nothing looks identical to one that worked, so "did TERM succeed?"
# is not a question worth asking. KILL cannot be blocked or handled, so
# anything alive after it is a signal-delivery failure, not a stubborn
# process -- which is precisely when the Windows path earns its keep.
proc_tree_terminate() {
    local pid="$1" grace="${2:-3}" survivor w
    [ -n "$pid" ] || return 0

    # Negative pid = the whole group. The bare-pid fallback covers a shell
    # without job control, where killing the wrapper still beats killing
    # nothing.
    kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null

    # Sleep the grace out flat rather than polling it away. Reading the
    # process table costs seconds on a loaded Windows box -- the state this
    # helper exists to clean up -- so polling to maybe save 3s reliably spent
    # 15 or more. The grace is a courtesy window for the suite's own cleanup;
    # nothing downstream needs to know precisely when it stopped needing it.
    sleep "$grace"

    kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    sleep 1

    # ONE table read, after the only signal that cannot be ignored. Anything
    # here is a delivery failure, not a stubborn process.
    proc_tree_group_alive "$pid" || return 0

    if proc_tree_is_windows; then
        for survivor in $(proc_tree_group_members "$pid"); do
            w=$(proc_tree_winpid "$survivor")
            [ -n "$w" ] || continue
            # MSYS_NO_PATHCONV: without it MSYS rewrites the /PID and /F
            # switches into Windows paths and taskkill rejects them.
            MSYS_NO_PATHCONV=1 taskkill /PID "$w" /T /F >/dev/null 2>&1
        done
        sleep 1
        proc_tree_group_alive "$pid" || return 0
    fi

    return 1
}
