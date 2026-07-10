#!/usr/bin/env bash
# queue-lock.sh -- structural one-writer-per-queue lock for armed/overnight
# sessions (HIMMEL-856).
#
# WHY: on 2026-07-10 two armed sessions (fleet-parallel-27 + vm-inflight-s28,
# plus a 3rd sibling) double-fired on the SAME queue and coordinated by
# PROSE (prove-before-start, a coordination markdown file, per-incident
# division locks written mid-flight) -- which failed three ways in one
# night (duplicate dispatch, duplicate shipping, coordination-by-append
# races). Per the enforcement-strength convention (HIMMEL-195): a rule
# that drifts >=2 times escalates to STRUCTURAL. This is that escalation
# for the queue-level collision -- see the design doc referenced from
# HIMMEL-856 for the full mechanism and the phase-2/3 rollout this seeds.
#
# USAGE (invoke as a script, one verb per call):
#   bash queue-lock.sh acquire   <handover-path> [session-id]
#   bash queue-lock.sh heartbeat <handover-path> <session-token>
#   bash queue-lock.sh release   <handover-path> <session-token>
#   bash queue-lock.sh status    <handover-path>
#
# TOKEN CONTRACT (HIMMEL-856 CR, C1): `acquire` records a session token in
# owner.json (the given session-id, or a generated "<hostname>-pid<pid>")
# and PRINTS it as the last stdout line: "release-token: <token>". The
# caller must capture that line and pass the token to `heartbeat` and
# `release` -- both REFUSE (rc=2, holder info printed) without it or with
# a token that does not match the current holder. The token is mandatory
# because separate script invocations cannot re-derive a stable
# per-session id (a fresh pid would silently "prove" nothing), and a
# token-less release could rm another session's LIVE lock -- the exact
# incident class this script exists to prevent. Emergency override when
# the token is lost: QUEUE_LOCK_FORCE_RELEASE=1 releases regardless,
# loudly, and logs the forced release to the queue-level
# .locks/queue/takeovers.log.
#
# LOCK LOCATION: a DIRECTORY (mkdir is atomic -- no TOCTOU race between
# "check" and "create", works on NTFS/Git-Bash without relying on O_EXCL)
# at:
#   <handover-root>/.locks/queue/<queue-slug>.lock/
# containing owner.json (current holder) and, after any takeover,
# takeovers.log (append-only trail -- the "loud trail" the design
# principles require instead of failing closed). <handover-root> is
# resolved via scripts/lib/handover-path.sh's handover_root_ensure, so
# this follows the same single-root convention every other
# scripts/handover/*.sh script uses (Mode A inline vs Mode B external
# HANDOVER_DIR) -- see scripts/handover/CLAUDE.md.
#
# QUEUE SLUG: the handover path relativized against the handover root (or
# used as-is if it doesn't fall under the root), with path separators
# folded to "__" and every other non [A-Za-z0-9_-] character replaced by
# "-". Sibling sessions of one epic (different next-session-N.md files)
# get DIFFERENT slugs on purpose -- this lock catches the SAME-queue
# double-fire, not all epic parallelism.
#
# TTL / STALE TAKEOVER: a lock whose heartbeat is older than
# QUEUE_LOCK_TTL_SECONDS (default 21600 = 6 h -- sized to cover the 3-4 h
# overnight-run budget with margin, HIMMEL-856 CR C2; heartbeat refreshes
# are the future tightening lever once wired into the long-session flow)
# is STALE. `acquire` against a stale lock SUPERSEDES automatically (armed
# sessions die, machines sleep -- the design's "fail open with a loud
# trail" principle). `acquire` against a FRESH foreign lock refuses (rc=2)
# unless QUEUE_LOCK_TAKEOVER=1 forces the takeover anyway. Every takeover
# (stale or forced) appends one line to the lock's takeovers.log naming
# the previous and new holder, so the next reader sees the trail. `status`
# warns when a FRESH lock's heartbeat age exceeds half the TTL (aging).
#
# EXIT CODES:
#   acquire:   0  lock acquired (fresh dir, stale takeover, or forced
#                 takeover -- stderr says which); the last stdout line is
#                 "release-token: <token>"
#              1  usage error, OR a genuine environment failure (handover
#                 root unresolvable, mkdir failed for a reason other than
#                 "already held", owner.json could not be written -- the
#                 lock dir is removed again, nothing is acquired)
#              2  refused -- held by a FRESH foreign lock; holder info
#                 printed to stderr. Callers (arm-resume.sh, the overnight
#                 pipeline) treat rc=2 as "work is owned elsewhere: pick a
#                 different queue, or set QUEUE_LOCK_TAKEOVER=1."
#   heartbeat: 0  heartbeat refreshed
#              1  usage error / environment failure (incl. a failed
#                 owner.json rewrite)
#              2  session token missing, no lock held for this queue, OR
#                 held by a DIFFERENT session than the token -- refused
#   release:   0  released (idempotent -- also rc 0 when nothing was held)
#              1  usage error / environment failure / rm failed to clear
#                 an existing lock dir (e.g. an open handle on Windows)
#              2  session token missing or does not match the current
#                 holder -- refused (QUEUE_LOCK_FORCE_RELEASE=1 overrides)
#   status:    0  free
#              1  usage error / environment failure
#              11 held, FRESH (owner.json printed to stdout; a CORRUPT
#                 lock dir -- owner.json missing/unreadable -- also
#                 reports 11, fail-closed, and SAYS it is corrupt)
#              12 held, STALE -- eligible for takeover (owner.json printed)
#
# CONVENTIONS: bash 3.2-safe (no associative arrays, no ${var,,}, no
# mapfile). `set -uo pipefail`, not -e -- callers care about specific exit
# codes. ASCII only in this file (a non-ASCII char on a line a shellcheck
# finding lands on crashes shellcheck -- repo convention).

