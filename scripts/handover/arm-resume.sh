#!/usr/bin/env bash
# arm-resume.sh — actually create the scheduled relaunch + dedupe.
#
# Unlike scripts/handover/schedule-resume.sh (which prints the
# platform scheduler command for operator copy-paste review), this
# script:
#   1. dedupes against the CURRENT handover's HIMMEL-Resume-<name> job
#      in the OS scheduler — refuses (rc=3) or replaces with --force,
#      so we never end up with two claude sessions cron-relaunched for
#      the SAME handover (the user's stated requirement for HIMMEL-122).
#      Distinct handovers each get their own slot (HIMMEL-340); pass
#      --dedup-any to instead defer to ANY existing slot (the auto-arm
#      watchdog safety-arm semantics — never queue a duplicate relaunch).
#   2. directly invokes schtasks / at / crontab — does NOT round-trip
#      through schedule-resume.sh's mixed prose+command stdout (the
#      v1 attempt at this script did, which silently failed because
#      bash parsed the prose lines as commands and the banner lied
#      about success)
#   3. injects a HIMMEL-Resume-<task_name> marker into the at-job
#      body so POSIX dedup actually matches (v1 grepped for a marker
#      that schedule-resume.sh never emitted)
#   4. emits a loud post-arm banner reminding operator to /exit
#
# This is the *arm* half of HIMMEL-122 (auto-resume on usage-cap
# detection). The *detect* half (monitoring claude-statusline / API
# rate-limit signals to auto-trigger this) is a separate wedge.
#
# Usage:
#   bash scripts/handover/arm-resume.sh \
#     --time <HH:MM> --handover <path> [--force] [--dedup-any] [--dry-run]
#
# Required:
#   --time <HH:MM>     24h local time. Today if future, tomorrow if past.
#   --handover <path>  Resume marker file path. Must exist. Pasted into
#                      the claude relaunch prompt so the next session
#                      picks up state.
#
# Optional:
#   --force            Replace the existing same-handover HIMMEL-Resume job
#                      (with --dedup-any, any existing HIMMEL-Resume job).
#                      Default refuses (rc=3) — explicit opt-in only.
#   --dedup-any        Dedup against ANY HIMMEL-Resume job, not just this
#                      handover's (HIMMEL-340 safety-arm semantics).
#   --dry-run          Print what would be scheduled, touch nothing.
#
# Env:
#   ARM_MAX_SLOTS      Soft cap on concurrent resume slots (default 4, 0
#                      disables). Arming past it WARNs but never blocks.
#
# Exit codes:
#   0  scheduler armed (or printed under --dry-run)
#   1  usage / input error
#   2  required tool missing or env unusable (no schtasks/at/crontab;
#      no platform match; dedup-check tool itself errored — fail-closed
#      rather than risk a duplicate)
#   3  dedup block — a same-handover HIMMEL-Resume job exists (or, under
#      --dedup-any, any HIMMEL-Resume job exists); pass --force to replace
#   4  scheduler invocation failed (job NOT armed; stderr above)
#   5  refused — --channels passed while the bun Telegram bridge is live
#      (HIMMEL-225: a 2nd getUpdates consumer 409s + the dev-channels prompt
#      hangs an unattended relaunch). Drop --channels (the bun bridge owns
#      Telegram) or, after stopping the bridge, override with ARM_CHANNELS_OK=1.
set -euo pipefail

RESUME_TIME=""
HANDOVER_PATH=""
FORCE=0
DRY_RUN=0
RESUME_CWD_OVERRIDE=""
CHANNELS=""
DEDUP_ANY=0

# Local HH:MM from an epoch (armored python3 — portable, no GNU `date -d`;
# capture via file so a wedged Store stub can't hang the $() call sites).
_epoch_hhmm() { py_armor_capture -c 'import sys,datetime; print(datetime.datetime.fromtimestamp(int(sys.argv[1])).astimezone().strftime("%H:%M"))' "$1" && printf '%s\n' "$PY_ARMOR_OUT"; }

usage() {
    cat <<'EOF'
Usage: arm-resume.sh --time <HH:MM> --handover <path> [--force] [--dedup-any] [--dry-run]

Arms the OS scheduler to relaunch claude at the given time with a
resume prompt referencing the given handover file. Dedup-guarded
against existing HIMMEL-Resume-* jobs; pass --force to replace.

Required:
  --time <HH:MM|smart|auto>
                       24h local time, OR a sentinel resolved from the
                       claude-statusline usage cache:
                         smart — usage-aware: relaunch ASAP when the bank
                                 has headroom, else wait for the binding
                                 window's reset (scripts/handover/resume-slot.sh).
                                 Maximizes throughput — prefer this.
                         auto  — next 5-hour cap reset regardless of headroom
                                 (scripts/handover/cap-reset-time.sh).
                       A past HH:MM rolls to tomorrow; sentinels carry their
                       own (possibly multi-day) date.
  --handover <path>    Resume marker file (must exist)

Optional:
  --cwd <path>       Working directory for the relaunched claude.
                     Default: git toplevel containing the --handover
                     file. Override when the handover lives in a
                     different repo than the one claude should run
                     from (e.g. hop.sh writes the snapshot under
                     yotam_docs but the origin session was in himmel).
                     If the handover file's YAML frontmatter contains
                     'resume_cwd: <path>', that value is used when
                     --cwd is omitted (set this for cross-repo
                     handovers so the correct repo is used without
                     requiring an explicit --cwd every time).
  --channels <spec>  Pass --channels <spec> to the relaunched claude so
                     the spawned session opens that channel. NOT for
                     Telegram: the always-on bun bridge (HIMMEL-207/208)
                     owns the single getUpdates slot, so a --channels
                     Telegram relaunch 409s against it AND its dev-channels
                     prompt hangs an unattended launch. This script REFUSES
                     --channels (rc=5) while the bun bridge is live — drop
                     it and relaunch PLAIN (bridge reaches Telegram on its
                     own). Override only after `bun supervisor.ts --kill`
                     with ARM_CHANNELS_OK=1. Omit for a silent relaunch.
  --force            Replace the existing same-handover HIMMEL-Resume job
  --dedup-any        Dedup against ANY HIMMEL-Resume job, not just this
                     handover's: arm only if NO resume slot exists at all.
                     The safety-arm semantics the auto-arm watchdogs use so
                     a machine-wide cap can never queue duplicate relaunches.
                     Default (omitted) is per-handover dedup — N distinct
                     handovers each get their own slot (HIMMEL-340).
  --dry-run          Print what would be scheduled, touch nothing

Env:
  ARM_MAX_SLOTS      Soft cap on concurrent resume slots (default 4, 0
                     disables). Arming past it WARNs but never blocks.
EOF
}

