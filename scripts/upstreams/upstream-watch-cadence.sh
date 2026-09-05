#!/usr/bin/env bash
# upstream-watch-cadence.sh — arm/status/disarm the daily upstream-watch scan
# cadence (HIMMEL-2367).
#
# WHY: a resident interactive claude session used to poll himmel's open
# upstream PRs/issues every 20 minutes, burning tokens. Operator ruling
# 2026-09-01: "we should monitor it daily not as a puller and with tokens" —
# this arms ONE daily local scheduled task (schtasks on Windows, crontab on
# Linux/macOS; structural sibling of drift-fix-cadence.sh / qmd-cadence.sh)
# that runs `bash scripts/upstreams/upstream-watch.sh` directly. There is NO
# claude session here at all — never `--model`, never a payload prompt — so
# HIMMEL-128 (headless-claude billing) does not apply even indirectly, the
# same reasoning qmd-cadence.sh's header gives for its own deterministic
# runner. ONE leg, unlike drift-fix-cadence's two: upstream-watch.sh has no
# "conflicted, a human must decide" branch that would need isolating from a
# sibling repair — it either finds a delta or it doesn't, so nothing here can
# get stuck the way a fork rebase can.
#
# This cadence self-registers with the observability registry
# (scripts/lib/observability-registry.sh) on arm/disarm, unlike
# drift-fix-cadence.sh, which does not register anywhere and is invisible to
# himmel-doctor's C24 check. That gap is not repeated here — see the
# observability_register_cadence / observability_unregister_cadence call
# sites below (same pattern as scripts/cleanup/codex-sweep-cadence.sh).
#
# Default fire time 06:00 local — after drift-fix-cadence's 05:00/05:30 legs
# (no overlap on the same machine) and still well before the workday.
# StartWhenAvailable=true (Windows): a fire missed because the machine was
# off/asleep catches up when it is next on.
#
# Usage:
#   bash scripts/upstreams/upstream-watch-cadence.sh arm [--time HH:MM] [--force] [--dry-run]
#   bash scripts/upstreams/upstream-watch-cadence.sh status
#   bash scripts/upstreams/upstream-watch-cadence.sh disarm [--dry-run]
#
# Test seams (used by test-upstream-watch-cadence.sh):
#   UPSTREAMWATCH_SCHTASKS       command invoked instead of `schtasks` (Windows)
#   UPSTREAMWATCH_CRONTAB        command invoked instead of `crontab` (POSIX)
#   UPSTREAMWATCH_BAT_DIR        where the persistent runner (.bat/.sh) + log live
#   UPSTREAMWATCH_HIMMEL_ROOT    overrides the resolved primary checkout outright
#   UPSTREAMWATCH_PLATFORM       force `windows` or `posix` (else: derived from OSTYPE)
#   HIMMEL_OBSERVABILITY_CONFIG  (existing seam, scripts/lib/observability-registry.sh)
#                                 overrides the observability-registry path arm/disarm
#                                 register with — MUST be set in tests, real or hand
#                                 smoke-tests alike: this arm/disarm's registration
#                                 write is otherwise unscoped and lands in the real
#                                 ~/.himmel/observability.json regardless of every
#                                 other UPSTREAMWATCH_* seam above (HIMMEL-2367 leak,
#                                 caught live: a hand smoke-test without this set
#                                 registered HIMMEL-UpstreamWatch as an expected task
#                                 and paged on the resulting scheduled-task-missing
#                                 alert once disarm wasn't called to match)
#
# Exit codes (mirrors drift-fix-cadence.sh's contract exactly):
#   0  done (armed / status printed / disarmed / dry-run complete)
#   1  usage or input error (bad subcommand, flag, --time)
#   2  env unusable (no scheduler, unknown platform, missing payload script)
#   3  dedup block — already armed; --force replaces
#   4  scheduler invocation failed (create/delete/query), or the post-arm
#      verify failed
set -euo pipefail

TASK_NAME="HIMMEL-UpstreamWatch"
SCHTASKS_BIN="${UPSTREAMWATCH_SCHTASKS:-schtasks}"
CRONTAB_BIN="${UPSTREAMWATCH_CRONTAB:-crontab}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cross-platform user-home resolution (HIMMEL-645): prefer USERPROFILE via
# cygpath on Windows Git-Bash (MSYS $HOME can differ from where ~/.claude
# actually lives).
resolve_user_home() {
    if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$USERPROFILE" 2>/dev/null || printf '%s' "$USERPROFILE"
    else
        printf '%s' "${HOME:-${USERPROFILE:-/tmp}}"
    fi
}

