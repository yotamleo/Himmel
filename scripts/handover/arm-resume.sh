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
#   5. makes the relaunch self-cleaning: the spawned launcher deletes
#      its OWN scheduler entry as its first action (schtasks .bat
#      self-/delete; crontab entry self-removes; at auto-removes), so a
#      fired slot never lingers to block a same-handover re-arm or fire
#      twice.
#   6. checks for time collisions with other HIMMEL-* claude-launching
#      scheduled tasks (HIMMEL-407): HARD-REFUSES (rc=6) on an exact-
#      minute match; WARNs (continues) within ±COLLISION_WINDOW_MINUTES
#      (default 5 min). --force bypasses both. --dedup-any arms run
#      WARN-ONLY so unattended watchdog arms never refuse.
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
#                      Also bypasses the time-collision check (HIMMEL-407).
#   --dedup-any        Dedup against ANY HIMMEL-Resume job, not just this
#                      handover's (HIMMEL-340 safety-arm semantics).
#   --dry-run          Print what would be scheduled, touch nothing.
#
# Env:
#   ARM_MAX_SLOTS           Soft cap on concurrent resume slots (default 4, 0
#                           disables). Arming past it WARNs but never blocks.
#   COLLISION_WINDOW_MINUTES Minutes around another HIMMEL-* task's fire time
#                           that trigger a WARN (default 5). An exact-minute
#                           match always refuses (rc=6) unless --force.
#   ARM_COLLISION_WINDOW    Test seam: overrides COLLISION_WINDOW_MINUTES.
#   ARM_NAME_TEMPLATE       Naming template for the derived session identity
#                           (HIMMEL-716): placeholders {ticket} {slug}
#                           {session}. Unset = the built-in ticket-first
#                           composition. See _compose_arm_name.
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
#   6  time collision — the requested time exactly matches another HIMMEL-*
#      scheduled task (HIMMEL-407). Pass --force to override, or choose a
#      different time (suggest_free_slot prints nearby free options).
#   7  refused — the handover's queue lock (scripts/handover/queue-lock.sh)
#      is currently FRESH: a session is LIVE on this queue right now
#      (HIMMEL-856). Override with QUEUE_LOCK_TAKEOVER=1.
#   8  refused — this handover already has a PENDING arm recorded on
#      ANOTHER host in the cross-machine arms registry (HIMMEL-856; the
#      win2+main double-arm shape). Override with ARM_DUP_OK=1. A record
#      stops being PENDING (and stops causing this refusal) once the arm it
#      names actually fires and the relaunched session acquires its queue
#      lock — queue-lock.sh CONSUMES (drops) it at that point (HIMMEL-882);
#      this script also prunes ITS OWN host's prior records for the same
#      handover on every re-arm, so neither a fired arm nor a superseded
#      re-arm blocks a later cross-host arm forever.
set -euo pipefail

RESUME_TIME=""
HANDOVER_PATH=""
FORCE=0
DRY_RUN=0
RESUME_CWD_OVERRIDE=""
CHANNELS=""
DEDUP_ANY=0
WORKTREE_BRANCH=""

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
                     the state repo but the origin session was in himmel).
                     If the handover file's YAML frontmatter contains
                     'resume_cwd: <path>', that value is used when
                     --cwd is omitted (set this for cross-repo
                     handovers so the correct repo is used without
                     requiring an explicit --cwd every time).
  --worktree <branch>  Run the relaunch in a FRESH himmel worktree for
                     <branch> (type/slug) instead of a shared checkout —
                     for code arms that must not collide with concurrent
                     github-sync / Telegram-bridge sessions. Creates the
                     worktree at arm time and resumes there. Mutually
                     exclusive with --cwd (the worktree IS the cwd). A
                     handover 'resume_worktree: <branch>' frontmatter key
                     does the same when the flag is omitted. (HIMMEL-387)
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
  --force            Replace the existing same-handover HIMMEL-Resume job;
                     also bypasses the time-collision check (HIMMEL-407).
  --dedup-any        Dedup against ANY HIMMEL-Resume job, not just this
                     handover's: arm only if NO resume slot exists at all.
                     The safety-arm semantics the auto-arm watchdogs use so
                     a machine-wide cap can never queue duplicate relaunches.
                     Default (omitted) is per-handover dedup — N distinct
                     handovers each get their own slot (HIMMEL-340).
  --dry-run          Print what would be scheduled, touch nothing

Env:
  ARM_MAX_SLOTS           Soft cap on concurrent resume slots (default 4, 0
                          disables). Arming past it WARNs but never blocks.
  COLLISION_WINDOW_MINUTES Minutes on either side of another HIMMEL-* task's
                          fire time that trigger a near-collision WARN (default
                          5). An exact-minute overlap always refuses (rc=6)
                          unless --force. Set ARM_COLLISION_WINDOW in tests.
  ARM_NAME_TEMPLATE       Template for the derived session identity
                          (HIMMEL-716). Placeholders: {ticket} (inferred key),
                          {slug} (worktree/handover name-half), {session}
                          (chain position, renders sN or empty). One template
                          drives BOTH the `claude -n` title and the scheduler
                          row's identity segment (each still sanitized for its
                          surface). Unset = the built-in ticket-first
                          composition; e.g. '{slug}' for slug-only names. A
                          template that renders empty falls back to the plain
                          HIMMEL-Resume-<path> name with no -n.
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
        --worktree)    WORKTREE_BRANCH="${2:-}"; shift 2 ;;
        --worktree=*)  WORKTREE_BRANCH="${1#--worktree=}"; shift ;;
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

# handover_root (HIMMEL-856): resolves the single handover root (Mode A
# inline vs Mode B external HANDOVER_DIR) so the queue-lock + arms-registry
# checks below read/write the SAME root every other scripts/handover/*.sh
# script uses -- never a hardcoded ./handovers/ (scripts/handover/CLAUDE.md
# hard rule). Same caller-side fail-open contract as telemetry.sh above
# (HIMMEL-236 T24): an absent/broken lib must never break arming -- a
# missing handover_root just means the queue-lock/arms-registry checks
# below WARN and skip (see their own guard), same as the existing dedup/
# collision checks proceed unaffected.
# shellcheck source=../lib/handover-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/handover-path.sh" 2>/dev/null || true
command -v handover_root >/dev/null 2>&1 || handover_root() { return 2; }

# HIMMEL_HEADROOM_PROXY flag parser (HIMMEL-901): same fail-open contract as
# the two libs above — an absent/broken lib just means the .env fallback
# never activates (the process-env check right below still works either
# way), never a broken arm. CR round: the failure WARNs once here at source
# time (not inside the stub, which would repeat) — an operator relying on
# the .env flag deserves to know the fallback is disabled.
# shellcheck source=../lib/headroom-proxy.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/headroom-proxy.sh" 2>/dev/null \
    || echo "WARN arm-resume: headroom-proxy lib failed to load -- .env HIMMEL_HEADROOM_PROXY fallback disabled (process env still honored)" >&2
command -v _headroom_proxy_env_file_active >/dev/null 2>&1 || _headroom_proxy_env_file_active() { return 1; }

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

# _cmd_metachar_escape <value> — echo <value> with the same CMD-metachar
# escaping schedule_arm's Windows .bat generator applies inline to the cd
# path / prompt / --channels spec below (HIMMEL-901: reused for the headroom
# proxy binary path so a fourth copy of the same six-substitution block
# isn't pasted in). % & ^ < > | can inject commands at .bat fire time.
_cmd_metachar_escape() {
    local v="$1"
    v="${v//\"/\\\"}"
    v="${v//%/%%}"
    v="${v//^/^^}"
    v="${v//&/^&}"
    v="${v//</^<}"
    v="${v//>/^>}"
    v="${v//|/^|}"
    printf '%s' "$v"
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
        # HIMMEL-708: emit the epoch AND the three schedule fields the derive
        # block below would otherwise compute in a SECOND python round-trip.
        # For the common explicit-HH:MM path this collapses two py_armor calls
        # (each ~4 helper spawns: 2 mktemp + interpreter + 2 rm) into one.
        # `cand` is already local (astimezone), so its strftime fields equal
        # what fromtimestamp(epoch).astimezone() yields in the derive block.
        py_armor_capture -c '
import sys
from datetime import datetime, timedelta
hh, mm = (int(x) for x in sys.argv[1].split(":"))
now = datetime.now().astimezone()
cand = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
if cand <= now:          # time already passed today -> tomorrow
    cand += timedelta(days=1)
print(int(cand.timestamp()), cand.strftime("%H:%M"), cand.strftime("%m/%d/%Y"), cand.strftime("%Y%m%d%H%M"))
' "$RESUME_TIME" || {
            echo "ERR arm-resume: could not resolve --time $RESUME_TIME to an epoch (python3 failed/timed out)" >&2
            exit 2
        }
        read -r TARGET_EPOCH RESUME_TIME START_DATE AT_STAMP <<<"$PY_ARMOR_OUT"
        _SCHED_FIELDS_DERIVED=1
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
# HIMMEL-708: the explicit-HH:MM branch already derived these fields in its
# single python pass (_SCHED_FIELDS_DERIVED); only the smart/auto paths (which
# get TARGET_EPOCH from a subprocess) still need this second derivation.
if [ -z "${_SCHED_FIELDS_DERIVED:-}" ]; then
    py_armor_capture -c '
import sys, datetime
dt = datetime.datetime.fromtimestamp(int(sys.argv[1])).astimezone()
print(dt.strftime("%H:%M"), dt.strftime("%m/%d/%Y"), dt.strftime("%Y%m%d%H%M"))
' "$TARGET_EPOCH" || {
        echo "ERR arm-resume: could not derive schedule fields from epoch $TARGET_EPOCH" >&2
        exit 2
    }
    read -r RESUME_TIME START_DATE AT_STAMP <<<"$PY_ARMOR_OUT"
fi
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

# HIMMEL_HEADROOM_PROXY (HIMMEL-901): route the armed relaunch through the
# local headroom Anthropic-API proxy (127.0.0.1:8787) when the operator has
# opted in. Resolved ONCE here, at arm time, and baked into whichever
# launcher schedule_arm emits below — the fired relaunch never re-reads this
# flag. Only the exact value "1" activates: the process env at arm time wins
# outright (HIMMEL_HEADROOM_PROXY set-but-not-"1" is INACTIVE, same as
# unset); only when the process env carries no signal at all does the
# himmel repo-root .env get consulted as a fallback. When inactive
# (the default), every launcher below stays BYTE-IDENTICAL to pre-901
# output — this block is the only thing that can turn it on.
# Known minimal-slice limitation (CR round): the .env fallback resolves
# against the checkout THIS script physically lives in (SCRIPT_DIR/../..),
# so arming from a worktree does not see the primary checkout's untracked
# .env — the process env is the worktree-safe path.
HEADROOM_PROXY_ACTIVE=0
if [ -n "${HIMMEL_HEADROOM_PROXY+x}" ]; then
    [ "$HIMMEL_HEADROOM_PROXY" = "1" ] && HEADROOM_PROXY_ACTIVE=1
elif _headroom_proxy_env_file_active "$(cd "$SCRIPT_DIR/../.." && pwd)"; then
    HEADROOM_PROXY_ACTIVE=1
