#!/usr/bin/env bash
# scripts/hooks/hook-integrity-lock.sh -- HIMMEL-2528 per-session record lock.
#
# It lives in scripts/hooks/, not scripts/lib/, because scripts/hooks/ is one
# of the two directories record-hook-integrity.sh pins: the recorder VERIFIES
# this file against the committed blob before sourcing it (see the "lock lib:
# VERIFY, then source" block there), and only a file in the pinned tree has a
# committed blob to be verified against. It is a LIBRARY, never a wired hook —
# the hook inventory is the hand-maintained EXPECTED_SCRIPT_ORDER list in
# wire-hook-bash.mjs, which no directory scan feeds, so living here does not
# make it look like an unwired hook.
#
# The hook-integrity record at <dir>/<session_id>.json (see
# scripts/hooks/record-hook-integrity.sh) is read-merge-written by whichever
# side gets there first each session: this bash SessionStart recorder, and
# the JS launcher's twin (hook-integrity.js) when it advances a pin past
# HEAD. Without a lock, two concurrent writers can interleave a
# read/merge/rename and one publication silently clobbers the other. This
# lib is the ONE place the lock's on-disk format and constants live; both
# writers implement the identical protocol against it, so keep any change
# here mirrored in the JS twin.
#
# LOCK: an atomic `mkdir "<record_path>.lock"`. Inside it, a single file
# `owner` with exactly three `key=value` lines:
#   pid=<pid>
#   pid_namespace=<msys|win32|posix>
#   start_time=<opaque token, or empty>
# `pid_namespace` exists because bash and node cannot always interpret each
# other's pid: under Git-Bash, `$$` is an MSYS pid, not the Windows pid node
# would report for the "same" process, so a pid number alone is ambiguous
# without knowing which runtime minted it. `start_time` is a pid-reuse guard:
# a dead pid can be recycled by the OS to an unrelated live process before we
# get around to checking it; comparing the process's start time (not just its
# aliveness) tells a live original from a live impostor with the same number.
#
# A dead owner's lock is reclaimed by RENAMING it to a transient
# `<record_path>.lock.dead.<pid>.<random>`, RE-READING the owner file there to
# confirm it is still the incarnation that was judged dead, and only then
# deleting it -- never by removing `<record_path>.lock` in place, and never
# without that second read; see hil_lock_reclaim for both. Such a graveyard
# path is never read by anything else; one surviving a crash mid-reclaim is
# inert litter, not a lock.
#
# CALLER FAILURE POSTURE (decided by the caller, not this lib): the
# SessionStart recorder is ADVISORY — when it cannot acquire the lock it
# exits 0 and writes nothing, the same outcome as never having run. The JS
# launcher's write path DENIES when it cannot acquire the lock, since it is
# advancing a pin mid-session rather than doing a best-effort initial record.
#
# PLATFORM GUARD: this is a POSIX/Git-Bash shell library, not a script with a
# missing `.ps1` twin -- its cross-platform counterpart is the JS
# implementation in scripts/hooks/hook-integrity.js, which the launcher runs
# natively on Windows and which speaks the identical on-disk protocol. This
# side is platform-AWARE, not platform-blind: it records
# pid_namespace=<msys|win32|posix> in the owner file and refuses to reclaim a
# lock owned by a foreign namespace, because under Git-Bash `$$` is an MSYS
# pid while node's is a Windows pid, so the two cannot be compared; liveness
# runs `kill -0` under `LC_ALL=C` and classifies the errno text into
# alive/dead, defaulting an unrecognised message to ALIVE (fail closed); and
# start_time, read from /proc, is unavailable on hosts with no /proc
# (macOS), where the code degrades to the pid alone.
#
# CONVENTIONS: bash 3.2-safe (no mapfile/associative arrays), same posture as
# scripts/lib/render-lease.sh. No comment line may BEGIN with the linter's
# name.
# COVERAGE: scripts/hooks/test-record-hook-integrity.sh.