# Persistent runner home — deliberately NOT %TEMP%/mktemp: this task recurs
# daily and temp sweeps would silently kill the cadence.
BAT_DIR="${UPSTREAMWATCH_BAT_DIR:-$(resolve_user_home)/.claude/upstream-watch-cadence}"

# Resolve the himmel root to the PRIMARY checkout, never this script's own
# location (mirrors drift-fix-cadence.sh's resolve_himmel_root, HIMMEL-892
# codex-adv-1): arming from a feature worktree would embed that worktree's
# absolute path in the persistent runner, and the post-merge prune then
# deletes it — every later fire would cd into nothing.
resolve_himmel_root() {
    local common_dir
    command -v git >/dev/null 2>&1 || return 1
    common_dir="$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common_dir" ] || return 1
    case "$common_dir" in
        /*|[A-Za-z]:[/\\]*) : ;;
        *) common_dir="$SCRIPT_DIR/$common_dir" ;;
    esac
    (cd "$(dirname "$common_dir")" 2>/dev/null && pwd)
}

if [ -n "${UPSTREAMWATCH_HIMMEL_ROOT:-}" ]; then
    HIMMEL_ROOT="$UPSTREAMWATCH_HIMMEL_ROOT"
elif HIMMEL_ROOT="$(resolve_himmel_root)" && [ -n "$HIMMEL_ROOT" ]; then
    :
else
    echo "WARN upstream-watch-cadence: could not resolve the primary checkout via git -- falling back to this script's own location. If this checkout is a worktree that gets pruned later, the armed cadence will break (HIMMEL-892 codex-adv-1)." >&2
    HIMMEL_ROOT="$(cd "$SCRIPT_DIR/.." 2>/dev/null && cd .. && pwd)"
fi
WATCH_SCRIPT="$HIMMEL_ROOT/scripts/upstreams/upstream-watch.sh"

# Runner-format version stamp (HIMMEL-588) — shared with the sibling cadences.
# shellcheck source=../lib/cadence-format.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/cadence-format.sh"
# shellcheck source=../lib/observability-registry.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/observability-registry.sh"

FIRE_TIME="06:00"
DRY_RUN=0
FORCE=0

usage() {
    cat <<'EOF'
Usage: upstream-watch-cadence.sh <arm|status|disarm> [flags]

Arm the OS scheduler with the daily upstream-watch cadence (HIMMEL-2367): ONE
daily task that runs `bash scripts/upstreams/upstream-watch.sh` directly --
never an interactive claude session, never --model. The script itself decides
whether anything changed (exit 0 = no delta, 10 = delta reported + telegram
sent, 2 = instrument failure); every one of those is a normal scheduler run,
so none of them is treated as a scheduler-level failure here.

Subcommands:
  arm      Register the daily task. Dedup-guarded: refuses (rc=3) if already
           armed; --force replaces.
  status   Show whether the task is armed (+ next run time + run-log
           evidence from its last fire).
  disarm   Remove the task and its runner (idempotent; rc=0 if nothing was
           armed).

Flags (arm only, except --dry-run):
  --time <HH:MM>  Daily fire time, 24h local (default 06:00 -- after
                  drift-fix-cadence's 05:00/05:30 legs, well before the
                  workday).
  --force         Replace an already-armed task.
  --dry-run       Print what would happen, touch nothing (honored by arm
                  AND disarm).

No --model flag: nothing here ever launches claude, so there is no model to
pin.
EOF
}

SUBCMD="${1:-}"
if [ -z "$SUBCMD" ]; then
    echo "ERR upstream-watch-cadence: subcommand required (arm|status|disarm)" >&2
    usage >&2
    exit 1
fi
shift
case "$SUBCMD" in
    arm|status|disarm) ;;
    -h|--help) usage; exit 0 ;;
    *)
        echo "ERR upstream-watch-cadence: unknown subcommand: $SUBCMD" >&2
        usage >&2
        exit 1
        ;;
esac

TIME_SET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --time)
            if [ $# -lt 2 ]; then
                echo "ERR upstream-watch-cadence: --time requires a value (HH:MM)" >&2
                usage >&2; exit 1
            fi
            FIRE_TIME="$2"; TIME_SET=1; shift 2 ;;
        --time=*) FIRE_TIME="${1#--time=}"; TIME_SET=1; shift ;;
        --force)   FORCE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "ERR upstream-watch-cadence: unknown arg: $1" >&2
            usage >&2; exit 1
            ;;
    esac
done

if [ "$TIME_SET" -eq 1 ] && [ "$SUBCMD" != "arm" ]; then
    echo "ERR upstream-watch-cadence: --time is arm-only" >&2; exit 1
fi

# Validate input BEFORE the platform gate so a bad value is rc 1 everywhere,
# not rc 2 on whichever platform happens to gate first.
if ! [[ "$FIRE_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "ERR upstream-watch-cadence: --time must be HH:MM (24h), got: $FIRE_TIME" >&2
    exit 1
fi

case "${UPSTREAMWATCH_PLATFORM:-${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}}" in
    windows|msys*|cygwin*|win32*|MINGW*) PLATFORM=windows ;;
    posix|linux*|darwin*|freebsd*|Linux|Darwin) PLATFORM=posix ;;
    *) PLATFORM=unknown ;;
esac
if [ "$PLATFORM" = "unknown" ]; then
    echo "ERR upstream-watch-cadence: unsupported platform '${OSTYPE:-unknown}'." >&2
    echo "    Supported: Windows (schtasks), Linux/macOS (crontab)" >&2
    exit 2
fi

# --------------------------------------------------------------------------
# Shared: payload presence + run-log reporting
# --------------------------------------------------------------------------

require_payload() {
    if [ ! -f "$WATCH_SCRIPT" ]; then
        echo "ERR upstream-watch-cadence: upstream-watch.sh not found at $WATCH_SCRIPT" >&2
        exit 2
    fi
}

status_log() {
    local log="$1" mtime last rc
    if [ -f "$log" ]; then
        mtime=$(date -r "$log" '+%Y-%m-%d %H:%M' 2>/dev/null \
            || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$log" 2>/dev/null || echo '?')
        echo "  run log    $log (last write: $mtime)"
        last=$(tail -n 1 "$log" 2>/dev/null | tr -d '\r' || true)
        [ -n "$last" ] && echo "             last line: $last"
        rc=$(grep -o '\[exit rc=[0-9]*\]' "$log" 2>/dev/null | tail -1 | grep -o '[0-9]*' || true)
        if [ -n "$rc" ] && [ "$rc" = "2" ]; then
            echo "  WARN: last fire exited rc=2 — instrument failure (gh auth / rate-limit / parse); see the log"
        fi
    elif [ -f "$log.prev" ]; then
        echo "  run log    $log (rotated — see .log.prev; no run since last rotation)"
    else
        echo "  run log    $log (absent — task has not fired yet)"
    fi
    if [ -f "$log.prev" ]; then
        mtime=$(date -r "$log.prev" '+%Y-%m-%d %H:%M' 2>/dev/null \
            || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$log.prev" 2>/dev/null || echo '?')
        echo "  prev log   $log.prev (last write: $mtime)"
    fi
}

# --------------------------------------------------------------------------
# Windows (schtasks)
# --------------------------------------------------------------------------

run_schtasks() { MSYS_NO_PATHCONV=1 "$SCHTASKS_BIN" "$@"; }

# emit_bat <himmel_win_esc> <payload> <log_esc> <git_bin_esc> — stamp the
# format version, rotate the log, stamp the fire time, cd into the primary
# checkout, run the payload with its rc captured and stamped, then exit /b
# with that SAME rc (0/2/10 from upstream-watch.sh are all "the task ran" —
# none of them is a scheduler-level failure, so nothing here treats 10
# specially). EVERY interpolated value arrives pre-cadence_cmd_escape'd.
emit_bat() {
    local himmel_win_esc="$1" payload="$2" log_esc="$3" git_bin_esc="${4:-}"
    printf '@echo off\r\n'
    printf 'rem upstream-watch-cadence runner (HIMMEL-2367)\r\n'
    printf 'rem %s %s\r\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    cadence_bat_editor_set
    # Prepend Git's usr\bin + bin (HIMMEL-1672): the payload is a bash script
    # that itself shells out to jq/gh/git/node, and a NON-LOGIN bash.exe (the
    # interpreter this runner bakes in) does not source the MSYS profile that
    # would otherwise put GNU coreutils ahead of System32.
    if [ -n "$git_bin_esc" ]; then
        printf 'set "PATH=%s;%%PATH%%"\r\n' "$git_bin_esc"
    fi
    printf 'if exist "%s" move /y "%s" "%s.prev" > NUL 2>&1\r\n' "$log_esc" "$log_esc" "$log_esc"
    printf 'echo [fired %%DATE%% %%TIME%%] >> "%s" 2>&1\r\n' "$log_esc"
    printf 'cd /d "%s" >> "%s" 2>&1 || exit /b 1\r\n' "$himmel_win_esc" "$log_esc"
    printf '%s >> "%s" 2>&1\r\n' "$payload" "$log_esc"
    printf 'set RC=%%ERRORLEVEL%%\r\n'
    printf 'echo [exit rc=%%RC%%] >> "%s"\r\n' "$log_esc"
    # rc=10 is upstream-watch.sh's own "delta found, handled" success code
    # (see its header) - map it to 0 so Task Scheduler's Last Run Result
    # reflects a normal run, not a failure, on every delta day.
    printf 'if %%RC%%==10 set RC=0\r\n'
    printf 'exit /b %%RC%%\r\n'
}

xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

emit_task_xml() {
    local bat_win="$1" start_time="$2" vbs_win vbs_args
    vbs_win=$(cadence_vbs_path "$bat_win")
    vbs_args=$(xml_escape "//B \"${vbs_win}\"")
    cat <<XML
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>himmel upstream-watch-cadence (HIMMEL-2367)</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>2020-01-01T${start_time}:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Settings>
    <StartWhenAvailable>true</StartWhenAvailable>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>wscript.exe</Command>
      <Arguments>${vbs_args}</Arguments>
    </Exec>
  </Actions>
</Task>
XML
}

schtasks_create_xml() {
    local name="$1" start_time="$2" bat_win="$3" err_file="$4"
    local xml_file xml_win rc
    if ! xml_file=$(mktemp -t upstream-watch-cadence.xml.XXXXXX 2>"$err_file"); then
        return 1
    fi
    emit_task_xml "$bat_win" "$start_time" > "$xml_file"
    if ! xml_win=$(cygpath -w "$xml_file" 2>"$err_file"); then
        rm -f "$xml_file"; return 1
    fi
    set +e
    run_schtasks /create /tn "$name" /xml "$xml_win" /f 2>"$err_file"
    rc=$?
    set -e
    rm -f "$xml_file"
    return "$rc"
}

NOT_FOUND_RE='The system cannot find the file specified|The specified task name .* does not exist'

QUERY_OUT=""
query_task() {
    local name="$1" rc err_file
    err_file=$(mktemp -t upstream-watch-cadence.err.XXXXXX)
    set +e
    QUERY_OUT=$(run_schtasks /query /tn "$name" /fo LIST 2>"$err_file")
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then rm -f "$err_file"; return 0; fi
    if [ "$rc" -eq 1 ] && grep -qiE "$NOT_FOUND_RE" "$err_file"; then
        rm -f "$err_file"; return 1
    fi
    echo "ERR upstream-watch-cadence: schtasks /query /tn $name failed (rc=$rc) — refusing to treat as 'not armed':" >&2
    cat "$err_file" >&2
    echo "    If this is a LOCALIZED 'task does not exist' message, the task may simply" >&2
    echo "    not be armed (only English stderr is trusted here). Verify / remove manually:" >&2
    echo "        schtasks /query /tn $name" >&2
    echo "        schtasks /delete /tn $name /f" >&2
    rm -f "$err_file"
    return 2
}

win_rollback() {
    run_schtasks /delete /tn "$TASK_NAME" /f >/dev/null 2>&1 || true
    local rc=0
    query_task "$TASK_NAME" 2>/dev/null || rc=$?
    if [ "$rc" -eq 1 ]; then
        rm -f "$BAT_DIR/upstream-watch.bat" "$BAT_DIR/upstream-watch.vbs"
    fi
}

win_arm() {
    command -v cygpath >/dev/null 2>&1 || {
        echo "ERR upstream-watch-cadence: cygpath not on PATH; cannot convert paths for schtasks" >&2
        exit 2
    }
    command -v "$SCHTASKS_BIN" >/dev/null 2>&1 || {
        echo "ERR upstream-watch-cadence: '$SCHTASKS_BIN' not on PATH (required on Windows)" >&2
        exit 2
    }
    cadence_require_wsh "upstream-watch-cadence" || exit 2
    require_payload

    local bash_posix bash_win
    if ! bash_posix=$(command -v bash 2>/dev/null); then
        echo "ERR upstream-watch-cadence: 'bash' not on PATH at arm time" >&2
        exit 2
    fi
    if ! bash_win=$(cygpath -w "$bash_posix" 2>&1); then
        echo "ERR upstream-watch-cadence: cygpath -w failed for bash path: $bash_win" >&2
        exit 4
    fi

    local dedup_rc=0
    query_task "$TASK_NAME" || dedup_rc=$?
    case "$dedup_rc" in
        0)
            if [ "$FORCE" -eq 1 ]; then
                echo "upstream-watch-cadence: --force set; existing task $TASK_NAME will be replaced by /create /f" >&2
            else
                {
                    echo "ERR upstream-watch-cadence: already armed: $TASK_NAME."
                    echo ""
                    echo "Dedup safeguard — re-run with --force to replace, or inspect with:"
                    echo "    bash scripts/upstreams/upstream-watch-cadence.sh status"
                } >&2
                exit 3
            fi
            ;;
        1) : ;;
        *) exit 2 ;;
    esac

    local himmel_win script_mixed
    if ! himmel_win=$(cygpath -w "$HIMMEL_ROOT" 2>&1); then
        echo "ERR upstream-watch-cadence: cygpath -w failed for himmel root: $himmel_win" >&2; exit 4
    fi
    if ! script_mixed=$(cygpath -m "$WATCH_SCRIPT" 2>&1); then
        echo "ERR upstream-watch-cadence: cygpath -m failed for upstream-watch.sh: $script_mixed" >&2; exit 4
    fi
    [ "$DRY_RUN" -eq 0 ] && mkdir -p "$BAT_DIR"

    local himmel_win_esc bash_win_esc script_esc git_bin_esc log_win log_esc payload
    himmel_win_esc=$(cadence_cmd_escape "$himmel_win")
    bash_win_esc=$(cadence_cmd_escape "$bash_win")
    script_esc=$(cadence_cmd_escape "$script_mixed")
    git_bin_esc=$(cadence_cmd_escape "$(cadence_git_bin_path_win "$bash_win")")
    payload="\"$bash_win_esc\" \"$script_esc\""

    local bat_file="$BAT_DIR/upstream-watch.bat" vbs_file="$BAT_DIR/upstream-watch.vbs" bat_win
    if ! bat_win=$(cygpath -w "$bat_file" 2>&1); then
        echo "ERR upstream-watch-cadence: cygpath -w failed for bat file: $bat_win" >&2; exit 4
    fi
    log_win="${bat_win%.bat}.log"
    log_esc=$(cadence_cmd_escape "$log_win")

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY upstream-watch-cadence: would write $bat_file:"
        emit_bat "$himmel_win_esc" "$payload" "$log_esc" "$git_bin_esc" | sed 's/^/    /'
        echo "DRY upstream-watch-cadence: would write $vbs_file:"
        cadence_vbs_wrapper "$bat_win" | sed 's/^/    /'
        echo "DRY upstream-watch-cadence: would schtasks /create /tn $TASK_NAME /xml <daily $FIRE_TIME, StartWhenAvailable=true> /f"
        emit_task_xml "$bat_win" "$FIRE_TIME" | sed 's/^/    /'
        echo "upstream-watch-cadence: dry-run complete (no changes made)"
        return 0
    fi

    # Atomic runner publication (mirrors drift-fix-cadence/qmd-cadence): stage
    # beside the final path, promote with `mv` only once both files are
    # complete, so a task firing concurrently with a re-arm never reads a
    # half-written .bat/.vbs.
    local bat_tmp vbs_tmp
    bat_tmp=$(mktemp "$BAT_DIR/.upstream-watch.bat.XXXXXX")
    vbs_tmp=$(mktemp "$BAT_DIR/.upstream-watch.vbs.XXXXXX")
    if ! emit_bat "$himmel_win_esc" "$payload" "$log_esc" "$git_bin_esc" > "$bat_tmp"; then
        echo "ERR upstream-watch-cadence: could not write staged runner" >&2
        rm -f "$bat_tmp" "$vbs_tmp"; exit 4
    fi
    if ! cadence_vbs_wrapper "$bat_win" > "$vbs_tmp"; then
        echo "ERR upstream-watch-cadence: could not write staged shim" >&2
        rm -f "$bat_tmp" "$vbs_tmp"; exit 4
    fi
    for final_to_check in "$bat_file" "$vbs_file"; do
        if [ -e "$final_to_check" ] && [ ! -f "$final_to_check" ]; then
            echo "ERR upstream-watch-cadence: $final_to_check exists and is not a regular file — refusing to publish" >&2
            rm -f "$bat_tmp" "$vbs_tmp"; exit 4
        fi
    done
    if ! mv -f "$vbs_tmp" "$vbs_file"; then
        echo "ERR upstream-watch-cadence: failed to publish shim to $vbs_file" >&2
        rm -f "$bat_tmp" "$vbs_tmp"; exit 4
    fi
    if ! mv -f "$bat_tmp" "$bat_file"; then
        echo "ERR upstream-watch-cadence: failed to publish runner to $bat_file" >&2
        rm -f "$bat_tmp"; exit 4
    fi

    local err_file
    err_file=$(mktemp -t upstream-watch-cadence.err.XXXXXX)
    if ! schtasks_create_xml "$TASK_NAME" "$FIRE_TIME" "$bat_win" "$err_file"; then
        echo "ERR upstream-watch-cadence: schtasks /create $TASK_NAME failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        win_rollback
        exit 4
    fi
    rm -f "$err_file"

    # Register immediately after /create succeeds (mirrors codex-sweep-cadence):
    # if the post-arm verify below proves the task dead and rolls it back, the
    # task intentionally stays "expected" so himmel-doctor's C24 check pages on
    # the vanished registration instead of staying silent about it.
    observability_register_cadence upstream-watch 86400 "$TASK_NAME"

    local verify_rc=0
    query_task "$TASK_NAME" || verify_rc=$?
    if [ "$verify_rc" -ne 0 ] || ! grep -qi 'Next Run Time' <<< "$QUERY_OUT"; then
        echo "ERR upstream-watch-cadence: post-arm verify failed for $TASK_NAME — rolling back." >&2
        win_rollback
        echo "    Re-arm with: bash scripts/upstreams/upstream-watch-cadence.sh arm --time $FIRE_TIME" >&2
        exit 4
    fi

    arm_summary "schtasks task" "$bat_file" "$log_win"
}

win_status() {
    command -v "$SCHTASKS_BIN" >/dev/null 2>&1 || {
        echo "ERR upstream-watch-cadence: '$SCHTASKS_BIN' not on PATH (required on Windows)" >&2
        exit 2
    }
    echo "upstream-watch-cadence status:"
    local rc=0 next status_rc=0
    query_task "$TASK_NAME" || rc=$?
    case "$rc" in
        0)
            next=$(printf '%s' "$QUERY_OUT" | grep -i 'Next Run Time' | head -1 | sed 's/^[^:]*: *//' | tr -d '\r') || true
            cadence_registered_status "$TASK_NAME" " (next run: ${next:-?})" || status_rc=2
            ;;
        1) echo "not armed  $TASK_NAME" ;;
        *) exit 2 ;;
    esac
    echo "  runner     $BAT_DIR/upstream-watch.bat"
    status_log "$BAT_DIR/upstream-watch.log"
    return "$status_rc"
}