fi
# Port fixed at 8787 for this slice — no port config (HIMMEL-901 minimal
# slice; a variable only to avoid repeating the literal across 3 platform
# launchers). HEADROOM_BIN: operator override wins; else the platform
# default venv layout. Only resolved when the flag is active, so an
# inactive arm never even looks at $HOME/.headroom-venv.
HEADROOM_PROXY_PORT=8787
# CR round (HIMMEL-901): resolve curl ONCE at arm time and bake the ABSOLUTE
# path into the launcher — scheduler contexts fire with a minimal PATH (the
# same reason claude/cygpath are resolved at arm time above), so a bare
# `curl` in the launcher could miss at fire time, fail both livez checks,
# and silently send the launch bare even with a healthy proxy. No curl at
# arm time -> one honest WARN and a plain pre-901 launcher (deactivate)
# rather than baking a known-broken check.
HEADROOM_CURL=""
if [ "$HEADROOM_PROXY_ACTIVE" -eq 1 ]; then
    if ! HEADROOM_CURL=$(command -v curl 2>/dev/null) || [ -z "$HEADROOM_CURL" ]; then
        echo "WARN arm-resume: curl not on PATH -- the armed launch will fail-open to bare (proxy livez unverifiable)" >&2
        HEADROOM_PROXY_ACTIVE=0
    fi
fi
if [ "$HEADROOM_PROXY_ACTIVE" -eq 1 ] && [ -z "${HEADROOM_BIN:-}" ]; then
    if [ "$PLATFORM" = windows ]; then
        HEADROOM_BIN="$HOME/.headroom-venv/Scripts/headroom.exe"
    else
        HEADROOM_BIN="$HOME/.headroom-venv/bin/headroom"
    fi
fi
# Non-blocking existence probe (CR round): a missing/non-executable headroom
# binary still arms — fail-open is the design — but the operator hears about
# it NOW instead of discovering a silently-bare session after the fire.
if [ "$HEADROOM_PROXY_ACTIVE" -eq 1 ]; then
    [ -x "$HEADROOM_BIN" ] || echo "WARN arm-resume: HEADROOM_BIN '$HEADROOM_BIN' not found/executable -- fire-time start will fail-open to bare" >&2
fi

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
            echo "    macOS:        uses crontab — ensure crontab is available" >&2
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

# Ticket inference for the scheduler task name (HIMMEL-540). The task name is
# built AFTER the cwd/worktree resolution block below (so $WORKTREE_BRANCH is
# fully resolved); these helpers are defined here and used there.
#
# _validate_key <raw> — echo the canonical ticket key (uppercased) or empty.
# errexit-safe: a `case` glob (never a bare `grep -q`); the last command is the
# `case` (rc 0 on every branch), so it never aborts under `set -euo pipefail`.
_validate_key() {
    local k
    k=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')   # himmel-540 -> HIMMEL-540
    # Fully-anchored canonical shape <KEY>-<NUM> with nothing trailing, so a
    # malformed value (e.g. ABC-123-456 or trailing junk) is rejected rather than
    # truncated-and-accepted. `grep -qE` inside `if` is errexit-safe; the `if` is
    # the function's last command and returns rc 0 whether or not it matched.
    if printf '%s' "$k" | grep -qE '^[A-Z][A-Z0-9]*-[0-9]+$'; then
        printf '%s' "$k"
    fi
}

# _infer_ticket <handover_path> — echo the inferred ticket key or empty. Sources,
# most-robust-first, falling through on miss:
#   1. ticket: front-matter key (consume-if-present; forward-compat).
#   2. worktree branch type/<ticket>-slug ($WORKTREE_BRANCH; lowercase->uppercase).
#   3. first H1 (`# `) line's first canonical [A-Z][A-Z0-9]+-[0-9]+ key.
#   4. (HIMMEL-716) CHAIN FILES ONLY (basename next-session-N.md): the leading
#      canonical key of the parent dir. The handover skill's chain layout names
#      the epic dir <TICKET>-<slug>, so a chained handover whose file carries
#      no key still resolves its chain identity. Scoped to chain files so an
#      ordinary handover sitting in an odd-named dir (e.g. session-2/) cannot
#      have a junk key welded in.
# Each `grep` is `|| true`-guarded — grep exits 1 on no-match and `set -o
# pipefail` would otherwise abort the assignment. The last command (src-4's
# `if`, rc 0 whether or not it fires) keeps the function errexit-safe.
_infer_ticket() {
    local _ho="$1" _raw _key _stem
    # src-1: ticket: frontmatter (same awk/sed/rtrim/unquote idiom as resume_cwd:).
    # `|| true` keeps the assignment errexit-safe even if head closes the pipe
    # early (SIGPIPE), matching the explicit guards on src-2/src-3 below.
    _raw=$(awk '/^---[[:space:]]*$/{c++; next} c==1' "$_ho" \
        | sed -n 's/^ticket:[[:space:]]*//p' | head -1) || true
    _raw="${_raw%"${_raw##*[![:space:]]}"}"   # rtrim (incl trailing \r)
    _raw="${_raw#\'}" ; _raw="${_raw%\'}"
    _raw="${_raw#\"}" ; _raw="${_raw%\"}"
    _key=$(_validate_key "$_raw")
    if [ -n "$_key" ]; then printf '%s' "$_key"; return 0; fi
    # src-2: worktree branch type/<ticket>-slug — real branches are lowercase,
    # so _validate_key uppercases. Takes the FIRST word-digits token from the
    # slug; for the himmel convention (type/<key>-N-rest) that IS the ticket.
    # Best-effort: a non-conventional slug that merely looks keyed (e.g.
    # feat/release-2024-x) yields a cosmetically-wrong row name only — the
    # per-handover-unique path-suffix still keys dedup/collision correctly.
    if [ -n "$WORKTREE_BRANCH" ]; then
        _raw=$(printf '%s\n' "${WORKTREE_BRANCH#*/}" \
            | grep -oiE '[A-Za-z][A-Za-z0-9]*-[0-9]+' | head -1) || true
        _key=$(_validate_key "$_raw")
        if [ -n "$_key" ]; then printf '%s' "$_key"; return 0; fi
    fi
    # src-3: first H1 line only, first canonical (uppercase) key. H1-only so a
    # stray ticket *mention* in the body can't be welded into the scheduler name.
    _raw=$(sed -n '/^# /{p;q}' "$_ho")
    _raw=$(printf '%s\n' "$_raw" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1) || true
    _key=$(_validate_key "$_raw")
    if [ -n "$_key" ]; then printf '%s' "$_key"; return 0; fi
    # src-4: chain files only (see header). Backslashes normalized first so a
    # Windows-style path still splits on its components.
    _stem=$(basename "${_ho//\\//}"); _stem="${_stem%.md}"
    if printf '%s' "$_stem" | grep -qE '^next-session-[0-9]+$'; then
        _raw=$(basename "$(dirname "${_ho//\\//}")" \
            | grep -oiE '^[A-Za-z][A-Za-z0-9]*-[0-9]+') || true
        _validate_key "$_raw"
    fi
}

# _infer_session_number <handover_path> - chain position N for a CHAINED
# handover (HIMMEL-716): the handover skill's auto-continuing chains write
# next-session-<N>.md files, so a stem that is (or ends in) next-session-<N>
# IS the chain sequence number. Echoes N or empty. Filename-only by design -
# a body mention of "next-session-9" can never leak into the name (the same
# scan discipline as _infer_ticket's H1-only rule). errexit-safe: the grep
# pipeline is || true-guarded and is the function's last command.
_infer_session_number() {
    local _stem
    _stem=$(basename "${1//\\//}"); _stem="${_stem%.md}"
    printf '%s\n' "$_stem" | grep -oE '(^|-)next-session-[0-9]+$' | grep -oE '[0-9]+$' || true
}

# _infer_slug <handover_path> - human slug from the handover NAME (HIMMEL-716),
# the no-ticket-system identity source (OSS adopters without Jira). The file
# stem, minus .md and minus a trailing next-session-<N> chain tail (carried
# separately as the session number); when nothing is left (a bare
# next-session-N.md chain file) fall back to the parent dir's basename (the
# <TICKET>-<slug> epic dir) unless that is a generic bucket (handovers / .),
# which would name every slot alike. Sanitized to [A-Za-z0-9._-]: a strict
# subset of the session-title class, and the task-name weld re-sanitizes for
# its own surface. errexit-safe: sed and tr always rc 0; the case has a no-op
# default arm.
_infer_slug() {
    local _p="${1//\\//}" _stem _parent
    _stem=$(basename "$_p"); _stem="${_stem%.md}"
    _stem=$(printf '%s\n' "$_stem" | sed -E 's/(^|-)next-session-[0-9]+$//')
    if [ -z "$_stem" ]; then
        _parent=$(basename "$(dirname "$_p")")
        case "$_parent" in
            handovers|.|/) : ;;
            *) _stem="$_parent" ;;
        esac
    fi
    printf '%s' "$_stem" | tr -cd 'A-Za-z0-9._-'
}

# _compose_arm_name <ticket> <handover_path> <title|task> - ONE composer for
# BOTH derived names (HIMMEL-716; subsumes HIMMEL-702's _infer_session_name so
# the `claude -n` title and the scheduler-row segment can never drift apart):
#   title -> the `claude -n` value, canonical retitle form "<TICKET> <name>"
#            (HIMMEL-432, space-joined), sanitized to [A-Za-z0-9._ -] so the
#            Windows .bat launch line can inject it quoted WITHOUT ^-escaping
#            (HIMMEL-702) and printf %q keeps it one arg for cron/at. Empty
#            tells the caller to omit -n (fail-open - let claude auto-title
#            rather than force a meaningless name).
#   task  -> the identity segment welded into TASK_NAME (dash-joined; space
#            and dot become dashes), sanitized to [:alnum:]_- so the crontab
#            self-clean ERE and the CMD launch lines stay injection-proof.
# Identity grammar (default): <ticket> + <name-half> + <s<N> chain position>.
# The name-half, by priority:
#   1. the worktree slug minus its leading ticket token (the HIMMEL-702
#      source, unchanged);
#   2. a ticket-KEYED handover slug - the file/dir is named <ticket>-<slug>,
#      so the slug is that ticket's own name-half;
#   3. ticketless only: the raw handover slug (the no-Jira adopter fallback).
# An UNKEYED slug never rides along with a ticket: the ticket alone is
# already meaningful, welding an unrelated filename in adds noise, and this
# keeps plain ticketed arms byte-identical to the pre-716 names (existing
# armed slots still dedup across the upgrade).
# ARM_NAME_TEMPLATE (HIMMEL-716; arming config, same surface as
# ARM_MAX_SLOTS): operator override with placeholders {ticket} {slug}
# {session} ({session} renders s<N> or empty; {slug} prefers the worktree
# half, else the keyed-stripped or raw handover slug). One template drives
# BOTH surfaces; the per-surface sanitize still applies afterwards, so even a
# hostile template value cannot inject into the .bat/cron launch lines.
# errexit-safe: greps || true-guarded, case arms rc 0, and each branch of the
# final if ends in a sed that returns rc 0.
_compose_arm_name() {
    local _tkt="$1" _ho="$2" _surface="$3"
    local _name="" _slug _tok _sess _hslug _up _out
    if [ -n "$WORKTREE_BRANCH" ]; then
        _slug="${WORKTREE_BRANCH#*/}"                     # feat/himmel-702-x -> himmel-702-x
        _tok=$(printf '%s\n' "$_slug" | grep -oiE '^[A-Za-z][A-Za-z0-9]*-[0-9]+' | head -1) || true
        if [ -n "$_tok" ]; then
            _name="${_slug#"$_tok"}"; _name="${_name#-}"  # strip leading <ticket>- token
        else
            _name="$_slug"
        fi
    fi
    _sess=$(_infer_session_number "$_ho")
    [ -n "$_sess" ] && _sess="s$_sess"
    _hslug=$(_infer_slug "$_ho")
    if [ -z "$_name" ]; then
        if [ -n "$_tkt" ]; then
            # keyed check is case-insensitive (real stems are usually lowercase).
            _up=$(printf '%s' "$_hslug" | tr '[:lower:]' '[:upper:]')
            case "$_up" in
                "$_tkt"-?*) _name="${_hslug:$(( ${#_tkt} + 1 ))}" ;;
            esac
        else
            _name="$_hslug"
        fi
    fi
    if [ -n "${ARM_NAME_TEMPLATE:-}" ]; then
        _out="$ARM_NAME_TEMPLATE"
        _out="${_out//\{ticket\}/$_tkt}"
        _out="${_out//\{slug\}/${_name:-$_hslug}}"
        _out="${_out//\{session\}/$_sess}"
    elif [ "$_surface" = "title" ]; then
        _out="$_tkt $_name $_sess"
    else
        _out="$_tkt-$_name-$_sess"
    fi
    # Per-surface finish: sanitize to the surface's class, squeeze separator
    # runs left by empty components, trim stray leading/trailing separators.
    # tr set args keep '-' LAST: a leading '-' in the set reads as an option
    # to GNU tr ("unknown option") and the failed pipeline would abort the
    # errexit caller.
    if [ "$_surface" = "title" ]; then
        printf '%s' "$_out" | tr -cd 'A-Za-z0-9._ -' | tr -s '. _-' \
            | sed -E 's/^[-. _]+//; s/[-. _]+$//'
    else
        printf '%s' "$_out" | tr ' .' '-' | tr -cd '[:alnum:]_-' | tr -s '_-' \
            | sed -E 's/^[-_]+//; s/[-_]+$//'
    fi
}

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
#      because the handover lives in the state repo but claude must run
#      from the origin repo, not the state repo.
#   2. resume_cwd: in the handover file's YAML frontmatter. Lets a
#      handover in the state repo declare its own work-repo without
#      requiring an explicit --cwd at every arm-resume call.
#   3. Auto-detect: git toplevel containing the handover file.
#   4. Fallback: handover's parent dir if it isn't tracked by git.
#
# Priority 0 (HIMMEL-387): --worktree <branch> / 'resume_worktree:' frontmatter
# short-circuits all of the above — the relaunch runs in a FRESH himmel
# worktree instead of a shared checkout. Required when github-sync / the
# Telegram bridge run concurrently, so an autonomous code arm never mutates a
# checkout another session has open. Explicit opt-in only: vault arms
# (luna/salus) must stay single-tree, so this is never inferred.