# Arg parsing — accept --flag <value> or --flag=<value>, any order,
# unknown flags are rejected loudly. Avoids the v1 "$3 == --force"
# positional trap.
while [ $# -gt 0 ]; do
    case "$1" in
        --time)        RESUME_TIME="${2:-}"; shift 2 ;;
        --time=*)      RESUME_TIME="${1#--time=}"; shift ;;
        --handover)    HANDOVER_PATH="${2:-}"; shift 2 ;;
        --handover=*)  HANDOVER_PATH="${1#--handover=}"; shift ;;
        --cwd)         RESUME_CWD_OVERRIDE="${2:-}"; shift 2 ;;
        --cwd=*)       RESUME_CWD_OVERRIDE="${1#--cwd=}"; shift ;;
        --channels)    CHANNELS="${2:-}"; shift 2 ;;
        --channels=*)  CHANNELS="${1#--channels=}"; shift ;;
        --force)       FORCE=1; shift ;;
        --dedup-any)   DEDUP_ANY=1; shift ;;
        --dry-run)     DRY_RUN=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "ERR arm-resume: unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [ -z "$RESUME_TIME" ] || [ -z "$HANDOVER_PATH" ]; then
    echo "ERR arm-resume: --time and --handover are required" >&2
    usage >&2
    exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# python3 hang armor (HIMMEL-249): the Windows Store python3 stub can wedge
# (ignores SIGTERM, orphan child holds the $() pipe). The auto-arm-on-cap
# watchdog calls this script, so the armor chain is only as strong as the
# weakest python call here — every one goes through the shared armor.
# shellcheck source=../lib/py-armor.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/py-armor.sh"

# 0-cost telemetry seam (HIMMEL-236): measure-during for in-use skills —
# one disk append per arm outcome, nothing into context. FAIL-OPEN both
# ways: a missing/broken lib must never block an arm (no-op fallback
# below), and telemetry_emit itself always returns 0 under our set -e.
# Format spec: docs/tool-adoption/telemetry.md.
# shellcheck source=../lib/telemetry.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/telemetry.sh" 2>/dev/null || true
command -v telemetry_emit >/dev/null 2>&1 || telemetry_emit() { return 0; }

# Canonicalise a path, tolerating non-existent ones: GNU realpath -m, else
# armored python3 pathlib, else the input unchanged (best effort — matches
# the prior inline fallback chains).
_arm_realpath() {
    local _p=""
    _p=$(realpath -m "$1" 2>/dev/null) || _p=""
    if [ -z "$_p" ]; then
        if py_armor_capture -c 'import sys,pathlib;print(pathlib.Path(sys.argv[1]).resolve(strict=False))' "$1" 2>/dev/null; then
            _p="$PY_ARMOR_OUT"
        fi
    fi
    [ -n "$_p" ] || _p="$1"
    printf '%s\n' "$_p"
}

