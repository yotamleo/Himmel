#!/usr/bin/env bash
# scripts/handover/konsole-macos.sh - HIMMEL-2534: give headed-arm.sh a TTY
# on macOS, where konsole does not exist.
#
# This is a SHIM, not a port: it accepts the exact konsole argv headed-arm.sh
# already builds and translates it into the house macOS launch pattern
# (`open -a <App> <file>.command`, the same one arm-resume.sh uses for its
# crontab arms). headed-arm.sh's two launch branches are left byte-identical
# -- every existing test asserts their exact argv shape, and a shim keeps
# that contract instead of forking it per platform.
#
# Platform guard (gitbash-only): macOS only, by construction - it shells out
# to `open -a`, which exists nowhere else. No .ps1 twin: the Windows station
# arms through scripts/handover/arm-resume.sh's schtasks backend, and Linux
# keeps using konsole directly, so neither platform ever reaches this file.
# headed-arm.sh only defaults to it when `uname -s` is Darwin.
#
# Accepted argv (exactly what headed-arm.sh emits, nothing more):
#   --separate                  accepted and ignored -- see BLOCKING below
#   --workdir <dir>             cwd for the launched command
#   -p tabtitle=<name>          window/tab title
#   -e <cmd> [args...]          the command to run; everything after -e
#
# BLOCKING (load-bearing): konsole --separate stays in the foreground for the
# life of its window, and headed-arm.sh leans on exactly that -- it
# backgrounds this launcher, keeps the pid, and reads a dead pid as "the
# launch failed" (its codex-1 / r8-codex-4 fixes). `open -a` returns the
# instant the app is told to open, so a naive shim would exit immediately and
# make every successful launch look like a failure. This shim therefore waits
# for the launched command's own pid and blocks until that process exits, so
# its own lifetime is a faithful proxy for the window's -- the same guarantee
# --separate buys on KDE.
#
# App resolution (ARM_TERMINAL_APP / ARM_APP_DIRS, including
# $HOME/Applications where a user-installed iTerm typically lives) is shared
# with arm-resume.sh's own macOS headed launch via
# scripts/lib/macos-app-resolve.sh (HIMMEL-3474) -- one copy of the decision
# instead of two drifting apart. A missing app WARNs and falls back to
# Terminal.app, which is present on every Mac -- fail open, never refuse a
# launch over a bad app name.
#
# Seams (tests only): KONSOLE_MACOS_STARTUP_TICKS overrides the number of
# 0.1s ticks the pid wait below allows (default 200 = 20s, which covers a
# COLD app launch - measured ~16s for a first-ever iTerm start on the
# HIMMEL-2534 station, ~1s warm), so a suite can exercise the timeout path
# without paying it. ARM_TERMINAL_APP / ARM_APP_DIRS are the shared
# macos-app-resolve.sh's own seams, reused here deliberately (see below).
#
# Exit codes: 0 the launched command exited 0; its own rc when it exited
# nonzero; 2 usage / bad argv; 3 nothing launched (`open` itself failed, or
# the scratch dir for the launch body could not be created); 5 a malformed
# KONSOLE_MACOS_STARTUP_TICKS (refused before launching);
# 4 the launched command never reported a pid within the startup budget (the
# scratch body is removed on the way out, so a window that opens AFTER the
# budget shows a missing-file error rather than running an unconfirmed
# session - deliberate, see codex-review S8), or its startup ack could not be
# written; a body runs its command only after that ack (HIMMEL-3484).
set -u

# HIMMEL-3474: shared with arm-resume.sh's own macOS headed launch -- one
# copy of the ARM_TERMINAL_APP / ARM_APP_DIRS resolution instead of two.
. "$(cd "$(dirname "$0")" && pwd)/../lib/macos-app-resolve.sh"

WORKDIR=""
TABTITLE=""
CMD=()
_saw_e=0

while [ $# -gt 0 ]; do
    case "$1" in
        --separate|--nofork)
            shift
            ;;
        --workdir)
            [ $# -ge 2 ] || { echo "konsole-macos: --workdir needs a value" >&2; exit 2; }
            WORKDIR="$2"; shift 2
            ;;
        -p)
            [ $# -ge 2 ] || { echo "konsole-macos: -p needs a value" >&2; exit 2; }
            case "$2" in
                tabtitle=*) TABTITLE="${2#tabtitle=}" ;;
                *) : ;;   # any other -p profile property: accepted, ignored
            esac
            shift 2
            ;;
        -e)
            shift
            _saw_e=1
            # Check the operand here (PR 1129 CR): `-e` as the last argument
            # leaves CMD empty, and an empty array under `set -u` is not safe
            # to expand on bash 3.2, the macOS system bash.
            [ $# -gt 0 ] || { echo "konsole-macos: no command given (-e is required)" >&2; exit 2; }
            CMD=("$@")
            break
            ;;
        *)
            echo "konsole-macos: unsupported argument '$1' (this shim accepts only the argv headed-arm.sh builds)" >&2
            exit 2
            ;;
    esac