# Resolve the worktree branch from frontmatter when not given on the CLI
# (flag wins, same precedence as --cwd over resume_cwd).
if [ -z "$WORKTREE_BRANCH" ]; then
    _fm_wt=$(awk '/^---[[:space:]]*$/{c++; next} c==1' "$HANDOVER_PATH" \
        | sed -n 's/^resume_worktree:[[:space:]]*//p' | head -1)
    _fm_wt="${_fm_wt%"${_fm_wt##*[![:space:]]}"}"   # rtrim (incl trailing \r)
    _fm_wt="${_fm_wt#\'}" ; _fm_wt="${_fm_wt%\'}"
    _fm_wt="${_fm_wt#\"}" ; _fm_wt="${_fm_wt%\"}"
    WORKTREE_BRANCH="$_fm_wt"
    unset _fm_wt
fi

if [ -n "$WORKTREE_BRANCH" ]; then
    if [ -n "$RESUME_CWD_OVERRIDE" ]; then
        echo "ERR arm-resume: --cwd and --worktree are mutually exclusive (the worktree IS the cwd)" >&2
        exit 1
    fi
    if ! printf '%s' "$WORKTREE_BRANCH" | grep -qE '^(feat|fix|chore|docs|refactor|test)/[A-Za-z0-9._-]+$'; then
        echo "ERR arm-resume: --worktree branch must be type/slug (type in feat|fix|chore|docs|refactor|test): '$WORKTREE_BRANCH'" >&2
        exit 1
    fi
    # clean-garden.sh (which worktree.sh wraps) creates the worktree under the
    # checkout's own .claude/worktrees/<type>+<slug>/. Compute that path so the
    # dry-run can report it and the pre-trust below can target it. SCRIPT_DIR is
    # scripts/handover, so ../.. is the repo root of THIS checkout (run from the
    # primary checkout per the operator rule).
    _wt_root=$(cd "$SCRIPT_DIR/../.." && pwd)
    _wt_path="$_wt_root/.claude/worktrees/${WORKTREE_BRANCH/\//+}"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY arm-resume: would create worktree '$WORKTREE_BRANCH' at '$_wt_path' and resume there"
        RESUME_CWD="$_wt_path"
    else
        if [ -d "$_wt_path" ]; then
            echo "arm-resume: reusing existing worktree at '$_wt_path'"
        else
            # ARM_WORKTREE_CMD is a test seam (default: the real worktree.sh).
            # ARM_WORKTREE_PATH lets a stub create the exact computed dir; the
            # real worktree.sh ignores it (it computes the same path itself).
            _wt_cmd="${ARM_WORKTREE_CMD:-bash $SCRIPT_DIR/../worktree.sh}"
            # _wt_cmd is an intentional cmd+args split — word-splitting wanted.
            # shellcheck disable=SC2086
            if ! ARM_WORKTREE_PATH="$_wt_path" $_wt_cmd "$WORKTREE_BRANCH"; then
                echo "ERR arm-resume: worktree create failed for branch '$WORKTREE_BRANCH'" >&2
                exit 4
            fi
        fi
        if [ ! -d "$_wt_path" ]; then
            echo "ERR arm-resume: expected worktree dir not found after create: '$_wt_path'" >&2
            exit 4
        fi
        RESUME_CWD=$(_arm_realpath "$_wt_path")
    fi
    unset _wt_root _wt_path
elif [ -n "$RESUME_CWD_OVERRIDE" ]; then
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

# Task name — ticket-aware (HIMMEL-540), extended with the full derived
# identity (HIMMEL-716): <TICKET>-<name-half>-<sN> so scheduler rows
# (schtasks /query, atq) are scannable AND chain-attributable, e.g.
# HIMMEL-Resume-HIMMEL-654-ws7-gates-s32-<path-suffix>. The HIMMEL-Resume-
# prefix AND the per-handover-unique <path-suffix> are preserved, so every
# dedup/collision/marker site that reads $TASK_NAME is unaffected - the value
# only gains a middle identity segment, recomputed deterministically from the
# same handover so a re-arm still exact-matches its own slot. Built HERE (not
# at parse time) so $WORKTREE_BRANCH (resolved above) is available to the
# inference helpers. The path-suffix matches the schedule-resume.sh:88
# convention so broad cross-route dedup (the HIMMEL-Resume- prefix grep)
# still matches between routes.
_ho_ticket=$(_infer_ticket "$HANDOVER_PATH")
# shellcheck disable=SC1003  # `\\` in single quotes is two backslashes which tr collapses to one literal `\` — intentional
_path_suffix=$(printf '%s' "$HANDOVER_PATH" | tr '/\\' '__' | tr -cd '[:alnum:]_-')
_name_seg=$(_compose_arm_name "$_ho_ticket" "$HANDOVER_PATH" task)
if [ -n "$_name_seg" ]; then
    TASK_NAME="HIMMEL-Resume-${_name_seg}-${_path_suffix}"
else
    TASK_NAME="HIMMEL-Resume-${_path_suffix}"
fi
# The armed relaunch's `claude -n` session title (HIMMEL-702/716) - the same
# composer renders both surfaces from one identity, so the scheduler row name
# and the session/tab title can never disagree.
SESSION_NAME=$(_compose_arm_name "$_ho_ticket" "$HANDOVER_PATH" title)
unset _ho_ticket _path_suffix _name_seg

# Pre-trust the resolved cwd (HIMMEL-386) so the fired relaunch doesn't stall
# on Claude Code's interactive workspace-trust prompt ("Is this a project you
# trust?"). An autonomous relaunch has no human to answer it and its stdin is
# closed, so an untrusted cwd silently wastes the whole run. Non-fatal: a
# pre-seed failure must never block the arm itself.
if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY arm-resume: would pre-trust workspace '$RESUME_CWD' in ~/.claude.json"
else
    "$SCRIPT_DIR/../lib/ensure-workspace-trust.sh" "$RESUME_CWD" \
        || echo "WARN arm-resume: workspace-trust pre-seed failed for '$RESUME_CWD' (arm continues; first relaunch may prompt to trust the folder)" >&2
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

# _crontab_list <scope> — grep the crontab for our HIMMEL-Resume markers
# (HIMMEL-594: shared by the linux crontab fallback + the macOS crontab-only
# branch so dedup reads the same store the schedule wrote).
_crontab_list() {
    local scope="${1:-all}"
    if [ "$scope" = task ]; then
        # Anchor the marker comment at end-of-line so a prefix task name can't
        # match a longer one. TASK_NAME is sanitized to [:alnum:]_- so it
        # carries no BRE specials.
        crontab -l 2>/dev/null | grep -E "# ${TASK_NAME}$" || true
    else
        crontab -l 2>/dev/null | grep -F 'HIMMEL-Resume-' || true
    fi
}

# HIMMEL-708 spawn-tax reduction: memoize the Windows scheduler listing.
# `schtasks /query` is ~1.2s per spawn and was re-run up to 4× per arm — once
# for the dedup read, twice for the soft-slot-cap count (list_existing all +
# task), and once for the collision check — each also re-running its own CSV
# parse on top of the spawn. Populate it ONCE here so the
# $()-wrapped list_existing / list_collision_candidates readers inherit the
# result from the parent shell (a subshell that populated it could not persist
# it up). Sets, for the caller to read directly:
#   _SCHTASKS_CSV    raw `/query /fo CSV /nh` stdout — the collision check needs
#                    the Next-Run-Time column, so it reads this.
#   _SCHTASKS_RC     the query's exit code (collision skips on rc!=0, matching
#                    its prior behavior).
#   _SCHTASKS_NAMES  sorted-unique HIMMEL-Resume-* task names — dedup/soft-cap.
# Fail-CLOSED on a genuine schtasks error (same policy list_existing had: an
# error keyword in stderr → ERR + exit 2), so a silent empty result can never
# be mistaken for "no jobs" and produce a duplicate arm.
# MSYS_NO_PATHCONV=1 is per-call (HIMMEL-125): without it gitbash mangles each
# /flag into a Windows-rooted path and schtasks rejects the call; scoping it to
# this one command keeps it off the later git -C in RESUME_CWD resolution.
_SCHTASKS_CACHE_DONE=""
_SCHTASKS_CSV=""
_SCHTASKS_RC=0
_SCHTASKS_NAMES=""
_ensure_schtasks_cache() {
    [ -n "$_SCHTASKS_CACHE_DONE" ] && return 0
    local err_file
    err_file=$(mktemp -t arm-resume.err.XXXXXX)
    _SCHTASKS_CSV=$(MSYS_NO_PATHCONV=1 schtasks /query /fo CSV /nh 2>"$err_file")
    _SCHTASKS_RC=$?
    if [ "$_SCHTASKS_RC" -ne 0 ]; then
        # schtasks returns rc=1 when there are NO scheduled tasks at all
        # (empty scheduler) — treat as empty. Any error keyword in stderr = fail.
        if grep -qiE 'access|denied|cannot|fail' "$err_file" 2>/dev/null; then
            echo "ERR arm-resume: schtasks /query failed (rc=$_SCHTASKS_RC):" >&2
            cat "$err_file" >&2
            rm -f "$err_file"
            exit 2
        fi
    fi
    rm -f "$err_file"
    # CSV TaskName column is path-prefixed (`\HIMMEL-Resume-...`); strip the
    # leading `\` and quotes.
    # shellcheck disable=SC1003  # `"\\'` strips both quote and literal backslash from schtasks's path-prefixed task names
    _SCHTASKS_NAMES=$(printf '%s\n' "$_SCHTASKS_CSV" \
        | grep -o '"\\\?HIMMEL-Resume-[^"]*"' 2>/dev/null \
        | tr -d '"\\' \
        | sort -u || true)
    _SCHTASKS_CACHE_DONE=1
}

list_existing() {
    local scope="${1:-all}"
    case "$PLATFORM" in
        windows)
            _ensure_schtasks_cache
            if [ "$scope" = task ]; then
                printf '%s\n' "$_SCHTASKS_NAMES" | grep -Fx "$TASK_NAME" || true
            else
                printf '%s\n' "$_SCHTASKS_NAMES"
            fi
            ;;
        linux)
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
                    # NB: use `if … then printf; fi`, NOT `grep … && printf`.
                    # A non-matching job makes grep exit 1; as the last command
                    # in this loop body that 1 would propagate out of the while
                    # loop → list_existing returns 1 → `existing=$(list_existing)`
                    # aborts under `set -e` (the multislot-on-Linux bug: arming a
                    # 2nd distinct handover failed whenever a non-matching at-job
                    # was already queued). The `if` always exits 0.
                    if [ "$scope" = task ]; then
                        # Exact whole-line marker (# $TASK_NAME) so a task
                        # whose name is a prefix of another's can't match it.
                        if at -c "$job_id" 2>/dev/null | grep -qxF "# $TASK_NAME"; then
                            printf 'at-job-%s\n' "$job_id"
                        fi
                    else
                        if at -c "$job_id" 2>/dev/null | grep -q 'HIMMEL-Resume-'; then
                            printf 'at-job-%s\n' "$job_id"
                        fi
                    fi
                done <<< "$atq_out"
            elif command -v crontab >/dev/null 2>&1; then
                _crontab_list "$scope"
            fi
            ;;
        macos)
            # macOS uses crontab only (see schedule_arm header) — read the same
            # store schedule writes so dedup operates on it, never the at queue.
            _crontab_list "$scope"
            ;;
    esac
}

