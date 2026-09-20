#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/test-agg-burn.sh - RED/GREEN suite for
# agg-burn.sh (HIMMEL-2977 P0 script shipped in #689 with no paired test;
# HIMMEL-2981). House check/contains style, per scripts/test-context-fill.sh.
#
# agg-burn.sh flags/branches covered:
#   --since (required, exit 2 if missing/bad)
#   --until (optional, exit 2 if bad)
#   unknown argument -> exit 2
#   SCORECARD_PROJECTS_DIR missing -> exit 2
#   since-window: last_epoch >= SINCE_EPOCH is the inclusive lower edge
#   until-window: first_epoch >= UNTIL_EPOCH is the exclusive upper edge
#   role_of(): console / relay / leg / other, with relay taking precedence
#     over a title that also matches *legN* (role-relay fixture)
#   subagent parent-role lookup via ${f%/subagents/*}.jsonl
#   leg-burn.sh failure -> FAILS + WARNING on stderr, run still exits 0
#   unreadable transcript subtree/file -> exit 1 + stderr, no partial TOTAL
#     (HIMMEL-2977: find errors were swallowed by `2>/dev/null | while`)
#   TOTAL cost-eq line: price-weighted sum across every row/session
#   TOTAL cost-eq line: mixed sub-1000 (exact) and >=1000 (leg-burn.sh
#     0.1k-rounded) per-session magnitudes (HIMMEL-2991)
#
# Platform guard: no .ps1 twin, by design. POSIX bash 3.2+; it runs under
# git bash unchanged.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
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

check_contains() {
    name="$1"; haystack="$2"; needle="$3"
    case "$haystack" in
        *"$needle"*) echo "ok - $name" ;;
        *) echo "FAIL - $name: expected to contain [$needle] in [$haystack]"; fails=$((fails + 1)) ;;
    esac
}

session_count() {
    printf '%s\n' "$1" | awk -F'\t' -v role="$2" '$1==role && $2=="ALL" {print $3; found=1} END{if(!found) print 0}'
}

# --- (a) usage: missing --since -> exit 2
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/agg-burn/roles"
"$AGG_BURN" >/dev/null 2>&1
check_exit "usage: missing --since exits 2" "$?" "2"

# --- (b) usage: unknown argument -> exit 2
"$AGG_BURN" --since 2026-01-01T00:00:00Z --bogus foo >/dev/null 2>&1
check_exit "usage: unknown argument exits 2" "$?" "2"

# --- (c) usage: missing transcript root dir -> exit 2
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/agg-burn/does-not-exist"
"$AGG_BURN" --since 2026-01-01T00:00:00Z >/dev/null 2>&1
check_exit "usage: missing SCORECARD_PROJECTS_DIR exits 2" "$?" "2"

# --- (d) since-edge: last_epoch >= SINCE_EPOCH is inclusive
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/agg-burn/since-edge"
SINCE_OUT=$("$AGG_BURN" --since 2026-09-05T00:00:00Z 2>/dev/null)
check_exit "since-edge: exits 0" "$?" "0"
check "since-edge: only the session whose last activity is exactly at --since is included" \
    "$(session_count "$SINCE_OUT" leg)" "1"

# --- (e) until-edge: first_epoch >= UNTIL_EPOCH is exclusive
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/agg-burn/until-edge"
UNTIL_OUT=$("$AGG_BURN" --since 2026-01-01T00:00:00Z --until 2026-09-06T00:00:00Z 2>/dev/null)
check_exit "until-edge: exits 0" "$?" "0"
check "until-edge: a session whose first activity is exactly at --until is excluded" \
    "$(session_count "$UNTIL_OUT" leg)" "1"

# --- (f) role classification, incl. subagent parent-role lookup
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/agg-burn/roles"
ROLES_OUT=$("$AGG_BURN" --since 2026-01-01T00:00:00Z 2>/dev/null)
check_exit "roles: exits 0" "$?" "0"
check "roles: a -console- title is classified console" \
    "$(session_count "$ROLES_OUT" console)" "1"
check "roles: a title matching none of console/relay/legN is classified other" \
    "$(session_count "$ROLES_OUT" other)" "1"
check "roles: a legN title (non-subagent) is classified leg" \
    "$(session_count "$ROLES_OUT" leg)" "1"
check "roles: a subagent transcript is tagged with its parent's leg role" \
    "$(session_count "$ROLES_OUT" 'subagent(leg)')" "1"