done

if [ "$_saw_e" -ne 1 ]; then
    echo "konsole-macos: no command given (-e is required)" >&2
    exit 2
fi
if [ -n "$WORKDIR" ] && [ ! -d "$WORKDIR" ]; then
    echo "konsole-macos: --workdir '$WORKDIR' is not a directory" >&2
    exit 2
fi

# Same resolution order, variable names and fail-open policy as
# arm-resume.sh's macOS headed launch -- one vocabulary for one decision,
# shared via scripts/lib/macos-app-resolve.sh (HIMMEL-3474).
# codex-review S10: arm-resume.sh documents ARM_TERMINAL_APP=none as "opt out
# to a headless inline launch". This launcher exists solely to give the
# session a TTY, so it has no headless mode to opt into -- treating "none" as
# an app name would WARN about a missing none.app and open a Terminal window
# anyway, contradicting the documented meaning of the variable the operator
# set. Refuse with the real reason instead.
if [ "${ARM_TERMINAL_APP:-}" = "none" ]; then
    echo "konsole-macos: ARM_TERMINAL_APP=none is not supported here - headed-arm needs a real TTY, so this launcher has no headless mode (arm-resume.sh's crontab arms are the path that does)" >&2
    exit 2
fi
TERM_APP="$(macos_resolve_term_app konsole-macos)"

# Startup budget: the window has to come up and the body has to reach its
# `echo $$`. 20s is generous for a cold app launch and still bounded, so a
# launch that silently never starts fails loudly instead of hanging an arm.
_ticks="${KONSOLE_MACOS_STARTUP_TICKS:-200}"
# HIMMEL-2534 CR fix (N346): `[ -ge ]` on a non-numeric _ticks doesn't abort -
# it errors to stderr every iteration and evaluates false, so a malformed
# KONSOLE_MACOS_STARTUP_TICKS (e.g. "abc") spins this loop forever instead of
# failing bounded. Validated BEFORE `open -a` (N357, codex-1): a refusal
# after the launch would leave a running, untracked session behind.
# headed-arm.sh validates the same var with this same pattern before it
# sizes its own budget from it (HIMMEL-3484), so both sides refuse alike.
case "$_ticks" in
    ''|*[!0-9]*)
        echo "konsole-macos: KONSOLE_MACOS_STARTUP_TICKS must be a plain decimal integer, got '$_ticks'" >&2
        exit 5
        ;;
