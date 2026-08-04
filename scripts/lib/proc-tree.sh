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
#   proc_tree_terminate "$pid" [grace-seconds] [expected-identity]
#   wait "$pid" 2>/dev/null    # caller reaps; this helper never does
#
# proc_tree_terminate returns 0 when the group is gone by the time it returns,
# 1 when something survived every verified escalation, 2 when a supplied
# expected identity is empty or the probe cannot confirm it either way before
# the next signal, and 3 when the probe CONFIRMS the leader already
# exited/was recycled before any signal was sent (HIMMEL-1501).
# proc_tree_group_terminate is the leader-exited variant: it signals only
# identity-verified observed member pids, never an unowned numeric group id.
#
# COVERAGE lives in scripts/ci/test-suite-concurrency.sh (cases 4b-4e, 5, and
# 5b: empty/recycled identities refuse unsafe signals, leader-exit members are
# revalidated, a wedged descendant is reaped, and a TERM-ignoring suite is still
# killed). The process cases are exercised through
# the one caller rather than duplicated here. A standalone
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

# proc_tree_process_identity <pid> -- print a stable start-time identity for a
# live process. POSIX uses start time + command; Git Bash maps its pid to the
# native Windows pid and reads the full-resolution Get-Process StartTime.
proc_tree_process_identity() {
    local pid="$1" value="" winpid="" pwsh_bin="" candidate
    [ -n "$pid" ] || return 1

    if proc_tree_is_windows; then
        winpid=$(proc_tree_winpid "$pid")
        case "$winpid" in ''|*[!0-9]*) return 1 ;; esac
        for candidate in pwsh pwsh.exe powershell.exe powershell; do
            if command -v "$candidate" >/dev/null 2>&1; then
                pwsh_bin=$candidate
                break
            fi
        done
        [ -n "$pwsh_bin" ] || return 1
        value=$("$pwsh_bin" -NoProfile -NonInteractive -Command "try { (Get-Process -Id $winpid -ErrorAction Stop).StartTime.ToUniversalTime().Ticks } catch { exit 1 }" 2>/dev/null) || value=""
        [ -n "$value" ] || return 1
        printf 'win:%s:%s\n' "$winpid" "$value"
        return 0
    fi

    value=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || value=""
    [ -n "$value" ] || return 1
    printf 'posix:%s\n' "$value"
}

# proc_tree_process_alive <pid> -- 0 when the numeric pid currently names a
# live process. This is deliberately identity-free so callers can distinguish a
# confirmed exit from a live process whose identity no longer matches.
proc_tree_process_alive() {
    local pid="$1"
    [ -n "$pid" ] || return 1
    if proc_tree_is_windows; then
        [ -d "/proc/$pid" ]
    else
        kill -0 "$pid" 2>/dev/null
    fi
}

# proc_tree_process_identity_matches <pid> <identity> -- 0 when the live
# process still has the launch identity, 1 on confirmed mismatch/exit, and 2
# when the identity probe is unavailable. Callers may wait through rc 2, but
# must never signal unless they received rc 0.
proc_tree_process_identity_matches() {
    local pid="$1" expected="$2" actual=""
    [ -n "$expected" ] || return 2
    proc_tree_process_alive "$pid" || return 1
    actual=$(proc_tree_process_identity "$pid") || return 2
    [ "$actual" = "$expected" ]
}

# proc_tree_group_members <pgid> -- print the pids still in a process group,
# one per line. Prints nothing when the group is empty and returns nonzero when
# the process table cannot be read. Existing liveness callers treat either as
# "cannot see any"; snapshot callers inspect the status so an observation
# failure can never become a falsely definitive empty survivor set.
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
    local pgid="$1" table=""
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
        table=$(ps -e -o pid=,pgid=,stat= 2>/dev/null) || return 1
        printf '%s\n' "$table" | awk -v g="$pgid" '$2==g && $3 !~ /^Z/ { print $1 }'
        return 0
    fi
    table=$(ps 2>/dev/null) || return 1
    printf '%s\n' "$table" | awk -v g="$pgid" 'NR>1 && $3==g { print $1 }'
}

# proc_tree_group_alive <pgid> -- 0 when at least one process is still in the
# group. Deliberately NOT `kill -0 -<pgid>`: our own not-yet-reaped child is a
# zombie, and a zombie answers signal 0 with success on Linux, so that test
# reports "alive" for a process that has already exited. The process table
# does not have that ambiguity.
proc_tree_group_alive() {
    [ -n "$(proc_tree_group_members "$1")" ]
}