# Overridable for tests; defaults are the HIMMEL-2528 spec values. Total
# retry budget is bounded at 200ms so a jammed lock never turns an advisory
# SessionStart hook into a slow one.
#
# Validated + normalized to base 10 here, once, at definition (same treatment
# critic-panel.sh gives CRITIC_TIMEOUT_SECS): HIL_LOCK_POLL_MS feeds a
# `$(( ))` arithmetic context in hil_lock_acquire's `waited=$((waited +
# HIL_LOCK_POLL_MS))`, and `$(( ))` is an OCTAL context — an operator- or
# test-supplied value with a leading zero (HIL_LOCK_POLL_MS=010) would
# silently read as 8, not 10. Worse than wrong math: `${VAR:-default}` only
# substitutes on UNSET/EMPTY, so a garbage override (HIL_LOCK_POLL_MS=abc)
# survives that substitution unchanged and then blows up the `$(( ))` --
# under `set -uo pipefail` (no -e, inherited from every caller that sources
# this lib) that failure does not stop the script, but it also leaves
# `waited` un-incremented, so hil_lock_acquire's own exit test never trips
# and the loop spins forever. Both constants get the same guard so neither
# can wedge the loop: invalid input is reported and replaced with the
# default rather than trusted.
_hil_valid_ms() {
    expr "$1" : '^[0-9][0-9]*$' > /dev/null 2>&1 && [ "$1" -gt 0 ] 2>/dev/null
}
if _hil_valid_ms "${HIL_LOCK_WAIT_MS:-200}"; then
    HIL_LOCK_WAIT_MS=$((10#${HIL_LOCK_WAIT_MS:-200}))
else
    echo "hook-integrity-lock: HIL_LOCK_WAIT_MS=$HIL_LOCK_WAIT_MS invalid, using 200" >&2
    HIL_LOCK_WAIT_MS=200
fi
if _hil_valid_ms "${HIL_LOCK_POLL_MS:-10}"; then
    HIL_LOCK_POLL_MS=$((10#${HIL_LOCK_POLL_MS:-10}))
else
    echo "hook-integrity-lock: HIL_LOCK_POLL_MS=$HIL_LOCK_POLL_MS invalid, using 10" >&2
    HIL_LOCK_POLL_MS=10
fi

# hil_pid_namespace -- print this bash process's pid namespace. `msys` when
# running under Git-Bash/MSYS2/Cygwin (uname -s reports MINGW*/MSYS*/CYGWIN*)
# because $$ there is an MSYS pid, not the Windows pid the JS twin would see
# for the same process; `posix` everywhere else (Linux, macOS, WSL bash).
# `win32` is only ever written by the JS twin (native node on Windows) -- the
# bash side never emits it.
hil_pid_namespace() {
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) printf 'msys\n' ;;
        *) printf 'posix\n' ;;
    esac
}

# hil_start_time <pid> -- print an opaque start-time token for PID, or empty
# when unavailable (no /proc, unreadable, pid gone). On Linux this is field
# 22 of /proc/<pid>/stat (ticks since boot the process started at) -- stable
# across the process's life and immune to pid-reuse confusion, unlike the pid
# number alone. The comm field (2nd paren-delimited field) can itself contain
# spaces or parens, so strip everything through the LAST ')' first and count
# fields in what remains: start_time is field 22 of the original line, i.e.
# field 20 once pid and comm are already consumed by the strip.
hil_start_time() {
    local pid="$1" stat_file="/proc/$1/stat"
    [ -n "$pid" ] || { printf ''; return 0; }
    [ -r "$stat_file" ] || { printf ''; return 0; }
    sed 's/.*) //' "$stat_file" 2>/dev/null | awk '{print $20}'
}

# hil_read_owner <lock_dir> -- populate HIL_OWNER_PID / HIL_OWNER_NS /
# HIL_OWNER_START from <lock_dir>/owner. rc 0 well-formed (pid numeric,
# namespace non-empty; start_time may legitimately be empty); rc 1
# missing/unreadable/malformed -- callers MUST treat rc 1 as "not ours to
# interpret", never as "safe to reclaim".
hil_read_owner() {
    local lock="$1" f="$1/owner" k v
    HIL_OWNER_PID=""
    HIL_OWNER_NS=""
    HIL_OWNER_START=""
    [ -r "$f" ] || return 1
    while IFS='=' read -r k v; do
        case "$k" in
            pid) HIL_OWNER_PID="$v" ;;
            pid_namespace) HIL_OWNER_NS="$v" ;;
            start_time) HIL_OWNER_START="$v" ;;
        esac
    done < "$f"
    case "$HIL_OWNER_PID" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ -n "$HIL_OWNER_NS" ] || return 1
    return 0
}

