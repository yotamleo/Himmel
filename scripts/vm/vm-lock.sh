#!/usr/bin/env bash
# vm-lock.sh — a FIFO, per-name advisory lock for VirtualBox lifecycle calls
# (HIMMEL-2623 PR-B, post-incident hardening).
#
# Platform guard (linux-only): the lock itself is pure POSIX filesystem
# primitives (mkdir, set -C) with no VBoxManage dependency of its own — the
# constraint is the STATION, not this file's logic. It guards VBoxManage
# calls that only ever run on this Linux station and inside Linux guest
# VMs (see the divergence note below); a Windows port would first need a
# Windows caller to lock for, which does not exist.
#
# WHY THIS EXISTS: an after-report.sh debug session forgot to pin
# VBOXMANAGE_PATH and fell through to the station's REAL VBoxManage, which
# then cloned and snapshotted a real VM with nothing structural in the way.
# The containment that stopped it was a brief instruction, not code. This
# file plus after-report.sh's own opt-in guard (see its header) are the
# structural fix: every real VBoxManage-touching span in after-report.sh now
# runs only while holding a lock named for the VM it is about to touch.
#
# THIS IS A DELIBERATE, DOCUMENTED MIRROR of the FIFO suite lock that landed
# in scripts/ci/run-shell-tests.sh at HIMMEL-2623 PR-A (the `_suite_lock_*` /
# `suite_lock_*` block, eight CR rounds of hardening) — NOT a refactor to
# share code with it. That file is deliberately self-contained and bash
# 3.2-safe, and its lock just landed; extracting a shared library now risks
# regressing eight rounds of fixes for a net-new, lower-concurrency use case.
# So: same properties, a SEPARATE, SIMPLER implementation, with the
# following DELIBERATE divergences from the original, each closing a
# specific gap the original hit or accepting a specific tradeoff:
#
#   - SECONDS, not nanoseconds, for `started`/`seen`. The suite lock moved to
#     nanoseconds (round 4) because many suite runners can plausibly start in
#     the same wall-clock second on one busy host. A VM lock's contenders are
#     at most HIMMEL_VM_AR_MAX after-report.sh processes (small, operator-set)
#     plus this file's own test suite — same-second collisions are the rare
#     case, not the common one, and a pid tiebreak (identical to the
#     original's own tiebreak for an exact tie) resolves them exactly the
#     same way. Revisit if this lock ever gates something with suite-lock-
#     scale concurrency.
#   - No BSD/uutils/MSYS-specific probing (the original's `date +%N`
#     capability probe, the uutils-mkdir-both-win-race comment). This
#     station and the guest VMs are Linux; the VM lock has no Windows/Git
#     Bash call site today. The underlying race THAT probing defends
#     against (two `mkdir`s of the same path both reporting success) is
#     still defended against here via the SAME fix the suite lock uses —
#     the owner-file `set -C` create is the real arbiter, not the `mkdir`.
#   - Messaging is shorter. The original's refusal text is long because it
#     had to teach an operator to tell "live holder" from "provably dead"
#     from "unverifiable" apart (HIMMEL-1805 shipped after a wrong "wait for
#     it" verdict at a corpse) — the CLASSIFICATION logic that came out of
#     that is kept verbatim in spirit here (pid_present / confirmed-dead /
#     unverifiable are three different code paths below, never collapsed
#     into one), just narrated in fewer words.
#   - No forge-relative "scope this run to a subtree" advice (meaningless
#     for a VM name) and no SUITE_TIER_MODE-shaped config surface — this
#     lock has exactly one axis: which VM name is contended.
#
# PROPERTIES CARRIED OVER DELIBERATELY (operator-specified, non-negotiable):
#   - Tickets named for the OWNER'S PID — unique by construction, never a
#     scanned max+1 sequence number (the original's own round-1 bug).
#   - THREE time fields, never conflated: `started` (arrival, branded once,
#     immutable, the sole FIFO ordering key), `seen` (liveness, refreshed by
#     the owner every poll), `stale_after` (the ticket's OWN expiry window,
#     branded by its owner, read verbatim by every prune/turn check — never
#     recomputed from the READER's own interval, which is what let a
#     fast-polling reader prune a healthy slow-polling waiter in the
#     original, round 8).
#   - The staleness ceiling for a ticket's own `stale_after` is an ABSOLUTE
#     constant (HIMMEL_VM_QUEUE_STALE_AFTER_CEILING), never
#     reader-relative — a reader-relative cap prunes a healthy waiter with a
#     legitimately longer lease (the original's round 9 fix).
#   - Short-circuits ("lock disabled", re-entrancy) are checked BEFORE the
#     queue-turn check, in BOTH the immediate-acquire and the waiting entry
#     points — the original's round 2 finding: putting the turn-check first
#     means a nested call whose own parent already holds the lock blocks on
#     its own parent forever, because the turn-check gate means the
#     short-circuited acquire underneath is never even reached.
#   - A no-wait caller YIELDS to any live queued waiter rather than jumping
#     it, even when the lock itself is free at that instant (the original's
#     round 4: an ad-hoc no-wait run can otherwise starve the FIFO queue
#     forever no matter how many callers upgrade to it).
#
# Usage (source, then call):
#   vm_lock_acquire_waiting <name>   # 0 acquired; 2 refused (instant/permanent
#                                    # — HIMMEL_VM_LOCK_PERMANENT names why);
#                                    # 5 waited the full budget and gave up
#   vm_lock_release <name>           # safe to call unconditionally (checks
#                                    # ownership itself); call from a trap
#
# Env:
#   HIMMEL_VM_LOCK              0 disables the lock entirely (default 1)
#   HIMMEL_VM_LOCK_DIR          base dir for lock state (default /tmp; test seam)
#   HIMMEL_VM_LOCK_TTL          seconds after which a held lock is presumed
#                               abandoned even if its pid still answers
#                               (default 14400 = 4h, mirrors SUITE_LOCK_TTL)
#   HIMMEL_VM_LOCK_WAIT         seconds to wait for a held lock (default 0 =
#                               refuse immediately, like SUITE_LOCK_WAIT)
#   HIMMEL_VM_LOCK_WAIT_INTERVAL  seconds between heartbeat polls (default 60)
#   HIMMEL_VM_QUEUE_STALE_AFTER_CEILING  absolute cap on a ticket's own
#                               stale_after window (default = HIMMEL_VM_LOCK_TTL)
set -uo pipefail

