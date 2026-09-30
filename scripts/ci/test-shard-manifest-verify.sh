#!/usr/bin/env bash
# scripts/ci/test-shard-manifest-verify.sh — scripts/ci/shard-manifest-verify.sh
# (HIMMEL-3897): the shell-unit aggregator's check that the fixed shards ran
# exactly what the base-sourced selection picked, at this head.
#
# Manifests and the aggregator's `--list .` output (disc.txt) are hand-built
# here so each case varies ONE property:
#
#   MV1   impacted, every selected suite ran once and passed    -> rc 0
#   MV2   a shard's manifest is missing                         -> rc 1
#   MV3   a manifest from another head sha                      -> rc 1
#   MV4   the shards ran fewer suites than selected             -> rc 1
#   MV5   a selected suite ran and FAILED                       -> rc 1
#   MV6   the selection says full, a shard ran impacted         -> rc 1
#   MV7   one suite ran on two shards                           -> rc 1
#   MV8   a shard ran a suite outside the selection             -> rc 1
#   MV9   a shard left a suite unrun (budget)                   -> rc 1
#   MV10  a selected suite tier-skipped (listed SKIP) is a NOTE -> rc 0
#   MV11  full mode: all green -> rc 0; one red -> rc 1
#   MV12  a manifest that claims another shard number           -> rc 1
#   MV13  docs-only: impacted, empty selection, nothing ran     -> rc 0
#   MV14  usage error / unreadable selection / no --discovered  -> rc 2
#   MV15  `notfound`, but the list names it to RUN              -> rc 1
#   MV16  `notfound`, and absent from the list (deleted)        -> rc 0
#   MV17  `notfound`, but the list names it (SKIP)              -> rc 1
#   MV18  a --discovered list naming no suite                   -> rc 2
#   MV19  impacted: a shard `skip`s a selected suite listed RUN -> rc 1
#   MV20  full: a suite listed RUN that no shard ran            -> rc 1
#   MV21  impacted: a shard `skip`s a selected suite not listed -> rc 1
#   MV22  the accounting awk fails                              -> rc 1
#
# Platform guard: bash-only, no .ps1 twin; the aggregator runs on Linux.
#
# Usage: bash scripts/ci/test-shard-manifest-verify.sh
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"

VERIFY="$RST_FIXTURE_DIR/shard-manifest-verify.sh"
T="$SUITE_LOCK_SANDBOX/mv"
mkdir -p "$T"

H=1111111111111111111111111111111111111111
B=2222222222222222222222222222222222222222
S=3333333333333333333333333333333333333333

# header <mode> [<suite>...] — a selection header for head $H.
header() {
  local mode="$1"; shift
  if [ "$mode" = full ]; then
    printf 'mode full\nreason no-base: x\nbase -\nhead %s\nselector -\n' "$H"
    return
  fi
  printf 'mode impacted\nreason base-sourced selector\nbase %s\nhead %s\nselector %s\n' "$B" "$H" "$S"
  printf 'changed scripts/tools/foo.sh\n'
  local s; for s in "$@"; do printf 'suite %s\n' "$s"; done
}

# case_dir <name> — a fresh manifest dir; prints its path.
case_dir() { rm -rf "${T:?}/$1"; mkdir -p "$T/$1/m"; printf '%s' "$T/$1"; }

# manifest <dir> <k> <n> <header-file> [body-line...]
manifest() {
  local d="$1" k="$2" n="$3" hf="$4"; shift 4
  { cat "$hf"; printf 'shard %s/%s\n' "$k" "$n"; local l; for l in "$@"; do printf '%s\n' "$l"; done; } \
    > "$d/m/manifest-shard$k.txt"
}

# disc <dir> <RUN|SKIP> <path> [<RUN|SKIP> <path>...] — the aggregator's
# `run-shell-tests.sh --list .` output, in the runner's own line format.
disc() {
  local d="$1"; shift
  : > "$d/disc.txt"
  while [ "$#" -ge 2 ]; do
    if [ "$1" = RUN ]; then printf '[RUN ] %s\n' "$2"; else printf '[SKIP] %s — tier\n' "$2"; fi >> "$d/disc.txt"
    shift 2
  done
}

verify() { bash "$VERIFY" --dir "$1/m" --shards "$2" --selection "$1/sel.txt" --discovered "$1/disc.txt" 2>&1; }

# expect <label> <want-rc> <dir> <n> [<grep-ERE the output must match>]
expect() {
  local out rc
  out=$(verify "$3" "$4"); rc=$?
  if [ "$rc" -eq "$2" ] && { [ -z "${5:-}" ] || grepq "$out" -E "$5"; }; then
    pass "$1 (rc $rc)"
  else
    fail "$1: want rc $2${5:+ matching /$5/}, got rc $rc: $out"
  fi
}