# _hil_write_owner <lock_dir> <pid> <ns> <start> -- write the owner file. rc 0
# only when the file actually landed with content. It must REPORT failure
# rather than swallow it: a lock dir with no owner file is refused by
# hil_lock_reclaim forever (owner missing => not ours to interpret), so a
# silently-failed owner write would permanently wedge every future session on
# that record. hil_lock_acquire's caller-side response to rc 1 is to remove the
# half-built lock; see there.
_hil_write_owner() {
    local lock="$1" pid="$2" ns="$3" start="$4"
    # The `2>/dev/null` comes BEFORE the output redirect deliberately:
    # redirections are applied left to right, so an error opening
    # "$lock/owner" is reported on whatever fd 2 is at that moment. Written the
    # other way round (the intuitive order) the "Permission denied" line
    # escapes to the real stderr and this advisory hook starts printing noise
    # into the transcript on the very path it is meant to handle silently. The
    # rc is unaffected either way.
    {
        printf 'pid=%s\n' "$pid"
        printf 'pid_namespace=%s\n' "$ns"
        printf 'start_time=%s\n' "$start"
    } 2>/dev/null > "$lock/owner" || return 1
    # A successful redirect is not proof of a usable owner file: a full
    # filesystem can create the file and then fail every write into it, and
    # hil_read_owner rejects an empty/partial file as malformed -- which is the
    # same permanent-refusal wedge. Require non-empty before claiming success.
    [ -s "$lock/owner" ] || return 1
    return 0
}

# hil_classify_kill_error <stderr_text> -- map the message `kill -0` printed on
# failure to `alive` or `dead`. The bash side cannot read errno from `kill -0`
# directly, but the DISTINCTION matters: `kill -0` against a LIVE process owned
# by another OS user fails with EPERM, and treating that as death steals a live
# foreign-user lock. hook-integrity.js (the JS twin of this protocol) treats
# EPERM as ALIVE and only ESRCH as dead; the two implementations must agree, so
# this classifier encodes the same rule.
#
# FAIL-CLOSED DEFAULT: an error string this function does not recognise is
# reported as `alive`. Guessing "dead" from an unfamiliar message is the only
# outcome that can cause two writers to hold the lock at once; guessing "alive"
# only delays a writer. Callers pass C-locale text (see hil_pid_liveness) so
# these are the untranslated strings, but the default covers the rest anyway.
hil_classify_kill_error() {
    case "$1" in
        *[Nn]o\ such\ process*) printf 'dead\n' ;;
        *[Oo]peration\ not\ permitted*|*[Nn]ot\ owner*|*[Pp]ermission\ denied*)
            printf 'alive\n' ;;
        *) printf 'alive\n' ;;
    esac
}