# Resolve the requested slot to an absolute epoch (TARGET_EPOCH). Three forms:
#   smart  — usage-aware: ASAP when the bank is free, else the binding window's
#            reset (resume-slot.sh, HIMMEL-204). Operator no longer has to
#            guess AND we don't park hours away when quota is available.
#   auto   — next 5-hour cap reset regardless of headroom (cap-reset-time.sh,
#            HIMMEL-126). Kept for "explicitly wait for the reset".
#   HH:MM  — explicit local clock time; today if still future, else tomorrow.
TARGET_EPOCH=""
case "$RESUME_TIME" in
    smart)
        # --max-age 3600: arming runs at session END, when the statusline may
        # not have re-rendered for several minutes, so tolerate older usage
        # data than a live render would. The 5-hour / 7-day windows move
        # slowly; an hour-old reading is still a sound ASAP-vs-wait signal. A
        # genuinely abandoned cache (>1h) still errors out. SLOT_MAX_AGE
        # overrides for tests / tighter freshness; RESUME_SLOT_CACHE injects a
        # fixture cache (test seam — keeps the smart path end-to-end testable).
        _slot_args=(--max-age "${SLOT_MAX_AGE:-3600}")
        [ -n "${RESUME_SLOT_CACHE:-}" ] && _slot_args+=(--cache "$RESUME_SLOT_CACHE")
        # One --emit all call (epoch<TAB>hhmm<TAB>reason) — avoids a second,
        # independent read of a ~60s-rewritten cache that could disagree with
        # the chosen epoch. set +e so we can relay resume-slot's own ERR.
        set +e
        _slot_out=$(bash "$SCRIPT_DIR/resume-slot.sh" "${_slot_args[@]}" --emit all 2>/tmp/arm-resume.slot-err.$$)
        _slot_rc=$?
        set -e
        if [ "$_slot_rc" -ne 0 ]; then
            echo "ERR arm-resume: --time smart could not resolve a slot:" >&2
            sed 's/^/    /' /tmp/arm-resume.slot-err.$$ >&2
            rm -f /tmp/arm-resume.slot-err.$$
            echo "    Pass --time HH:MM manually, or open Claude Code once to refresh" >&2
            echo "    the statusline usage cache, then retry --time smart." >&2
            exit 1
        fi
        rm -f /tmp/arm-resume.slot-err.$$
        TARGET_EPOCH=$(printf '%s' "$_slot_out" | cut -f1)
        _reason=$(printf '%s' "$_slot_out" | cut -f3-)
        echo "arm-resume: --time smart -> $(_epoch_hhmm "$TARGET_EPOCH") (${_reason:-usage-aware})"
        ;;
    auto)
        if ! TARGET_EPOCH=$(bash "$SCRIPT_DIR/cap-reset-time.sh" --epoch 2>/tmp/arm-resume.cap-err.$$); then
            echo "ERR arm-resume: --time auto could not resolve cap-reset:" >&2
            sed 's/^/    /' /tmp/arm-resume.cap-err.$$ >&2
            rm -f /tmp/arm-resume.cap-err.$$
            echo "    Pass --time HH:MM manually, or open Claude Code once to refresh" >&2
            echo "    the statusline usage cache, then retry --time auto." >&2
            exit 1
        fi
        rm -f /tmp/arm-resume.cap-err.$$
        echo "arm-resume: --time auto -> $(_epoch_hhmm "$TARGET_EPOCH") (next cap reset)"
        ;;
    *)
        if ! [[ "$RESUME_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
            echo "ERR arm-resume: --time must be HH:MM (24h), 'smart', or 'auto', got: $RESUME_TIME" >&2
            exit 1
        fi
        py_armor_capture -c '
import sys
from datetime import datetime, timedelta
hh, mm = (int(x) for x in sys.argv[1].split(":"))
now = datetime.now().astimezone()
cand = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
if cand <= now:          # time already passed today -> tomorrow
    cand += timedelta(days=1)
print(int(cand.timestamp()))
' "$RESUME_TIME" || {
            echo "ERR arm-resume: could not resolve --time $RESUME_TIME to an epoch (python3 failed/timed out)" >&2
            exit 2
        }
        TARGET_EPOCH="$PY_ARMOR_OUT"
        ;;
esac

# Derive the local clock fields the schedulers need from TARGET_EPOCH:
#   RESUME_TIME  HH:MM        — schtasks /st, at, banner
#   START_DATE   MM/DD/YYYY   — schtasks /sd. FIXES the bug where /st with no
#                /sd defaulted to TODAY, so a time already past today gave
#                "Next Run Time: N/A" and never fired (HIMMEL-204). NOTE:
#                schtasks /sd parses per the user's Windows short-date LOCALE;
#                MM/DD/YYYY is correct for US-format machines (this repo's
#                operator env). On a dd/MM/yyyy locale schtasks would reject or
#                misread it — locale-adaptive /sd is a follow-up if this tool
#                ever runs on a non-US Windows box.
#   AT_STAMP     YYYYMMDDhhmm — at -t, an exact datetime (replaces the
#                today/tomorrow heuristic that broke for resets >24h out).
# Capture FIRST (explicit || handler — a $(...) failure inside a heredoc
# body would not abort), then validate non-empty before arming.
py_armor_capture -c '
import sys, datetime
dt = datetime.datetime.fromtimestamp(int(sys.argv[1])).astimezone()
print(dt.strftime("%H:%M"), dt.strftime("%m/%d/%Y"), dt.strftime("%Y%m%d%H%M"))
' "$TARGET_EPOCH" || {
    echo "ERR arm-resume: could not derive schedule fields from epoch $TARGET_EPOCH" >&2
    exit 2
}
_sched_fields="$PY_ARMOR_OUT"
read -r RESUME_TIME START_DATE AT_STAMP <<<"$_sched_fields"
if [ -z "$RESUME_TIME" ] || [ -z "$START_DATE" ] || [ -z "$AT_STAMP" ]; then
    echo "ERR arm-resume: derived schedule fields empty (epoch=$TARGET_EPOCH) — refusing to arm" >&2
    exit 2
fi

if [ ! -f "$HANDOVER_PATH" ]; then
    echo "ERR arm-resume: --handover file not found: $HANDOVER_PATH" >&2
    exit 1
fi

# Platform detect.
case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    msys*|cygwin*|win32*|MINGW*) PLATFORM=windows ;;
    linux*|Linux*)               PLATFORM=linux ;;
    darwin*|Darwin*)             PLATFORM=macos ;;
    *)
        echo "ERR arm-resume: unsupported platform (OSTYPE=${OSTYPE:-})" >&2
        echo "    Supported: Windows (Git Bash / MSYS / Cygwin), Linux, macOS" >&2
        exit 2
        ;;
esac

# Tool detection per platform.
case "$PLATFORM" in
    windows)
        command -v schtasks >/dev/null 2>&1 || {
            echo "ERR arm-resume: 'schtasks' not on PATH (required on Windows)" >&2
            exit 2
        }
        ;;
    linux|macos)
        if ! command -v at >/dev/null 2>&1 && ! command -v crontab >/dev/null 2>&1; then
            echo "ERR arm-resume: neither 'at' nor 'crontab' on PATH" >&2
            echo "    Install 'at': Debian/Ubuntu: sudo apt install at && sudo systemctl enable --now atd" >&2
            echo "    macOS:        at is preinstalled; enable atd via launchctl" >&2
            exit 2
        fi
        ;;
esac

# True (rc 0) if PID names a live process. POSIX: `kill -0`. Windows (Git
# Bash): the bun bridge is a NATIVE win32 process whose pid MSYS `kill -0`
# can't see, so query `tasklist` by PID filter instead. (Pid reuse could
# false-positive, but the supervisor clears its pidfile on clean exit and a
# false "live" only ever errs toward the SAFE side here — refusing a risky
# --channels arm.)
_pid_alive() {
    local pid="$1"
    [ -n "$pid" ] || return 1
    case "$PLATFORM" in
        windows)
            # Capture stdout+stderr together (NOT 2>/dev/null) so a broken/absent
            # tasklist is distinguishable from a clean miss (HIMMEL-228). A clean
            # miss prints "No tasks are running..." (legit dead pid); a genuine
            # tooling failure prints something else (e.g. "ERROR: ..."). If we
            # silently swallowed a malfunctioning tasklist, every pid would read
            # "dead" and bridge_poller_live would fail OPEN — the unsafe direction.
            local out rc
            out=$(MSYS_NO_PATHCONV=1 tasklist /FI "PID eq $pid" 2>&1); rc=$?
            # A clean "No tasks" miss is an authoritative dead-pid -> return 1
            # without warning. A pid match counts as LIVE only on a clean exit
            # (rc 0): a nonzero rc that merely echoed the pid digits into stderr
            # (a tasklist error variant) must NOT short-circuit to "alive" — gate
            # the match on rc==0 so it falls through to the warn branch instead
            # of masking the failure the rc check is meant to surface (HIMMEL-228).
            case "$out" in
                *"No tasks"*) return 1 ;;
                *"$pid"*)     [ "$rc" -eq 0 ] && return 0 ;;
            esac
            # Reached when: no "No tasks" miss AND (no pid match, OR a pid match
            # with a nonzero rc). If tasklist exited nonzero it likely failed
            # (broken/absent) rather than reporting a clean dead-pid. Warn so a
            # broken toolchain is visible instead of silently disabling the guard;
            # keep returning 1 (dead).
            if [ "$rc" -ne 0 ]; then
                echo "WARN arm-resume: tasklist exited $rc with no 'No tasks' miss for PID $pid — treating as dead, but tasklist may be broken/absent (output: ${out:-<empty>})" >&2
            fi
            return 1
            ;;
        *)
            kill -0 "$pid" 2>/dev/null
            ;;
    esac
}

