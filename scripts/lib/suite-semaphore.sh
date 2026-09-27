#!/usr/bin/env bash
# scripts/lib/suite-semaphore.sh -- the machine-wide suite concurrency budget
# (HIMMEL-1818). Sourced by the two suite chokepoints: scripts/quiet-run.sh
# (label `suite`) and scripts/ci/run-shell-tests.sh. The HIMMEL-1338 scan-root
# lock inside run-shell-tests.sh serialises sweeps of ONE tree; this budget
# counts every suite on the machine, whatever tree or runner it came from.
#
# Model: N slot directories, slot-1..slot-N, under
#   ${HIMMEL_SUITE_SEMAPHORE_DIR:-${TMPDIR:-/tmp}/himmel-suite-semaphore.d}
# ponytail: the TMPDIR-keyed default shards the "machine-wide" budget across
# any two processes with different TMPDIR values (e.g. two login sessions) --
# each gets its own N-slot budget instead of sharing one. Upgrade path tracked
# as the round-3 TMPDIR sharding axis on HIMMEL-1838.
# N = HIMMEL_SUITE_SLOTS (default 3). A slot is taken by an atomic `mkdir` and
# carries an `owner` file: pid, start-time identity (proc-tree.sh), label,
# started epoch. Liveness is pid + identity, not a TTL alone -- unlike
# shared-branch-lock.sh, which deliberately does no pid probing. A slot is
# reclaimed when its owner is confirmed gone, its pid now names a different
# process (identity mismatch), or it is older than HIMMEL_SUITE_SLOT_TTL
# seconds (default 14400, the scan lock's TTL). An ownerless slot (a writer
# killed between mkdir and the owner write) is reclaimed after ~1 minute.
#
# Busy: fail loud with rc 75 (EX_TEMPFAIL), naming each holder and the retry
# shape. SUITE_LOCK_WAIT=<seconds> (the knob run-shell-tests.sh already reads)
# waits for a slot instead.
#
# Re-entrancy: the holder exports HIMMEL_SUITE_SLOT_HELD=<slot path>. It is
# honoured only when that slot's recorded owner (pid AND identity) is a live
# ANCESTOR of the current process -- a nested quiet-run under the holder, or a
# suite the runner spawns. A value copied into an unrelated process's
# environment names an owner that is not its ancestor, so it takes a slot like
# anyone else (HIMMEL-1818 console ruling, condition a).
# ponytail: a process that WRITES a slot dir by hand, naming its own ancestor as
# owner, passes the ancestor check -- the semaphore is a budget, not a security
# boundary; the deny-hook (block-chokepoint-env-prefix.sh) is the fence, and a
# hand-written slot is deliberate evasion, not drift. Upgrade trigger: a second
# observed forgery -> HMAC the owner file with a per-boot secret.
#
# API (after sourcing):
#   suite_sem_acquire <label> <retry-hint>  -> 0 slot held (or re-entrant),
#                                              75 busy, 2 bad config
#   suite_sem_release                        -> frees only a slot WE acquired
# bash 3.2-safe; set -e/-u safe. ASCII only.

_SUITE_SEM_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=proc-tree.sh
# shellcheck disable=SC1091
. "$_SUITE_SEM_LIB_DIR/proc-tree.sh"

SUITE_SEM_SLOT=''
SUITE_SEM_OWNER_PID=''

suite_sem_dir() {
    printf '%s\n' "${HIMMEL_SUITE_SEMAPHORE_DIR:-${TMPDIR:-/tmp}/himmel-suite-semaphore.d}"
}

# _suite_sem_uint <value> <default> -- print value when a positive integer.
# An all-zero string ("0", "00", ...) is not a digit-string typo the caller
# needs to see rejected -- it falls back to the default like any other
# non-positive input, same as an empty or non-digit value.
_suite_sem_uint() {
    case "$1" in
        ''|*[!0-9]*) printf '%s\n' "$2" ;;
        *) if [ "$((10#$1))" -gt 0 ]; then printf '%s\n' "$((10#$1))"; else printf '%s\n' "$2"; fi ;;
    esac
}

# _suite_sem_ppid <pid> -- the parent pid, or nothing. MSYS exposes
# /proc/<pid>/ppid, Linux the PPid: line of /proc/<pid>/status, macOS neither.
_suite_sem_ppid() {
    local pid="$1" line
    if [ -r "/proc/$pid/ppid" ]; then
        cat "/proc/$pid/ppid" 2>/dev/null
        return 0
    fi
    if [ -r "/proc/$pid/status" ]; then
        while IFS= read -r line; do
            case "$line" in
                PPid:*) line=${line#PPid:}; printf '%s\n' "${line//[!0-9]/}"; return 0 ;;
            esac
        done <"/proc/$pid/status"
        return 0
    fi
    line=$(ps -o ppid= -p "$pid" 2>/dev/null) || line=''
    printf '%s\n' "${line//[!0-9]/}"
}