win_disarm() {
    command -v "$SCHTASKS_BIN" >/dev/null 2>&1 || {
        echo "ERR upstream-watch-cadence: '$SCHTASKS_BIN' not on PATH (required on Windows)" >&2
        exit 2
    }
    local rc=0
    query_task "$TASK_NAME" || rc=$?
    case "$rc" in
        1)
            if [ "$DRY_RUN" -eq 0 ]; then
                rm -f "$BAT_DIR/upstream-watch.bat" "$BAT_DIR/upstream-watch.vbs"
                # No live task, but the registry may still expect one (e.g. it
                # was deleted outside this script, or arm registered then a
                # later step failed before this disarm ran) — unregister
                # unconditionally so disarm never leaves a stale expectation
                # behind (HIMMEL-2367 leak: caught live via a paging alert).
                observability_unregister_cadence upstream-watch "$TASK_NAME"
            fi
            echo "upstream-watch-cadence: nothing armed — disarm is a no-op"
            return 0
            ;;
        2) exit 2 ;;
    esac
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY upstream-watch-cadence: would schtasks /delete /tn $TASK_NAME /f"
        echo "DRY upstream-watch-cadence: would remove $BAT_DIR/upstream-watch.bat + .vbs"
        echo "DRY upstream-watch-cadence: no changes made"
        return 0
    fi
    local err_file
    err_file=$(mktemp -t upstream-watch-cadence.err.XXXXXX)
    if ! run_schtasks /delete /tn "$TASK_NAME" /f >/dev/null 2>"$err_file"; then
        echo "ERR upstream-watch-cadence: schtasks /delete $TASK_NAME failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        exit 4
    fi
    rm -f "$err_file" "$BAT_DIR/upstream-watch.bat" "$BAT_DIR/upstream-watch.vbs"
    observability_unregister_cadence upstream-watch "$TASK_NAME"
    echo "upstream-watch-cadence: cadence disarmed"
}

