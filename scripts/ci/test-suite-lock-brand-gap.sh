#!/usr/bin/env bash
# scripts/ci/test-suite-lock-brand-gap.sh -- HIMMEL-3799 / HIMMEL-3791
# regression suite for the advisory suite lock's claim gap and its reclaim
# guard.
#
# HIMMEL-3799: _suite_lock_claim used to fork (proc_tree_process_identity --
# pwsh on Windows) BETWEEN the lock mkdir and the owner-file brand. A slow
# probe left the live lock unbranded long enough for a second run to read it
# as a crash husk and reclaim it: two holders. Case 1 reproduces that with a
# `ps` shim that delays the FIRST identity probe (no timing sweep: the delay
# is fixed and longer than the loser's whole husk spin), and asserts the two
# runs never overlap.
#
# HIMMEL-3791: a mkdir failure on the `.reclaim` guard that is NOT another
# reclaimer holding it (EACCES on a read-only parent) is a permanent refusal,
# not contention -- it must not burn the SUITE_LOCK_WAIT budget. Cases 2-3
# cover _suite_sem_reclaim and _suite_lock_reclaim.
#
# Every case runs in a mktemp sandbox with its OWN lock path.
#
# Usage: bash scripts/ci/test-suite-lock-brand-gap.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail
unset SUITE_LOCK_WAIT

CI_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$CI_DIR/run-shell-tests.sh"
SEM_LIB="$CI_DIR/../lib/suite-semaphore.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

sandboxes=()
# shellcheck disable=SC2317,SC2329  # invoked via the EXIT trap below
cleanup() {
  local d
  for d in ${sandboxes[@]+"${sandboxes[@]}"}; do
    chmod -R u+w "$d" 2>/dev/null
    rm -rf "$d"
  done
}
trap cleanup EXIT

REAL_PS=$(command -v ps)
REAL_RM=$(command -v rm)
REAL_MKDIR=$(command -v mkdir)
if [ -z "$REAL_PS" ] || [ -z "$REAL_RM" ] || [ -z "$REAL_MKDIR" ]; then
  echo "ERR: ps, rm and mkdir must all be on PATH for the shims" >&2
  exit 1
fi

echo "== Case 1: a slow identity probe leaves no unbranded gap (HIMMEL-3799) =="
w=$(mktemp -d "${TMPDIR:-/tmp}/lock-brand-gap.XXXXXX") || exit 1; sandboxes+=("$w")
mkdir -p "$w/shim" "$w/sb" "$w/home" "$w/tmp"
# Delay ONLY the first identity probe (`ps ... -o lstart=`), by longer than
# the loser's ~1s husk spin.
cat > "$w/shim/ps" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *lstart=*) if [ ! -e "$w/mark" ]; then : > "$w/mark"; sleep 2; fi ;;
esac
exec "$REAL_PS" "\$@"
EOF
# Slow the FIRST `rm` of a lock owner file (stands in for Windows fork+exec
# cost in the loser's husk drop), so F's late brand lands inside that drop
# and is deleted by it -- the double hold this ticket closes.
cat > "$w/shim/rm" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *suite.lock/owner*) if [ ! -e "$w/rmmark" ]; then : > "$w/rmmark"; sleep 3; fi ;;
esac
exec "$REAL_RM" "\$@"
EOF
cat > "$w/sb/test-hold.sh" <<'EOF'
#!/usr/bin/env bash
echo "start $(date +%s) $HOLDNAME" >> "$HOLDLOG"
sleep 4
echo "end $(date +%s) $HOLDNAME" >> "$HOLDLOG"
EOF
chmod +x "$w/shim/ps" "$w/shim/rm" "$w/sb/test-hold.sh"
lock="$w/tmp/suite.lock"; : > "$w/hold.log"
run() {
  env PATH="$w/shim:$PATH" HOME="$w/home" TMPDIR="$w/tmp" SUITE_LOCK_DIR="$lock" \
    HIMMEL_SUITE_SEMAPHORE_DIR="$w/tmp/sem" HOLDLOG="$w/hold.log" SUITE_LOCK_WAIT=60 "$@" \
    bash "$RUNNER" "$w/sb"
}
run HOLDNAME=F > "$w/F.out" 2>&1 & fp=$!
# B starts the instant F's lock dir exists (at base: unbranded, F stuck in
# the probe; fixed: F is past the probe, so the brand is already there).
n=0
while [ ! -d "$lock" ] && [ "$n" -lt 400 ]; do sleep 0.05; n=$((n + 1)); done
run HOLDNAME=B > "$w/B.out" 2>&1 & bp=$!
wait "$fp"; frc=$?
wait "$bp"; brc=$?
# Both runs must have completed their suite (start AND end logged, rc 0); a
# run that never executed would otherwise read as "no overlap".
dbl=$(awk '$1=="start"{s[$3]=$2} $1=="end"{e[$3]=$2}
  END {if (!(("F" in s) && ("B" in s) && ("F" in e) && ("B" in e))) print 2;
        else if (s["B"] < e["F"] && s["F"] < e["B"]) print 1; else print 0}' "$w/hold.log")
if [ "$frc" -ne 0 ] || [ "$brc" -ne 0 ] || [ "$dbl" = 2 ]; then
  fail "a run did not complete its suite (F rc=$frc, B rc=$brc, hold-log incomplete=$dbl)"
  cat "$w/hold.log" "$w/F.out" "$w/B.out"
elif [ "$dbl" = 0 ]; then
  pass "two runs never held the suite lock at once"
else
  fail "DOUBLE HOLD: both runs executed their suite at the same time"
  cat "$w/hold.log" "$w/B.out"
fi

echo "== Case 2: _suite_sem_reclaim refuses at once on a non-contention guard failure (HIMMEL-3791) =="
if [ "$(id -u)" = 0 ]; then
  echo "  SKIP  running as root: chmod cannot make a directory unwritable"
else
  s=$(mktemp -d "${TMPDIR:-/tmp}/lock-brand-gap.XXXXXX") || exit 1; sandboxes+=("$s")
  mkdir -p "$s/sem/slot-1"
  # A dead owner: the slot is stale, so a waiter goes for the reclaim guard.
  printf 'pid=999999\nidentity=\nlabel=x\nstarted=1\n' > "$s/sem/slot-1/owner"
  chmod a-w "$s/sem"
  start=$(date +%s)
  out=$(env HIMMEL_SUITE_SEMAPHORE_DIR="$s/sem" HIMMEL_SUITE_SLOTS=1 SUITE_LOCK_WAIT=20 \
    bash -c ". '$SEM_LIB'; suite_sem_acquire case2 hint" 2>&1)
  rc=$?
  elapsed=$(( $(date +%s) - start ))
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 75 ] && [ "$elapsed" -lt 10 ] \
    && grep -q 'cannot create the reclaim guard' <<< "$out"; then
    pass "refused permanently (rc=$rc) in ${elapsed}s, not after the wait budget"
  else
    fail "rc=$rc after ${elapsed}s (want an immediate non-75 refusal): $out"
  fi
  chmod -R u+w "$s"
