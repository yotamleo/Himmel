#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/test-scorecard.sh - RED/GREEN suite for
# agg-postpin.sh's --exclude-straddle, --cohort and counted_shifts column
# (HIMMEL-2977 Task 3 Step 2). House check/contains style, per
# scripts/test-context-fill.sh.
#
# Platform guard: no .ps1 twin, by design. POSIX bash 3.2+; it runs under
# git bash unchanged.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
POSTPIN="$HERE/agg-postpin.sh"
AGG_BURN="$HERE/agg-burn.sh"
fails=0

check() {
    name="$1"; actual="$2"; expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "ok - $name"
    else
        echo "FAIL - $name: expected [$expected] got [$actual]"
        fails=$((fails + 1))
    fi
}

check_exit() {
    name="$1"; actual="$2"; expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "ok - $name"
    else
        echo "FAIL - $name: expected exit [$expected] got [$actual]"
        fails=$((fails + 1))
    fi
}

session_count() {
    # the role's "ALL"-model row already carries the total session count
    # in the sessions column (field 3) - read it directly.
    printf '%s\n' "$1" | awk -F'\t' -v role="$2" '$1==role && $2=="ALL" {print $3; found=1} END{if(!found) print 0}'
}

# --- (a) straddle: before/after/straddling fixtures, T = 2026-09-03T00:00:00Z
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/straddle"
unset SCORECARD_LAUNCH_LOG_DIR

WITHOUT_STRADDLE=$("$POSTPIN" --since 2026-09-03T00:00:00Z --role leg 2>/dev/null)
check "straddle: without --exclude-straddle counts 2 sessions" \
    "$(session_count "$WITHOUT_STRADDLE" leg)" "2"

WITH_STRADDLE=$("$POSTPIN" --since 2026-09-03T00:00:00Z --exclude-straddle 2026-09-03T00:00:00Z --role leg 2>/dev/null)
check "straddle: with --exclude-straddle counts 1 session" \
    "$(session_count "$WITH_STRADDLE" leg)" "1"

# --- (b) cohort: leg-impl pair, --cohort counts 1 of 2
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/cohort"
export SCORECARD_LAUNCH_LOG_DIR="$HERE/fixtures/cohort/launch-logs"

WITHOUT_COHORT=$("$POSTPIN" --since 2026-01-01T00:00:00Z --role leg 2>/dev/null)
check "cohort: without --cohort counts 3 sessions" \
    "$(session_count "$WITHOUT_COHORT" leg)" "3"

WITH_COHORT=$("$POSTPIN" --since 2026-01-01T00:00:00Z --role leg --cohort leg-impl 2>/dev/null)
check "cohort: --cohort leg-impl counts 1 of 3 (excludes no-log and leg-impl-other)" \
    "$(session_count "$WITH_COHORT" leg)" "1"

# --- (b2) cohort-substring: a launch-log line whose field is a DIFFERENT
# key that merely contains "profile=leg-impl" as a substring
# (other-profile=leg-impl) must NOT match --cohort leg-impl (HIMMEL-2977
# /pr-check codex-8 fix: exact-field match via awk, not substring grep).
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/cohort-substring"
export SCORECARD_LAUNCH_LOG_DIR="$HERE/fixtures/cohort-substring/launch-logs"

SUBSTRING_COHORT=$("$POSTPIN" --since 2026-01-01T00:00:00Z --role leg --cohort leg-impl 2>/dev/null)
check "cohort-substring: other-profile=leg-impl does not false-positive match --cohort leg-impl" \
    "$(session_count "$SUBSTRING_COHORT" leg)" "0"

# --- (c) shift: 60 Fable + 50 Sonnet console-role calls -> counted_shifts=1
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/shift"
unset SCORECARD_LAUNCH_LOG_DIR

