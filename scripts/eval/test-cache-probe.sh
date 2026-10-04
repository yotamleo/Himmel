#!/usr/bin/env bash
# scripts/eval/test-cache-probe.sh - suite for scripts/eval/cache-probe.sh
# (HIMMEL-3837). Every scenario is a fixture directory under
# fixtures/cache-probe/<scenario>/*.jsonl plus ONE `scenario` line below; the
# fixtures carry synthetic token counts only (no transcript content). The
# scenario names are what docs/internals/prompt-cache.md's `eval:` column cites.
#
# Fixture clock: event = 2026-01-01T00:10:00Z = epoch 1767226200.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PROBE="$HERE/cache-probe.sh"
FIX="$HERE/fixtures/cache-probe"
EVENT=1767226200
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cache-probe-test.XXXXXX")" || { echo "test-cache-probe: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }

# scenario <name> <expected verdict word> <expected rc> <probe args...>
# The fixture directory's *.jsonl files are appended as the probe's file args.
scenario() {
  local name="$1" want_verdict="$2" want_rc="$3"; shift 3
  local out rc verdict
  out=$(bash "$PROBE" "$@" "$FIX/$name"/*.jsonl 2>&1); rc=$?
  verdict=$(printf '%s\n' "$out" | sed -n 's/^verdict: \([a-z-]*\).*/\1/p' | head -n 1)
  eq "$name: verdict" "$verdict" "$want_verdict"
  eq "$name: exit code" "$rc" "$want_rc"
  LAST_OUT="$out"
}

# --- invalidation: the memory-edit question ----------------------------------
scenario no-invalidation not-invalidated 0 invalidation --event "$EVENT"
has "no-invalidation: both sessions kept" "$LAST_OUT" "kept=2 invalidated=0"
has "no-invalidation: a duplicate message row is counted once" "$LAST_OUT" "b	kept	3	3"

scenario real-invalidation invalidated 1 invalidation --event "$EVENT"
has "real-invalidation: b is the invalidated session" "$LAST_OUT" "b	invalidated"
has "real-invalidation: a is still kept" "$LAST_OUT" "a	kept"

scenario compaction-lookalike inconclusive 2 invalidation --event "$EVENT"
has "compaction-lookalike: classed compacted, not invalidated" "$LAST_OUT" "a	compacted"

scenario too-few-turns inconclusive 2 invalidation --event "$EVENT"
has "too-few-turns: classed inconclusive" "$LAST_OUT" "a	inconclusive"

scenario ttl-expiry inconclusive 2 invalidation --event "$EVENT"
has "ttl-expiry: classed ttl, not invalidated" "$LAST_OUT" "a	ttl"

# An unexplained rewrite on the THIRD post-event turn is not the event's doing:
# a prefix change shows on the first turn after it, so only that one is judged.
scenario late-rewrite-unrelated not-invalidated 0 invalidation --event "$EVENT"
has "late-rewrite-unrelated: classed kept" "$LAST_OUT" "a	kept"

# A <synthetic> row (zero usage) and a row with no token fields are not turns:
# both are skipped, so the counts and means come from the six real turns only.
scenario synthetic-row-invalidation not-invalidated 0 invalidation --event "$EVENT"
has "synthetic-row-invalidation: only real turns counted" "$LAST_OUT" "session	kept	3	3	80283	316	81276	310	120"

# --- the event forms --------------------------------------------------------
scenario no-invalidation not-invalidated 0 invalidation --event 2026-01-01T00:10:00Z
: > "$TMP/event-file"
TZ=UTC touch -t 202601010010.00 "$TMP/event-file"
scenario no-invalidation not-invalidated 0 invalidation --event "@$TMP/event-file"

# --- idle-gap: the TTL question ---------------------------------------------
scenario idle-ttl-5m ttl-consistent 0 idle-gap
scenario idle-ttl-1h ttl-consistent 0 idle-gap
scenario idle-ttl-violated ttl-inconsistent 1 idle-gap
scenario idle-none inconclusive 2 idle-gap
# A boundary-less compaction inside a warm gap is not a TTL miss, and one inside a
# cold gap is not TTL evidence: both are excluded, as the invalidation mode does.
scenario idle-compaction-lookalike ttl-consistent 0 idle-gap
has "idle-compaction-lookalike: the compaction pair is excluded" "$LAST_OUT" "cold-expected=1 cold-rewrote=1 warm-expected=3 warm-rewrote=0"
# An early 1h write followed by 5m-only writes: the TTL is the last write's tier
# (300s), so a 20-minute gap that rewrote is expected-cold, not a warm miss.
scenario ttl-last-write ttl-consistent 0 idle-gap
has "ttl-last-write: the TTL comes from the last cache write" "$LAST_OUT" "session	300	2	2	3	0"

# --- first-turn: does a new session start warm ------------------------------
scenario first-turn-warm warm-start 0 first-turn
scenario first-turn-cold cold-start 1 first-turn
# A <synthetic> zero-usage row ahead of the first real request is not the first
# turn: the warm real one is.
scenario synthetic-first-turn warm-start 0 first-turn
has "synthetic-first-turn: the first real turn is counted" "$LAST_OUT" "session	warm	2	80000	300"

# --- usage errors exit 64, and never with a verdict --------------------------
out=$(bash "$PROBE" 2>&1); rc=$?
eq "no mode: usage error" "$rc" "64"
out=$(bash "$PROBE" bogus "$FIX/no-invalidation/a.jsonl" 2>&1); rc=$?
eq "unknown mode: usage error" "$rc" "64"
out=$(bash "$PROBE" invalidation "$FIX/no-invalidation/a.jsonl" 2>&1); rc=$?
eq "invalidation without --event: usage error" "$rc" "64"
out=$(bash "$PROBE" invalidation --event notatime "$FIX/no-invalidation/a.jsonl" 2>&1); rc=$?
eq "unparseable event: usage error" "$rc" "64"
out=$(bash "$PROBE" first-turn "$TMP/does-not-exist.jsonl" 2>&1); rc=$?
eq "missing file: usage error" "$rc" "64"
out=$(bash "$PROBE" invalidation --event "$EVENT" --turns 0 "$FIX/no-invalidation/a.jsonl" 2>&1); rc=$?
eq "--turns 0: usage error" "$rc" "64"
out=$(bash "$PROBE" invalidation --event "$EVENT" --min-turns 0 "$FIX/no-invalidation/a.jsonl" 2>&1); rc=$?
eq "--min-turns 0: usage error" "$rc" "64"

# --- determinism: the same input twice is byte-identical --------------------
a=$(bash "$PROBE" invalidation --event "$EVENT" "$FIX/real-invalidation"/*.jsonl)
b=$(bash "$PROBE" invalidation --event "$EVENT" "$FIX/real-invalidation"/*.jsonl)
eq "deterministic output" "$a" "$b"

echo "test-cache-probe: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
