#!/usr/bin/env bash
# scripts/ci/test-shard-manifest-verify.sh — scripts/ci/shard-manifest-verify.sh
# (HIMMEL-3897): the shell-unit aggregator's check that the fixed shards ran
# exactly what the base-sourced selection picked, at this head.
#
# Manifests are hand-built here so each case varies ONE property:
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
#   MV10  a selected suite tier-skipped is accounted for        -> rc 0
#   MV11  full mode: all green -> rc 0; one red -> rc 1
#   MV12  a manifest that claims another shard number           -> rc 1
#   MV13  docs-only: impacted, empty selection, nothing ran     -> rc 0
#   MV14  usage error / unreadable selection                    -> rc 2
#   MV15  `notfound`, but the aggregator's `--list .` finds it  -> rc 1
#   MV16  `notfound`, and absent from `--list .` (deleted)      -> rc 0
#   MV17  `notfound` with no --discovered list (fail closed)    -> rc 1
#   MV18  a --discovered list naming no suite                   -> rc 2
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

# DISC, when set, is passed as --discovered (the aggregator's `--list .` output).
DISC=""
verify() { bash "$VERIFY" --dir "$1/m" --shards "$2" --selection "$1/sel.txt" ${DISC:+--discovered "$DISC"} 2>&1; }

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
manifest "$d" 1 2 "$d/sel.txt" 'ran 0 scripts/test-a.sh' 'skip scripts/test-c.sh'
manifest "$d" 2 2 "$d/sel.txt" 'ran 0 scripts/test-b.sh' 'skip scripts/test-c.sh'
expect "MV1: impacted, every selected suite ran once and passed" 0 "$d" 2 '^OK'

# --- MV2 ---------------------------------------------------------------------
d=$(case_dir mv2); header impacted scripts/test-a.sh > "$d/sel.txt"
manifest "$d" 1 2 "$d/sel.txt" 'ran 0 scripts/test-a.sh'
expect "MV2: a missing shard manifest is refused" 1 "$d" 2 'missing manifest.*shard2'

# --- MV3 ---------------------------------------------------------------------
d=$(case_dir mv3); header impacted scripts/test-a.sh scripts/test-b.sh > "$d/sel.txt"
manifest "$d" 1 2 "$d/sel.txt" 'ran 0 scripts/test-a.sh'
sed "s/^head $H\$/head 4444444444444444444444444444444444444444/" "$d/sel.txt" > "$d/other.txt"
manifest "$d" 2 2 "$d/other.txt" 'ran 0 scripts/test-b.sh'
expect "MV3: a manifest from another head sha is refused" 1 "$d" 2 'shard2.*head'

# --- MV4 ---------------------------------------------------------------------
d=$(case_dir mv4); header impacted scripts/test-a.sh scripts/test-b.sh > "$d/sel.txt"
manifest "$d" 1 2 "$d/sel.txt" 'ran 0 scripts/test-a.sh'
manifest "$d" 2 2 "$d/sel.txt"
expect "MV4: shards that ran fewer suites than selected are refused" 1 "$d" 2 'scripts/test-b\.sh.*never ran'

# --- MV5 ---------------------------------------------------------------------
d=$(case_dir mv5); header impacted scripts/test-a.sh scripts/test-b.sh > "$d/sel.txt"
manifest "$d" 1 2 "$d/sel.txt" 'ran 0 scripts/test-a.sh'
manifest "$d" 2 2 "$d/sel.txt" 'ran 1 scripts/test-b.sh'
expect "MV5: a failing selected suite is refused" 1 "$d" 2 'scripts/test-b\.sh.*rc 1'

# --- MV6 ---------------------------------------------------------------------
d=$(case_dir mv6); header full > "$d/sel.txt"
header impacted scripts/test-a.sh > "$d/imp.txt"
manifest "$d" 1 1 "$d/imp.txt" 'ran 0 scripts/test-a.sh'
expect "MV6: an impacted shard under a full selection is refused" 1 "$d" 1 'shard1.*header'

# --- MV7 ---------------------------------------------------------------------
d=$(case_dir mv7); header impacted scripts/test-a.sh > "$d/sel.txt"
manifest "$d" 1 2 "$d/sel.txt" 'ran 0 scripts/test-a.sh'
manifest "$d" 2 2 "$d/sel.txt" 'ran 0 scripts/test-a.sh'
expect "MV7: a suite run on two shards is refused" 1 "$d" 2 'scripts/test-a\.sh.*2 times'

# --- MV8 ---------------------------------------------------------------------
d=$(case_dir mv8); header impacted scripts/test-a.sh > "$d/sel.txt"
manifest "$d" 1 1 "$d/sel.txt" 'ran 0 scripts/test-a.sh' 'ran 0 scripts/test-z.sh'
expect "MV8: a suite outside the selection that ran is refused" 1 "$d" 1 'scripts/test-z\.sh.*not selected'