# _crontab_delete <marker> — remove exactly one crontab LINE (HIMMEL-594:
# shared by the linux crontab branch + the macOS crontab-only branch).
_crontab_delete() {
    local marker="$1"
    # marker is the full matched crontab LINE — rewrite without exactly that
    # line (HIMMEL-340: scoped delete so a --force on one handover can't wipe
    # sibling slots). Snapshot first so a mid-pipeline failure doesn't wipe.
    local snap
    snap=$(mktemp -t crontab.snap.XXXXXX)
    if ! crontab -l > "$snap" 2>/dev/null; then
        echo "ERR arm-resume: crontab -l failed; aborting before rewrite" >&2
        rm -f "$snap"
        exit 2
    fi
    # grep -v exits 1 when it filters out EVERY line (deleting the LAST entry is
    # a valid empty result, not an error). Under `set -o pipefail` the old
    # `grep … | crontab -` read that grep-rc-1 as a rewrite failure and aborted
    # before schedule_arm could re-add — so capture tolerantly (rc 1 ok, rc>1 =
    # real grep error), then write + check crontab's OWN rc.
    local filtered rc=0
    filtered=$(grep -vxF "$marker" "$snap") || rc=$?
    if [ "$rc" -gt 1 ]; then
        echo "ERR arm-resume: crontab filter failed (grep rc=$rc); original saved at $snap" >&2
        exit 2
    fi
    # $filtered empty → install an empty crontab (correct); else write the lines.
    if ! { [ -z "$filtered" ] || printf '%s\n' "$filtered"; } | crontab - 2>/dev/null; then
        echo "ERR arm-resume: crontab rewrite failed; original saved at $snap" >&2
        exit 2
    fi
    rm -f "$snap"
    echo "arm-resume: removed crontab entry: $marker"
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
        linux)
            if [[ "$marker" == at-job-* ]]; then
                local job_id="${marker#at-job-}"
                if atrm "$job_id" 2>/dev/null; then
                    echo "arm-resume: removed at job: $job_id"
                else
                    echo "ERR arm-resume: failed to atrm $job_id" >&2
                    exit 2
                fi
            else
                _crontab_delete "$marker"
            fi
            ;;
        macos)
            # macOS: crontab-only, so the marker is always a crontab line
            # (the at-job-* arm is unreachable here).
            _crontab_delete "$marker"
            ;;
    esac
}

# HIMMEL-407: time-collision check against all other HIMMEL-* scheduled tasks.
#
# list_collision_candidates(): query the scheduler for all HIMMEL-* tasks
# (broader than the HIMMEL-Resume- filter used by list_existing), parse each
# next-run datetime, and emit "<name><TAB><HH:MM>" lines. Excludes the Resume
# slot being armed (already handled by dedup above — no double-reporting).
# ARM_COLLISION_CANDIDATES is a test seam: when set, its content replaces the
# real scheduler query (one "<name><TAB><HH:MM>" per line; empty = no others).
list_collision_candidates() {
    if [ -n "${ARM_COLLISION_CANDIDATES+x}" ]; then
        printf '%s' "$ARM_COLLISION_CANDIDATES"
        return 0
    fi
    case "$PLATFORM" in
        windows)
            # HIMMEL-708: reuse the memoized `schtasks /query` from
            # _ensure_schtasks_cache instead of a 2nd (identical) spawn. This
            # tightens ONE narrow case in the safe direction: a GENUINE schtasks
            # error now fail-closes (exit 2) at the earlier dedup read rather
            # than only WARN-skipping the collision check here — and the dedup
            # read already fail-closed on that same error before this branch was
            # reachable. What still reaches here is the benign rc!=0 "no tasks"
            # case, which WARNs and skips the collision check exactly as before.
            _ensure_schtasks_cache
            local out rc
            out="$_SCHTASKS_CSV"
            rc="$_SCHTASKS_RC"
            if [ "$rc" -ne 0 ]; then
                echo "WARN arm-resume: schtasks /query returned rc=$rc — skipping collision check" >&2
                return 0
            fi
            # Parse all HIMMEL-* tasks from CSV, excluding our own Resume slot.
            # CSV format (from /fo CSV /nh): "TaskName","Next Run Time","Status"
            # TaskName is path-prefixed: "\HIMMEL-Pipeline-Harvest"
            # Next Run Time is locale datetime: "6/20/2026 2:00:00 AM" or "N/A"
            local raw_lines name datetime hhmm
            # shellcheck disable=SC1003  # `"\\\?HIMMEL-"` — BRE \? = optional backslash; matches both "\HIMMEL-" and "HIMMEL-" (same style as list_existing)
            raw_lines=$(printf '%s\n' "$out" | grep -i '"\\\?HIMMEL-' 2>/dev/null || true)
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                # Extract task name (field 1, strip quotes + leading backslash)
                # shellcheck disable=SC1003  # `'\\'` strips the literal backslash schtasks path-prefixes task names with
                name=$(printf '%s' "$line" | cut -d'"' -f2 | tr -d '\\')
                [ -z "$name" ] && continue
                # Skip our own Resume task (dedup already handles it)
                [ "$name" = "$TASK_NAME" ] && continue
                # Only check HIMMEL-* tasks (all are toolchain-owned; any that
                # launches claude could collide — we don't inspect the body)
                case "$name" in HIMMEL-*) ;; *) continue ;; esac
                # Extract Next Run Time (field 4 = 4th quoted token)
                datetime=$(printf '%s' "$line" | cut -d'"' -f4)
                # "N/A" or empty = never fires / already ran → skip
                case "$datetime" in N/A|"") continue ;; esac
                # Parse HH:MM from locale datetime via armored python3.
                # Locale-safe: datetime module parses M/D/YYYY H:MM:SS AM/PM.
                # Failure = WARN + skip (never block an arm on parse errors).
                if py_armor_capture -c '
import sys, datetime as dt
s = sys.argv[1]
for fmt in ("%m/%d/%Y %I:%M:%S %p", "%m/%d/%Y %H:%M:%S", "%d/%m/%Y %H:%M:%S", "%Y-%m-%dT%H:%M:%S"):
    try:
        print(dt.datetime.strptime(s, fmt).strftime("%H:%M"))
        break
    except ValueError:
        pass
' "$datetime" 2>/dev/null; then
                    hhmm="$PY_ARMOR_OUT"
                    [ -n "$hhmm" ] && printf '%s\t%s\n' "$name" "$hhmm"
                else
                    echo "WARN arm-resume: could not parse next-run time '$datetime' for task '$name' — skipping in collision check" >&2
                fi
            done <<< "$raw_lines"
            ;;
        linux|macos)
            # crontab: grep all HIMMEL-* marker lines, parse HH:MM from the
            # cron fields (minute=$1, hour=$2 in standard crontab format).
            if command -v crontab >/dev/null 2>&1; then
                local crontab_out line mm hh name
                crontab_out=$(crontab -l 2>/dev/null || true)
                while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    case "$line" in *HIMMEL-*) ;; *) continue ;; esac
                    # Extract task name from trailing # HIMMEL-... marker
                    name=$(printf '%s' "$line" | grep -o 'HIMMEL-[^[:space:]]*$' || true)
                    [ -z "$name" ] && continue
                    [ "$name" = "$TASK_NAME" ] && continue
                    # Parse minute (field 1) and hour (field 2) from cron entry
                    mm=$(printf '%s' "$line" | awk '{print $1}')
                    hh=$(printf '%s' "$line" | awk '{print $2}')
                    # Skip wildcard or complex expressions (only plain numbers)
                    case "$mm$hh" in *[^0-9]*) continue ;; esac
                    printf '%s\t%02d:%02d\n' "$name" "$hh" "$mm"
                done <<< "$crontab_out"
            fi
            # at queue: inspect each job body for a HIMMEL- marker;
            # at doesn't expose the fire time per-job via atq in a reliable
            # parsed format across platforms → skip (collision guard is
            # best-effort on POSIX; the crontab branch covers the common case).
            ;;
    esac
}

# _minutes_from_midnight <HH:MM>: convert HH:MM to minutes since midnight (pure bash).
_minutes_from_midnight() {
    local t="$1" hh mm
    hh="${t%:*}"; mm="${t#*:}"
    # strip leading zeros to avoid octal interpretation
    hh="${hh#0}"; hh="${hh:-0}"
    mm="${mm#0}"; mm="${mm:-0}"
    printf '%d' $(( hh * 60 + mm ))
}

