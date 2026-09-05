#!/usr/bin/env bash
# codex-sweep-cadence.sh — arm/status/disarm the recurring codex broker-orphan
# sweep cadence (HIMMEL-892).
#
# WHY: the codex broker's own teardown paths (broker/shutdown RPC + the
# SessionEnd session-lifecycle-hook.mjs) structurally miss a class of orphan:
# a UI client that closed without a clean handshake, a hard process kill, or
# a broker whose cwd drifted from a deleted worktree. The broker itself has
# no idle-TTL, so those orphans accumulate silently. scripts/cleanup/
# sweep-codex-orphans.ps1 (name-verified stop) and scripts/codex/
# reap-mcp-fleet.ps1 (dead-registry MCP fleet reap) already exist and are
# live-validated manually; what's missing is the scheduler/arm layer. This
# is that layer: ONE task that fires all THREE payloads with -Kill.
#
# THIRD LEG + INTRA-DAY REPEAT (HIMMEL-1309): both original payloads skip
# anything under a LIVE app-server, so duplicate MCP fleets accumulating INSIDE
# one live broker were swept by neither — 45 luna-correlate pairs under a single
# app-server on 2026-07-27. scripts/codex/reap-superseded-fleets.ps1 is that
# third check and fires last (it is the narrowest; the two orphan sweeps ahead
# of it have already removed everything whose supervisor is gone). Same run also
# added <Repetition>: ~9 GB accumulated in well under a day against a daily-only
# fire, so the trigger now repeats every --repeat-hours (default 4) across the
# day. Repeats inherit the InteractiveToken principal, so they still only fire
# while the operator is logged on.
#
# ONE task, daily, default 09:00 local. WHY 09:00 (not off-peak/overnight):
# the task Principal is InteractiveToken (see below) — it fires only while
# the operator is logged on, and 09:00 is reliably inside the logged-on
# window; a missed fire catches up at next logon via StartWhenAvailable. A
# cleanup window "while the machine sleeps" is impossible for this payload
# class (no interactive token -> the sweep can't see client command lines,
# see below), so daytime + liveness-test safety is the correct design here,
# not a compromise.
#
# PRINCIPAL DELTA from the sibling scripts/luna/graphmap-cadence.sh: this
# task's XML carries <LogonType>InteractiveToken</LogonType> +
# <RunLevel>LeastPrivilege</RunLevel> for the arming user (Actions
# Context="Author"), instead of graphmap's default (SYSTEM-ish/no explicit
# Principal) shape. Reason: sweep-codex-orphans.ps1 REFUSES to -Kill (exit 1)
# when a candidate process's CommandLine is invisible — which is exactly what
# happens under an elevated or session-detached scheduled-task run (e.g. the
# default "run whether user is logged on or not" SYSTEM-ish context). Firing
# as InteractiveToken, same user, least privilege, in the interactive
# session keeps client command lines visible so the sweep can actually do
# its job instead of silently no-op'ing every day.
#
# Usage:
#   bash scripts/cleanup/codex-sweep-cadence.sh arm [--time HH:MM] [--force] [--dry-run]
#   bash scripts/cleanup/codex-sweep-cadence.sh status
#   bash scripts/cleanup/codex-sweep-cadence.sh disarm
#
# Test seams (used by test-codex-sweep-cadence.sh):
#   SWEEP_SCHTASKS    — command invoked instead of `schtasks`
#   SWEEP_BAT_DIR     — where the persistent runner (.bat) lives
#   SWEEP_PWSH        — payload shell override (else: command -v pwsh || powershell)
#   SWEEP_HIMMEL_ROOT — overrides the resolved HIMMEL_ROOT outright (test-only;
#                       used ONLY to exercise the missing-payload rc=2 path via
#                       a root without the payload scripts — the git-common-dir
#                       derivation itself is covered directly, not via this seam)
#
# Exit codes:
#   0  done (armed / dry-run complete)
#   1  usage / input error (incl. malformed --time — checked BEFORE the
#      platform gate so it is rc 1 on every platform, not rc 2 on POSIX)
#   2  env unusable (non-Windows platform; no schtasks/cygpath/payload-shell
#      on PATH; payload script missing)
#   3  dedup block — HIMMEL-CodexOrphanSweep already armed; --force replaces
#   4  scheduler invocation failed (/create, /delete, path conversion) OR
#      the post-arm verify query failed / reported no live next-run time
#      (rolled back: the just-armed task is deleted before exiting 4). That
#      self-deletion also writes a `codex-sweep-cadence` / outcome=self-deleted
#      row to the flow-run ledger (HIMMEL-1879) — absence of a scheduled task
#      is otherwise indistinguishable from "not due yet".
#
# Known limitations:
#   - query_task's locale-independent existence probe (codex-7) needs a
#     resolvable pwsh/PowerShell; if none is on PATH, or the probe itself
#     errors/returns CommandNotFoundException, a localized "task not found"
#     schtasks stderr still classifies as a hard query error (rc 2,
#     fail-closed) rather than "not armed" — English-stderr matching
#     (NOT_FOUND_RE) remains the only trusted not-found signal in that case.
#   - `--force` replacement does NOT preserve/restore the previous task
#     definition on a post-replacement verify rollback — the task's only
#     state is its --time, regenerable with one command (the rollback
#     message prints it); full export/restore machinery was considered and
#     rejected (simplicity-first).
set -euo pipefail

TASK_NAME="HIMMEL-CodexOrphanSweep"
SCHTASKS_BIN="${SWEEP_SCHTASKS:-schtasks}"

# Cross-platform user-home resolution (mirrors graphmap-cadence's
# resolve_user_home, HIMMEL-645): prefer USERPROFILE via cygpath on Windows
# Git-Bash (MSYS $HOME can differ from where ~/.claude actually lives).
resolve_user_home() {
    if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$USERPROFILE" 2>/dev/null || printf '%s' "$USERPROFILE"
    else
        printf '%s' "${HOME:-${USERPROFILE:-/tmp}}"
    fi
}

