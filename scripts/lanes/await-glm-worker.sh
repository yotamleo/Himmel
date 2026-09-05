#!/usr/bin/env bash
# await-glm-worker.sh - canonical bounded await for a GLM lane worker (HIMMEL-883).
#
# WHY: dispatchers repeatedly ended their turn promising "a background monitor
# will re-invoke me when the worker finishes"; that monitor can die silently
# and the parent session strands (observed 2026-07-10: worker done at 10:15Z,
# parent idled ~4h). This script is the structural replacement: a FOREGROUND,
# bounded poll of the worker session's meta.json that the dispatcher repeats
# inside its own turn until the worker reaches a terminal status.
#
# Usage:
#   await-glm-worker.sh [--session-dir <dir> | --slug <slug>] [--max-mins <n>]
#
#   --session-dir  exact worker session dir (contains meta.json)
#   --slug         worker slug; resolves the NEWEST session dir matching
#                  glm-<slug>-* under the glm-sessions root
#                  (BRIDGE_ROOT or ~/.claude/handover/bridge, + /glm-sessions)
#   --max-mins     how long THIS invocation polls before giving up (default 8;
#                  keep <= 8 so a Bash-tool call stays under its 10-min cap)
#   --stall-mins   HIMMEL-1378: no-output threshold before declaring a
#                  "running" session STALLED (default 6; see exit code 4)
#
# Exit codes:
#   0  worker reached a terminal status (meta.json + outbox tail printed)
#   2  no session dir / meta.json found
#   3  worker still running when the window closed (caller loops: re-invoke)
#   4  STALLED (HIMMEL-1378): status is "running", the recorded pid CANNOT be
#      probed (absent, 0, or the probe cannot answer), and no liveness signal
#      has moved for >= --stall-mins. A pid CONFIRMED alive never reads
#      STALLED (HIMMEL-1573) — see the fourth-signal comment in the loop.
#      Exits the poll loop EARLY (before --max-mins) instead of burning the
#      full window blind — the caller decides whether to keep waiting
#      (re-invoke) or escalate/retry. Never kills the worker.
#   5  PHANTOM (HIMMEL-1378): status is "running" but the recorded pid is
#      confirmed DEAD — the process exited/crashed without spawn-glm.ts ever
#      writing a terminal meta.json. Distinct from 4: this one is not
#      recoverable by waiting.
#
# 4/5 are evaluated ONLY when meta.json carries "started_at" (every real
# spawn-glm.ts session does, from the first "running" write onward) — a
# bare/minimal meta.json (as used by hermetic fixtures) skips both checks and
# falls through to the pre-existing running/deadline (rc 3) behavior
# unchanged.
set -u

POLL_SECS=10

session_dir=""
slug=""
max_mins=8
stall_mins=6
while [ $# -gt 0 ]; do
    case "$1" in
        # Guard the value: a bare `--slug` (value missing) would make `shift 2`
        # fail under set -u without set -e, leaving $# unchanged → infinite loop.
        # Fail fast like the unknown-arg case instead.
        --session-dir) [ $# -ge 2 ] || { echo "await-glm-worker: $1 needs a value" >&2; exit 2; }; session_dir="$2"; shift 2 ;;
        --slug) [ $# -ge 2 ] || { echo "await-glm-worker: $1 needs a value" >&2; exit 2; }; slug="$2"; shift 2 ;;
        --max-mins) [ $# -ge 2 ] || { echo "await-glm-worker: $1 needs a value" >&2; exit 2; }; max_mins="$2"; shift 2 ;;
        --stall-mins) [ $# -ge 2 ] || { echo "await-glm-worker: $1 needs a value" >&2; exit 2; }; stall_mins="$2"; shift 2 ;;
        *) echo "await-glm-worker: unknown arg: $1" >&2; exit 2 ;;
    esac
done