# --- (g) relay precedence: a title matching both *legN* and *-relay* is
# classified relay, never leg (reuses test-scorecard.sh's role-relay fixture)
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/role-relay"
RELAY_OUT=$("$AGG_BURN" --since 2026-01-01T00:00:00Z 2>/dev/null)
check_exit "role-relay: exits 0" "$?" "0"
check "role-relay: a legN+relay title is classified relay" \
    "$(session_count "$RELAY_OUT" relay)" "1"
check "role-relay: a legN+relay title is not also counted into leg" \
    "$(session_count "$RELAY_OUT" leg)" "0"

# --- (h) leg-burn.sh failure -> FAILS + WARNING, run still exits 0
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/agg-burn/malformed"
MALFORMED_ERR=$("$AGG_BURN" --since 2026-01-01T00:00:00Z 2>&1 >/dev/null)
MALFORMED_OUT=$("$AGG_BURN" --since 2026-01-01T00:00:00Z 2>/dev/null)
MALFORMED_EXIT=$?
check_contains "malformed: a leg-burn.sh failure prints a skip WARNING" \
    "$MALFORMED_ERR" "WARNING: 1 transcript(s) skipped due to leg-burn.sh failure"
check_exit "malformed: a skipped transcript still exits 0" "$MALFORMED_EXIT" "0"
check "malformed: TOTAL line is all-zero with no surviving rows" \
    "$(printf '%s\n' "$MALFORMED_OUT" | grep '^TOTAL cache-read=')" \
    "TOTAL cache-read=0.0k cache-create=0.0k input=0.0k output=0.0k cost-eq=0.0k"

# --- (i) HIMMEL-2987: TOTAL cost-eq line aggregates across sessions.
# session-a: 2 calls x (input=1000,cache_read=3000,cache_creation=500,output=200)
# session-b: 3 calls x (input=500,cache_read=1000,cache_creation=0,output=100)
# -> input=3.5k cache-read=9.0k cache-create=1.0k output=0.7k
#    cost-eq = 3500*1 + 9000*0.1 + 1000*1.25 + 700*5 = 9150 -> "9.2k"
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/agg-burn/totals"
TOTALS_OUT=$("$AGG_BURN" --since 2026-01-01T00:00:00Z 2>/dev/null)
check_exit "totals: exits 0" "$?" "0"
check "totals: cross-session TOTAL cost-eq line" \
    "$(printf '%s\n' "$TOTALS_OUT" | grep '^TOTAL cache-read=')" \
    "TOTAL cache-read=9.0k cache-create=1.0k input=3.5k output=0.7k cost-eq=9.2k"

# --- (j) HIMMEL-2996: TOTAL sums mix sub-1000 (exact) and >=1000 per-session
# magnitudes and must sum the EXACT raw counts (leg-burn.sh --raw), not
# per-session 0.1k-rounded values - this is the RED HIMMEL-2991 could not
# construct (its brute force over rounding boundaries found 0 mismatches;
# this fixture is a targeted counter-example).
# session-small (1 call, all <1000, exact):        input=234  cache_read=567  cache_creation=89   output=345
# session-large-exact (2 calls x 800/900/700/600):  input=1600 cache_read=1800 cache_creation=1400 output=1200
# session-large-rounded (1 call, all >=1000):        input=2345 cache_read=3456 cache_creation=1234 output=4567
#
# OLD (wrong) path - leg-burn.sh's kf() rounds a >=1000 session to 0.1k before
# agg-burn.sh ever sees it (input 2.345->2.3k, cache_read 3.456->3.5k,
# cache_creation 1.234->1.2k, output 4.567->4.6k), then sums the k-units:
#   input        = 0.234 + 1.600 + 2.3 = 4.134 -> 4.1k  (true: 4.179 -> 4.2k)
#   cache-read   = 0.567 + 1.800 + 3.5 = 5.867 -> 5.9k  (true: 5.823 -> 5.8k)
# NEW (raw) path - sum the exact raw integers once, divide by 1000 once:
#   input      = 234 + 1600 + 2345 = 4179 -> 4.179 -> 4.2k
#   cache-read = 567 + 1800 + 3456 = 5823 -> 5.823 -> 5.8k
#   cache-create = 89 + 1400 + 1234 = 2723 -> 2.723 -> 2.7k
#   output     = 345 + 1200 + 4567 = 6112 -> 6.112 -> 6.1k
#   cost-eq = 4179*1 + 5823*0.1 + 2723*1.25 + 6112*5 = 38725.05 -> 38.7k
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/agg-burn/totals-mixed"
MIXED_OUT=$("$AGG_BURN" --since 2026-01-01T00:00:00Z 2>/dev/null)
check_exit "totals-mixed: exits 0" "$?" "0"
check "totals-mixed: TOTAL line sums exact raw counts, not per-session rounded" \
    "$(printf '%s\n' "$MIXED_OUT" | grep '^TOTAL cache-read=')" \
    "TOTAL cache-read=5.8k cache-create=2.7k input=4.2k output=6.1k cost-eq=38.7k"