# Persistent runner home — NOT mktemp/%TEMP%: this task recurs daily and
# %TEMP% is subject to cleanup sweeps that would silently kill the cadence.
BAT_DIR="${SWEEP_BAT_DIR:-$(resolve_user_home)/.claude/codex-sweep-cadence}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the himmel root to the PRIMARY checkout, not this script's own
# location (codex-adv-1, HIMMEL-892): arming from a feature worktree would
# otherwise embed absolute payload paths under THAT worktree in the
# persistent .bat runner; post-merge worktree pruning then deletes those
# paths and every scheduled fire fails thereafter — the cadence whose job is
# cleaning up after deleted worktrees would die to a deleted worktree.
# `--git-common-dir` always resolves to the PRIMARY .git even from a linked
# worktree (same derivation as clean-garden.sh's PRIMARY_WORKTREE / ship-
# branch.sh's git_dir), so its parent dir IS the primary checkout root —
# resolved relative to THIS script's own dir (`-C "$SCRIPT_DIR"`) so it is
# independent of the caller's cwd. Falls back to the old script-relative
# derivation (WARN) when git is unavailable or the rev-parse fails (e.g. a
# non-repo install). Payload scripts are consumed AS-IS — never modified by
# this cadence.
#
# Test seam: SWEEP_HIMMEL_ROOT overrides HIMMEL_ROOT outright — test-only,
# used ONLY to exercise the missing-payload rc=2 path via a root without the
# payload scripts; the git-common-dir derivation itself is covered directly
# by test-codex-sweep-cadence.sh.
resolve_himmel_root() {
    local common_dir
    command -v git >/dev/null 2>&1 || return 1
    common_dir="$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common_dir" ] || return 1
    case "$common_dir" in
        /*|[A-Za-z]:[/\\]*) : ;;                 # already absolute (POSIX or Windows drive)
        *) common_dir="$SCRIPT_DIR/$common_dir" ;;
    esac
    (cd "$(dirname "$common_dir")" 2>/dev/null && pwd)
}

if [ -n "${SWEEP_HIMMEL_ROOT:-}" ]; then
    HIMMEL_ROOT="$SWEEP_HIMMEL_ROOT"
elif HIMMEL_ROOT="$(resolve_himmel_root)" && [ -n "$HIMMEL_ROOT" ]; then
    :
else
    echo "WARN codex-sweep-cadence: could not resolve the primary checkout via git (git unavailable, not inside a repo, or rev-parse failed) -- falling back to this script's own location. If this checkout is a worktree that gets pruned later, the armed cadence's payload paths will break (HIMMEL-892 codex-adv-1)." >&2
    HIMMEL_ROOT="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)"
fi
SWEEP_SCRIPT="$HIMMEL_ROOT/scripts/cleanup/sweep-codex-orphans.ps1"
REAP_SCRIPT="$HIMMEL_ROOT/scripts/codex/reap-mcp-fleet.ps1"
SUPERSEDE_SCRIPT="$HIMMEL_ROOT/scripts/codex/reap-superseded-fleets.ps1"

# Runner-format version stamp (HIMMEL-588): shared with the other cadences so
# a stale-format armed runner is detectable via the same marker convention.
# shellcheck source=../lib/cadence-format.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/cadence-format.sh"
# shellcheck source=../lib/observability-registry.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/observability-registry.sh"

SWEEP_TIME="09:00"
REPEAT_HOURS=4
DRY_RUN=0
FORCE=0

usage() {
    cat <<'EOF'
Usage: codex-sweep-cadence.sh <arm|status|disarm> [flags]

Arm the OS scheduler with the recurring codex broker-orphan sweep cadence
(HIMMEL-892): ONE task that fires sweep-codex-orphans.ps1 -Kill, then
reap-mcp-fleet.ps1 -Kill, then reap-superseded-fleets.ps1 -Kill, as the arming
user (InteractiveToken / LeastPrivilege) so client command lines stay visible
to the sweep. Fires at --time and then every --repeat-hours across the day.

Subcommands:
  arm      Register the daily task. Dedup-guarded: refuses (rc=3) if
           HIMMEL-CodexOrphanSweep is already armed; --force replaces.
  status   Show whether the cadence task is armed (+ next run time +
           runner-log evidence).
  disarm   Remove the task (idempotent; rc=0 if nothing was armed).

Flags (arm only, except --dry-run):
  --time <HH:MM>  Daily fire time, 24h local (default 09:00 — reliably
                  inside the logged-on window InteractiveToken needs).
                  arm-only — rejected (rc=1) on status/disarm.
  --repeat-hours <n>
                  Re-fire every n hours after --time, all day (default 4;
                  0 = fire once daily, the pre-HIMMEL-1309 behaviour).
                  arm-only — rejected (rc=1) on status/disarm.
  --force         Replace an already-armed HIMMEL-CodexOrphanSweep task
  --dry-run       Print what would happen, touch nothing (honored by
                  arm AND disarm)
EOF
}

SUBCMD="${1:-}"
if [ -z "$SUBCMD" ]; then
    echo "ERR codex-sweep-cadence: subcommand required (arm|status|disarm)" >&2
    usage >&2
    exit 1
fi
shift
case "$SUBCMD" in
    arm|status|disarm) ;;
    -h|--help) usage; exit 0 ;;
    *)
        echo "ERR codex-sweep-cadence: unknown subcommand: $SUBCMD" >&2
        usage >&2
        exit 1
        ;;
esac

TIME_SET=0
REPEAT_SET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --time)
            # Guard the value slot (coderabbit-1, HIMMEL-892): `arm --time`
            # with nothing after it has $#=1 here, so a bare `shift 2` dies
            # on a raw bash "shift count out of range" error under set -e.
            # Report it as a normal usage error instead.
            if [ $# -lt 2 ]; then
                echo "ERR codex-sweep-cadence: --time requires a value (HH:MM)" >&2
                usage >&2
                exit 1
            fi
            SWEEP_TIME="$2"; TIME_SET=1; shift 2 ;;
        --time=*)   SWEEP_TIME="${1#--time=}"; TIME_SET=1; shift ;;
        --repeat-hours)
            # Same value-slot guard as --time above: a bare `shift 2` with
            # nothing after the flag dies on "shift count out of range".
            if [ $# -lt 2 ]; then
                echo "ERR codex-sweep-cadence: --repeat-hours requires a value (0-23)" >&2
                usage >&2
                exit 1
            fi
            REPEAT_HOURS="$2"; REPEAT_SET=1; shift 2 ;;
        --repeat-hours=*) REPEAT_HOURS="${1#--repeat-hours=}"; REPEAT_SET=1; shift ;;
        --force)    FORCE=1; shift ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)
            echo "ERR codex-sweep-cadence: unknown arg: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# --time is arm-only (Task 1 review note): usage scoped it to arm, but the
# flag was validated for every subcommand. Reject it on status/disarm before
# the format check so the error names the real reason, not a format gripe.
if [ "$TIME_SET" -eq 1 ] && [ "$SUBCMD" != "arm" ]; then
    echo "ERR codex-sweep-cadence: --time is arm-only" >&2
    exit 1
fi
if [ "$REPEAT_SET" -eq 1 ] && [ "$SUBCMD" != "arm" ]; then
    echo "ERR codex-sweep-cadence: --repeat-hours is arm-only" >&2
    exit 1
fi

# Validated alongside --time, BEFORE the platform gate, for the same reason:
# an input error must be rc 1 on every platform, not rc 2 on POSIX. Capped at
# 23 — an interval of 24h or more never re-fires inside the P1D duration, so
# it would silently mean "daily", which is what 0 already says explicitly.
if ! [[ "$REPEAT_HOURS" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then
    echo "ERR codex-sweep-cadence: --repeat-hours must be an integer 0-23 (0 = daily only), got: $REPEAT_HOURS" >&2
    exit 1
fi

# --time validation happens BEFORE the platform gate (ordering delta from
# graphmap-cadence, which validates inside the arm dispatch): input errors
# must be rc 1 on every platform, not rc 2 on POSIX.
if ! [[ "$SWEEP_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "ERR codex-sweep-cadence: --time must be HH:MM (24h), got: $SWEEP_TIME" >&2
    exit 1
fi

# Platform gate: Windows-only. The codex broker-tree leak class (named
# pipes, Win32 process walks) and both payload scripts are Windows
# constructs — there is no POSIX equivalent to arm.
case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    msys*|cygwin*|win32*|MINGW*) PLATFORM=windows ;;
    *)                           PLATFORM=other ;;
esac
if [ "$PLATFORM" != "windows" ]; then
    echo "ERR codex-sweep-cadence: Windows-only — the codex broker-tree leak class (named pipes, Win32 process walks) and both payload scripts are Windows constructs." >&2
    exit 2
fi
command -v "$SCHTASKS_BIN" >/dev/null 2>&1 || {
    echo "ERR codex-sweep-cadence: '$SCHTASKS_BIN' not on PATH (required on Windows)" >&2
    exit 2
}

# MSYS_NO_PATHCONV=1 per call: without it gitbash mangles /query, /create etc.
# into Windows-rooted paths before schtasks sees them.
run_schtasks() { MSYS_NO_PATHCONV=1 "$SCHTASKS_BIN" "$@"; }

# Emit the runner .bat body: stamp the format version, rotate the log
# (move /y to .prev on each fire), stamp the fire time, then run all three
# payloads with each rc captured to the log. Any non-zero leg is remembered and
# returned AFTER the later legs run, so Task Scheduler cannot report success
# merely because the final payload succeeded (HIMMEL-1706).
emit_bat() {
    local bat_dir_esc="$1" pwsh_esc="$2" sweep_esc="$3" reap_esc="$4" supersede_esc="$5"
    printf '@echo off\r\n'
    printf 'rem codex-sweep-cadence runner (HIMMEL-892)\r\n'
    printf 'rem %s %s\r\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    # Pin editor hooks to the no-op `true` so a cadence child (stdin closed under
    # schtasks) can never block on an editor prompt (HIMMEL-1753).
    cadence_bat_editor_set
    # Quoted `set "LOG=..."`, not bare `set LOG=...` (HIMMEL-1281). This was
    # the ONE emitter line interpolating an escaped value OUTSIDE quotes —
    # where & < > | really are live metacharacters and the old caret escapes
    # were load-bearing. cadence_cmd_escape's contract is quoted-context only,
    # so the line moves into quotes rather than the escape growing a second
    # mode. Bonus: the quoted form also stops a trailing space in the bat dir
    # from landing in %LOG%.
    printf 'set "LOG=%s\\codex-sweep.log"\r\n' "$bat_dir_esc"
    printf 'set "PAYLOAD_FAILED=0"\r\n'
    printf 'if exist "%%LOG%%" move /y "%%LOG%%" "%%LOG%%.prev" >nul\r\n'
    printf 'echo [fired %%date%% %%time%%] > "%%LOG%%"\r\n'
    # `call` on every payload leg (HIMMEL-1389, mirroring #1454's fix in
    # drift-fix-cadence.sh): if the resolved pwsh/powershell path is ever a
    # .cmd/.bat shim, a bare invocation makes cmd.exe transfer control into it
    # and never return — the rc capture, the two later legs and the
    # PAYLOAD_FAILED exit would all silently never run, and Task Scheduler
    # would see the shim's rc instead of the sweep's.
    printf 'call "%s" -NoProfile -ExecutionPolicy Bypass -File "%s" -Kill >> "%%LOG%%" 2>&1\r\n' "$pwsh_esc" "$sweep_esc"
    printf 'set "PAYLOAD_RC=%%ERRORLEVEL%%"\r\n'
    printf 'echo [sweep exit rc=%%PAYLOAD_RC%%] >> "%%LOG%%"\r\n'
    printf 'if not "%%PAYLOAD_RC%%"=="0" set "PAYLOAD_FAILED=1"\r\n'
    printf 'call "%s" -NoProfile -ExecutionPolicy Bypass -File "%s" -Kill >> "%%LOG%%" 2>&1\r\n' "$pwsh_esc" "$reap_esc"
    printf 'set "PAYLOAD_RC=%%ERRORLEVEL%%"\r\n'
    printf 'echo [reap exit rc=%%PAYLOAD_RC%%] >> "%%LOG%%"\r\n'
    printf 'if not "%%PAYLOAD_RC%%"=="0" set "PAYLOAD_FAILED=1"\r\n'
    printf 'call "%s" -NoProfile -ExecutionPolicy Bypass -File "%s" -Kill >> "%%LOG%%" 2>&1\r\n' "$pwsh_esc" "$supersede_esc"
    printf 'set "PAYLOAD_RC=%%ERRORLEVEL%%"\r\n'
    printf 'echo [supersede exit rc=%%PAYLOAD_RC%%] >> "%%LOG%%"\r\n'
    printf 'if not "%%PAYLOAD_RC%%"=="0" set "PAYLOAD_FAILED=1"\r\n'
    printf 'exit /b %%PAYLOAD_FAILED%%\r\n'
}

# --- schtasks task XML (StartWhenAvailable + InteractiveToken Principal) ---
#
# schtasks /create has no flag for StartWhenAvailable, so a daily 09:00 run
# is SILENTLY SKIPPED if the machine was off/asleep at 09:00. The only CLI
# route is `schtasks /create /xml` (same approach as graphmap-cadence,
# HIMMEL-362). This XML additionally carries the InteractiveToken/
# LeastPrivilege Principal delta (see header WHY).

# Escape the three XML-significant characters for element-body text.
xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

schedule_daily_xml() {
    printf '      <ScheduleByDay>\n        <DaysInterval>1</DaysInterval>\n      </ScheduleByDay>'
}

# Intra-day repetition fragment (HIMMEL-1309). Emits nothing when --repeat-hours
# is 0 (daily-only, the pre-1309 behaviour). Duration P1D with Interval PTnH
# re-fires the trigger every n hours until the next day's StartBoundary takes
# over; StopAtDurationEnd=false so an in-flight sweep is never cut short.
# Emitted as the FIRST child of <CalendarTrigger>, before <StartBoundary>
# (glm-1 CR finding, HIMMEL-1309). Verified rather than assumed: round-tripping
# both orderings through TaskDefinition.XmlText — the same COM layer
# `schtasks /create /xml` parses with — shows it canonicalizes every trigger to
# `Repetition > StartBoundary > Enabled > ScheduleByDay`, so Repetition-first IS
# the canonical order. Both orderings were accepted here with PT4H intact (the
# "silently dropped interval" half of the finding did NOT reproduce), but
# emitting what the scheduler itself emits costs nothing and removes the risk on
# a stricter parser build, where a dropped <Repetition> would quietly downgrade
# this cadence back to daily — the exact failure that would be invisible.
#
# Emits a LEADING newline (not a trailing one) because `$(...)` strips trailing
# newlines: the caller interpolates it directly after the <CalendarTrigger> tag,
# so the fragment has to carry its own line break in front, and an empty fragment
# then leaves the surrounding lines exactly as they were.
repetition_xml() {
    local hours="$1"
    [ "$hours" -gt 0 ] || return 0
    printf '\n      <Repetition>\n        <Interval>PT%sH</Interval>\n        <Duration>P1D</Duration>\n        <StopAtDurationEnd>false</StopAtDurationEnd>\n      </Repetition>' "$hours"
}

# Emit the task XML: a CalendarTrigger at the given local time, daily
# schedule, StartWhenAvailable=true, an InteractiveToken/LeastPrivilege
# Principal, and the .bat runner as the Exec Command. Declared UTF-16 (what
# schtasks /create /xml expects) but the bytes are plain ASCII (cmd.exe's
# OEM codepage mojibakes non-ASCII — same rule as graphmap-cadence).
emit_task_xml() {
    local bat_win="$1" start_time="$2" schedule_xml="$3" repeat_hours="${4:-0}"
    local repetition vbs_win vbs_args
    # HIMMEL-1753: Exec is a `wscript //B <shim>.vbs` wrapper around the .bat.
    # The earlier hidden-powershell wrapper (-WindowStyle Hidden) was MEASURED to
    # still allocate visible consoles; wscript //B hosting the .vbs shim (which
    # runs the .bat hidden via WScript.Shell.Run and forwards its exit code via
    # WScript.Quit) allocates zero consoles. (codex-sweep previously threaded the
    # resolved pwsh path in here as <Command> — that is gone now; the resolved
    # pwsh still drives the .bat's three payload legs via emit_bat's $pwsh_esc.)
    # The shim path is derived from the .bat path through cadence_vbs_path — the
    # SAME helper cmd_arm writes the file with — so referenced path and written
    # file can never disagree. //B is the WSH batch-mode flag (no error/prompt
    # UI); the path is quoted for spaces, then xml_escaped like any element text.
    # WScript.Quit in the shim preserves HIMMEL-1706 exit-code fidelity (rc=42
    # re-arm survives — proven in test-cadence-format.sh).
    repetition=$(repetition_xml "$repeat_hours")
    vbs_win=$(cadence_vbs_path "$bat_win")
    vbs_args=$(xml_escape "//B \"${vbs_win}\"")
    cat <<XML
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>himmel codex-sweep-cadence (HIMMEL-892)</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>${repetition}
      <StartBoundary>2020-01-01T${start_time}:00</StartBoundary>
      <Enabled>true</Enabled>
${schedule_xml}
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
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

# Create the task from an XML definition (so StartWhenAvailable + the
# Principal delta apply). Mirrors graphmap-cadence's schtasks_create_xml.
schtasks_create_xml() {
    local name="$1" schedule_xml="$2" start_time="$3" bat_win="$4" err_file="$5" repeat_hours="${6:-0}"
    local xml_file xml_win rc
    if ! xml_file=$(mktemp -t codex-sweep-cadence.xml.XXXXXX 2>"$err_file"); then
        return 1
    fi
    emit_task_xml "$bat_win" "$start_time" "$schedule_xml" "$repeat_hours" > "$xml_file"
    if ! xml_win=$(cygpath -w "$xml_file" 2>"$err_file"); then
        rm -f "$xml_file"
        return 1
    fi
    set +e
    run_schtasks /create /tn "$name" /xml "$xml_win" /f 2>"$err_file"
    rc=$?
    set -e
    rm -f "$xml_file"
    return "$rc"
}

# Resolve the payload/probe shell: SWEEP_PWSH override, else pwsh, else
# Windows PowerShell. Echoes the resolved path and returns 0, or returns 1
# with nothing echoed if none is resolvable. Factored out (codex-7,
# HIMMEL-892) so query_task's locale-independent existence probe below can
# share the exact same resolution cmd_arm already used for the post-arm
# verify probe, instead of only cmd_arm being able to find pwsh. Callers
# decide whether a missing shell is fatal (cmd_arm: yes, exit 2) or a soft
# probe-unavailable fallback (query_task: no — keep the existing fail-closed
# rc 2 behavior).
resolve_pwsh() {
    if [ -n "${SWEEP_PWSH:-}" ]; then
        printf '%s' "$SWEEP_PWSH"
        return 0
    fi
    local p pwsh_cand
    for pwsh_cand in pwsh pwsh.exe; do
        if p=$(command -v "$pwsh_cand" 2>/dev/null); then
            printf '%s' "$p"
            return 0
        fi
    done
    if p=$(command -v powershell 2>/dev/null); then
        # HIMMEL-2126: pwsh is unavailable — loud, named 5.1 fallback, never silent.
        echo "WARN resolve_pwsh: pwsh (PowerShell 7) not found; falling back to Windows PowerShell 5.1 (powershell) -- HIMMEL-2126: PS 5.1 misreads BOM-less UTF-8 as cp1252 (em-dash mojibake -> phantom-token ParserError at the WRONG line), has reserved-variable quirks, and strips jq-style quoting differently than pwsh." >&2
        printf '%s' "$p"
        return 0
    fi
    return 1
}

# Known not-found stderr signatures for `/query /tn <name>` (ported verbatim
# from graphmap-cadence). Real schtasks always emits one of these on a missing
# task, so rc=1 WITHOUT a match (silent rc=1 included) is a real query failure.
NOT_FOUND_RE='The system cannot find the file specified|The specified task name .* does not exist'

# query_task <name>: rc 0 = armed (QUERY_OUT set), rc 1 = trusted not-found,
# rc 2 = query failed (stderr already printed). Ported verbatim-with-renames
# from graphmap-cadence's query_one — codex-sweep has a single fixed
# TASK_NAME (no prefix-listing needed), so this single-name query IS the
# dedup/status/disarm classifier.
#
# Locale-independent fallback (codex-7, HIMMEL-892): NOT_FOUND_RE only
# matches ENGLISH schtasks stderr. On a localized Windows the not-found
# message never matches, so every missing-task query would otherwise
# classify as a hard query error (fail-closed rc 2) — arm/status/disarm
# become unusable on non-English locales. Before giving up, probe existence
# via Get-ScheduledTask (its exceptions carry a structured, locale-
# independent .CategoryInfo.Category, not localized text) through the same
# resolved pwsh cmd_arm uses for its own post-arm verify.
QUERY_OUT=""
query_task() {
    local name="$1" rc err_file
    err_file=$(mktemp -t codex-sweep-cadence.err.XXXXXX)
    set +e
    QUERY_OUT=$(run_schtasks /query /tn "$name" /fo LIST 2>"$err_file")
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        rm -f "$err_file"
        return 0
    fi
    if [ "$rc" -eq 1 ] && grep -qiE "$NOT_FOUND_RE" "$err_file"; then
        rm -f "$err_file"
        return 1
    fi

    local pwsh_probe
    if pwsh_probe=$(resolve_pwsh); then
        local probe_err probe_out probe_rc
        probe_err=$(mktemp -t codex-sweep-cadence.probe-err.XXXXXX)
        probe_rc=0
        # errexit-safe capture (same idiom as cmd_arm's post-arm verify,
        # HIMMEL-938): `|| probe_rc=$?`, not a bare trailing assignment.
        probe_out=$("$pwsh_probe" -NoProfile -NonInteractive -Command "
            try {
                Get-ScheduledTask -TaskPath '\' -TaskName '$name' -ErrorAction Stop | Out-Null
                'EXISTS'
            } catch {
                if (\$_.Exception -is [System.Management.Automation.CommandNotFoundException]) { Write-Error \$_; exit 1 }
                elseif (\$_.CategoryInfo.Category -eq 'ObjectNotFound') { 'ABSENT' }
                else { Write-Error \$_; exit 1 }
            }
        " 2>"$probe_err") || probe_rc=$?
        probe_out=$(printf '%s' "$probe_out" | tr -d '\r\n ')
        if [ "$probe_rc" -eq 0 ] && [ "$probe_out" = "EXISTS" ]; then
            rm -f "$probe_err"
            echo "ERR codex-sweep-cadence: schtasks /query /tn $name failed (rc=$rc) with non-English/unrecognized stderr, but the locale-independent Get-ScheduledTask probe confirms the task EXISTS -- the schtasks failure was transient/other, staying fail-closed (see stderr below):" >&2
            cat "$err_file" >&2
            rm -f "$err_file"
            return 2
        fi
        if [ "$probe_rc" -eq 0 ] && [ "$probe_out" = "ABSENT" ]; then
            rm -f "$err_file" "$probe_err"
            return 1
        fi
        # CommandNotFoundException (ScheduledTasks module absent) or any
        # other probe failure -- probe unavailable/inconclusive, fall
        # through to the existing fail-closed rc 2 below, unchanged.
        rm -f "$probe_err"
    fi

    echo "ERR codex-sweep-cadence: schtasks /query /tn $name failed (rc=$rc) — refusing to treat as 'not armed':" >&2
    cat "$err_file" >&2
    echo "    If this is a localized 'task does not exist' message, the task may simply" >&2
    echo "    not be armed. Verify / remove manually:" >&2
    echo "        schtasks /query /tn $name" >&2
    echo "        schtasks /delete /tn $name /f" >&2
    rm -f "$err_file"
    return 2
}

delete_task() {
    local name="$1" err_file
    err_file=$(mktemp -t codex-sweep-cadence.err.XXXXXX)
    if run_schtasks /delete /tn "$name" /f >/dev/null 2>"$err_file"; then
        rm -f "$err_file"
        echo "codex-sweep-cadence: deleted scheduled task: $name"
    else
        echo "ERR codex-sweep-cadence: schtasks /delete $name failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        exit 4
    fi
}

# Surface fire-time evidence: the runner writes its output to a .log next to
# the .bat (rotated to .log.prev on each fire), so "armed but never
# succeeding" is visible here. Ported from graphmap-cadence's status_log,
# INCLUDING its .prev branch, WITH ONE DELIBERATE DELTA: graphmap's version
# reads only the log's last line (tail -1) — fine there, since its runner's
# last line IS the meaningful stamp. Here the runner ALWAYS ends with the
# reap stamp (see emit_bat), so a tail-1 port would make a sweep failure
# invisible (including the sweep's visibility-refusal rc 1 — exactly the
# failure class HIMMEL-892 exists to catch). So this scans the WHOLE log for
# both `[sweep exit rc=` and `[reap exit rc=` stamps and WARNs if either is
# non-zero.
status_log() {
    local log="$1" mtime last sweep_rc reap_rc supersede_rc
    if [ -f "$log" ]; then
        mtime=$(date -r "$log" '+%Y-%m-%d %H:%M' 2>/dev/null \
            || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$log" 2>/dev/null \
            || echo '?')
        last=$(tail -n 1 "$log" 2>/dev/null | tr -d '\r' || true)
        echo "  run log    $log (last write: $mtime)"
        if [ -n "$last" ]; then
            echo "             last line: $last"
        fi
        sweep_rc=$(grep -o '\[sweep exit rc=[0-9]*\]' "$log" 2>/dev/null | tail -1 | grep -o '[0-9]*' || true)
        reap_rc=$(grep -o '\[reap exit rc=[0-9]*\]' "$log" 2>/dev/null | tail -1 | grep -o '[0-9]*' || true)
        supersede_rc=$(grep -o '\[supersede exit rc=[0-9]*\]' "$log" 2>/dev/null | tail -1 | grep -o '[0-9]*' || true)
        if { [ -n "$sweep_rc" ] && [ "$sweep_rc" != "0" ]; } \
            || { [ -n "$reap_rc" ] && [ "$reap_rc" != "0" ]; } \
            || { [ -n "$supersede_rc" ] && [ "$supersede_rc" != "0" ]; }; then
            echo "  WARN: last fire had non-zero payload rc (sweep exit rc=${sweep_rc:-?}, reap exit rc=${reap_rc:-?}, supersede exit rc=${supersede_rc:-?})"
        fi
        # An armed v5 runner has no third leg at all, so its log never carries a
        # supersede stamp — that is the stale-format nudge, not a payload fault.
        if [ -z "$supersede_rc" ] && [ -n "$sweep_rc" ]; then
            echo "  WARN: last fire logged no [supersede exit rc=] stamp — this runner predates HIMMEL-1309's third leg. Re-arm with: bash scripts/cleanup/codex-sweep-cadence.sh arm --force"
        fi
    elif [ -f "$log.prev" ]; then
        echo "  run log    $log (rotated — see .log.prev; no run since last rotation)"
    else
        echo "  run log    $log (absent — task has not fired yet)"
    fi
    if [ -f "$log.prev" ]; then
        mtime=$(date -r "$log.prev" '+%Y-%m-%d %H:%M' 2>/dev/null \
            || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$log.prev" 2>/dev/null \
            || echo '?')
        last=$(tail -n 1 "$log.prev" 2>/dev/null | tr -d '\r' || true)
        echo "  prev log   $log.prev (last write: $mtime)"
        if [ -n "$last" ]; then
            echo "             last line: $last"
        fi
    fi
}

cmd_arm() {
    cadence_require_wsh "codex-sweep-cadence" || exit 2

    command -v cygpath >/dev/null 2>&1 || {
        echo "ERR codex-sweep-cadence: cygpath not on PATH; cannot convert paths for schtasks" >&2
        exit 2
    }

    if [ ! -f "$SWEEP_SCRIPT" ]; then
        echo "ERR codex-sweep-cadence: sweep-codex-orphans.ps1 not found at $SWEEP_SCRIPT" >&2
        exit 2
    fi
    if [ ! -f "$REAP_SCRIPT" ]; then
        echo "ERR codex-sweep-cadence: reap-mcp-fleet.ps1 not found at $REAP_SCRIPT" >&2
        exit 2
    fi
    if [ ! -f "$SUPERSEDE_SCRIPT" ]; then
        echo "ERR codex-sweep-cadence: reap-superseded-fleets.ps1 not found at $SUPERSEDE_SCRIPT" >&2
        exit 2
    fi

    # Payload-shell resolve at arm time (shared with query_task's existence
    # probe via resolve_pwsh, codex-7 HIMMEL-892): SWEEP_PWSH override, else
    # pwsh, else Windows PowerShell.
    local pwsh_posix
    if ! pwsh_posix=$(resolve_pwsh); then
        echo "ERR codex-sweep-cadence: no pwsh or powershell on PATH (set SWEEP_PWSH to override)" >&2
        exit 2
    fi

    # Dedup guard — never double-register the cadence (moved here from Task 1
    # so it lands WITH query_task's fail-closed query classifier it depends
    # on). Mirrors graphmap-cadence's dedup guard, adapted for codex-sweep's
    # single fixed TASK_NAME (no prefix-listing needed). Placed after the
    # env-usable checks (cygpath/scripts/payload-shell) so those still fail
    # rc 2 without ever touching schtasks.
    local dedup_rc=0
    query_task "$TASK_NAME" || dedup_rc=$?
    case "$dedup_rc" in
        0)
            if [ "$FORCE" -eq 1 ]; then
                # NOTE: no /delete here (codex-adv-2, HIMMEL-892) — deleting
                # the existing task at THIS dedup stage, before runner
                # emission/XML generation/creation, left NO cadence at all if
                # any later step failed. `schtasks /create /xml <file> /f`
                # already force-overwrites an existing task IN PLACE, so
                # --force just skips the rc=3 refusal below and lets /create
                # /f replace atomically once all prep below has succeeded.
                echo "codex-sweep-cadence: --force set; existing task $TASK_NAME will be replaced by /create /f" >&2
            else
                {
                    echo "ERR codex-sweep-cadence: $TASK_NAME already armed."
                    echo ""
                    echo "Dedup safeguard — re-run with --force to replace, or inspect with:"
                    echo "    bash scripts/cleanup/codex-sweep-cadence.sh status"
                } >&2
                exit 3
            fi
            ;;
        1) : ;;
        *) exit 2 ;;
    esac

    local pwsh_win sweep_win reap_win supersede_win bat_dir_win
    if ! pwsh_win=$(cygpath -w "$pwsh_posix" 2>&1); then
        echo "ERR codex-sweep-cadence: cygpath -w failed for pwsh path: $pwsh_win" >&2
        exit 4
    fi
    if ! sweep_win=$(cygpath -w "$SWEEP_SCRIPT" 2>&1); then
        echo "ERR codex-sweep-cadence: cygpath -w failed for sweep script: $sweep_win" >&2
        exit 4
    fi
    if ! reap_win=$(cygpath -w "$REAP_SCRIPT" 2>&1); then
        echo "ERR codex-sweep-cadence: cygpath -w failed for reap script: $reap_win" >&2
        exit 4
    fi
    if ! supersede_win=$(cygpath -w "$SUPERSEDE_SCRIPT" 2>&1); then
        echo "ERR codex-sweep-cadence: cygpath -w failed for supersede script: $supersede_win" >&2
        exit 4
    fi
    if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p "$BAT_DIR"
    fi
    if ! bat_dir_win=$(cygpath -w "$BAT_DIR" 2>&1); then
        echo "ERR codex-sweep-cadence: cygpath -w failed for bat dir: $bat_dir_win" >&2
        exit 4
    fi

    local pwsh_esc sweep_esc reap_esc supersede_esc bat_dir_esc
    pwsh_esc=$(cadence_cmd_escape "$pwsh_win")
    sweep_esc=$(cadence_cmd_escape "$sweep_win")
    reap_esc=$(cadence_cmd_escape "$reap_win")
    supersede_esc=$(cadence_cmd_escape "$supersede_win")
    bat_dir_esc=$(cadence_cmd_escape "$bat_dir_win")

    local bat_file="$BAT_DIR/codex-sweep.bat" vbs_file="$BAT_DIR/codex-sweep.vbs" bat_win
    if ! bat_win=$(cygpath -w "$bat_file" 2>&1); then
        echo "ERR codex-sweep-cadence: cygpath -w failed for bat file: $bat_win" >&2
        exit 4
    fi

    local sched
    sched=$(schedule_daily_xml)

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY codex-sweep-cadence: would write $bat_file:"
        emit_bat "$bat_dir_esc" "$pwsh_esc" "$sweep_esc" "$reap_esc" "$supersede_esc" | sed 's/^/    /'
        echo "DRY codex-sweep-cadence: would write $vbs_file:"
        cadence_vbs_wrapper "$bat_win" | sed 's/^/    /'
        echo "DRY codex-sweep-cadence: would schtasks /create /tn $TASK_NAME /xml <daily $SWEEP_TIME, repeat every ${REPEAT_HOURS}h, StartWhenAvailable=true, InteractiveToken/LeastPrivilege> /f"
        emit_task_xml "$bat_win" "$SWEEP_TIME" "$sched" "$REPEAT_HOURS" | sed 's/^/    /'
        echo "codex-sweep-cadence: dry-run complete (no changes made)"
        return 0
    fi

    # Atomic runner publication BEFORE task registration (round-3 CR fix,
    # codex-adv round 3 Important, HIMMEL-892): emit to a temp file BESIDE
    # the target (same dir -> same filesystem -> `mv` is an atomic rename,
    # not a copy; mirrors sanitize-plugin-hooks.sh's
    # `mktemp "$(dirname "$f")/.hooks.json.XXXXXX"` rationale), then publish
    # it (`mv -f` onto $bat_file) BEFORE /create runs, not after /create +
    # verify. The OLD ordering (publish only once the arm outcome was
    # settled) left the scheduled task registered while $bat_file was still
    # ABSENT (fresh arm) or STALE (--force replace) for the entire /create +
    # verify window -- a fire in that window ran the missing/old runner, not
    # the one just armed. Runner generations are functionally equivalent
    # (same version-stamped format, same payload paths -- primary-checkout
    # stable), so publishing early is harmless; the `mv` itself is still an
    # atomic same-dir rename, so $bat_file is NEVER observed partially
    # written either way -- only the ORDER relative to /create moved.
    # Consequences: a failed /create now leaves $bat_file holding the
    # COMPLETE new content (not the old sentinel) -- correct, not a bug (on
    # --force this means the OLD task, still registered, points at the NEW
    # runner, which is fine). A failed-verify NEXTRUN-NONE rollback deletes
    # the task but leaves the published new .bat in place (inert without a
    # task; disarm cleans it up). Only early failures BEFORE this point
    # (cygpath, mktemp) still leave any pre-existing .bat byte-identical.
    local bat_tmp vbs_tmp
    bat_tmp=$(mktemp "$BAT_DIR/.codex-sweep.bat.XXXXXX")
    vbs_tmp=$(mktemp "$BAT_DIR/.codex-sweep.vbs.XXXXXX")
    emit_bat "$bat_dir_esc" "$pwsh_esc" "$sweep_esc" "$reap_esc" "$supersede_esc" > "$bat_tmp"
    cadence_vbs_wrapper "$bat_win" > "$vbs_tmp"
    # Publish the shim first: an already-armed task can safely run the new shim
    # against the still-current .bat while the pair is being replaced.
    if ! mv -f "$vbs_tmp" "$vbs_file"; then
        echo "ERR codex-sweep-cadence: failed to publish runner shim to $vbs_file" >&2
        rm -f "$bat_tmp" "$vbs_tmp"
        exit 4
    fi
    if ! mv -f "$bat_tmp" "$bat_file"; then
        echo "ERR codex-sweep-cadence: failed to publish runner to $bat_file" >&2
        rm -f "$bat_tmp"
        exit 4
    fi

    local err_file
    err_file=$(mktemp -t codex-sweep-cadence.err.XXXXXX)
    if ! schtasks_create_xml "$TASK_NAME" "$sched" "$SWEEP_TIME" "$bat_win" "$err_file" "$REPEAT_HOURS"; then
        echo "ERR codex-sweep-cadence: schtasks /create $TASK_NAME failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        # $bat_file already holds the complete NEW content (atomic mv,
        # published before this /create attempt) -- that is CORRECT
        # behavior now, not a bug; no temp remains to clean up.
        exit 4
    fi
    if [ -s "$err_file" ]; then cat "$err_file" >&2; fi
    rm -f "$err_file"

    # Register immediately after /create succeeds. If the post-arm verification
    # below proves the task dead and rolls it back, the task intentionally stays
    # expected so scheduled_task_exists pages on that vanished registration.
    observability_register_cadence codex-sweep 14400 "$TASK_NAME"

    # Post-arm verify (HIMMEL-938 lesson, ported from scripts/handover/
    # arm-resume.sh Part B): a successful schtasks /create rc=0 is not proof
    # the task will fire -- a misregistered /sd, or any other silent
    # misparse, still returns rc=0 and the task just sits Ready, never
    # firing. The PREVIOUS version of this check grepped the English
    # 'Next Run Time:' label out of `schtasks /query /fo LIST` -- on a
    # non-English Windows locale that label is localized, so a CORRECTLY
    # armed task showed up with empty next-run text and got rolled back +
    # refused: a false positive on the exact safeguard meant to catch true
    # positives. Get-ScheduledTaskInfo's .NextRunTime is a real DateTime
    # (locale-independent), unlike schtasks' text output, so it is the
    # trustworthy cross-check instead -- same lesson, same fix shape as
    # arm-resume.sh. Fail-OPEN on the PROBE itself (missing/broken
    # PowerShell must never block an otherwise-good arm -- WARN and let the
    # arm stand); fail-CLOSED on a bad ANSWER (a confirmed dead
    # registration -- NextRunTime null -- is worse than no arm at all --
    # delete the just-created task and refuse). Unlike arm-resume's ONCE
    # trigger, this task recurs DAILY, so there is no create/verify race or
    # time-window tolerance to reason about -- any real epoch answer passes.
    local _verify_err _ps_out _ps_rc next
    _verify_err=$(mktemp -t codex-sweep-cadence.verify-err.XXXXXX)
    _ps_rc=0
    # `|| _ps_rc=$?` (not a bare trailing `_ps_rc=$?`): under this file's
    # `set -e`, a failing command substitution assigned straight to a
    # variable aborts the script right there -- same errexit-safe capture
    # idiom arm-resume.sh uses (HIMMEL-938).
    _ps_out=$("$pwsh_posix" -NoProfile -NonInteractive -Command "
        try {
            \$t = Get-ScheduledTaskInfo -TaskPath '\' -TaskName '$TASK_NAME' -ErrorAction Stop
            if (\$null -eq \$t.NextRunTime) { 'NEXTRUN-NONE' }
            else { [int64]([DateTimeOffset]\$t.NextRunTime.ToUniversalTime()).ToUnixTimeSeconds() }
        } catch {
            # CommandNotFoundException (ScheduledTasks module absent) ALSO
            # carries the ObjectNotFound category -- it must stay a probe
            # failure, not a task-not-found answer (arm-resume.sh
            # coderabbit-1 lesson).
            if (\$_.Exception -is [System.Management.Automation.CommandNotFoundException]) { Write-Error \$_; exit 1 }
            elseif (\$_.CategoryInfo.Category -eq 'ObjectNotFound') { 'NEXTRUN-NONE' }
            else { Write-Error \$_; exit 1 }
        }
    " 2>"$_verify_err") || _ps_rc=$?

    if [ "$_ps_rc" -ne 0 ] || [ -z "$_ps_out" ]; then
        echo "WARN codex-sweep-cadence: post-arm NextRunTime verify could not run (rc=$_ps_rc) -- arm stands unverified:" >&2
        sed 's/^/    /' "$_verify_err" >&2
        rm -f "$_verify_err"
        next="(unverified -- see WARN above)"
    else
        rm -f "$_verify_err"
        _ps_out=$(printf '%s' "$_ps_out" | tr -d '\r\n ')
        if [ "$_ps_out" = "NEXTRUN-NONE" ]; then
            echo "ERR codex-sweep-cadence: post-arm verify found NO NextRunTime for '$TASK_NAME' -- the task registered but will never fire. Deleting the bad task -- this is the HIMMEL-938 silent-misarm class." >&2
            run_schtasks /delete /tn "$TASK_NAME" /f >/dev/null 2>&1 || true
            # HIMMEL-1879 part 2: ABSENCE IS A REAL STATE, and a run-watcher
            # cannot see it. On 2026-08-09 this cadence ran clean at 12:00 and
            # 13:00, then self-deleted and was gone ~13h before anyone noticed:
            # nothing was WRONG in the ledger, there simply were no more rows,
            # and "no rows" reads identically to "not due yet". The fail-closed
            # delete above stays exactly as it is -- what changes is that the
            # deletion now leaves a POSITIVE row behind, so the absence has a
            # cause an operator (or a cadence auditor) can find. Best-effort:
            # a ledger write must never change the arm's outcome.
            _csd_ledger="$SCRIPT_DIR/../lib/flow-run-ledger.sh"
            _csd_path="${HIMMEL_FLOW_RUNS_LEDGER:-$HOME/.himmel/flow-runs.jsonl}"
            # Tracked, not assumed (codex-2): the ledger write is best-effort, so
            # the banner below must not promise a row that a missing helper or a
            # failed write never produced -- an operator who goes looking for it
            # and finds nothing learns to distrust the banner.
            _csd_logged=0
            if [ -f "$_csd_ledger" ]; then
                _csd_run=$(bash "$_csd_ledger" --append-start "codex-sweep-cadence" "" "" "arm" "" "$TASK_NAME" "" "$$" 2>/dev/null) || _csd_run=""
                if [ -n "$_csd_run" ] && bash "$_csd_ledger" --append-end "codex-sweep-cadence" "$_csd_run" "" 4 "self-deleted" "" \
                        "post-arm verify returned NEXTRUN-NONE; the cadence DELETED ITS OWN task (fail-closed, HIMMEL-938). NOT armed -- no further rows will appear for this task until it is re-armed." >/dev/null 2>&1; then
                    _csd_logged=1
                fi
            fi
            {
                echo "=================================================================="
                echo "  CADENCE SELF-DELETED ITS OWN TASK (HIMMEL-1879)"
                echo "    task:   $TASK_NAME"
                echo "    ledger: $_csd_path"
                echo "  NOTHING IS SCHEDULED. The sweep will simply stop happening,"
                echo "  and silence looks exactly like 'not due yet' -- which is how"
                echo "  the 2026-08-09 disappearance went ~13h unnoticed."
                if [ "$_csd_logged" -eq 1 ]; then
                    echo "  A 'self-deleted' row was written to the flow-run ledger above."
                else
                    echo "  WARNING: the 'self-deleted' ledger row could NOT be written, so"
                    echo "  THIS BANNER IS THE ONLY RECORD. Note it somewhere durable."
                fi
                echo "=================================================================="
            } >&2
            # The runner .bat was already published (see the atomic
            # publication block above) -- it stays on disk holding the new
            # content. It's inert without a live task (disarm cleans it up
            # too); rolling it back here would just reintroduce the
            # publish-after-verify ordering this fix removes.
            echo "NOTE: any previous task definition was replaced; re-arm with: bash scripts/cleanup/codex-sweep-cadence.sh arm [--time HH:MM] --force" >&2
            exit 4
        fi
        # Human-readable banner form; the raw epoch above is what the
        # NEXTRUN-NONE gate validated. date -d @epoch is GNU (Git Bash);
        # fall back to the raw epoch if the conversion fails.
        next=$(date -d "@$_ps_out" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$_ps_out")
    fi

    cat <<EOF

================================================================
  CODEX-SWEEP CADENCE ARMED (HIMMEL-892)
  $TASK_NAME    daily $SWEEP_TIME$(if [ "$REPEAT_HOURS" -gt 0 ]; then printf ', repeating every %sh' "$REPEAT_HOURS"; fi)
    -> sweep-codex-orphans.ps1 -Kill
    -> reap-mcp-fleet.ps1 -Kill
    -> reap-superseded-fleets.ps1 -Kill
  Principal: InteractiveToken / LeastPrivilege (fires only while logged on
  -- StartWhenAvailable catches a missed fire at next logon)
  Next run: $next
  Runner .bat: $bat_file

  Disarm anytime with:
      bash scripts/cleanup/codex-sweep-cadence.sh disarm
================================================================
EOF
}

cmd_status() {
    local status_rc=0 qrc=0 next
    echo "codex-sweep-cadence status:"
    query_task "$TASK_NAME" || qrc=$?
    case "$qrc" in
        0)
            next=$(printf '%s\n' "$QUERY_OUT" | grep -i 'Next Run Time' | head -1 \
                | sed 's/^[^:]*:[[:space:]]*//' || true)
            cadence_registered_status "$TASK_NAME" "${next:+ (next run: $next)}" || status_rc=2
            ;;
        1)  echo "not armed  $TASK_NAME" ;;
        *)
            echo "QUERY ERR  $TASK_NAME (see stderr above)"
            status_rc=2
            ;;
    esac
    status_log "$BAT_DIR/codex-sweep.log"
    return "$status_rc"
}

