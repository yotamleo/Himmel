#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check(), as in test-append-results.sh
# scripts/handover/console-kit/test-leg-jira-status.sh - HIMMEL-4419. Hermetic
# tests for leg-jira-status.sh and its append-results.sh wiring: a stubbed Jira
# CLI (LEG_JIRA_CLI) records every `transition`, so no real ticket is touched.
#   1. LIVE bullet on a ticket-named doc   -> To Do ticket moves to In Progress
#   2. non-LIVE bullet                     -> no transition
#   3. already In Progress / In Review     -> no re-transition, no backwards move
#   4. Done / Closed                       -> never moved, even with --allow-back
#   5. --allow-back                        -> In Review may go back to In Progress
#   6. Jira failure (get or transition)    -> rc 0, warns, the bullet still lands
#   7. doc with no ticket in its name      -> no Jira call at all
#   8. LEG_JIRA_STATUS=0                   -> opt-out, no Jira call
#
# Platform guard: POSIX bash 3.2+, no .ps1 twin by design (shell-only harness).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/leg-jira-status.sh"
APPEND="$HERE/append-results.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/leg-jira-status-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: [$2] lacks [$3]"; fails=$((fails+1)) ;; esac; }

STUB="$tmp/jira-stub.sh"
cat >"$STUB" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1" in
    get)
        [ "${STUB_GET_FAIL:-}" = 1 ] && { echo "boom" >&2; exit 1; }
        printf '{"fields":{"status":{"name":"%s"}}}\n' "$STUB_STATUS" ;;
    transition)
        [ "${STUB_TRANSITION_FAIL:-}" = 1 ] && { echo "boom" >&2; exit 1; }
        exit 0 ;;
esac
EOS
chmod +x "$STUB"
export STUB_LOG="$tmp/log"
export LEG_JIRA_CLI="$STUB"

run() { # <status> <args...> -> rc
    : > "$STUB_LOG"
    STUB_STATUS="$1" bash "$SUT" "${@:2}" >"$tmp/out" 2>&1
}
transitions() { grep -c '^transition' "$STUB_LOG" || true; }

mkdoc() { printf '# leg\n\n## Results (newest at the bottom)\n' > "$1"; }

# --- 1. LIVE on a ticket-named doc -----------------------------------------
d="$tmp/HIMMEL-9001-N1-slug-2026-10-05-RESUME.md"; mkdoc "$d"
: > "$STUB_LOG"
STUB_STATUS="To Do" bash "$APPEND" "$d" "LIVE — starting" >/dev/null 2>&1
check "1: LIVE moves a To Do ticket" "$(grep '^transition' "$STUB_LOG")" "transition HIMMEL-9001 In Progress"
contains "1: bullet landed" "$(tail -n 1 "$d")" "LIVE — starting"

# --- 2. non-LIVE bullet ------------------------------------------------------
: > "$STUB_LOG"
STUB_STATUS="To Do" bash "$APPEND" "$d" "FINDING — x" >/dev/null 2>&1
check "2: FINDING makes no transition" "$(transitions)" 0
: > "$STUB_LOG"
STUB_STATUS="To Do" bash "$APPEND" "$d" "LIVELY prose" >/dev/null 2>&1
check "2: LIVELY (not the LIVE token) makes no transition" "$(transitions)" 0

# --- 3. idempotent / never backwards ----------------------------------------
run "In Progress" HIMMEL-9001 "In Progress"
check "3: same status -> no transition" "$(transitions)" 0
run "In Review" HIMMEL-9001 "In Progress"
check "3: In Review -> In Progress is backwards, refused" "$(transitions)" 0
run "In Review" HIMMEL-9001 "In Review"
check "3: In Review twice -> no transition" "$(transitions)" 0
run "In Progress" HIMMEL-9001 "In Review"
check "3: In Progress -> In Review moves" "$(grep '^transition' "$STUB_LOG")" "transition HIMMEL-9001 In Review"

# --- 4. Done is terminal ------------------------------------------------------
run "Done" HIMMEL-9001 "In Progress" --allow-back
check "4: Done never moves (--allow-back)" "$(transitions)" 0
run "Done" HIMMEL-9001 "In Review"
check "4: Done never moves" "$(transitions)" 0
run "Closed" HIMMEL-9001 "In Review"
check "4: Closed never moves" "$(transitions)" 0

# --- 5. --allow-back ----------------------------------------------------------
run "In Review" HIMMEL-9001 "In Progress" --allow-back
check "5: --allow-back moves In Review -> In Progress" "$(grep '^transition' "$STUB_LOG")" "transition HIMMEL-9001 In Progress"

# --- 6. Jira failure never blocks --------------------------------------------
: > "$STUB_LOG"; rc=0
STUB_GET_FAIL=1 STUB_STATUS="To Do" bash "$APPEND" "$d" "LIVE — again" >"$tmp/out" 2>&1 || rc=$?
check "6: get failure -> append rc 0" "$rc" 0
contains "6: get failure warns" "$(cat "$tmp/out")" "WARN"
contains "6: bullet still landed" "$(tail -n 1 "$d")" "LIVE — again"
rc=0
STUB_TRANSITION_FAIL=1 STUB_STATUS="To Do" bash "$SUT" HIMMEL-9001 "In Progress" >"$tmp/out" 2>&1 || rc=$?
check "6: transition failure -> rc 0" "$rc" 0
contains "6: transition failure warns" "$(cat "$tmp/out")" "WARN"

# --- 7. no ticket in the doc name ---------------------------------------------
d7="$tmp/plain.md"; mkdoc "$d7"; : > "$STUB_LOG"
STUB_STATUS="To Do" bash "$APPEND" "$d7" "LIVE — x" >/dev/null 2>&1
check "7: no ticket in doc name -> no Jira call" "$(wc -c < "$STUB_LOG" | tr -d ' ')" 0

# --- 8. opt-out ----------------------------------------------------------------
: > "$STUB_LOG"
LEG_JIRA_STATUS=0 STUB_STATUS="To Do" bash "$APPEND" "$d" "LIVE — y" >/dev/null 2>&1
check "8: LEG_JIRA_STATUS=0 -> no Jira call" "$(wc -c < "$STUB_LOG" | tr -d ' ')" 0

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