: "${HIMMEL_VM_LOCK:=1}"
: "${HIMMEL_VM_LOCK_DIR:=/tmp}"

# _vm_lock_num <name> <value> <default> [min] — validate <value> is an
# integer >= [min] (default 0), falling back to <default> with a WARN
# otherwise. `10#$val` forces decimal interpretation (HIMMEL-2623 CR
# finding): every numeric knob below reaches this unvalidated from whatever
# the environment sets — after-report.sh and dry-run-restore.sh forward
# HIMMEL_VM_LOCK_WAIT/HIMMEL_VM_LOCK_WAIT_INTERVAL straight through with no
# case-statement guard of their own — so an operator-set "010" would
# otherwise parse as OCTAL 8 in the `$(( ))` sites below, not decimal 10.
# Mirrors run-shell-tests.sh's own `_suite_num` (same `10#` fix) but never
# `exit`s on bad input: this file is SOURCED into the caller's own process,
# so terminating here would kill the whole caller over one bad knob, not
# just refuse the lock.
_vm_lock_num() {
    local name="$1" val="$2" default="$3" min="${4:-0}" v
    case "$val" in
        ''|*[!0-9]*)
            printf 'WARN: %s="%s" is not a non-negative integer — using %s\n' "$name" "$val" "$default" >&2
            printf '%s' "$default"
            return 0
            ;;
    esac
    v=$(( 10#$val ))
    if [ "$v" -lt "$min" ]; then
        printf 'WARN: %s="%s" must be >= %s — using %s\n' "$name" "$val" "$min" "$default" >&2
        printf '%s' "$default"
        return 0
    fi
    printf '%s' "$v"
}

HIMMEL_VM_LOCK_TTL=$(_vm_lock_num HIMMEL_VM_LOCK_TTL "${HIMMEL_VM_LOCK_TTL:-14400}" 14400 1)
HIMMEL_VM_LOCK_WAIT=$(_vm_lock_num HIMMEL_VM_LOCK_WAIT "${HIMMEL_VM_LOCK_WAIT:-0}" 0 0)
HIMMEL_VM_LOCK_WAIT_INTERVAL=$(_vm_lock_num HIMMEL_VM_LOCK_WAIT_INTERVAL "${HIMMEL_VM_LOCK_WAIT_INTERVAL:-60}" 60 1)
HIMMEL_VM_QUEUE_STALE_AFTER_CEILING=$(_vm_lock_num HIMMEL_VM_QUEUE_STALE_AFTER_CEILING \
    "${HIMMEL_VM_QUEUE_STALE_AFTER_CEILING:-$HIMMEL_VM_LOCK_TTL}" "$HIMMEL_VM_LOCK_TTL" 1)
HIMMEL_VM_QUEUE_STALE_AFTER=$(( 10#$HIMMEL_VM_LOCK_WAIT_INTERVAL * 3 ))
[ "$HIMMEL_VM_QUEUE_STALE_AFTER" -gt "$HIMMEL_VM_QUEUE_STALE_AFTER_CEILING" ] \
    && HIMMEL_VM_QUEUE_STALE_AFTER="$HIMMEL_VM_QUEUE_STALE_AFTER_CEILING"

# Set by vm_lock_acquire when its refusal is PERMANENT (a safety refusal
# waiting cannot clear — a symlinked lock path, a non-lock directory, a
# failed reclaim) as opposed to "someone else holds it," which waiting is
# for. Read by vm_lock_acquire_waiting to stop burning its budget on a
# condition no amount of waiting resolves.
HIMMEL_VM_LOCK_PERMANENT=0

# When 1, vm_lock_acquire suppresses its REFUSED verdict line (NOTE: and
# RECLAIM ERROR: lines still print) — set by the waiting loop for its silent
# retries, so a held lock (the EXPECTED state under a wait budget) does not
# flood the log with the same verdict every poll interval. The FINAL attempt
# in vm_lock_acquire_waiting is always loud.
HIMMEL_VM_LOCK_QUIET=0

# --- per-lock-name ownership (CR finding codex-1) --------------------------
# This is the SAME SHAPE PR-A's suite lock spent multiple CR rounds closing:
# a value that belongs to a SPECIFIC LOCK was being kept somewhere that
# belongs to the PROCESS. A single scalar HIMMEL_VM_LOCK_HELD="$dir" cannot
# represent "this process holds BOTH the clone lock and the nested
# himmel-vm-registry lock at once" — acquiring the second silently
# overwrote the first's record, so releasing the second cleared ownership
# of BOTH: the clone lock was never dropped (leaked until its TTL), and a
# later acquire of that same name self-deadlocked against its own live pid.
#
# Two SEPARATE stores now, each keyed by lock dir, for two SEPARATE jobs:
#
#   HIMMEL_VM_LOCK_HELD — an EXPORTABLE, colon-delimited SET of dirs
#   ("" | ":dir1:" | ":dir1:dir2:" ...), membership-tested via
#   _vm_lock_is_held. Bash cannot export an associative array, and the
#   re-entrancy guard (a nested call, or a child process whose parent
#   already holds this exact lock) must survive across that process
#   boundary — a delimited string is the same "exported string" shape the
#   original design already relied on, generalised from one slot to a set.
#
#   _VM_LOCK_GEN — a bash associative array, dir -> the EXACT raw owner-file
#   content THIS process itself read at the moment it won the lock. Never
#   exported (cannot be, and must not be: only the process that actually
#   performed the acquire may release, exactly mirroring the original
#   suite_lock_owned scalar gate — generalised per name here since more
#   than one name can be genuinely owned by this process at once). Consumed
#   by vm_lock_release's CAS-protected drop (codex-8, see that function).
declare -A _VM_LOCK_GEN

_vm_lock_is_held() {
    case ":${HIMMEL_VM_LOCK_HELD:-}:" in
        *":$1:"*) return 0 ;;
        *) return 1 ;;
    esac
}

# _vm_lock_mark_held <dir> — add <dir> to the held-set and record ITS OWN
# raw owner-file content (read fresh, right now, at the moment of winning
# it) as this process's remembered generation for that dir. Idempotent.
_vm_lock_mark_held() {
    local dir="$1"
    _vm_lock_is_held "$dir" || HIMMEL_VM_LOCK_HELD="${HIMMEL_VM_LOCK_HELD:+$HIMMEL_VM_LOCK_HELD:}$dir"
    export HIMMEL_VM_LOCK_HELD
    _VM_LOCK_GEN["$dir"]="$(_vm_lock_owner_raw "$dir")"
}

# _vm_lock_unmark_held <dir> — remove <dir> from the held-set and forget its
# remembered generation, regardless of whether this process's own drop
# actually ran (a lock we no longer hold — because we dropped it, or
# because a reclaimer already took it over — is equally "not held" from
# here on).
_vm_lock_unmark_held() {
    local dir="$1" part new=""
    local IFS=:
    for part in ${HIMMEL_VM_LOCK_HELD:-}; do
        [ "$part" = "$dir" ] && continue
        new="${new:+$new:}$part"
    done
    HIMMEL_VM_LOCK_HELD="$new"
    export HIMMEL_VM_LOCK_HELD
    unset "_VM_LOCK_GEN[$dir]"
}

_vm_lock_path() { printf '%s/himmel-vm-lock-%s' "$HIMMEL_VM_LOCK_DIR" "$1"; }

_vm_lock_host() { printf '%s' "${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"; }

_vm_lock_same_host() {
    [ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" = \
      "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" ]
}

# _vm_lock_probe_pid <pid> — 0 alive-or-unknown-owner, 1 CONFIRMED dead
# (ESRCH — "No such process"), 2 refused for any other reason (EPERM etc,
# proves nothing). Mirrors the suite lock's own three-way classification
# exactly: only ESRCH may ever be read as death.
_vm_lock_probe_pid() {
    local err rc=0
    err=$(kill -0 "$1" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] && return 0
    case "$err" in
        *"No such process"*) return 1 ;;
        *) return 2 ;;
    esac
}

