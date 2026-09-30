#!/usr/bin/env bash
# qmd-bounded.sh — run qmd under a deadline that kills its WHOLE process tree
# (HIMMEL-3956).
#
# Run it:   bash qmd-bounded.sh <qmd verb> [args...]
#   runs qmd (resolved as qmd-bin.sh's qmd_cmd does) under a deadline of
#   $QMD_TIMEOUT_SECS, else 300 s — the ad-hoc path block-bare-qmd-query.sh
#   sends agents to.
# Source it, then: qmd_bounded <secs> <cmd> [args...]
#   rc      the command's own rc, or 124 when the deadline fired (as timeout(1))
#   <secs>  whole seconds; 0 runs the command unbounded
#   QMD_KILL_GRACE_SECS  seconds between the group SIGTERM and the SIGKILL (5)
#
# qmd_timeout_secs prints the SOURCED callers' default (qmd_cmd, qmd-reindex,
# qmd-staleness): $QMD_TIMEOUT_SECS, else 3600 - longer than the executed
# path's 300 s because those run embeds. An embed cut short by it is
# resumable; the next run carries on.
#
# Why not plain `timeout N qmd …`: the qmd launcher (bin/qmd in the fork) is a
# node trampoline that spawns `bun src/cli/qmd.ts` and forwards no signals.
# GNU timeout SIGTERMs its process group, node dies, and timeout returns at
# once — so its `-k` SIGKILL never fires. bun catches SIGTERM in a JS handler
# that cannot run while its main thread is blocked in native llama.cpp, so it
# lives on, reparented to init. Five such `qmd query` orphans ran at ~99 % CPU
# for ~15 h. Here the command gets its own process group (`set -m`) and a
# watchdog outside it SIGTERMs, then SIGKILLs, the whole group — whatever the
# direct child did. The watchdog is also its own group, so it still enforces
# the deadline if the caller itself is killed. When the direct child ends
# first, anything it left in the group is reaped the same way before return.
#
# ponytail: bounds the orphan, not the upstream launcher's missing signal
# forwarding — HIMMEL-3958 (tobi/qmd issue) removes the cause. Only callers
# that go through this are bounded: ad-hoc agent Bash reaching the `qmd` on
# PATH is not; block-bare-qmd-query.sh (HIMMEL-3960) refuses the bare search
# verbs and names this script as the replacement.
#
# Platform guard (gitbash-only): POSIX bash 3.2+; on Git Bash a native
# Windows node child is outside MSYS process groups (Windows is alpha).

qmd_timeout_secs() {
  printf '%s\n' "${QMD_TIMEOUT_SECS:-3600}"
}

qmd_bounded() {
  local secs="$1"
  shift
  case "$secs" in
    '' | *[!0-9]*)
      echo "qmd_bounded: deadline must be whole seconds, got '$secs'" >&2
      return 2
      ;;
  esac
  if [ "$secs" -eq 0 ]; then
    "$@"
    return $?
  fi
  # No watchdog is possible without these (a hermetic test PATH); a sleep that
  # fails at once would fire the deadline immediately. Run unbounded instead.
  if ! command -v sleep >/dev/null 2>&1 || ! command -v mktemp >/dev/null 2>&1; then
    echo "qmd_bounded: sleep/mktemp not on PATH - running unbounded" >&2
    "$@"
    return $?
  fi
  (
    # Sourced by errexit callers: a non-zero `wait` must not abort this
    # subshell before the rc is mapped and the watchdog is cancelled.
    set +e
    grace="${QMD_KILL_GRACE_SECS:-5}"
    # The watchdog creates the marker; it never exists before, so a failed
    # cleanup (no rm on a hermetic PATH) cannot read as a fired deadline.
    fdir="$(mktemp -d "${TMPDIR:-/tmp}/qmd-bounded.XXXXXX")" || exit 2
    fired="$fdir/fired"
    # bash hands a background job /dev/null for stdin; keep the caller's on fd
    # 3 so a piped input still reaches the command. A CLOSED stdin becomes
    # /dev/null: a closed fd 0 lets the command's own pipes land on it.
    { exec 3<&0; } 2>/dev/null || exec 3</dev/null
    set -m
    "$@" <&3 3<&- &
    pid=$!
    exec 3<&-
    # Output to /dev/null: a watchdog left holding the caller's stdout would
    # keep a `$(qmd_bounded …)` capture open until the deadline.
    (
      sleep "$secs"
      : >"$fired"
      kill -TERM -- "-$pid" 2>/dev/null || exit 0
      n=0
      while [ "$n" -lt "$grace" ]; do
        sleep 1
        kill -0 -- "-$pid" 2>/dev/null || exit 0
        n=$((n + 1))
      done
      kill -KILL -- "-$pid" 2>/dev/null
    ) >/dev/null 2>&1 &
    wd=$!
    # Both groups exist now; job control off again silences bash's "[1] Exit"
    # job notices on the caller's stderr.
    set +m
    trap 'kill -TERM -- "-$pid" 2>/dev/null' TERM INT HUP
    wait "$pid"
    rc=$?
    # A trapped signal interrupts wait with rc > 128; wait again for the real rc.
    while kill -0 "$pid" 2>/dev/null; do
      wait "$pid"
      rc=$?
    done
    if [ -e "$fired" ]; then
      # The direct child is gone; the watchdog is still reaping the rest of
      # the group (bun, in the qmd case). Return only once it has.
      wait "$wd"
      rm -rf "$fdir"
      exit 124
    fi
    # The direct child is gone before the deadline - it exited, was killed by
    # someone else, or took a forwarded caller signal - but a TERM-ignoring
    # descendant (bun) may not be. Escalate as the watchdog would before
    # cancelling it; an empty group costs one kill -0.
    if kill -0 -- "-$pid" 2>/dev/null; then
      kill -TERM -- "-$pid" 2>/dev/null
      n=0
      while kill -0 -- "-$pid" 2>/dev/null && [ "$n" -lt "$grace" ]; do
        sleep 1
        n=$((n + 1))
      done
      kill -KILL -- "-$pid" 2>/dev/null
    fi
    kill -- "-$wd" 2>/dev/null
    rm -rf "$fdir" 2>/dev/null
    exit "$rc"
  )
}

# Executed rather than sourced: run qmd bounded. The guard stops the re-source
# from qmd-bin.sh (which sources this file) from re-entering this block.
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ -z "${_QMD_BOUNDED_MAIN:-}" ]; then
  _QMD_BOUNDED_MAIN=1
  if [ "$#" -eq 0 ]; then
    echo "usage: bash qmd-bounded.sh <qmd verb> [args...]  (deadline: \$QMD_TIMEOUT_SECS, else 300 s)" >&2
    exit 2
  fi
  export QMD_TIMEOUT_SECS="${QMD_TIMEOUT_SECS:-300}"
  # shellcheck source=scripts/lib/qmd-bin.sh
  . "$(dirname "${BASH_SOURCE[0]}")/qmd-bin.sh"
  qmd_cmd "$@"
  exit $?
fi