# proc_tree_terminate <pid> [grace-seconds] [expected-identity] -- TERM the
# group, wait out the grace period, KILL the group, and only THEN check whether
# anything is left. When expected-identity is supplied, the leader identity is
# revalidated immediately before every group signal, and a failed group signal
# never falls back to the bare pid. Windows fallback targets only survivors
# whose current identity can be captured and immediately revalidated. The
# initial guard splits a CONFIRMED exit/recycle (rc 3, no signal sent) from a
# probe that could not confirm anything either way (rc 2) -- callers must not
# treat them the same (HIMMEL-1501).
proc_tree_terminate() {
    local pid="$1" grace="${2:-3}" expected_identity="${3:-}" survivor survivor_identity w guarded=0 identity_unverified=0
    local member member_identity i leader_identity_rc survivor_verified=0 identity_rc=0
    local -a member_pids=() member_identities=()
    [ -n "$pid" ] || return 0
    [ "$#" -ge 3 ] && guarded=1

    if [ "$guarded" -eq 1 ]; then
        identity_rc=0
        proc_tree_process_identity_matches "$pid" "$expected_identity" || identity_rc=$?
        if [ "$identity_rc" -ne 0 ]; then
            # rc 1 = identity_matches CONFIRMED the leader already
            # exited/was recycled; rc 2 = the probe itself was unavailable.
            # These demand opposite handling downstream (HIMMEL-1501).
            [ "$identity_rc" -eq 1 ] && return 3
            return 2
        fi
        # The leader can honor TERM while a descendant ignores it. Snapshot every
        # observable member identity before TERM so an exited/recycled leader does
        # not strand survivors or authorize signals to newly-reused numeric pids.
        for member in $(proc_tree_group_members "$pid"); do
            member_identity=$(proc_tree_process_identity "$member") || member_identity=''
            [ -n "$member_identity" ] || continue
            member_pids[${#member_pids[@]}]="$member"
            member_identities[${#member_identities[@]}]="$member_identity"
        done
        if ! kill -TERM -"$pid" 2>/dev/null; then
            proc_tree_group_alive "$pid" || return 0
            return 2
        fi
    else
        # Without an ownership identity, preserve the legacy best-effort bare-pid
        # fallback for callers that did not establish a dedicated process group.
        kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    fi

    # Sleep the grace out flat rather than polling it away. Reading the
    # process table costs seconds on a loaded Windows box -- the state this
    # helper exists to clean up -- so polling to maybe save 3s reliably spent
    # 15 or more. The grace is a courtesy window for the suite's own cleanup;
    # nothing downstream needs to know precisely when it stopped needing it.
    sleep "$grace"

    proc_tree_group_alive "$pid" || return 0
    if [ "$guarded" -eq 1 ]; then
        # The original leader may exit and its numeric pid may be recycled during
        # the TERM grace. If it still matches, the group signal remains owned. If
        # not, escalate only member pids whose pre-TERM identities still match.
        leader_identity_rc=0
        proc_tree_process_identity_matches "$pid" "$expected_identity" || leader_identity_rc=$?
        if [ "$leader_identity_rc" -eq 0 ]; then
            if ! kill -KILL -"$pid" 2>/dev/null; then
                proc_tree_group_alive "$pid" || return 0
                return 2
            fi
        else
            i=0
            while [ "$i" -lt "${#member_pids[@]}" ]; do
                member=${member_pids[$i]}
                member_identity=${member_identities[$i]}
                if proc_tree_process_identity_matches "$member" "$member_identity"; then
                    survivor_verified=1
                    kill -KILL "$member" 2>/dev/null || true
                fi
                i=$((i + 1))
            done
            [ "$survivor_verified" -eq 1 ] || return 2
            sleep 1
            proc_tree_group_alive "$pid" || return 0
            return 1
        fi
    else
        kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    fi
    sleep 1

    # ONE table read, after the only signal that cannot be ignored. Anything
    # here is a delivery failure, not a stubborn process.
    proc_tree_group_alive "$pid" || return 0

    if proc_tree_is_windows; then
        for survivor in $(proc_tree_group_members "$pid"); do
            if [ "$guarded" -eq 1 ]; then
                survivor_identity=$(proc_tree_process_identity "$survivor") || survivor_identity=''
                if [ -z "$survivor_identity" ] || ! proc_tree_process_identity_matches "$survivor" "$survivor_identity"; then
                    identity_unverified=1
                    continue
                fi
            fi
            w=$(proc_tree_winpid "$survivor")
            [ -n "$w" ] || continue
            # MSYS_NO_PATHCONV: without it MSYS rewrites the /PID and /F
            # switches into Windows paths and taskkill rejects them.
            MSYS_NO_PATHCONV=1 taskkill /PID "$w" /T /F >/dev/null 2>&1
        done
        sleep 1
        proc_tree_group_alive "$pid" || return 0
    fi

    [ "$identity_unverified" -eq 0 ] || return 2
    return 1
}

# proc_tree_group_terminate <pgid> [grace-seconds] -- clean descendants after
# their leader exits. HIMMEL-1474 r4/r12: snapshot each observed member with
# its identity, then revalidate that member immediately before every PID signal.
# Never signal the unowned numeric group id or use a blind Windows tree-kill.
proc_tree_group_terminate() {
    local pid="$1" grace="${2:-3}" member member_identity i identity_unverified=0
    local -a member_pids=() member_identities=()
    [ -n "$pid" ] || return 0
    proc_tree_group_alive "$pid" || return 0

    for member in $(proc_tree_group_members "$pid"); do
        member_identity=$(proc_tree_process_identity "$member") || member_identity=''
        if [ -z "$member_identity" ]; then
            identity_unverified=1
            continue
        fi
        member_pids[${#member_pids[@]}]="$member"
        member_identities[${#member_identities[@]}]="$member_identity"
    done

    i=0
    while [ "$i" -lt "${#member_pids[@]}" ]; do
        member=${member_pids[$i]}
        member_identity=${member_identities[$i]}
        if proc_tree_process_identity_matches "$member" "$member_identity"; then
            kill -TERM "$member" 2>/dev/null || true
        else
            identity_unverified=1
        fi
        i=$((i + 1))
    done
    sleep "$grace"
    if ! proc_tree_group_alive "$pid"; then
        [ "$identity_unverified" -eq 0 ] || return 2
        return 0
    fi

    i=0
    while [ "$i" -lt "${#member_pids[@]}" ]; do
        member=${member_pids[$i]}
        member_identity=${member_identities[$i]}
        if proc_tree_process_identity_matches "$member" "$member_identity"; then
            kill -KILL "$member" 2>/dev/null || true
        else
            identity_unverified=1
        fi
        i=$((i + 1))
    done
    sleep 1
    if ! proc_tree_group_alive "$pid"; then
        [ "$identity_unverified" -eq 0 ] || return 2
        return 0
    fi

    [ "$identity_unverified" -eq 0 ] || return 2
    return 1
}
