#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-headed-arm-leg.sh
# scripts/handover/console-kit/test-go.sh - suite for go.sh (HIMMEL-2919), the
# console's GO-evidence writer that merge-on-green.sh's console-GO gate reads.
# test-merge-on-green.sh drives the reader end to end with GO files written by
# THIS script; this suite pins the writer's own contract:
#   1. usage: arg count, non-digit / leading-zero PR, sha not 40 lowercase hex -> exit 2.
#   2. write: path printed, file fields pr= / head= / by= / at= (ISO-8601 UTC).
#   3. by= falls back to <user>@<host> without CONSOLE_SESSION_NAME.
#   4. idempotent: a re-run overwrites in place, no temp file left behind.
#   5. HIMMEL_CONSOLE_LEG set -> exit 3, nothing written (a leg never writes its own GO).
#   6. unresolvable handover root -> exit 1.
#
# Platform guard (gitbash-only): POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/go.sh"
unset HIMMEL_CONSOLE_LEG CONSOLE_SESSION_NAME 2>/dev/null || true

tmp="$(mktemp -d "${TMPDIR:-/tmp}/go-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
fails=0
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { grepq "$2" -F -e "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }

SHA=0123456789abcdef0123456789abcdef01234567
ROOT="$tmp/root"; mkdir -p "$ROOT"
GO="$ROOT/.locks/go/77.$SHA"

# --- 1. usage --------------------------------------------------------------
for args in "" "77" "77 $SHA extra" "x1 $SHA" "077 $SHA" "77 ${SHA%?}" "77 ${SHA}0" \
            "77 0123456789ABCDEF0123456789abcdef01234567" "77 g123456789abcdef0123456789abcdef01234567"; do
  rc=0
  # shellcheck disable=SC2086  # word-splitting the args string IS the point
  HANDOVER_DIR="$ROOT" bash "$SCRIPT" $args >/dev/null 2>&1 || rc=$?
  check "usage: [$args] -> exit 2" "$rc" "2"
done
check "usage: nothing written" "$(ls -A "$ROOT")" ""

# --- 2. write ----------------------------------------------------------------
rc=0; out="$(HANDOVER_DIR="$ROOT" CONSOLE_SESSION_NAME=console-x bash "$SCRIPT" 77 "$SHA" 2>&1)" || rc=$?
check "write: exit 0" "$rc" "0"
check "write: prints the GO path" "$out" "$GO"
body="$(cat "$GO" 2>/dev/null || true)"
contains "write: pr= field" "$body" "pr=77"
contains "write: head= field" "$body" "head=$SHA"
contains "write: by= is the console session name" "$body" "by=console-x"
grepq "$body" -Ex 'at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' \
  && echo "ok - write: at= is ISO-8601 UTC" || { echo "FAIL - write: at= not ISO-8601 UTC: [$body]"; fails=$((fails+1)); }

# --- 3. by= fallback ---------------------------------------------------------
rc=0; HANDOVER_DIR="$ROOT" bash "$SCRIPT" 78 "$SHA" >/dev/null 2>&1 || rc=$?
check "fallback: exit 0" "$rc" "0"
grepq "$(cat "$ROOT/.locks/go/78.$SHA" 2>/dev/null)" -Ex 'by=[^@]+@.+' \
  && echo "ok - fallback: by=<user>@<host>" || { echo "FAIL - fallback: by= not <user>@<host>"; fails=$((fails+1)); }

# --- 4. idempotent rewrite ---------------------------------------------------
rc=0; HANDOVER_DIR="$ROOT" CONSOLE_SESSION_NAME=console-y bash "$SCRIPT" 77 "$SHA" >/dev/null 2>&1 || rc=$?
check "rewrite: exit 0" "$rc" "0"
contains "rewrite: overwritten in place" "$(cat "$GO" 2>/dev/null)" "by=console-y"
check "rewrite: one head= line, not appended" "$(grep -c '^head=' "$GO" 2>/dev/null)" "1"
leftover=0
for f in "$ROOT/.locks/go"/.go.*; do [ -e "$f" ] && leftover=$((leftover+1)); done
check "rewrite: no temp file left behind" "$leftover" "0"

# --- 5. a console-spawned leg cannot write its own GO ------------------------
LEGROOT="$tmp/legroot"; mkdir -p "$LEGROOT"
rc=0; out="$(HANDOVER_DIR="$LEGROOT" HIMMEL_CONSOLE_LEG=1 bash "$SCRIPT" 77 "$SHA" 2>&1)" || rc=$?
check "leg marker: exit 3" "$rc" "3"
contains "leg marker: names the reason" "$out" "console-spawned leg"
check "leg marker: nothing written" "$(ls -A "$LEGROOT")" ""
rc=0; HANDOVER_DIR="$LEGROOT" HIMMEL_CONSOLE_LEG=0 bash "$SCRIPT" 77 "$SHA" >/dev/null 2>&1 || rc=$?
check "leg marker: a falsy marker is no marker" "$rc" "0"

# --- 6. unresolvable handover root -------------------------------------------
rc=0; HANDOVER_DIR="$tmp/absent" bash "$SCRIPT" 77 "$SHA" >/dev/null 2>&1 || rc=$?
check "no root: exit 1" "$rc" "1"

echo "---"
if [ "$fails" -eq 0 ]; then
  echo "PASS - test-go.sh"
  exit 0
else
  echo "FAIL - test-go.sh ($fails failure(s))"
  exit 1
fi
