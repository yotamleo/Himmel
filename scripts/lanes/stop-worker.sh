#!/usr/bin/env bash
# scripts/lanes/stop-worker.sh -- the sanctioned STOP chokepoint for in-flight
# lane workers (HIMMEL-1693). Symmetric with the spawn chokepoints
# (scripts/telegram/spawn-glm.ts, spawn-claudex.ts): those mint a worker and
# publish its liveness metadata; this one resolves that metadata back to a
# process and stops it.
#
# WHY THIS EXISTS: a dispatched worker could not be stopped. `taskkill` is
# hard-blocked by scripts/hooks/block-destructive-commands.sh (correctly -- the
# general no-process-termination rule must stay), spawn-claudex has no in-band
# halt channel, and no stop helper existed anywhere. A judge who discovered a
# dispatch was redundant had to let it burn its full 45-minute timebox. The
# house model is judge -> N lanes with the judge expected to "watchdog
# executors"; watchdogging without a stop primitive is not watchdogging.
#
# AUTHORIZATION IS THE REGISTRY, NOT A SECRET. The target is resolved through
# the lane session registry -- never a raw pid handed in by a caller -- so this
# cannot be aimed at an arbitrary process. Anything that is not a lane worker
# this machine spawned is refused. Deliberately NO nonce: the RETASK channel
# (docs/internals/retask-channel.md) lets halt through WITHOUT the token because
# halting is the fail-safe direction, and a process-layer gate stricter than the
# protocol it enforces would re-open the exact gap this ticket was filed for.
#
# NO DATA LOSS ON HALT: the worker's dirty worktree is checkpointed to
# refs/checkpoints/<slug> BEFORE any signal, so stopping a worker is never the
# thing that destroys its work (HIMMEL-1691). A checkpoint failure ABORTS the
# stop -- we would rather leave a worker running than kill it with unsaved work.
#
# IDENTITY BEFORE SIGNAL: termination goes through scripts/lib/proc-tree.sh,
# which verifies the target's identity and VERIFIES THE OUTCOME rather than
# trusting a return code ("an rc of 0 is not evidence; an empty group is").
# Its rc 2 (identity unconfirmable) and rc 3 (leader already exited) are
# distinct outcomes handled separately below -- neither is reported as a kill.
#
# THE HALT OWNS THE POISON IT STRANDS (HIMMEL-1929): the spawn chokepoints set
# a worktree-scoped remote.origin.pushurl sentinel for the life of a dispatch
# and restore it in a `finally`. A hard kill is not catchable, so that finally
# never runs and the sentinel is STRANDED on the worker's worktree -- and with
# the GLM lane dropped, nothing self-heals it any more. This script performs
# that kill, so it clears the sentinel on every path where it concludes the
# worker is gone (see clear_push_poison below).
#
# CONVENTIONS: bash 3.2-safe (no associative arrays, no mapfile). ASCII only.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/proc-tree.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/proc-tree.sh"

DRY_RUN=0
LIST=0
TARGET=""
GRACE="${STOP_WORKER_GRACE_SECS:-5}"
# CR (HIMMEL-1693 round 2): a non-numeric GRACE reaches `sleep` inside
# proc_tree_terminate and fails at once, silently collapsing the TERM grace
# window -- the worker then gets KILL with no chance to finalize. Reject
# anything that is not a whole number of seconds before it gets that far.
case "$GRACE" in
    ''|*[!0-9]*)
        echo "stop-worker: STOP_WORKER_GRACE_SECS must be a whole number of seconds (got '$GRACE')" >&2
        exit 1
        ;;
esac