# _vm_lock_drop <dir> — remove a lock/ticket dir, but ONLY one holding
# exactly a lone `owner` file (or nothing) — never touches a symlink or a
# directory carrying anything else, so a mis-set HIMMEL_VM_LOCK_DIR pointed
# at a real, unrelated directory is never blown away.
_vm_lock_drop() {
    local f
    [ -L "$1" ] && return 1
    for f in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        if [ -e "$f" ] || [ -L "$f" ]; then
            case "$f" in
                "$1"/owner) ;;
                *) return 1 ;;
            esac
        fi
    done
    rm -f "$1/owner" 2>/dev/null
    rmdir "$1" 2>/dev/null
}

_vm_lock_dir_empty() {
    local f
    for f in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        if [ -e "$f" ] || [ -L "$f" ]; then return 1; fi
    done
    return 0
}

_vm_lock_owner_raw() { cat "$1/owner" 2>/dev/null || printf ''; }

_vm_lock_owner_field() {
    # $1 file, $2 key -> value (empty when absent). CR finding codex-5
    # (round 4): the explicit `-f` guard avoids bash's own "No such file"
    # diagnostic for a failed `<` redirection leaking to stderr ahead of
    # the trailing `2>/dev/null` on the SAME command — redirections are
    # set up left-to-right, so the failed read redirect is reported
    # before the later one ever takes effect. Harmless before this round
    # (this function was rarely asked about a not-yet-existing file), but
    # _vm_lock_wait_brand now polls it in a tight loop against exactly
    # that case, which would otherwise spam stderr for the length of
    # every wait.
    local k v
    [ -f "$1" ] || { printf ''; return 0; }
    while IFS='=' read -r k v; do
        [ "$k" = "$2" ] && { printf '%s' "$v"; return 0; }
    done < "$1" 2>/dev/null
    printf ''
}