# --------------------------------------------------------------------------
# POSIX (crontab)
# --------------------------------------------------------------------------

cron_escape() {
    local s
    s=$(printf '%q' "$1")
    printf '%s' "${s//%/\\%}"
}

CRON_TAB=""
cron_read() {
    local err_file rc
    err_file=$(mktemp -t upstream-watch-cadence.err.XXXXXX)
    set +e
    CRON_TAB=$(LC_ALL=C "$CRONTAB_BIN" -l 2>"$err_file")
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 1 ] && { [ ! -s "$err_file" ] || grep -qi 'no crontab' "$err_file"; }; then
            CRON_TAB=""
        else
            echo "ERR upstream-watch-cadence: crontab -l failed (rc=$rc) — refusing to treat as an empty crontab:" >&2
            cat "$err_file" >&2
            echo "    Non-vixie crons (busybox, Solaris) phrase 'no crontab yet' differently;" >&2
            echo "    if that is what tripped this, install an empty crontab to unblock:" >&2
            echo "        crontab - </dev/null" >&2
            rm -f "$err_file"
            exit 2
        fi
    fi
    rm -f "$err_file"
}

cron_install() {
    local tab_file="$1" err_file
    err_file=$(mktemp -t upstream-watch-cadence.err.XXXXXX)
    if ! "$CRONTAB_BIN" - < "$tab_file" 2>"$err_file"; then
        echo "ERR upstream-watch-cadence: crontab install failed:" >&2
        cat "$err_file" >&2
        echo "    rejected crontab left at: $tab_file" >&2
        rm -f "$err_file"
        return 4
    fi
    rm -f "$err_file" "$tab_file"
}

