#!/usr/bin/env bash
# test-claude-headless-trap.sh — HIMMEL-2514. Two concerns, both about
# claude-headless.sh's EXIT/INT/TERM trap doing process-tree damage:
#
#   A. The trap must never kill a pid it did not launch. `CLAUDE_PID` is
#      exported into every subprocess by an interactive Claude Code session,
#      and `finalize_on_exit` used to read exactly that name — so every
#      PRE-LAUNCH refusal path (which exits before the launch assigns it)
#      killed the session that ran the wrapper. Observed twice on 2026-09-04.
#   B. kill_tree must be bounded. It used to fork a fresh `ps` at every
#      recursion level with no visited set, which is what turned a busy
#      process table into a bash SIGSEGV.
#
# Hermetic: no live `claude` call, no real session pid is ever named. The
# only pids this suite touches are throwaway sleepers it spawned itself.
# Bash 3.2 safe.
# shellcheck disable=SC2012  # registry ids are UUIDs; ls-over-glob is fine here
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$REPO/scripts/lib/claude-headless.sh"
KILL_TREE_LIB="$REPO/scripts/lib/kill-tree.sh"
PASS=0; FAIL=0; SKIP=0
# Guarded BEFORE any $W path is used and before the cleanup trap is
# installed: an unchecked mktemp failure leaves $W empty, and every
# subsequent "$W/..." path then resolves at the filesystem ROOT
# (mkdir -p /fakebin, /bank-cache.json, ...) while the suite carries on
# against that bogus scaffolding.
W="$(mktemp -d -t claude-headless-trap-test.XXXXXX)" || { echo "test-claude-headless-trap.sh: mktemp failed, aborting" >&2; exit 1; }
SLEEPERS=""

cleanup() {
  local p
  for p in $SLEEPERS; do kill -KILL "$p" 2>/dev/null || true; done
  # Backstop independent of the mktemp guard above: if $W is ever empty by
  # the time this trap fires (an edit years from now breaks the guard, a
  # variable gets clobbered), refuse rather than `rm -rf` a root-level path.
  [ -n "$W" ] || return 0
  rm -rf "$W"
}
trap cleanup EXIT

check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }

# A killed CHILD of this script lingers as an unreaped zombie, and `kill -0`
# answers 0 for a zombie — which would mask exactly the bug this suite is
# here to catch. Treat state Z as dead. (MSYS `ps` has no -o stat=; there a
# terminated process is simply gone, so the empty-output fallthrough is
# correct there too.)
sleeper_alive() {
  local pid="$1" stat
  kill -0 "$pid" 2>/dev/null || return 1
  stat="$(ps -o stat= -p "$pid" 2>/dev/null)"
  case "$stat" in *Z*) return 1 ;; esac
  return 0
}

SLEEPER_PID=""
spawn_sleeper() {
  sleep 120 >/dev/null 2>&1 &
  SLEEPER_PID=$!
  SLEEPERS="$SLEEPERS $SLEEPER_PID"
}

# --- hermetic bank cache (verdict PROCEED unless a row overrides it) ---
BANK_CACHE="$W/bank-cache.json"
mk_bank_cache() { printf '{"five_hour":{"utilization":10},"seven_day":{"utilization":20},"primaries_refreshed_at":%s}\n' "$(date +%s)" > "$BANK_CACHE"; }
mk_bank_cache
export CADENCE_BANK_CACHE="$BANK_CACHE"
export CADENCE_BANK_SKIP_REFRESH=1
export CADENCE_BANK_LEDGER="$W/bank-ledger.jsonl"

REGISTRY_DIR="$W/registry"
export HIMMEL_REGISTRY_DIR="$REGISTRY_DIR"
LIVE_DIR="$REGISTRY_DIR/live"
mkdir -p "$LIVE_DIR"

FAKE_OK="$W/fake-claude-ok.sh"
cat > "$FAKE_OK" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
echo "OK" > "$FAKE_ARTIFACT"
echo '{"is_error":false,"result":"done","session_id":"fake-session","permission_denials":[],"num_turns":2}'
EOF
chmod +x "$FAKE_OK"

