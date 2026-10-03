#!/usr/bin/env bash
# Hidden acceptance test for task doc-plus-code (HIMMEL-4090).
# Usage: accept.sh <worktree> <fixture-sha>
# bash -c bodies take their values as positional args, so single quotes are right.
# shellcheck disable=SC2016
set -u
. "$(dirname "$0")/../accept-common.sh"
WT="$1"
S="$WT/lq-work/log-tail.sh"
R="$WT/lq-work/README.md"
LOG="$(mktemp "${TMPDIR:-/tmp}/lq-log.XXXXXX")" || { echo "accept: mktemp failed" >&2; exit 1; }
printf '%s\n' 'INFO start' 'ERROR one' 'INFO mid' 'ERROR two' 'WARN x' 'ERROR three' 'INFO end' > "$LOG"

out() { bash "$S" "$@" 2>/dev/null | tr '\n' '|'; }

accept_eq plain-n-unchanged 'ERROR three|INFO end|' "$(out -n 2 "$LOG")"
accept_eq grep-then-tail 'ERROR two|ERROR three|' "$(out --grep ERROR -n 2 "$LOG")"
accept_eq order-independent 'ERROR two|ERROR three|' "$(out -n 2 --grep ERROR "$LOG")"
accept_eq extended-regex 'ERROR one|WARN x|' "$(out --grep 'one|WARN' "$LOG")"
accept_eq no-match-empty '' "$(out --grep NOPE "$LOG")"
accept_rc no-match-exit0 0 bash "$S" --grep NOPE "$LOG"
accept_rc grep-missing-value 64 bash "$S" "$LOG" --grep
accept_rc invalid-regex 64 bash "$S" --grep '(' "$LOG"
accept_rc unreadable-still-66 66 bash "$S" --grep x /nonexistent/lq-file

accept_ok readme-usage-line grep -Eq '^ *log-tail\.sh .*--grep' "$R"
accept_ok readme-option-row grep -Eq '^\|[^|]*--grep' "$R"
accept_ok readme-keeps-n-row grep -Eq '^\|[^|]*-n N' "$R"
accept_ok readme-keeps-exit-codes grep -q '66 unreadable' "$R"
accept_ok own-test-passes bash -c 'cd "$1" && bash lq-work/test-log-tail.sh' _ "$WT"
rm -f "$LOG"

accept_done