# suggest_free_slot <requested_HH:MM> <candidates_block>:
# Step outward from the requested time in ±WINDOW increments until a minute
# clear of all candidates ±window. Print "Suggested free slots: HH:MM or HH:MM"
# plus a re-run hint. candidates_block is the output of list_collision_candidates.
suggest_free_slot() {
    local req_hhmm="$1" candidates="$2"
    local window="${ARM_COLLISION_WINDOW:-${COLLISION_WINDOW_MINUTES:-5}}"
    case "$window" in ''|*[!0-9]*) window=5 ;; esac
    local req_min
    req_min=$(_minutes_from_midnight "$req_hhmm")

    # Collect candidate minutes
    local cand_mins=""
    while IFS=$'\t' read -r _cname chhmm; do
        [ -z "$chhmm" ] && continue
        cand_mins="$cand_mins $(_minutes_from_midnight "$chhmm")"
    done <<< "$candidates"

    # _is_free <minute>: rc 0 if that minute is clear of all candidates ±window
    _is_free() {
        local m="$1" cm diff
        for cm in $cand_mins; do
            diff=$(( m - cm ))
            [ "$diff" -lt 0 ] && diff=$(( -diff ))
            # Midnight wrap: if abs diff > 720, use 1440-diff
            [ "$diff" -gt 720 ] && diff=$(( 1440 - diff ))
            [ "$diff" -le "$window" ] && return 1
        done
        return 0
    }

    local slots="" step
    for step in 1 2 3 4 5 6 7 8 9 10 11 12; do
        local try_plus try_minus
        try_plus=$(( (req_min + step * (window + 1)) % 1440 ))
        try_minus=$(( (req_min - step * (window + 1) + 1440) % 1440 ))
        if _is_free "$try_plus"; then
            local hh mm
            hh=$(( try_plus / 60 )); mm=$(( try_plus % 60 ))
            local s
            s=$(printf '%02d:%02d' "$hh" "$mm")
            case "$slots" in *"$s"*) ;; *) slots="${slots:+$slots or }$s" ;; esac
        fi
        if _is_free "$try_minus" && [ "$try_minus" -ne "$try_plus" ]; then
            local hh2 mm2
            hh2=$(( try_minus / 60 )); mm2=$(( try_minus % 60 ))
            local s2
            s2=$(printf '%02d:%02d' "$hh2" "$mm2")
            case "$slots" in *"$s2"*) ;; *) slots="${slots:+$slots or }$s2" ;; esac
        fi
        # Stop once we have two suggestions
        local count=0
        case "$slots" in *" or "*) count=2 ;; *) [ -n "$slots" ] && count=1 ;; esac
        [ "$count" -ge 2 ] && break
    done

    if [ -n "$slots" ]; then
        echo "    Suggested free slots: $slots"
        echo "    Re-run: bash scripts/handover/arm-resume.sh --time <HH:MM> --handover <path>"
    fi
    echo "    Or pass --force to arm at $req_hhmm anyway (HIMMEL-407)."
}

# check_collision(): compare RESUME_TIME against all other HIMMEL-* tasks.
# Exact-minute match → HARD-REFUSE rc=6 (unless --force or --dedup-any → WARN).
# Within ±window → WARN (continue).
# Outside window → silent.
check_collision() {
    local window="${ARM_COLLISION_WINDOW:-${COLLISION_WINDOW_MINUTES:-5}}"
    case "$window" in ''|*[!0-9]*) window=5 ;; esac
    local candidates
    candidates=$(list_collision_candidates)
    [ -z "$candidates" ] && return 0

    local req_min
    req_min=$(_minutes_from_midnight "$RESUME_TIME")

    local exact_hits="" near_hits=""
    while IFS=$'\t' read -r cname chhmm; do
        [ -z "$cname" ] || [ -z "$chhmm" ] && continue
        local cm diff
        cm=$(_minutes_from_midnight "$chhmm")
        diff=$(( req_min - cm ))
        [ "$diff" -lt 0 ] && diff=$(( -diff ))
        [ "$diff" -gt 720 ] && diff=$(( 1440 - diff ))
        if [ "$diff" -eq 0 ]; then
            exact_hits="${exact_hits:+$exact_hits, }$cname ($chhmm)"
        elif [ "$diff" -le "$window" ]; then
            near_hits="${near_hits:+$near_hits, }$cname ($chhmm, ${diff}min away)"
        fi
    done <<< "$candidates"

    if [ -n "$exact_hits" ]; then
        if [ "$FORCE" -eq 1 ]; then
            echo "WARN arm-resume: --force: ignoring exact time collision at $RESUME_TIME with: $exact_hits" >&2
        elif [ "$DEDUP_ANY" -eq 1 ]; then
            # --dedup-any (unattended watchdog): WARN-ONLY, never refuse
            echo "WARN arm-resume: exact time collision at $RESUME_TIME with: $exact_hits (continuing — --dedup-any watchdog path; pass --force to suppress)" >&2
        else
            {
                echo "ERR arm-resume: time collision — $RESUME_TIME exactly matches another HIMMEL-* task:"
                echo "    $exact_hits"
                echo "Two concurrent claude sessions would launch at $RESUME_TIME, risking hung harvests,"
                echo "doubled API spend, and ~/.claude.json write races."
                suggest_free_slot "$RESUME_TIME" "$candidates"
            } >&2
            return 6
        fi
    fi

    if [ -n "$near_hits" ]; then
        echo "WARN arm-resume: near time collision (within ${window}min of $RESUME_TIME): $near_hits — two claude sessions may overlap. Pass --force to suppress." >&2
    fi

    return 0
}

# HIMMEL-340: dedup against the CURRENT handover's $TASK_NAME by default
# (so N distinct handovers each arm their own slot), or against ANY
# HIMMEL-Resume job under --dedup-any (the safety-arm semantics the
# auto-arm watchdogs rely on — defer to whatever is already queued).
DEDUP_SCOPE=task
[ "$DEDUP_ANY" -eq 1 ] && DEDUP_SCOPE=all
# HIMMEL-708: warm the Windows scheduler-listing cache in THIS (parent) shell so
# the $()-wrapped list_existing / list_collision_candidates readers below inherit
# it — a subshell populating it could not persist the globals up. Fail-closed
# (exit 2 on a genuine schtasks error) happens here, at the first read, exactly
# as before. Windows-only: POSIX still lists per-call (atq/crontab, cheap).
if [ "$PLATFORM" = windows ]; then
    _ensure_schtasks_cache
fi
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

# HIMMEL-856: queue-lock FRESH-holder refusal + cross-machine arms-registry
# dedup -- the two double-fire vectors from the 2026-07-10 00:51 incident
# that the existing same-machine dedup above cannot see: (a) a LIVE session
# is actively working this queue right now (scripts/handover/queue-lock.sh),
# and (b) this SAME handover already has a PENDING arm recorded on ANOTHER
# host (schtasks/cron are per-machine, so win2 arming a handover was
# invisible to main arming the same handover until this registry). Both
# checks are skipped -- WARN, never fail-closed -- when the handover root
# can't be resolved (HANDOVER_DIR unset and no inline handovers/ dir yet):
# this mechanism is additive infrastructure and must never brick every arm.
#
# LAYERED DEFENSE -- why check-then-append is acceptable here (HIMMEL-856
# CR, codex-1): the registry is a git-synced FILE shared across machines,
# so the pre-arm check and the append below cannot be made atomic across
# hosts -- two hosts arming in the same sync window can both pass the
# check. That is BY DESIGN: the registry is the ADVISORY EARLY-WARNING
# layer (catch the double-arm before either session fires); the queue lock
# taken at session start (overnight step 0 / queue-lock.sh acquire) is the
# ENFORCING layer -- a double-arm that slips through the registry still
# serializes there, with exactly one winner. The cheap mitigation for the
# window is the post-append re-read at the bottom of this script: after
# recording our own arm we re-scan the registry and, if another host's arm
# for the same handover became visible, print a LOUD operator warning
# naming the hosts (no non-zero exit -- the arm already happened; the
# warning is the value). Do not re-raise this as a race bug.

# _arm_registry_foreign_hits <registry-file> <handover-path> <this-host> --
# print a "; "-joined summary of every registry line recording an arm for
# <handover-path> on a host OTHER than <this-host> (empty = none). Always
# rc 0 (errexit-safe: the loop ends in string ops, nothing unguarded).
# HIMMEL-882: a consumed arm no longer has a record at all (queue-lock.sh's
# acquire DROPS this host's record(s) at session start -- retention, round
# 3), and any legacy '"fired":"true"'-marked line from the earlier marking
# revision is skipped here (and GC'd by the next locked rewrite) -- this is
# what lets a re-arm from another host stop hard-refusing (rc=8) once the
# original arm has actually fired, instead of forever.
_arm_registry_foreign_hits() {
    local _reg="$1" _ho="$2" _this_host="$3"
    local _needle _this_esc _hits="" _line _rhost _rfire _rtask
    # Both needles are JSON-escaped with the shared writer-side escape so an
    # escaped stored value (e.g. a backslash Windows path, doubled on write)
    # compares equal (round-2 -- raw-vs-escaped never matches).
    _hp_json_escape "$_ho"
    _needle="\"handover\":\"$_HP_ESC\""
    _hp_json_escape "$_this_host"; _this_esc="$_HP_ESC"
    [ -f "$_reg" ] || { printf '%s' ""; return 0; }
    # `|| [ -n "$_line" ]`: read returns 1 at EOF-without-newline while
    # still filling the variable -- without the guard a final record
    # lacking a trailing newline would be invisible to this scan.
    # Field extraction is the shared pure-bash _hp_json_field (round-3:
    # zero forks per line; the grep|head|sed pipelines this replaces cost
    # ~185-200ms/LINE on Windows/Git-Bash).
    while IFS= read -r _line || [ -n "$_line" ]; do
        [ -z "$_line" ] && continue
        case "$_line" in
            *"$_needle"*) ;;
            *) continue ;;
        esac
        case "$_line" in
            *'"fired":"true"'*) continue ;;
        esac
        _hp_json_field "$_line" host; _rhost="$_HP_FIELD"
        [ -z "$_rhost" ] && continue
        [ "$_rhost" = "$_this_esc" ] && continue
        _hp_json_field "$_line" fire-at;   _rfire="$_HP_FIELD"
        _hp_json_field "$_line" task-name; _rtask="$_HP_FIELD"
        _hits="${_hits:+$_hits; }host=$_rhost fire-at=$_rfire task=$_rtask"
    done < "$_reg"
    printf '%s' "$_hits"
}

# _arm_registry_mutex_acquire <registry-file> -- HIMMEL-882 CR round-2/3:
# acquire the short-lived mkdir-CAS mutex (<registry>.lock, a DIRECTORY)
# that serializes every arms.jsonl read-filter-rewrite writer. MUST stay
# path- and protocol-identical to queue-lock.sh's _ql_arms_mutex_acquire --
# the consume there and the prune-and-append here race each other on the
# same file (one registry per handover ROOT, so an arm on handover A and a
# session start on handover B are concurrent writers; last mv would win and
# drop the other's update). On success the lock dir carries an `owner`
# token file and $_ARM_REGISTRY_MUTEX_TOKEN names it -- release/mv are
# compare-then-act against that token (round-3: a holder reclaimed after
# the 60s staleness expiry must not blind-rmdir the reclaimer's lock or mv
# a stale snapshot over its rewrite). Bounded: nominal ~4s of 0.1s retries
# (platform-dependent -- measured ~2x that, ~8.7s, on Windows/Git-Bash from
# per-iteration mkdir+sleep overhead), then rc 1 -- the caller keeps the
# fail-open contract (WARN + skip, never fail the arm). A mutex stranded by
# a crashed writer is cleared when its dir mtime is >=60s old, re-probed
# every 10th iteration across the retry budget (round-4: NOT every
# iteration -- py_armor_mtime forks python and Windows python startup is
# ~100-300ms; probing every 10th yields ~4 probes across the ~40-iteration
# budget, bounding the extra forks while still catching a lock that crosses
# the 60s threshold mid-wait -- a lock that was, say, 56s old when this
# contender started is not yet stale at _tries==0 but would previously
# never be re-checked, burning the whole retry budget instead of
# reclaiming it; a failed probe never clears). errexit-safe: every probe is
# guarded, the loop exits only via return.
_ARM_REGISTRY_MUTEX_TOKEN=""
_arm_registry_mutex_acquire() {
    local _reg="$1" _lockd _tries=0 _m _now _tok
    _lockd="$_reg.lock"
    while :; do
        if mkdir "$_lockd" 2>/dev/null; then
            # Brand the lock (see queue-lock.sh's twin for the rationale).
            _tok="pid$$-r$RANDOM"
            if ! printf '%s' "$_tok" > "$_lockd/owner" 2>/dev/null; then
                rm -f "$_lockd/owner" 2>/dev/null
                rmdir "$_lockd" 2>/dev/null
                return 1
            fi
            _ARM_REGISTRY_MUTEX_TOKEN="$_tok"
            return 0
        fi
        if [ $(( _tries % 10 )) -eq 0 ]; then
            _m=$(py_armor_mtime "$_lockd") || _m=""
            _now=$(date -u +%s 2>/dev/null) || _now=""
            if [ -n "$_m" ] && [ -n "$_now" ] && [ $(( _now - _m )) -ge 60 ]; then
                rm -rf "$_lockd" 2>/dev/null
            fi
        fi
        _tries=$((_tries + 1))
        if [ "$_tries" -ge 40 ]; then
            return 1
        fi
        sleep 0.1
    done
}

