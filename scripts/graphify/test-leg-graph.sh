#!/usr/bin/env bash
# test-leg-graph.sh — leg-graph.sh points graphify at the PRIMARY
# checkout's graphify-out/ from a linked worktree, passes `path` through, and says so
# when the graph is behind the worktree. A graphify stub on PATH echoes what it
# was given, so no real graph is needed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/leg-graph.sh"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/leg-graph-test.XXXXXX")" || exit 1
# the script under test prints physical paths; macOS's /tmp is a symlink to /private/tmp
T="$(cd "$T" && pwd -P)" || exit 1
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
P="$T/primary"
git init -q -b main "$P"
git -C "$P" commit -q --allow-empty -m base
BASE="$(git -C "$P" rev-parse HEAD)"
mkdir -p "$P/graphify-out"
printf '{"nodes":[],"built_at_commit": "%s"}\n' "$BASE" > "$P/graphify-out/graph.json"
git -C "$P" worktree add -q -b leg "$T/wt"
mkdir -p "$T/bin"
# shellcheck disable=SC2016  # the stub's own $-expansions must stay literal
printf '#!/bin/sh\n[ "$1" = --help ] && { echo "  --rationale"; exit 0; }\necho "STUB GRAPHIFY_OUT=$GRAPHIFY_OUT ARGS=$*"\n' > "$T/bin/graphify"
chmod +x "$T/bin/graphify"
run() { (cd "$T/wt" && PATH="$T/bin:$PATH" bash "$SCRIPT" "$@" 2>"$T/err"); }

# T1: query from the worktree resolves to the primary's graphify-out.
out="$(run query "what is X")"; rc=$?
if [ "$rc" = 0 ] && [ "$out" = "STUB GRAPHIFY_OUT=$P/graphify-out ARGS=query what is X --rationale --budget 8000" ]; then
  pass "T1 query from a worktree targets the primary graph"
else fail "T1 rc=$rc out='$out'"; fi

# T1b: a graphify whose help lacks --rationale gets the question unchanged (no flag it would misread).
# shellcheck disable=SC2016  # the stub's own $-expansions must stay literal
printf '#!/bin/sh\n[ "$1" = --help ] && { echo "usage: graphify query"; exit 0; }\necho "STUB ARGS=$*"\n' > "$T/bin/graphify.old"
cp "$T/bin/graphify" "$T/bin/graphify.new"; cp "$T/bin/graphify.old" "$T/bin/graphify"
out="$(run query "what is X")"
if [ "$out" = "STUB ARGS=query what is X --budget 8000" ]; then pass "T1b no --rationale for a graphify without it"
else fail "T1b out='$out'"; fi
cp "$T/bin/graphify.new" "$T/bin/graphify"

# T1c-T1e: a hung graphify must not hang the wrapper. An outer timeout makes a missing bound fail the row, not the suite.
# shellcheck source=../lib/timeout-bin.sh
. "$HERE/../lib/timeout-bin.sh" 2>/dev/null
if [ -n "${_TIMEOUT_BIN:-}" ]; then
  hrun() { (cd "$T/wt" && PATH="$T/bin:$PATH" "$_TIMEOUT_BIN" -k 2 25 bash "$SCRIPT" "$@" 2>"$T/err"); }
  # shellcheck disable=SC2016  # the stub's own $-expansions must stay literal
  printf '#!/bin/sh\n[ "$1" = --help ] && { echo "$GRAPHIFY_NO_AUTO_REFRESH" > "%s/probe-env"; sleep 40; exit 0; }\necho "STUB ARGS=$*"\n' "$T" > "$T/bin/graphify"
  out="$(GRAPH_WRAP_PROBE_SECS=1 hrun query "what is X")"; rc=$?
  if [ "$rc" = 0 ] && [ "$out" = "STUB ARGS=query what is X --budget 8000" ]; then pass "T1c a hung --help probe is cut off and the query still runs"
  else fail "T1c rc=$rc out='$out'"; fi
  if [ "$(cat "$T/probe-env" 2>/dev/null)" = 1 ]; then pass "T1d the probe runs with GRAPHIFY_NO_AUTO_REFRESH=1"
  else fail "T1d probe env='$(cat "$T/probe-env" 2>/dev/null)'"; fi
  # shellcheck disable=SC2016  # the stub's own $-expansions must stay literal
  printf '#!/bin/sh\n[ "$1" = --help ] && { echo "  --rationale"; exit 0; }\nsleep 40\n' > "$T/bin/graphify"
  out="$(GRAPH_WRAP_CALL_SECS=1 hrun query "what is X")"; rc=$?
  if [ "$rc" = 124 ] && grep -q 'was stopped' "$T/err"; then pass "T1e a hung graphify call is cut off and reported"
  else fail "T1e rc=$rc err='$(cat "$T/err")'"; fi