# --- MV1 ---------------------------------------------------------------------
d=$(case_dir mv1); header impacted scripts/test-a.sh scripts/test-b.sh > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh RUN scripts/test-b.sh RUN scripts/test-c.sh
manifest "$d" 1 2 "$d/sel.txt" 'ran 0 scripts/test-a.sh' 'skip scripts/test-c.sh'
manifest "$d" 2 2 "$d/sel.txt" 'ran 0 scripts/test-b.sh' 'skip scripts/test-c.sh'
expect "MV1: impacted, every selected suite ran once and passed" 0 "$d" 2 '^OK'

# --- MV2 ---------------------------------------------------------------------
d=$(case_dir mv2); header impacted scripts/test-a.sh > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh
manifest "$d" 1 2 "$d/sel.txt" 'ran 0 scripts/test-a.sh'
expect "MV2: a missing shard manifest is refused" 1 "$d" 2 'missing manifest.*shard2'

# --- MV3 ---------------------------------------------------------------------
d=$(case_dir mv3); header impacted scripts/test-a.sh scripts/test-b.sh > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh RUN scripts/test-b.sh
manifest "$d" 1 2 "$d/sel.txt" 'ran 0 scripts/test-a.sh'
sed "s/^head $H\$/head 4444444444444444444444444444444444444444/" "$d/sel.txt" > "$d/other.txt"
manifest "$d" 2 2 "$d/other.txt" 'ran 0 scripts/test-b.sh'
expect "MV3: a manifest from another head sha is refused" 1 "$d" 2 'shard2.*head'

# --- MV4 ---------------------------------------------------------------------
d=$(case_dir mv4); header impacted scripts/test-a.sh scripts/test-b.sh > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh RUN scripts/test-b.sh
manifest "$d" 1 2 "$d/sel.txt" 'ran 0 scripts/test-a.sh'
manifest "$d" 2 2 "$d/sel.txt"
expect "MV4: shards that ran fewer suites than selected are refused" 1 "$d" 2 'scripts/test-b\.sh.*never ran'

# --- MV5 ---------------------------------------------------------------------
d=$(case_dir mv5); header impacted scripts/test-a.sh scripts/test-b.sh > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh RUN scripts/test-b.sh
manifest "$d" 1 2 "$d/sel.txt" 'ran 0 scripts/test-a.sh'
manifest "$d" 2 2 "$d/sel.txt" 'ran 1 scripts/test-b.sh'
expect "MV5: a failing selected suite is refused" 1 "$d" 2 'scripts/test-b\.sh.*rc 1'

# --- MV6 ---------------------------------------------------------------------
d=$(case_dir mv6); header full > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh
header impacted scripts/test-a.sh > "$d/imp.txt"
manifest "$d" 1 1 "$d/imp.txt" 'ran 0 scripts/test-a.sh'
expect "MV6: an impacted shard under a full selection is refused" 1 "$d" 1 'shard1.*header'

# --- MV7 ---------------------------------------------------------------------
d=$(case_dir mv7); header impacted scripts/test-a.sh > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh
manifest "$d" 1 2 "$d/sel.txt" 'ran 0 scripts/test-a.sh'
manifest "$d" 2 2 "$d/sel.txt" 'ran 0 scripts/test-a.sh'
expect "MV7: a suite run on two shards is refused" 1 "$d" 2 'scripts/test-a\.sh.*2 times'

# --- MV8 ---------------------------------------------------------------------
d=$(case_dir mv8); header impacted scripts/test-a.sh > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh RUN scripts/test-z.sh
manifest "$d" 1 1 "$d/sel.txt" 'ran 0 scripts/test-a.sh' 'ran 0 scripts/test-z.sh'
expect "MV8: a suite outside the selection that ran is refused" 1 "$d" 1 'scripts/test-z\.sh.*not selected'

# --- MV9 ---------------------------------------------------------------------
d=$(case_dir mv9); header impacted scripts/test-a.sh scripts/test-b.sh > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh RUN scripts/test-b.sh
manifest "$d" 1 1 "$d/sel.txt" 'ran 0 scripts/test-a.sh' 'unrun scripts/test-b.sh'
expect "MV9: an unrun suite is refused" 1 "$d" 1 'scripts/test-b\.sh.*unrun'