# rc 0 if the always-on bun Telegram bridge (HIMMEL-207/208) appears to be
# running. Liveness = the supervisor pidfile exists AND at least one recorded
# pid (supervisor or poller) is alive. ARM_BRIDGE_LIVE is a test seam (1/0
# forces the answer without a real process); BRIDGE_PIDFILE / BRIDGE_ROOT
# mirror bus.ts's resolution (`$BRIDGE_ROOT ?? ~/.claude/handover/bridge`) so a
# real check inspects the same supervisor.pid the bridge actually wrote.
bridge_poller_live() {
    case "${ARM_BRIDGE_LIVE:-}" in
        1) return 0 ;;
        0) return 1 ;;
    esac
    local pidfile="${BRIDGE_PIDFILE:-${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}/supervisor.pid}"
    # Pidfile ABSENT -> bridge not running -> not live (a --channels arm may
    # proceed). Pidfile PRESENT but unreadable/empty -> we CANNOT confirm the
    # bridge is down, and a present pidfile most likely means it IS up (the
    # supervisor wrote it; it may just be torn mid-write), so fail CLOSED: treat
    # as live and let the guard refuse. The operator's escape for a genuinely
    # stale/corrupt file is the documented ARM_CHANNELS_OK=1.
    [ -f "$pidfile" ] || return 1
    local pids parse_rc=0
    # Armored capture (HIMMEL-249): a wedged python3 stub reads as a parse
    # failure (nonzero rc -> fail-closed WARN below), never a hang. The `||`
    # also keeps this errexit-safe regardless of the call context.
    py_armor_capture -c '
import json, sys
try:
    with open(sys.argv[1]) as fh:
        o = json.load(fh)
except Exception:
    sys.exit(0)
for k in ("supervisor", "poller"):
    v = o.get(k)
    if isinstance(v, int) and v > 0:
        print(v)
' "$pidfile" 2>/dev/null || parse_rc=$?
    pids="$PY_ARMOR_OUT"
    if [ "$parse_rc" -ne 0 ] || [ -z "$pids" ]; then
        echo "WARN arm-resume: bridge pidfile present but unreadable/empty ($pidfile);" >&2
        echo "    treating the Telegram bridge as LIVE (fail-closed). If it is genuinely" >&2
        echo "    down, override with ARM_CHANNELS_OK=1." >&2
        return 0
    fi
    # >=1 recorded pid parsed: live iff any is still running. ALL dead = a stale
    # pidfile from a crashed bridge -> not live (the arm may proceed).
    local pid
    while IFS= read -r pid; do
        [ -n "$pid" ] && _pid_alive "$pid" && return 0
    done <<< "$pids"
    return 1
}

# HIMMEL-225: refuse to arm a --channels relaunch while the bun Telegram
# bridge is live. Telegram reachability comes from the bun bridge, NOT from a
# session holding --channels, and a --channels relaunch alongside the live
# bridge is unattended-fatal two ways: (1) it is a 2nd getUpdates consumer ->
# 409 Conflict (neither settles); (2) --channels needs
# --dangerously-load-development-channels, whose prompt does NOT persist -> the
# scheduled relaunch HANGS on it forever. So the anti-lockout default is a
# PLAIN relaunch. ARM_CHANNELS_OK=1 overrides (also the escape for a stale
# pidfile) — use only after stopping the bridge (`bun supervisor.ts --kill`).
if [ -n "$CHANNELS" ] && [ -z "${ARM_CHANNELS_OK:-}" ] && bridge_poller_live; then
    {
        echo "ERR arm-resume: refusing --channels while the bun Telegram bridge is live."
        echo "    A --channels relaunch becomes a 2nd getUpdates consumer (409 Conflict)"
        echo "    AND --dangerously-load-development-channels prompts interactively, so an"
        echo "    unattended relaunch HANGS. The bun bridge already owns Telegram — relaunch"
        echo "    PLAIN (drop --channels)."
        echo "    To really arm --channels: stop the bridge first (bun supervisor.ts --kill),"
        echo "    then re-run with ARM_CHANNELS_OK=1. See docs/internals/telegram-bridge.md."
    } >&2
    exit 5
fi

# Task name — sanitize handover path for use as a task identifier.
# Matches the convention from schedule-resume.sh:88 so jobs created by
# either route share a name space (operator can manage them with the
# same schtasks/atq commands).
# shellcheck disable=SC1003  # `\\` in single quotes is two backslashes which tr collapses to one literal `\` — intentional
TASK_NAME="HIMMEL-Resume-$(printf '%s' "$HANDOVER_PATH" | tr '/\\' '__' | tr -cd '[:alnum:]_-')"
RESUME_PROMPT="load $HANDOVER_PATH overnight mode"

