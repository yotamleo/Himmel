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

# --- (g) HIMMEL-2975 Task 29: ready-go-latency.sh. Fixtures are built at run
# time; GO-file mtimes are set with `touch -t` (BSD-portable, unlike
# `touch -d`) under TZ=UTC. The handover root (and so .locks/go) is pinned
# with HANDOVER_DIR, never the live one.
RGL="$HERE/ready-go-latency.sh"
RGL_TMP=$(mktemp -d "${TMPDIR:-/tmp}/rgl-test.XXXXXX") || { echo "FAIL - mktemp"; exit 1; }
trap 'rm -rf "$RGL_TMP"' EXIT

# mkgo <root> <pr> <sha> <CCYYMMDDhhmm>
mkgo() {
    mkdir -p "$1/.locks/go"
    : > "$1/.locks/go/$2.$3"
    TZ=UTC touch -t "$4" "$1/.locks/go/$2.$3"
}

# g1: the day-2026-10-01 table, READY_GO_NOW = 2026-10-01T12:00:00Z
mkdir -p "$RGL_TMP/g1"
cat > "$RGL_TMP/g1/console-2026-10-01.md" <<'EOF'
# console

- 09:00 READY 77 aaaaaaa
- 09:30 READY 81 fffffff
- 10:00 READY 78 bbbbbbb
- 10:05 READY 78 ccccccc
- 10:10 READY 79 ddddddd
- 10:20 READY 80 eeeeeee
- 10:30 READY 83 7654321
- 10:40 HOLD 79 waiting on CR
- 11:01 READY 82 1234567
EOF
mkgo "$RGL_TMP/g1" 77 aaaaaaa 202610010912
mkgo "$RGL_TMP/g1" 81 fffffff 202610010950
mkgo "$RGL_TMP/g1" 78 ccccccc 202610011030
mkgo "$RGL_TMP/g1" 83 7654321 202610011130
G1_OUT=$(TZ=UTC HANDOVER_DIR="$RGL_TMP/g1" READY_GO_NOW=1790856000 "$RGL" --doc "$RGL_TMP/g1/console-2026-10-01.md" --since 2026-10-01T00:00:00Z 2>&1)
check "rgl g1: events/median/missed summary" "$(printf '%s\n' "$G1_OUT" | head -1)" "events=4 median_min=22.5 missed=1"
check "rgl g1: exactly one MISSED line (80 eeeeeee 10:20)" "$(printf '%s\n' "$G1_OUT" | grep '^MISSED')" "MISSED 80 eeeeeee 10:20"

# g2: midnight crossing, READY_GO_NOW = 2026-10-02T03:00:00Z
mkdir -p "$RGL_TMP/g2"
cat > "$RGL_TMP/g2/console-2026-10-01.md" <<'EOF'
- 22:00 READY 90 9999999
- 23:40 READY 91 1111111
- 00:30 READY 92 2222222
EOF
mkgo "$RGL_TMP/g2" 90 9999999 202610012210
mkgo "$RGL_TMP/g2" 91 1111111 202610020010
G2_DOC="$RGL_TMP/g2/console-2026-10-01.md"
G2_SINCE=$(TZ=UTC HANDOVER_DIR="$RGL_TMP/g2" READY_GO_NOW=1790910000 "$RGL" --doc "$G2_DOC" --since 2026-10-01T23:00:00Z 2>&1)
check "rgl g2: --since 23:00Z excludes READY 90" "$(printf '%s\n' "$G2_SINCE" | head -1)" "events=1 median_min=30 missed=1"
G2_ALL=$(TZ=UTC HANDOVER_DIR="$RGL_TMP/g2" READY_GO_NOW=1790910000 "$RGL" --doc "$G2_DOC" 2>&1)
check "rgl g2: no --since counts both GO'd READYs" "$(printf '%s\n' "$G2_ALL" | head -1)" "events=2 median_min=20 missed=1"
check "rgl g2: reconstructed MISSED stamp is 00:30" "$(printf '%s\n' "$G2_ALL" | grep '^MISSED')" "MISSED 92 2222222 00:30"
G2_UNTIL=$(TZ=UTC HANDOVER_DIR="$RGL_TMP/g2" READY_GO_NOW=1790910000 "$RGL" --doc "$G2_DOC" --until 2026-10-01T23:00:00Z 2>&1)
check "rgl g2: --until 23:00Z keeps only READY 90" "$(printf '%s\n' "$G2_UNTIL" | head -1)" "events=1 median_min=10 missed=0"

# g3: real GO files carry the full 40-char sha; a 7-char READY matches by prefix
mkdir -p "$RGL_TMP/g3"
printf '%s\n' '- 09:00 READY 93 abcdef1' '- 09:05 READY 94 abcdef1' > "$RGL_TMP/g3/console-2026-10-01.md"
mkgo "$RGL_TMP/g3" 93 abcdef1234567890abcdef1234567890abcdef12 202610010915
mkgo "$RGL_TMP/g3" 94 fedcba9234567890abcdef1234567890abcdef12 202610010915
G3_OUT=$(TZ=UTC HANDOVER_DIR="$RGL_TMP/g3" READY_GO_NOW=1790856000 "$RGL" --doc "$RGL_TMP/g3/console-2026-10-01.md" --since 2026-10-01T00:00:00Z 2>&1)
check "rgl g3: 40-char GO matches a 7-char READY; a different-prefix GO does not" \
    "$(printf '%s\n' "$G3_OUT" | tr '\n' '|')" "events=1 median_min=15 missed=1|MISSED 94 abcdef1 09:05|"

# g4: no bullets -> zero events, and missing --doc is a usage error (rc 2)
mkdir -p "$RGL_TMP/g4"
printf '%s\n' '# nothing to see' > "$RGL_TMP/g4/console-2026-10-01.md"
G4_OUT=$(TZ=UTC HANDOVER_DIR="$RGL_TMP/g4" READY_GO_NOW=1790856000 "$RGL" --doc "$RGL_TMP/g4/console-2026-10-01.md" --since 2026-10-01T00:00:00Z 2>&1)
check "rgl g4: no READY bullets -> events=0" "$G4_OUT" "events=0 median_min=n/a missed=0"
HANDOVER_DIR="$RGL_TMP/g4" "$RGL" --since 2026-10-01T00:00:00Z >/dev/null 2>&1
check_exit "rgl g4: missing --doc exits 2" "$?" "2"

echo "---"
if [ "$fails" -eq 0 ]; then
    echo "PASS - test-scorecard.sh: 0 failures"
    exit 0
else
    echo "FAIL - test-scorecard.sh: $fails failure(s)"
    exit 1
fi