# True (rc 0) if PID names a live process; rc 1 if CONFIRMED dead; rc 2 if
# unknown/can't tell (never escalated to "phantom" on rc 2 — pid 0 is the
# spawn-glm.ts sentinel for "not yet known", not a dead process, and a
# broken/absent tasklist must not misreport a live worker as dead).
# Windows twin of arm-resume.sh's _pid_alive (same tasklist/MSYS_NO_PATHCONV
# shape; same "No tasks" clean-miss vs error-output distinction) — POSIX uses
# `kill -0` directly. Kept local to this script rather than sourced: the two
# call sites diverge on what "ambiguous" should mean (arm-resume treats
# ambiguous as dead — the safe direction for refusing a risky arm; this script
# treats ambiguous as unknown/non-escalating — the safe direction for NOT
# declaring a live worker phantom on a flaky tasklist).
pid_alive() {
    local pid="$1" out rc
    [ -n "$pid" ] && [ "$pid" != "0" ] || return 2
    case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
        msys*|cygwin*|win32*|MINGW*)
            out=$(MSYS_NO_PATHCONV=1 tasklist /FI "PID eq $pid" 2>&1); rc=$?
            case "$out" in
                *"No tasks"*) return 1 ;;
                *"$pid"*) [ "$rc" -eq 0 ] && return 0 ;;
            esac
            return 2
            ;;
        *)
            kill -0 "$pid" 2>/dev/null && return 0
            # kill -0's exit status collapses ESRCH (confirmed gone) and EPERM
            # (probe refused — the pid EXISTS but cannot be signalled) into the
            # same nonzero rc. Only ESRCH is confirmed death; EPERM must read
            # as unknown (rc 2), or an active-but-unprobeable worker gets
            # declared PHANTOM. Same message-parse as proc-tree.sh's
            # proc_tree_process_alive (CR round 1, PR #1603).
            err=$(LC_ALL=C kill -0 "$pid" 2>&1 >/dev/null)
            case "$err" in
                *"No such process"*) return 1 ;;
                *) return 2 ;;
            esac
            ;;
    esac
}

# Extract a JSON string/number field's value from a small meta.json (no jq
# dependency — this script has none today; matches the existing status-regex
# style above). head -1 takes the first match (meta.json is a flat object, no
# nesting under these key names).
extract_json_str() { grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" | head -1 | sed -E 's/^"[^"]+"[[:space:]]*:[[:space:]]*"//; s/"$//'; }
extract_json_num() { grep -oE "\"$2\"[[:space:]]*:[[:space:]]*[0-9]+" "$1" | head -1 | sed -E 's/.*:[[:space:]]*//'; }

# ISO-8601 timestamp -> epoch seconds. GNU `date -d` handles the format
# directly (incl. fractional seconds + trailing Z); BSD/macOS `date` lacks
# -d, so the fallback strips the fractional-seconds+Z suffix (everything from
# the first '.') and parses with -j -f against the whole-second format. Same
# GNU-first/BSD-fallback shape as scripts/statusline/lib/all-sessions-index.sh.
iso_to_epoch() {
    date -d "$1" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${1%%.*}" +%s 2>/dev/null
}

# Newest regular-file mtime under $1 as whole epoch seconds, .git excluded.
#
# HIMMEL-1614: `find -printf` is a GNU findutils extension. On BSD/macOS find
# it is an unknown primary, so the leg used to error into 2>/dev/null, return
# nothing, and the watchdog SILENTLY degraded to two liveness signals with no
# indication. newest_mtime runs whichever path matches MTIME_TOOL (detected
# once at startup): the GNU fast path that is verified working here, or a
# BSD/macOS `stat -f %m` equivalent that ships on every macOS box.
#
# `stat` was chosen over perl as the fallback: stat is already present
# wherever BSD find is, perl is an extra dependency, and a single perl form
# would drop the verified GNU path. This mirrors iso_to_epoch's GNU-first /
# BSD-second shape. Empty output (tool missing at runtime, or an empty tree)
# is rejected by the caller's digit-guard, so a transient miss fails safe --
# it merely fails to widen ALIVE.
newest_mtime() {
    case "$MTIME_TOOL" in
        gnu)
            find "$1" -path "$1/.git" -prune -o -type f -printf '%T@\n' 2>/dev/null |
                cut -d. -f1 | sort -n | tail -1
            ;;
        bsd)
            # BSD/macOS `stat -f %m` prints st_mtime as whole epoch seconds, so
            # the GNU pipeline's `cut -d. -f1` (dropping fractional seconds) is
            # not needed here; same max-of-mtimes via sort -n | tail -1.
            find "$1" -path "$1/.git" -prune -o -type f -exec stat -f %m {} + 2>/dev/null |
                sort -n | tail -1
            ;;
    esac
}

