#!/usr/bin/env bash
# Tests for scripts/lib/dedupe-path.sh (HIMMEL-3640).
set -uo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/dedupe-path.sh"
# shellcheck source=dedupe-path.sh
# shellcheck disable=SC1091
. "$LIB"

FAILED=0
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label — expected '$expected', got '$actual'"
        FAILED=$((FAILED + 1))
    fi
}

# T1: no duplicates — unchanged, same order, same bytes (true no-op).
got=$(dedupe_path "/a:/b:/c")
assert_eq "T1 no dupes is a no-op" "/a:/b:/c" "$got"

# T2: adjacent duplicate collapsed, first occurrence's position kept.
got=$(dedupe_path "/a:/a:/b")
assert_eq "T2 adjacent dupe collapsed" "/a:/b" "$got"

# T3: non-adjacent duplicate — later repeat dropped, earlier position wins.
got=$(dedupe_path "/plugin/bin:/usr/bin:/plugin/bin:/local/bin:/plugin/bin")
assert_eq "T3 first occurrence position kept" "/plugin/bin:/usr/bin:/local/bin" "$got"

# T4: empty input — empty output.
got=$(dedupe_path "")
assert_eq "T4 empty in, empty out" "" "$got"

# T5: single entry — unchanged.
got=$(dedupe_path "/only")
assert_eq "T5 single entry unchanged" "/only" "$got"

# T6: entirely duplicate entries collapse to one.
got=$(dedupe_path "/x:/x:/x:/x")
assert_eq "T6 all-dupes collapse to one" "/x" "$got"

# T7: idempotent — deduping an already-deduped PATH changes nothing.
once=$(dedupe_path "/plugin/bin:/usr/bin:/plugin/bin")
twice=$(dedupe_path "$once")
assert_eq "T7 idempotent" "$once" "$twice"

# T8 (RED for HIMMEL-3640): simulated N-hop nesting. Each hop mimics Claude
# Code's own one-time-per-start plugin-bin injection — unconditionally
# prepending the plugin bins onto whatever PATH it inherited, with no check
# for an existing copy. WITHOUT the fix, each himmel-driven hop hands the
# next hop its own already-doubled PATH as the new inherited baseline, so
# the duplicate count grows with the number of hops (unbounded, matching
# N522's 25x in a long session). WITH the fix — dedupe_path called on the
# inherited PATH at each himmel launch chokepoint, right before the next
# hop's injection — every hop starts from a clean baseline, so the
# duplicate count stays flat at the single upstream-added copy no matter
# how many hops run.
PLUGIN_BINS="/plugins/a/bin:/plugins/b/bin:/plugins/c/bin"
BASE_PATH="/usr/bin:/bin"

claude_start_inject() {  # $1 = inherited PATH — simulates Claude Code's own injection
    printf '%s:%s' "$PLUGIN_BINS" "$1"
}

occurrence_count() {  # how many times $2 appears as a PATH entry of $1
    printf '%s' "$1" | tr ':' '\n' | grep -c -x -- "$2"
}

# Without the fix: N hops, each feeding its (undeduped) output straight to
# the next hop's inherited PATH — a plugin bin's occurrence count grows one
# per hop (a dupe-GROUP count would saturate after hop 2 and hide this).
undeduped="$BASE_PATH"
for _ in 1 2 3 4 5; do
    undeduped="$(claude_start_inject "$undeduped")"
done
undeduped_occurrences=$(occurrence_count "$undeduped" "/plugins/a/bin")
assert_eq "T8a without fix: 5 hops grow one plugin bin to 5 occurrences" "5" "$undeduped_occurrences"

# With the fix: dedupe the inherited PATH before each hop's injection —
# every hop starts clean, so the occurrence count stays at 1 after any
# number of hops, instead of growing without bound.
deduped="$BASE_PATH"
for _ in 1 2 3 4 5; do
    deduped="$(dedupe_path "$(claude_start_inject "$deduped")")"
done
deduped_occurrences=$(occurrence_count "$deduped" "/plugins/a/bin")
assert_eq "T8b with fix: 5 hops stay capped at 1 occurrence" "1" "$deduped_occurrences"

# T9 (RED for codex-1): a trailing empty PATH entry (PATH ending in ":",
# conventionally "look in cwd") must round-trip, not be silently dropped.
got=$(dedupe_path "/usr/bin:")
assert_eq "T9 trailing empty entry preserved" "/usr/bin:" "$got"

# T10: a leading empty PATH entry (PATH starting with ":") must also
# round-trip.
got=$(dedupe_path ":/usr/bin")
assert_eq "T10 leading empty entry preserved" ":/usr/bin" "$got"

# T11 (RED for HIMMEL-3643): a consecutive run of empty entries ("::")
# collapses to a single empty entry, same as a plain duplicate — control to
# pin existing behavior while the newline fix goes in.
got=$(dedupe_path "::")
assert_eq "T11 consecutive empty entries collapse to one" "" "$got"

NL=$'\n'
ENTRY_NL="/opt/weird${NL}dir"

# T12 (RED for HIMMEL-3643): an entry containing a literal embedded newline
# must round-trip byte-identical. awk's default RS is newline, so it tears
# this single PATH entry into two records instead of treating it as one field.
got=$(dedupe_path "/a:${ENTRY_NL}:/b")
assert_eq "T12 newline-embedded entry round-trips, no dupes" "/a:${ENTRY_NL}:/b" "$got"

# T13 (RED for HIMMEL-3643): same newline-embedded entry, plus a duplicate
# elsewhere in the PATH — first occurrence's position kept, newline entry
# still intact.
got=$(dedupe_path "/plugin/bin:${ENTRY_NL}:/plugin/bin")
assert_eq "T13 newline-embedded entry survives a duplicate elsewhere" "/plugin/bin:${ENTRY_NL}" "$got"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "All dedupe-path tests passed."
else
    echo "$FAILED dedupe-path test(s) failed."
    exit 1
fi