usage() {
    cat <<'EOF'
usage: stop-worker.sh [--list] [--dry-run] <session-id|branch>

  --list      print registered lane sessions (session-id, lane, status, pid, branch) and exit
  --dry-run   resolve + checkpoint, report what WOULD be signalled, signal nothing

Resolves <session-id|branch> through the lane session registry under the
CANONICAL root ~/.claude/handover/bridge: glm-sessions/ and claudex-sessions/.
A raw pid is NOT accepted -- that is the point. Unlike the other BRIDGE_ROOT
readers in this repo, a plain BRIDGE_ROOT env is IGNORED here (HIMMEL-1693
CR): this is the sanctioned kill chokepoint, so its registry root must not be
caller-controlled. Tests that need a fixture registry set
STOP_WORKER_BRIDGE_ROOT_OVERRIDE=<path> explicitly.

exit: 0 stopped (or dry-run ok) | 1 usage/refused | 2 target not found
      3 target not running | 4 could not verify identity, nothing signalled
      5 checkpoint failed, nothing signalled | 6 signalled but survivors remain
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --list)    LIST=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        -*)        echo "stop-worker: unknown flag '$1'" >&2; usage >&2; exit 1 ;;
        *)
            if [ -n "$TARGET" ]; then
                echo "stop-worker: more than one target given ('$TARGET', '$1')" >&2
                exit 1
            fi
            TARGET="$1"
            ;;
    esac
    shift
done

# CR (HIMMEL-1693 panel, codex-1): this is the sanctioned KILL chokepoint, so
# its registry root must not be caller-controlled the way BRIDGE_ROOT is
# elsewhere in this repo (bus.ts / spawn-glm.ts / await-glm-worker.sh all
# honor a plain BRIDGE_ROOT env -- fine for them, since none of them signal a
# process). The destructive-command hook only ever sees the outer
# `bash stop-worker.sh <id>` invocation; it cannot see that BRIDGE_ROOT
# redirects the registry this resolves identity through. A caller who exports
# BRIDGE_ROOT at a forged registry would otherwise gain an arbitrary-process-
# kill primitive through this exact chokepoint -- "the registry is the
# authorization" only holds if the registry location itself is trusted. No
# other script in the repo invokes stop-worker.sh with BRIDGE_ROOT set (only
# this suite's hermetic fixture does), so ignoring a plain BRIDGE_ROOT here
# does not break any legitimate caller. The test seam stays explicit and loud:
# STOP_WORKER_BRIDGE_ROOT_OVERRIDE must be set on its own -- its name makes
# the intent (test-only, not the canonical registry) unmistakable.
if [ -n "${STOP_WORKER_BRIDGE_ROOT_OVERRIDE:-}" ]; then
    BRIDGE_ROOT_DIR="$STOP_WORKER_BRIDGE_ROOT_OVERRIDE"
    echo "stop-worker: TEST OVERRIDE: registry root = $BRIDGE_ROOT_DIR -- not the canonical registry" >&2
else
    if [ -n "${BRIDGE_ROOT:-}" ]; then
        echo "stop-worker: WARNING: BRIDGE_ROOT is set but ignored by this chokepoint -- the kill-primitive registry root is not caller-overridable; set STOP_WORKER_BRIDGE_ROOT_OVERRIDE if this is a test" >&2
    fi
    BRIDGE_ROOT_DIR="$HOME/.claude/handover/bridge"
fi

# meta_field <meta.json> <key> -- read one top-level scalar. node is already a
# hard dependency of the lane stack (the spawners are TypeScript), so this
# needs no new tooling; a missing/corrupt file prints nothing and the caller
# treats that as unknown, which every branch below fails CLOSED on.
meta_field() {
    node -e '
const fs = require("fs");
try {
  const o = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const v = o[process.argv[2]];
  if (v !== undefined && v !== null) process.stdout.write(String(v));
} catch (_) {}
' "$1" "$2" 2>/dev/null
}

