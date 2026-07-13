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
# ARMS REGISTRY LIFECYCLE (HIMMEL-882): arm-resume.sh (HIMMEL-856) records a
# PENDING record in <handover-root>/.locks/arms.jsonl every time it arms a
# relaunch, and refuses (rc=8) to re-arm a handover that already has a
# PENDING record on another host. Nothing previously retired a record when
# its arm fired, so that refusal was permanent -- ARM_DUP_OK=1 was needed on
# every re-arm forever, even long after the original arm had fired and its
# session finished. A successful `acquire` -- the session actually starting
# on this handover's queue -- is proof this host's PENDING arm(s) for it
# have fired, so `acquire` CONSUMES them (drops the record(s); see
# _ql_arms_registry_retire_fired -- CR round-3 retention: fired records are
# inert, so the registry stays O(active arms) instead of growing forever).
# This closes the gap on the reading side; arm-resume.sh separately prunes
# its OWN host's stale records at re-schedule time (its own HIMMEL-882
# comment) so a superseded arm that never fires doesn't linger either.
# Registry rewrites here and in arm-resume.sh are serialized by a
# short-lived OWNER-TOKENED mkdir-CAS mutex at <registry>.lock (rounds 2/3)
# -- the read-filter-rewrite pair is a lost-update race between concurrent
# writers that the original append-only `>>` never had, and the owner token
# stops a holder that outlived the mutex expiry from clobbering its
# reclaimer.
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

# JSON escape/extract now delegate to the shared pure-bash helpers in
# scripts/lib/handover-path.sh (_hp_json_escape / _hp_json_field, HIMMEL-882
# CR round-3): zero forks per call site that uses them directly, and the
# extractor is escape-AWARE (scans to the first UNESCAPED closing quote by
# trailing-backslash parity), so values containing \" and backslash runs --
# legal in macOS/Linux paths -- extract correctly. These $()-style wrappers
# keep the existing one-shot call sites unchanged; HOT loops call the _hp_*
# helpers directly (no substitution fork).
_ql_json_escape() {
    _hp_json_escape "$1"
    printf '%s' "$_HP_ESC"
}

# _ql_json_field <file> <key> -- extract a flat string field's value.
_ql_json_field() {
    local _raw=""
    _raw=$(cat "$1" 2>/dev/null) || _raw=""
    _hp_json_field "$_raw" "$2"
    printf '%s' "$_HP_FIELD"
}