# Compute working directory for the relaunched claude process. Without
# this, schtasks fires .bat with CWD=C:\Windows\System32 (and at/cron
# fire with CWD=$HOME or /), so claude.exe lands outside the repo:
# relative handover paths resolve to System32\handovers\..., the
# block-edit-on-main hook can't find .git, and claude registers an
# unintended "C:\Windows\System32" project in ~/.claude/projects/.
#
# Priority:
#   1. --cwd override. hop.sh (HIMMEL-130) passes the ORIGIN repo here
#      because the handover lives in yotam_docs but claude must run
#      from the origin repo, not yotam_docs.
#   2. resume_cwd: in the handover file's YAML frontmatter. Lets a
#      handover in yotam_docs declare its own work-repo without
#      requiring an explicit --cwd at every arm-resume call.
#   3. Auto-detect: git toplevel containing the handover file.
#   4. Fallback: handover's parent dir if it isn't tracked by git.
if [ -n "$RESUME_CWD_OVERRIDE" ]; then
    if [ ! -d "$RESUME_CWD_OVERRIDE" ]; then
        echo "ERR arm-resume: --cwd path does not exist: $RESUME_CWD_OVERRIDE" >&2
        exit 1
    fi
    RESUME_CWD=$(_arm_realpath "$RESUME_CWD_OVERRIDE")
else
    # Extract resume_cwd: from the first YAML frontmatter block only.
    # awk collects lines between the first two --- markers; sed picks
    # the resume_cwd: value; head -1 takes only the first match.
    _fm_cwd=$(awk '/^---[[:space:]]*$/{c++; next} c==1' "$HANDOVER_PATH" \
        | sed -n 's/^resume_cwd:[[:space:]]*//p' | head -1)
    # rtrim FIRST (removes trailing \r on CRLF files too), THEN strip
    # surrounding quotes. Order matters: on CRLF input the raw value is
    # `"/path"\r`; quote-strip looks for a trailing `"` but the last
    # byte is `\r` so it no-ops, leaving `/path"` after rtrim strips `\r`.
    _fm_cwd="${_fm_cwd%"${_fm_cwd##*[![:space:]]}"}"  # rtrim (incl \r)
    _fm_cwd="${_fm_cwd#\'}" ; _fm_cwd="${_fm_cwd%\'}"
    _fm_cwd="${_fm_cwd#\"}" ; _fm_cwd="${_fm_cwd%\"}"
    # Track whether the key was present (non-empty after trim+unquote)
    # so the fallback block can emit the correct discoverability message.
    _fm_cwd_found=0
    [ -n "$_fm_cwd" ] && _fm_cwd_found=1

    if [ -n "$_fm_cwd" ]; then
        if [ -d "$_fm_cwd" ]; then
            RESUME_CWD=$(_arm_realpath "$_fm_cwd")
        else
            echo "WARN arm-resume: handover resume_cwd: '$_fm_cwd' is not a directory — ignoring, falling back" >&2
            _fm_cwd=""
        fi
    fi

    if [ -z "$_fm_cwd" ]; then
        _handover_abs=$(_arm_realpath "$HANDOVER_PATH")
        _handover_dir=$(dirname "$_handover_abs")
        if ! RESUME_CWD=$(git -C "$_handover_dir" rev-parse --show-toplevel 2>/dev/null); then
            RESUME_CWD="$_handover_dir"
        fi
        unset _handover_abs _handover_dir
        # Only emit the discoverability warning when resume_cwd was genuinely
        # absent from the frontmatter. When it was present-but-invalid the
        # bad-path WARN above already explained it; emitting this too is
        # factually wrong ("no resume_cwd" when there was one).
        if [ "$_fm_cwd_found" -eq 0 ]; then
            echo "WARN arm-resume: no --cwd and no 'resume_cwd:' in handover frontmatter — defaulting cwd to '$RESUME_CWD'. For cross-repo handovers (handover in one repo, work in another) set 'resume_cwd: <work-repo>' in the handover frontmatter or pass --cwd." >&2
        fi
    fi
    unset _fm_cwd _fm_cwd_found
fi

# Dedup: list existing HIMMEL-Resume jobs. Fail-CLOSED if the listing
# tool itself errors — silent empty result + arm = duplicate.
#
# Scope ($1, HIMMEL-340):
#   task — only the CURRENT $TASK_NAME (per-handover dedup; the default for
#          an explicit arm, so N distinct handovers each get their own slot).
#   all  — every HIMMEL-Resume-* job (the legacy broad behavior; used by the
#          --dedup-any safety arms and by the soft slot-cap count).
# Defaults to "all" so any unscoped caller keeps the pre-340 semantics.
list_existing() {
    local scope="${1:-all}"
    case "$PLATFORM" in
        windows)
            # schtasks /query: stderr captured separately. CSV output's
            # TaskName column is path-prefixed (`\HIMMEL-Resume-...`);
            # strip the leading `\` and quotes.
            #
            # MSYS_NO_PATHCONV=1 is per-call (HIMMEL-125): without it,
            # gitbash mangles each /flag arg into a Windows-rooted path
            # like "C:/Program Files/Git/query" before schtasks sees
            # it, and schtasks rejects the call. Setting the var only
            # for this single command keeps it isolated from later
            # subshells (the git -C used by RESUME_CWD resolution
            # breaks if MSYS_NO_PATHCONV is set process-wide).
            local err_file out rc
            err_file=$(mktemp -t arm-resume.err.XXXXXX)
            out=$(MSYS_NO_PATHCONV=1 schtasks /query /fo CSV /nh 2>"$err_file")
            rc=$?
            if [ "$rc" -ne 0 ]; then
                # schtasks returns rc=1 when there are NO scheduled
                # tasks at all (empty scheduler) — treat as empty.
                # Any other rc OR any error keyword in stderr = fail.
                if grep -qiE 'access|denied|cannot|fail' "$err_file" 2>/dev/null; then
                    echo "ERR arm-resume: schtasks /query failed (rc=$rc):" >&2
                    cat "$err_file" >&2
                    rm -f "$err_file"
                    exit 2
                fi
            fi
            rm -f "$err_file"
            local names
            # shellcheck disable=SC1003  # `"\\'` strips both quote and literal backslash from schtasks's path-prefixed task names
            names=$(printf '%s\n' "$out" \
                | grep -o '"\\\?HIMMEL-Resume-[^"]*"' 2>/dev/null \
                | tr -d '"\\' \
                | sort -u || true)
            if [ "$scope" = task ]; then
                printf '%s\n' "$names" | grep -Fx "$TASK_NAME" || true
            else
                printf '%s\n' "$names"
            fi
            ;;
        linux|macos)
            if command -v atq >/dev/null 2>&1; then
                local err_file rc atq_out
                err_file=$(mktemp -t arm-resume.err.XXXXXX)
                atq_out=$(atq 2>"$err_file")
                rc=$?
                if [ "$rc" -ne 0 ]; then
                    echo "ERR arm-resume: atq failed (rc=$rc) — atd not running?" >&2
                    cat "$err_file" >&2
                    rm -f "$err_file"
                    exit 2
                fi
                rm -f "$err_file"
                # at jobs don't have names; we grep each job body for
                # our marker. arm-resume injects this marker into the
                # at-job body via a leading comment line (see schedule
                # block below).
                while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    local job_id
                    job_id=$(printf '%s' "$line" | awk '{print $1}')
                    [ -z "$job_id" ] && continue
                    if [ "$scope" = task ]; then
                        # Exact whole-line marker (# $TASK_NAME) so a task
                        # whose name is a prefix of another's can't match it.
                        at -c "$job_id" 2>/dev/null | grep -qxF "# $TASK_NAME" \
                            && printf 'at-job-%s\n' "$job_id"
                    else
                        at -c "$job_id" 2>/dev/null | grep -q 'HIMMEL-Resume-' \
                            && printf 'at-job-%s\n' "$job_id"
                    fi
                done <<< "$atq_out"
            elif command -v crontab >/dev/null 2>&1; then
                # crontab fallback: grep crontab for our marker.
                if [ "$scope" = task ]; then
                    # Anchor the marker comment at end-of-line so a prefix
                    # task name can't match a longer one. TASK_NAME is
                    # sanitized to [:alnum:]_- so it carries no BRE specials.
                    crontab -l 2>/dev/null | grep -E "# ${TASK_NAME}$" || true
                else
                    crontab -l 2>/dev/null | grep -F 'HIMMEL-Resume-' || true
                fi
            fi
            ;;
    esac
}