# _arm_registry_mutex_release <registry-file> <token> -- compare-then-delete
# (round-3, twin of queue-lock.sh's _ql_arms_mutex_release): release the
# arms mutex ONLY if its owner token is still ours. A mismatch means the
# lock was reclaimed from under us mid-rewrite -- WARN loudly and leave the
# reclaimer's lock alone (rc 1); the caller has already skipped its stale
# mv on the same comparison. Residual (accepted): a reclaim landing between
# the token read and the rmdir can still lose its lock -- a microsecond
# window vs the whole-rewrite window this closes.
_arm_registry_mutex_release() {
    local _reg="$1" _tok="$2" _cur=""
    _cur=$(cat "$_reg.lock/owner" 2>/dev/null) || _cur=""
    if [ "$_cur" != "$_tok" ]; then
        echo "WARN arm-resume: the arms-registry mutex ($_reg.lock) was reclaimed by another writer mid-rewrite (owner token mismatch: now '${_cur:-none}') -- leaving their lock in place; this rewrite was discarded" >&2
        return 1
    fi
    rm -f "$_reg.lock/owner" 2>/dev/null
    rmdir "$_reg.lock" 2>/dev/null
    return 0
}

# _arm_registry_replace_and_append <registry-file> <host> <handover-path>
# <new-record-line> -- HIMMEL-882: drop any existing line whose host AND
# handover match (this host's own prior record(s) for this same handover),
# GC any legacy '"fired":"true"'-marked line in passing (retention, round
# 3 -- fired records are inert; both rewriters drop them so the registry
# stays O(active arms)), then append <new-record-line>. Without the prune,
# a re-arm or --force replace of the SAME handover on the SAME host left
# the superseded line sitting in arms.jsonl forever: harmless to THIS host
# (the dedup check above only looks at foreign hosts) but a permanent rc=8
# trap for the NEXT host that tries to arm this handover. CRASH-atomic:
# filtered+new content goes to a same-dir temp file, then mv into place --
# a mid-write crash never leaves a torn arms.jsonl. Temp+mv alone does NOT
# cover a CONCURRENT rewriter, so the whole read-filter-rewrite runs under
# the OWNER-TOKENED _arm_registry_mutex_acquire mkdir-CAS mutex shared with
# queue-lock.sh's consume, and the mv happens only while the owner token
# still names us. Needles are escaped with the shared _hp_json_escape
# (round-2 -- the stored values are JSON-escaped; raw-vs-escaped never
# matches). rc 1 on mutex timeout, mid-rewrite theft, or any write failure
# (caller WARNs and moves on); rc 0 on success. Single unlock point:
# failures only set _rc and fall through to the token-checked release
# (which WARNs about a theft). round-4 (sfh-2): on a write failure (not a
# mutex timeout/theft) $_ARM_REGISTRY_REPLACE_ERR carries the first line of
# the OS error (disk full / permission denied / RO-fs / AV lock, ...) so
# the caller's WARN can name it instead of reading identically to a mutex
# timeout; empty on success or on a mutex-timeout/theft failure.
_ARM_REGISTRY_REPLACE_ERR=""
_arm_registry_replace_and_append() {
    local _reg="$1" _host="$2" _ho="$3" _new="$4"
    local _tmp="$_reg.tmp.$$" _tok _cur _line _l_host _l_ho _host_esc _ho_esc _rc=0 _werr=""
    _ARM_REGISTRY_REPLACE_ERR=""
    if ! _arm_registry_mutex_acquire "$_reg"; then
        echo "WARN arm-resume: could not lock the arms registry ($_reg.lock) -- skipping the registry rewrite for this arm (a mutex stuck from a crashed writer self-expires after 60s)" >&2
        return 1
    fi
    _tok="$_ARM_REGISTRY_MUTEX_TOKEN"
    _hp_json_escape "$_host"; _host_esc="$_HP_ESC"
    _hp_json_escape "$_ho";   _ho_esc="$_HP_ESC"
    # round-4 (sfh-2): capture stderr instead of discarding it -- see
    # queue-lock.sh's twin for the rationale (2>/dev/null made a real write
    # failure read identically to a mutex timeout/theft).
    if _werr=$( { : > "$_tmp"; } 2>&1 ); then
        if [ -f "$_reg" ]; then
            # `|| [ -n "$_line" ]`: read returns 1 at EOF-without-newline
            # while still filling the variable -- without the guard the
            # rewrite silently DELETES a final record lacking a trailing
            # newline (round-2 Critical). Blank lines are dropped on
            # rewrite. ZERO forks per line (round-3 Critical):
            # _hp_json_field returns via $_HP_FIELD, no $().
            while IFS= read -r _line || [ -n "$_line" ]; do
                [ -z "$_line" ] && continue
                case "$_line" in
                    *'"fired":"true"'*) continue ;;   # GC legacy fired-marked line
                esac
                _hp_json_field "$_line" host;     _l_host="$_HP_FIELD"
                _hp_json_field "$_line" handover; _l_ho="$_HP_FIELD"
                if [ "$_l_host" = "$_host_esc" ] && [ "$_l_ho" = "$_ho_esc" ]; then
                    continue   # superseded by $_new -- drop
                fi
                printf '%s\n' "$_line" >> "$_tmp" || { _rc=1; break; }
            done < "$_reg"
        fi
        if [ "$_rc" -eq 0 ]; then
            printf '%s\n' "$_new" >> "$_tmp" || _rc=1
        fi
        if [ "$_rc" -eq 0 ]; then
            # OWNER-TOKEN verify (round-3): mv only while the mutex still
            # names us -- see queue-lock.sh's twin for the rationale. The
            # cat->mv window below is residual (accepted), same class as
            # _arm_registry_mutex_release's token-read->rmdir gap.
            _cur=$(cat "$_reg.lock/owner" 2>/dev/null) || _cur=""
            if [ "$_cur" = "$_tok" ]; then
                _werr=$(mv -f "$_tmp" "$_reg" 2>&1) || _rc=1
            else
                _rc=1   # reclaimed mid-rewrite: snapshot stale, skip the mv
            fi
        fi
    else
        _rc=1
    fi
    if [ "$_rc" -ne 0 ]; then
        rm -f "$_tmp" 2>/dev/null
        [ -n "$_werr" ] && _ARM_REGISTRY_REPLACE_ERR="${_werr%%$'\n'*}"
    fi
    _arm_registry_mutex_release "$_reg" "$_tok" || true
    return "$_rc"
}

# _arm_hostname -- this machine's identity for registry records/compares.
_arm_hostname() {
    local _h=""
    _h=$(hostname 2>/dev/null) || _h=""
    [ -z "$_h" ] && _h="${COMPUTERNAME:-${HOSTNAME:-unknown-host}}"
    printf '%s' "$_h"
}

HIMMEL_856_HR_ROOT=""
HIMMEL_856_HR_ROOT=$(handover_root 2>/dev/null) || HIMMEL_856_HR_ROOT=""
if [ -z "$HIMMEL_856_HR_ROOT" ]; then
    echo "WARN arm-resume: could not resolve the handover root -- skipping queue-lock + arms-registry checks (HIMMEL-856)" >&2
else
    QUEUE_LOCK_SH="$SCRIPT_DIR/queue-lock.sh"
    if [ -f "$QUEUE_LOCK_SH" ]; then
        # `|| _ql_status_rc=$?` (not a bare assignment) -- under `set -e`,
        # `var=$(cmd)` where cmd exits non-zero (rc=11/12 = held here, a
        # normal outcome, not a script error) would otherwise abort the
        # whole arm right here instead of reaching the rc-7 refusal below.
        _ql_status_rc=0
        _ql_status_out=$(bash "$QUEUE_LOCK_SH" status "$HANDOVER_PATH" 2>&1) || _ql_status_rc=$?
        if [ "$_ql_status_rc" -eq 11 ]; then
            if [ "${QUEUE_LOCK_TAKEOVER:-}" = "1" ]; then
                {
                    echo "WARN arm-resume: queue lock is FRESH for this handover -- arming anyway (QUEUE_LOCK_TAKEOVER=1):"
                    printf '%s\n' "$_ql_status_out" | sed 's/^/    /'
                } >&2
            else
                {
                    echo "ERR arm-resume: refusing to arm -- a session is LIVE on this handover's queue right now:"
                    printf '%s\n' "$_ql_status_out" | sed 's/^/    /'
                    echo "Two live sessions on the same queue is exactly the 2026-07-10 00:51 double-fire (HIMMEL-856)."
                    echo "Override with QUEUE_LOCK_TAKEOVER=1 if you are certain the holder is gone/stale."
                } >&2
                exit 7
            fi
        elif [ "$_ql_status_rc" -ne 0 ] && [ "$_ql_status_rc" -ne 12 ]; then
            # rc 0 = free, 12 = held-but-STALE (arming over a stale lock is
            # fine -- the session-start acquire supersedes it). Anything
            # else means the status check itself broke -- say so instead of
            # silently proceeding as if the queue were verified free.
            echo "WARN arm-resume: queue-lock status failed (rc=$_ql_status_rc) -- proceeding WITHOUT the queue-lock check:" >&2
            printf '%s\n' "$_ql_status_out" | sed 's/^/    /' >&2
        fi
        unset _ql_status_out _ql_status_rc
    else
        # Missing script is a skipped check, not a silent pass -- same WARN
        # contract as the unresolvable-handover-root branch above.
        echo "WARN arm-resume: queue-lock.sh not found at '$QUEUE_LOCK_SH' -- skipping the queue-lock check (HIMMEL-856)" >&2
    fi

    HIMMEL_856_ARMS_REGISTRY="$HIMMEL_856_HR_ROOT/.locks/arms.jsonl"
    if [ -f "$HIMMEL_856_ARMS_REGISTRY" ]; then
        _arm_dup_hits=$(_arm_registry_foreign_hits "$HIMMEL_856_ARMS_REGISTRY" "$HANDOVER_PATH" "$(_arm_hostname)")
        if [ -n "$_arm_dup_hits" ]; then
            if [ "${ARM_DUP_OK:-}" = "1" ]; then
                echo "WARN arm-resume: this handover already has a PENDING arm on another host ($_arm_dup_hits) -- arming anyway (ARM_DUP_OK=1)" >&2
            else
                {
                    echo "ERR arm-resume: refusing to arm -- this handover already has a PENDING arm recorded on another host:"
                    echo "    $_arm_dup_hits"
                    echo "This is the win2+main-both-arming shape from the 2026-07-10 00:51 incident (HIMMEL-856)."
                    echo "Override with ARM_DUP_OK=1 if you are certain the other host's arm is stale/cancelled."
                } >&2
                exit 8
            fi
        fi
        unset _arm_dup_hits
    fi