SHIFT_OUT=$("$POSTPIN" --since 2026-01-01T00:00:00Z --role console 2>/dev/null)
COUNTED=$(printf '%s\n' "$SHIFT_OUT" | awk -F'\t' '$1=="console" && $2=="ALL" {print $NF}')
check "shift: >=100 console-role calls -> counted_shifts=1" "$COUNTED" "1"

# --- (d) shift: 10 console-role calls (< 100) -> counted_shifts=0, disproving
# a hardcoded counted_shifts=1
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/shift-under"
unset SCORECARD_LAUNCH_LOG_DIR

SHIFT_UNDER_OUT=$("$POSTPIN" --since 2026-01-01T00:00:00Z --role console 2>/dev/null)
COUNTED_UNDER=$(printf '%s\n' "$SHIFT_UNDER_OUT" | awk -F'\t' '$1=="console" && $2=="ALL" {print $NF}')
check "shift: <100 console-role calls -> counted_shifts=0" "$COUNTED_UNDER" "0"

# --- (e0) role-relay: a title matching both *legN* and *-relay* must be
# classified as relay, not leg (HIMMEL-2977 /pr-check round-3 codex-6 fix:
# role_of() here lacked the *-relay* branch agg-burn.sh's role_of() has, so
# this file - restricted to role in {leg, console} - would have counted a
# relay session into the leg cohort).
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/role-relay"
unset SCORECARD_LAUNCH_LOG_DIR

ROLE_RELAY_OUT=$("$POSTPIN" --since 2026-01-01T00:00:00Z --role leg 2>/dev/null)
check "role-relay: a legN+relay title is not counted into the leg cohort" \
    "$(session_count "$ROLE_RELAY_OUT" leg)" "0"

# --- (e) exit-contract: a successful run (zero leg-burn failures) must exit 0
# (HIMMEL-2977 /pr-check round-3 codex-1/codex-4 fix: `[ cond ] && echo` as the
# last statement made a clean run's own exit code depend on the warning firing).
"$POSTPIN" --since 2026-01-01T00:00:00Z --role console >/dev/null 2>&1
check_exit "exit-contract: a run with zero leg-burn failures exits 0" "$?" "0"

# --- (f) HIMMEL-2987: agg-burn.sh's TOTAL line carries the price-weighted
# cost-eq split. Reuses the existing shift/ fixture (110 assistant calls, all
# input=100/cache_read=0/cache_creation=0/output=5, per leg-burn.sh directly):
#   input=11.0k output=0.55k->0.6k cache-read=0.0k cache-create=0.0k
#   cost-eq = 11000*1 + 0*0.1 + 0*1.25 + 550*5 = 13750 -> "13.8k"
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/shift"
unset SCORECARD_LAUNCH_LOG_DIR

BURN_TOTAL=$("$AGG_BURN" --since 2026-01-01T00:00:00Z 2>/dev/null | grep '^TOTAL cache-read=')
check "agg-burn TOTAL: price-weighted cost-eq line" "$BURN_TOTAL" \
    "TOTAL cache-read=0.0k cache-create=0.0k input=11.0k output=0.6k cost-eq=13.8k"

# env override: output weight 5 -> 1 must move cost-eq (pins the weight is
# read from env in agg-burn.sh too, not just leg-burn.sh)
# 11000*1 + 0*0.1 + 0*1.25 + 550*1 = 11550 -> "11.6k"
BURN_TOTAL_OVERRIDE=$(LEG_BURN_W_OUTPUT=1 "$AGG_BURN" --since 2026-01-01T00:00:00Z 2>/dev/null | grep -o 'cost-eq=[^ ]*$')
check "agg-burn TOTAL: output weight override changes cost-eq" \
    "$BURN_TOTAL_OVERRIDE" "cost-eq=11.6k"

echo "---"
if [ "$fails" -eq 0 ]; then
    echo "PASS - test-scorecard.sh: 0 failures"
    exit 0
else
    echo "FAIL - test-scorecard.sh: $fails failure(s)"
    exit 1
fi