WORKTREE="$W/worktree"; mkdir -p "$WORKTREE"
PROMPT_FILE="$W/prompt.txt"; echo "write the file" > "$PROMPT_FILE"

# Runs the wrapper with CLAUDE_PID exported to a pid we own, exactly as an
# interactive session exports its own pid. `env` (not a bash function-call
# assignment prefix, whose persistence differs between bash's posix and
# default modes) keeps the override scoped to this one invocation.
run_with_ambient_claude_pid() {
  local ambient="$1" artifact="$2"; shift 2
  # `env` only accepts NAME=value tokens before the command it execs — a
  # bare flag like `--permission-mode` in that position makes `env` treat
  # IT as the command (rc 127, `bash "$SUT"` never runs). Split "$@" into
  # env-var overrides (NAME=value, e.g. HIMMEL_DISPATCH_MAX_CONCURRENT=2)
  # and everything else (extra CLI args for the SUT, e.g. --permission-mode).
  local envs=() extra=() a
  for a in "$@"; do
    case "$a" in
      [A-Za-z_]*=*) envs+=("$a") ;;
      *) extra+=("$a") ;;
    esac
  done
  env CLAUDE_PID="$ambient" FAKE_ARTIFACT="$artifact" HIMMEL_CLAUDE_BIN="$FAKE_OK" \
    "${envs[@]}" bash "$SUT" \
    --role test-role --ticket HIMMEL-2514 --worktree "$WORKTREE" --cwd "$WORKTREE" \
    --artifact "$artifact" --prompt-file "$PROMPT_FILE" "${extra[@]}"
}

# =====================================================================
# A. refusal paths must not kill the ambient CLAUDE_PID
# =====================================================================

# --- A1: concurrency cap. Refuses at the cap check, which sits AFTER the
# trap is registered — the exact path test-claude-headless.sh case 5 walks,
# and the one that killed the launching session on 2026-09-04. stderr is
# captured (not discarded) so a positive control can confirm the wrapper
# actually reached THIS refusal, not some other crash that happens to also
# exit 1 and leave the sleeper alone.
spawn_sleeper; S1="$SLEEPER_PID"
jq -n '{id:"a", role:"r", worktree:"w", ticket:"t", status:"dispatched"}' > "$LIVE_DIR/a.json"
jq -n '{id:"b", role:"r", worktree:"w", ticket:"t", status:"running"}' > "$LIVE_DIR/b.json"
STDERR_A1="$W/stderr-a1.txt"
run_with_ambient_claude_pid "$S1" "$W/artifact-a1.txt" \
  HIMMEL_DISPATCH_MAX_CONCURRENT=2 --permission-mode default >/dev/null 2>"$STDERR_A1"
RC_A1=$?
sleep 1
check "concurrency-cap refusal exits 1" "1" "$RC_A1"
check "concurrency-cap refusal leaves the ambient CLAUDE_PID process ALIVE" \
  "alive" "$(if sleeper_alive "$S1"; then echo alive; else echo killed; fi)"
check "concurrency-cap refusal stderr names the concurrency cap" \
  "1" "$(grep -c 'concurrency cap' "$STDERR_A1" || true)"