# _ql_json_field_str <json-string> <key> -- same extraction from an
# in-memory string. acquire parses ALL fields from ONE captured read
# (o_raw) so the staleness judgment and the CAS takeover verify below
# operate on the same generation -- N separate file reads could straddle
# a concurrent owner.json rewrite.
_ql_json_field_str() {
    _hp_json_field "$1" "$2"
    printf '%s' "$_HP_FIELD"
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
    # NOTE: this final fold also collapses every OTHER non [A-Za-z0-9_-]
    # separator (space, dot, colon, ...) to "-", so e.g. "foo bar" and
    # "foo-bar" slug identically -- same theoretical-only caveat as the "/"
    # fold above; the repo handover naming convention never produces two
    # distinct paths differing only in which separator they use.
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

# _ql_arms_registry_retire_fired <handover-path> -- HIMMEL-882 registry
# lifecycle: on a SUCCESSFUL acquire, CONSUME (drop) every still-pending
# <handover-root>/.locks/arms.jsonl record for THIS host + this handover.
# arms.jsonl (scripts/handover/arm-resume.sh, HIMMEL-856) is append-only
# and nothing previously retired a record when its arm fired -- so a re-arm
# of the SAME handover from ANOTHER host kept matching the stale record and
# hard-refusing rc=8 forever (ARM_DUP_OK=1 required on every re-arm). An
# armed session that reaches the point of acquiring its queue lock has, by
# definition, fired, so this is the natural place to retire its record(s).
# RETENTION SHAPE (CR round-3): a fired record is inert coordination state
# (the foreign-hits scan skips it; takeovers.log + session notes are the
# audit trail), so instead of marking records "fired" and carrying them
# forever -- which made the registry O(all arms ever) and a long rewrite a
# mutex-expiry hazard -- consumed records are DROPPED, and any legacy
# '"fired":"true"'-marked line (written by the earlier marking revision) is
# garbage-collected in passing. Both rewriters GC this way, so the file
# stays O(active arms). Matches by host+handover only (not task-name/
# fire-at) so it also clears earlier SAME-host records left by a re-arm/
# --force replace that never itself fired (arm-resume.sh additionally
# prunes those at re-schedule time -- see its own HIMMEL-882 comment).
#
# Best-effort and fail-open: a missing/unresolvable registry, a mutex
# timeout, a mid-rewrite mutex theft, or a write failure just leaves the
# record(s) unconsumed (WARN on stderr) -- same contract as the rest of the
# arms-registry integration (a registry hiccup must never fail an acquire
# that otherwise succeeded). CRASH-atomic: filtered content is written to a
# same-dir temp file, then mv'd into place (matches _ql_write_owner's
# owner.json pattern) so a mid-write crash never leaves a torn arms.jsonl
# -- but temp+mv alone does NOT protect against a CONCURRENT rewriter, so
# the whole read-filter-rewrite runs under the OWNER-TOKENED
# _ql_arms_mutex_acquire mkdir-CAS mutex shared with arm-resume.sh's
# _arm_registry_replace_and_append, and the mv happens only while the
# owner token still names us (round-3: a holder that outlives the mutex's
# 60s staleness expiry gets reclaimed; its snapshot is then stale and its
# blind mv/rmdir would corrupt the reclaimer's generation).
_ql_arms_registry_retire_fired() {
    local ho="$1" root reg host tmp tok cur line l_host l_ho host_esc ho_esc changed=0 failed=0 stolen=0 wfail_err=""
    # handover_root failure here would require an external race (the root
    # deleted out from under us mid-acquire): _ql_lockdir already resolved
    # this same root moments earlier via handover_root_ensure, so this is
    # structurally can't-happen on this call path -- silent return is
    # intentional, not an oversight (unlike every other failure branch
    # below, which WARNs).
    root=$(handover_root 2>/dev/null) || return 0
    [ -n "$root" ] || return 0
    reg="$root/.locks/arms.jsonl"
    [ -f "$reg" ] || return 0
    if ! _ql_arms_mutex_acquire "$reg"; then
        echo "WARN queue-lock: could not lock the arms registry ($reg.lock) -- skipping the consume; this host's arm record stays PENDING (a later acquire or same-host re-arm clears it; a mutex stuck from a crashed writer self-expires after 60s)" >&2
        return 0
    fi
    tok="$_QL_ARMS_MUTEX_TOKEN"
    # Compare ESCAPED-vs-ESCAPED (round-2): the registry stores JSON-escaped
    # values, so the needles get the same transform before comparing.
    host=$(_ql_hostname)
    _hp_json_escape "$host"; host_esc="$_HP_ESC"
    _hp_json_escape "$ho";   ho_esc="$_HP_ESC"
    tmp="$reg.tmp.$$"
    # round-4 (sfh-2): capture stderr instead of discarding it, so a real
    # write failure (disk full / permission denied / RO-fs / AV lock) folds
    # its first line into the WARN below and reads differently from a
    # mutex timeout or theft -- 2>/dev/null made all of these look like the
    # same generic "could not rewrite" message.
    if wfail_err=$( { : > "$tmp"; } 2>&1 ); then
        # `|| [ -n "$line" ]` (round-2 Critical): read returns 1 at
        # EOF-without-newline while still filling $line -- without the guard
        # the rewrite silently DELETES a final record lacking a trailing
        # newline. Blank lines are dropped on rewrite (aligned with
        # _arm_registry_replace_and_append). ZERO forks per line (round-3
        # Critical): _hp_json_field returns via $_HP_FIELD, no $().
        while IFS= read -r line || [ -n "$line" ]; do
            [ -z "$line" ] && continue
            case "$line" in
                *'"fired":"true"'*) changed=1; continue ;;   # GC legacy fired-marked line
            esac
            _hp_json_field "$line" host;     l_host="$_HP_FIELD"
            _hp_json_field "$line" handover; l_ho="$_HP_FIELD"
            if [ "$l_host" = "$host_esc" ] && [ "$l_ho" = "$ho_esc" ]; then
                changed=1
                continue   # consumed: this acquire IS the arm's session start
            fi
            printf '%s\n' "$line" >> "$tmp" || failed=1
            [ "$failed" -eq 1 ] && break
        done < "$reg"
    else
        failed=1
    fi
    if [ "$failed" -eq 0 ] && [ "$changed" -eq 1 ]; then
        # OWNER-TOKEN verify (round-3): mv only while the mutex still names
        # us. If it was reclaimed mid-rewrite our snapshot is stale -- skip
        # the mv (the release below WARNs about the theft). The cat->mv
        # window is microseconds vs the whole-rewrite window it replaces --
        # residual (accepted), same class as the release function's
        # token-read->rmdir gap documented below.
        cur=$(cat "$reg.lock/owner" 2>/dev/null) || cur=""
        if [ "$cur" = "$tok" ]; then
            if wfail_err=$(mv -f "$tmp" "$reg" 2>&1); then
                echo "queue-lock: consumed this host's pending arms-registry record(s) for this handover (arm fired)" >&2
            else
                failed=1
            fi
        else
            stolen=1
        fi
    fi
    if [ "$failed" -eq 1 ]; then
        echo "WARN queue-lock: could not rewrite the arms registry ($reg) -- consume skipped; this host's arm record stays PENDING (the lock acquire itself is unaffected)${wfail_err:+ (write error: ${wfail_err%%$'\n'*})}" >&2
    fi
    if [ "$failed" -eq 1 ] || [ "$stolen" -eq 1 ] || [ "$changed" -eq 0 ]; then
        rm -f "$tmp" 2>/dev/null
    fi
    _ql_arms_mutex_release "$reg" "$tok" || true
    return 0
}