# --- MV10 --------------------------------------------------------------------
d=$(case_dir mv10); header impacted scripts/test-a.sh scripts/test-slow.sh > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh SKIP scripts/test-slow.sh
manifest "$d" 1 2 "$d/sel.txt" 'ran 0 scripts/test-a.sh' 'skip scripts/test-slow.sh'
manifest "$d" 2 2 "$d/sel.txt" 'skip scripts/test-slow.sh'
expect "MV10: a tier-skipped selected suite is accounted for" 0 "$d" 2 'NOTE.*scripts/test-slow\.sh'

# --- MV11 --------------------------------------------------------------------
d=$(case_dir mv11); header full > "$d/sel.txt"
disc "$d" RUN scripts/test-x.sh RUN scripts/test-y.sh SKIP scripts/test-q.sh
manifest "$d" 1 2 "$d/sel.txt" 'ran 0 scripts/test-x.sh'
manifest "$d" 2 2 "$d/sel.txt" 'ran 0 scripts/test-y.sh' 'skip scripts/test-q.sh'
expect "MV11: full mode, all green" 0 "$d" 2 '^OK'
manifest "$d" 2 2 "$d/sel.txt" 'ran 1 scripts/test-y.sh'
expect "MV11: full mode, one red suite" 1 "$d" 2 'scripts/test-y\.sh.*rc 1'

# --- MV12 --------------------------------------------------------------------
d=$(case_dir mv12); header impacted scripts/test-a.sh > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh
manifest "$d" 1 2 "$d/sel.txt" 'ran 0 scripts/test-a.sh'
manifest "$d" 2 2 "$d/sel.txt"
sed -i.bak 's#^shard 2/2$#shard 1/2#' "$d/m/manifest-shard2.txt"
rm -f "$d/m/manifest-shard2.txt.bak"
expect "MV12: a manifest claiming another shard is refused" 1 "$d" 2 'shard2.*shard 2/2'

# --- MV13 --------------------------------------------------------------------
d=$(case_dir mv13); header impacted > "$d/sel.txt"
disc "$d" SKIP scripts/test-a.sh
manifest "$d" 1 2 "$d/sel.txt"
manifest "$d" 2 2 "$d/sel.txt"
expect "MV13: docs-only (empty selection, nothing ran) is green" 0 "$d" 2 '^OK'