# hil_pid_liveness <pid> -- print `alive` or `dead` for PID, erring towards
# `alive`. LC_ALL=C is set inside the command substitution's subshell so the
# message classified below is the untranslated C-locale one, not a localized
# rendering hil_classify_kill_error would not match (and would then, correctly
# but uselessly, default to `alive` on every non-English machine).
hil_pid_liveness() {
    local pid="$1" err rc=0
    # `|| rc=$?` rather than a bare assignment + `$?`: a failing command
    # substitution is a failing assignment, which under a caller's `set -e`
    # (this lib is sourced, so the caller's shell options apply) would abort
    # instead of reaching the classification below.
    err=$(LC_ALL=C; kill -0 "$pid" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf 'alive\n'
        return 0
    fi
    # /proc is an ADDITIONAL oracle, never the only one (macOS has no /proc):
    # it can only ever upgrade a `dead` verdict to `alive`, so a platform
    # without it loses a corroboration, not the check itself.
    if [ "$(hil_classify_kill_error "$err")" = "dead" ] \
        && { [ ! -d /proc/self ] || [ ! -d "/proc/$pid" ]; }; then
        printf 'dead\n'
        return 0
    fi
    printf 'alive\n'
}

# hil_lock_reclaim <record_path> -- reclaim <record_path>.lock ONLY when its
# owner is PROVABLY dead. Never reclaims by age alone: a paused-but-live
# owner would resume and could overwrite a NEWER publication with a stale
# read, which is a worse failure than a slightly-delayed writer. rc 0
# reclaimed (lock dir removed); rc 1 refused -- owner file missing/unreadable
# /malformed, a foreign pid_namespace (not ours to interpret), the owner is
# provably (or unprovably-not) still alive, another contender won the steal
# below, or the directory this call renamed aside turned out NOT to be the
# incarnation it judged (a recreated lock), in which case it is put back first.
# Callers must not proceed past a refusal.
hil_lock_reclaim() {
    local record="$1" lock="${1}.lock" our_ns live_start graveyard
    local seen_pid seen_ns seen_start
    our_ns=$(hil_pid_namespace)
    hil_read_owner "$lock" || return 1
    [ "$HIL_OWNER_NS" = "$our_ns" ] || return 1
    if [ "$(hil_pid_liveness "$HIL_OWNER_PID")" = "alive" ]; then
        # A live pid alone is not proof of identity if the recorded owner
        # gave us a start_time to check it against -- an unreadable stored
        # start_time (empty) means liveness is all the evidence we can ever
        # have, so treat it as sufficient (owner is live).
        [ -n "$HIL_OWNER_START" ] || return 1
        live_start=$(hil_start_time "$HIL_OWNER_PID")
        # Same fail-closed rule when WE cannot read the live process's own
        # start_time: we cannot disprove liveness, so we must not reclaim.
        if [ -z "$live_start" ] || [ "$live_start" = "$HIL_OWNER_START" ]; then
            return 1
        fi
        # live_start differs from the recorded one: the pid number was
        # reused by an unrelated process after the real owner exited. Falls
        # through to reclaim.
    fi
    # STEAL ATOMICALLY, never `rm -rf "$lock"` in place. Two contenders can
    # read the SAME dead owner and both decide to reclaim; `rm -rf` succeeds
    # for BOTH of them (it is idempotent on a path that is already gone), so
    # the loser's removal lands on whatever lock exists at that moment -- which
    # may be the winner's freshly created one, leaving two processes holding
    # the lock and each able to publish from a stale read.
    #
    # Renaming is at least atomic -- but a rename cannot be CONDITIONED on
    # which directory is at the path, and that is the hole this used to paper
    # over. "The loser's `mv` fails against a path that is no longer there" is
    # only true while the winner has NOT yet recreated it. Once the winner has
    # stolen the dead lock AND re-taken it under its own live pid, the loser's
    # `mv` SUCCEEDS -- against the winner's LIVE lock, which it then carts off
    # and deletes.
    #
    # So the identity check happens AFTER the move and is undone when it was
    # the wrong directory: what we just renamed aside must still carry the
    # owner we inspected. A recreated lock cannot, by construction -- a holder
    # only ever writes its OWN pid into the owner file, and we only got here by
    # proving the recorded pid is dead (or that the live process wearing that
    # pid number started at a different time, i.e. is not the recorded owner),
    # so a recreated lock always names a different, live owner. That is why NO
    # inode check is needed and why there is no platform caveat: the owner file
    # content already discriminates. An owner file that is not there at all
    # (mkdir done, stamp not yet written) is the same verdict -- not the
    # incarnation we judged. Put it back and refuse.
    #
    # RESIDUAL, small but real: the restore is itself two syscalls, so a third
    # party can occupy the freed path in between. The rename back then fails
    # and we leave the graveyard where it is rather than delete a lock we could
    # not return -- inert litter beats an unjustified deletion.
    #
    # The graveyard name carries our pid and a random suffix so two reclaimers
    # can never collide on the destination either; renaming a directory onto a
    # NON-EXISTENT path is a plain rename(2), which is why it must not pre-exist
    # (and why mktemp -d is wrong here -- it would create the path and turn the
    # mv into a move INTO it). The `[ -e "$lock" ]` guard on the restore is the
    # one place this differs in FORM from reclaimIfDead in
    # scripts/hooks/hook-integrity.js: node's rename refuses a non-empty
    # directory target outright, while `mv` would silently move the graveyard
    # INSIDE it. Same behaviour, different spelling; the two must not diverge in
    # anything else.
    seen_pid="$HIL_OWNER_PID"
    seen_ns="$HIL_OWNER_NS"
    seen_start="$HIL_OWNER_START"
    graveyard="${lock}.dead.$$.${RANDOM}${RANDOM}"
    if [ -e "$graveyard" ]; then
        return 1
    fi
    mv "$lock" "$graveyard" 2>/dev/null || return 1
    # hil_read_owner OVERWRITES HIL_OWNER_*, which is why the values we judged
    # were copied into locals above -- comparing the globals against themselves
    # here would pass unconditionally and pin nothing.
    if ! hil_read_owner "$graveyard" \
        || [ "$HIL_OWNER_PID" != "$seen_pid" ] \
        || [ "$HIL_OWNER_NS" != "$seen_ns" ] \
        || [ "$HIL_OWNER_START" != "$seen_start" ]; then
        [ -e "$lock" ] || mv "$graveyard" "$lock" 2>/dev/null || true
        return 1
    fi
    rm -rf "$graveyard" 2>/dev/null || true
    return 0
}

# hil_lock_acquire <record_path> -- atomically acquire <record_path>.lock via
# mkdir, retrying for up to HIL_LOCK_WAIT_MS total (polling every
# HIL_LOCK_POLL_MS, attempting hil_lock_reclaim on every failed mkdir before
# the next retry). rc 0 acquired (owner file now names this process); rc 1
# timed out / refused -- prints exactly one line to stderr naming the lock
# path. This function only tries and reports; the caller decides what a
# failure to acquire means for it (see the header's CALLER FAILURE POSTURE).
hil_lock_acquire() {
    local record="$1" lock="${1}.lock" waited=0 ns pid start poll_secs
    ns=$(hil_pid_namespace)
    pid=$$
    start=$(hil_start_time "$pid")
    poll_secs=$(awk -v ms="$HIL_LOCK_POLL_MS" 'BEGIN { printf "%.3f", ms / 1000 }' 2>/dev/null)
    [ -n "$poll_secs" ] || poll_secs=0.01
    while :; do
        if mkdir "$lock" 2>/dev/null; then
            if _hil_write_owner "$lock" "$pid" "$ns" "$start"; then
                return 0
            fi
            # mkdir won the race but the owner file could not be written (full
            # or unwritable filesystem). An OWNERLESS lock dir is the worst
            # possible thing to leave behind: hil_lock_reclaim refuses a lock
            # whose owner is missing, forever, so it would wedge every future
            # session on this record with no way out short of a manual rm.
            # Tear it back down and report failure -- the caller's advisory
            # posture (write nothing this pass) is a recoverable outcome; a
            # permanent wedge is not.
            rm -rf "$lock" 2>/dev/null || true
            echo "hook-integrity-lock: could not write owner for $lock" >&2
            return 1
        fi
        hil_lock_reclaim "$record" >/dev/null 2>&1
        # HIL_LOCK_POLL_MS is already normalized to a leading-zero-free
        # decimal above, but 10# is repeated here (belt-and-suspenders, and
        # what the class detector matches on) since this is the one place it
        # actually feeds a $(( )) octal context.
        waited=$((waited + 10#$HIL_LOCK_POLL_MS))
        if [ "$waited" -gt "$HIL_LOCK_WAIT_MS" ]; then
            echo "hook-integrity-lock: could not acquire $lock" >&2
            return 1
        fi
        sleep "$poll_secs" 2>/dev/null
    done
}

# hil_lock_release <record_path> -- rm -rf the lock dir ONLY when its owner
# record names THIS process (pid + namespace match). A former holder whose
# lock was reclaimed by hil_lock_reclaim must never delete a successor's
# freshly acquired lock. Always returns 0: release runs from cleanup traps,
# and a cleanup step must never itself become a reason to fail.
hil_lock_release() {
    local record="$1" lock="${1}.lock" ns
    [ -e "$lock" ] || return 0
    ns=$(hil_pid_namespace)
    if hil_read_owner "$lock" && [ "$HIL_OWNER_PID" = "$$" ] && [ "$HIL_OWNER_NS" = "$ns" ]; then
        rm -rf "$lock" 2>/dev/null || true
    fi
    return 0
}