# _vm_lock_wait_brand <dir> — a brief grace window for a just-`mkdir`'d
# directory to get its `owner` file COMPLETELY branded, not merely
# present. CR finding codex-5 (round 4): waiting for mere EXISTENCE let a
# contender observe `owner` in the empty/partial window `_vm_lock_claim`
# used to leave open between creating the file and finishing the write,
# and misjudge a live, just-won acquisition as an unbranded stranded
# claim. Completeness means a parseable `started=` field — every writer
# emits one before it is done. Returns 0 once complete; 1 if the grace
# window expires first, whether `owner` never appeared at all or appeared
# but never finished — a caller must NOT treat those two outcomes as
# equivalent: only "never appeared" is safe to read as abandoned (see
# _vm_lock_reclaim).
_vm_lock_wait_brand() {
    local s=0
    while [ "$s" -lt 20 ]; do
        case "$(_vm_lock_owner_field "$1/owner" started)" in
            ''|*[!0-9]*) ;;
            *) return 0 ;;
        esac
        sleep 0.05
        s=$((s + 1))
    done
    case "$(_vm_lock_owner_field "$1/owner" started)" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# _vm_lock_claim <dir> <extra-fields...> — mkdir, then brand the owner
# file (set -C is the real arbiter, not the mkdir — see the header
# divergence note on uutils). CR finding codex-5 (round 4): "atomically
# brand" overstated what this used to do — the write ran FOUR separate
# printfs inside a `{ ... }` GROUP redirected as a whole, so `owner` was
# created EMPTY the instant the group's redirection opened, with
# `$(_vm_lock_host)`/`$(date +%s)` each forking a subprocess before the
# rest of the content ever landed — a real, milliseconds-wide window in
# which a contender polling for mere existence (the old
# _vm_lock_wait_brand) could catch `owner` half-written and misjudge a
# live acquisition as an unbranded stranded claim. The whole payload is
# now built into a variable FIRST — both substitutions run to completion
# before `owner` is ever opened — then written with a single `printf
# '%s'`: one write, not four, collapsing the create-to-complete window to
# as small as a shell command gets (not a literal guarantee of atomicity,
# which is why the reader above still waits for completeness rather than
# assuming existence implies it). Returns 0 only when THIS process is the
# branded owner.
_vm_lock_claim() {
    local dir="$1"; shift
    mkdir "$dir" 2>/dev/null || return 1
    local payload
    payload=$(
        printf 'pid=%s\n' "$$"
        printf 'host=%s\n' "$(_vm_lock_host)"
        printf 'started=%s\n' "$(date +%s)"
        printf '%s\n' "$@"
    )
    if ! ( set -C; printf '%s\n' "$payload" > "$dir/owner" ) 2>/dev/null; then
        [ -e "$dir/owner" ] || rmdir "$dir" 2>/dev/null
        return 1
    fi
    return 0
}