# --- MV14 --------------------------------------------------------------------
out=$(bash "$VERIFY" --dir "$T" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "MV14: missing arguments -> rc 2"; else fail "MV14: rc=$rc out: $out"; fi
out=$(bash "$VERIFY" --dir "$T" --shards 1 --selection "$T/nope.txt" --discovered "$d/disc.txt" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "MV14: unreadable selection -> rc 2"; else fail "MV14: rc=$rc out: $out"; fi
out=$(bash "$VERIFY" --dir "$d/m" --shards 2 --selection "$d/sel.txt" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" -e '--discovered'; then pass "MV14: no --discovered list -> rc 2"
else fail "MV14: no --discovered: rc=$rc out: $out"; fi

# --- MV15-MV18: a selected suite a shard recorded as `notfound` ---------------
# The aggregator lists discovery at the same head; a suite it finds that a shard
# did not is a shard that skipped discovery, not a deleted suite.
d=$(case_dir mv15); header impacted scripts/test-a.sh scripts/test-b.sh > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh RUN scripts/test-b.sh SKIP scripts/test-c.sh
manifest "$d" 1 1 "$d/sel.txt" 'ran 0 scripts/test-a.sh' 'notfound scripts/test-b.sh'
expect "MV15: notfound but listed to run at this head is refused" 1 "$d" 1 'scripts/test-b\.sh.*discovery'

d=$(case_dir mv16); header impacted scripts/test-a.sh scripts/test-gone.sh > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh
manifest "$d" 1 1 "$d/sel.txt" 'ran 0 scripts/test-a.sh' 'notfound scripts/test-gone.sh'
expect "MV16: notfound and not discoverable (deleted suite) is a NOTE" 0 "$d" 1 'NOTE.*scripts/test-gone\.sh'

d=$(case_dir mv17); header impacted scripts/test-a.sh scripts/test-b.sh > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh SKIP scripts/test-b.sh
manifest "$d" 1 1 "$d/sel.txt" 'ran 0 scripts/test-a.sh' 'notfound scripts/test-b.sh'
expect "MV17: notfound but discovered (as SKIP) at this head is refused" 1 "$d" 1 'scripts/test-b\.sh.*notfound.*discovery finds it'

: > "$d/disc.txt"
expect "MV18: a discovered list naming no suite is a usage error" 2 "$d" 1 'names no suite'

# --- MV19 --------------------------------------------------------------------
# A shard's `skip` is only a NOTE when discovery here skips the suite too; one
# the list names to RUN was dropped by something other than a standing filter.
d=$(case_dir mv19); header impacted scripts/test-a.sh scripts/test-b.sh > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh RUN scripts/test-b.sh
manifest "$d" 1 1 "$d/sel.txt" 'ran 0 scripts/test-a.sh' 'skip scripts/test-b.sh'
expect "MV19: a selected suite skipped by a shard but listed RUN is refused" 1 "$d" 1 'scripts/test-b\.sh.*discovery lists it'

# --- MV20 --------------------------------------------------------------------
d=$(case_dir mv20); header full > "$d/sel.txt"
disc "$d" RUN scripts/test-x.sh RUN scripts/test-y.sh
manifest "$d" 1 2 "$d/sel.txt" 'ran 0 scripts/test-x.sh'
manifest "$d" 2 2 "$d/sel.txt"
expect "MV20: full mode, a suite listed RUN that no shard ran is refused" 1 "$d" 2 'scripts/test-y\.sh.*discovery lists it'

# --- MV21 --------------------------------------------------------------------
# A shard's `skip` of a selected suite the list does not name at all has no
# standing filter to point to: refused, not a NOTE.
d=$(case_dir mv21); header impacted scripts/test-a.sh scripts/test-b.sh > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh
manifest "$d" 1 1 "$d/sel.txt" 'ran 0 scripts/test-a.sh' 'skip scripts/test-b.sh'
expect "MV21: a selected suite skipped by a shard but absent from the list is refused" 1 "$d" 1 'scripts/test-b\.sh.*skipped.*discovery does not'

# --- MV22 --------------------------------------------------------------------
# A crashed accounting pass must not read as OK: an awk that exits non-zero
# with no output fails the verify closed.
d=$(case_dir mv22); header impacted scripts/test-a.sh > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh
manifest "$d" 1 1 "$d/sel.txt" 'ran 0 scripts/test-a.sh'
mkdir -p "$d/stub"
printf '#!/bin/sh\nexit 2\n' > "$d/stub/awk"; chmod +x "$d/stub/awk"
out=$(PATH="$d/stub:$PATH" bash "$VERIFY" --dir "$d/m" --shards 1 --selection "$d/sel.txt" --discovered "$d/disc.txt" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" -E 'accounting.*failed'; then
  pass "MV22: a failing accounting pass is refused (rc $rc)"
else fail "MV22: want rc 1 matching /accounting.*failed/, got rc $rc: $out"; fi

# --- MV23 --------------------------------------------------------------------
# A suite path holding whitespace would be split at the first space by every
# space-delimited field, so the verifier refuses it, naming the path, wherever
# it appears (HIMMEL-3916). The control keeps normal paths passing.
d=$(case_dir mv23); header impacted scripts/test-a.sh > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh RUN "scripts/test b.sh"
manifest "$d" 1 1 "$d/sel.txt" 'ran 0 scripts/test-a.sh' 'skip scripts/test b.sh'
expect "MV23: a discovered suite path with whitespace is refused" 1 "$d" 1 'whitespace.*scripts/test b\.sh'

d=$(case_dir mv23s); header impacted "scripts/test b.sh" > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh
manifest "$d" 1 1 "$d/sel.txt" 'ran 0 scripts/test-a.sh'
expect "MV23: a selected suite path with whitespace is refused" 1 "$d" 1 'whitespace.*scripts/test b\.sh'

d=$(case_dir mv23k); header impacted scripts/test-a.sh > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh SKIP "scripts/test c.sh"
manifest "$d" 1 1 "$d/sel.txt" 'ran 0 scripts/test-a.sh'
expect "MV23: a SKIP-listed suite path with whitespace is refused" 1 "$d" 1 'whitespace.*scripts/test c\.sh'

# --- MV24 --------------------------------------------------------------------
d=$(case_dir mv24); header impacted scripts/test-a.sh > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh
manifest "$d" 1 1 "$d/sel.txt" 'ran 0 scripts/test-a.sh' 'notfound scripts/test d.sh'
expect "MV24: a manifest entry with whitespace in the path is refused" 1 "$d" 1 'shard1.*whitespace.*scripts/test d\.sh'

d=$(case_dir mv24r); header impacted scripts/test-a.sh > "$d/sel.txt"
disc "$d" RUN scripts/test-a.sh
manifest "$d" 1 1 "$d/sel.txt" 'ran 0 scripts/test a.sh'
expect "MV24: a ran entry with whitespace in the path is refused" 1 "$d" 1 'shard1.*whitespace.*scripts/test a\.sh'

rst_tally