rm -f "$LIVE_DIR"/*.json

# --- A2: bank-preflight SKIP. Also refuses after the trap is registered.
spawn_sleeper; S2="$SLEEPER_PID"
printf '{"five_hour":{"utilization":95},"seven_day":{"utilization":20},"primaries_refreshed_at":%s}\n' "$(date +%s)" > "$BANK_CACHE"
STDERR_A2="$W/stderr-a2.txt"
run_with_ambient_claude_pid "$S2" "$W/artifact-a2.txt" --permission-mode default >/dev/null 2>"$STDERR_A2"
RC_A2=$?
sleep 1
check "bank-SKIP refusal exits 1" "1" "$RC_A2"
check "bank-SKIP refusal leaves the ambient CLAUDE_PID process ALIVE" \
  "alive" "$(if sleeper_alive "$S2"; then echo alive; else echo killed; fi)"
check "bank-SKIP refusal stderr names the bank preflight refusal" \
  "1" "$(grep -c 'bank preflight refused' "$STDERR_A2" || true)"
# The launch-window race itself (a SIGTERM landing between `( ... ) &` and
# `_LAUNCHED_CLAUDE_PID=$!` in claude-headless.sh) is NOT reproducible in
# this suite — it depends on signal timing bash gives no hook into, and this
# row does not attempt to fake it. What it DOES pin: on this refusal path no
# background job is ever started, so finalize_on_exit's `jobs -p` fallback
# is empty and a no-op — it never falls through to the ambient CLAUDE_PID
# this suite exported (same assertion as above, named for the property it
# proves rather than the refusal that triggers it).
check "jobs -p fallback cannot reach the ambient CLAUDE_PID on a refusal path" \
  "alive" "$(if sleeper_alive "$S2"; then echo alive; else echo killed; fi)"
mk_bank_cache
rm -f "$LIVE_DIR"/*.json

# --- A3: bypassPermissions. This refusal happens during argument validation,
# BEFORE the trap is registered, so it is green even on the buggy version —
# it is kept as a guard against the trap ever being moved earlier (which
# would silently re-arm the whole bug class on the validation paths).
spawn_sleeper; S3="$SLEEPER_PID"
STDERR_A3="$W/stderr-a3.txt"
run_with_ambient_claude_pid "$S3" "$W/artifact-a3.txt" --permission-mode bypassPermissions >/dev/null 2>"$STDERR_A3"
RC_A3=$?
sleep 1
check "bypassPermissions refusal exits 1" "1" "$RC_A3"
check "bypassPermissions refusal leaves the ambient CLAUDE_PID process ALIVE" \
  "alive" "$(if sleeper_alive "$S3"; then echo alive; else echo killed; fi)"
check "bypassPermissions refusal stderr names bypassPermissions" \
  "1" "$(grep -c 'bypassPermissions' "$STDERR_A3" || true)"
rm -f "$LIVE_DIR"/*.json

# =====================================================================
# B. kill_tree is bounded
# =====================================================================
# A fake `ps` first on PATH returns a SYNTHETIC process table wired over
# real sleeper pids, so the walk's shape (depth, cycles, how many times it
# consults `ps`) is under the test's control while the kills it issues are
# still real and checkable.

if [ ! -r "$KILL_TREE_LIB" ]; then
  # kill-tree.sh is a COMMITTED sibling of this suite, not an optional host
  # capability (unlike, say, cygpath) — its absence means a broken checkout,
  # not a platform gap. Section B silently SKIPping here would let this
  # entire suite report green while the kill_tree implementation under test
  # was never executed once (confirmed with a positive control: delete
  # kill-tree.sh and the suite still reports all-green, because section A's
  # rows only assert "the wrapper refused and left the sleeper alone",
  # which is equally true of a wrapper that refuses because it can't source
  # its own dependency). Fail loudly instead.
  FAIL=$((FAIL+1))
  echo "FAIL - kill_tree rows: kill-tree.sh is a required sibling of this suite, not found at $KILL_TREE_LIB"
else
  mkdir -p "$W/fakebin"
  # FAKE_PS_TABLE2 is optional: unset, every call returns FAKE_PS_TABLE
  # (existing rows' behavior, unchanged). Set, calls from the 2nd onward
  # return FAKE_PS_TABLE2 instead — used by the late-fork sweep row below to
  # simulate a process that forks into the tree between sweeps. FAKE_PS_FAIL
  # is also optional: set, `ps` exits 1 with NO output at all, regardless of
  # any table — the pure "ps itself is broken/missing" case, used by the
  # failed-snapshot row below.
  cat > "$W/fakebin/ps" <<'EOF'
#!/usr/bin/env bash
echo call >> "$FAKE_PS_COUNT"
if [ -n "${FAKE_PS_FAIL:-}" ]; then
  exit 1
fi
n=$(wc -l < "$FAKE_PS_COUNT" | tr -d ' ')
if [ "$n" -ge 2 ] && [ -n "${FAKE_PS_TABLE2:-}" ]; then
  cat "$FAKE_PS_TABLE2"
else
  cat "$FAKE_PS_TABLE"
fi
EOF
  chmod +x "$W/fakebin/ps"

  run_kill_tree() { # $1 = ps table, $2 = ps call-count file, $3 = root pid, rest = env
    local table="$1" count="$2" root="$3"; shift 3
    # shellcheck disable=SC2016  # single-quoted: $1/$2 are positional args to `bash -c`, not this shell's vars
    timeout 20 env PATH="$W/fakebin:$PATH" FAKE_PS_TABLE="$table" FAKE_PS_COUNT="$count" "$@" \
      bash -c '. "$1"; kill_tree "$2"' _ "$KILL_TREE_LIB" "$root" >/dev/null 2>&1
  }

  # --- B1: a 6-deep chain is walked completely (correctness preserved) and
  # `ps` is consulted once PER SWEEP (2 by default), not once per node and
  # not just once overall. The old per-level-recursion shape forked a fresh
  # `ps` at every level — 7 calls for this same 7-node table; the single-
  # snapshot shape CR round 1 replaced it with forked exactly 1 — correct
  # count but (per finding 1) blind to a process forked between the
  # snapshot and its parent being signalled. Sweeping trades "1" for
  # "bounded by KILL_TREE_SWEEPS" to NARROW that gap (see the row pair
  # below — it does not close the gap; that's HIMMEL-2523), while still
  # being nowhere near "once per node".
  CHAIN=""
  i=0
  while [ "$i" -lt 7 ]; do spawn_sleeper; CHAIN="$CHAIN $SLEEPER_PID"; i=$((i+1)); done
  # shellcheck disable=SC2086
  set -- $CHAIN
  TABLE_B1="$W/ps-chain.txt"
  {
    printf '%s 1\n' "$1"
    printf '%s %s\n' "$2" "$1"
    printf '%s %s\n' "$3" "$2"
    printf '%s %s\n' "$4" "$3"
    printf '%s %s\n' "$5" "$4"
    printf '%s %s\n' "$6" "$5"
    printf '%s %s\n' "$7" "$6"
    printf '99991 99990\n99992 99990\n'   # unrelated noise
  } > "$TABLE_B1"
  COUNT_B1="$W/ps-count-chain.txt"; : > "$COUNT_B1"
  run_kill_tree "$TABLE_B1" "$COUNT_B1" "$1"
  RC_B1=$?
  sleep 1
  ALIVE_B1=0
  for p in $CHAIN; do if sleeper_alive "$p"; then ALIVE_B1=$((ALIVE_B1+1)); fi; done
  check "6-deep chain: kill_tree returns 0" "0" "$RC_B1"
  check "6-deep chain: every descendant killed" "0" "$ALIVE_B1"
  check "6-deep chain: ps consulted once per sweep (2), not once per node" \
    "2" "$(wc -l < "$COUNT_B1" | tr -d ' ')"

  # --- B1c: KILL_TREE_SWEEPS is a real, honoured knob — 1 sweep forks `ps`
  # exactly once, 3 sweeps fork it exactly three times. Same chain shape,
  # freshly spawned each time (sleepers are one-shot once killed).
  for SWEEPN in 1 3; do
    CHAINS=""
    i=0
    while [ "$i" -lt 7 ]; do spawn_sleeper; CHAINS="$CHAINS $SLEEPER_PID"; i=$((i+1)); done
    # shellcheck disable=SC2086
    set -- $CHAINS
    TABLE_SW="$W/ps-chain-sweeps-$SWEEPN.txt"
    {
      printf '%s 1\n' "$1"
      printf '%s %s\n' "$2" "$1"
      printf '%s %s\n' "$3" "$2"
      printf '%s %s\n' "$4" "$3"
      printf '%s %s\n' "$5" "$4"
      printf '%s %s\n' "$6" "$5"
      printf '%s %s\n' "$7" "$6"
    } > "$TABLE_SW"
    COUNT_SW="$W/ps-count-sweeps-$SWEEPN.txt"; : > "$COUNT_SW"
    run_kill_tree "$TABLE_SW" "$COUNT_SW" "$1" "KILL_TREE_SWEEPS=$SWEEPN"
    sleep 1
    check "KILL_TREE_SWEEPS=$SWEEPN: ps consulted exactly $SWEEPN time(s)" \
      "$SWEEPN" "$(wc -l < "$COUNT_SW" | tr -d ' ')"
  done

  # --- B1d: this row pair proves the 2nd sweep's snapshot is CONSULTED AND
  # ACTED ON — nothing more. It is NOT evidence that sweeping catches every
  # real late fork (HIMMEL-2523, deferred): a synthetic `ps` table has no
  # live process tree in which a child could reparent, so a fake `ps`
  # returning a table with a late-added child on its 2nd call cannot
  # exercise the reparenting failure mode CR round 2 identified. It only
  # proves the mechanical claim — that a later sweep re-reads `ps` and acts
  # on what it finds there. The fake `ps` returns TABLE_LATE1 on its first
  # call and TABLE_LATE2 (which adds LATE as a new child of node 2, as if
  # it forked between sweeps) from the second call onward. With the default
  # 2 sweeps, LATE is only visible on sweep 2 and must still be killed. The
  # negative control (KILL_TREE_SWEEPS=1) proves it's specifically the
  # SECOND sweep's snapshot doing the work: with only one sweep, `ps` is
  # only ever asked TABLE_LATE1, and LATE (which isn't in that table) must
  # survive.
  CHAINL=""
  i=0
  while [ "$i" -lt 3 ]; do spawn_sleeper; CHAINL="$CHAINL $SLEEPER_PID"; i=$((i+1)); done
  # shellcheck disable=SC2086
  set -- $CHAINL
  spawn_sleeper; LATE="$SLEEPER_PID"
  TABLE_LATE1="$W/ps-late1.txt"
  printf '%s 1\n%s %s\n%s %s\n' "$1" "$2" "$1" "$3" "$2" > "$TABLE_LATE1"
  TABLE_LATE2="$W/ps-late2.txt"
  printf '%s 1\n%s %s\n%s %s\n%s %s\n' "$1" "$2" "$1" "$3" "$2" "$LATE" "$2" > "$TABLE_LATE2"
  COUNT_LATE_POS="$W/ps-count-late-pos.txt"; : > "$COUNT_LATE_POS"
  run_kill_tree "$TABLE_LATE1" "$COUNT_LATE_POS" "$1" "FAKE_PS_TABLE2=$TABLE_LATE2"
  sleep 1
  check "2nd sweep's snapshot is consulted: simulated late-arriving child killed" \
    "killed" "$(if sleeper_alive "$LATE"; then echo alive; else echo killed; fi)"

  CHAINL2=""
  i=0
  while [ "$i" -lt 3 ]; do spawn_sleeper; CHAINL2="$CHAINL2 $SLEEPER_PID"; i=$((i+1)); done
  # shellcheck disable=SC2086
  set -- $CHAINL2
  spawn_sleeper; LATE2="$SLEEPER_PID"
  TABLE_LATE1B="$W/ps-late1b.txt"
  printf '%s 1\n%s %s\n%s %s\n' "$1" "$2" "$1" "$3" "$2" > "$TABLE_LATE1B"
  TABLE_LATE2B="$W/ps-late2b.txt"
  printf '%s 1\n%s %s\n%s %s\n%s %s\n' "$1" "$2" "$1" "$3" "$2" "$LATE2" "$2" > "$TABLE_LATE2B"
  COUNT_LATE_NEG="$W/ps-count-late-neg.txt"; : > "$COUNT_LATE_NEG"
  run_kill_tree "$TABLE_LATE1B" "$COUNT_LATE_NEG" "$1" "FAKE_PS_TABLE2=$TABLE_LATE2B" KILL_TREE_SWEEPS=1
  sleep 1
  check "2nd sweep's snapshot negative control: KILL_TREE_SWEEPS=1 never takes it, survives" \
    "alive" "$(if sleeper_alive "$LATE2"; then echo alive; else echo killed; fi)"

  # --- B1b: a malformed KILL_TREE_MAX_DEPTH must fall back to the default
  # (32), not silently degrade to killing only the root. A bare `-lt` on a
  # non-numeric value errors, and an erroring `if` reads as false — the
  # walk would stop descending after the root, leaving every descendant
  # alive. Same 6-deep chain shape as B1, freshly spawned.
  CHAINB=""
  i=0
  while [ "$i" -lt 7 ]; do spawn_sleeper; CHAINB="$CHAINB $SLEEPER_PID"; i=$((i+1)); done
  # shellcheck disable=SC2086
  set -- $CHAINB
  TABLE_B1B="$W/ps-chain-baddepth.txt"
  {
    printf '%s 1\n' "$1"
    printf '%s %s\n' "$2" "$1"
    printf '%s %s\n' "$3" "$2"
    printf '%s %s\n' "$4" "$3"
    printf '%s %s\n' "$5" "$4"
    printf '%s %s\n' "$6" "$5"
    printf '%s %s\n' "$7" "$6"
  } > "$TABLE_B1B"
  COUNT_B1B="$W/ps-count-chain-baddepth.txt"; : > "$COUNT_B1B"
  run_kill_tree "$TABLE_B1B" "$COUNT_B1B" "$1" KILL_TREE_MAX_DEPTH=lots
  RC_B1B=$?
  sleep 1
  ALIVE_B1B=0
  for p in $CHAINB; do if sleeper_alive "$p"; then ALIVE_B1B=$((ALIVE_B1B+1)); fi; done
  check "malformed KILL_TREE_MAX_DEPTH: kill_tree returns 0" "0" "$RC_B1B"
  check "malformed KILL_TREE_MAX_DEPTH: falls back to 32, every descendant killed" \
    "0" "$ALIVE_B1B"

  # --- B1e: an in-range-looking but absurdly LONG digit string must also
  # fall back to 32, not degrade to root-only. Confirmed on this host:
  # `[ 0 -lt 99999999999999999999 ]` errors ("integer expected") and an
  # erroring `if` reads as false — the exact silent degrade the range
  # ceiling exists to prevent. Same 6-deep chain shape, freshly spawned.
  CHAINR=""
  i=0
  while [ "$i" -lt 7 ]; do spawn_sleeper; CHAINR="$CHAINR $SLEEPER_PID"; i=$((i+1)); done
  # shellcheck disable=SC2086
  set -- $CHAINR
  TABLE_B1E="$W/ps-chain-hugedepth.txt"
  {
    printf '%s 1\n' "$1"
    printf '%s %s\n' "$2" "$1"
    printf '%s %s\n' "$3" "$2"
    printf '%s %s\n' "$4" "$3"
    printf '%s %s\n' "$5" "$4"
    printf '%s %s\n' "$6" "$5"
    printf '%s %s\n' "$7" "$6"
  } > "$TABLE_B1E"
  COUNT_B1E="$W/ps-count-chain-hugedepth.txt"; : > "$COUNT_B1E"
  run_kill_tree "$TABLE_B1E" "$COUNT_B1E" "$1" KILL_TREE_MAX_DEPTH=99999999999999999999
  RC_B1E=$?
  sleep 1
  ALIVE_B1E=0
  for p in $CHAINR; do if sleeper_alive "$p"; then ALIVE_B1E=$((ALIVE_B1E+1)); fi; done
  check "out-of-range KILL_TREE_MAX_DEPTH: kill_tree returns 0" "0" "$RC_B1E"
  check "out-of-range KILL_TREE_MAX_DEPTH: falls back to 32, every descendant killed" \
    "0" "$ALIVE_B1E"

  # --- B1f: KILL_TREE_SWEEPS=0 must fall back to 2, not silently no-op. A
  # ceiling-only check let 0 validate clean, so the sweep `while` ran zero
  # times and kill_tree signalled NOTHING — not even the root — and still
  # returned 0. Confirmed empirically before this fix: the target was left
  # STILL ALIVE. Same 6-deep chain shape, freshly spawned.
  CHAINZ=""
  i=0
  while [ "$i" -lt 7 ]; do spawn_sleeper; CHAINZ="$CHAINZ $SLEEPER_PID"; i=$((i+1)); done
  # shellcheck disable=SC2086
  set -- $CHAINZ
  TABLE_B1F="$W/ps-chain-zerosweeps.txt"
  {
    printf '%s 1\n' "$1"
    printf '%s %s\n' "$2" "$1"
    printf '%s %s\n' "$3" "$2"
    printf '%s %s\n' "$4" "$3"
    printf '%s %s\n' "$5" "$4"
    printf '%s %s\n' "$6" "$5"
    printf '%s %s\n' "$7" "$6"
  } > "$TABLE_B1F"
  COUNT_B1F="$W/ps-count-chain-zerosweeps.txt"; : > "$COUNT_B1F"
  run_kill_tree "$TABLE_B1F" "$COUNT_B1F" "$1" KILL_TREE_SWEEPS=0
  RC_B1F=$?
  sleep 1
  ALIVE_B1F=0
  for p in $CHAINZ; do if sleeper_alive "$p"; then ALIVE_B1F=$((ALIVE_B1F+1)); fi; done
  check "KILL_TREE_SWEEPS=0: kill_tree returns 0" "0" "$RC_B1F"
  check "KILL_TREE_SWEEPS=0: falls back to 2, every descendant killed (not a no-op)" \
    "0" "$ALIVE_B1F"

  # --- B1g: KILL_TREE_MAX_DEPTH=0 is a LEGITIMATE, documented value (root
  # only) and must NOT be rejected by the new floor — pins that semantic so
  # a future floor change on this knob cannot quietly break it. Only the
  # root dies; all 6 descendants in the same chain shape survive.
  CHAIN0=""
  i=0
  while [ "$i" -lt 7 ]; do spawn_sleeper; CHAIN0="$CHAIN0 $SLEEPER_PID"; i=$((i+1)); done
  # shellcheck disable=SC2086
  set -- $CHAIN0
  TABLE_B1G="$W/ps-chain-zerodepth.txt"
  {
    printf '%s 1\n' "$1"
    printf '%s %s\n' "$2" "$1"
    printf '%s %s\n' "$3" "$2"
    printf '%s %s\n' "$4" "$3"
    printf '%s %s\n' "$5" "$4"
    printf '%s %s\n' "$6" "$5"
    printf '%s %s\n' "$7" "$6"
  } > "$TABLE_B1G"
  COUNT_B1G="$W/ps-count-chain-zerodepth.txt"; : > "$COUNT_B1G"
  run_kill_tree "$TABLE_B1G" "$COUNT_B1G" "$1" KILL_TREE_MAX_DEPTH=0
  RC_B1G=$?
  sleep 1
  ALIVE_B1G=0
  for p in $CHAIN0; do if sleeper_alive "$p"; then ALIVE_B1G=$((ALIVE_B1G+1)); fi; done
  check "KILL_TREE_MAX_DEPTH=0: kill_tree returns 0" "0" "$RC_B1G"
  check "KILL_TREE_MAX_DEPTH=0: root-only semantic preserved, 6 descendants survive" \
    "6" "$ALIVE_B1G"

  # --- B1h: a failed `ps` snapshot must not read as an empty (childless)
  # tree. Undetected, the walk finds no children and reports a clean,
  # complete kill while the whole descendant tree keeps running — the
  # pre-fix inline version on main swallowed this identically (not a
  # regression), but it is exactly the silent-failure class this file
  # exists to close. Fake `ps` here exits 1 with NO output at all — the
  # pure "ps itself is broken/missing" case — so the root is the only pid
  # kill_tree has any chance of signalling; assert it still is, and that
  # the warning names it on stderr. KILL_TREE_SWEEPS=1 keeps the failure
  # (and so the warning) to exactly one occurrence for a clean grep -c.
  spawn_sleeper; ROOT_PSFAIL="$SLEEPER_PID"
  TABLE_PSFAIL="$W/ps-psfail-unused.txt"; : > "$TABLE_PSFAIL"
  COUNT_PSFAIL="$W/ps-count-psfail.txt"; : > "$COUNT_PSFAIL"
  STDERR_PSFAIL="$W/stderr-psfail.txt"
  # shellcheck disable=SC2016  # single-quoted: $1/$2 are positional args to `bash -c`, not this shell's vars
  timeout 20 env PATH="$W/fakebin:$PATH" FAKE_PS_TABLE="$TABLE_PSFAIL" FAKE_PS_COUNT="$COUNT_PSFAIL" FAKE_PS_FAIL=1 KILL_TREE_SWEEPS=1 \
    bash -c '. "$1"; kill_tree "$2"' _ "$KILL_TREE_LIB" "$ROOT_PSFAIL" >/dev/null 2>"$STDERR_PSFAIL"
  sleep 1
  check "failed ps snapshot: root is still signalled" \
    "killed" "$(if sleeper_alive "$ROOT_PSFAIL"; then echo alive; else echo killed; fi)"
  check "failed ps snapshot: warning names the root pid on stderr" \
    "1" "$(grep -c "$ROOT_PSFAIL" "$STDERR_PSFAIL" || true)"

  # --- B2: a table containing a parent/child CYCLE must terminate. The old
  # shape recursed forever here (and forked a `ps` per hop while doing it).
  CYC=""
  i=0
  while [ "$i" -lt 3 ]; do spawn_sleeper; CYC="$CYC $SLEEPER_PID"; i=$((i+1)); done
  # shellcheck disable=SC2086
  set -- $CYC
  TABLE_B2="$W/ps-cycle.txt"
  printf '%s 1\n%s %s\n%s %s\n%s %s\n' "$1" "$2" "$1" "$3" "$2" "$1" "$3" > "$TABLE_B2"
  COUNT_B2="$W/ps-count-cycle.txt"; : > "$COUNT_B2"
  run_kill_tree "$TABLE_B2" "$COUNT_B2" "$1"
  RC_B2=$?
  sleep 1
  ALIVE_B2=0
  for p in $CYC; do if sleeper_alive "$p"; then ALIVE_B2=$((ALIVE_B2+1)); fi; done
  check "cyclic table: kill_tree terminates (rc 124 would be the 20s timeout)" "0" "$RC_B2"
  check "cyclic table: every listed pid killed" "0" "$ALIVE_B2"

  # --- B3: the depth backstop bounds the walk. With a cap of 2 on a 6-deep
  # chain, the root and its first two generations die and the rest survive —
  # the deliberate trade the backstop makes.
  DEEP=""
  i=0
  while [ "$i" -lt 7 ]; do spawn_sleeper; DEEP="$DEEP $SLEEPER_PID"; i=$((i+1)); done
  # shellcheck disable=SC2086
  set -- $DEEP
  TABLE_B3="$W/ps-deep.txt"
  printf '%s 1\n%s %s\n%s %s\n%s %s\n%s %s\n%s %s\n%s %s\n' \
    "$1" "$2" "$1" "$3" "$2" "$4" "$3" "$5" "$4" "$6" "$5" "$7" "$6" > "$TABLE_B3"
  COUNT_B3="$W/ps-count-deep.txt"; : > "$COUNT_B3"
  run_kill_tree "$TABLE_B3" "$COUNT_B3" "$1" KILL_TREE_MAX_DEPTH=2
  sleep 1
  ALIVE_B3=0
  for p in $DEEP; do if sleeper_alive "$p"; then ALIVE_B3=$((ALIVE_B3+1)); fi; done
  check "depth backstop: KILL_TREE_MAX_DEPTH=2 stops after 3 generations" "4" "$ALIVE_B3"

  # --- B4: a root that is not a plausible pid is refused outright — no ps
  # call, no signal. Guards against a caller handing kill_tree an empty
  # string, a word, or pid 1.
  spawn_sleeper; S4="$SLEEPER_PID"
  TABLE_B4="$W/ps-guard.txt"
  printf '%s 1\n' "$S4" > "$TABLE_B4"
  COUNT_B4="$W/ps-count-guard.txt"; : > "$COUNT_B4"
  run_kill_tree "$TABLE_B4" "$COUNT_B4" "notapid"
  RC_B4=$?
  run_kill_tree "$TABLE_B4" "$COUNT_B4" ""
  run_kill_tree "$TABLE_B4" "$COUNT_B4" "1"
  sleep 1
  check "implausible root: kill_tree returns 0 without erroring" "0" "$RC_B4"
  check "implausible root: ps never consulted" "0" "$(wc -l < "$COUNT_B4" | tr -d ' ')"
  check "implausible root: unrelated process untouched" \
    "alive" "$(if sleeper_alive "$S4"; then echo alive; else echo killed; fi)"
fi

echo "--- $PASS passed, $FAIL failed, $SKIP skipped ---"
[ "$FAIL" -eq 0 ]