# _vm_lock_reclaim <dir> <expected-owner-raw> — the same CAS takeover
# protocol as the suite lock: mkdir a `.claim` sibling (exclusive right to
# take over), re-verify the lock's generation is still the one judged
# abandoned, and only then drop + reclaim. rc 0 = now ours; rc 1 = confirmed
# contention (another taker won, or the lock changed hands under us — an
# ordinary race, retry later); rc 2 = an operational failure (reason printed
# to stderr, prefixed RECLAIM ERROR).
_vm_lock_reclaim() {
    local dir="$1" expected="$2" claim="${1}.claim" rc=1

    if ! mkdir "$claim" 2>/dev/null; then
        local c_started c_age=-1
        if _vm_lock_wait_brand "$claim"; then
            c_started=$(_vm_lock_owner_field "$claim/owner" started)
            case "$c_started" in
                ''|*[!0-9]*) ;;
                *) c_age=$(( $(date +%s) - 10#$c_started )) ;;
            esac
            if [ "$c_age" -ge 0 ] && [ "$c_age" -lt 120 ]; then
                return 1
            fi
        elif [ -f "$claim/owner" ]; then
            # CR finding codex-5 (round 4): _vm_lock_wait_brand's grace
            # window expired but `owner` DOES exist — an in-flight brand
            # (or, worst case, a partial-write corruption), never a
            # confirmed-crashed claimant. c_age would read -1 here exactly
            # like a truly stranded claim's would, so without this branch
            # the code below would drop a claim someone else is actively
            # writing. Treat it exactly like a young claim instead: back
            # off, do NOT fall through to the stranded-claim drop below.
            # Only a claim whose `owner` never appeared at all gets that
            # far.
            return 1
        fi
        if ! _vm_lock_drop "$claim"; then
            echo "RECLAIM ERROR: could not clear a stranded takeover claim at $claim" >&2
            return 2
        fi
        if ! mkdir "$claim" 2>/dev/null; then
            _vm_lock_wait_brand "$claim" && return 1
            echo "RECLAIM ERROR: could not create a takeover claim at $claim" >&2
            return 2
        fi
    fi
    if ! ( set -C; printf 'pid=%s\nhost=%s\nstarted=%s\n' "$$" "$(_vm_lock_host)" "$(date +%s)" \
            > "$claim/owner" ) 2>/dev/null; then
        [ -f "$claim/owner" ] && return 1
        rmdir "$claim" 2>/dev/null
        echo "RECLAIM ERROR: could not brand the takeover claim at $claim" >&2
        return 2
    fi

    if [ "$(_vm_lock_owner_raw "$dir")" = "$expected" ]; then
        if _vm_lock_drop "$dir"; then
            if _vm_lock_claim "$dir"; then
                rc=0
            elif _vm_lock_wait_brand "$dir"; then
                rc=1
            else
                echo "RECLAIM ERROR: dropped the abandoned lock at $dir but could not re-acquire it" >&2
                rc=2
            fi
        else
            echo "RECLAIM ERROR: $dir holds more than a lone owner file — not a vm-lock; refusing to delete it" >&2
            rc=2
        fi
    fi
    _vm_lock_drop "$claim"
    return "$rc"
}

# vm_lock_acquire <name> — ONE immediate attempt. 0 to proceed, 1 to refuse
# (HIMMEL_VM_LOCK_PERMANENT tells the caller whether waiting could help).
vm_lock_acquire() {
    local name="$1" dir; dir=$(_vm_lock_path "$name")
    HIMMEL_VM_LOCK_PERMANENT=0
    [ "$HIMMEL_VM_LOCK" = "0" ] && return 0
    _vm_lock_is_held "$dir" && return 0

    if [ -L "$dir" ]; then
        [ "$HIMMEL_VM_LOCK_QUIET" -eq 1 ] || echo "REFUSED: $dir is a symlink — the vm-lock must be a real directory (check HIMMEL_VM_LOCK_DIR)." >&2
        HIMMEL_VM_LOCK_PERMANENT=1
        return 1
    fi
    mkdir -p "$(dirname "$dir")" 2>/dev/null

    if _vm_lock_claim "$dir"; then
        _vm_lock_mark_held "$dir"
        return 0
    fi

    _vm_lock_wait_brand "$dir"
    if [ ! -f "$dir/owner" ]; then
        if ! _vm_lock_dir_empty "$dir"; then
            [ "$HIMMEL_VM_LOCK_QUIET" -eq 1 ] || echo "REFUSED: $dir exists, has no owner file, and is not empty — this does not look like a vm-lock. Check HIMMEL_VM_LOCK_DIR." >&2
            HIMMEL_VM_LOCK_PERMANENT=1
            return 1
        fi
        if _vm_lock_reclaim "$dir" ""; then
            _vm_lock_mark_held "$dir"
            return 0
        fi
    fi

    local o_raw o_pid o_host o_started now age=-1 dated=0
    o_raw=$(_vm_lock_owner_raw "$dir")
    o_pid=$(_vm_lock_owner_field "$dir/owner" pid)
    case "$o_pid" in *[!0-9]*) o_pid='' ;; esac
    o_host=$(_vm_lock_owner_field "$dir/owner" host)
    o_started=$(_vm_lock_owner_field "$dir/owner" started)
    now=$(date +%s)
    case "$o_started" in
        ''|*[!0-9]*) ;;
        *) age=$(( now - 10#$o_started )); dated=1 ;;
    esac

    local stale=0 this_host same_host=0
    this_host=$(_vm_lock_host)
    _vm_lock_same_host "$o_host" "$this_host" && same_host=1
    if [ -n "$o_pid" ] && [ "$same_host" -eq 1 ]; then
        local probe_rc=0
        _vm_lock_probe_pid "$o_pid" || probe_rc=$?
        [ "$probe_rc" -eq 1 ] && stale=1
    fi
    [ "$dated" -eq 1 ] && [ "$age" -ge "$HIMMEL_VM_LOCK_TTL" ] && stale=1
    if [ "$dated" -eq 0 ]; then
        { [ -z "$o_pid" ] || [ "$same_host" -eq 0 ]; } && stale=1
    fi

    if [ "$stale" -eq 1 ]; then
        local reclaim_rc=0
        _vm_lock_reclaim "$dir" "$o_raw" || reclaim_rc=$?
        if [ "$reclaim_rc" -eq 0 ]; then
            echo "NOTE: cleared an abandoned vm-lock for '$name' (pid=${o_pid:-?} host=${o_host:-?} age=${age}s)" >&2
            _vm_lock_mark_held "$dir"
            return 0
        fi
        if [ "$reclaim_rc" -eq 2 ]; then
            HIMMEL_VM_LOCK_PERMANENT=1
            [ "$HIMMEL_VM_LOCK_QUIET" -eq 1 ] || echo "REFUSED: could not take over the vm-lock for '$name' — reclaim failed (RECLAIM ERROR above)." >&2
            return 1
        fi
        [ "$HIMMEL_VM_LOCK_QUIET" -eq 1 ] || echo "REFUSED: lost the race to take over the vm-lock for '$name' — another run claimed it; nothing wedged, retry." >&2
        return 1
    fi

    [ "$HIMMEL_VM_LOCK_QUIET" -eq 1 ] || echo "REFUSED: another run holds the vm-lock for '$name' (pid=${o_pid:-unknown} host=${o_host:-unknown} age=${age}s), TTL ${HIMMEL_VM_LOCK_TTL}s. HIMMEL_VM_LOCK=0 opts out; HIMMEL_VM_LOCK_WAIT=<seconds> queues for it." >&2
    return 1
}

# --- FIFO queue (pid-named tickets under <lock>.q/) -------------------------

_vm_lock_queue_dir() { printf '%s.q' "$(_vm_lock_path "$1")"; }

HIMMEL_VM_QUEUE_TICKET_DIR=""
HIMMEL_VM_QUEUE_TICKET_STARTED=""
HIMMEL_VM_QUEUE_BLOCKER_PID=""
HIMMEL_VM_QUEUE_BLOCKER_HOST=""

_vm_lock_queue_brand() {
    # <ticket-dir> <started> <stale_after> — atomic write-then-rename, same
    # as the suite lock: never a partial owner file, and a crash between the
    # two leaves only harmless litter beside the ticket.
    local dir="$1" started="$2" stale_after="$3" tmp
    tmp="$(dirname "$dir")/.brand.$$.tmp"
    if ! { printf 'pid=%s\n' "$$"
           printf 'host=%s\n' "$(_vm_lock_host)"
           printf 'started=%s\n' "$started"
           printf 'stale_after=%s\n' "$stale_after"
           printf 'seen=%s\n' "$(date +%s)"
         } > "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    mv -f "$tmp" "$dir/owner" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

_vm_lock_queue_resolve_stale_after() {
    # A ticket's OWN stale_after wins, verbatim, up to the absolute ceiling —
    # never recomputed from the reader's own interval (the original's round
    # 8/9 fix: a reader-relative cap prunes a healthy differently-configured
    # waiter).
    case "$1" in
        ''|*[!0-9]*) printf '%s' "$HIMMEL_VM_QUEUE_STALE_AFTER"; return 0 ;;
    esac
    local v=$(( 10#$1 ))
    if [ "$v" -le 0 ] || [ "$v" -gt "$HIMMEL_VM_QUEUE_STALE_AFTER_CEILING" ]; then
        printf '%s' "$HIMMEL_VM_QUEUE_STALE_AFTER"
    else
        printf '%s' "$v"
    fi
}

# vm_lock_queue_join <name> — take a ticket at <lock>.q/$$. Always returns 0
# (a ticket is a fairness nicety, never a hard gate — failure to get one
# just means this run proceeds unticketed, same posture as the original).
vm_lock_queue_join() {
    local qdir; qdir=$(_vm_lock_queue_dir "$1")
    local tdir="$qdir/$$" stamp
    mkdir -p "$qdir" 2>/dev/null || return 0
    mkdir "$tdir" 2>/dev/null || return 0
    stamp=$(date +%s)
    if ! _vm_lock_queue_brand "$tdir" "$stamp" "$HIMMEL_VM_QUEUE_STALE_AFTER"; then
        rmdir "$tdir" 2>/dev/null
        return 0
    fi
    HIMMEL_VM_QUEUE_TICKET_DIR="$tdir"
    HIMMEL_VM_QUEUE_TICKET_STARTED="$stamp"
    return 0
}

vm_lock_queue_leave() {
    [ -n "$HIMMEL_VM_QUEUE_TICKET_DIR" ] || return 0
    _vm_lock_drop "$HIMMEL_VM_QUEUE_TICKET_DIR"
    HIMMEL_VM_QUEUE_TICKET_DIR=""
    HIMMEL_VM_QUEUE_TICKET_STARTED=""
}

# _vm_lock_queue_ticket_dead <dir> — judged on `seen` (liveness), NEVER
# `started` (ordering) — a healthy waiter refreshes `seen` every
# HIMMEL_VM_LOCK_WAIT_INTERVAL, comfortably under its own stale_after, no
# matter how long the total wait; a wedged one stops refreshing and ages out
# exactly like a wedged lock holder does against the TTL.
_vm_lock_queue_ticket_dead() {
    local dir="$1" o_pid o_host o_seen o_stale_after now age=-1 dated=0 same_host=0 probe_rc=0
    _vm_lock_wait_brand "$dir" || return 0
    o_pid=$(_vm_lock_owner_field "$dir/owner" pid)
    case "$o_pid" in *[!0-9]*) o_pid='' ;; esac
    o_host=$(_vm_lock_owner_field "$dir/owner" host)
    o_seen=$(_vm_lock_owner_field "$dir/owner" seen)
    case "$o_seen" in ''|*[!0-9]*) o_seen=$(_vm_lock_owner_field "$dir/owner" started) ;; esac
    o_stale_after=$(_vm_lock_queue_resolve_stale_after "$(_vm_lock_owner_field "$dir/owner" stale_after)")
    now=$(date +%s)
    case "$o_seen" in
        ''|*[!0-9]*) ;;
        *) age=$(( now - 10#$o_seen )); dated=1 ;;
    esac
    _vm_lock_same_host "$o_host" "$(_vm_lock_host)" && same_host=1
    if [ -n "$o_pid" ] && [ "$same_host" -eq 1 ]; then
        _vm_lock_probe_pid "$o_pid" || probe_rc=$?
        [ "$probe_rc" -eq 1 ] && return 0
    fi
    [ "$dated" -eq 1 ] && [ "$age" -ge "$o_stale_after" ] && return 0
    if [ "$dated" -eq 0 ] && { [ -z "$o_pid" ] || [ "$same_host" -eq 0 ]; }; then
        return 0
    fi
    return 1
}

vm_lock_queue_prune() {
    local qdir; qdir=$(_vm_lock_queue_dir "$1")
    local f
    [ -d "$qdir" ] || return 0
    for f in "$qdir"/*; do
        [ -d "$f" ] || continue
        case "${f##*/}" in ''|*[!0-9]*) continue ;; esac
        [ "$f" = "$HIMMEL_VM_QUEUE_TICKET_DIR" ] && continue
        _vm_lock_queue_ticket_dead "$f" && _vm_lock_drop "$f"
    done
}