cron_existing() { printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_NAME" || true; }

# emit_runner <q_himmel> <payload> <q_log> — mirrors emit_bat: rotate the
# log, stamp the fire, cd into the checkout, run the payload with its rc
# captured, then exit WITH that rc (not the trailing echo's).
# shellcheck disable=SC2016  # $log / $(date) are emitted literally for the runner's own /bin/sh
emit_runner() {
    local q_himmel="$1" payload="$2" q_log="$3"
    printf '#!/bin/sh\n'
    printf '# upstream-watch-cadence runner — generated by upstream-watch-cadence.sh arm (HIMMEL-2367)\n'
    printf '# %s %s\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    printf 'log=%s\n' "$q_log"
    printf 'if [ -f "$log" ]; then mv -f "$log" "$log.prev" 2>/dev/null; fi\n'
    printf '{\n'
    printf '    echo "[fired $(date "+%%Y-%%m-%%d %%H:%%M:%%S")]"\n'
    printf '    cd %s || exit 1\n' "$q_himmel"
    printf '    %s\n' "$payload"
    printf '    _rc=$?\n'
    printf '    echo "[exit rc=$_rc]"\n'
    printf '} >> "$log" 2>&1\n'
    # rc=10 is upstream-watch.sh's own "delta found, handled" success code
    # (see its header) - map it to 0 so cron's own exit-code visibility
    # reflects a normal run, not a failure, on every delta day.
    printf '[ "$_rc" -eq 10 ] && _rc=0\n'
    printf 'exit "$_rc"\n'
}

cron_status() {
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
        echo "ERR upstream-watch-cadence: '$CRONTAB_BIN' not on PATH (required on Linux/macOS)" >&2
        exit 2
    }
    cron_read
    echo "upstream-watch-cadence status:"
    local entry sched
    entry=$(cron_existing | head -1)
    if [ -n "$entry" ]; then
        sched=$(printf '%s' "$entry" | awk '{print $1, $2, $3, $4, $5}')
        echo "ARMED      $TASK_NAME (cron: $sched)"
    else
        echo "not armed  $TASK_NAME"
    fi
    echo "  runner     $BAT_DIR/upstream-watch.sh"
    status_log "$BAT_DIR/upstream-watch.log"
}