set -uo pipefail

_QL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/handover-path.sh
# shellcheck disable=SC1091
. "$_QL_SCRIPT_DIR/../lib/handover-path.sh"
# shellcheck source=../lib/py-armor.sh
# shellcheck disable=SC1091
. "$_QL_SCRIPT_DIR/../lib/py-armor.sh"

_ql_usage() {
    cat <<'EOF'
Usage: queue-lock.sh acquire   <handover-path> [session-id]
       queue-lock.sh heartbeat <handover-path> <session-token>
       queue-lock.sh release   <handover-path> <session-token>
       queue-lock.sh status    <handover-path>

acquire prints "release-token: <token>" on success -- capture it and pass
it to heartbeat/release (both refuse without it). Lost the token?
QUEUE_LOCK_FORCE_RELEASE=1 queue-lock.sh release <handover-path>
EOF
}

_ql_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_ql_now_epoch() { date -u +%s; }

# _ql_epoch_of_iso <iso8601> -- print epoch seconds, or empty on failure.
# GNU date first (Git Bash / Linux), BSD date fallback (macOS), armored
# python3 last resort -- same fallback shape as py_armor_mtime.
_ql_epoch_of_iso() {
    local iso="$1" e=""
    e=$(date -u -d "$iso" +%s 2>/dev/null) || e=""
    if [ -z "$e" ]; then
        e=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null) || e=""
    fi
    if [ -z "$e" ]; then
        if py_armor_capture -c 'import sys,datetime
d = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
print(int(d.timestamp()))' "$iso" 2>/dev/null; then
            e="$PY_ARMOR_OUT"
        fi
    fi
    printf '%s' "$e"
}

_ql_hostname() {
    local h=""
    h=$(hostname 2>/dev/null) || h=""
    [ -z "$h" ] && h="${COMPUTERNAME:-${HOSTNAME:-unknown-host}}"
    printf '%s' "$h"
}

_ql_default_session() { printf '%s-pid%s' "$(_ql_hostname)" "$$"; }

_ql_json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# _ql_json_field <file> <key> -- extract a flat string field's value.
# The lock JSON is always single-line, flat, all-string values, so a
# simple grep -o is sufficient (no jq dependency).
_ql_json_field() {
    grep -o "\"$2\":\"[^\"]*\"" "$1" 2>/dev/null | head -1 \
        | sed -e "s/^\"$2\":\"//" -e 's/"$//'
}