if [ -z "$session_dir" ] && [ -z "$slug" ]; then
    echo "await-glm-worker: need --session-dir or --slug" >&2
    exit 2
fi

resolve_session_dir() {
    # newest glm-<slug>-<epoch> dir, where <epoch> is a millisecond stamp.
    #
    # HIMMEL-1347: the `*` in the find -name pattern also matches any LONGER
    # slug sharing this one as a prefix, so `--slug foo` matched
    # `glm-foo-signal-<epoch>` (a different dispatch) as well as `glm-foo-<epoch>`.
    # In the C locale 's' > '1', so the prefix-sibling sorted LAST and won the
    # `tail -1` — the watchdog then reported a prior FAILED dispatch's terminal
    # status for a worker that was mid-run. The parent reads that as "worker
    # dead" and either abandons live work or re-dispatches a duplicate racing
    # the original on the same branch, which is a single-writer violation.
    #
    # find's -name cannot express "digits only", so the glob stays broad and
    # the remainder after "glm-<slug>-" is checked here: anything that is not
    # ALL DIGITS is a different slug, not an older run of this one. Ordering is
    # numeric on that epoch rather than lexical over the whole path — the old
    # comment's "equal-length stamps" assumption held only while every stamp
    # had the same width, which is exactly what the sibling broke.
    find "$GLM_SESSIONS_ROOT" -maxdepth 1 -type d -name "glm-${slug}-*" 2>/dev/null |
    while IFS= read -r _cand; do
        _stamp="${_cand##*/}"
        _stamp="${_stamp#"glm-${slug}-"}"
        case "$_stamp" in
            '' | *[!0-9]*) continue ;;
        esac
        printf '%s\t%s\n' "$_stamp" "$_cand"
    done | sort -n | tail -1 | cut -f2-
}

GLM_SESSIONS_ROOT="${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}/glm-sessions"

deadline=$(( $(date +%s) + max_mins * 60 ))

# HIMMEL-1614: detect the mtime-leg toolchain ONCE (not per-poll). `find
# -printf` is a GNU findutils extension; on BSD/macOS find it is an unknown
# primary, so the leg used to error into 2>/dev/null and silently degrade the
# watchdog to two liveness signals. Probe the REAL capability (not
# `find --version`, whose flags also differ by platform) and remember it:
#   gnu  -> GNU find -printf (the verified fast path on Linux / Git Bash)
#   bsd  -> BSD/macOS `stat -f %m` (ships on every macOS box)
#   none -> neither; newest_mtime is skipped and a single notice is emitted
# -maxdepth 0 keeps the find probe to one stat of / rather than a walk.
if find / -maxdepth 0 -printf '%T@\n' >/dev/null 2>&1; then
    MTIME_TOOL=gnu
elif stat -f %m / >/dev/null 2>&1; then
    MTIME_TOOL=bsd
else
    MTIME_TOOL=none
