#!/usr/bin/env bash
# scripts/ci/test-suite-lock-orphan-reaper.sh -- HIMMEL-3923 regression suite.
#
# A cap-killed lane worker left a run-shell-tests.sh holding the suite lock for
# 17 minutes with its PARENT dead: the owner was alive, so nothing reclaimed it.
# A waiter now recognises that orphan (owner alive + identity matches + its
# recorded parent dead + re-parented), TERMs it, and takes the lock over.
#
# Case 1 (RED at base): orphan owner is reaped and the waiter gets the lock.
# Case 2 (keep): an owner whose parent is ALIVE is never signalled.
# Case 3 (keep): a dead owner is still reclaimed as before.
# Case 4 (keep): a recycled pid (identity mismatch, or no recorded identity)
#                is never signalled, even with an orphan-shaped lock.
#
# Every case runs in a mktemp sandbox with its OWN lock path.
#
# Usage: bash scripts/ci/test-suite-lock-orphan-reaper.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail
unset SUITE_LOCK_WAIT

CI_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$CI_DIR/run-shell-tests.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

sandboxes=()
bgpids=()
# shellcheck disable=SC2317  # invoked via the EXIT trap below
cleanup() {
  local d p
  for p in ${bgpids[@]+"${bgpids[@]}"}; do kill "$p" 2>/dev/null; done
  for d in ${sandboxes[@]+"${sandboxes[@]}"}; do
    [ -f "$d/suite.pid" ] && kill "$(cat "$d/suite.pid")" 2>/dev/null
    rm -rf "$d"
  done
}
trap cleanup EXIT

# mk_sandbox -- sets global w: a sandbox with a slow holder suite and a quick one.
mk_sandbox() {
  w=$(mktemp -d "${TMPDIR:-/tmp}/lock-orphan.XXXXXX") || exit 1
  sandboxes+=("$w")
  mkdir -p "$w/slow" "$w/fast" "$w/home" "$w/tmp"
  printf '#!/usr/bin/env bash\necho $$ > "%s/suite.pid"\nexec sleep 40\n' "$w" > "$w/slow/test-slow.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$w/fast/test-fast.sh"
  chmod +x "$w/slow/test-slow.sh" "$w/fast/test-fast.sh"
}

# run_runner <w> <suite-dir> [ENV=val...] -- the runner under the sandbox's own
# lock path; output to $w/<basename suite-dir>.out.
run_runner() {
  local w="$1" sd="$2"
  shift 2
  env HOME="$w/home" TMPDIR="$w/tmp" SUITE_LOCK_DIR="$w/tmp/suite.lock" \
    HIMMEL_SUITE_SEMAPHORE_DIR="$w/tmp/sem" "$@" bash "$RUNNER" "$w/$sd"
}

# wait_lock <w> -- wait (<=10s) for the lock owner file to exist.
wait_lock() {
  local n=0
  while [ ! -f "$1/tmp/suite.lock/owner" ] && [ "$n" -lt 200 ]; do sleep 0.05; n=$((n + 1)); done
  [ -f "$1/tmp/suite.lock/owner" ]
}

owner_pid() { sed -n 's/^pid=//p' "$1/tmp/suite.lock/owner"; }

echo "== Case 1: an orphaned owner (parent dead) is reaped and the lock taken =="
mk_sandbox
# The `bash -c` shell is the owner's PARENT; it exits once the runner has branded the lock (so the recorded ppid is that shell), orphaning the runner.
bash -c '"$@" > "$0/holder.out" 2>&1 & n=0; while [ ! -f "$0/tmp/suite.lock/owner" ] && [ "$n" -lt 200 ]; do sleep 0.05; n=$((n + 1)); done' "$w" \
  env HOME="$w/home" TMPDIR="$w/tmp" SUITE_LOCK_DIR="$w/tmp/suite.lock" \
  HIMMEL_SUITE_SEMAPHORE_DIR="$w/tmp/sem" bash "$RUNNER" "$w/slow"
if case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) true ;; *) false ;; esac; then
  # ponytail: Windows Git Bash has no ps -o ppid, so the reaper keeps the old wait there; revisit when a Windows-safe parent probe exists.
  pass "SKIP: orphan reaping is not supported on Windows Git Bash"
elif ! wait_lock "$w"; then
  fail "holder never took the lock"; cat "$w/holder.out"
