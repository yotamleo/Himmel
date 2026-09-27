#!/usr/bin/env bash
# test-graph-out-root.sh — HIMMEL-3718: the one resolver every in-tree reader
# of luna's graph must share (graph-refresh.sh, graphmap-cadence.sh), so the
# out-of-corpus destination is a single fact, not N copies of a path.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$HERE/graph-out-root.sh"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

# T1: luna resolves to a default under $HOME when no override is configured.
# shellcheck source=/dev/null
out=$( (unset GRAPHIFY_LUNA_OUT_ROOT; HOME="/tmp/t-graph-out-root-home"; . "$RESOLVER"; graphify_out_root_for luna) )
if [ "$out" = "/tmp/t-graph-out-root-home/.local/share/himmel/graphify/luna" ]; then
  pass "T1 luna default resolves under \$HOME/.local/share/himmel/graphify/luna"
else
  fail "T1 luna default resolved to '$out'"
fi

# T2: GRAPHIFY_LUNA_OUT_ROOT is a test/operator seam that overrides the default.
# shellcheck source=/dev/null
out=$( GRAPHIFY_LUNA_OUT_ROOT="/tmp/t-graph-out-root-override" bash -c ". \"$RESOLVER\"; graphify_out_root_for luna" )
if [ "$out" = "/tmp/t-graph-out-root-override" ]; then
  pass "T2 GRAPHIFY_LUNA_OUT_ROOT overrides the default"
else
  fail "T2 override resolved to '$out'"
fi

# T3: himmel's own corpus stays in-corpus (empty = no override) -- its
# graphify-out/ is a tracked, shared artifact (HIMMEL-1123).
# shellcheck source=/dev/null
out=$( bash -c ". \"$RESOLVER\"; graphify_out_root_for himmel" )
if [ -z "$out" ]; then
  pass "T3 himmel resolves to empty (stays in-corpus)"
else
  fail "T3 himmel should resolve to empty, got '$out'"
fi

# T4: an unknown corpus name also stays in-corpus (empty), never a guess.
# shellcheck source=/dev/null
out=$( bash -c ". \"$RESOLVER\"; graphify_out_root_for some-other-corpus" )
if [ -z "$out" ]; then
  pass "T4 an unrecognised corpus resolves to empty (stays in-corpus)"
else
  fail "T4 unrecognised corpus should resolve to empty, got '$out'"
fi

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