cmd_disarm() {
    local qrc=0 found=0
    query_task "$TASK_NAME" || qrc=$?
    case "$qrc" in
        0)
            found=1
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "DRY codex-sweep-cadence: would delete $TASK_NAME"
            else
                delete_task "$TASK_NAME"
            fi
            ;;
        1)  : ;;
        *)  exit 2 ;;
    esac
    # Runner cleanup runs in BOTH branches (graphmap-cadence parity) -- a
    # not-armed task can still have a leftover .bat from a prior disarm that
    # failed partway, and disarm should always leave the runner clean too.
    # Still --dry-run safe: gated on DRY_RUN, so a preview touches nothing.
    if [ "$DRY_RUN" -eq 0 ]; then
        rm -f "$BAT_DIR/codex-sweep.bat" "$BAT_DIR/codex-sweep.vbs"
        observability_unregister_cadence codex-sweep "$TASK_NAME"
    fi
    if [ "$found" -eq 0 ]; then
        echo "codex-sweep-cadence: nothing armed — disarm is a no-op"
    elif [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY codex-sweep-cadence: no changes made"
    else
        echo "codex-sweep-cadence: cadence disarmed"
    fi
}

# Runtime preflight on the ARM path only (HIMMEL-1991) — same reasoning as
# graphmap-cadence: arming hands this runtime to an unattended schedule, so the
# drift is named while a human is still watching. Advisory by default;
# HIMMEL_RUNTIME_PREFLIGHT=strict refuses, =0 silences.
if [ "$SUBCMD" = "arm" ]; then
    # shellcheck source=../lib/runtime-preflight.sh
    # shellcheck disable=SC1091
    . "$(dirname "${BASH_SOURCE[0]}")/../lib/runtime-preflight.sh"
    runtime_preflight "codex-sweep-cadence arm" || exit 1
fi

case "$SUBCMD" in
    arm)    cmd_arm ;;
    status) cmd_status ;;
    disarm) cmd_disarm ;;
esac