# _ql_arms_mutex_acquire <registry-file> -- HIMMEL-882 CR round-2/3: acquire
# the short-lived mkdir-CAS mutex (<registry>.lock, a DIRECTORY -- the same
# atomic primitive as the queue lock and the takeover claim above) that
# serializes every arms.jsonl read-filter-rewrite writer (this script's
# consume + arm-resume.sh's prune-and-append; the path AND the owner-token
# protocol must stay identical in both). On success the lock dir carries an
# `owner` token file and $_QL_ARMS_MUTEX_TOKEN names it -- release/mv are
# compare-then-act against that token (round-3: a holder reclaimed after
# the 60s staleness expiry must not blind-rmdir the reclaimer's lock or mv
# a stale snapshot over its rewrite). Bounded: nominal ~4s of 0.1s retries
# (platform-dependent -- measured ~2x that, ~8.7s, on Windows/Git-Bash from
# per-iteration mkdir+sleep overhead), then rc 1 -- callers keep the
# fail-open contract (WARN + skip the registry op, never fail the
# acquire/arm). A mutex stranded by a crashed writer is cleared when its
# dir mtime is >=60s old, re-probed every 10th iteration across the retry
# budget (round-4: NOT every iteration -- py_armor_mtime forks python and
# Windows python startup is ~100-300ms; probing every 10th yields ~4 probes
# across the ~40-iteration budget, bounding the extra forks while still
# catching a lock that crosses the 60s threshold mid-wait -- a lock that
# was, say, 56s old when this contender started is not yet stale at
# tries==0 but would previously never be re-checked, burning the whole
# retry budget instead of reclaiming it; a failed probe never clears).
_QL_ARMS_MUTEX_TOKEN=""
_ql_arms_mutex_acquire() {
    local reg="$1" lockd tries=0 m now tok
    lockd="$reg.lock"
    while :; do
        if mkdir "$lockd" 2>/dev/null; then
            # Brand the lock. pid alone is unique among LIVE processes;
            # $RANDOM guards the recycled-pid edge.
            #
            # mkdir is NOT a reliable mutual-exclusion primitive on every
            # platform: uutils coreutils 0.8.0 (the Rust coreutils shipped on
            # some Windows/WSL apt boxes) resolves two CONCURRENT mkdir of the
            # same path to BOTH rc=0 -- a non-atomic check-then-create that
            # breaks the mkdir(2) EEXIST guarantee this lock relied on
            # (HIMMEL-966; measured ~96% double-win on ext4, so two writers
            # entered the arms-registry critical section at once and one
            # consume was lost). So the OWNER create, not the mkdir, is the
            # real arbiter: set -C (noclobber) makes it a single kernel
            # open(O_CREAT|O_EXCL) -- performed by bash itself, no coreutils
            # binary -- atomic on every POSIX fs. Exactly one co-winner of a
            # double-won mkdir wins this create; the losers leave the winner's
            # lock alone and fall through to the spin/reclaim path.
            tok="pid$$-r$RANDOM"
            if ( set -C; printf '%s' "$tok" > "$lockd/owner" ) 2>/dev/null; then
                _QL_ARMS_MUTEX_TOKEN="$tok"
                return 0
            fi
            # Lost the O_EXCL owner create to a co-winner that branded first
            # -- it is the true holder; do NOT tear down its lock. Fall
            # through and retry (spin, or reclaim if it later goes stale).
        fi
        if [ $(( tries % 10 )) -eq 0 ]; then
            m=$(py_armor_mtime "$lockd") || m=""
            now=$(_ql_now_epoch)
            if [ -n "$m" ] && [ -n "$now" ] && [ $(( now - m )) -ge 60 ]; then
                rm -rf "$lockd" 2>/dev/null
            fi
        fi
        tries=$((tries + 1))
        if [ "$tries" -ge 40 ]; then
            return 1
        fi
        sleep 0.1
    done
}