else
  hp=$(owner_pid "$w")
  bgpids+=("$hp")
  start=$(date +%s)
  run_runner "$w" fast SUITE_LOCK_WAIT=25 SUITE_LOCK_WAIT_INTERVAL=1 > "$w/waiter.out" 2>&1
  wrc=$?
  el=$(( $(date +%s) - start ))
  sp=$(cat "$w/suite.pid" 2>/dev/null)
  # The owner's child suite must be gone too, or the waiter would run beside it.
  if [ "$wrc" -eq 0 ] && ! kill -0 "$hp" 2>/dev/null && [ -n "$sp" ] && ! kill -0 "$sp" 2>/dev/null && grep -q "ORPHAN-REAP" "$w/waiter.out"; then
    pass "waiter took the lock in ${el}s; orphan pid $hp and its suite $sp gone"
  else
    fail "orphan not reaped (waiter rc=$wrc after ${el}s, holder alive=$(kill -0 "$hp" 2>/dev/null && echo yes || echo no))"
    cat "$w/waiter.out"
  fi
fi

echo "== Case 2: an owner whose parent is ALIVE is never signalled =="
mk_sandbox
run_runner "$w" slow > "$w/holder.out" 2>&1 & hp=$!
bgpids+=("$hp")
if ! wait_lock "$w"; then
  fail "holder never took the lock"; cat "$w/holder.out"
else
  hp=$(owner_pid "$w")
  run_runner "$w" fast SUITE_LOCK_WAIT=4 SUITE_LOCK_WAIT_INTERVAL=1 > "$w/waiter.out" 2>&1
  wrc=$?
  if [ "$wrc" -eq 5 ] && kill -0 "$hp" 2>/dev/null && ! grep -q "ORPHAN-REAP" "$w/waiter.out"; then
    pass "live-parent owner left alone (waiter rc=5)"
  else
    fail "live-parent owner mishandled (waiter rc=$wrc, holder alive=$(kill -0 "$hp" 2>/dev/null && echo yes || echo no))"
    cat "$w/waiter.out"
  fi
fi

echo "== Case 3: a dead owner is still reclaimed =="
mk_sandbox
mkdir -p "$w/tmp/suite.lock"
printf 'pid=999999\nhost=%s\nstarted=%s\nscan=x\nidentity=\nppid=1\n' "${HOSTNAME:-$(hostname)}" "$(date +%s)" > "$w/tmp/suite.lock/owner"
run_runner "$w" fast SUITE_LOCK_WAIT=10 SUITE_LOCK_WAIT_INTERVAL=1 > "$w/waiter.out" 2>&1
wrc=$?
if [ "$wrc" -eq 0 ]; then pass "dead owner reclaimed"; else fail "dead owner not reclaimed (rc=$wrc)"; cat "$w/waiter.out"; fi

echo "== Case 4: a recycled pid is never signalled =="
mk_sandbox
sleep 40 & sp=$!
bgpids+=("$sp")
# Orphan-shaped lock (recorded parent dead, current parent differs) pointing at
# an UNRELATED live process. Variant a: identity recorded but mismatching.
mkdir -p "$w/tmp/suite.lock"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=x\nidentity=posix:not-this-process\nppid=999998\n' \
  "$sp" "${HOSTNAME:-$(hostname)}" "$(date +%s)" > "$w/tmp/suite.lock/owner"
run_runner "$w" fast SUITE_LOCK_WAIT=10 SUITE_LOCK_WAIT_INTERVAL=1 > "$w/waiter.out" 2>&1
wrc=$?
if kill -0 "$sp" 2>/dev/null && ! grep -q "ORPHAN-REAP" "$w/waiter.out"; then
  pass "identity mismatch: unrelated pid untouched (waiter rc=$wrc)"
else
  fail "unrelated pid signalled or flagged (rc=$wrc)"; cat "$w/waiter.out"
fi
# Variant b: no recorded identity -> nothing proves it is the owner -> wait.
rm -rf "$w/tmp/suite.lock"
mkdir -p "$w/tmp/suite.lock"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=x\nidentity=\nppid=999998\n' \
  "$sp" "${HOSTNAME:-$(hostname)}" "$(date +%s)" > "$w/tmp/suite.lock/owner"
run_runner "$w" fast SUITE_LOCK_WAIT=3 SUITE_LOCK_WAIT_INTERVAL=1 > "$w/waiter2.out" 2>&1
wrc=$?
if kill -0 "$sp" 2>/dev/null && [ "$wrc" -eq 5 ]; then
  pass "no recorded identity: unrelated pid untouched, waiter gave up (rc=5)"
else
  fail "no-identity lock mishandled (rc=$wrc, pid alive=$(kill -0 "$sp" 2>/dev/null && echo yes || echo no))"
  cat "$w/waiter2.out"
fi

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$failures FAILED"; exit 1