# _suite_sem_is_ancestor <pid> -- 0 when <pid> is this shell or an ancestor.
_suite_sem_is_ancestor() {
    local want="$1" cur="$$" hops=0
    while [ -n "$cur" ] && [ "$cur" != "0" ] && [ "$hops" -lt 64 ]; do
        [ "$cur" = "$want" ] && return 0
        [ "$cur" = "1" ] && return 1
        cur=$(_suite_sem_ppid "$cur")
        hops=$((hops + 1))
    done
    return 1
}

# _suite_sem_read_owner <slot> -- sets SO_PID SO_ID SO_LABEL SO_STARTED;
# returns 1 when the slot has no owner file yet.
_suite_sem_read_owner() {
    local line
    SO_PID=''; SO_ID=''; SO_LABEL=''; SO_STARTED=''
    [ -f "$1/owner" ] || return 1
    while IFS= read -r line; do
        case "$line" in
            pid=*)     SO_PID=${line#pid=} ;;
            identity=*) SO_ID=${line#identity=} ;;
            label=*)   SO_LABEL=${line#label=} ;;
            started=*) SO_STARTED=${line#started=} ;;
        esac
    done <"$1/owner"
    return 0
}

# _suite_sem_stale <slot> -- 0 when the slot may be reclaimed; sets
# SUITE_SEM_STALE_WHY.
_suite_sem_stale() {
    local slot="$1" ttl now rc=0
    SUITE_SEM_STALE_WHY=''
    if ! _suite_sem_read_owner "$slot"; then
        # Ownerless: a writer between mkdir and the owner write, or one killed
        # there. Young = still being written; leave it alone.
        if [ -n "$(find "$slot" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then  # gnu-ok: -maxdepth/-mmin are BSD find too; bash has no mtime-age test
            SUITE_SEM_STALE_WHY='no owner record for over a minute'
            return 0
        fi
        return 1
    fi
    case "$SO_PID" in
        ''|*[!0-9]*) SUITE_SEM_STALE_WHY='owner record has no valid pid'; return 0 ;;
    esac
    # HIMMEL-3778: SO_ID can be empty (the ps probe failed at acquire time,
    # see _suite_sem_try below) -- proc_tree_process_identity_matches alone
    # always answers 2 (unavailable) for an empty expected, which made a
    # confirmed-dead holder with no recorded identity reclaimable ONLY by the
    # TTL. proc_tree_liveness_matches falls back to identity-free liveness in
    # that case, so a dead holder is still confirmed dead even without one.
    proc_tree_liveness_matches "$SO_PID" "$SO_ID" || rc=$?
    if [ "$rc" -eq 1 ]; then
        SUITE_SEM_STALE_WHY="owner pid $SO_PID is gone or now names another process"
        return 0
    fi
    # rc 0 (live) or 2 (probe could not answer): only the TTL can free it.
    ttl=$(_suite_sem_uint "${HIMMEL_SUITE_SLOT_TTL:-}" 14400)
    now=$(date +%s)
    case "$SO_STARTED" in ''|*[!0-9]*) SO_STARTED=0 ;; esac
    if [ $((now - SO_STARTED)) -gt "$ttl" ]; then
        SUITE_SEM_STALE_WHY="older than HIMMEL_SUITE_SLOT_TTL=${ttl}s"
        return 0
    fi
    return 1
}

# _suite_sem_reclaim <slot> -- remove a stale slot under a per-slot reclaim
# lock, re-checking staleness while holding it: two waiters that both judged
# the same dead slot stale must not let the second remove the FRESH slot the
# first one's successor just created. mkdir on $slot cannot succeed while
# this function holds it, so nothing can claim $slot between the recheck and
# the mv below -- the mv only ever moves the dead owner's own directory.
# ponytail: the guard only orders reclaimers against EACH OTHER, not against
# a false-stale verdict -- if _suite_sem_stale wrongly calls a live owner
# dead (a too-short TTL, clock skew), that owner's own eventual release could
# still race this mv. Fixing that needs a stronger liveness check than a TTL
# heuristic, tracked under HIMMEL-1838's liveness-owner unification.
_suite_sem_reclaim() {
    local slot="$1" guard="$1.reclaim" tomb
    if ! mkdir "$guard" 2>/dev/null; then
        # A reclaimer killed mid-way leaves the guard behind; free it late.
        [ -n "$(find "$guard" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rmdir "$guard" 2>/dev/null  # gnu-ok: -maxdepth/-mmin are BSD find too
        return 1
    fi
    if _suite_sem_stale "$slot"; then
        tomb="$slot.tomb.$$.$RANDOM"
        if mv "$slot" "$tomb" 2>/dev/null; then
            rm -rf "$tomb"
            printf 'suite-semaphore: reclaimed %s (%s; label %s)\n' \
                "${slot##*/}" "$SUITE_SEM_STALE_WHY" "${SO_LABEL:-?}" >&2
        fi
    fi
    rmdir "$guard" 2>/dev/null
    return 0
}

# _suite_sem_held_ok -- 0 when HIMMEL_SUITE_SLOT_HELD names a slot of THIS
# semaphore whose owner is a live ancestor with a matching identity.
_suite_sem_held_ok() {
    local held="${HIMMEL_SUITE_SLOT_HELD:-}" dir
    [ -n "$held" ] || return 1
    dir=$(suite_sem_dir)
    case "$held" in "$dir"/slot-*) ;; *) return 1 ;; esac
    case "${held#"$dir"/slot-}" in ''|*[!0-9]*) return 1 ;; esac
    _suite_sem_read_owner "$held" || return 1
    case "$SO_PID" in ''|*[!0-9]*) return 1 ;; esac
    _suite_sem_is_ancestor "$SO_PID" || return 1
    # HIMMEL-3778: an empty SO_ID (failed ps probe at acquire) must not refuse
    # our OWN re-entrant child -- fall back to identity-free liveness, same as
    # _suite_sem_stale above.
    proc_tree_liveness_matches "$SO_PID" "$SO_ID"
}

