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
# CONSTRAINT (HIMMEL-636): detached SessionEnd work must be self-contained host
# tooling (node/git/curl). It must NOT depend on headless `claude` print/--bg
# modes — those bill to a separate, volatile bucket (HIMMEL-128) and a detached
# failure is silent. If a SessionEnd step ever needs an LLM (e.g. the HIMMEL-576
# crystallizer), migrate it to an ARMED-session model (a scheduled INTERACTIVE
# `claude` via the arm-resume scheduler), not a fire-and-forget child here.
#
# bash 3.2-safe (`disown` is a 3.2 builtin; it is guarded so a non-bash sh that
# happens to source this still degrades to a plain background job).
# DETACH_NO_SETSID=1 forces the no-setsid fallback even where setsid exists — a
# test seam so the disown branch (the HIMMEL-623 fix, which only matters on
# setsid-less platforms) is exercisable on a Linux CI box that has setsid.
#
# HIMMEL_DETACH_INLINE=1 (HIMMEL-2004) turns every detach_run in the process
# tree into a plain synchronous call. The bounded Stop worker sets it on the
# jobs it runs: work that has ALREADY been serialised by the queue must not
# fan back out of it, or the bound buys nothing. Nothing else sets it, so the
# Codex lane and any adopter without the queue see today's behaviour exactly.
#
# BASH_SOURCE is a bash array, and `${BASH_SOURCE[0]}` is a hard parse error in
# dash — the header above promises this file still degrades cleanly when a
# non-bash `sh` sources it, so the resolution is gated rather than
# unconditional. With no bash the dir stays empty and detach_queued takes its
# documented fallback instead of resolving a wrong path.
_DETACH_LIB_DIR=""
if [ -n "${BASH_VERSION:-}" ]; then
    _DETACH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || _DETACH_LIB_DIR=""
fi

detach_run() {
    if [ "${HIMMEL_DETACH_INLINE:-}" = "1" ]; then
        "$@" </dev/null >/dev/null 2>&1
        return 0
    fi
    if [ -z "${DETACH_NO_SETSID:-}" ] && command -v setsid >/dev/null 2>&1; then
        setsid "$@" </dev/null >/dev/null 2>&1 &
    else
        "$@" </dev/null >/dev/null 2>&1 &
    fi
    disown 2>/dev/null || true
    return 0
}

# detach_queued <key> <cmd> [args...] — the BOUNDED variant of detach_run
# (HIMMEL-2004). Instead of spawning an independent tree per caller, it drops
# one durable entry in the Stop queue (scripts/hooks/stop-queue.mjs) and returns;
# a single worker drains the queue one job at a time. N sessions ending together
# then cost one drain rather than N trees — which is the whole point, since
# HIMMEL-1993 measured this box's kernel pool leaking in proportion to exactly
# that fan-out.
#
# <key> NAMES the work; it is not a dedup identity here. The queue keys an entry
# on the session id it reads from the enqueue's STDIN, and this function has no
# stdin to give it — the calling hook drained the payload before re-execing
# itself — so every detach_queued call gets its own unique entry. That is the
# correct behaviour for these callers (SessionEnd fires once per session, so a
# fleet of N children must produce N entries and there is nothing to collapse),
# but it does mean per-session dedup applies only to the settings-wired hooks,
# which pipe their payload straight into the enqueue.
#
# CALL IT ONLY WITH SECRET-FREE ARGUMENTS. A queue entry is a file on disk, so
# argv is written down. The end-side hooks route their outer self-re-exec here
# (argv = a script path plus a payload file) and deliberately leave their inner
# relay calls — a curl whose URL carries a bot token — on plain detach_run,
# which the worker then runs INLINE via HIMMEL_DETACH_INLINE. The token never
# leaves memory and the relay is still inside the bound.
#
# Falls back to detach_run whenever the queue is unavailable (no node, no
# script — an adopter running the hooks outside this checkout) or switched off
# with HIMMEL_STOP_QUEUE_OFF=1. Losing the bound is acceptable; losing the work
# is not.
#
# Optional `--cleanup <file>` after the key: a file the COMMAND would delete
# itself if it ran (these hooks save their stdin payload to a temp file and pass
# the path in argv). An entry that expires or exhausts its crash budget never
# runs, so the queue takes ownership of that file and removes it with the entry;
# otherwise one leaks per dropped session.
detach_queued() {
    _dq_key="$1"
    shift
    _dq_cleanup=""
    if [ "${1:-}" = "--cleanup" ]; then
        _dq_cleanup="$2"
        shift 2
    fi
    if [ "${HIMMEL_DETACH_INLINE:-}" = "1" ]; then
        "$@" </dev/null >/dev/null 2>&1
        return 0
    fi
    _dq_script="${_DETACH_LIB_DIR:-}/../hooks/stop-queue.mjs"
    if [ "${HIMMEL_STOP_QUEUE_OFF:-}" != "1" ] && [ -n "${_DETACH_LIB_DIR:-}" ] \
        && [ -f "$_dq_script" ] && command -v node >/dev/null 2>&1; then
        if [ -n "$_dq_cleanup" ]; then
            node "$_dq_script" enqueue --key "$_dq_key" --cleanup "$_dq_cleanup" -- "$@" </dev/null >/dev/null 2>&1 && return 0
        else
            node "$_dq_script" enqueue --key "$_dq_key" -- "$@" </dev/null >/dev/null 2>&1 && return 0
        fi
    fi
    detach_run "$@"
}
