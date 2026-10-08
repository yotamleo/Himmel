#!/usr/bin/env bash
# Hidden acceptance test for task class-sweep (HIMMEL-4906).
# Six unchecked `cd` sites in a.sh..e.sh (c.sh has two); ok1.sh and ok2.sh are
# already correct and must stay byte-identical.
# Usage: accept.sh <worktree> <fixture-sha>
# shellcheck disable=SC2016
set -u
. "$(dirname "$0")/../accept-common.sh"
WT="$1"; FIX="$2"
SW="$WT/lq-work/sweep"
G="$(mktemp -d "${TMPDIR:-/tmp}/lq-sw.XXXXXX")" || { echo "accept: mktemp failed" >&2; exit 1; }
mkdir -p "$G/out"
NO="$G/does-not-exist"

# stops <script> <args...>: non-zero exit and no RAN line
stops() {
  local out rc
  out="$(bash "$@" 2>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] && ! grep -q RAN <<<"$out"
}
# runs <script> <args...>: still works on good input
runs() { bash "$@" 2>/dev/null | grep -q RAN; }

accept_ok a-stops stops "$SW/a.sh" "$NO"
accept_ok b-stops stops "$SW/b.sh" "$NO"
accept_ok c-first-cd-stops stops "$SW/c.sh" "$NO" "$G"
accept_ok c-second-cd-stops bash -c 'out="$(bash "$1" "$2" "$3" 2>/dev/null)"; rc=$?; [ "$rc" -ne 0 ] && ! grep -q "RAN dest" <<<"$out"' _ "$SW/c.sh" "$G" "$NO"
accept_ok d-stops stops "$SW/d.sh" "$NO"
accept_ok e-stops stops "$SW/e.sh" "$NO"
accept_ok a-still-works runs "$SW/a.sh" "$G"
accept_ok c-still-works runs "$SW/c.sh" "$G" "$G"
accept_ok d-still-works runs "$SW/d.sh" "$G"
accept_ok e-still-works runs "$SW/e.sh" "$G"
accept_ok ok1-unchanged git -C "$WT" diff --quiet "$FIX" -- lq-work/sweep/ok1.sh
accept_ok ok2-unchanged git -C "$WT" diff --quiet "$FIX" -- lq-work/sweep/ok2.sh
rm -rf "$G"

accept_done
