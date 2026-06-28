#!/usr/bin/env bash
# detach.sh — run a command fully detached from the caller's process group so it
# survives session / hook teardown (HIMMEL-576 + HIMMEL-572).
#
# Source this, then: detach_run <cmd> [args...]
#
# Why: a SessionEnd hook that backgrounds work with a bare `cmd &` leaves the
# child in the hook's process group; when Claude Code tears that group down on
# exit the child can be reaped before it finishes. `setsid` starts the child in
# a NEW session/process group so the teardown can't reach it (proven by the
# crystallizer detach-survival test). macOS ships no `setsid`, so fall back to a
# double-fork subshell: the subshell backgrounds the command and exits
# immediately, orphaning the child to init. Stdin is bounded to /dev/null so a
# child that prompts EOFs out instead of hanging.
#
# bash 3.2-safe.
detach_run() {
    if command -v setsid >/dev/null 2>&1; then
        setsid "$@" </dev/null >/dev/null 2>&1 &
    else
        ( "$@" </dev/null >/dev/null 2>&1 & )
    fi
    return 0
}