vm_lock_queue_live_count() {
    local qdir; qdir=$(_vm_lock_queue_dir "$1")
    local f n=0
    if [ -d "$qdir" ]; then
        vm_lock_queue_prune "$1"
        for f in "$qdir"/*; do
            [ -d "$f" ] || continue
            case "${f##*/}" in ''|*[!0-9]*) continue ;; esac
            n=$((n + 1))
        done
    fi
    printf '%s' "$n"
}

# vm_lock_queue_is_our_turn <name> — 0 when no older LIVE ticket is ahead of
# ours (ties broken by pid, same as the original). Refreshes our own
# ticket's `seen` on every call.
vm_lock_queue_is_our_turn() {
    HIMMEL_VM_QUEUE_BLOCKER_PID=""
    HIMMEL_VM_QUEUE_BLOCKER_HOST=""
    [ -n "$HIMMEL_VM_QUEUE_TICKET_DIR" ] || return 0
    vm_lock_queue_prune "$1"

    local my_started
    my_started=$(_vm_lock_owner_field "$HIMMEL_VM_QUEUE_TICKET_DIR/owner" started)
    case "$my_started" in
        ''|*[!0-9]*)
            # Pruned out from under us (past our own stale_after) — restore
            # at the CACHED original `started`, never a fresh stamp, so we
            # keep our queue position instead of going to the back of the
            # line (mirrors the original's round-6 fix exactly).
            my_started=""
            if [ -n "$HIMMEL_VM_QUEUE_TICKET_STARTED" ]; then
                mkdir -p "$HIMMEL_VM_QUEUE_TICKET_DIR" 2>/dev/null
                if _vm_lock_queue_brand "$HIMMEL_VM_QUEUE_TICKET_DIR" \
                        "$HIMMEL_VM_QUEUE_TICKET_STARTED" "$HIMMEL_VM_QUEUE_STALE_AFTER"; then
                    my_started="$HIMMEL_VM_QUEUE_TICKET_STARTED"
                fi
            fi
            case "$my_started" in
                ''|*[!0-9]*) return 0 ;;   # fail-open for this one poll, retried next
            esac
            ;;
        *)
            _vm_lock_queue_brand "$HIMMEL_VM_QUEUE_TICKET_DIR" "$my_started" \
                "$(_vm_lock_queue_resolve_stale_after "$(_vm_lock_owner_field "$HIMMEL_VM_QUEUE_TICKET_DIR/owner" stale_after)")"
            ;;
    esac

    local qdir; qdir=$(_vm_lock_queue_dir "$1")
    local f pid started host blocked=0 have_best=0 best_started=0 best_pid=0
    for f in "$qdir"/*; do
        [ -d "$f" ] || continue
        [ "$f" = "$HIMMEL_VM_QUEUE_TICKET_DIR" ] && continue
        pid="${f##*/}"
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        started=$(_vm_lock_owner_field "$f/owner" started)
        host=$(_vm_lock_owner_field "$f/owner" host)
        case "$started" in
            ''|*[!0-9]*)
                blocked=1
                if [ "$have_best" -eq 0 ]; then
                    HIMMEL_VM_QUEUE_BLOCKER_PID="$pid"
                    HIMMEL_VM_QUEUE_BLOCKER_HOST="$host"
                fi
                continue
                ;;
        esac
        if [ "$started" -lt "$my_started" ] || \
           { [ "$started" -eq "$my_started" ] && [ "$pid" -lt "$$" ]; }; then
            blocked=1
            if [ "$have_best" -eq 0 ] || [ "$started" -lt "$best_started" ] || \
               { [ "$started" -eq "$best_started" ] && [ "$pid" -lt "$best_pid" ]; }; then
                have_best=1
                best_started="$started"
                best_pid="$pid"
                HIMMEL_VM_QUEUE_BLOCKER_PID="$pid"
                HIMMEL_VM_QUEUE_BLOCKER_HOST="$host"
            fi
        fi
    done
    [ "$blocked" -eq 1 ] && return 1
    return 0
}