delete_existing() {
    local marker="$1"
    case "$PLATFORM" in
        windows)
            # MSYS_NO_PATHCONV=1: see HIMMEL-125 note in list_existing.
            if MSYS_NO_PATHCONV=1 schtasks /delete /tn "$marker" /f >/dev/null 2>&1; then
                echo "arm-resume: deleted scheduled task: $marker"
            else
                echo "ERR arm-resume: failed to delete scheduled task: $marker" >&2
                exit 2
            fi
            ;;
        linux|macos)
            if [[ "$marker" == at-job-* ]]; then
                local job_id="${marker#at-job-}"
                if atrm "$job_id" 2>/dev/null; then
                    echo "arm-resume: removed at job: $job_id"
                else
                    echo "ERR arm-resume: failed to atrm $job_id" >&2
                    exit 2
                fi
            else
                # crontab marker is the full matched crontab LINE — rewrite
                # without exactly that line (HIMMEL-340: scoped delete so a
                # --force on one handover can't wipe sibling slots).
                # Snapshot first so a mid-pipeline failure doesn't wipe.
                local snap
                snap=$(mktemp -t crontab.snap.XXXXXX)
                if ! crontab -l > "$snap" 2>/dev/null; then
                    echo "ERR arm-resume: crontab -l failed; aborting before rewrite" >&2
                    rm -f "$snap"
                    exit 2
                fi
                if ! grep -vxF "$marker" "$snap" | crontab - 2>/dev/null; then
                    echo "ERR arm-resume: crontab rewrite failed; original saved at $snap" >&2
                    exit 2
                fi
                rm -f "$snap"
                echo "arm-resume: removed crontab entry: $marker"
            fi
            ;;
    esac
}

# HIMMEL-340: dedup against the CURRENT handover's $TASK_NAME by default
# (so N distinct handovers each arm their own slot), or against ANY
# HIMMEL-Resume job under --dedup-any (the safety-arm semantics the
# auto-arm watchdogs rely on — defer to whatever is already queued).
DEDUP_SCOPE=task
[ "$DEDUP_ANY" -eq 1 ] && DEDUP_SCOPE=all
existing=$(list_existing "$DEDUP_SCOPE")
if [ -n "$existing" ]; then
    if [ "$FORCE" -eq 1 ]; then
        echo "arm-resume: --force set; replacing existing job(s):" >&2
        while IFS= read -r marker; do
            [ -z "$marker" ] && continue
            echo "  $marker" >&2
            if [ "$DRY_RUN" -eq 0 ]; then
                delete_existing "$marker"
            else
                echo "DRY arm-resume: would delete $marker"
            fi
        done <<< "$existing"
    else
        {
            if [ "$DEDUP_SCOPE" = task ]; then
                echo "ERR arm-resume: a resume job for THIS handover is already scheduled:"
            else
                echo "ERR arm-resume: a HIMMEL-Resume-* job is already scheduled:"
            fi
            while IFS= read -r marker; do
                [ -z "$marker" ] && continue
                echo "    $marker"
            done <<< "$existing"
            echo ""
            echo "Dedup safeguard — never want two claude sessions cron-relaunched"
            echo "for the same handover. To replace, re-run with --force. Inspect:"
            case "$PLATFORM" in
                windows) echo "    schtasks /query /tn \"<task-name>\"" ;;
                *)       echo "    atq && at -c <job-id>   (or: crontab -l)" ;;
            esac
        } >&2
        # Telemetry (HIMMEL-236): dedup friction signal. Guarded so a
        # --dry-run that hits the block keeps the touch-nothing contract
        # (this else-branch is reachable under --dry-run without --force).
        if [ "$DRY_RUN" -eq 0 ]; then
            telemetry_emit handover-arm-resume dedup-block "time=$RESUME_TIME"
        fi
        exit 3
    fi
fi