fi

# HIMMEL-407: time-collision check — runs AFTER the same-handover dedup block
# and BEFORE schedule_arm. Runs even under --dry-run (it mutates nothing).
# On exact-minute collision: rc=6 (HARD-REFUSE) unless --force or --dedup-any.
# Near collision (within window): WARN only. Outside window: silent.
_collision_rc=0
check_collision || _collision_rc=$?
if [ "$_collision_rc" -eq 6 ]; then
    exit 6
fi

# Build and execute the scheduler command directly — no round-trip
# through schedule-resume.sh's mixed-prose stdout (the v1 bug).
# _crontab_schedule — install the one-shot crontab entry (HIMMEL-594: shared by
# the linux crontab fallback + the macOS crontab-only branch). Uses the script
# globals RESUME_TIME/RESUME_PROMPT/RESUME_CWD/CHANNELS/TASK_NAME/DRY_RUN only.
# A `return 0` here (dry-run) returns to the schedule_arm case, which then ends
# and returns 0 — equivalent to the pre-extraction inline `return 0`.
_crontab_schedule() {
    # crontab fallback — crontab entries are RECURRING, so the
    # entry SELF-REMOVES as its first action (the cron analogue of
    # the schtasks .bat self-/delete above): it rewrites the
    # crontab without its own marker line before running cd+claude,
    # turning the recurring entry into a one-shot. The running
    # /bin/sh -c continues after the rewrite, so claude still
    # launches. The marker match is ANCHORED at end-of-line
    # (grep -vE '# <TASK_NAME>$'), mirroring the dedup detector's
    # crontab branch in list_existing so a sibling slot whose
    # TASK_NAME is a strict PREFIX of this one is not cross-matched
    # and survives. TASK_NAME is sanitized to [:alnum:]_- so it
    # carries no ERE specials. The terminal `crontab -` is NOT
    # error-suppressed: a silently-failed rewrite would leave the
    # entry RECURRING (a daily relaunch loop) while we told the
    # operator it is one-shot, so let cron surface the failure
    # (mail/log) — the manual-prune hint printed below is the
    # backstop. printf '%q' shell-quotes the prompt so cron's
    # /bin/sh -c can't re-interpret $/backticks/etc in a handover
    # path.
    local hh="${RESUME_TIME%:*}" mm="${RESUME_TIME#*:}"
    local q_prompt q_cwd q_channels="" q_name=""
    q_prompt=$(printf '%q' "$RESUME_PROMPT")
    q_cwd=$(printf '%q' "$RESUME_CWD")
    [ -n "$CHANNELS" ] && q_channels="--channels $(printf '%q' "$CHANNELS") "
    # -n <session name> (HIMMEL-702): %q-quote so a space in "<TICKET> <name>"
    # stays ONE arg through the /bin/sh re-parse at fire time. Empty -> omit.
    [ -n "$SESSION_NAME" ] && q_name="-n $(printf '%q' "$SESSION_NAME") "
    local self_clean="crontab -l 2>/dev/null | grep -vE '# ${TASK_NAME}\$' | crontab -;"
    # HIMMEL_HEADROOM_PROXY (HIMMEL-901): a crontab entry is ONE line, so the
    # livez-check-then-launch logic (same shape as the `at` branch's
    # $launch_lines) has to be a single ';'-joined compound wrapped in its
    # own `{ ; }` group — `cd ... && { ...; }` keeps `cd` a hard gate (plain
    # `&&`/`||` chaining without the group would let a failed cd fall
    # through into starting the proxy, since `&&`/`||` are left-associative
    # at equal precedence). Inactive -> $tail is byte-identical to the
    # pre-901 line (zero behavior change).
    # CR round: absolute curl path ($q_curl) + one mode-marker echo per
    # branch (HIMMEL-897 trail). The marker uses `echo "\$(date) ..."`, NOT
    # printf: cron treats an unescaped % in the command as end-of-command +
    # stdin, so a printf format string would truncate the entry. `\$(date)`
    # lands literally and evaluates at fire time.
    local tail="claude ${q_name}$q_prompt $q_channels"
    if [ "$HEADROOM_PROXY_ACTIVE" -eq 1 ]; then
        local q_hb q_log q_curl
        q_hb=$(printf '%q' "$HEADROOM_BIN")
        q_log=$(printf '%q' "$HOME/.headroom-proxy.log")
        q_curl=$(printf '%q' "$HEADROOM_CURL")
        tail="{ $q_curl -s -m 5 http://127.0.0.1:$HEADROOM_PROXY_PORT/livez >/dev/null 2>&1 || { $q_hb proxy --port $HEADROOM_PROXY_PORT >> $q_log 2>&1 & sleep 3; }; if $q_curl -s -m 5 http://127.0.0.1:$HEADROOM_PROXY_PORT/livez >/dev/null 2>&1; then echo \"\$(date) arm=$TASK_NAME mode=proxied\" >> $q_log; ANTHROPIC_BASE_URL=http://127.0.0.1:$HEADROOM_PROXY_PORT HEADROOM_OFFLINE=1 claude ${q_name}$q_prompt $q_channels; else echo \"\$(date) arm=$TASK_NAME mode=bare-fallback\" >> $q_log; claude ${q_name}$q_prompt $q_channels; fi; }"
    fi
    local entry="$mm $hh * * * $self_clean cd $q_cwd && $tail # $TASK_NAME"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY arm-resume: would add crontab entry:"
        echo "    $entry"
        echo "DRY arm-resume: NOTE: entry self-removes on first fire (one-shot)."
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
    echo "arm-resume: NOTE: crontab entry self-removes on first fire (one-shot)."
    echo "    If it never fires, prune manually with:"
    echo "    crontab -l | grep -v 'HIMMEL-Resume' | crontab -"
}

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
            # bash mktemp on gitbash returns POSIX path; schtasks wants a
            # Windows path. cygpath converts. cygpath must exist here (Linux
            # would already have failed the platform check above).
            if ! command -v cygpath >/dev/null 2>&1; then
                echo "ERR arm-resume: cygpath not on PATH; cannot convert paths for schtasks" >&2
                echo "    Install Git for Windows (which ships cygpath)." >&2
                rm -f "$bat_path"
                exit 2
            fi
            # Resolve claude.cmd to an absolute path so the .bat doesn't
            # depend on PATH being set in whatever cmd shell schtasks
            # spawns (SYSTEM context lacks npm-installed shims by default).
            local claude_cmd_posix
            if ! claude_cmd_posix=$(command -v claude 2>/dev/null); then
                echo "ERR arm-resume: 'claude' not on PATH at arm time" >&2
                rm -f "$bat_path"
                exit 2
            fi
            # HIMMEL-708: convert all three paths (.bat, claude, cwd) in ONE
            # cygpath spawn instead of three — cygpath emits one Windows path
            # per input line, in argument order. Windows paths contain no
            # newlines, so split the result with pure-bash parameter expansion
            # (no extra sed/head spawns).
            local bat_path_win claude_cmd_win resume_cwd_win _cyg_out _cyg_rest
            if ! _cyg_out=$(cygpath -w "$bat_path" "$claude_cmd_posix" "$RESUME_CWD" 2>&1); then
                echo "ERR arm-resume: cygpath -w failed converting one of [bat=$bat_path claude=$claude_cmd_posix cwd=$RESUME_CWD]: $_cyg_out" >&2
                rm -f "$bat_path"
                exit 4
            fi
            bat_path_win="${_cyg_out%%$'\n'*}"
            _cyg_rest="${_cyg_out#*$'\n'}"
            claude_cmd_win="${_cyg_rest%%$'\n'*}"
            resume_cwd_win="${_cyg_rest#*$'\n'}"
            # Belt-and-suspenders (HIMMEL-708 CR): a well-behaved cygpath emits
            # exactly three non-empty lines on rc 0, so the split above is sound.
            # Guard anyway against a build that exits 0 with fewer lines —
            # otherwise resume_cwd_win would silently inherit claude_cmd_win (the
            # `#*\n` no-ops when no newline remains) and mis-target the .bat cd.
            # Mirrors the non-empty check the python-derived schedule fields get.
            if [ -z "$bat_path_win" ] || [ -z "$claude_cmd_win" ] || [ -z "$resume_cwd_win" ]; then
                echo "ERR arm-resume: cygpath -w produced incomplete output (bat/claude/cwd): $_cyg_out" >&2
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
            # -n <session name> (HIMMEL-702). SESSION_NAME is sanitized to
            # [A-Za-z0-9._ -] (see _compose_arm_name) so it carries no CMD
            # metacharacter and needs no ^-escaping here; quote it so the space
            # in "<TICKET> <name>" stays a single argv entry. Empty -> omit.
            local nm=""
            [ -n "$SESSION_NAME" ] && nm=" -n \"$SESSION_NAME\""
            # HIMMEL_HEADROOM_PROXY (HIMMEL-901): a SEPARATE cygpath call
            # (not folded into the batched bat/claude/cwd conversion above)
            # so the existing HIMMEL-708 3-path split logic stays untouched
            # when the flag is off — this only spawns when the flag is on.
            # CR round: curl gets the same treatment as HEADROOM_BIN (one
            # cygpath spawn for both) so the livez checks below carry an
            # ABSOLUTE curl path — see the HEADROOM_CURL resolution comment.
            local hb="" cu=""
            if [ "$HEADROOM_PROXY_ACTIVE" -eq 1 ]; then
                local _hp_cyg_out _hp_cyg_rest headroom_bin_win curl_bin_win
                if ! _hp_cyg_out=$(cygpath -w "$HEADROOM_BIN" "$HEADROOM_CURL" 2>&1); then
                    echo "ERR arm-resume: cygpath -w failed converting [headroom=$HEADROOM_BIN curl=$HEADROOM_CURL]: $_hp_cyg_out" >&2
                    rm -f "$bat_path"
                    exit 4
                fi
                headroom_bin_win="${_hp_cyg_out%%$'\n'*}"
                _hp_cyg_rest="${_hp_cyg_out#*$'\n'}"
                curl_bin_win="${_hp_cyg_rest%%$'\n'*}"
                # Same incomplete-output guard as the batched 3-path split
                # above (HIMMEL-708 CR): a cygpath that exits 0 with fewer
                # lines must not leave curl_bin_win aliasing headroom_bin_win.
                if [ -z "$headroom_bin_win" ] || [ -z "$curl_bin_win" ] || [ "$_hp_cyg_out" = "$_hp_cyg_rest" ]; then
                    echo "ERR arm-resume: cygpath -w produced incomplete output (headroom/curl): $_hp_cyg_out" >&2
                    rm -f "$bat_path"
                    exit 4
                fi
                hb=$(_cmd_metachar_escape "$headroom_bin_win")
                cu=$(_cmd_metachar_escape "$curl_bin_win")
            fi
            # Self-clean FIRST: a /sc ONCE task lingers in Task Scheduler
            # after it fires (Ready/completed), accumulating stale jobs and
            # blocking a future same-handover arm without --force. So the
            # launcher deletes its OWN task as its first action. Deleting a
            # one-shot task's registration does NOT terminate the already-
            # spawned action process, so claude still launches below.
            # Non-fatal (>nul 2>&1, no `|| exit`): a failed cleanup must
            # never block the relaunch. TASK_NAME is sanitized to
            # [:alnum:]_- so it carries no CMD metacharacters.
            # cd /d switches drive + path in one step; quoted to survive
            # spaces. `|| exit /b 1` ensures the .bat aborts instead of
            # silently falling through to claude.exe in the wrong CWD
            # (which is the bug this fix targets — see comment above
            # RESUME_CWD computation).
            # Prompt MUST come before --channels: --channels is variadic
            # (consumes following args), so a trailing positional prompt
            # gets parsed as a bogus channel entry ("must be tagged" → exit 1).
            # HIMMEL_HEADROOM_PROXY (HIMMEL-901): when active, gate the
            # claude launch on a livez check, starting the proxy DETACHED
            # if it's down and giving it ~3s before rechecking. Fail-open:
            # if it's STILL down after the retry, fall through to a bare
            # launch (a broken proxy must never block the relaunch) — the
            # log at %USERPROFILE%\.headroom-proxy.log is the only trail.
            # `start "" /b cmd /c "..."` (not `start "" /b <exe> ... >>log`,
            # which does not reliably redirect the child) is the verified
            # detached-with-redirection form. `if errorlevel 1` reads the
            # LAST command's exit code, so the second `if errorlevel 1`
            # below correctly reflects either the original livez check (skip
            # branch never ran) or the retry livez check (skip branch ran) —
            # no delayed-expansion (!VAR!) needed anywhere. %USERPROFILE% is
            # a literal CMD env-var reference (NOT run through the %->%%
            # escaping below, which is for literal-data percents only).
            # CR round: each branch appends ONE mode-marker line to the
            # proxy log before launching (proxied vs bare-fallback) — the
            # HIMMEL-897 measurement trail; without it a fired launch is
            # indistinguishable after the fact. %DATE%/%TIME% expand when
            # CMD parses the if-block, close enough to launch time.
            # TASK_NAME is sanitized to [:alnum:]_- (no CMD metachars).
            {
                printf 'schtasks /delete /tn "%s" /f >nul 2>&1\r\n' "$TASK_NAME"
                printf 'cd /d "%s" || exit /b 1\r\n' "$c"
                if [ "$HEADROOM_PROXY_ACTIVE" -eq 1 ]; then
                    printf '"%s" -s -m 5 http://127.0.0.1:%s/livez >nul 2>&1\r\n' "$cu" "$HEADROOM_PROXY_PORT"
                    printf 'if errorlevel 1 (\r\n'
                    printf '    start "" /b cmd /c ""%s" proxy --port %s >> "%%USERPROFILE%%\\.headroom-proxy.log" 2>&1"\r\n' "$hb" "$HEADROOM_PROXY_PORT"
                    printf '    ping -n 4 127.0.0.1 >nul\r\n'
                    printf '    "%s" -s -m 5 http://127.0.0.1:%s/livez >nul 2>&1\r\n' "$cu" "$HEADROOM_PROXY_PORT"
                    printf ')\r\n'
                    printf 'if errorlevel 1 (\r\n'
                    printf '    echo %%DATE%% %%TIME%% arm=%s mode=bare-fallback>> "%%USERPROFILE%%\\.headroom-proxy.log"\r\n' "$TASK_NAME"
                    printf '    "%s"%s "%s"%s\r\n' "$claude_cmd_win" "$nm" "$p" "$ch"
                    printf ') else (\r\n'
                    printf '    echo %%DATE%% %%TIME%% arm=%s mode=proxied>> "%%USERPROFILE%%\\.headroom-proxy.log"\r\n' "$TASK_NAME"
                    printf '    set "ANTHROPIC_BASE_URL=http://127.0.0.1:%s"\r\n' "$HEADROOM_PROXY_PORT"
                    printf '    set "HEADROOM_OFFLINE=1"\r\n'
                    printf '    "%s"%s "%s"%s\r\n' "$claude_cmd_win" "$nm" "$p" "$ch"
                    printf ')\r\n'
                else
                    printf '"%s"%s "%s"%s\r\n' "$claude_cmd_win" "$nm" "$p" "$ch"
                fi
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
        linux)
            if command -v at >/dev/null 2>&1; then
                # at jobs are one-shot and atd removes them from the queue
                # after they run, so (unlike schtasks ONCE and crontab) the
                # at body needs no self-clean line — the queue cleans itself.
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
                local q_prompt q_cwd q_channels="" q_name=""
                q_prompt=$(printf '%q' "$RESUME_PROMPT")
                q_cwd=$(printf '%q' "$RESUME_CWD")
                # %q shell-quotes the channels spec so /bin/sh can't
                # re-interpret it at fire time; trailing space separates
                # it from the prompt arg (empty when no --channels).
                [ -n "$CHANNELS" ] && q_channels="--channels $(printf '%q' "$CHANNELS") "
                # -n <session name> (HIMMEL-702): %q so "<TICKET> <name>"
                # stays one arg after the /bin/sh re-parse. Empty -> omit.
                [ -n "$SESSION_NAME" ] && q_name="-n $(printf '%q' "$SESSION_NAME") "
                # HIMMEL_HEADROOM_PROXY (HIMMEL-901): $launch_lines is the
                # plain 'claude ...' line unless the flag is active, in
                # which case it becomes a livez-check-then-launch block
                # (same shape as _crontab_schedule's $tail above) — built
                # ONCE so the dry-run echo and the real heredoc can't drift
                # apart. Inactive -> byte-identical to the pre-901 line.
                # CR round: absolute curl path ($q_curl — see HEADROOM_CURL)
                # + one mode-marker echo per branch (HIMMEL-897 trail).
                # `\$(date)` is escaped so it lands LITERALLY in the job
                # body and evaluates at FIRE time, not arm time.
                local launch_lines="claude ${q_name}$q_prompt $q_channels"
                if [ "$HEADROOM_PROXY_ACTIVE" -eq 1 ]; then
                    local q_hb q_log q_curl
                    q_hb=$(printf '%q' "$HEADROOM_BIN")
                    q_log=$(printf '%q' "$HOME/.headroom-proxy.log")
                    q_curl=$(printf '%q' "$HEADROOM_CURL")
                    launch_lines="$q_curl -s -m 5 http://127.0.0.1:$HEADROOM_PROXY_PORT/livez >/dev/null 2>&1 || { $q_hb proxy --port $HEADROOM_PROXY_PORT >> $q_log 2>&1 & sleep 3; }