# --- (k) HIMMEL-2977: an unreadable subtree / transcript must FAIL LOUDLY, not
# yield a successful-looking partial total. Before this fix `find ... 2>/dev/null
# | while` swallowed find's permission errors AND its exit status, so a readable
# sibling alone produced exit 0 and a TOTAL that silently omitted the rest (the
# same shape as a coverage gap: a number that looks complete and is not).
# The fixture makes ONE specific subtree/file unreadable (not the whole root), and
# each case asserts its own precondition first: a blanket failure (read-only
# TMPDIR, unreadable root) or a root user (chmod 000 does not bind uid 0) would be a
# VACUOUS control, so the case is SKIPPED, never passed, when the precondition fails.
UNR_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agg-burn-unreadable.XXXXXX") || { echo "FAIL - mktemp -d"; exit 1; }
trap 'chmod -R u+rwx "$UNR_ROOT" 2>/dev/null; rm -rf "$UNR_ROOT"' EXIT

unr_fixture() {
    rm -rf "${UNR_ROOT:?}"/* 2>/dev/null
    mkdir -p "$UNR_ROOT/readable" "$UNR_ROOT/other"
    cp "$HERE/fixtures/agg-burn/totals/session-a.jsonl" "$UNR_ROOT/readable/"
    cp "$HERE/fixtures/agg-burn/totals/session-b.jsonl" "$UNR_ROOT/other/"
}

# Precondition: the ONE locked path fails discovery/reading, the readable sibling
# is still discovered, and a run over the unlocked fixture succeeds (control).
unr_case() {
    label="$1"; lock="$2"; want_err="$3"
    unr_fixture
    export SCORECARD_PROJECTS_DIR="$UNR_ROOT"
    CONTROL_OUT=$("$AGG_BURN" --since 2026-01-01T00:00:00Z 2>/dev/null)
    check_exit "$label control: unlocked fixture exits 0" "$?" "0"
    check "$label control: both sessions counted" \
        "$(session_count "$CONTROL_OUT" TOTAL)" "2"
    chmod 000 "$lock"
    if [ -r "$lock" ] && [ -x "$lock" ]; then
        echo "SKIP - $label: chmod 000 does not bind this user (uid $(id -u)); precondition not met"
        chmod u+rwx "$lock"; return 0
    fi
    check_contains "$label precondition: readable sibling is still discovered" \
        "$(find "$UNR_ROOT" -name '*.jsonl' -type f 2>/dev/null)" "readable/session-a.jsonl"
    UNR_OUT=$("$AGG_BURN" --since 2026-01-01T00:00:00Z 2>"$UNR_ROOT/stderr"); UNR_EXIT=$?
    UNR_ERR=$(cat "$UNR_ROOT/stderr")
    chmod u+rwx "$lock"
    check_exit "$label: exits non-zero (1), not a successful-looking partial run" "$UNR_EXIT" "1"
    check_contains "$label: stderr names the unreadable path" "$UNR_ERR" "$want_err"
    check "$label: no TOTAL line on stdout (a partial total must not be consumable)" \
        "$(printf '%s\n' "$UNR_OUT" | grep -c '^TOTAL cache-read=')" "0"
}

# (k1) an unreadable transcript SUBTREE: find cannot descend into other/.
unr_case "unreadable-subtree" "$UNR_ROOT/other" "other"
# (k2) an unreadable transcript FILE: find lists it, grep on it fails silently.
unr_case "unreadable-file" "$UNR_ROOT/other/session-b.jsonl" "session-b.jsonl"

echo "---"
if [ "$fails" -eq 0 ]; then
    echo "PASS - test-agg-burn.sh: 0 failures"
    exit 0
else
    echo "FAIL - test-agg-burn.sh: $fails failure(s)"
    exit 1
fi