# --- MV9 ---------------------------------------------------------------------
d=$(case_dir mv9); header impacted scripts/test-a.sh scripts/test-b.sh > "$d/sel.txt"
manifest "$d" 1 1 "$d/sel.txt" 'ran 0 scripts/test-a.sh' 'unrun scripts/test-b.sh'
expect "MV9: an unrun suite is refused" 1 "$d" 1 'scripts/test-b\.sh.*unrun'

# --- MV10 --------------------------------------------------------------------
d=$(case_dir mv10); header impacted scripts/test-a.sh scripts/test-slow.sh > "$d/sel.txt"
manifest "$d" 1 2 "$d/sel.txt" 'ran 0 scripts/test-a.sh' 'skip scripts/test-slow.sh'
manifest "$d" 2 2 "$d/sel.txt" 'skip scripts/test-slow.sh'
expect "MV10: a tier-skipped selected suite is accounted for" 0 "$d" 2 'NOTE.*scripts/test-slow\.sh'

# --- MV11 --------------------------------------------------------------------
d=$(case_dir mv11); header full > "$d/sel.txt"
manifest "$d" 1 2 "$d/sel.txt" 'ran 0 scripts/test-x.sh'
manifest "$d" 2 2 "$d/sel.txt" 'ran 0 scripts/test-y.sh' 'skip scripts/test-q.sh'
expect "MV11: full mode, all green" 0 "$d" 2 '^OK'
manifest "$d" 2 2 "$d/sel.txt" 'ran 1 scripts/test-y.sh'
expect "MV11: full mode, one red suite" 1 "$d" 2 'scripts/test-y\.sh.*rc 1'

# --- MV12 --------------------------------------------------------------------
d=$(case_dir mv12); header impacted scripts/test-a.sh > "$d/sel.txt"
manifest "$d" 1 2 "$d/sel.txt" 'ran 0 scripts/test-a.sh'
manifest "$d" 2 2 "$d/sel.txt"
sed -i.bak 's#^shard 2/2$#shard 1/2#' "$d/m/manifest-shard2.txt"
rm -f "$d/m/manifest-shard2.txt.bak"
expect "MV12: a manifest claiming another shard is refused" 1 "$d" 2 'shard2.*shard 2/2'

# --- MV13 --------------------------------------------------------------------
d=$(case_dir mv13); header impacted > "$d/sel.txt"
manifest "$d" 1 2 "$d/sel.txt"
manifest "$d" 2 2 "$d/sel.txt"
expect "MV13: docs-only (empty selection, nothing ran) is green" 0 "$d" 2 '^OK'

# --- MV14 --------------------------------------------------------------------
out=$(bash "$VERIFY" --dir "$T" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "MV14: missing arguments -> rc 2"; else fail "MV14: rc=$rc out: $out"; fi
out=$(bash "$VERIFY" --dir "$T" --shards 1 --selection "$T/nope.txt" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "MV14: unreadable selection -> rc 2"; else fail "MV14: rc=$rc out: $out"; fi

# --- MV15-MV18: a selected suite a shard recorded as `notfound` ---------------
# The aggregator lists discovery at the same head; a suite it finds that a shard
# did not is a shard that skipped discovery, not a deleted suite.
d=$(case_dir mv15); header impacted scripts/test-a.sh scripts/test-b.sh > "$d/sel.txt"
manifest "$d" 1 1 "$d/sel.txt" 'ran 0 scripts/test-a.sh' 'notfound scripts/test-b.sh'
printf '[RUN ] scripts/test-a.sh\n[RUN ] scripts/test-b.sh\n[SKIP] scripts/test-c.sh — tier\n' > "$d/disc.txt"
DISC="$d/disc.txt"
expect "MV15: notfound but discoverable at this head is refused" 1 "$d" 1 'scripts/test-b\.sh.*discover'

d=$(case_dir mv16); header impacted scripts/test-a.sh scripts/test-gone.sh > "$d/sel.txt"
manifest "$d" 1 1 "$d/sel.txt" 'ran 0 scripts/test-a.sh' 'notfound scripts/test-gone.sh'
printf '[RUN ] scripts/test-a.sh\n' > "$d/disc.txt"
DISC="$d/disc.txt"
expect "MV16: notfound and not discoverable (deleted suite) is a NOTE" 0 "$d" 1 'NOTE.*scripts/test-gone\.sh'

DISC=""
expect "MV17: notfound without a --discovered list fails closed" 1 "$d" 1 'scripts/test-gone\.sh.*--discovered'

: > "$d/empty.txt"
DISC="$d/empty.txt"
expect "MV18: a discovered list naming no suite is a usage error" 2 "$d" 1 'names no suite'
DISC=""

rst_tally