esac
_ticks=$(( 10#$_ticks ))

RUNDIR="$(mktemp -d "${TMPDIR:-/tmp}/konsole-macos.XXXXXX")" || {
    echo "konsole-macos: could not create a scratch dir for the launch body" >&2
    exit 3
}
# ponytail (HIMMEL-2534 CR fix, N346): this delete races the terminal app's
# own read of $CMDFILE if `open -a` is slow handing it to `sh`. Probed as
# safe -- a `.command` `sh` has already opened keeps running to completion
# after the unlink, standard POSIX unlink-while-open semantics -- but that is
# a probed behavior on the filesystems tried, not something this shim
# enforces; it is not re-checked after cleanup.
trap 'rm -rf "$RUNDIR"' EXIT
PIDFILE="$RUNDIR/pid"
RCFILE="$RUNDIR/rc"
GOFILE="$RUNDIR/go"
CMDFILE="$RUNDIR/session.command"

# %q-quote every element so an argv value carrying spaces/quotes (a claude
# prompt, a tabtitle) survives the trip through the .command file's shell.
_q_cmd=$(printf '%q ' "${CMD[@]}")
# HIMMEL-2534, measured: `open -a` does NOT inherit the launching shell's
# environment the way konsole inherits its parent's -- the .command body
# starts from a fresh login-shell environment. Without this, $PATH is
# whatever the GUI session has and the launcher (`claude`) either resolves
# to a different binary or is not found at all, which is the same class of
# bug HIMMEL-3074 fixed on arm-resume.sh's macOS path. Propagate PATH
# explicitly, exactly as arm-resume.sh's generated crontab runner does.
# PATH ONLY. Every other variable the arming shell exported is deliberately
# dropped (codex-review I2): the macOS arm starts from the GUI session's
# environment, not the arming session's, which DIVERGES from Linux, where
# konsole inherits its parent's env wholesale. The three vars headed-arm.sh
# sets itself travel in $CMD's own `env -u ... VAR=val` prefix and are
# unaffected; its `-u` clears become no-ops, since nothing was inherited to
# clear. But anything an operator exported in the launching shell -- e.g.
# HANDOVER_DIR, JIRA_PROJECT_KEY, a hook-bypass var -- does NOT reach the
# armed session here; the CLAUDE_CODE_MAX_* / FLEET_CAP fan-out caps are the
# one exception, forwarded below (HIMMEL-3484). Propagating a wider allowlist
# is a deliberate non-goal for now; widening it is a policy decision about
# what an armed successor should inherit, not a shim detail.
_q_path=$(printf '%q' "$PATH")
_q_workdir=$(printf '%q' "${WORKDIR:-$PWD}")
_q_pidfile=$(printf '%q' "$PIDFILE")
_q_rcfile=$(printf '%q' "$RCFILE")
_q_gofile=$(printf '%q' "$GOFILE")
_q_rundir=$(printf '%q' "$RUNDIR")

{
    printf '#!/bin/sh\n'
    printf '# generated by konsole-macos.sh -- headed session body\n'
    printf 'PATH=%s; export PATH\n' "$_q_path"
    # HIMMEL-3484: the fan-out caps are the one exception to PATH ONLY above -
    # dropping them runs a Mac leg uncapped, which is a safety loss, not a
    # policy choice about what a successor inherits.
    for _v in $(compgen -e); do
        case "$_v" in
            CLAUDE_CODE_MAX_*|FLEET_CAP)
                printf '%s=%s; export %s\n' "$_v" "$(printf '%q' "${!_v}")" "$_v"
                ;;
        esac
    done
    printf 'cd %s || exit 1\n' "$_q_workdir"
    # The wrapper shell deliberately does NOT exec the command (codex-review
    # I4): it must OUTLIVE it to record the rc on the line after, which is
    # what the shim reads back at the end. Its pid is still a faithful
    # session lifetime, because it waits on the command. Do not "restore" an
    # exec here -- $RCFILE would then never be written and every launch would
    # report success regardless of outcome.
    # `|| exit 1` (N357 r2 codex-1): a body the terminal opened just before
    # the shim's timeout cleanup removed $RUNDIR can no longer record its pid.
    # The shim has already given up on it, so running the command would leave
    # an untracked session a retry could duplicate - stop here instead.
    printf 'echo $$ > %s || exit 1\n' "$_q_pidfile"
    # HIMMEL-3484 startup handshake: a pid written after the shim's last
    # check but before its exit-4 cleanup lands, and the body would run a
    # session the shim already reported as failed. So the body waits for the
    # shim's go/ack, and exits once the shim or its scratch dir is gone.
    printf 'while [ ! -e %s ]; do\n' "$_q_gofile"
    printf '    [ -d %s ] || exit 1\n' "$_q_rundir"
    printf '    kill -0 %s 2>/dev/null || exit 1\n' "$$"
    printf '    sleep 0.1\n'
    printf 'done\n'
    printf '%s\n' "$_q_cmd"
    printf 'echo $? > %s\n' "$_q_rcfile"
} > "$CMDFILE"
chmod +x "$CMDFILE"

if [ -n "$TABTITLE" ]; then
    # Title via the terminal's own OSC escape rather than AppleScript: it
    # works identically in iTerm and Terminal.app, needs no Automation
    # (TCC) permission prompt, and cannot fail the launch.
    _tmp="$RUNDIR/titled.command"
    {
        printf '#!/bin/sh\n'
        printf 'printf "\\033]0;%%s\\007" %s\n' "$(printf '%q' "$TABTITLE")"
        tail -n +2 "$CMDFILE"
    } > "$_tmp"
    chmod +x "$_tmp"
    mv "$_tmp" "$CMDFILE"
fi

if ! open -a "$TERM_APP" "$CMDFILE"; then
    echo "konsole-macos: open -a $TERM_APP failed - no session was launched" >&2
    exit 3
fi

_waited=0
while [ ! -s "$PIDFILE" ]; do
    if [ "$_waited" -ge "$_ticks" ]; then
        echo "konsole-macos: launched $TERM_APP but the session never reported a pid within the startup budget" >&2
        exit 4
    fi
    sleep 0.1
    _waited=$((_waited + 1))
done
CHILD="$(cat "$PIDFILE")"
# The ack the body is waiting on (HIMMEL-3484). Written only here, never on
# the timeout path above, so a body that missed the budget can never run.
: > "$GOFILE" || {
    echo "konsole-macos: could not write the startup ack for the session" >&2
    exit 4
}

# Block for the life of the session -- the --separate contract headed-arm.sh
# depends on. kill -0 is the liveness probe; the body writes its rc on exit.
while kill -0 "$CHILD" 2>/dev/null; do
    sleep 1
done
if [ -s "$RCFILE" ]; then
    exit "$(cat "$RCFILE")"
fi
exit 0