# _ql_arms_mutex_release <registry-file> <token> -- compare-then-delete
# (round-3): release the arms mutex ONLY if its owner token is still ours.
# A mismatch means the lock was reclaimed from under us (we outlived the
# 60s staleness expiry mid-rewrite) -- WARN loudly and leave the
# reclaimer's lock alone (rc 1); the caller has already skipped its stale
# mv on the same comparison. Residual (accepted): a reclaim landing between
# the token read and the rmdir can still lose its lock -- a microsecond
# window vs the whole-rewrite window this closes, same accepted-residual
# class as the takeover claim's rm->mkdir gap above.
_ql_arms_mutex_release() {
    local reg="$1" tok="$2" cur=""
    cur=$(cat "$reg.lock/owner" 2>/dev/null) || cur=""
    if [ "$cur" != "$tok" ]; then
        echo "WARN queue-lock: the arms-registry mutex ($reg.lock) was reclaimed by another writer mid-rewrite (owner token mismatch: now '${cur:-none}') -- leaving their lock in place; this rewrite was discarded" >&2
        return 1
    fi
    rm -f "$reg.lock/owner" 2>/dev/null
    rmdir "$reg.lock" 2>/dev/null
    return 0
}

# Drop a takeover claim only while its atomic owner brand still names us.
# A taker that outlives the 120s claim TTL must not remove a reclaimer's
# newly created generation.
_ql_takeover_claim_release() {
    local claim="$1" token="$2" current=""
    current=$(cat "$claim/owner" 2>/dev/null) || current=""
    if [ "$current" != "$token" ]; then
        return 1
    fi
    rm -f "$claim/owner" 2>/dev/null
    rmdir "$claim" 2>/dev/null
    return 0
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
    # uutils mkdir can report success to concurrent creators of the same
    # directory. The owner create is the real CAS: bash noclobber maps to
    # open(O_CREAT|O_EXCL), so only its winner may brand owner.json.
    if mkdir "$lockdir" 2>/dev/null; then
        if ( set -C; printf '%s' "$session" > "$lockdir/owner" ) 2>/dev/null; then
            if ! _ql_write_owner "$lockdir" "$session" "$host" "$ho" "$now" "$now"; then
                # C3: never report acquired over a failed owner write -- the
                # torn lock would parse as CORRUPT-held (fail-closed) forever.
                rm -rf "$lockdir" 2>/dev/null
                echo "queue-lock: acquire FAILED -- owner.json could not be written; the lock dir was removed, nothing is acquired" >&2
                return 1
            fi
            echo "queue-lock: acquired (session=$session host=$host)"
            _ql_arms_registry_retire_fired "$ho"
            echo "release-token: $session"
            return 0
        elif [ ! -e "$lockdir/owner" ]; then
            # Owner create failed with NO winner branded (ENOSPC/ACL/IO --
            # not a lost race; codex-adv 981-r1): an unbranded dir would
            # wedge every future taker on manual cleanup. rmdir (never
            # rm -rf) is race-safe -- it only removes an EMPTY dir, so a
            # racer branding between the check and here makes it a no-op.
            rmdir "$lockdir" 2>/dev/null
            echo "queue-lock: acquire FAILED -- the owner file could not be created (disk full? permissions?); the empty lock dir was removed, nothing is acquired" >&2
            return 1
        fi
        # owner exists: a uutils co-winner branded first -- we LOST the
        # arbiter; fall through to the loser/spin path below.
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
        # mkdir success is provisional on uutils. Atomically brand the
        # claim with bash noclobber; a co-winner leaves the true winner's
        # directory/owner untouched and follows the normal held path.
        local claim_token="pid$$-r$RANDOM"
        if ! mkdir "$claim" 2>/dev/null \
            || ! ( set -C; printf '%s' "$claim_token" > "$claim/owner" ) 2>/dev/null; then
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
            _ql_takeover_claim_release "$claim" "$claim_token" || true
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
        # Same owner-file arbiter as the fresh acquire above: a uutils
        # mkdir co-winner must not overwrite or remove the true winner.
        # And same write-failure contract (codex-adv 981-r1): a failed owner
        # create with NO winner branded is an IO/permissions error, not a
        # lost race -- rmdir the unbranded dir (race-safe: rmdir refuses a
        # non-empty dir) instead of leaving a queue-wedging husk.
        local takeover_owner_ok=0
        if mkdir "$lockdir" 2>/dev/null; then
            if ( set -C; printf '%s' "$session" > "$lockdir/owner" ) 2>/dev/null; then
                takeover_owner_ok=1
            elif [ ! -e "$lockdir/owner" ]; then
                rmdir "$lockdir" 2>/dev/null
                _ql_takeover_claim_release "$claim" "$claim_token" || true
                echo "queue-lock: takeover FAILED -- the owner file could not be created (disk full? permissions?); the empty lock dir was removed, nothing is acquired" >&2
                return 1
            fi
        fi
        if [ "$takeover_owner_ok" -eq 1 ]; then
            if ! _ql_write_owner "$lockdir" "$session" "$host" "$ho" "$now" "$now"; then
                # C3: same contract as the fresh path -- never report a
                # takeover over a failed owner write.
                rm -rf "$lockdir" 2>/dev/null
                _ql_takeover_claim_release "$claim" "$claim_token" || true
                echo "queue-lock: takeover FAILED -- owner.json could not be written; the lock dir was removed, nothing is acquired" >&2
                return 1
            fi
            printf '%s took over from session=%s host=%s started=%s heartbeat=%s reason=%s new_session=%s new_host=%s\n' \
                "$now" "$o_session" "$o_host" "$o_started" "$o_heartbeat" "$reason" "$session" "$host" \
                >> "$lockdir/takeovers.log"
            _ql_takeover_claim_release "$claim" "$claim_token" || true
            echo "queue-lock: took over ($reason) -- previous holder: session=$o_session host=$o_host" >&2
            echo "queue-lock: acquired (session=$session host=$host)"
            _ql_arms_registry_retire_fired "$ho"
            echo "release-token: $session"
            return 0
        fi
        # Lost the rm->mkdir gap to a fresh acquirer -- it owns the lock.
        _ql_takeover_claim_release "$claim" "$claim_token" || true
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