# Soft slot cap (HIMMEL-340): WARN — never block — when arming would push the
# machine past ARM_MAX_SLOTS concurrent resume slots. Each fired slot is
# another concurrent claude process + API spend, so the operator gets a
# heads-up while still being allowed to proceed. Skipped under --dedup-any
# (such arms add at most one slot and only when none exists, so they can't be
# the arm that pushes past the cap) and when ARM_MAX_SLOTS=0 (disabled).
# Reached only on a net-change path: a new arm (no same-handover job) or a
# --force replace (the no-force same-handover case already exited rc 3 above),
# so the predicted total is computed as "every OTHER slot, plus this one" —
# robust whether or not --force already deleted the old job.
if [ "$DEDUP_ANY" -eq 0 ]; then
    _max_slots="${ARM_MAX_SLOTS:-4}"
    case "$_max_slots" in ''|*[!0-9]*) _max_slots=4 ;; esac
    if [ "$_max_slots" -gt 0 ]; then
        # Bare assignments (not <<< "$(list_existing …)" here-strings) so a
        # list_existing fail-closed `exit 2` propagates and aborts rather than
        # being swallowed by the command-substitution subshell — the soft-cap
        # count inherits the same fail-closed contract as the dedup check.
        _all_list=$(list_existing all)
        _same_list=$(list_existing task)
        _all_count=0
        while IFS= read -r _l; do
            [ -n "$_l" ] && _all_count=$((_all_count + 1))
        done <<< "$_all_list"
        _same_count=0
        while IFS= read -r _l; do
            [ -n "$_l" ] && _same_count=$((_same_count + 1))
        done <<< "$_same_list"
        _predicted=$((_all_count - _same_count + 1))
        if [ "$_predicted" -gt "$_max_slots" ]; then
            echo "WARN arm-resume: arming this slot brings the total to $_predicted concurrent resume slots (soft cap ARM_MAX_SLOTS=$_max_slots). Each fired slot is another concurrent claude process + API spend. Proceeding anyway — raise ARM_MAX_SLOTS or prune stale jobs to silence this." >&2
        fi
    fi
fi

# Build and execute the scheduler command directly — no round-trip
# through schedule-resume.sh's mixed-prose stdout (the v1 bug).
schedule_arm() {
    case "$PLATFORM" in
        windows)
            # schtasks ONETIME + a .bat indirection. We write the .bat
            # to a real path (mktemp) rather than relying on %TEMP%
            # expansion via bash, since bash leaves %TEMP% literal —
            # the v1 bug emitted %TEMP%\himmel-resume.bat which bash
            # wrote to a path NAMED %TEMP%\himmel-resume.bat instead
            # of $TEMP-resolved.
            local bat_path
            bat_path=$(mktemp -t himmel-resume.XXXXXX.bat)
            # bash mktemp on gitbash returns POSIX path; schtasks
            # wants a Windows path. cygpath converts; fall back to
            # raw if cygpath absent (Linux running this would fail at
            # the platform check above, so cygpath should exist here).
            local bat_path_win
            if command -v cygpath >/dev/null 2>&1; then
                if ! bat_path_win=$(cygpath -w "$bat_path" 2>&1); then
                    echo "ERR arm-resume: cygpath -w failed: $bat_path_win" >&2
                    rm -f "$bat_path"
                    exit 4
                fi
            else
                echo "ERR arm-resume: cygpath not on PATH; cannot convert .bat path for schtasks" >&2
                echo "    Install Git for Windows (which ships cygpath)." >&2
                rm -f "$bat_path"
                exit 2
            fi
            # Resolve claude.cmd to an absolute path so the .bat doesn't
            # depend on PATH being set in whatever cmd shell schtasks
            # spawns (SYSTEM context lacks npm-installed shims by default).
            local claude_cmd_posix claude_cmd_win
            if claude_cmd_posix=$(command -v claude 2>/dev/null); then
                if ! claude_cmd_win=$(cygpath -w "$claude_cmd_posix" 2>&1); then
                    echo "ERR arm-resume: cygpath -w failed for claude path: $claude_cmd_win" >&2
                    rm -f "$bat_path"
                    exit 4
                fi
            else
                echo "ERR arm-resume: 'claude' not on PATH at arm time" >&2
                rm -f "$bat_path"
                exit 2
            fi
            # Resolve repo root to a Windows path for the cd line.
            local resume_cwd_win
            if ! resume_cwd_win=$(cygpath -w "$RESUME_CWD" 2>&1); then
                echo "ERR arm-resume: cygpath -w failed for resume cwd: $resume_cwd_win" >&2
                rm -f "$bat_path"
                exit 4
            fi
            # .bat content: escape CMD metacharacters in BOTH the prompt
            # AND the cd path. % & ^ < > | can inject commands at fire
            # time if a directory or handover path contains them. (Windows
            # forbids <>"|?* in actual path components, but %, &, ^ are
            # legal in directory names — and the prompt arg can carry
            # arbitrary text.) Same escape both places; bash assoc-array
            # would be cleaner but not worth the dep for two values.
            local p="$RESUME_PROMPT" c="$resume_cwd_win"
            p="${p//\"/\\\"}"   # escape "
            p="${p//%/%%}"      # double % for CMD literal
            p="${p//^/^^}"
            p="${p//&/^&}"
            p="${p//</^<}"
            p="${p//>/^>}"
            p="${p//|/^|}"
            c="${c//\"/\\\"}"
            c="${c//%/%%}"
            c="${c//^/^^}"
            c="${c//&/^&}"
            c="${c//</^<}"
            c="${c//>/^>}"
            c="${c//|/^|}"
            # Optional --channels passthrough. Same CMD-metachar escape as
            # the prompt — the spec is operator-supplied (could carry % & ^).
            local ch=""
            if [ -n "$CHANNELS" ]; then
                local cs="$CHANNELS"
                cs="${cs//\"/\\\"}"
                cs="${cs//%/%%}"
                cs="${cs//^/^^}"
                cs="${cs//&/^&}"
                cs="${cs//</^<}"
                cs="${cs//>/^>}"
                cs="${cs//|/^|}"
                ch=" --channels \"$cs\""
            fi
            # cd /d switches drive + path in one step; quoted to survive
            # spaces. `|| exit /b 1` ensures the .bat aborts instead of
            # silently falling through to claude.exe in the wrong CWD
            # (which is the bug this fix targets — see comment above
            # RESUME_CWD computation).
            # Prompt MUST come before --channels: --channels is variadic
            # (consumes following args), so a trailing positional prompt
            # gets parsed as a bogus channel entry ("must be tagged" → exit 1).
            {
                printf 'cd /d "%s" || exit /b 1\r\n' "$c"
                printf '"%s" "%s"%s\r\n' "$claude_cmd_win" "$p" "$ch"
            } > "$bat_path"

            if [ "$DRY_RUN" -eq 1 ]; then
                echo "DRY arm-resume: would schtasks /create /tn $TASK_NAME /tr $bat_path_win /sc ONCE /st $RESUME_TIME /sd $START_DATE /f"
                echo "DRY arm-resume: .bat content:"
                sed 's/^/    /' "$bat_path"
                rm -f "$bat_path"
                return 0
            fi

            local err_file
            err_file=$(mktemp -t arm-resume.err.XXXXXX)
            # MSYS_NO_PATHCONV=1: see HIMMEL-125 note in list_existing.
            if ! MSYS_NO_PATHCONV=1 schtasks /create /tn "$TASK_NAME" /tr "$bat_path_win" /sc ONCE /st "$RESUME_TIME" /sd "$START_DATE" /f 2>"$err_file"; then
                echo "ERR arm-resume: schtasks /create failed:" >&2
                cat "$err_file" >&2
                rm -f "$err_file" "$bat_path"
                exit 4
            fi
            rm -f "$err_file"
            ;;
        linux|macos)
            if command -v at >/dev/null 2>&1; then
                # at heredoc body INCLUDES the HIMMEL-Resume-<name>
                # marker as a comment line so list_existing's grep
                # actually matches. v1 omitted this; dedup was dead.
                #
                # Heredoc delimiter is UNQUOTED on purpose — we need
                # $q_prompt / $q_cwd to expand at write time so the
                # at-job body contains the actual quoted values, not
                # literal "$q_prompt" strings. Injection protection
                # comes from `printf '%q'` applied to RESUME_PROMPT and
                # RESUME_CWD below: bash %q backslash-escapes $, `,
                # spaces, etc., so a handover path containing $(rm -rf
                # /) survives both the heredoc write AND the /bin/sh
                # re-parse at fire time as a literal string.
                local q_prompt q_cwd q_channels=""
                q_prompt=$(printf '%q' "$RESUME_PROMPT")
                q_cwd=$(printf '%q' "$RESUME_CWD")
                # %q shell-quotes the channels spec so /bin/sh can't
                # re-interpret it at fire time; trailing space separates
                # it from the prompt arg (empty when no --channels).
                [ -n "$CHANNELS" ] && q_channels="--channels $(printf '%q' "$CHANNELS") "
                if [ "$DRY_RUN" -eq 1 ]; then
                    echo "DRY arm-resume: would at -t $AT_STAMP <<'CMD'"
                    echo "    # $TASK_NAME"
                    echo "    cd $q_cwd || exit 1"
                    echo "    claude $q_prompt $q_channels"
                    echo "    CMD"
                    return 0
                fi
                local err_file
                err_file=$(mktemp -t arm-resume.err.XXXXXX)
                # at -t takes an exact [[CC]YY]MMDDhhmm datetime, so we pass the
                # already-resolved START date+time (AT_STAMP). Avoids at's
                # impl-defined past-time handling AND the old today/tomorrow
                # heuristic that broke for resets >24h out. HIMMEL-204.
                if ! at -t "$AT_STAMP" 2>"$err_file" <<CMD