# _ql_json_field_str <json-string> <key> -- same extraction from an
# in-memory string. acquire parses ALL fields from ONE captured read
# (o_raw) so the staleness judgment and the CAS takeover verify below
# operate on the same generation -- N separate file reads could straddle
# a concurrent owner.json rewrite.
_ql_json_field_str() {
    printf '%s' "$1" | grep -o "\"$2\":\"[^\"]*\"" 2>/dev/null | head -1 \
        | sed -e "s/^\"$2\":\"//" -e 's/"$//'
}

# _ql_slug <handover-path> -- normalize a handover path to a filesystem-
# safe queue slug. Relativizes against the handover root when the path
# falls under it (the common case); otherwise normalizes the raw path.
# NOTE: "/" folds to "__", so a path containing a literal "__" collides
# with the same path using "/" at that spot -- theoretical only; the repo
# handover naming convention never produces "__" in a path component.
_ql_slug() {
    local p="${1//\\//}"
    p="${p%.md}"
    local root=""
    root=$(handover_root 2>/dev/null) || root=""
    if [ -n "$root" ]; then
        root="${root//\\//}"
        case "$p" in
            "$root"/*) p="${p#"$root"/}" ;;
        esac
    fi
    p=$(printf '%s' "$p" | sed 's#/#__#g')
    printf '%s' "$p" | tr -c 'A-Za-z0-9_-' '-'
}

# _ql_write_owner -- ATOMIC owner.json write (HIMMEL-856 CR, C3): write to
# a tmp file in the lock dir, then mv into place (same-dir file rename --
# atomic; readers never see a torn owner.json), rc-checked at every step.
# Returns 1 on any failure; callers MUST check and never report a
# successful acquire/heartbeat over a failed write -- a torn/absent
# owner.json parses as CORRUPT-held (fail-closed) forever otherwise.
_ql_write_owner() {
    local lockdir="$1" session="$2" host="$3" ho="$4" started="$5" heartbeat="$6"
    local tmp="$lockdir/owner.json.tmp.$$"
    if ! printf '{"session":"%s","host":"%s","handover":"%s","started":"%s","heartbeat":"%s"}\n' \
        "$(_ql_json_escape "$session")" \
        "$(_ql_json_escape "$host")" \
        "$(_ql_json_escape "$ho")" \
        "$started" "$heartbeat" \
        > "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    if ! mv -f "$tmp" "$lockdir/owner.json" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    return 0
}

# _ql_lockdir <handover-path> -- print the absolute lock dir path, or
# nothing (rc 1) if the handover root can't be resolved.
_ql_lockdir() {
    local ho="$1" root=""
    root=$(handover_root_ensure 2>/dev/null) || return 1
    local slug
    slug=$(_ql_slug "$ho")
    printf '%s/.locks/queue/%s.lock' "$root" "$slug"
}

queue_lock_acquire() {
    local ho="${1:-}" session="${2:-}"
    if [ -z "$ho" ]; then
        _ql_usage >&2
        return 1
    fi
    local lockdir
    if ! lockdir=$(_ql_lockdir "$ho"); then
        echo "queue-lock: could not resolve handover root (HANDOVER_DIR unset and no inline handovers/ dir?)" >&2
        return 1
    fi
    session="${session:-$(_ql_default_session)}"
    local host now
    host=$(_ql_hostname)
    now=$(_ql_now_iso)

    # Check the parent mkdir explicitly so a permission failure reports its
    # true cause instead of surfacing later as a misleading lock-mkdir
    # failure (HIMMEL-856 CR suggestion).
    if ! mkdir -p "$(dirname "$lockdir")" 2>/dev/null; then
        echo "queue-lock: cannot create the lock parent dir '$(dirname "$lockdir")' (permissions? a file in the way?)" >&2
        return 1
    fi
    if mkdir "$lockdir" 2>/dev/null; then
        if ! _ql_write_owner "$lockdir" "$session" "$host" "$ho" "$now" "$now"; then
            # C3: never report acquired over a failed owner write -- the
            # torn lock would parse as CORRUPT-held (fail-closed) forever.
            rm -rf "$lockdir" 2>/dev/null
            echo "queue-lock: acquire FAILED -- owner.json could not be written; the lock dir was removed, nothing is acquired" >&2
            return 1
        fi
        echo "queue-lock: acquired (session=$session host=$host)"
        echo "release-token: $session"
        return 0
    fi

    # Lost the mkdir race, but the WINNER may not have finished writing
    # owner.json yet (mkdir-then-write is not a single atomic step) -- a
    # concurrent loser landing in that narrow window would otherwise
    # misread a healthy fresh lock as "corrupt". Bounded spin-wait (up to
    # ~1s) before concluding genuine corruption.
    if [ ! -f "$lockdir/owner.json" ]; then
        local _wait_i=0
        while [ "$_wait_i" -lt 20 ] && [ ! -f "$lockdir/owner.json" ]; do
            sleep 0.05
            _wait_i=$((_wait_i + 1))
        done
    fi
    if [ ! -f "$lockdir/owner.json" ]; then
        echo "queue-lock: lock dir exists but owner.json is missing/corrupt -- refusing (manual cleanup needed at $lockdir)" >&2
        return 1
    fi

    # ONE raw read; every field (and the CAS verify in the takeover branch)
    # derives from this single captured generation.
    local o_raw o_session o_host o_started o_heartbeat
    o_raw=$(cat "$lockdir/owner.json" 2>/dev/null) || o_raw=""
    o_session=$(_ql_json_field_str "$o_raw" session)
    o_host=$(_ql_json_field_str "$o_raw" host)
    o_started=$(_ql_json_field_str "$o_raw" started)
    o_heartbeat=$(_ql_json_field_str "$o_raw" heartbeat)

    local ttl="${QUEUE_LOCK_TTL_SECONDS:-21600}"
    case "$ttl" in ''|*[!0-9]*) ttl=21600 ;; esac
    local hb_epoch now_epoch age=-1 stale=0
    hb_epoch=$(_ql_epoch_of_iso "$o_heartbeat")
    now_epoch=$(_ql_now_epoch)
    if [ -n "$hb_epoch" ] && [ -n "$now_epoch" ]; then
        age=$(( now_epoch - hb_epoch ))
        [ "$age" -lt 0 ] && age=0
        [ "$age" -ge "$ttl" ] && stale=1
    else
        echo "WARN queue-lock: could not parse heartbeat '$o_heartbeat' -- treating as FRESH (fail-closed on unparsable timestamps)" >&2
    fi

    if [ "$stale" -eq 1 ] || [ "${QUEUE_LOCK_TAKEOVER:-}" = "1" ]; then
        local reason
        if [ "$stale" -eq 1 ]; then
            reason="stale (heartbeat age ${age}s >= ttl ${ttl}s)"
        else
            reason="forced (QUEUE_LOCK_TAKEOVER=1, lock is still FRESH)"
        fi
        # ATOMIC TAKEOVER (HIMMEL-856 CR, codex-2): never write into a lock
        # dir we did not just create via mkdir. An in-place owner.json
        # rewrite would let two concurrent stale-acquirers BOTH "win".
        # NOTE: an earlier revision claimed the old dir via `mv` to a
        # graveyard name -- observed UNRELIABLE on MSYS/Git-Bash (rc-0 mv
        # with a missing or empty target under concurrent rename), so the
        # only atomic primitive this takeover trusts is mkdir:
        #   1. mkdir <lockdir>.claim -- the exclusive right to take over
        #      this slug. Exactly one contender wins; every other taker
        #      reports held (rc=2). A crashed taker's claim expires after
        #      120s (dir mtime) and is cleared by the next taker.
        #   2. CAS re-verify UNDER the claim: the lock's owner.json must
        #      still byte-match the generation judged stale above
        #      ($o_raw). A mismatch means the lock changed hands since we
        #      read it (another taker superseded it, or the holder
        #      heartbeat) -- it is LIVE: drop the claim, report held.
        #   3. rm -rf the verified-stale dir, then the normal fresh
        #      `mkdir` acquire + owner.json + takeovers.log trail, then
        #      drop the claim. A fresh acquirer slipping into the
        #      rm->mkdir gap just wins instead of us (exactly one mkdir
        #      succeeds) -- a normal rc-2 loss for us, and a trail-less
        #      but correct single ownership handoff.
        # Residual (accepted, microsecond-scale): a holder judged stale
        # who actively RELEASES between step 2 and step 3, immediately
        # followed by a fresh third-party acquire inside that same window,
        # could have that fresh lock rm'd -- it requires a by-definition
        # dead session to act, plus a third contender, inside a
        # microsecond window; the fail-open TTL design already accepts
        # takeover-vs-revival at far larger windows than this.
        local claim="${lockdir}.claim"
        # Expire a crashed taker's claim: older than 120s by mtime. A
        # failed mtime probe treats the claim as fresh (fail-safe: never
        # clear a claim we cannot age).
        if [ -d "$claim" ]; then
            local claim_mtime claim_age
            claim_mtime=$(py_armor_mtime "$claim")
            if [ -n "$claim_mtime" ] && [ -n "$now_epoch" ]; then
                claim_age=$(( now_epoch - claim_mtime ))
                if [ "$claim_age" -ge 120 ]; then
                    rm -rf "$claim" 2>/dev/null
                fi
            else
                # Probe failed: fail-closed (treat as fresh -- never clear
                # a claim we cannot age) but say so, with the manual escape
                # hatch, instead of a misleading "try again shortly".
                echo "WARN queue-lock: cannot age the takeover claim '$claim' (mtime probe failed) -- treating it as fresh. If it is stuck from a crashed taker, remove it manually: rm -rf '$claim'" >&2
            fi
        fi
        if ! mkdir "$claim" 2>/dev/null; then
            {
                echo "queue-lock: held -- another taker holds the takeover claim for this queue right now ($claim)"
                echo "Try again shortly, or check: queue-lock.sh status"
            } >&2
            return 2
        fi
        # CAS re-verify under the claim (step 2).
        local v_raw
        v_raw=$(cat "$lockdir/owner.json" 2>/dev/null) || v_raw=""
        if [ "$v_raw" != "$o_raw" ]; then
            rmdir "$claim" 2>/dev/null
            local n_session n_host
            n_session=$(_ql_json_field_str "$v_raw" session)
            n_host=$(_ql_json_field_str "$v_raw" host)
            {
                echo "queue-lock: takeover aborted -- the lock changed hands since it was read; now held by session=${n_session:-unknown} host=${n_host:-unknown}"
                echo "Work is owned elsewhere. Pick a different queue, or check again with: queue-lock.sh status"
            } >&2
            return 2
        fi
        # Step 3: destroy the verified-stale generation, fresh-acquire.
        rm -rf "$lockdir" 2>/dev/null
        if mkdir "$lockdir" 2>/dev/null; then
            if ! _ql_write_owner "$lockdir" "$session" "$host" "$ho" "$now" "$now"; then
                # C3: same contract as the fresh path -- never report a
                # takeover over a failed owner write.
                rm -rf "$lockdir" 2>/dev/null
                rmdir "$claim" 2>/dev/null
                echo "queue-lock: takeover FAILED -- owner.json could not be written; the lock dir was removed, nothing is acquired" >&2
                return 1
            fi
            printf '%s took over from session=%s host=%s started=%s heartbeat=%s reason=%s new_session=%s new_host=%s\n' \
                "$now" "$o_session" "$o_host" "$o_started" "$o_heartbeat" "$reason" "$session" "$host" \
                >> "$lockdir/takeovers.log"
            rmdir "$claim" 2>/dev/null
            echo "queue-lock: took over ($reason) -- previous holder: session=$o_session host=$o_host" >&2
            echo "queue-lock: acquired (session=$session host=$host)"
            echo "release-token: $session"
            return 0
        fi
        # Lost the rm->mkdir gap to a fresh acquirer -- it owns the lock.
        rmdir "$claim" 2>/dev/null
        local l_session="" l_host=""
        if [ -f "$lockdir/owner.json" ]; then
            l_session=$(_ql_json_field "$lockdir/owner.json" session)
            l_host=$(_ql_json_field "$lockdir/owner.json" host)
        fi
        {
            echo "queue-lock: takeover lost the race -- the queue is now held by session=${l_session:-unknown} host=${l_host:-unknown}"
            echo "Work is owned elsewhere. Pick a different queue, or check again with: queue-lock.sh status"
        } >&2
        return 2
    fi

    {
        echo "queue-lock: held (FRESH) by session=$o_session host=$o_host started=$o_started heartbeat=$o_heartbeat (age ${age}s < ttl ${ttl}s)"
        echo "Work is owned elsewhere. Pick a different queue, or override with QUEUE_LOCK_TAKEOVER=1."
    } >&2
    return 2
}

queue_lock_heartbeat() {
    local ho="${1:-}" session="${2:-}"
    if [ -z "$ho" ]; then
        _ql_usage >&2
        return 1
    fi
    local lockdir
    if ! lockdir=$(_ql_lockdir "$ho"); then
        echo "queue-lock: could not resolve handover root" >&2
        return 1
    fi
    # C1: the token is MANDATORY -- a token-less heartbeat could refresh
    # (and keep alive) another session's lock.
    if [ -z "$session" ]; then
        {
            echo "queue-lock: heartbeat requires the session token printed by acquire (release-token: <token>)"
            echo "usage: queue-lock.sh heartbeat <handover-path> <session-token>"
            if [ -f "$lockdir/owner.json" ]; then
                echo "current holder:"
                cat "$lockdir/owner.json"
            else
                echo "current holder: (no lock currently held)"
            fi
        } >&2
        return 2
    fi
    if [ ! -d "$lockdir" ] || [ ! -f "$lockdir/owner.json" ]; then
        echo "queue-lock: no lock held for this queue -- nothing to heartbeat" >&2
        return 2
    fi
    local o_session o_host o_started
    o_session=$(_ql_json_field "$lockdir/owner.json" session)
    o_host=$(_ql_json_field "$lockdir/owner.json" host)
    o_started=$(_ql_json_field "$lockdir/owner.json" started)
    if [ "$session" != "$o_session" ]; then
        echo "queue-lock: heartbeat refused -- held by session=$o_session, not '$session'" >&2
        return 2
    fi
    if ! _ql_write_owner "$lockdir" "$o_session" "$o_host" "$ho" "$o_started" "$(_ql_now_iso)"; then
        echo "queue-lock: heartbeat FAILED -- owner.json could not be rewritten atomically (the previous heartbeat stays in effect)" >&2
        return 1
    fi
    return 0
}

queue_lock_release() {
    local ho="${1:-}" session="${2:-}"
    if [ -z "$ho" ]; then
        _ql_usage >&2
        return 1
    fi
    local lockdir
    if ! lockdir=$(_ql_lockdir "$ho"); then
        echo "queue-lock: could not resolve handover root" >&2
        return 1
    fi
    # Emergency override (C1): releases regardless of token -- loud on
    # stderr AND logged to the queue-level takeovers.log (the lock's own
    # takeovers.log dies with the dir, so the trail lives one level up).
    if [ "${QUEUE_LOCK_FORCE_RELEASE:-}" = "1" ]; then
        if [ ! -d "$lockdir" ]; then
            return 0
        fi
        local f_session f_host
        f_session=$(_ql_json_field "$lockdir/owner.json" session)
        f_host=$(_ql_json_field "$lockdir/owner.json" host)
        printf '%s FORCED RELEASE of session=%s host=%s lock=%s (QUEUE_LOCK_FORCE_RELEASE=1, by pid=%s on host=%s)\n' \
            "$(_ql_now_iso)" "${f_session:-unknown}" "${f_host:-unknown}" "$lockdir" "$$" "$(_ql_hostname)" \
            >> "$(dirname "$lockdir")/takeovers.log" 2>/dev/null || true
        echo "WARN queue-lock: FORCED release of session=${f_session:-unknown} host=${f_host:-unknown} (QUEUE_LOCK_FORCE_RELEASE=1) -- logged to $(dirname "$lockdir")/takeovers.log" >&2
        rm -rf "$lockdir" 2>/dev/null
        if [ -d "$lockdir" ]; then
            echo "queue-lock: failed to remove lock dir '$lockdir' -- it still exists (open handle on Windows? permission?); NOT released" >&2
            return 1
        fi
        return 0
    fi
    # C1: the token is MANDATORY -- a token-less release would rm another
    # session's LIVE lock (the exact incident class this script prevents).
    # Separate script invocations cannot re-derive a stable per-session id,
    # so a re-derived default would "prove" nothing.
    if [ -z "$session" ]; then
        {
            echo "queue-lock: release requires the session token printed by acquire (release-token: <token>)"
            echo "usage: queue-lock.sh release <handover-path> <session-token>"
            if [ -f "$lockdir/owner.json" ]; then
                echo "current holder:"
                cat "$lockdir/owner.json"
            else
                echo "current holder: (no lock currently held)"
            fi
            echo "emergency override (token lost): QUEUE_LOCK_FORCE_RELEASE=1 queue-lock.sh release <handover-path>"
        } >&2
        return 2
    fi
    if [ ! -d "$lockdir" ]; then
        return 0
    fi
    if [ -f "$lockdir/owner.json" ]; then
        local o_session
        o_session=$(_ql_json_field "$lockdir/owner.json" session)
        if [ -n "$o_session" ] && [ "$o_session" != "$session" ]; then
            echo "queue-lock: release refused -- held by session=$o_session, not '$session' (QUEUE_LOCK_FORCE_RELEASE=1 to force)" >&2
            return 2
        fi
    fi
    rm -rf "$lockdir" 2>/dev/null
    if [ -d "$lockdir" ]; then
        echo "queue-lock: failed to remove lock dir '$lockdir' -- it still exists (open handle on Windows? permission?); NOT released" >&2
        return 1
    fi
    return 0
}

queue_lock_status() {
    local ho="${1:-}"
    if [ -z "$ho" ]; then
        _ql_usage >&2
        return 1
    fi
    local lockdir
    if ! lockdir=$(_ql_lockdir "$ho"); then
        echo "queue-lock: could not resolve handover root" >&2
        return 1
    fi
    if [ ! -d "$lockdir" ]; then
        echo "free"
        return 0
    fi
    if [ ! -f "$lockdir/owner.json" ]; then
        # Distinguish corruption from a live holder in the OUTPUT (a
        # passthrough caller like arm-resume would otherwise misdiagnose
        # this as a live session) while keeping rc=11 -- fail-closed.
        echo "held -- CORRUPT lock dir (owner.json missing/unreadable): $lockdir"
        echo "manual cleanup once verified dead: rm -rf '$lockdir'"
        return 11
    fi
    cat "$lockdir/owner.json"
    local ttl="${QUEUE_LOCK_TTL_SECONDS:-21600}"
    case "$ttl" in ''|*[!0-9]*) ttl=21600 ;; esac
    local o_heartbeat hb_epoch now_epoch age=-1 stale=0
    o_heartbeat=$(_ql_json_field "$lockdir/owner.json" heartbeat)
    hb_epoch=$(_ql_epoch_of_iso "$o_heartbeat")
    now_epoch=$(_ql_now_epoch)
    if [ -n "$hb_epoch" ] && [ -n "$now_epoch" ]; then
        age=$(( now_epoch - hb_epoch ))
        [ "$age" -lt 0 ] && age=0
        [ "$age" -ge "$ttl" ] && stale=1
    else
        echo "WARN queue-lock: could not parse heartbeat '$o_heartbeat' -- treating as FRESH (fail-closed on unparsable timestamps)" >&2
    fi
    if [ "$stale" -eq 1 ]; then
        echo "status: STALE (age ${age}s >= ttl ${ttl}s)"
        return 12
    fi
    # Aging warning (C2): heartbeat is not yet wired into the long-session
    # flow, so a FRESH lock past half the TTL is drifting toward a stale
    # takeover window -- surface it before it becomes one.
    if [ "$age" -ge 0 ] && [ "$age" -ge $(( ttl / 2 )) ]; then
        echo "WARN queue-lock: heartbeat age ${age}s exceeds half the TTL (${ttl}s) -- the lock is AGING toward stale; refresh it (queue-lock.sh heartbeat) on long sessions" >&2
    fi
    echo "status: FRESH"
    return 11
}

_ql_main() {
    local verb="${1:-}"
    if [ -n "$verb" ]; then
        shift
    fi
    case "$verb" in
        acquire)   queue_lock_acquire "$@" ;;
        heartbeat) queue_lock_heartbeat "$@" ;;
        release)   queue_lock_release "$@" ;;
        status)    queue_lock_status "$@" ;;
        *)
            _ql_usage >&2
            return 1
            ;;
    esac
}

# Sourcing guard (bash 3.2-safe form of "is this file executed, not
# sourced"), same idiom as shared-branch-lock.sh -- lets tests source this
# file and call the queue_lock_* functions in-process.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    _ql_main "$@"
    exit $?
fi