# vm_lock_acquire_waiting <name> — the public entry point. 0 acquired; 2
# refused instantly/permanently; 5 waited the full HIMMEL_VM_LOCK_WAIT budget
# and gave up. Prints one unambiguous `VM-LOCK-WAIT EXPIRED after Ns —
# vm-lock '<name>' NOT acquired` line on stdout in the give-up case — a
# distinct literal prefix from the suite lock's `LOCK-WAIT EXPIRED`, so a
# console monitor can grep either without conflating the two lock domains.
vm_lock_acquire_waiting() {
    local name="$1"

    if [ "$HIMMEL_VM_LOCK_WAIT" -le 0 ]; then
        # Disabled / re-entrant: bypass EVERYTHING, including the queue-yield
        # check below, in this exact order — the original's round-2 deadlock
        # finding, applied here: a nested call is not a queue jumper.
        if [ "$HIMMEL_VM_LOCK" = "0" ] || _vm_lock_is_held "$(_vm_lock_path "$name")"; then
            vm_lock_acquire "$name" && return 0
            return 2
        fi
        local qcount; qcount=$(vm_lock_queue_live_count "$name")
        if [ "$qcount" -gt 0 ]; then
            [ "$HIMMEL_VM_LOCK_QUIET" -eq 1 ] || echo "REFUSED: $qcount queued waiter(s) already ahead for vm-lock '$name' — this is a no-wait attempt, it yields to them rather than cutting in line. HIMMEL_VM_LOCK_WAIT=<seconds> to queue instead." >&2
            return 2
        fi
        vm_lock_acquire "$name" && return 0
        return 2
    fi

    # Same short-circuits, same reason, before suite_lock_queue_join ever
    # runs — see the header note. Spelled identically to the no-wait branch
    # above on purpose (a literal copy, not a shared helper): the two must
    # never silently drift apart.
    if [ "$HIMMEL_VM_LOCK" = "0" ] || _vm_lock_is_held "$(_vm_lock_path "$name")"; then
        vm_lock_acquire "$name" && return 0
        return 2
    fi

    local start deadline now waited nap remaining
    start=$(date +%s)
    deadline=$(( start + 10#$HIMMEL_VM_LOCK_WAIT ))
    vm_lock_queue_join "$name"

    HIMMEL_VM_LOCK_QUIET=1
    while :; do
        if vm_lock_queue_is_our_turn "$name" && vm_lock_acquire "$name"; then
            HIMMEL_VM_LOCK_QUIET=0
            waited=$(( $(date +%s) - start ))
            [ "$waited" -gt 0 ] && echo "ACQUIRED: got the vm-lock for '$name' after waiting ${waited}s." >&2
            vm_lock_queue_leave
            return 0
        fi
        now=$(date +%s)
        [ "$HIMMEL_VM_LOCK_PERMANENT" -eq 1 ] && break
        [ "$now" -ge "$deadline" ] && break
        echo "WAITING: vm-lock '$name' still contended (waited $(( now - start ))s of ${HIMMEL_VM_LOCK_WAIT}s budget)..." >&2
        nap="$HIMMEL_VM_LOCK_WAIT_INTERVAL"
        remaining=$(( deadline - now ))
        [ "$nap" -gt "$remaining" ] && nap="$remaining"
        sleep "$nap"
    done
    HIMMEL_VM_LOCK_QUIET=0

    if vm_lock_queue_is_our_turn "$name" && vm_lock_acquire "$name"; then
        waited=$(( $(date +%s) - start ))
        echo "ACQUIRED: got the vm-lock for '$name' after waiting ${waited}s." >&2
        vm_lock_queue_leave
        return 0
    fi
    if [ "$HIMMEL_VM_LOCK_PERMANENT" -eq 1 ]; then
        echo "NOT QUEUED: the refusal above is a safety refusal, not a held lock — waiting cannot clear it." >&2
        vm_lock_queue_leave
        return 2
    fi
    waited=$(( $(date +%s) - start ))
    if [ -n "$HIMMEL_VM_QUEUE_BLOCKER_PID" ]; then
        echo "GAVE UP: waited ${waited}s for vm-lock '$name' — still behind an older waiter (pid=$HIMMEL_VM_QUEUE_BLOCKER_PID host=${HIMMEL_VM_QUEUE_BLOCKER_HOST:-unknown})." >&2
    else
        echo "GAVE UP: waited ${waited}s for vm-lock '$name' and it is still held." >&2
    fi
    printf 'VM-LOCK-WAIT EXPIRED after %ss — vm-lock '"'"'%s'"'"' NOT acquired\n' "$waited" "$name"
    vm_lock_queue_leave
    return 5
}

# _vm_lock_release_cas <dir> <expected-raw> — CAS-protected drop (CR finding
# codex-8). Re-reading pid/host and then dropping in two unprotected steps
# has a live window: a TTL reclaim can land BETWEEN the check and the
# `_vm_lock_drop`, so the drop that follows deletes the SUCCESSOR's fresh
# lock, not the generation we just confirmed was ours — the exact failure
# the CAS exists to prevent, reintroduced by not actually being atomic
# against it. This reuses the SAME `.claim` mkdir mutual-exclusion
# `_vm_lock_reclaim` uses for takeover, applied to release instead: win the
# exclusive right to mutate <dir> FIRST, re-verify its raw content is STILL
# byte-identical to <expected-raw> (captured at OUR OWN acquire time, not
# re-derived from separately-read fields), and only then drop. A claim
# already held means a reclaimer is mutating <dir> RIGHT NOW — back off
# without deleting anything; from here that lock is not ours either way.
#
# The mkdir alone only wins the mutex; it does not yet make this a claim
# `_vm_lock_reclaim` recognises as live. An unbranded claim is not a WEAKER
# claim, it is no claim at all: `_vm_lock_reclaim`'s own `mkdir "$claim"`
# fails on our directory entry, but `_vm_lock_wait_brand` then times out
# waiting for `$claim/owner`, `c_age` is left at -1, the `[ "$c_age" -ge 0 ]`
# guard fails, and the reclaimer treats OUR release-claim as stranded —
# dropping it and taking over, right in the window this CAS exists to close.
# So brand immediately (CR finding codex-4), with the SAME `set -C` write
# shape `_vm_lock_reclaim` uses. If branding itself fails, back off without
# dropping anything: we cannot prove the claim is still ours to delete, and
# leaving it for the TTL reclaim to eventually clear is the fail-safe
# direction — a lock held too long, never a lock lost.
_vm_lock_release_cas() {
    local dir="$1" expected="$2" claim="${1}.claim"
    if ! mkdir "$claim" 2>/dev/null; then
        return 0
    fi
    if ! ( set -C; printf 'pid=%s\nhost=%s\nstarted=%s\n' "$$" "$(_vm_lock_host)" "$(date +%s)" \
            > "$claim/owner" ) 2>/dev/null; then
        return 0
    fi
    if [ "$(_vm_lock_owner_raw "$dir")" = "$expected" ]; then
        _vm_lock_drop "$dir"
    fi
    _vm_lock_drop "$claim"
    return 0
}

# vm_lock_release <name> — safe to call unconditionally (from a trap, or on
# a name this process never held): only a name THIS process itself recorded
# acquiring (present in _VM_LOCK_GEN — never exported, so a re-entrant CHILD
# that only inherited the HELD-set string never attempts a release it does
# not own, same gate shape as the original's `suite_lock_owned` scalar,
# generalised per lock name) is ever a candidate for deletion, and even then
# only via the CAS-protected drop above.
vm_lock_release() {
    local name="$1" dir; dir=$(_vm_lock_path "$name")
    local gen="${_VM_LOCK_GEN[$dir]:-}"
    if [ -n "$gen" ]; then
        _vm_lock_release_cas "$dir" "$gen"
    fi
    _vm_lock_unmark_held "$dir"
}