fi
while :; do
    d="$session_dir"
    if [ -z "$d" ]; then
        d="$(resolve_session_dir)"
    fi
    if [ -n "$d" ] && [ -f "$d/meta.json" ]; then  # fail-open-ok: unreadable/torn meta.json reads as NON-terminal (positive-match rule below) — polling continues to the deadline
        # Positively require a KNOWN terminal status (the finalMeta set in
        # spawn-glm.ts) before completing. Anything else — "running", an
        # unrecognized status, or a torn read mid-rewrite — is treated as
        # not-yet-terminal and falls through to the deadline check, so we keep
        # polling instead of falsely completing on a partial write. This is the
        # exact strand (premature terminal) the watchdog exists to prevent.
        # Whitespace-tolerant because a producer reformat must not silently
        # break detection (producer currently emits JSON.stringify(...,null,2)).
        # HIMMEL-1641: done_escalated (F1, a finished worker hitting the
        # lane's structural git-push block) and killed-by-caller (F2, a
        # dispatcher-side SIGTERM finalize) are both terminal — without them
        # here a healthy/correctly-finalized worker reads as still-running and
        # burns the rest of this poll's window instead of completing at once.
        # HIMMEL-1693: stop-worker.sh's annotate_halt writes stopped-by-parent
        # (signalled) / already-exited (confirmed gone before any signal) and
        # always zeros pid alongside them — without both listed here, a halted
        # worker's pid=0 falls through to the liveness check below (unprobeable)
        # and eventually reads STALLED/deadline instead of the terminal halt it
        # already recorded.
        if grep -qE '"status"[[:space:]]*:[[:space:]]*"(done|failed|capped|blocked|timeout|done_escalated|killed-by-caller|stopped-by-parent|already-exited)"' "$d/meta.json"; then
            echo "await-glm-worker: TERMINAL: $d"
            cat "$d/meta.json"
            echo
            if [ -f "$d/outbox.jsonl" ]; then  # fail-open-ok: display-only outbox tail after a terminal status — an unreadable outbox costs the echo, nothing else
                echo "--- outbox tail ---"
                tail -3 "$d/outbox.jsonl"
            fi
            exit 0
        fi
        # not terminal yet (still "running", or an unrecognized/torn status).
        # HIMMEL-1378 process-liveness check: gated on "started_at" being
        # present so a bare/minimal fixture meta.json (no started_at) is
        # untouched by this block and falls straight to the pre-existing
        # deadline check below, unchanged.
        started_at=$(extract_json_str "$d/meta.json" started_at)
        if [ -n "$started_at" ]; then
            last_out=$(extract_json_str "$d/meta.json" last_output_at)
            [ -n "$last_out" ] || last_out="$started_at"
            last_epoch=$(iso_to_epoch "$last_out")
            if [ -n "$last_epoch" ]; then
                pid=$(extract_json_num "$d/meta.json" pid)
                pid_alive "$pid"; palive=$?
                if [ "$palive" -eq 1 ]; then
                    echo "await-glm-worker: PHANTOM: $d (recorded pid ${pid:-<none>} is not alive; meta.json still says running)"
                    cat "$d/meta.json"
                    echo
                    exit 5
                fi
                elapsed=$(( $(date +%s) - last_epoch ))
                stall_secs=$(( stall_mins * 60 ))
                # HIMMEL-1596 Task 1.2: last_output_at ALONE lies in one
                # direction. A worker that commits early and leaves a clean
                # tree emits nothing further, so the better-behaved it is, the
                # more it reads STALLED -- the same false-positive class this
                # watchdog exists to remove. Widen to the MAXIMUM of three
                # signals: recorded output, newest worktree mtime, and branch
                # HEAD commit time.
                #
                # Computed ONLY here, on the verge of declaring STALLED, not
                # every poll: a max can only ever widen ALIVE, so consulting
                # the expensive signals early cannot change a live verdict --
                # it would just walk the worktree every POLL_SECS for nothing.
                #
                # refs/checkpoints/<slug> is deliberately NOT a signal. Task
                # 1.1 writes the checkpoint only after the run ENDS, so during
                # the await window it is either absent or -- on a re-dispatch
                # reusing the slug -- a stale ref from the PREVIOUS dispatch,
                # which would read as a false ALIVE. Revisit only if
                # checkpointing ever becomes periodic.
                #
                # Accepted false-negative: a wedged worker that keeps writing
                # files still reads alive. A max cannot distinguish "busy" from
                # "progressing"; the hard deadline (rc 3) is the backstop.
                #
                # HIMMEL-1573: process liveness is the FOURTH signal, and it
                # short-circuits. The three signals above/below are all
                # WRITE-side (recorded output, worktree mtime, HEAD commit),
                # so none can see a worker in its READ/PLAN phase — measured
                # 2026-08-07: a verifiably-alive worker (pid running per
                # ps -W) was declared STALLED at the default window while it
                # was reading. A pid CONFIRMED alive is not stalled, full
                # stop — keep polling; the hard --max-mins window (rc 3)
                # remains the backstop for an alive-but-wedged worker. rc 4
                # is reserved for a pid that cannot be probed (absent, 0, or
                # probe failure) with every write-side signal stale.
                if [ "$palive" -ne 0 ] && [ "$elapsed" -ge "$stall_secs" ]; then
                    # HIMMEL-1616: prefer the worker's own minted worktree.
                    # The legacy `worktree` key records the DISPATCH CWD, so
                    # walking it sweeps every sibling worktree in the checkout
                    # and a SIBLING worker's writes read as THIS worker's
                    # liveness — a false ALIVE, the dangerous direction. The
                    # fallback keeps a meta.json written by an older spawner
                    # working (same optional-fields contract as HIMMEL-1596).
                    wt=$(extract_json_str "$d/meta.json" worker_worktree)
                    [ -n "$wt" ] || wt=$(extract_json_str "$d/meta.json" worktree)
                    br=$(extract_json_str "$d/meta.json" branch)
                    if [ -n "$wt" ] && [ -d "$wt" ]; then
                        # .git is excluded on purpose: it churns for reasons
                        # that are not worker progress, and the commit signal
                        # below covers real git activity precisely.
                        #
                        # HIMMEL-1614: newest_mtime runs the portable path for
                        # this host (MTIME_TOOL, detected once at startup). When
                        # the leg has NO usable toolchain it emits ONE stderr
                        # note (mt_warned) and contributes nothing, rather than
                        # the old silent degrade to two signals. The digit-guard
                        # still handles an empty value at runtime either way.
                        if [ "$MTIME_TOOL" != none ]; then
                            mt=$(newest_mtime "$wt")
                            case "$mt" in
                                ''|*[!0-9]*) ;;
                                *) [ "$mt" -gt "$last_epoch" ] && last_epoch="$mt" ;;
                            esac
                        elif [ -z "${mt_warned:-}" ]; then
                            echo "await-glm-worker: mtime liveness leg unavailable on this host (no GNU 'find -printf' and no BSD 'stat -f %m'); degrading to output + commit signals" >&2
                            mt_warned=1
                        fi
                        ct=$(git -C "$wt" log -1 --format=%ct "${br:-HEAD}" 2>/dev/null)
                        case "$ct" in
                            ''|*[!0-9]*) ;;
                            *) [ "$ct" -gt "$last_epoch" ] && last_epoch="$ct" ;;
                        esac
                    fi
                    elapsed=$(( $(date +%s) - last_epoch ))
                fi
                if [ "$palive" -ne 0 ] && [ "$elapsed" -ge "$stall_secs" ]; then
                    echo "await-glm-worker: STALLED: $d (no output for ${elapsed}s >= --stall-mins ${stall_mins}m; last activity $last_out; pid ${pid:-<none>} unprobeable)"
                    cat "$d/meta.json"
                    echo
                    exit 4
                fi
            fi
        fi
        # fall through to the deadline check
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
        if [ -z "$d" ] || [ ! -f "$d/meta.json" ]; then
            echo "await-glm-worker: no session found (slug=${slug:-} dir=${session_dir:-}) under $GLM_SESSIONS_ROOT" >&2
            exit 2
        fi
        echo "await-glm-worker: still running after ${max_mins}m: $d (re-invoke to keep waiting)"
        exit 3
    fi
    sleep "$POLL_SECS"
done