# _suite_sem_try <slot> <label> -- take <slot>; 0 on success.
_suite_sem_try() {
    local slot="$1" label="$2" id
    mkdir "$slot" 2>/dev/null || return 1
    id=$(proc_tree_process_identity "$$") || id=''
    if ! { printf 'pid=%s\nidentity=%s\nlabel=%s\nstarted=%s\n' \
        "$$" "$id" "$label" "$(date +%s)" >"$slot/owner.tmp" \
        && mv "$slot/owner.tmp" "$slot/owner"; }; then
        rm -rf "$slot" 2>/dev/null
        return 1
    fi
    SUITE_SEM_SLOT="$slot"
    SUITE_SEM_OWNER_PID="$$"
    export HIMMEL_SUITE_SLOT_HELD="$slot"
    return 0
}

# _suite_sem_busy_report <dir> <n> <retry-hint>
_suite_sem_busy_report() {
    local dir="$1" n="$2" hint="$3" i=1 now age
    now=$(date +%s)
    {
        printf 'ERR suite-semaphore: all %s suite slot(s) on this machine are busy (HIMMEL-1818).\n' "$n"
        while [ "$i" -le "$n" ]; do
            if _suite_sem_read_owner "$dir/slot-$i"; then
                case "$SO_STARTED" in ''|*[!0-9]*) age='?' ;; *) age="$((now - SO_STARTED))s" ;; esac
                printf '  slot-%s: pid %s, label %s, age %s\n' "$i" "$SO_PID" "${SO_LABEL:-?}" "$age"
            else
                printf '  slot-%s: being taken (no owner record yet)\n' "$i"
            fi
            i=$((i + 1))
        done
        printf 'Retry, waiting up to 60s for a slot:\n'
        printf '  SUITE_LOCK_WAIT=60 %s\n' "$hint"
        printf 'The budget is HIMMEL_SUITE_SLOTS (default 3), set in the LAUNCHING shell.\n'
    } >&2
}

suite_sem_acquire() {
    local label="$1" hint="$2" dir n wait poll deadline i
    if _suite_sem_held_ok; then
        return 0
    fi
    dir=$(suite_sem_dir)
    n=$(_suite_sem_uint "${HIMMEL_SUITE_SLOTS:-}" 3)
    wait=${SUITE_LOCK_WAIT:-0}
    case "$wait" in ''|*[!0-9]*) wait=0 ;; esac
    wait=$((10#$wait))
    poll=$(_suite_sem_uint "${HIMMEL_SUITE_SLOT_POLL:-}" 1)
    if ! mkdir -p "$dir" 2>/dev/null; then
        printf 'ERR suite-semaphore: cannot create %s\n' "$dir" >&2
        return 2
    fi
    deadline=$(( $(date +%s) + wait ))
    while :; do
        i=1
        while [ "$i" -le "$n" ]; do
            _suite_sem_try "$dir/slot-$i" "$label" && return 0
            if _suite_sem_stale "$dir/slot-$i"; then
                _suite_sem_reclaim "$dir/slot-$i" || true
                _suite_sem_try "$dir/slot-$i" "$label" && return 0
            fi
            i=$((i + 1))
        done
        if [ "$(date +%s)" -ge "$deadline" ]; then
            _suite_sem_busy_report "$dir" "$n" "$hint"
            return 75
        fi
        sleep "$poll"
    done
}

# ponytail: release checks the owner record and then removes -- a reclaimer
# acting between the two (only possible once our slot passed its TTL) could
# have its fresh slot removed. Window is one stat; upgrade trigger: an
# observed double-hold -> release via the same reclaim guard.
suite_sem_release() {
    [ -n "$SUITE_SEM_SLOT" ] || return 0
    if _suite_sem_read_owner "$SUITE_SEM_SLOT" && [ "$SO_PID" = "$SUITE_SEM_OWNER_PID" ]; then
        rm -rf "$SUITE_SEM_SLOT"
    fi
    SUITE_SEM_SLOT=''
    return 0
}
