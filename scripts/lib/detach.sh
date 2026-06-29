#!/usr/bin/env bash
# detach.sh — run a command detached from the caller so it survives the caller
# returning AND exiting (HIMMEL-576 + HIMMEL-572 + HIMMEL-623).
#
# Source this, then: detach_run <cmd> [args...]
#
# Why: a SessionEnd hook spawns slow best-effort work (a where-are-we ledger
# refresh, an LLM crystallization) and MUST return immediately — the harness
# cancels a hook that overruns its budget (the recurring "Hook cancelled" of
# HIMMEL-623). Two things have to hold for that:
#
#   1. The spawn must not block, and — just as important — the caller's eventual
#      EXIT must not wait for the child. On Linux `setsid` starts the child in a
#      NEW session so neither a wait nor a process-group teardown can reach it
#      (proven by the crystallizer detach-survival test). macOS and Windows Git
#      Bash ship no `setsid`; there the previous `( cmd & )` double-fork was
#      meant to release the child, but on MSYS bash still INTERMITTENTLY waits
#      for the backgrounded grandchild at shell exit. Reproduced on Windows Git
#      Bash (HIMMEL-623): the where-are-we SessionEnd hook returned in a jittery
#      1.4–4.9s with a fixed 6s child even though it "detached" — long enough to
#      blow the hook budget. `disown` removes the job from this shell's table so
#      the exit never waits for it; that is the portable, deterministic fix and
#      it composes with `setsid` where present.
#   2. Stdin is bounded to /dev/null so a child that prompts EOFs out instead of
#      hanging; stdout/stderr to /dev/null so the child never holds the hook's
#      output pipe open.
#
# bash 3.2-safe (`disown` is a 3.2 builtin; it is guarded so a non-bash sh that
# happens to source this still degrades to a plain background job).
# DETACH_NO_SETSID=1 forces the no-setsid fallback even where setsid exists — a
# test seam so the disown branch (the HIMMEL-623 fix, which only matters on
# setsid-less platforms) is exercisable on a Linux CI box that has setsid.
detach_run() {
    if [ -z "${DETACH_NO_SETSID:-}" ] && command -v setsid >/dev/null 2>&1; then
        setsid "$@" </dev/null >/dev/null 2>&1 &
    else
        "$@" </dev/null >/dev/null 2>&1 &
    fi
    disown 2>/dev/null || true
    return 0
}