cron_disarm() {
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
        echo "ERR upstream-watch-cadence: '$CRONTAB_BIN' not on PATH (required on Linux/macOS)" >&2
        exit 2
    }
    cron_read
    local existing
    existing=$(cron_existing)
    if [ -z "$existing" ]; then
        if [ "$DRY_RUN" -eq 0 ]; then
            rm -f "$BAT_DIR/upstream-watch.sh"
            # No live entry, but the registry may still expect one (e.g. the
            # crontab line was removed outside this script) — unregister
            # unconditionally so disarm never leaves a stale expectation
            # behind (HIMMEL-2367 leak: caught live via a paging alert).
            observability_unregister_cadence upstream-watch "$TASK_NAME"
        fi
        echo "upstream-watch-cadence: nothing armed — disarm is a no-op"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' "$existing" | sed 's/^/DRY upstream-watch-cadence: would remove crontab entry: /'
        echo "DRY upstream-watch-cadence: no changes made"
        return 0
    fi
    local newtab
    newtab=$(mktemp -t upstream-watch-cadence.cron.XXXXXX)
    printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" > "$newtab" || true
    cron_install "$newtab" || exit 4
    rm -f "$BAT_DIR/upstream-watch.sh"
    observability_unregister_cadence upstream-watch "$TASK_NAME"
    echo "upstream-watch-cadence: cadence disarmed"
}