if $q_curl -s -m 5 http://127.0.0.1:$HEADROOM_PROXY_PORT/livez >/dev/null 2>&1; then
    echo \"\$(date) arm=$TASK_NAME mode=proxied\" >> $q_log
    ANTHROPIC_BASE_URL=http://127.0.0.1:$HEADROOM_PROXY_PORT HEADROOM_OFFLINE=1 claude ${q_name}$q_prompt $q_channels
else
    echo \"\$(date) arm=$TASK_NAME mode=bare-fallback\" >> $q_log
    claude ${q_name}$q_prompt $q_channels
fi"
                fi
                if [ "$DRY_RUN" -eq 1 ]; then
                    echo "DRY arm-resume: would at -t $AT_STAMP <<'CMD'"
                    echo "    # $TASK_NAME"
                    echo "    cd $q_cwd || exit 1"
                    printf '%s\n' "$launch_lines" | sed 's/^/    /'
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
$launch_lines
CMD
                then
                    echo "ERR arm-resume: at -t $AT_STAMP failed:" >&2
                    cat "$err_file" >&2
                    rm -f "$err_file"
                    exit 4
                fi
                rm -f "$err_file"
            else
                _crontab_schedule
            fi
            ;;
        macos)
            # macOS deliberately uses crontab, NOT at: atrun (com.apple.atrun)
            # is off-by-default and may be unenableable under SIP, so an `at -t`
            # job would silently never fire. crontab is the per-user one-shot
            # primitive needing no privileged daemon. (HIMMEL-594)
            _crontab_schedule ;;
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

# HIMMEL-856: record this arm in the cross-machine arms registry, same
# dry-run gate as telemetry above. Best-effort -- a registry write failure
# must never fail an arm that already succeeded (fail-open, loud trail).
# HIMMEL-882: prune this SAME host's prior record(s) for this SAME handover
# before appending the fresh one (see _arm_registry_replace_and_append) --
# closes the re-arm/--force accumulation gap that would otherwise block a
# later cross-host arm forever, on top of the consume queue-lock.sh does at
# session start (see its own HIMMEL-882 comment).
if [ -n "${HIMMEL_856_HR_ROOT:-}" ]; then
    _arm_host=$(_arm_hostname)
    # `|| true`: an unwritable .locks (e.g. a FILE squatting on the dir
    # path) must not errexit-abort a script whose arm ALREADY succeeded --
    # the failure surfaces as the replace-and-append WARN below instead.
    mkdir -p "$HIMMEL_856_HR_ROOT/.locks" 2>/dev/null || true
    # Values are escaped with the shared _hp_json_escape (round-3) -- the
    # SAME transform every reader's needle uses, so escaped-vs-escaped
    # comparisons hold by construction.
    _hp_json_escape "$_arm_host";     _arm_rec_host="$_HP_ESC"
    _hp_json_escape "$HANDOVER_PATH"; _arm_rec_ho="$_HP_ESC"
    _hp_json_escape "$AT_STAMP";      _arm_rec_fire="$_HP_ESC"
    _hp_json_escape "$TASK_NAME";     _arm_rec_task="$_HP_ESC"
    _arm_new_record=$(printf '{"host":"%s","handover":"%s","fire-at":"%s","task-name":"%s"}' \
        "$_arm_rec_host" "$_arm_rec_ho" "$_arm_rec_fire" "$_arm_rec_task")
    unset _arm_rec_host _arm_rec_ho _arm_rec_fire _arm_rec_task
    if ! _arm_registry_replace_and_append "$HIMMEL_856_HR_ROOT/.locks/arms.jsonl" "$_arm_host" "$HANDOVER_PATH" "$_arm_new_record"; then
        # round-4 (sfh-2): fold the first line of the captured write error
        # (if any -- empty on a mutex timeout/theft) so this WARN reads
        # differently from those cases.
        echo "WARN arm-resume: failed to append the arms.jsonl registry record (the arm itself still succeeded)${_ARM_REGISTRY_REPLACE_ERR:+ (write error: $_ARM_REGISTRY_REPLACE_ERR)}" >&2
    fi
    unset _arm_new_record
    # Post-append re-read (HIMMEL-856 CR, codex-1 -- see the LAYERED
    # DEFENSE comment at the pre-arm check): the check-then-append pair
    # above cannot be atomic across machines, so AFTER recording our own
    # arm, re-scan the registry. If another host's arm for this same
    # handover is now visible (it landed in the check->append window, or
    # was let through with ARM_DUP_OK=1), tell the operator LOUDLY which
    # hosts double-armed. No non-zero exit -- the arm already happened;
    # the queue lock at session start is the layer that serializes the
    # actual double-fire.
    _arm_post_hits=$(_arm_registry_foreign_hits "$HIMMEL_856_HR_ROOT/.locks/arms.jsonl" "$HANDOVER_PATH" "$_arm_host")
    if [ -n "$_arm_post_hits" ]; then
        {
            echo "=================================================================="
            echo "  WARN arm-resume: DOUBLE-ARM DETECTED (HIMMEL-856)"
            echo "  This handover now has PENDING arms on MULTIPLE hosts:"
            echo "      this host:  $_arm_host"
            echo "      also armed: $_arm_post_hits"
            echo "  Cancel one of them (schtasks /delete on the losing host, or"
            echo "  its cron/at equivalent) -- otherwise both will fire and"
            echo "  serialize only at the queue lock, wasting a session slot."
            echo "=================================================================="
        } >&2
    fi
    unset _arm_host _arm_post_hits
fi

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