# $TASK_NAME
cd $q_cwd || exit 1
claude $q_prompt $q_channels
CMD
                then
                    echo "ERR arm-resume: at -t $AT_STAMP failed:" >&2
                    cat "$err_file" >&2
                    rm -f "$err_file"
                    exit 4
                fi
                rm -f "$err_file"
            else
                # crontab fallback — recurring entry tagged with the
                # marker so we can find + remove it. Operator manually
                # cleans up after first fire. printf '%q' shell-quotes
                # the prompt so cron's /bin/sh -c can't re-interpret
                # $/backticks/etc in a handover path.
                local hh="${RESUME_TIME%:*}" mm="${RESUME_TIME#*:}"
                local q_prompt q_cwd q_channels=""
                q_prompt=$(printf '%q' "$RESUME_PROMPT")
                q_cwd=$(printf '%q' "$RESUME_CWD")
                [ -n "$CHANNELS" ] && q_channels="--channels $(printf '%q' "$CHANNELS") "
                local entry="$mm $hh * * * cd $q_cwd && claude $q_prompt $q_channels # $TASK_NAME"
                if [ "$DRY_RUN" -eq 1 ]; then
                    echo "DRY arm-resume: would add crontab entry:"
                    echo "    $entry"
                    echo "DRY arm-resume: NOTE: crontab is RECURRING; remove after first fire."
                    return 0
                fi
                local snap
                snap=$(mktemp -t crontab.snap.XXXXXX)
                if ! crontab -l > "$snap" 2>/dev/null; then
                    : > "$snap"
                fi
                {
                    cat "$snap"
                    echo "$entry"
                } | crontab - || {
                    echo "ERR arm-resume: crontab rewrite failed; snapshot at $snap" >&2
                    exit 4
                }
                rm -f "$snap"
                echo "arm-resume: NOTE: crontab is RECURRING; remove after first fire with:"
                echo "    crontab -l | grep -v 'HIMMEL-Resume' | crontab -"
            fi
            ;;
    esac
}

schedule_arm

if [ "$DRY_RUN" -eq 1 ]; then
    echo "RESUME_CWD=$RESUME_CWD"
    echo "arm-resume: dry-run complete (no changes made)"
    exit 0
fi

# Telemetry (HIMMEL-236): a successful arm IS the re-launch signal the
# measure-during protocol wants — one append, after the dry-run gate so
# --dry-run keeps its "touch nothing" contract.
telemetry_emit handover-arm-resume armed "time=$RESUME_TIME" "force=$FORCE"

cat <<EOF

================================================================
  RESUME ARMED for $RESUME_TIME on $START_DATE (handover: $HANDOVER_PATH)
  Task name: $TASK_NAME

  PLEASE /exit YOUR CURRENT CLAUDE SESSION NOW.

  The cron/schtasks relaunch will spawn a NEW claude process at the
  scheduled time. If this session is still running then, you'll
  have two concurrent claude processes operating on the same
  handover state (file races, doubled API spend, possible
  double-pushes from auto-commit).

  Closing also gives the next session a clean prompt cache and a
  fresh handover-context read.
================================================================

EOF
exit 0