cron_arm() {
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
        echo "ERR upstream-watch-cadence: '$CRONTAB_BIN' not on PATH (required on Linux/macOS)" >&2
        exit 2
    }
    require_payload
    local bash_bin
    if ! bash_bin=$(command -v bash 2>/dev/null); then
        echo "ERR upstream-watch-cadence: 'bash' not on PATH at arm time" >&2
        exit 2
    fi

    cron_read
    local existing
    existing=$(cron_existing)
    if [ -n "$existing" ]; then
        if [ "$FORCE" -eq 1 ]; then
            echo "upstream-watch-cadence: --force set; replacing existing entry:" >&2
            printf '%s\n' "$existing" | sed 's/^/  /' >&2
        else
            {
                echo "ERR upstream-watch-cadence: already armed: $TASK_NAME."
                echo ""
                echo "Dedup safeguard — re-run with --force to replace, or inspect with:"
                echo "    bash scripts/upstreams/upstream-watch-cadence.sh status"
            } >&2
            exit 3
        fi
    fi

    local q_himmel q_bash q_script q_log payload
    q_himmel=$(printf '%q' "$HIMMEL_ROOT")
    q_bash=$(printf '%q' "$bash_bin")
    q_script=$(printf '%q' "$WATCH_SCRIPT")
    q_log=$(printf '%q' "$BAT_DIR/upstream-watch.log")
    payload="$q_bash $q_script"

    local runner="$BAT_DIR/upstream-watch.sh"
    local hh="${FIRE_TIME%:*}" mm="${FIRE_TIME#*:}"
    local entry_line
    entry_line="$mm $hh * * * $(cron_escape "$runner") # $TASK_NAME"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY upstream-watch-cadence: would write $runner:"
        emit_runner "$q_himmel" "$payload" "$q_log" | sed 's/^/    /'
        echo "DRY upstream-watch-cadence: would install crontab entry:"
        echo "    $entry_line"
        echo "upstream-watch-cadence: dry-run complete (no changes made)"
        return 0
    fi

    mkdir -p "$BAT_DIR"

    # Stage the runner and PROMOTE (checked mv) BEFORE touching the crontab
    # (mirrors drift-fix-cadence.sh's own cron_arm and win_arm's staged
    # bat/vbs publish above): publishing the artifact first means a failed
    # publish never reaches the scheduler at all, and a failed crontab
    # install afterward leaves a fully-published runner an operator can
    # inspect or retry against, rather than a live schedule pointing at a
    # runner that was never actually updated (HIMMEL-2367 codex-2 — the
    # opposite order used to install the crontab FIRST with an unchecked mv
    # after it, so a failed mv left the crontab live against a missing or
    # stale runner while still reporting success).
    local tmp_runner
    tmp_runner=$(mktemp "$BAT_DIR/.upstream-watch.sh.XXXXXX")
    emit_runner "$q_himmel" "$payload" "$q_log" > "$tmp_runner"
    chmod +x "$tmp_runner"
    if [ -e "$runner" ] && [ ! -f "$runner" ]; then
        echo "ERR upstream-watch-cadence: $runner exists and is not a regular file — refusing to publish" >&2
        rm -f "$tmp_runner"
        exit 4
    fi
    if ! mv -f "$tmp_runner" "$runner"; then
        echo "ERR upstream-watch-cadence: failed to publish runner to $runner" >&2
        rm -f "$tmp_runner"
        exit 4
    fi

    local newtab
    newtab=$(mktemp -t upstream-watch-cadence.cron.XXXXXX)
    {
        if [ -n "$CRON_TAB" ]; then
            printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" || true
        fi
        printf '%s\n' "$entry_line"
    } > "$newtab"
    if ! cron_install "$newtab"; then
        echo "    runner published to $runner but crontab install failed — cadence NOT armed; inspect/retry" >&2
        exit 4
    fi

    observability_register_cadence upstream-watch 86400 "$TASK_NAME"

    arm_summary "crontab entry" "$runner" "$BAT_DIR/upstream-watch.log"
}

# --------------------------------------------------------------------------

arm_summary() {
    local kind="$1" runner="$2" log="$3"
    cat <<EOF
================================================================
upstream-watch-cadence ARMED (HIMMEL-2367)

  $TASK_NAME   daily $FIRE_TIME local — $kind — runner: $runner
  Repo:   $HIMMEL_ROOT
  Log:    $log
          (one prior run kept as .log.prev)

  Each day: bash scripts/upstreams/upstream-watch.sh runs directly (no
  claude session). It builds the open-PR/issue inventory, diffs it against
  the previous run, and only when something changed writes a dated report
  under the handover root and sends one Telegram line — a no-delta run costs
  zero tokens.

  Registered with the observability registry (himmel-doctor's C24 check will
  report this task as expected).

  Status / disarm anytime:
      bash scripts/upstreams/upstream-watch-cadence.sh status
      bash scripts/upstreams/upstream-watch-cadence.sh disarm
================================================================
EOF
}

case "$PLATFORM:$SUBCMD" in
    windows:arm)    win_arm ;;
    windows:status) win_status ;;
    windows:disarm) win_disarm ;;
    posix:arm)      cron_arm ;;
    posix:status)   cron_status ;;
    posix:disarm)   cron_disarm ;;
esac