# each_session_meta -- print every "<session-dir>\t<meta.json>" pair the
# registry knows about, across both lanes.
each_session_meta() {
    local root d
    for root in "$BRIDGE_ROOT_DIR/glm-sessions" "$BRIDGE_ROOT_DIR/claudex-sessions"; do
        [ -d "$root" ] || continue
        for d in "$root"/*/; do
            [ -d "$d" ] || continue
            d="${d%/}"
            [ -f "$d/meta.json" ] || continue
            printf '%s\t%s\n' "$d" "$d/meta.json"
        done
    done
}

if [ "$LIST" -eq 1 ]; then
    printf '%-44s %-8s %-10s %-8s %s\n' "SESSION" "LANE" "STATUS" "PID" "BRANCH"
    while IFS="$(printf '\t')" read -r sdir meta; do
        [ -n "$sdir" ] || continue
        printf '%-44s %-8s %-10s %-8s %s\n' \
            "$(basename "$sdir")" \
            "$(meta_field "$meta" lane)" \
            "$(meta_field "$meta" status)" \
            "$(meta_field "$meta" pid)" \
            "$(meta_field "$meta" branch)"
    done <<EOF
$(each_session_meta)
EOF
    exit 0
fi

if [ -z "$TARGET" ]; then
    usage >&2
    exit 1
fi

# --- resolve the target through the registry --------------------------------
# Matches a session-dir basename OR a branch. A branch match is restricted to
# RUNNING sessions: a branch is reused across dispatches, so an old finished
# session on the same branch must never shadow the live one.
MATCH_DIR=""
MATCH_META=""
MATCH_COUNT=0
while IFS="$(printf '\t')" read -r sdir meta; do
    [ -n "$sdir" ] || continue
    base="$(basename "$sdir")"
    if [ "$base" = "$TARGET" ]; then
        MATCH_DIR="$sdir"; MATCH_META="$meta"; MATCH_COUNT=1
        break   # an exact session id is unique and wins outright
    fi
    if [ "$(meta_field "$meta" branch)" = "$TARGET" ] && [ "$(meta_field "$meta" status)" = "running" ]; then
        MATCH_DIR="$sdir"; MATCH_META="$meta"
        MATCH_COUNT=$((MATCH_COUNT + 1))
    fi
done <<EOF
$(each_session_meta)
EOF

if [ "$MATCH_COUNT" -eq 0 ]; then
    echo "stop-worker: no lane worker matches '$TARGET' (not a session id or a running branch in $BRIDGE_ROOT_DIR) -- refusing; run --list to see registered sessions" >&2
    exit 2
fi
if [ "$MATCH_COUNT" -gt 1 ]; then
    echo "stop-worker: '$TARGET' matches $MATCH_COUNT running sessions -- refusing an ambiguous stop; name the session id (--list)" >&2
    exit 1
fi

LANE="$(meta_field "$MATCH_META" lane)"
STATUS="$(meta_field "$MATCH_META" status)"
PID="$(meta_field "$MATCH_META" pid)"
PROBE="$(meta_field "$MATCH_META" pid_probe)"
WORKER_WT="$(meta_field "$MATCH_META" worker_worktree)"
BRANCH="$(meta_field "$MATCH_META" branch)"
SESSION_ID="$(basename "$MATCH_DIR")"

echo "stop-worker: target $SESSION_ID (lane=${LANE:-?} branch=${BRANCH:-?} status=${STATUS:-?} pid=${PID:-?})"

if [ "$STATUS" != "running" ]; then
    echo "stop-worker: $SESSION_ID is not running (status=${STATUS:-unknown}) -- nothing to stop" >&2
    exit 3
fi

# writeLiveWorkerMeta (spawn-glm.ts) DELETES the pid key and writes
# pid_probe=unprobeable when its atomic replace fails, precisely so a reader
# cannot mistake an unknown worker for a dead one. Honour that contract: an
# unprobeable worker is POSSIBLY ALIVE and must not be signalled blind.
if [ "$PROBE" = "unprobeable" ]; then
    echo "stop-worker: $SESSION_ID published an unprobeable liveness marker -- its pid is unknown and it must be treated as possibly alive; refusing to signal anything" >&2
    exit 4
fi
case "${PID:-}" in
    ''|*[!0-9]*|0)
        echo "stop-worker: $SESSION_ID has no usable pid ('${PID:-<none>}') -- refusing to signal" >&2
        exit 4
        ;;
esac

# --- checkpoint BEFORE signalling (HIMMEL-1691) -----------------------------
# A halt must not become a data-loss event. Plumbing only (write-tree /
# commit-tree / update-ref run no hooks), a private index so the worker's own
# index and working tree are untouched mid-edit, and the tree is seeded from
# HEAD -- an unseeded index yields a tree whose diff vs HEAD deletes the rest
# of the repo. Same shape clean-garden.sh uses for its refused-prune autosave.
checkpoint_worker_worktree() {
    local wt="$1" slug="$2" tmp_dir tmp_index head_oid head_tree tree oid
    if [ -z "$wt" ] || [ ! -d "$wt" ]; then
        echo "no worker worktree recorded"
        return 1
    fi
    git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git worktree: $wt"; return 1; }
    if [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
        echo "clean"
        return 0
    fi
    head_oid=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || head_oid=""
    [ -n "$head_oid" ] || { echo "no HEAD"; return 1; }
    tmp_dir=$(mktemp -d 2>/dev/null) || tmp_dir=""
    [ -n "$tmp_dir" ] || { echo "mktemp failed"; return 1; }
    tmp_index="$tmp_dir/index"
    if ! GIT_INDEX_FILE="$tmp_index" git -C "$wt" read-tree "$head_oid" >/dev/null 2>&1; then
        rm -rf "$tmp_dir"; echo "read-tree failed"; return 1
    fi
    if ! GIT_INDEX_FILE="$tmp_index" git -C "$wt" add -A >/dev/null 2>&1; then
        rm -rf "$tmp_dir"; echo "add failed"; return 1
    fi
    tree=$(GIT_INDEX_FILE="$tmp_index" git -C "$wt" write-tree 2>/dev/null) || tree=""
    rm -rf "$tmp_dir"
    [ -n "$tree" ] || { echo "write-tree failed"; return 1; }
    head_tree=$(git -C "$wt" rev-parse --verify "${head_oid}^{tree}" 2>/dev/null) || head_tree=""
    if [ "$tree" = "$head_tree" ]; then
        echo "clean"
        return 0
    fi
    oid=$(git -C "$wt" commit-tree "$tree" -p "$head_oid" -m "stop-worker halt checkpoint (HIMMEL-1693): $slug" 2>/dev/null) || oid=""
    [ -n "$oid" ] || { echo "commit-tree failed"; return 1; }
    # Create-or-update, both compare-and-swap: two concurrent halts must not
    # clobber each other's snapshot.
    local prev
    prev=$(git -C "$wt" rev-parse --verify --quiet "refs/checkpoints/$slug" 2>/dev/null) || prev=""
    if [ -n "$prev" ]; then
        git -C "$wt" update-ref "refs/checkpoints/$slug" "$oid" "$prev" 2>/dev/null || { echo "update-ref raced"; return 1; }
    else
        git -C "$wt" update-ref "refs/checkpoints/$slug" "$oid" "" 2>/dev/null || { echo "update-ref raced"; return 1; }
    fi
    echo "refs/checkpoints/$slug"
    return 0
}

CKPT_SLUG="$SESSION_ID-halt"
CKPT_RESULT="$(checkpoint_worker_worktree "$WORKER_WT" "$CKPT_SLUG")"
CKPT_RC=$?
if [ "$CKPT_RC" -ne 0 ]; then
    echo "stop-worker: REFUSING to stop $SESSION_ID -- its worktree could not be checkpointed ($CKPT_RESULT). A halt must not destroy unsaved work; fix the worktree or commit by hand, then retry." >&2
    exit 5
fi
if [ "$CKPT_RESULT" = "clean" ]; then
    echo "stop-worker: worker worktree is clean -- nothing to checkpoint"
else
    echo "stop-worker: checkpointed the worker's uncommitted work -> $CKPT_RESULT"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY stop-worker: would terminate pid/group $PID for $SESSION_ID (nothing signalled)"
    exit 0
fi

# annotate_halt <meta.json> <checkpoint-result> <status> -- record status/
# exit_code/pid/stopped_at/stop_checkpoint so a later reader (census,
# reconciliation, the judge) does not read a no-longer-running worker as
# "running". Shared by every exit path below that concludes a worker is gone,
# so each one stays truthful the same way TERM_RC=3 already was. Best-effort:
# the process is already gone either way, and failing to annotate must not
# turn an already-concluded halt into a reported failure -- callers warn and
# still exit 0.
annotate_halt() {
    node -e '
const fs = require("fs");
try {
  const p = process.argv[1];
  const o = JSON.parse(fs.readFileSync(p, "utf8"));
  o.status = process.argv[3]; o.exit_code = -1; o.pid = 0;
  o.stopped_at = new Date().toISOString();
  o.stop_checkpoint = process.argv[2];
  fs.writeFileSync(p, JSON.stringify(o, null, 2));
} catch (e) { process.exit(1); }
' "$1" "$2" "$3" 2>/dev/null
}

# clear_push_poison <worker-worktree> -- clear a STRANDED push-quarantine
# sentinel (HIMMEL-1929). Called from every path that concludes the worker is
# gone, alongside annotate_halt, and never from --dry-run (which exits above)
# nor from a path that leaves the worker running: clearing the sentinel out
# from under a live worker would drop its push tripwire.
#
# ONLY the exact sentinel is touched. An operator's real per-worktree pushurl
# must never be unset by a halt, so a value that is anything else -- or absent
# -- is left exactly as it is.
#
# HISTORICAL RESIDUE ONLY (HIMMEL-1961): nothing produces this sentinel any
# more. The spawner lanes no longer touch push config at all, so what is left
# on disk comes from dispatches that ran BEFORE that removal, and with the
# producer gone nothing else will ever clear it. This chokepoint keeps doing so
# because it is the one command that visits such a worktree.
#
# Why unset rather than restore: a pre-existing real pushurl left disk at
# POISON time, in the spawner, and its captured copy was a local variable never
# written to meta.json or anywhere else. A hard kill took that memory with it,
# so there is nothing left anywhere to restore FROM -- unsetting destroys
# nothing the halt still had.
#
# Best-effort, same contract as annotate_halt: the worker is already stopped,
# so a failure to clean up must be LOUD but must not turn a completed halt
# into a reported failure.
# The literal the retired lane quarantine used to write. It is defined here
# now because the spawner-side constant is gone (HIMMEL-1961) -- this is the
# only remaining reader, matching a value no writer can change.
POISON_SENTINEL="DISABLED-glm-quarantine"
clear_push_poison() {
    local wt="$1" cur wtq
    [ -n "$wt" ] && [ -d "$wt" ] || return 0
    cur="$(git -C "$wt" config --worktree --get remote.origin.pushurl 2>/dev/null)" || cur=""
    [ "$cur" = "$POISON_SENTINEL" ] || return 0
    if git -C "$wt" config --worktree --unset remote.origin.pushurl 2>/dev/null; then
        echo "stop-worker: cleared the stranded push quarantine (remote.origin.pushurl=$POISON_SENTINEL) on $wt"
    else
        # The recovery command is single-quoted so a worktree path with spaces
        # or shell metacharacters stays copy-pasteable (panel codex-2), with
        # any embedded single quote closed-escaped-reopened the standard '\''
        # way so the quoting survives that too (panel round 2).
        wtq=${wt//"'"/"'\\''"}
        echo "WARN stop-worker: could not clear remote.origin.pushurl=$POISON_SENTINEL on $wt -- that worktree cannot push until you run: git -C '$wtq' config --worktree --unset remote.origin.pushurl" >&2
    fi
}

# --- terminate, identity-verified -------------------------------------------
IDENTITY="$(proc_tree_process_identity "$PID" 2>/dev/null)" || IDENTITY=""
if [ -z "$IDENTITY" ]; then
    # proc_tree_process_alive returns THREE outcomes: 0 alive, 1 CONFIRMED
    # absent, 2 the probe could not answer -- and its contract says "callers
    # MUST treat 2 as unknown, never as confirmed absence". Testing it with a
    # bare `if` collapsed 1 and 2 into the same branch, so an unanswerable
    # probe was reported as "already gone" and written into meta.json as
    # already-exited (HIMMEL-1929 panel round 4: with the quarantine cleanup
    # below riding on the same conclusion, it would also strip a still-live
    # worker's push tripwire). Read the rc and fail CLOSED on 2.
    ALIVE_RC=0
    proc_tree_process_alive "$PID" 2>/dev/null || ALIVE_RC=$?
    if [ "$ALIVE_RC" -eq 0 ]; then
        echo "stop-worker: pid $PID is alive but its identity cannot be established -- refusing to signal an unverifiable target" >&2
        exit 4
    fi
    if [ "$ALIVE_RC" -ne 1 ]; then
        echo "stop-worker: pid $PID's liveness probe could not answer (rc $ALIVE_RC) -- absence is UNCONFIRMED, so $SESSION_ID must be treated as possibly alive; nothing signalled, nothing annotated, its push quarantine left in place" >&2
        exit 4
    fi
    echo "stop-worker: pid $PID is already gone -- $SESSION_ID needs no signal (its work is checkpointed above)"
    # The pid was gone before this chokepoint ever sampled an identity for it --
    # distinct from the TERM_RC=3 path below (which fires only after
    # proc_tree_terminate's own guard runs), but the same truthful outcome: no
    # signal was ever sent, so the session must not be left reading "running".
    annotate_halt "$MATCH_META" "$CKPT_RESULT" "already-exited" \
      || echo "WARN stop-worker: $SESSION_ID's pid was already gone but its meta.json could not be annotated" >&2
    clear_push_poison "$WORKER_WT"
    exit 0
fi

# iso_to_epoch <iso8601> -- GNU `date -d` handles the registry's format (incl.
# fractional seconds + trailing Z) directly; BSD/macOS `date` lacks -d, so the
# fallback strips the fractional-seconds+Z suffix and parses with -j -f. Same
# GNU-first/BSD-fallback shape as await-glm-worker.sh's iso_to_epoch.
iso_to_epoch() {
    date -d "$1" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${1%%.*}" +%s 2>/dev/null
}

# identity_started_epoch <identity> -- given a proc_tree_process_identity
# string, print the process's OWN reported start time as a Unix epoch. Kept
# local to this script: it depends on proc-tree.sh's identity STRING FORMAT
# (win:<winpid>:<ticks> / posix:<lstart> <command>), not its public contract,
# so a format change there is the one place both must move together. Empty
# output / nonzero rc when the identity cannot be parsed.
identity_started_epoch() {
    local identity="$1" ticks="" lstart=""
    case "$identity" in
        win:*)
            ticks="${identity##*:}"
            case "$ticks" in ''|*[!0-9]*) return 1 ;; esac
            # .NET ticks: 100ns units since 0001-01-01T00:00:00Z. The gap to
            # the Unix epoch (1970-01-01) is 621355968000000000 ticks.
            echo $(( (ticks - 621355968000000000) / 10000000 ))
            ;;
        posix:*)
            lstart="${identity#posix:}"
            # `ps -o lstart=` is the fixed-width "Dow Mon DD HH:MM:SS YYYY"
            # (24 chars), immediately followed by a space and the command.
            lstart="${lstart:0:24}"
            date -d "$lstart" +%s 2>/dev/null \
                || date -j -f "%a %b %e %T %Y" "$lstart" +%s 2>/dev/null
            ;;
        *) return 1 ;;
    esac
}

# SPAWN-TIME CORRELATION (CR round, HIMMEL-1693): the registry does not (yet)
# store an immutable spawn-time identity -- that needs a spawner-side change
# (spawn-glm.ts / spawn-claudex.ts write meta.json's `pid` but never an
# identity snapshot), which is out of scope for this chokepoint alone and is
# tracked as a residual, not silently skipped. Without it, comparing the
# freshly-sampled IDENTITY above against itself (the pre-fix shape) is a
# tautology: a RECYCLED pid always "matches" its own just-read identity.
#
# The strongest available check without that spawner change: the registry DID
# record started_at (a spawn-time timestamp, written before the pid was even
# known) at meta.json creation. A process that is genuinely still this worker
# reports a start time within seconds of started_at; a process that now
# occupies a recycled pid almost never does. Anything unparseable or outside a
# generous window is refused, never trusted. This is a correlation, not proof
# of identity -- it cannot rule out an unrelated process that happens to start
# in the same few minutes, but it closes the "any process, any age" gap the
# tautology left wide open.
REG_STARTED_AT="$(meta_field "$MATCH_META" started_at)"
if [ -z "$REG_STARTED_AT" ]; then
    echo "stop-worker: $SESSION_ID has no started_at recorded -- cannot identity-verify: no spawn-time identity recorded; refusing to signal" >&2
    exit 4
fi
REG_STARTED_EPOCH="$(iso_to_epoch "$REG_STARTED_AT")" || REG_STARTED_EPOCH=""
IDENTITY_EPOCH="$(identity_started_epoch "$IDENTITY")" || IDENTITY_EPOCH=""
if [ -z "$REG_STARTED_EPOCH" ] || [ -z "$IDENTITY_EPOCH" ]; then
    echo "stop-worker: cannot identity-verify $SESSION_ID (unparseable timestamp) -- refusing to signal" >&2
    exit 4
fi
# -60s tolerates clock skew between the started_at write and the process's own
# start; +900s (15min) tolerates a slow spawn (cold bun/npm start) without
# opening the window wide enough for an unrelated long-lived recycled pid to
# plausibly land inside it.
IDENTITY_DRIFT=$(( IDENTITY_EPOCH - REG_STARTED_EPOCH ))
if [ "$IDENTITY_DRIFT" -lt -60 ] || [ "$IDENTITY_DRIFT" -gt 900 ]; then
    echo "stop-worker: pid $PID's own start time does not correlate with $SESSION_ID's registered started_at (drift ${IDENTITY_DRIFT}s) -- this looks like a RECYCLED pid, not the registered worker; refusing to signal" >&2
    exit 4
fi

proc_tree_terminate "$PID" "$GRACE" "$IDENTITY"
TERM_RC=$?
HALT_STATUS="stopped-by-parent"
case "$TERM_RC" in
    0) echo "stop-worker: STOPPED $SESSION_ID (pid/group $PID gone, verified)" ;;
    3)
        echo "stop-worker: $SESSION_ID had already exited before any signal was sent"
        HALT_STATUS="already-exited"
        ;;
    2)
        echo "stop-worker: identity could not be confirmed before signalling pid $PID -- nothing was signalled" >&2
        exit 4
        ;;
    *)
        echo "stop-worker: signalled $SESSION_ID but something survived every verified escalation (rc=$TERM_RC) -- inspect pid $PID by hand" >&2
        exit 6
        ;;
esac

# Record the halt so a later reader (census, reconciliation, the judge) does not
# read a stopped worker as still running. TERM_RC=3 (already exited before any
# signal was sent) is recorded as "already-exited", never "stopped-by-parent" --
# that status must stay truthful about whether this chokepoint actually acted.
annotate_halt "$MATCH_META" "$CKPT_RESULT" "$HALT_STATUS" \
  || echo "WARN stop-worker: $SESSION_ID was stopped but its meta.json could not be annotated" >&2

# The worker is gone (TERM_RC 0 or 3 -- rc 2/other exited above, leaving it
# possibly alive and its tripwire deliberately intact).
clear_push_poison "$WORKER_WT"

exit 0