else
  echo "  skip: T1c-T1e (no GNU timeout)"
fi
cp "$T/bin/graphify.new" "$T/bin/graphify"

# T2: graph at the worktree's HEAD → no staleness note.
if ! grep -q behind "$T/err"; then pass "T2 current graph prints no staleness note"
else fail "T2 unexpected note: $(cat "$T/err")"; fi

# T3: worktree two commits ahead of the graph → note names the count.
git -C "$T/wt" commit -q --allow-empty -m a
git -C "$T/wt" commit -q --allow-empty -m b
run explain "Y" >/dev/null
if grep -q '2 commits behind' "$T/err"; then pass "T3 stale graph says how far behind"
else fail "T3 no staleness note: $(cat "$T/err")"; fi

# T4: `path` on a cross-file pair reaches graphify against the primary graph
# (harden-graph.py merges one entity across files into one node).
out="$(run path "docs/a.md" "check.sh")"; rc=$?
if [ "$rc" = 0 ] && [ "$out" = "STUB GRAPHIFY_OUT=$P/graphify-out ARGS=path docs/a.md check.sh --budget 8000" ]; then
  pass "T4 path on a cross-file pair runs against the primary graph"
else fail "T4 rc=$rc out='$out'"; fi

# T5: missing graph → exit 2, says so, never silent.
mv "$P/graphify-out/graph.json" "$P/graphify-out/graph.json.x"
run query q >/dev/null; rc=$?
if [ "$rc" = 2 ] && grep -q 'no graph' "$T/err"; then pass "T5 missing graph is loud"
else fail "T5 rc=$rc err=$(cat "$T/err")"; fi

# T6: a larger default --budget is passed; an explicit --budget wins.
mv "$P/graphify-out/graph.json.x" "$P/graphify-out/graph.json"
out="$(run query "q")"
if grep -q -- '--budget [0-9]\{4,\}' <<<"$out"; then pass "T6 default budget is raised"
else fail "T6 out='$out'"; fi
out="$(run query "q" --budget 123)"
if grep -q -- '--budget 123$' <<<"$out" && ! grep -q -- '--budget [0-9]* .*--budget' <<<"$out"; then pass "T6b explicit --budget is respected"
else fail "T6b out='$out'"; fi

out="$(run query "q" --budget=123)"
if grep -q -- '--budget=123$' <<<"$out" && ! grep -q -- '--budget 8000' <<<"$out"; then pass "T6c --budget=N is respected"
else fail "T6c out='$out'"; fi

# T7: a truncated answer gets an explicit re-run line naming the wrapper.
# shellcheck disable=SC2016  # the stub's own $-expansions must stay literal
printf '#!/bin/sh\n[ "$1" = --help ] && { echo "  --rationale"; exit 0; }\necho "[!] TRUNCATED: showing 60 of 223 nodes (~2000-token budget). raise the token budget to 7523 to get all 223 (CLI: --budget 7523)"\necho "NODE a"\n' > "$T/bin/graphify"
out="$(run query "two words")"; rc=$?
if [ "$rc" = 0 ] && grep -q 'NODE a' <<<"$out" && grep -q 'bash scripts/graphify/leg-graph.sh query '"'"'two words'"'"' --budget 7523' "$T/err"; then
  pass "T7 truncation prints a re-run line"
else fail "T7 rc=$rc err=$(cat "$T/err")"; fi

# shellcheck disable=SC2016  # the metacharacters must reach the wrapper literally
out="$(run query 'a$(x)b')"
if grep -qF "query 'a\$(x)b' --budget 7523" "$T/err"; then pass "T7b re-run line single-quotes shell metacharacters"
else fail "T7b err=$(cat "$T/err")"; fi

# T8: missing graph names the wrapper.
mv "$P/graphify-out/graph.json" "$P/graphify-out/graph.json.x"
run query q >/dev/null
if grep -q 'leg-graph.sh' "$T/err"; then pass "T8 missing-graph message names leg-graph.sh"
else fail "T8 err=$(cat "$T/err")"; fi

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