fi

echo "== Case 3: _suite_lock_reclaim refuses at once on a non-contention guard failure (HIMMEL-3791) =="
if [ "$(id -u)" = 0 ]; then
  echo "  SKIP  running as root: chmod cannot make a directory unwritable"
else
  r=$(mktemp -d "${TMPDIR:-/tmp}/lock-brand-gap.XXXXXX") || exit 1; sandboxes+=("$r")
  mkdir -p "$r/sb" "$r/home" "$r/tmp" "$r/lockparent/suite.lock"
  printf '#!/usr/bin/env bash\ntrue\n' > "$r/sb/test-noop.sh"
  # An empty unbranded husk in an unwritable parent: the husk path reaches
  # the reclaim guard and its mkdir fails with EACCES, not contention.
  # (Only the lock's parent is unwritable; TMPDIR stays writable so the runner
  # reaches the lock instead of dying earlier on an unrelated mktemp.)
  chmod a-w "$r/lockparent"
  start=$(date +%s)
  out=$(env HOME="$r/home" TMPDIR="$r/tmp" SUITE_LOCK_DIR="$r/lockparent/suite.lock" \
    HIMMEL_SUITE_SEMAPHORE_DIR="$r/sem" SUITE_LOCK_WAIT=20 \
    bash "$RUNNER" "$r/sb" 2>&1)
  rc=$?
  elapsed=$(( $(date +%s) - start ))
  if [ "$rc" -ne 0 ] && [ "$elapsed" -lt 10 ] \
    && grep -q 'making the reclaim guard directory' <<< "$out"; then
    pass "refused (rc=$rc) in ${elapsed}s, not after the wait budget"
  else
    fail "rc=$rc after ${elapsed}s (want an immediate refusal): $out"
  fi
  chmod -R u+w "$r"
fi

echo "== Case 4: a guard-mkdir failure whose guard is then absent is retried once, not refused (HIMMEL-3791) =="
m=$(mktemp -d "${TMPDIR:-/tmp}/lock-brand-gap.XXXXXX") || exit 1; sandboxes+=("$m")
mkdir -p "$m/shim" "$m/sb" "$m/home" "$m/tmp/suite.lock"
printf '#!/usr/bin/env bash\ntrue\n' > "$m/sb/test-noop.sh"
# Fail the FIRST `.reclaim` mkdir WITHOUT creating it: the shape of another
# reclaimer releasing the guard between our mkdir and our existence check.
cat > "$m/shim/mkdir" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *.reclaim*) if [ ! -e "$m/mkmark" ]; then : > "$m/mkmark"; exit 1; fi ;;
esac
exec "$REAL_MKDIR" "\$@"
EOF
chmod +x "$m/shim/mkdir"
out=$(env PATH="$m/shim:$PATH" HOME="$m/home" TMPDIR="$m/tmp" SUITE_LOCK_DIR="$m/tmp/suite.lock" \
  HIMMEL_SUITE_SEMAPHORE_DIR="$m/sem" bash "$RUNNER" "$m/sb" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'cleared an unbranded suite lock' <<< "$out"; then
  pass "husk cleared after one transient guard-mkdir failure"
else
  fail "rc=$rc (want 0, a retry of the guard mkdir): $out"
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "All cases passed."
  exit 0
fi
echo "$failures case(s) FAILED."
exit 1
