#!/usr/bin/env bash
# scripts/ci/test-suite-concurrency.sh -- HIMMEL-1338 regression suite for the
# run-shell-tests.sh harness guards: the machine-wide concurrency lock, the
# per-suite cap that must reap descendants, the whole-run budget, and stdin
# isolation.
#
# These are the four ways a full-suite run could grind unattended for hours on
# 2026-07-28: nothing stopped a fifth concurrent run from starting, nothing
# stopped one run from going forever, a suite's wedged grandchildren outlived
# every cap, and a suite that read stdin ate the remaining suite list.
#
# Every case runs against a mktemp sandbox with its OWN lock path, so the suite
# never touches the real machine lock and can run inside a full-suite run.
#
# SELF-CONTAINED TERMINATION: the blocking-suite cases spawn processes and let
# the RUNNER reap them; nothing here signals a process the harness did not
# start, and the final guard below fails the suite if a fixture leaks.
#
# Usage: bash scripts/ci/test-suite-concurrency.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

# run-shell-tests.sh exports its whole environment to every child suite, and
# a queued after-report is launched with SUITE_LOCK_WAIT=21600 -- so a suite
# invocation of THIS suite inherits that value unless we clear it. Several
# cases below (W1, 2m) assert the knob is absent and fail if the inner
# runner queues instead of refusing on sight. Explicit per-case prefixes
# (e.g. W2's SUITE_LOCK_WAIT=0) still apply after this unset.
unset SUITE_LOCK_WAIT

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

CI_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$CI_DIR/run-shell-tests.sh"

if [ ! -f "$RUNNER" ]; then
  echo "FAIL: runner not found at $RUNNER"
  exit 1
fi

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

# Must resolve the host EXACTLY as the runner's _suite_lock_host does. The two
# sources disagree in case on Windows (HOSTNAME=overlord8 vs
# COMPUTERNAME=OVERLORD8), and a mismatch here would silently disable the
# runner's same-host liveness check — the abandoned-lock cases would then pass
# for the wrong reason, via the TTL, and stop testing what they name.
this_host() {
  printf '%s' "${HOSTNAME:-${COMPUTERNAME:-$(hostname 2>/dev/null || echo unknown)}}"
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/himmel-suite-concurrency.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Each case gets a fresh sandbox + a lock path inside it.
new_sandbox() {
  local d
  d=$(mktemp -d "$WORK/sbXXXXXX")
  printf '%s' "$d"
}

# ticket_list <queue-dir> -- the ticket directory names directly under a FIFO
# queue dir (HIMMEL-2623), one per line, unsorted. Each name is its owner's
# pid (round 3: no allocated sequence numbers), so `sort -n` on the output
# sorts by PID VALUE, not by arrival order -- callers that need arrival order
# read `started` from each ticket's own owner file instead (see Case W11).
# Empty output (and rc 0) when the dir does not exist yet or holds none --
# callers combine this with `sort -n`/`wc -l` rather than treating a missing
# queue dir as an error.
ticket_list() {
  local qdir="$1" f
  for f in "$qdir"/*; do
    [ -d "$f" ] || continue
    case "${f##*/}" in
      ''|*[!0-9]*) continue ;;
    esac
    printf '%s\n' "${f##*/}"
  done
}

# --------------------------------------------------------------------------
# Case 1 -- a second concurrent full-suite run REFUSES with rc 2.
#
# The holder is simulated by branding the lock with a pid that is genuinely
# alive and genuinely ours to observe: this test's own $$. That is a live
# process on this host, so the staleness check must NOT clear it, which is the
# distinction the case is really pinning down -- refusing a live holder while
# still reclaiming a dead one (Case 2).
# --------------------------------------------------------------------------
echo "== Case 1: second concurrent run refuses (rc 2) =="
sb1=$(new_sandbox)
cat > "$sb1/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lock1="$sb1/suite.lock"
mkdir -p "$lock1"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=other\n' \
  "$$" "$(this_host)" "$(date +%s)" > "$lock1/owner"

out1=$(SUITE_LOCK_DIR="$lock1" bash "$RUNNER" "$sb1" 2>&1)
rc1=$?
if [ "$rc1" -eq 2 ]; then
  pass "held lock -> rc 2"
else
  fail "held lock -> expected rc 2 got $rc1; output: $out1"
fi
if grepq "$out1" -F 'REFUSED'; then
  pass "refusal message names the condition"
else
  fail "refusal message missing REFUSED; output: $out1"
fi
if grepq "$out1" -F "pid=$$"; then
  pass "refusal message names the holder"
else
  fail "refusal message does not name the holding pid; output: $out1"
fi
# The refusal must say WHICH case it is in (HIMMEL-1805): this holder's pid
# answered the probe, so the message carries the PRESENT verdict — not the
# unverifiable one whose advice would counsel waiting on a guess.
if grepq "$out1" -F 'PID PRESENT'; then
  pass "refusal message distinguishes a probed holder (PID PRESENT verdict)"
else
  fail "refusal message missing the PID PRESENT verdict for a probed holder; output: $out1"
fi
# kill -0 proves the pid EXISTS, not that it is still the original holder
# (pids recycle), so the verdict must not overclaim aliveness (HIMMEL-1805
# round 3). Grepped in caps: the honest wording may say "not proof of life",
# which a case-sensitive -F for the verdict token must not trip on.
if grepq "$out1" -F 'ALIVE'; then
  fail "refusal overclaims ALIVE for a merely-present pid; output: $out1"
else
  pass "refusal claims presence, not aliveness"
fi
# The verdict names what this host resolved to, which also pins that the
# fixture's this_host branding really matched the runner's resolution — the
# assertion above would pass for the wrong reason if it ever did not.
if grepq "$out1" -F 'this host='; then
  pass "present-pid verdict names what this host resolved to"
else
  fail "present-pid verdict does not name this host; output: $out1"
fi
# The refused run must not have executed anything.
if grepq "$out1" -F '[PASS]'; then
  fail "refused run executed a suite anyway"
else
  pass "refused run executed nothing"
fi
# ...and it must not have stolen the lock it refused.
if [ -f "$lock1/owner" ] && grep -qF "pid=$$" "$lock1/owner"; then
  pass "refused run left the holder's lock intact"
else
  fail "refused run clobbered the holder's lock"
fi

# --------------------------------------------------------------------------
# Case 1b -- the DEFAULT lock path is keyed by scan root.
#
# Every other case here passes SUITE_LOCK_DIR explicitly, which bypasses the
# derivation entirely — so without this case the keying would be untested and
# the refusal message's "scope this run to the subtree you changed" advice
# would be unverified. Drive the real derivation by pointing TMPDIR at a
# sandbox and leaving SUITE_LOCK_DIR unset.
#
# The keying is what makes that advice actionable, and it is also why the key
# is the scan root AS GIVEN rather than its absolute path: the runs this
# bounds come from different worktrees, and an absolute key would give each
# worktree its own lock and bound nothing.
# --------------------------------------------------------------------------
echo "== Case 1b: the default lock path is keyed by scan root =="
sb1b=$(new_sandbox)
mkdir -p "$sb1b/tmp" "$sb1b/a" "$sb1b/b"
printf '#!/usr/bin/env bash\nexit 0\n' > "$sb1b/a/test-pass.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$sb1b/b/test-pass.sh"

# Mirrors the runner's derivation. Duplicated deliberately: this IS the
# contract under test, so a silent change to either side must fail here.
lock_path_for() {
  local s="${1#./}" key
  key=$(printf '%s' "$s" | sed 's#/#__#g' | tr -c 'A-Za-z0-9_-' '-')
  printf '%s/himmel-shell-suite-%s.lock' "$sb1b/tmp" "$key"
}

lock_a=$(lock_path_for "$sb1b/a")
mkdir -p "$lock_a"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=%s\n' \
  "$$" "$(this_host)" "$(date +%s)" "$sb1b/a" > "$lock_a/owner"

# `env -u SUITE_LOCK_DIR` is load-bearing, not tidiness: this is the ONLY case
# that exercises the derivation, and if the operator happens to have
# SUITE_LOCK_DIR exported the runner would use theirs and this case would pass
# while testing the override path it exists to avoid — a test that silently
# stops testing its own subject.
#
# Same scan root as the held lock -> refused, which also proves the runner
# derived the very path this test computed.
out1b=$(env -u SUITE_LOCK_DIR TMPDIR="$sb1b/tmp" bash "$RUNNER" "$sb1b/a" 2>&1)
rc1b=$?
if [ "$rc1b" -eq 2 ]; then
  pass "derived lock path is used (same scan root -> rc 2)"
else
  fail "derived lock path unused: expected rc 2 got $rc1b; output: $out1b"
fi

# A DIFFERENT scan root -> different key -> runs now, not queued behind it.
out1b2=$(env -u SUITE_LOCK_DIR TMPDIR="$sb1b/tmp" bash "$RUNNER" "$sb1b/b" 2>&1)
rc1b2=$?
if [ "$rc1b2" -eq 0 ]; then
  pass "a different scan root takes a different lock (rc 0)"
else
  fail "scoped run queued behind an unrelated scan root: expected rc 0 got $rc1b2; output: $out1b2"
fi

# --------------------------------------------------------------------------
# Case 2 -- an ABANDONED lock is reclaimed, not honoured forever.
#
# A crashed run that left its lock behind must not wedge the box until someone
# notices.
#
# The dead pid is one we OBSERVED die, not a large constant hoped to be out of
# range: pid_max is tunable up to 4194304 on Linux, so a hardcoded 999999 can
# name a live process and make this case fail for a reason that has nothing to
# do with the lock. Spawn a trivial child, reap it, and reuse its pid — dead by
# construction on every platform.
# --------------------------------------------------------------------------
echo "== Case 2: abandoned lock is reclaimed =="
sb2=$(new_sandbox)
cat > "$sb2/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
bash -c 'exit 0' & dead_pid=$!
wait "$dead_pid" 2>/dev/null
lock2="$sb2/suite.lock"
mkdir -p "$lock2"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=crashed\n' \
  "$dead_pid" "$(this_host)" "$(date +%s)" > "$lock2/owner"

out2=$(SUITE_LOCK_DIR="$lock2" bash "$RUNNER" "$sb2" 2>&1)
rc2=$?
if [ "$rc2" -eq 0 ]; then
  pass "dead holder -> lock reclaimed, run proceeds (rc 0)"
else
  fail "dead holder -> expected rc 0 got $rc2; output: $out2"
fi
if grepq "$out2" -F 'abandoned'; then
  pass "reclaim is announced, not silent"
else
  fail "reclaim was silent; output: $out2"
fi

# Same again via the TTL, for a lock whose pid still answers but is far too
# old to be this run (the recycled-pid backstop).
echo "== Case 2b: TTL expiry reclaims a lock whose pid still answers =="
sb2b=$(new_sandbox)
cat > "$sb2b/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lock2b="$sb2b/suite.lock"
mkdir -p "$lock2b"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=ancient\n' \
  "$$" "$(this_host)" "$(( $(date +%s) - 100000 ))" \
  > "$lock2b/owner"

out2b=$(SUITE_LOCK_DIR="$lock2b" SUITE_LOCK_TTL=60 bash "$RUNNER" "$sb2b" 2>&1)
rc2b=$?
if [ "$rc2b" -eq 0 ]; then
  pass "TTL-expired lock -> reclaimed (rc 0)"
else
  fail "TTL-expired lock -> expected rc 0 got $rc2b; output: $out2b"
fi

# --------------------------------------------------------------------------
# Case 2c -- an UNBRANDED lock dir (no owner file) is cleared, not honoured.
#
# The lock is made in two steps: mkdir, then brand. A crash in between leaves
# a directory nobody owns and no staleness check can judge -- no pid to probe,
# no timestamp to age out. Reading that as "held" would refuse every future
# run on the machine until a human noticed a stray directory in /tmp, which is
# a worse outage than the contention the lock exists to prevent. This is an
# advisory scheduling lock, so it fails OPEN with a trail.
# --------------------------------------------------------------------------
echo "== Case 2c: an unbranded lock dir is cleared =="
sb2c=$(new_sandbox)
cat > "$sb2c/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lock2c="$sb2c/suite.lock"
mkdir -p "$lock2c"   # directory only -- no owner file, as a crashed claim leaves it

out2c=$(SUITE_LOCK_DIR="$lock2c" bash "$RUNNER" "$sb2c" 2>&1)
rc2c=$?
if [ "$rc2c" -eq 0 ]; then
  pass "unbranded lock -> cleared, run proceeds (rc 0)"
else
  fail "unbranded lock -> expected rc 0 got $rc2c; output: $out2c"
fi
if grepq "$out2c" -F 'unbranded'; then
  pass "unbranded-lock clearing is announced"
else
  fail "unbranded-lock clearing was silent; output: $out2c"
fi

# --------------------------------------------------------------------------
# Case 2d -- a mis-set SUITE_LOCK_DIR must never destroy data.
#
# SUITE_LOCK_DIR is env-controlled, and the abandoned-lock path clears an
# unbranded directory. Recursively, that is a loaded gun: point the override at
# a real directory by typo and the runner would erase it. The lock only ever
# creates one file, so clearing is `owner` + rmdir — and rmdir refuses a
# non-empty directory, which IS the "this is not my lock" signal.
# --------------------------------------------------------------------------
echo "== Case 2d: a mis-set SUITE_LOCK_DIR does not delete a real directory =="
sb2d=$(new_sandbox)
cat > "$sb2d/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
# Stand in for the typo target: a directory with real content and no owner file.
precious="$sb2d/precious"
mkdir -p "$precious/nested"
printf 'do not delete me\n' > "$precious/keep.txt"
printf 'nor me\n' > "$precious/nested/deep.txt"

out2d=$(SUITE_LOCK_DIR="$precious" bash "$RUNNER" "$sb2d" 2>&1)
rc2d=$?
if [ -f "$precious/keep.txt" ] && [ -f "$precious/nested/deep.txt" ]; then
  pass "a non-empty lock-dir override is left intact"
else
  fail "the runner DELETED a non-empty directory named by SUITE_LOCK_DIR"
fi

# The harder shape: the mis-pointed directory happens to contain a file named
# `owner` whose content parses as an ancient `started=`, so the lock reads as
# ABANDONED and the takeover path engages. Relying on rmdir to refuse the
# non-empty directory is too late here — `owner` is unlinked first, so the
# file is already gone by the time the guard fires. Nothing may be deleted
# until the directory has been proven to be a lock.
echo "== Case 2d2: a foreign directory containing an 'owner' file is untouched =="
sb2d2=$(new_sandbox)
cat > "$sb2d2/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
decoy="$sb2d2/decoy"
mkdir -p "$decoy"
printf 'started=1\nsomething the operator cares about\n' > "$decoy/owner"
printf 'also mine\n' > "$decoy/other.txt"

out2d2=$(SUITE_LOCK_DIR="$decoy" bash "$RUNNER" "$sb2d2" 2>&1)
rc2d2=$?
if [ -f "$decoy/owner" ] && [ -f "$decoy/other.txt" ]; then
  pass "a foreign 'owner' file survives the abandoned-lock path"
else
  fail "the runner deleted a foreign file named 'owner' before proving the dir was a lock"
fi
if [ "$rc2d2" -eq 2 ]; then
  pass "the undroppable lock path refuses (rc 2)"
else
  fail "foreign owner-file dir -> expected rc 2 got $rc2d2; output: $out2d2"
fi
# The verdict must not relabel an operational failure as contention
# (HIMMEL-1805 round 4): this directory is not a lock and the reclaim refused
# to delete foreign content -- a condition re-running cannot clear, so the
# race verdict's "re-run in a moment" advice would send an unattended job
# retrying forever without ever seeing the real requirement.
if grepq "$out2d2" -F 'TAKEOVER IN PROGRESS'; then
  fail "an operational reclaim failure is reported as a takeover race; output: $out2d2"
else
  pass "operational reclaim failure does not use the race verdict"
fi
if grepq "$out2d2" -F 'RECLAIM FAILED'; then
  pass "operational reclaim failure has a verdict of its own"
else
  fail "operational reclaim failure has no verdict of its own; output: $out2d2"
fi
if grepq "$out2d2" -F 'RECLAIM ERROR'; then
  pass "the concrete reclaim error is named"
else
  fail "no concrete reclaim error named; output: $out2d2"
fi
if [ "$rc2d" -eq 2 ]; then
  pass "an unusable lock path refuses (rc 2) rather than proceeding unlocked"
else
  fail "unusable lock path -> expected rc 2 got $rc2d; output: $out2d"
fi
if grepq "$out2d" -F 'not look like a suite lock'; then
  pass "the refusal explains what it will not touch"
else
  fail "refusal did not explain itself; output: $out2d"
fi

# --------------------------------------------------------------------------
# Case 2e -- a takeover is EXCLUSIVE: a live foreign claim blocks it.
#
# Two runs that both judge the same lock stale must not both reclaim it.
# Dropping-then-claiming does not prevent that on its own: the second dropper
# removes the first's fresh brand and rmdir's its now-empty directory, so both
# end up believing they hold the lock. The right to take over is therefore
# claimed with mkdir first (the takeover protocol scripts/handover/queue-lock.sh
# arrived at for the same race). A live claim held by someone else means the
# takeover is theirs, so this run refuses.
# --------------------------------------------------------------------------
echo "== Case 2e: a live foreign takeover claim blocks the reclaim =="
sb2e=$(new_sandbox)
cat > "$sb2e/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lock2e="$sb2e/suite.lock"
mkdir -p "$lock2e"
bash -c 'exit 0' & dead2e=$!
wait "$dead2e" 2>/dev/null
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=crashed\n' \
  "$dead2e" "$(this_host)" "$(date +%s)" > "$lock2e/owner"
# Another run is mid-takeover of this same abandoned lock.
mkdir -p "$lock2e.claim"
printf 'pid=1\nstarted=%s\n' "$(date +%s)" > "$lock2e.claim/owner"

out2e=$(SUITE_LOCK_DIR="$lock2e" bash "$RUNNER" "$sb2e" 2>&1)
rc2e=$?
if [ "$rc2e" -eq 2 ]; then
  pass "abandoned lock + live foreign claim -> refused (rc 2)"
else
  fail "takeover was not exclusive: expected rc 2 got $rc2e; output: $out2e"
fi
if [ -d "$lock2e.claim" ]; then
  pass "the other taker's claim is left alone"
else
  fail "the run destroyed another taker's live claim"
fi
# The refusal must describe the state it observed (HIMMEL-1805 round 3): this
# run SAW a dead same-host pid and judged the lock abandoned. Losing the
# takeover race to another taker is not "the owner records no pid" — there was
# a pid, it was dead, and the race was lost — and the generation that judgement
# came from is too stale to quote TTL arithmetic out of.
if grepq "$out2e" -F 'records no pid'; then
  fail "takeover-race refusal claims the owner records no pid; output: $out2e"
else
  pass "takeover-race refusal does not claim a missing pid"
fi
if grepq "$out2e" -F 'TTL backstop reclaims'; then
  fail "takeover-race refusal quotes TTL advice from the stale generation; output: $out2e"
else
  pass "takeover-race refusal gives no stale-generation TTL advice"
fi
if grepq "$out2e" -F 'TAKEOVER IN PROGRESS'; then
  pass "takeover-race refusal names the race (TAKEOVER IN PROGRESS verdict)"
else
  fail "takeover-race refusal missing the TAKEOVER IN PROGRESS verdict; output: $out2e"
fi

# --------------------------------------------------------------------------
# Case 2f -- a STRANDED claim (its taker crashed) must not wedge takeovers.
#
# The claim is exclusive, so a taker that dies holding one would otherwise
# block every future takeover of that lock forever. It carries its own
# timestamp and is expired after 120s.
# --------------------------------------------------------------------------
echo "== Case 2f: a stranded takeover claim is expired, not honoured forever =="
sb2f=$(new_sandbox)
cat > "$sb2f/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lock2f="$sb2f/suite.lock"
mkdir -p "$lock2f"
bash -c 'exit 0' & dead2f=$!
wait "$dead2f" 2>/dev/null
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=crashed\n' \
  "$dead2f" "$(this_host)" "$(date +%s)" > "$lock2f/owner"
mkdir -p "$lock2f.claim"
printf 'pid=1\nstarted=%s\n' "$(( $(date +%s) - 300 ))" > "$lock2f.claim/owner"

out2f=$(SUITE_LOCK_DIR="$lock2f" bash "$RUNNER" "$sb2f" 2>&1)
rc2f=$?
if [ "$rc2f" -eq 0 ]; then
  pass "stranded claim expired -> takeover proceeds (rc 0)"
else
  fail "stranded claim wedged the takeover: expected rc 0 got $rc2f; output: $out2f"
fi
if grepq "$out2f" -F 'stranded takeover claim'; then
  pass "the claim expiry is announced, not silent"
else
  fail "claim expiry was silent; output: $out2f"
fi

# --------------------------------------------------------------------------
# Case 2d3 -- a SYMLINKED lock path is refused outright.
#
# The sharpest shape of the mis-set-override class: globbing inspects the
# TARGET while `rm` writes through the link, so the content checks that prove
# "this is my lock" are answered by one directory and acted on in another.
# This script only ever creates real directories, so a symlink is always wrong.
#
# Skipped where symlinks cannot be created (Windows without the privilege) —
# the same guard scripts/codex/test-dispatch-codex-wsl.sh uses.
# --------------------------------------------------------------------------
echo "== Case 2d3: a symlinked lock path is refused =="
sb2d3=$(new_sandbox)
cat > "$sb2d3/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
target="$sb2d3/target"
mkdir -p "$target"
printf 'started=1\nvaluable\n' > "$target/owner"
link="$sb2d3/link"
if ln -s "$target" "$link" 2>/dev/null && [ -L "$link" ]; then
  out2d3=$(SUITE_LOCK_DIR="$link" bash "$RUNNER" "$sb2d3" 2>&1)
  rc2d3=$?
  if [ -f "$target/owner" ]; then
    pass "a symlinked lock path leaves the target's contents alone"
  else
    fail "the runner wrote through a symlinked SUITE_LOCK_DIR and deleted the target's owner file"
  fi
  if [ "$rc2d3" -eq 2 ]; then
    pass "a symlinked lock path refuses (rc 2)"
  else
    fail "symlinked lock path -> expected rc 2 got $rc2d3; output: $out2d3"
  fi
  if grepq "$out2d3" -F 'is a symlink'; then
    pass "the refusal names the reason"
  else
    fail "symlink refusal did not name the reason; output: $out2d3"
  fi
else
  echo "  SKIP  symlink creation unavailable on this host"
fi

# --------------------------------------------------------------------------
# Case 2g -- an UNBRANDED takeover claim must not wedge reclaim forever.
#
# The claim is branded just after its mkdir, so a crash in that window leaves a
# directory with no timestamp. Honouring an undateable claim as "live" would
# block every future takeover of this lock permanently, with no way back except
# a human deleting a directory in /tmp — the same husk-wedges-everything shape
# case 2c covers for the lock directory itself, which this originally repeated.
# --------------------------------------------------------------------------
echo "== Case 2g: an unbranded takeover claim is cleared, not honoured forever =="
sb2g=$(new_sandbox)
cat > "$sb2g/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lock2g="$sb2g/suite.lock"
mkdir -p "$lock2g"
bash -c 'exit 0' & dead2g=$!
wait "$dead2g" 2>/dev/null
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=crashed\n' \
  "$dead2g" "$(this_host)" "$(date +%s)" > "$lock2g/owner"
mkdir -p "$lock2g.claim"   # directory only -- no owner file, as a crash leaves it

out2g=$(SUITE_LOCK_DIR="$lock2g" bash "$RUNNER" "$sb2g" 2>&1)
rc2g=$?
if [ "$rc2g" -eq 0 ]; then
  pass "unbranded claim -> cleared, takeover proceeds (rc 0)"
else
  fail "unbranded claim wedged the takeover: expected rc 0 got $rc2g; output: $out2g"
fi

# --------------------------------------------------------------------------
# Case 2h -- a FOREIGN-host holder is refused until the TTL (HIMMEL-1805).
#
# A pid from another machine says nothing about liveness here, so the probe
# is skipped by design and the lock is honoured until its TTL expires -- even
# when the pid is one this test OBSERVED die. The refusal must say that
# case: the holder is UNVERIFIABLE, not alive, and the message names what
# this host resolved to, so a same-machine host-string divergence is
# diagnosable from the output instead of silent.
# --------------------------------------------------------------------------
echo "== Case 2h: a foreign-host holder is refused until the TTL =="
sb2h=$(new_sandbox)
cat > "$sb2h/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
bash -c 'exit 0' & dead2h=$!
wait "$dead2h" 2>/dev/null

lock2h="$sb2h/suite.lock"
mkdir -p "$lock2h"
printf 'pid=%s\nhost=some-other-host\nstarted=%s\nscan=remote\n' \
  "$dead2h" "$(date +%s)" > "$lock2h/owner"

out2h=$(SUITE_LOCK_DIR="$lock2h" bash "$RUNNER" "$sb2h" 2>&1)
rc2h=$?
if [ "$rc2h" -eq 2 ]; then
  pass "foreign-host holder with a dead pid -> still refused (rc 2)"
else
  fail "foreign-host holder -> expected rc 2 got $rc2h; output: $out2h"
fi
if grepq "$out2h" -F 'UNVERIFIABLE'; then
  pass "foreign-host refusal says the holder is unverifiable"
else
  fail "foreign-host refusal missing the UNVERIFIABLE verdict; output: $out2h"
fi
if grepq "$out2h" -F 'PID PRESENT'; then
  fail "foreign-host refusal claims a probed-present pid"
else
  pass "foreign-host refusal does not claim a probed-present pid"
fi
if grepq "$out2h" -F 'this host='; then
  pass "foreign-host refusal names what this host resolved to"
else
  fail "foreign-host refusal does not name this host; output: $out2h"
fi
if grepq "$out2h" -F 'TTL backstop'; then
  pass "foreign-host refusal names the TTL as the way out"
else
  fail "foreign-host refusal missing the TTL advice; output: $out2h"
fi

# The "until the TTL" half: the SAME foreign shape, aged past its TTL, is
# reclaimed -- the backstop really is the only way a foreign lock frees.
echo "== Case 2h2: a foreign-host lock past its TTL is reclaimed =="
lock2h2="$sb2h/suite2.lock"
mkdir -p "$lock2h2"
printf 'pid=%s\nhost=some-other-host\nstarted=%s\nscan=remote\n' \
  "$dead2h" "$(( $(date +%s) - 100000 ))" > "$lock2h2/owner"

out2h2=$(SUITE_LOCK_DIR="$lock2h2" SUITE_LOCK_TTL=60 bash "$RUNNER" "$sb2h" 2>&1)
rc2h2=$?
if [ "$rc2h2" -eq 0 ]; then
  pass "foreign-host lock past TTL -> reclaimed (rc 0)"
else
  fail "foreign-host lock past TTL -> expected rc 0 got $rc2h2; output: $out2h2"
fi

# --------------------------------------------------------------------------
# Case 2i -- a host differing only in CASE is still this host (HIMMEL-1805).
#
# _suite_lock_host's sources disagree in case on Windows (bash's own
# HOSTNAME=overlord8 vs the COMPUTERNAME=OVERLORD8 fallback), and an
# inherited HOSTNAME survives into child bash -- so two runs on the SAME
# machine can brand and probe under different spellings. A case-strict
# compare silently skipped the liveness probe and refused a provably dead
# same-machine pid until the TTL: the exact observed incident. The match is
# case-insensitive; a genuinely different name (Case 2h) still mismatches.
# --------------------------------------------------------------------------
echo "== Case 2i: a case-variant host still counts as this host =="
# The variant must actually VARY, or this case is vacuous: on a host whose
# resolved name has no lowercase letters (the COMPUTERNAME=OVERLORD8 fallback
# is all-caps), upper-casing is a no-op and the "variant" would silently test
# the plain same-host path — green, but not testing what it names. Fold the
# other way when the first fold changes nothing; a name with no letters at
# all cannot be varied, and the case says so instead of passing quietly.
# (this_host, defined at the top of this file, resolves EXACTLY as the
# runner's _suite_lock_host does.)
variant_host=$(printf '%s' "$(this_host)" | tr '[:lower:]' '[:upper:]')
if [ "$variant_host" = "$(this_host)" ]; then
  variant_host=$(printf '%s' "$(this_host)" | tr '[:upper:]' '[:lower:]')
fi

if [ "$variant_host" != "$(this_host)" ]; then
sb2i=$(new_sandbox)
cat > "$sb2i/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF

# Dead pid under the case-variant spelling -> probed, found dead, RECLAIMED.
bash -c 'exit 0' & dead2i=$!
wait "$dead2i" 2>/dev/null
lock2i="$sb2i/suite.lock"
mkdir -p "$lock2i"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=crashed\n' \
  "$dead2i" "$variant_host" "$(date +%s)" > "$lock2i/owner"

out2i=$(SUITE_LOCK_DIR="$lock2i" bash "$RUNNER" "$sb2i" 2>&1)
rc2i=$?
if [ "$rc2i" -eq 0 ]; then
  pass "dead pid under a case-variant host spelling -> reclaimed (rc 0)"
else
  fail "case-variant host: expected reclaim rc 0 got $rc2i; output: $out2i"
fi

# LIVE pid under the case-variant spelling -> probed, answers, still refuses:
# case-folding widens the probe to same-machine spellings, never past them.
lock2i2="$sb2i/suite2.lock"
mkdir -p "$lock2i2"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=live\n' \
  "$$" "$variant_host" "$(date +%s)" > "$lock2i2/owner"

out2i2=$(SUITE_LOCK_DIR="$lock2i2" bash "$RUNNER" "$sb2i" 2>&1)
rc2i2=$?
if [ "$rc2i2" -eq 2 ]; then
  pass "live pid under a case-variant host spelling -> still refused (rc 2)"
else
  fail "case-variant host with a live pid: expected rc 2 got $rc2i2; output: $out2i2"
fi
if grepq "$out2i2" -F 'PID PRESENT'; then
  pass "case-variant live refusal carries the PID PRESENT verdict"
else
  fail "case-variant live refusal missing the PID PRESENT verdict; output: $out2i2"
fi
else
  echo "  SKIP  host name has no letters to case-vary on this host"
fi

# --------------------------------------------------------------------------
# Case 2j -- a LIVE holder the probe may not signal is NOT reclaimed
# (HIMMEL-1805 round 4).
#
# POSIX kill -0 fails for ESRCH (no such process) AND for EPERM (the caller
# may not signal it): a live holder running under another account fails the
# probe exactly like a dead one, so reading every failure as "holder dead"
# reclaims a live holder's lock out from under it -- a fail-OPEN, the opposite
# direction of every other defect in this arc, all of which merely withheld a
# warning. A refusal the probe cannot explain must fall through to the TTL
# instead (the HIMMEL-1776 convention: unknown never takes the permissive
# path).
#
# The holder is THIS TEST'S pid: genuinely alive on this host. An exported
# kill() shim makes `kill -0 <that pid>` fail the way it fails for such a
# holder -- refused with a reason that is not "no such process" -- while every
# other call delegates to the real builtin, so the runner's watchdog and
# termination behaviour is unchanged.
# --------------------------------------------------------------------------
echo "== Case 2j: a live holder the probe may not signal is not reclaimed =="
sb2j=$(new_sandbox)
cat > "$sb2j/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lock2j="$sb2j/suite.lock"
mkdir -p "$lock2j"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=other-user\n' \
  "$$" "$(this_host)" "$(date +%s)" > "$lock2j/owner"

probe_refuse_pid=$$
# shellcheck disable=SC2317,SC2329  # invoked by the runner child via export -f
kill() {
  if [ "$1" = "-0" ] && [ "$2" = "$probe_refuse_pid" ]; then
    printf 'bash: kill: (%s) - Operation not permitted\n' "$2" >&2
    return 1
  fi
  builtin kill "$@"
}
export -f kill
export probe_refuse_pid

out2j=$(SUITE_LOCK_DIR="$lock2j" bash "$RUNNER" "$sb2j" 2>&1)
rc2j=$?
unset -f kill
unset probe_refuse_pid

if [ "$rc2j" -eq 2 ]; then
  pass "live but unsignalable holder -> refused, not reclaimed (rc 2)"
else
  fail "live but unsignalable holder -> expected rc 2 got $rc2j; output: $out2j"
fi
if [ -f "$lock2j/owner" ] && grep -qF "pid=$$" "$lock2j/owner"; then
  pass "a refused probe left the live holder's lock intact"
else
  fail "the refusal reclaimed a live holder's lock; output: $out2j"
fi
if grepq "$out2j" -F 'UNVERIFIABLE'; then
  pass "refused-probe refusal says the holder is unverifiable"
else
  fail "refused-probe refusal missing the UNVERIFIABLE verdict; output: $out2j"
fi
# The probe was REFUSED, not answered: claiming the pid was probed present
# would be the same overread this case exists to catch, in the other
# direction.
if grepq "$out2j" -F 'PID PRESENT'; then
  fail "refused-probe refusal claims a probed-present pid; output: $out2j"
else
  pass "refused-probe refusal does not claim a probed-present pid"
fi
if grepq "$out2j" -F 'TTL backstop'; then
  pass "refused-probe refusal names the TTL as the way out"
else
  fail "refused-probe refusal missing the TTL advice; output: $out2j"
fi

# --------------------------------------------------------------------------
# Case 2j2 -- the UNDATED sibling of 2j: a same-host holder whose probe was
# refused AND whose owner file carries no "started" line at all (HIMMEL-1805
# round 6).
#
# age starts at -1 and only becomes a duration when the owner's started field
# parses, so this shape -- a pid, this host, a probe refused for a reason that
# is not "no such process", and no timestamp -- is the one refusal path where
# age stays the sentinel: not stale (a refused probe is not death), not
# datable. Printed as "-1s" it reads as a measurement, and the TTL sentence
# it anchored named a backstop that can never fire -- age=-1 never reaches
# the TTL -- so the refusal must say the age is unknown instead of quoting
# arithmetic out of the sentinel.
# --------------------------------------------------------------------------
echo "== Case 2j2: an undated holder with a refused probe gets no TTL advice =="
sb2j2=$(new_sandbox)
cat > "$sb2j2/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lock2j2="$sb2j2/suite.lock"
mkdir -p "$lock2j2"
printf 'pid=%s\nhost=%s\nscan=other-user\n' \
  "$$" "$(this_host)" > "$lock2j2/owner"

probe_refuse_pid=$$
# shellcheck disable=SC2317,SC2329  # invoked by the runner child via export -f
kill() {
  if [ "$1" = "-0" ] && [ "$2" = "$probe_refuse_pid" ]; then
    printf 'bash: kill: (%s) - Operation not permitted\n' "$2" >&2
    return 1
  fi
  builtin kill "$@"
}
export -f kill
export probe_refuse_pid

out2j2=$(SUITE_LOCK_DIR="$lock2j2" bash "$RUNNER" "$sb2j2" 2>&1)
rc2j2=$?
unset -f kill
unset probe_refuse_pid

if [ "$rc2j2" -eq 2 ]; then
  pass "undated holder with a refused probe -> refused, not reclaimed (rc 2)"
else
  fail "undated holder with a refused probe -> expected rc 2 got $rc2j2; output: $out2j2"
fi
if [ -f "$lock2j2/owner" ] && grep -qF "pid=$$" "$lock2j2/owner"; then
  pass "a refused probe left the undated holder's lock intact"
else
  fail "the refusal reclaimed an undated holder's lock; output: $out2j2"
fi
if grepq "$out2j2" -F 'TTL backstop reclaims'; then
  fail "undated refusal quotes a TTL backstop that can never fire; output: $out2j2"
else
  pass "undated refusal does not quote TTL reclamation advice"
fi
if grepq "$out2j2" -F 'no usable "started" timestamp'; then
  pass "undated refusal says the owner has no usable started timestamp"
else
  fail "undated refusal missing the no-usable-started advice; output: $out2j2"
fi
if grepq "$out2j2" -F 'age=-1'; then
  fail "undated refusal prints the age sentinel as a duration (age=-1); output: $out2j2"
else
  pass "undated refusal does not print the raw age sentinel"
fi

# A non-numeric pid is not probeable owner metadata. Treat it exactly like a
# missing pid, so an undated same-host lock cannot be wedged by a corrupt value.
echo "== Case 2j3: an undated holder with a non-numeric pid is reclaimed =="
sb2j3=$(new_sandbox)
cat > "$sb2j3/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lock2j3="$sb2j3/suite.lock"
mkdir -p "$lock2j3"
printf 'pid=not-a-pid\nhost=%s\nscan=corrupt\n' "$(this_host)" > "$lock2j3/owner"

out2j3=$(SUITE_LOCK_DIR="$lock2j3" bash "$RUNNER" "$sb2j3" 2>&1)
rc2j3=$?
if [ "$rc2j3" -eq 0 ]; then
  pass "undated holder with a non-numeric pid -> reclaimed (rc 0)"
else
  fail "undated holder with a non-numeric pid -> expected rc 0 got $rc2j3; output: $out2j3"
fi

# --------------------------------------------------------------------------
# Cases 2k/2l/2m -- a failed reclaim step answered by a LIVE WINNER is
# contention, not an operational failure (HIMMEL-1805 round 5).
#
# Round 4 split the reclaim's return codes but split them the wrong way for
# three ORDINARY races: after a stranded claim is cleared, another taker can
# win the re-mkdir (2k); the noclobber brand can lose to the uutils co-winner
# of the claim mkdir this code explicitly anticipates (2l, HIMMEL-966); and
# after the stale lock is dropped, a normal acquirer can win the re-acquire
# before _suite_lock_claim does (2m). All three printed RECLAIM FAILED with
# advice to remove the lock by hand -- while a live runner may own it, the
# exact starvation HIMMEL-1338 exists to prevent, then actively recommended
# by the refusal.
#
# Each race is injected deterministically by shadowing mkdir ON PATH for the
# one runner invocation: a shim directory is prepended to PATH carrying a
# `mkdir` script that delegates to the real binary unless this is the exact
# target path on the exact Nth call -- in which case the "other party" wins
# by creating the directory AND branding a fresh foreign owner into it. "A
# live winner exists" is precisely what the classification must check before
# calling a failed step operational. A PATH shim, not an exported mkdir()
# function (the Case 2j kill() technique): a function named mkdir defined
# here would make every earlier mkdir -p fixture call in this file resolve
# to it statically (shellcheck SC2218), while the shim is live only for the
# prefixed invocation. The call counter lives in a file because each shim
# invocation is its own process.
#
# Shared assertions per case: the refusal carries the TAKEOVER IN PROGRESS
# verdict (retry advice), NOT the RECLAIM FAILED verdict (dead-end advice),
# the co-winner's brand is left intact, and the shim's own call counter
# proves the race fired (race_shim_fired) — a shim PATH refused to execute
# must FAIL the case rather than assert against a scenario that never
# happened.
# --------------------------------------------------------------------------
race_shim_prepare() {
  RACE_SHIM_DIR=$(mktemp -d "$WORK/shimXXXXXX")
  RACE_REAL_MKDIR=$(command -v mkdir)
  export RACE_REAL_MKDIR
  cat > "$RACE_SHIM_DIR/mkdir" <<'SHEOF'
#!/usr/bin/env bash
# Test shim, not a runtime component: shadows mkdir on PATH for one runner
# invocation. Delegates to the real mkdir unless this is the injected race.
if [ "$#" -eq 1 ] && [ "$1" = "${RACE_TARGET:-}" ]; then
  n=$(( $(cat "${RACE_HITS:?}" 2>/dev/null || printf '0') + 1 ))
  printf '%s' "$n" > "${RACE_HITS:?}"
  if [ "$n" -eq "${RACE_HIT_NO:?}" ]; then
    "${RACE_REAL_MKDIR:?}" "$1"
    printf 'pid=%s\nhost=co-winner\nstarted=%s\nscan=%s\n' \
      "$$" "$(date +%s)" "${RACE_SCAN:?}" > "$1/owner"
    exit "${RACE_SIM_RC:?}"
  fi
fi
exec "${RACE_REAL_MKDIR:?}" "$@"
SHEOF
  # The heredoc creates the shim mode 644, and PATH lookup needs the execute
  # bit on Linux/macOS — without this the shim is silently skipped, mkdir
  # resolves to the real binary, and the races below never happen. MSYS /tmp
  # is noacl (a created file reads as +x whatever its bits), which is why the
  # hole was invisible on the dev box; race_shim_fired in each case is the
  # tripwire that turns any future skip back into a failure that names itself.
  chmod +x "$RACE_SHIM_DIR/mkdir"
}

# race_shim_fired <hits-file> <hit-no> — the case's race really happened.
#
# The hits file is written ONLY by the shim, so a missing file — or a count
# that never reached the injection call — means PATH resolved mkdir to the
# real binary and no race was injected. The verdict assertions around this
# check would then be evaluated against a scenario that did not occur, so the
# case FAILS here, naming the cause, before they can lend a vacuous result
# any credibility.
race_shim_fired() {
  if [ -f "$1" ] && [ "$(cat "$1" 2>/dev/null || printf '0')" -ge "$2" ]; then
    pass "the injected race fired (shim reached mkdir call $2)"
  else
    fail "the injected race never fired (counter $(cat "$1" 2>/dev/null || printf 'absent') never reached $2): the mkdir shim was skipped — this case's scenario did not happen"
  fi
}
race_shim_prepare

echo "== Case 2k: a claim won between the stranded-claim drop and the re-mkdir =="
sb2k=$(new_sandbox)
cat > "$sb2k/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lock2k="$sb2k/suite.lock"
mkdir -p "$lock2k"
bash -c 'exit 0' & dead2k=$!
wait "$dead2k" 2>/dev/null
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=crashed\n' \
  "$dead2k" "$(this_host)" "$(date +%s)" > "$lock2k/owner"
# A stranded claim, aged past its 120s expiry so the runner clears it.
mkdir -p "$lock2k.claim"
printf 'pid=1\nstarted=%s\n' "$(( $(date +%s) - 300 ))" > "$lock2k.claim/owner"

# Hit #2 on the claim path is the re-mkdir after the runner dropped the
# stranded claim -- where the co-taker wins the freed slot.
out2k=$(PATH="$RACE_SHIM_DIR:$PATH" RACE_TARGET="$lock2k.claim" RACE_HIT_NO=2 \
  RACE_SIM_RC=1 RACE_SCAN=case2k-co-taker RACE_HITS="$sb2k/hits" \
  SUITE_LOCK_DIR="$lock2k" bash "$RUNNER" "$sb2k" 2>&1)
rc2k=$?
race_shim_fired "$sb2k/hits" 2

if [ "$rc2k" -eq 2 ]; then
  pass "claim lost between drop and re-mkdir -> refused (rc 2)"
else
  fail "claim lost between drop and re-mkdir -> expected rc 2 got $rc2k; output: $out2k"
fi
if grepq "$out2k" -F 'TAKEOVER IN PROGRESS'; then
  pass "lost re-mkdir is reported as the race it is"
else
  fail "lost re-mkdir missing the TAKEOVER IN PROGRESS verdict; output: $out2k"
fi
if grepq "$out2k" -F 'RECLAIM FAILED'; then
  fail "an ordinary claim race is reported as an operational failure; output: $out2k"
else
  pass "claim race is not reported as an operational failure"
fi
if [ -f "$lock2k.claim/owner" ] && grep -qF 'scan=case2k-co-taker' "$lock2k.claim/owner"; then
  pass "the co-taker's freshly-won claim is left intact"
else
  fail "the run destroyed a co-taker's freshly-won claim; output: $out2k"
fi

echo "== Case 2l: the noclobber brand loses to the uutils co-winner =="
sb2l=$(new_sandbox)
cat > "$sb2l/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lock2l="$sb2l/suite.lock"
mkdir -p "$lock2l"
bash -c 'exit 0' & dead2l=$!
wait "$dead2l" 2>/dev/null
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=crashed\n' \
  "$dead2l" "$(this_host)" "$(date +%s)" > "$lock2l/owner"

# No pre-existing claim, so hit #1 on the claim path is the takeover's own
# mkdir. uutils coreutils resolves two concurrent mkdirs of the same path to
# BOTH rc=0 (HIMMEL-966), so the shim returns SUCCESS -- having branded the
# co-winner's owner first, which is what makes the runner's own noclobber
# brand lose.
out2l=$(PATH="$RACE_SHIM_DIR:$PATH" RACE_TARGET="$lock2l.claim" RACE_HIT_NO=1 \
  RACE_SIM_RC=0 RACE_SCAN=case2l-co-winner RACE_HITS="$sb2l/hits" \
  SUITE_LOCK_DIR="$lock2l" bash "$RUNNER" "$sb2l" 2>&1)
rc2l=$?
race_shim_fired "$sb2l/hits" 1

if [ "$rc2l" -eq 2 ]; then
  pass "brand lost to the uutils co-winner -> refused (rc 2)"
else
  fail "brand lost to the uutils co-winner -> expected rc 2 got $rc2l; output: $out2l"
fi
if grepq "$out2l" -F 'TAKEOVER IN PROGRESS'; then
  pass "a lost brand is reported as the race it is"
else
  fail "lost brand missing the TAKEOVER IN PROGRESS verdict; output: $out2l"
fi
if grepq "$out2l" -F 'RECLAIM FAILED'; then
  fail "a lost noclobber brand is reported as an operational failure; output: $out2l"
else
  pass "lost brand is not reported as an operational failure"
fi
if [ -f "$lock2l.claim/owner" ] && grep -qF 'scan=case2l-co-winner' "$lock2l.claim/owner"; then
  pass "the co-winner's branded claim is left intact"
else
  fail "the run destroyed a co-winner's branded claim; output: $out2l"
fi

echo "== Case 2m: the freed lock is won before the re-acquire =="
sb2m=$(new_sandbox)
cat > "$sb2m/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lock2m="$sb2m/suite.lock"
mkdir -p "$lock2m"
bash -c 'exit 0' & dead2m=$!
wait "$dead2m" 2>/dev/null
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=crashed\n' \
  "$dead2m" "$(this_host)" "$(date +%s)" > "$lock2m/owner"

# Hit #1 on the LOCK path is the runner's initial claim (the stale lock dir
# makes the real mkdir fail on its own); hit #2 is the re-acquire after the
# reclaim dropped it -- where a normal acquirer wins the gap.
out2m=$(PATH="$RACE_SHIM_DIR:$PATH" RACE_TARGET="$lock2m" RACE_HIT_NO=2 \
  RACE_SIM_RC=1 RACE_SCAN=case2m-acquirer RACE_HITS="$sb2m/hits" \
  SUITE_LOCK_DIR="$lock2m" bash "$RUNNER" "$sb2m" 2>&1)
rc2m=$?
race_shim_fired "$sb2m/hits" 2

if [ "$rc2m" -eq 2 ]; then
  pass "freed lock won before the re-acquire -> refused (rc 2)"
else
  fail "freed lock won before the re-acquire -> expected rc 2 got $rc2m; output: $out2m"
fi
if grepq "$out2m" -F 'TAKEOVER IN PROGRESS'; then
  pass "a lost re-acquire is reported as the race it is"
else
  fail "lost re-acquire missing the TAKEOVER IN PROGRESS verdict; output: $out2m"
fi
if grepq "$out2m" -F 'RECLAIM FAILED'; then
  fail "a lost re-acquire is reported as an operational failure; output: $out2m"
else
  pass "lost re-acquire is not reported as an operational failure"
fi
if [ -f "$lock2m/owner" ] && grep -qF 'scan=case2m-acquirer' "$lock2m/owner"; then
  pass "the acquirer's freshly-won lock is left intact"
else
  fail "the run destroyed an acquirer's freshly-won lock; output: $out2m"
fi

# --------------------------------------------------------------------------
# Case 3 -- the lock is RE-ENTRANT for nested runs.
#
# The scripts/ci/test-run-shell-tests*.sh family — six suites since
# HIMMEL-2895 split the original file — invokes the runner roughly twenty
# times between them and is itself part of the full suite. If the holder's own
# descendants could not pass through, the lock would deadlock the suites it
# exists to protect.
# --------------------------------------------------------------------------
echo "== Case 3: nested run under the holder passes through =="
sb3=$(new_sandbox)
cat > "$sb3/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lock3="$sb3/suite.lock"
mkdir -p "$lock3"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=parent\n' \
  "$$" "$(this_host)" "$(date +%s)" > "$lock3/owner"

out3=$(HIMMEL_SUITE_LOCK_HELD="$lock3" SUITE_LOCK_DIR="$lock3" \
  bash "$RUNNER" "$sb3" 2>&1)
rc3=$?
if [ "$rc3" -eq 0 ]; then
  pass "nested run holding the same lock -> proceeds (rc 0)"
else
  fail "nested run -> expected rc 0 got $rc3; output: $out3"
fi

# A nested run pointed at a DIFFERENT lock must still have to acquire: the
# pass-through keys on the lock PATH, not on "am I nested at all".
echo "== Case 3b: pass-through does not leak to a different lock =="
sb3b=$(new_sandbox)
cat > "$sb3b/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lock3b="$sb3b/suite.lock"
mkdir -p "$lock3b"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=other\n' \
  "$$" "$(this_host)" "$(date +%s)" > "$lock3b/owner"

out3b=$(HIMMEL_SUITE_LOCK_HELD="$lock3/elsewhere" SUITE_LOCK_DIR="$lock3b" \
  bash "$RUNNER" "$sb3b" 2>&1)
rc3b=$?
if [ "$rc3b" -eq 2 ]; then
  pass "nested run against a foreign held lock -> still refused (rc 2)"
else
  fail "foreign-lock pass-through leaked: expected rc 2 got $rc3b; output: $out3b"
fi

# --------------------------------------------------------------------------
# Case 4 -- SUITE_LOCK=0 opts out entirely (the documented escape hatch).
# --------------------------------------------------------------------------
echo "== Case 4: SUITE_LOCK=0 bypasses a held lock =="
sb4=$(new_sandbox)
cat > "$sb4/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lock4="$sb4/suite.lock"
mkdir -p "$lock4"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=other\n' \
  "$$" "$(this_host)" "$(date +%s)" > "$lock4/owner"

out4=$(SUITE_LOCK=0 SUITE_LOCK_DIR="$lock4" bash "$RUNNER" "$sb4" 2>&1)
rc4=$?
if [ "$rc4" -eq 0 ]; then
  pass "SUITE_LOCK=0 -> runs despite a held lock"
else
  fail "SUITE_LOCK=0 -> expected rc 0 got $rc4; output: $out4"
fi

# --------------------------------------------------------------------------
# Case 4b -- an explicitly EMPTY expected identity refuses to signal.
#
# The timeout harvest can have a pid but no readable identity sidecar. That is
# not enough authority to signal a possibly-recycled pid: rc 2 means the helper
# sent neither its POSIX group/bare-pid signal nor the Windows fallback.
# --------------------------------------------------------------------------
echo "== Case 4b: empty identity refuses to signal =="
empty_identity_result=$(
  # shellcheck source=scripts/lib/proc-tree.sh
  # shellcheck disable=SC1091  # runtime path; library is checked separately
  . "$CI_DIR/../lib/proc-tree.sh"
  signal_calls=0
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_terminate
  kill() { signal_calls=$((signal_calls + 1)); }
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_terminate
  taskkill() { signal_calls=$((signal_calls + 1)); }
  terminate_rc=0
  proc_tree_terminate 4242 0 "" || terminate_rc=$?
  printf '%s:%s\n' "$terminate_rc" "$signal_calls"
)
if [ "$empty_identity_result" = "2:0" ]; then
  pass "empty identity -> rc 2, no signal sent"
else
  fail "empty identity -> expected rc 2 and zero signals, got $empty_identity_result"
fi

# --------------------------------------------------------------------------
# Case 4b2 -- HIMMEL-1501: the initial guard must not collapse a CONFIRMED
# exit/recycle (identity_matches rc 1) and a merely unavailable probe
# (identity_matches rc 2) into the same outcome. Confirmed-gone gets its own
# rc 3; unavailable keeps rc 2. Neither sends a signal.
# --------------------------------------------------------------------------
echo "== Case 4b2: confirmed-gone identity before any signal -> rc 3, no signal sent =="
confirmed_gone_result=$(
  # shellcheck source=scripts/lib/proc-tree.sh
  # shellcheck disable=SC1091  # runtime path; library is checked separately
  . "$CI_DIR/../lib/proc-tree.sh"
  signal_calls=0
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_terminate
  proc_tree_process_identity_matches() { return 1; }
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_terminate
  kill() { signal_calls=$((signal_calls + 1)); }
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_terminate
  taskkill() { signal_calls=$((signal_calls + 1)); }
  terminate_rc=0
  proc_tree_terminate 4242 0 test-identity || terminate_rc=$?
  printf '%s:%s\n' "$terminate_rc" "$signal_calls"
)
if [ "$confirmed_gone_result" = "3:0" ]; then
  pass "confirmed-gone identity -> rc 3, no signal sent"
else
  fail "confirmed-gone identity -> expected rc 3 and zero signals, got $confirmed_gone_result"
fi

echo "== Case 4b3: unavailable identity probe (non-empty identity) before any signal -> rc 2, no signal sent =="
unavailable_identity_result=$(
  # shellcheck source=scripts/lib/proc-tree.sh
  # shellcheck disable=SC1091  # runtime path; library is checked separately
  . "$CI_DIR/../lib/proc-tree.sh"
  signal_calls=0
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_terminate
  proc_tree_process_identity_matches() { return 2; }
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_terminate
  kill() { signal_calls=$((signal_calls + 1)); }
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_terminate
  taskkill() { signal_calls=$((signal_calls + 1)); }
  terminate_rc=0
  proc_tree_terminate 4242 0 test-identity || terminate_rc=$?
  printf '%s:%s\n' "$terminate_rc" "$signal_calls"
)
if [ "$unavailable_identity_result" = "2:0" ]; then
  pass "unavailable identity probe -> rc 2, no signal sent"
else
  fail "unavailable identity probe -> expected rc 2 and zero signals, got $unavailable_identity_result"
fi

# --------------------------------------------------------------------------
# Case 4c -- a guarded leader recycled during TERM grace is never targeted.
#
# The first identity check authorizes TERM for the original group. Before KILL,
# the leader identity has changed: cleanup returns unverified without sending
# KILL to either the recycled group id or the recycled bare pid.
# --------------------------------------------------------------------------
echo "== Case 4c: recycled guarded leader blocks KILL and bare-pid fallback =="
recycled_identity_result=$(
  # shellcheck source=scripts/lib/proc-tree.sh
  # shellcheck disable=SC1091  # runtime path; library is checked separately
  . "$CI_DIR/../lib/proc-tree.sh"
  signal_log=''
  identity_checks=0
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_terminate
  proc_tree_process_identity_matches() {
    identity_checks=$((identity_checks + 1))
    [ "$identity_checks" -eq 1 ]
  }
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_terminate
  proc_tree_group_alive() { return 0; }
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_terminate
  kill() { signal_log="${signal_log}${1}:${2},"; return 0; }
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_terminate
  sleep() { :; }
  terminate_rc=0
  proc_tree_terminate 4242 0 test-identity || terminate_rc=$?
  printf '%s:%s\n' "$terminate_rc" "$signal_log"
)
if [ "$recycled_identity_result" = "2:-TERM:-4242," ]; then
  pass "recycled guarded leader -> TERM only, rc 2, no KILL or bare-pid signal"
else
  fail "recycled guarded leader -> expected only group TERM then rc 2, got $recycled_identity_result"
fi

# A failed guarded group signal must not retry against the bare leader pid.
guarded_fallback_result=$(
  # shellcheck source=scripts/lib/proc-tree.sh
  # shellcheck disable=SC1091  # runtime path; library is checked separately
  . "$CI_DIR/../lib/proc-tree.sh"
  signal_log=''
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_terminate
  proc_tree_process_identity_matches() { return 0; }
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_terminate
  proc_tree_group_alive() { return 0; }
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_terminate
  kill() { signal_log="${signal_log}${1}:${2},"; return 1; }
  terminate_rc=0
  proc_tree_terminate 4242 0 test-identity || terminate_rc=$?
  printf '%s:%s\n' "$terminate_rc" "$signal_log"
)
if [ "$guarded_fallback_result" = "2:-TERM:-4242," ]; then
  pass "guarded group signal failure -> rc 2 without bare-pid fallback"
else
  fail "guarded group signal failure -> expected no bare-pid fallback, got $guarded_fallback_result"
fi

# A leader that exits during the grace does not revoke authority over member
# identities captured before TERM. Escalate the still-matching child by pid,
# never the now-unowned numeric group id.
leader_exit_survivor_result=$(
  # shellcheck source=scripts/lib/proc-tree.sh
  # shellcheck disable=SC1091  # runtime path; library is checked separately
  . "$CI_DIR/../lib/proc-tree.sh"
  signal_log=''
  leader_checks=0
  alive_checks=0
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_terminate
  proc_tree_group_members() { printf '%s\n' 4242 500; }
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_terminate
  proc_tree_process_identity() { printf 'identity-%s\n' "$1"; }
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_terminate
  proc_tree_process_identity_matches() {
    if [ "$1" = "4242" ]; then
      leader_checks=$((leader_checks + 1))
      [ "$leader_checks" -eq 1 ]
    else
      [ "$1" = "500" ] && [ "$2" = "identity-500" ]
    fi
  }
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_terminate
  proc_tree_group_alive() {
    alive_checks=$((alive_checks + 1))
    [ "$alive_checks" -eq 1 ]
  }
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_terminate
  kill() { signal_log="${signal_log}${1}:${2},"; return 0; }
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_terminate
  sleep() { :; }
  terminate_rc=0
  proc_tree_terminate 4242 0 identity-4242 || terminate_rc=$?
  printf '%s:%s\n' "$terminate_rc" "$signal_log"
)
if [ "$leader_exit_survivor_result" = "0:-TERM:-4242,-KILL:500," ]; then
  pass "guarded leader exit -> KILL only the identity-verified survivor, rc 0"
else
  fail "guarded leader exit -> expected group TERM then verified survivor KILL, got $leader_exit_survivor_result"
fi

# --------------------------------------------------------------------------
# Case 4d -- leader-exit cleanup revalidates every observed member.
#
# The numeric group id has no surviving ownership anchor after leader exit.
# Snapshot member identities, signal only identity-matching pids, and return rc 2
# rather than group-KILLing or taskkilling a member whose identity changed.
# --------------------------------------------------------------------------
echo "== Case 4d: leader-exit group sweep verifies each member identity =="
group_member_identity_result=$(
  # shellcheck source=scripts/lib/proc-tree.sh
  # shellcheck disable=SC1091  # runtime path; library is checked separately
  . "$CI_DIR/../lib/proc-tree.sh"
  signal_log=''
  identity_checks=0
  taskkill_calls=0
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_group_terminate
  proc_tree_group_alive() { return 0; }
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_group_terminate
  proc_tree_group_members() { printf '%s\n' 500 501; }
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_group_terminate
  proc_tree_process_identity() { printf 'identity-%s\n' "$1"; }
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_group_terminate
  proc_tree_process_identity_matches() {
    identity_checks=$((identity_checks + 1))
    [ "$1" = "500" ]
  }
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_group_terminate
  kill() { signal_log="${signal_log}${1}:${2},"; return 0; }
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_group_terminate
  taskkill() { taskkill_calls=$((taskkill_calls + 1)); return 0; }
  # shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_group_terminate
  sleep() { :; }
  terminate_rc=0
  proc_tree_group_terminate 4242 0 || terminate_rc=$?
  printf '%s:%s:%s:%s\n' "$terminate_rc" "$identity_checks" "$signal_log" "$taskkill_calls"
)
if [ "$group_member_identity_result" = "2:4:-TERM:500,-KILL:500,:0" ]; then
  pass "leader-exit sweep -> per-member TERM/KILL validation, rc 2, no blind fallback"
else
  fail "leader-exit sweep -> expected only verified pid signals and rc 2, got $group_member_identity_result"
fi

# --------------------------------------------------------------------------
# Case 4e -- a guarded leader that exits on TERM must not strand an ignoring
# descendant. The guarded helper snapshots member identities before TERM, then
# escalates only the still-matching survivor after the leader identity is gone.
# --------------------------------------------------------------------------
echo "== Case 4e: guarded leader exit escalates verified survivors =="
sb4e=$(new_sandbox)
cat > "$sb4e/leader.sh" <<'SHEOF'
#!/usr/bin/env bash
node -e 'process.on("SIGTERM", () => {}); setInterval(() => {}, 1000)' &
printf '%s\n' "$!" > "${HIMMEL_R13_CHILD_PID_FILE:?}"
trap 'exit 0' TERM
while :; do sleep 1; done
SHEOF
# shellcheck source=scripts/lib/proc-tree.sh
# shellcheck disable=SC1091
. "$CI_DIR/../lib/proc-tree.sh"
set -m
HIMMEL_R13_CHILD_PID_FILE="$sb4e/child.pid" bash "$sb4e/leader.sh" &
leader4e=$!
set +m
waited4e=0
while [ ! -s "$sb4e/child.pid" ] && kill -0 "$leader4e" 2>/dev/null && [ "$waited4e" -lt 50 ]; do
  sleep 0.1
  waited4e=$((waited4e + 1))
done
leader_identity4e=$(proc_tree_process_identity "$leader4e") || leader_identity4e=''
terminate4e_rc=0
proc_tree_terminate "$leader4e" 1 "$leader_identity4e" || terminate4e_rc=$?
wait "$leader4e" 2>/dev/null || true
child4e=$(cat "$sb4e/child.pid" 2>/dev/null || echo '')
if [ "$terminate4e_rc" -eq 0 ]; then
  pass "leader exits during TERM grace -> verified survivor cleanup returns rc 0"
else
  fail "leader exits during TERM grace -> expected cleanup rc 0 got $terminate4e_rc"
fi
if [ -n "$child4e" ] && ! kill -0 "$child4e" 2>/dev/null; then
  pass "leader exits during TERM grace -> TERM-ignoring child is gone"
else
  fail "leader exits during TERM grace -> TERM-ignoring child survived (pid=${child4e:-missing})"
  if [ -n "$child4e" ]; then
    kill -9 "$child4e" 2>/dev/null || true
    if command -v taskkill >/dev/null 2>&1; then
      MSYS_NO_PATHCONV=1 taskkill /PID "$child4e" /T /F >/dev/null 2>&1 || true
    fi
  fi
fi

# --------------------------------------------------------------------------
# Case 5 -- a deliberately-blocking suite is TIMED OUT, and its DESCENDANTS
# die with it.
#
# This is the core of the ticket. The fixture spawns a long sleeper, publishes
# its pid, and then blocks forever; the runner's cap must reap both. The
# descendant is checked by pid AFTER the runner returns -- signalling the
# suite wrapper alone would leave the sleeper behind, which is exactly the
# leak that accumulated 200 live bash processes on the box.
# --------------------------------------------------------------------------
echo "== Case 5: blocking suite is capped, descendants reaped =="
sb5=$(new_sandbox)
cat > "$sb5/test-block.sh" <<'SHEOF'
#!/usr/bin/env bash
# A wedged suite: leaves a descendant running and never returns.
sleep 600 &
printf '%s' "$!" > "$(dirname "$0")/descendant.pid"
sleep 600
SHEOF
cat > "$sb5/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF

start5=$(date +%s)
out5=$(SUITE_LOCK_DIR="$sb5/suite.lock" SUITE_TIMEOUT=5 bash "$RUNNER" "$sb5" 2>&1)
rc5=$?
elapsed5=$(( $(date +%s) - start5 ))

if [ "$rc5" -eq 1 ]; then
  pass "blocking suite -> run reports failure (rc 1)"
else
  fail "blocking suite -> expected rc 1 got $rc5; output: $out5"
fi
# The cap is 5s and there are two suites; anything near the 600s the fixture
# asked for means the cap did not fire at all.
if [ "$elapsed5" -lt 120 ]; then
  pass "blocking suite -> run finished in ${elapsed5}s (cap fired)"
else
  fail "blocking suite -> run took ${elapsed5}s; the cap did not fire"
fi
if grepq "$out5" -F '[TIME]'; then
  pass "timeout is reported as a timeout, not a plain failure"
else
  fail "no [TIME] marker in output: $out5"
fi
# The suite AFTER the blocking one must still have run -- a cap that takes the
# whole run down with it is just a slower hang.
if grepq "$out5" -F '[PASS]'; then
  pass "run continued past the capped suite"
else
  fail "run did not continue past the capped suite; output: $out5"
fi

desc5=$(cat "$sb5/descendant.pid" 2>/dev/null || echo "")
if [ -z "$desc5" ]; then
  fail "descendant reaping -- the fixture never published a descendant pid"
elif kill -0 "$desc5" 2>/dev/null; then
  fail "descendant reaping -- pid $desc5 survived the cap"
  LEAKED_PIDS="${LEAKED_PIDS:-} $desc5"
else
  pass "descendant reaping -- the sleeper died with its suite"
fi

# --------------------------------------------------------------------------
# Case 5b -- a suite that IGNORES TERM is still capped.
#
# This is the case the old harness got wrong. It capped with `timeout` and no
# --kill-after, so TERM was the only signal a suite ever saw; any suite with a
# cleanup trap simply ignored it and ran to completion while the log still
# claimed rc=124. Measured against the pre-fix runner: 41s of work under a 5s
# cap. The cap must escalate to KILL, which cannot be trapped.
#
# The fixture self-exits after 40s so a REGRESSION here fails the assertion
# instead of leaving a process behind for someone else to clean up.
# --------------------------------------------------------------------------
echo "== Case 5b: a TERM-ignoring suite is still capped =="
sb5b=$(new_sandbox)
cat > "$sb5b/test-stubborn.sh" <<'SHEOF'
#!/usr/bin/env bash
trap '' TERM
end=$(( $(date +%s) + 40 ))
while [ "$(date +%s)" -lt "$end" ]; do sleep 1; done
exit 0
SHEOF

start5b=$(date +%s)
out5b=$(SUITE_LOCK_DIR="$sb5b/suite.lock" SUITE_TIMEOUT=5 bash "$RUNNER" "$sb5b" 2>&1)
rc5b=$?
elapsed5b=$(( $(date +%s) - start5b ))

if [ "$rc5b" -eq 1 ]; then
  pass "TERM-ignoring suite -> rc 1"
else
  fail "TERM-ignoring suite -> expected rc 1 got $rc5b; output: $out5b"
fi
# 40s is the fixture's own exit. Finishing at or past it means the cap did not
# enforce and the suite simply finished on its own terms.
if [ "$elapsed5b" -lt 35 ]; then
  pass "TERM-ignoring suite -> killed at ${elapsed5b}s, before its own 40s exit"
else
  fail "TERM-ignoring suite -> ran ${elapsed5b}s under a 5s cap; TERM was ignored and nothing escalated"
fi

# --------------------------------------------------------------------------
# Case 5c -- a suite that HANDLES the cap's TERM and exits 0 is still a timeout.
#
# Case 5b covers `trap '' TERM` (ignore). This is the other shape: the suite
# exits CLEANLY on the signal, so its own status is 0 and an over-time run
# could be recorded as a PASS.
#
# It is not, and the reason is structural rather than lucky: the wrapper that
# writes the rc file sits in the same process group as the suite, so the group
# signal takes it too and it never reaches the write. The rc file therefore
# stays empty and the runner reads a timeout. That is worth an assertion
# precisely BECAUSE it is a side effect of the grouping — a later refactor that
# moved the rc write out of the killed group would turn every polite suite into
# a silent PASS, and nothing else here would notice.
# --------------------------------------------------------------------------
echo "== Case 5c: a suite that exits 0 on the cap's TERM is still a timeout =="
sb5c=$(new_sandbox)
cat > "$sb5c/test-polite.sh" <<'SHEOF'
#!/usr/bin/env bash
# Exits 0 the moment it is asked to stop -- well past the cap. Self-limits at
# 60s so a regression cannot leave this running.
trap 'exit 0' TERM
end=$(( $(date +%s) + 60 ))
while [ "$(date +%s)" -lt "$end" ]; do sleep 1; done
exit 0
SHEOF

out5c=$(SUITE_LOCK_DIR="$sb5c/suite.lock" SUITE_TIMEOUT=5 bash "$RUNNER" "$sb5c" 2>&1)
rc5c=$?
if [ "$rc5c" -eq 1 ]; then
  pass "TERM-handling suite -> run fails (rc 1)"
else
  fail "TERM-handling suite -> expected rc 1 got $rc5c; output: $out5c"
fi
if grepq "$out5c" -F '[TIME]'; then
  pass "an over-time suite that exited 0 is recorded as a timeout"
else
  fail "an over-time suite that exited 0 was NOT recorded as a timeout; output: $out5c"
fi
if grepq "$out5c" -F '[PASS]'; then
  fail "the over-time suite was counted as a PASS"
else
  pass "no PASS recorded for the over-time suite"
fi

# --------------------------------------------------------------------------
# Case 6 -- a suite that reads stdin cannot eat the suite list.
#
# With the loop's list on the body's stdin, a `cat`-like suite consumed the
# remaining suite paths and the runner reported OK over a list it had silently
# swallowed. The sandbox holds three suites; all three must run, and the
# stdin-reading one must see EOF rather than a suite path.
# --------------------------------------------------------------------------
echo "== Case 6: a stdin-reading suite neither blocks nor eats the list =="
sb6=$(new_sandbox)
cat > "$sb6/test-a-greedy.sh" <<'SHEOF'
#!/usr/bin/env bash
# Drain stdin. On the old harness this swallowed the remaining suite list.
swallowed=$(cat)
printf '%s' "$swallowed" > "$(dirname "$0")/swallowed.txt"
exit 0
SHEOF
cat > "$sb6/test-b-second.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/b.ran"
exit 0
SHEOF
cat > "$sb6/test-c-third.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/c.ran"
exit 0
SHEOF

out6=$(SUITE_LOCK_DIR="$sb6/suite.lock" SUITE_TIMEOUT=30 bash "$RUNNER" "$sb6" 2>&1)
rc6=$?
if [ "$rc6" -eq 0 ]; then
  pass "stdin-reading suite -> rc 0"
else
  fail "stdin-reading suite -> expected rc 0 got $rc6; output: $out6"
fi
if [ -f "$sb6/b.ran" ] && [ -f "$sb6/c.ran" ]; then
  pass "suites after the stdin reader still ran"
else
  fail "suites after the stdin reader were swallowed; output: $out6"
fi
if [ -s "$sb6/swallowed.txt" ]; then
  fail "the stdin reader received data: $(cat "$sb6/swallowed.txt")"
else
  pass "the stdin reader saw EOF (stdin is /dev/null)"
fi
# All three must be accounted for in the summary.
if grepq "$out6" -F 'OK: all 3 run suites passed'; then
  pass "summary counts all three suites"
else
  fail "summary did not count three suites; output: $out6"
fi

# --------------------------------------------------------------------------
# Case 7 -- the whole-run budget stops a long run and names what did not run.
#
# Two suites, each sleeping past a 1s budget: the first runs (the budget is
# checked BETWEEN suites, so no suite is ever truncated mid-assertion), the
# second is reported unrun, and the run fails rather than greening over the
# coverage it never obtained.
# --------------------------------------------------------------------------
echo "== Case 7: run budget stops the run and reports the gap =="
sb7=$(new_sandbox)
cat > "$sb7/test-a-slow.sh" <<'SHEOF'
#!/usr/bin/env bash
sleep 3
exit 0
SHEOF
cat > "$sb7/test-b-never.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/never.ran"
exit 0
SHEOF

out7=$(SUITE_LOCK_DIR="$sb7/suite.lock" SUITE_ROTATE_STATE="$sb7/rotate.cursor" \
  SUITE_RUN_BUDGET=1 SUITE_TIMEOUT=30 \
  bash "$RUNNER" "$sb7" 2>&1)
rc7=$?
if [ "$rc7" -eq 1 ]; then
  pass "expired budget -> rc 1 (not a false green)"
else
  fail "expired budget -> expected rc 1 got $rc7; output: $out7"
fi
if [ ! -f "$sb7/never.ran" ]; then
  pass "expired budget -> the remaining suite did not run"
else
  fail "expired budget -> the remaining suite ran anyway"
fi
if grepq "$out7" -F 'test-b-never.sh'; then
  pass "expired budget -> the unrun suite is named"
else
  fail "expired budget -> unrun suites not named; output: $out7"
fi

# A budget that is NOT exceeded must leave the run alone.
echo "== Case 7b: an ample budget changes nothing =="
sb7b=$(new_sandbox)
cat > "$sb7b/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
out7b=$(SUITE_LOCK_DIR="$sb7b/suite.lock" SUITE_ROTATE_STATE="$sb7b/rotate.cursor" \
  SUITE_RUN_BUDGET=3600 \
  bash "$RUNNER" "$sb7b" 2>&1)
rc7b=$?
if [ "$rc7b" -eq 0 ]; then
  pass "ample budget -> rc 0"
else
  fail "ample budget -> expected rc 0 got $rc7b; output: $out7b"
fi

# --------------------------------------------------------------------------
# Case 8 -- the lock is released when the run ends, so the next run is free.
# --------------------------------------------------------------------------
echo "== Case 8: the lock is released on exit =="
sb8=$(new_sandbox)
cat > "$sb8/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lock8="$sb8/suite.lock"
SUITE_LOCK_DIR="$lock8" bash "$RUNNER" "$sb8" >/dev/null 2>&1
if [ ! -d "$lock8" ]; then
  pass "lock directory is gone after a clean run"
else
  fail "lock directory survived a clean run at $lock8"
fi
# A failing run must release too, or one red suite wedges the box.
sb8b=$(new_sandbox)
cat > "$sb8b/test-fail.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 1
SHEOF
lock8b="$sb8b/suite.lock"
SUITE_LOCK_DIR="$lock8b" bash "$RUNNER" "$sb8b" >/dev/null 2>&1
if [ ! -d "$lock8b" ]; then
  pass "lock directory is gone after a FAILING run"
else
  fail "lock directory survived a failing run at $lock8b"
fi

# --------------------------------------------------------------------------
# Case 8c -- a holder that was TAKEN OVER must not delete its successor's lock.
#
# "I acquired this once" is not "I hold it now". A run that overruns the TTL is
# reclaimed by another run, which removes this dir and creates its own; an
# unconditional release would then delete the live successor on the way out and
# admit a third run alongside it — the concurrency this file exists to prevent,
# caused by its own cleanup.
#
# The fixture simulates the takeover from inside the run by re-branding the
# lock with a foreign owner. It can find the lock because the holder exports
# HIMMEL_SUITE_LOCK_HELD, which its suites inherit.
# --------------------------------------------------------------------------
echo "== Case 8c: a taken-over holder leaves the successor's lock alone =="
sb8c=$(new_sandbox)
cat > "$sb8c/test-a-steal.sh" <<'SHEOF'
#!/usr/bin/env bash
# Stand in for another run that TTL-reclaimed this lock and re-branded it.
printf 'pid=1\nhost=some-other-host\nstarted=%s\nscan=successor\n' "$(date +%s)" \
  > "$HIMMEL_SUITE_LOCK_HELD/owner"
exit 0
SHEOF
lock8c="$sb8c/suite.lock"
out8c=$(SUITE_LOCK_DIR="$lock8c" bash "$RUNNER" "$sb8c" 2>&1)
rc8c=$?
if [ "$rc8c" -eq 0 ]; then
  pass "taken-over holder -> run itself still succeeds (rc 0)"
else
  fail "taken-over holder -> expected rc 0 got $rc8c; output: $out8c"
fi
if [ -d "$lock8c" ] && grep -qF 'host=some-other-host' "$lock8c/owner" 2>/dev/null; then
  pass "the successor's lock survived the original holder's exit"
else
  fail "the original holder deleted the successor's lock — concurrent runs would be admitted"
fi
if grepq "$out8c" -F 'taken over'; then
  pass "the skipped release is announced, not silent"
else
  fail "the skipped release was silent; output: $out8c"
fi

# --------------------------------------------------------------------------
# Case 9 -- a malformed numeric knob warns and falls back, it does not
# silently disable the guard it configures.
#
# Every knob feeds arithmetic or `sleep`, where a typo fails quietly in the
# worst direction: SUITE_TIMEOUT=abc makes `sleep abc` return immediately (no
# cap at all) and SUITE_RUN_BUDGET=08 dies as an invalid octal constant. Both
# leave a guard disabled while looking configured.
# --------------------------------------------------------------------------
echo "== Case 9: malformed numeric knobs warn and fall back =="
sb9=$(new_sandbox)
cat > "$sb9/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF

out9=$(SUITE_LOCK_DIR="$sb9/suite.lock" SUITE_TIMEOUT=abc bash "$RUNNER" "$sb9" 2>&1)
rc9=$?
if [ "$rc9" -eq 0 ]; then
  pass "non-numeric SUITE_TIMEOUT -> still runs (rc 0)"
else
  fail "non-numeric SUITE_TIMEOUT -> expected rc 0 got $rc9; output: $out9"
fi
if grepq "$out9" -F 'SUITE_TIMEOUT="abc"'; then
  pass "the bad value is named in the warning"
else
  fail "no warning naming the bad SUITE_TIMEOUT; output: $out9"
fi

# ZERO must be rejected, not honoured. SUITE_LOCK_TTL=0 makes `age -ge 0` true
# for a lock created microseconds ago, so every LIVE lock reads as abandoned
# and the concurrency guard silently ceases to exist — the guard disabled by a
# value that looks like configuration. The lock below is held by a live pid
# (this test), so a correct runner still refuses.
echo "== Case 9b: SUITE_LOCK_TTL=0 does not make every live lock stale =="
sb9c=$(new_sandbox)
cat > "$sb9c/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lock9c="$sb9c/suite.lock"
mkdir -p "$lock9c"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=live\n' \
  "$$" "$(this_host)" "$(date +%s)" > "$lock9c/owner"

out9c=$(SUITE_LOCK_DIR="$lock9c" SUITE_LOCK_TTL=0 bash "$RUNNER" "$sb9c" 2>&1)
rc9c=$?
if [ "$rc9c" -eq 2 ]; then
  pass "SUITE_LOCK_TTL=0 -> live lock still refuses (rc 2)"
else
  fail "SUITE_LOCK_TTL=0 defeated the guard: expected rc 2 got $rc9c; output: $out9c"
fi
if grepq "$out9c" -F 'must be >= 1'; then
  pass "the zero value is rejected with a reason"
else
  fail "no warning rejecting the zero TTL; output: $out9c"
fi

# Zero-padded values must read as decimal, not octal: 08 is not a valid octal
# constant and would abort the arithmetic outright.
out9b=$(SUITE_LOCK_DIR="$sb9/suite9b.lock" SUITE_TIMEOUT=08 bash "$RUNNER" "$sb9" 2>&1)
rc9b=$?
if [ "$rc9b" -eq 0 ]; then
  pass "zero-padded SUITE_TIMEOUT is read as decimal (rc 0)"
else
  fail "zero-padded SUITE_TIMEOUT -> expected rc 0 got $rc9b; output: $out9b"
fi
if grepq "$out9b" -E 'value too great for base|invalid octal'; then
  fail "zero-padded value was parsed as octal; output: $out9b"
else
  pass "no octal parse error on a zero-padded value"
fi

# --------------------------------------------------------------------------
# Case W1 -- SUITE_LOCK_WAIT unset: the new knob is genuinely opt-in. A held
# lock must still refuse ON SIGHT with the historical single-shot BEHAVIOUR —
# same decision, same rc 2, nothing waited (HIMMEL-2215).
#
# Behaviour, deliberately not byte-identical TEXT: the refusal gained three
# lines naming SUITE_LOCK_WAIT as the way to queue instead. So this case
# asserts the decision (rc 2), the verdict marker (REFUSED), and the ABSENCE
# of any heartbeat — never an exact-output match, which would fail on the
# intended new lines and would have to be re-baselined on every message edit.
# --------------------------------------------------------------------------
echo "== Case W1: default is unchanged -- a held lock still refuses on sight =="
sbw1=$(new_sandbox)
cat > "$sbw1/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lockw1="$sbw1/suite.lock"
mkdir -p "$lockw1"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=other\n' \
  "$$" "$(this_host)" "$(date +%s)" > "$lockw1/owner"

outw1=$(SUITE_LOCK_DIR="$lockw1" bash "$RUNNER" "$sbw1" 2>&1)
rcw1=$?
if [ "$rcw1" -eq 2 ]; then
  pass "no SUITE_LOCK_WAIT -> held lock still refuses (rc 2)"
else
  fail "no SUITE_LOCK_WAIT -> expected rc 2 got $rcw1; output: $outw1"
fi
if grepq "$outw1" -F 'REFUSED'; then
  pass "refusal message present"
else
  fail "refusal message missing; output: $outw1"
fi
if grepq "$outw1" -F 'WAITING:'; then
  fail "unset SUITE_LOCK_WAIT queued instead of refusing; output: $outw1"
else
  pass "no WAITING: heartbeat when the knob is unset"
fi

# --------------------------------------------------------------------------
# Case W2 -- SUITE_LOCK_WAIT=0 is explicitly the same as unset: 0 is the
# meaningful OFF value for this budget, not a degenerate "wait zero seconds".
# --------------------------------------------------------------------------
echo "== Case W2: SUITE_LOCK_WAIT=0 is explicitly the same as unset =="
sbw2=$(new_sandbox)
cat > "$sbw2/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lockw2="$sbw2/suite.lock"
mkdir -p "$lockw2"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=other\n' \
  "$$" "$(this_host)" "$(date +%s)" > "$lockw2/owner"

outw2=$(SUITE_LOCK_DIR="$lockw2" SUITE_LOCK_WAIT=0 bash "$RUNNER" "$sbw2" 2>&1)
rcw2=$?
if [ "$rcw2" -eq 2 ]; then
  pass "SUITE_LOCK_WAIT=0 -> held lock still refuses (rc 2)"
else
  fail "SUITE_LOCK_WAIT=0 -> expected rc 2 got $rcw2; output: $outw2"
fi
if grepq "$outw2" -F 'WAITING:'; then
  fail "SUITE_LOCK_WAIT=0 queued instead of refusing; output: $outw2"
else
  pass "no WAITING: heartbeat with SUITE_LOCK_WAIT=0"
fi

# A leading-zero value is a valid decimal budget, not a malformed one --
# "0060" must parse as 60, not trip the WARN fallback. Use "0003" (a 3s
# budget) rather than "0060" so this sub-case does not cost the suite a full
# minute; SUITE_LOCK_WAIT_INTERVAL=1 keeps the heartbeat cadence tight too.
outw2z=$(SUITE_LOCK_DIR="$lockw2" SUITE_LOCK_WAIT=0003 SUITE_LOCK_WAIT_INTERVAL=1 bash "$RUNNER" "$sbw2" 2>&1)
rcw2z=$?
# rc 5 (HIMMEL-2623), not rc 2: this sub-case genuinely SPENT its budget
# against a still-held lock, the EXPIRED class -- rc 2 stays reserved for the
# instant/permanent refusals that never waited at all.
if [ "$rcw2z" -eq 5 ]; then
  pass "SUITE_LOCK_WAIT=0003 -> still refuses once its budget is spent (rc 5)"
else
  fail "SUITE_LOCK_WAIT=0003 -> expected rc 5 got $rcw2z; output: $outw2z"
fi
if grepq "$outw2z" -F 'WARN' && grepq "$outw2z" -F 'SUITE_LOCK_WAIT'; then
  fail "SUITE_LOCK_WAIT=0003 (a valid leading-zero budget) was rejected as malformed; output: $outw2z"
else
  pass "no WARN naming SUITE_LOCK_WAIT -- leading zeros parsed as decimal"
fi
if grepq "$outw2z" -F 'WAITING:'; then
  pass "WAITING: heartbeat present -- 0003 was honoured as a 3s budget, not rejected"
else
  fail "no WAITING: heartbeat; 0003 should have queued for its 3s budget; output: $outw2z"
fi

# --------------------------------------------------------------------------
# Case W3 -- LIVE TWO-PROCESS PROBE: a genuine race between a real holder and
# a real waiter, not a simulation. This is the done-criterion evidence for
# HIMMEL-2215 -- the waiter must queue, heartbeat repeatedly naming the
# holder, and eventually acquire once the holder exits, all without ever
# touching the lock while the holder still has it.
# --------------------------------------------------------------------------
echo "== Case W3: a live waiter queues behind a live holder, then acquires =="
sbw3=$(new_sandbox)
cat > "$sbw3/test-hold.sh" <<'SHEOF'
#!/usr/bin/env bash
sleep 8
exit 0
SHEOF
lockw3="$sbw3/suite.lock"

SUITE_LOCK_DIR="$lockw3" bash "$RUNNER" "$sbw3" >"$sbw3/holder.log" 2>&1 &
holder_pid=$!

# The lock is a DIRECTORY with an owner FILE; test with `-f` on the owner
# file, never `cat` -- the file may not exist yet.
_spin=0
while [ ! -f "$lockw3/owner" ] && [ "$_spin" -lt 100 ]; do
  sleep 0.1
  _spin=$((_spin + 1))
done

if [ ! -f "$lockw3/owner" ]; then
  fail "W3 setup -- holder never branded the lock within 10s; cannot run the race"
  kill "$holder_pid" 2>/dev/null
  wait "$holder_pid" 2>/dev/null
else
  holder_reported_pid=$(grep '^pid=' "$lockw3/owner" | cut -d= -f2)

  SUITE_LOCK_DIR="$lockw3" SUITE_LOCK_WAIT=60 SUITE_LOCK_WAIT_INTERVAL=1 bash "$RUNNER" "$sbw3" >"$sbw3/waiter.log" 2>&1
  rcw3=$?

  wait "$holder_pid"
  holder_rc=$?

  outw3=$(cat "$sbw3/waiter.log" 2>/dev/null || echo "")
  holder_log=$(cat "$sbw3/holder.log" 2>/dev/null || echo "")

  if [ "$rcw3" -eq 0 ]; then
    pass "W3a: waiter eventually acquired (rc 0) rather than refusing"
  else
    fail "W3a: waiter -> expected rc 0 got $rcw3; output: $outw3"
  fi

  if grepq "$outw3" -F 'WAITING:'; then
    pass "W3b: waiter log contains a WAITING: heartbeat"
  else
    fail "W3b: no WAITING: heartbeat in waiter output: $outw3"
  fi

  if grepq "$outw3" -F "pid=$holder_reported_pid"; then
    pass "W3c: heartbeat names the holder's actual pid"
  else
    fail "W3c: heartbeat does not name pid=$holder_reported_pid; output: $outw3"
  fi

  waiting_count=$(grep -c 'WAITING:' "$sbw3/waiter.log" 2>/dev/null) || waiting_count=0
  case "$waiting_count" in ''|*[!0-9]*) waiting_count=0 ;; esac
  if [ "$waiting_count" -ge 2 ]; then
    pass "W3d: heartbeat repeats ($waiting_count times) rather than firing once"
  else
    fail "W3d: heartbeat fired $waiting_count time(s), expected >= 2; output: $outw3"
  fi

  if grepq "$outw3" -E 'held=[0-9]+s'; then
    pass "W3e: heartbeat carries the holder's elapsed hold time"
  else
    fail "W3e: no held=<seconds>s in heartbeat; output: $outw3"
  fi

  if grepq "$outw3" -F 'has waited'; then
    pass "W3f: heartbeat carries how long this run has waited"
  else
    fail "W3f: no 'has waited' in heartbeat; output: $outw3"
  fi

  if grepq "$outw3" -F 'ACQUIRED:'; then
    pass "W3g: waiter log closes the loop with ACQUIRED:"
  else
    fail "W3g: no ACQUIRED: in waiter output: $outw3"
  fi

  # The two checks above are necessary but NOT sufficient on their own: a
  # waiter that stole the lock mid-hold is invisible to both. suite_lock_release
  # compares the owner file against its own pid/host before deleting anything,
  # so a holder whose lock was taken over does not fail -- it prints
  # "NOTE: not releasing ... it was taken over" and exits 0. That NOTE is the
  # runner's own evidence of a theft, and it is emitted no matter WHEN in the
  # hold the takeover happened, so it is a stronger and more deterministic
  # check than sampling the owner file at some arbitrary mid-flight moment.
  if grepq "$holder_log" -F 'REFUSED'; then
    fail "W3h: holder log shows REFUSED -- the waiter contended the lock while held; holder log: $holder_log"
  elif [ "$holder_rc" -ne 0 ]; then
    fail "W3h: holder exited non-zero ($holder_rc); holder log: $holder_log"
  elif grepq "$holder_log" -F 'not releasing'; then
    fail "W3h: the holder's lock was TAKEN OVER while it still held it -- the waiter stole the lock; holder log: $holder_log"
  else
    pass "W3h: the waiter did not steal the lock while the holder held it (holder released its own lock cleanly)"
  fi

  # W3i pins the accuracy fix: `waited` used to be assigned only on the
  # failure path (before the sleep), so the ACQUIRED: line could report a
  # duration lower than the real wait -- 0 in the worst case, which the
  # `-gt 0` guard would then suppress entirely. W3 waits ~8s, so a real
  # measurement taken at acquisition must read at least 1s.
  acq_secs=$(printf '%s\n' "$outw3" | sed -n 's/.*after waiting \([0-9][0-9]*\)s\..*/\1/p' | head -1)
  case "$acq_secs" in ''|*[!0-9]*) acq_secs=-1 ;; esac
  if [ "$acq_secs" -ge 1 ]; then
    pass "W3i: ACQUIRED: reports a real elapsed wait (${acq_secs}s), measured at acquisition"
  else
    fail "W3i: ACQUIRED: reported '${acq_secs}' seconds -- the waited counter is stale (measured at the last failure, not at acquisition); output: $outw3"
  fi
fi

# --------------------------------------------------------------------------
# Case W4 -- the wait budget is honoured (the run actually spends it) and the
# give-up verdict is loud: the last attempt against a still-held lock must
# print the full REFUSED block, not a quiet retry.
# --------------------------------------------------------------------------
echo "== Case W4: the wait budget is honoured and the give-up verdict is loud =="
sbw4=$(new_sandbox)
cat > "$sbw4/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lockw4="$sbw4/suite.lock"
mkdir -p "$lockw4"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=other\n' \
  "$$" "$(this_host)" "$(date +%s)" > "$lockw4/owner"

start4=$(date +%s)
outw4=$(SUITE_LOCK_DIR="$lockw4" SUITE_LOCK_WAIT=3 SUITE_LOCK_WAIT_INTERVAL=1 bash "$RUNNER" "$sbw4" 2>&1)
rcw4=$?
elapsed4=$(( $(date +%s) - start4 ))

# rc 5 (HIMMEL-2623): a budget that actually ran out against a still-held
# lock is the EXPIRED class, distinct from the instant-refusal rc 2.
if [ "$rcw4" -eq 5 ]; then
  pass "budget exhausted -> rc 5"
else
  fail "budget exhausted -> expected rc 5 got $rcw4; output: $outw4"
fi
if grepq "$outw4" -F 'WAITING:'; then
  pass "output contains a WAITING: heartbeat before giving up"
else
  fail "no WAITING: heartbeat in output: $outw4"
fi
if grepq "$outw4" -F 'GAVE UP'; then
  pass "output contains the GAVE UP verdict"
else
  fail "no GAVE UP verdict in output: $outw4"
fi
if grepq "$outw4" -F 'REFUSED'; then
  pass "the final attempt is loud (REFUSED present)"
else
  fail "the final attempt did not emit REFUSED; output: $outw4"
fi
owner4=$(cat "$lockw4/owner" 2>/dev/null || echo "")
if grepq "$owner4" -F "pid=$$"; then
  pass "the holder's lock is intact after the waiter gave up"
else
  fail "the holder's lock was disturbed; owner file: $owner4"
fi
if [ "$elapsed4" -ge 3 ]; then
  pass "the run actually spent the budget (${elapsed4}s >= 3s)"
else
  fail "the run returned in ${elapsed4}s, budget not honoured; output: $outw4"
fi

# --------------------------------------------------------------------------
# Case W5 -- a malformed SUITE_LOCK_WAIT falls back to no wait, loudly: a
# typo must not silently convert a refusal into an hours-long block.
# --------------------------------------------------------------------------
echo "== Case W5: a malformed SUITE_LOCK_WAIT falls back to no wait, loudly =="
sbw5=$(new_sandbox)
cat > "$sbw5/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lockw5="$sbw5/suite.lock"
mkdir -p "$lockw5"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=other\n' \
  "$$" "$(this_host)" "$(date +%s)" > "$lockw5/owner"

outw5=$(SUITE_LOCK_DIR="$lockw5" SUITE_LOCK_WAIT=abc bash "$RUNNER" "$sbw5" 2>&1)
rcw5=$?
if [ "$rcw5" -eq 2 ]; then
  pass "malformed SUITE_LOCK_WAIT -> rc 2 (no wait)"
else
  fail "malformed SUITE_LOCK_WAIT -> expected rc 2 got $rcw5; output: $outw5"
fi
if grepq "$outw5" -F 'WARN'; then
  pass "output contains a WARN for the malformed value"
else
  fail "no WARN in output: $outw5"
fi
if grepq "$outw5" -F 'SUITE_LOCK_WAIT'; then
  pass "the warning names SUITE_LOCK_WAIT"
else
  fail "warning does not name SUITE_LOCK_WAIT; output: $outw5"
fi
if grepq "$outw5" -F 'WAITING:'; then
  fail "malformed SUITE_LOCK_WAIT queued instead of falling back; output: $outw5"
else
  pass "no WAITING: heartbeat -- typo did not become an unbounded block"
fi

# --------------------------------------------------------------------------
# Case W6 -- an out-of-range SUITE_LOCK_WAIT falls back to no wait, loudly.
# An all-digit value is not the same as an in-range one: bash arithmetic
# WRAPS past intmax instead of failing, so a fat-fingered digit run must be
# caught separately from the non-digit case Case W5 already covers -- a typo
# here must not silently become an unbounded block either.
# --------------------------------------------------------------------------
echo "== Case W6: an out-of-range SUITE_LOCK_WAIT falls back to no wait, loudly =="
sbw6=$(new_sandbox)
cat > "$sbw6/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lockw6="$sbw6/suite.lock"
mkdir -p "$lockw6"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=other\n' \
  "$$" "$(this_host)" "$(date +%s)" > "$lockw6/owner"

outw6=$(SUITE_LOCK_DIR="$lockw6" SUITE_LOCK_WAIT=99999999999999999999 bash "$RUNNER" "$sbw6" 2>&1)
rcw6=$?
if [ "$rcw6" -eq 2 ]; then
  pass "out-of-range SUITE_LOCK_WAIT -> rc 2 (no wait)"
else
  fail "out-of-range SUITE_LOCK_WAIT -> expected rc 2 got $rcw6; output: $outw6"
fi
if grepq "$outw6" -F 'WARN'; then
  pass "output contains a WARN for the out-of-range value"
else
  fail "no WARN in output: $outw6"
fi
if grepq "$outw6" -F 'SUITE_LOCK_WAIT'; then
  pass "the warning names SUITE_LOCK_WAIT"
else
  fail "warning does not name SUITE_LOCK_WAIT; output: $outw6"
fi
if grepq "$outw6" -F 'WAITING:'; then
  fail "out-of-range SUITE_LOCK_WAIT queued instead of falling back; output: $outw6"
else
  pass "no WAITING: heartbeat -- a digit-string typo did not become an unbounded block"
fi
if grep -q "^pid=$$\$" "$lockw6/owner" 2>/dev/null; then
  pass "the holder's lock is still intact after the refusal"
else
  fail "the holder's owner file no longer shows pid=$$; refusal must not have touched it"
fi

# --------------------------------------------------------------------------
# Case W7 -- a permanent safety refusal does NOT queue (HIMMEL-2215 round 2,
# codex-1). SUITE_LOCK_DIR pointed at a directory that exists, has no owner
# file, and is not empty is a safety refusal, not "someone else holds it" --
# waiting can never clear it. Before this fix the wait loop could not tell the
# two apart and would spend the whole SUITE_LOCK_WAIT budget printing
# WAITING: lines naming a holder that does not exist.
# --------------------------------------------------------------------------
echo "== Case W7: a permanent safety refusal does NOT queue =="
sbw7=$(new_sandbox)
cat > "$sbw7/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
mkdir -p "$sbw7/notalock"
touch "$sbw7/notalock/decoy"

start7=$(date +%s)
outw7=$(SUITE_LOCK_DIR="$sbw7/notalock" SUITE_LOCK_WAIT=60 SUITE_LOCK_WAIT_INTERVAL=1 bash "$RUNNER" "$sbw7" 2>&1)
rcw7=$?
elapsed7=$(( $(date +%s) - start7 ))

if [ "$rcw7" -eq 2 ]; then
  pass "permanent refusal -> rc 2"
else
  fail "permanent refusal -> expected rc 2 got $rcw7; output: $outw7"
fi
if grepq "$outw7" -F 'REFUSED'; then
  pass "output contains REFUSED"
else
  fail "no REFUSED in output: $outw7"
fi
if grepq "$outw7" -F 'WAITING:'; then
  fail "a permanent refusal was dressed up as a queue -- WAITING: present; output: $outw7"
else
  pass "no WAITING: heartbeat -- a safety refusal is never presented as a queue"
fi
if grepq "$outw7" -F 'NOT QUEUED'; then
  pass "output contains NOT QUEUED"
else
  fail "no NOT QUEUED verdict in output: $outw7"
fi
if [ "$elapsed7" -lt 30 ]; then
  pass "broke out immediately instead of spending the 60s budget (${elapsed7}s)"
else
  fail "spent ${elapsed7}s on a refusal waiting cannot clear; output: $outw7"
fi

# --------------------------------------------------------------------------
# Case W8 -- the wait budget has a ceiling (HIMMEL-2215 round 2, codex-2). A
# near-intmax SUITE_LOCK_WAIT round-trips the existing validation (it IS
# intmax), but `start + SUITE_LOCK_WAIT` then overflows into a NEGATIVE
# deadline and the run refuses instantly instead of waiting -- so the ceiling
# must reject it as out-of-range, same as an ordinary overflow.
# --------------------------------------------------------------------------
echo "== Case W8: the wait budget has a ceiling =="
sbw8=$(new_sandbox)
cat > "$sbw8/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lockw8="$sbw8/suite.lock"
mkdir -p "$lockw8"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=other\n' \
  "$$" "$(this_host)" "$(date +%s)" > "$lockw8/owner"

outw8a=$(SUITE_LOCK_DIR="$lockw8" SUITE_LOCK_WAIT=31536001 bash "$RUNNER" "$sbw8" 2>&1)
rcw8a=$?
if [ "$rcw8a" -eq 2 ]; then
  pass "just-over-the-ceiling SUITE_LOCK_WAIT -> rc 2 (no wait)"
else
  fail "just-over-the-ceiling SUITE_LOCK_WAIT -> expected rc 2 got $rcw8a; output: $outw8a"
fi
if grepq "$outw8a" -F 'WARN'; then
  pass "output contains a WARN for the over-ceiling value"
else
  fail "no WARN in output: $outw8a"
fi
if grepq "$outw8a" -F 'SUITE_LOCK_WAIT'; then
  pass "the warning names SUITE_LOCK_WAIT"
else
  fail "warning does not name SUITE_LOCK_WAIT; output: $outw8a"
fi
if grepq "$outw8a" -F 'WAITING:'; then
  fail "an over-ceiling SUITE_LOCK_WAIT queued instead of falling back; output: $outw8a"
else
  pass "no WAITING: heartbeat -- the ceiling did not let it queue"
fi
if grep -q "^pid=$$\$" "$lockw8/owner" 2>/dev/null; then
  pass "the holder's lock is still intact after the refusal"
else
  fail "the holder's owner file no longer shows pid=$$; refusal must not have touched it"
fi

outw8b=$(SUITE_LOCK_DIR="$lockw8" SUITE_LOCK_WAIT=9223372036854775807 bash "$RUNNER" "$sbw8" 2>&1)
rcw8b=$?
if [ "$rcw8b" -eq 2 ]; then
  pass "near-intmax SUITE_LOCK_WAIT -> rc 2 (no wait)"
else
  fail "near-intmax SUITE_LOCK_WAIT -> expected rc 2 got $rcw8b; output: $outw8b"
fi
if grepq "$outw8b" -F 'WARN'; then
  pass "output contains a WARN for the near-intmax value"
else
  fail "no WARN in output: $outw8b"
fi
if grepq "$outw8b" -F 'SUITE_LOCK_WAIT'; then
  pass "the warning names SUITE_LOCK_WAIT"
else
  fail "warning does not name SUITE_LOCK_WAIT; output: $outw8b"
fi
if grepq "$outw8b" -F 'WAITING:'; then
  fail "a near-intmax SUITE_LOCK_WAIT queued instead of falling back; output: $outw8b"
else
  pass "no WAITING: heartbeat -- the round-trip-but-overflowing value did not slip through"
fi
if grep -q "^pid=$$\$" "$lockw8/owner" 2>/dev/null; then
  pass "the holder's lock is still intact after the refusal"
else
  fail "the holder's owner file no longer shows pid=$$; refusal must not have touched it"
fi

# --------------------------------------------------------------------------
# Case W9 -- a huge SUITE_LOCK_WAIT_INTERVAL cannot outlive the wait budget
# (HIMMEL-2215 round 3, codex/gpt-5.6-sol). SUITE_LOCK_WAIT_INTERVAL only
# validates as a positive integer, with no upper bound. The clamp used to be
# written as `now + nap > deadline`; with a near-intmax interval that SUM
# wraps negative, so it is never greater than the deadline, the clamp is
# skipped, and `sleep` gets the near-intmax value -- blocking far past the
# SUITE_LOCK_WAIT budget the clamp exists to enforce. The fix compares
# against the remaining budget instead of a sum. A held lock forces the
# queue path (not the NOT-QUEUED safety-refusal path), and the run must
# still give up once SUITE_LOCK_WAIT is spent, well under a minute.
# --------------------------------------------------------------------------
echo "== Case W9: a huge SUITE_LOCK_WAIT_INTERVAL cannot outlive the wait budget =="
sbw9=$(new_sandbox)
cat > "$sbw9/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
lockw9="$sbw9/suite.lock"
mkdir -p "$lockw9"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=other\n' \
  "$$" "$(this_host)" "$(date +%s)" > "$lockw9/owner"

startw9=$(date +%s)
if command -v timeout >/dev/null 2>&1; then
  outw9=$(SUITE_LOCK_DIR="$lockw9" SUITE_LOCK_WAIT=3 SUITE_LOCK_WAIT_INTERVAL=9223372036854775807 \
    timeout 60 bash "$RUNNER" "$sbw9" 2>&1)
  rcw9=$?
  w9_ran=1
else
  # SKIPPED, deliberately -- never run this one unguarded. The case exists to
  # prove a near-intmax interval cannot outlive the budget; without a watchdog
  # a regression in exactly that code path hands `sleep` a near-intmax argument
  # and wedges the whole suite, so the unguarded fallback risks the very hang
  # the case is testing for. A hand-rolled bash watchdog is not the answer
  # either: reaping a runner's whole process tree on Git Bash is the problem
  # scripts/lib/proc-tree.sh exists to solve, and reimplementing it inline in a
  # test is worse than declaring the gap.
  echo "  SKIP  W9 needs the 'timeout' binary to bound a possible hang -- not present, case skipped"
  w9_ran=0
fi
endw9=$(date +%s)
elapsedw9=$(( endw9 - startw9 ))

if [ "$w9_ran" -eq 1 ]; then
  if [ "$rcw9" -eq 124 ]; then
    fail "the interval clamp was skipped; sleep outlived the budget (timed out after ${elapsedw9}s)"
  else
    # rc 5 (HIMMEL-2623): this genuinely waited out its budget against a
    # still-held lock -- the EXPIRED class, not the instant-refusal rc 2.
    if [ "$rcw9" -eq 5 ]; then
      pass "huge SUITE_LOCK_WAIT_INTERVAL -> rc 5 (budget spent, refused)"
    else
      fail "huge SUITE_LOCK_WAIT_INTERVAL -> expected rc 5 got $rcw9; output: $outw9"
    fi
    if [ "$elapsedw9" -lt 60 ]; then
      pass "gave up in ${elapsedw9}s -- did not sleep past the budget"
    else
      fail "took ${elapsedw9}s -- the clamp let sleep run past the budget; output: $outw9"
    fi
    if grepq "$outw9" -F 'GAVE UP'; then
      pass "output contains GAVE UP -- this is the queue path, not a safety refusal"
    else
      fail "no GAVE UP in output: $outw9"
    fi
  fi
  if grep -q "^pid=$$\$" "$lockw9/owner" 2>/dev/null; then
    pass "the holder's lock is still intact after the wait"
  else
    fail "the holder's owner file no longer shows pid=$$; the wait must not have touched it"
  fi
fi

# --------------------------------------------------------------------------
# Case W10 -- RED CONTROL (HIMMEL-2623): an older ticket is never jumped, even
# when the lock is completely FREE. Deterministic, no race window: the
# planted ticket is what blocks the new waiter, not lock contention. This is
# the done-criterion evidence for the FIFO fix -- before it existed, the
# runner had no notion of a ticket at all and acquired a free lock instantly
# regardless of who else was "waiting."
#
# Ticket dir is named for the helper's OWN pid (HIMMEL-2623 round 3) -- the
# shipped scheme has no allocated sequence numbers, a ticket IS its owner's
# pid -- and `started` is stamped a few seconds in the PAST, unambiguously
# earlier than whatever second the real waiter joins in.
# --------------------------------------------------------------------------
echo "== Case W10: an older ticket is never jumped (deterministic RED control) =="
sbw10=$(new_sandbox)
cat > "$sbw10/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/ran"
exit 0
SHEOF
lockw10="$sbw10/suite.lock"

# A real, live pid this case owns -- not a simulation. Same host, `started` a
# few seconds in the past: nothing about this ticket looks abandoned, and its
# arrival time is unambiguously earlier than the real waiter's.
sleep 60 &
w10_helper_pid=$!
mkdir -p "$lockw10.q/$w10_helper_pid"
printf 'pid=%s\nhost=%s\nstarted=%s\n' "$w10_helper_pid" "$(this_host)" "$(( $(date +%s) - 5 ))" \
  > "$lockw10.q/$w10_helper_pid/owner"

outw10=$(SUITE_LOCK_DIR="$lockw10" SUITE_LOCK_WAIT=3 SUITE_LOCK_WAIT_INTERVAL=1 bash "$RUNNER" "$sbw10" 2>&1)
rcw10=$?

kill "$w10_helper_pid" 2>/dev/null
wait "$w10_helper_pid" 2>/dev/null

if [ "$rcw10" -eq 5 ]; then
  pass "W10a: blocked behind an older LIVE ticket despite a FREE lock -> rc 5"
else
  fail "W10a: expected rc 5 got $rcw10; output: $outw10"
fi
if grepq "$outw10" -E 'LOCK-WAIT EXPIRED after [0-9]+s'; then
  pass "W10b: LOCK-WAIT EXPIRED line present"
else
  fail "W10b: no LOCK-WAIT EXPIRED line; output: $outw10"
fi
if [ -e "$sbw10/ran" ]; then
  fail "W10c: the suite RAN even though an older ticket was still queued (it was jumped); output: $outw10"
else
  pass "W10c: the suite never ran -- the older ticket was never jumped"
fi
# W10d/e (HIMMEL-2623 round 2, Defect 2): the lock here is FREE -- the block
# is entirely a queue-position matter -- so the GAVE UP wording must say so,
# not claim a holder that does not exist.
if grepq "$outw10" -F 'still behind an older waiter in the queue'; then
  pass "W10d: GAVE UP names the queue-position reason, naming the blocking ticket"
else
  fail "W10d: GAVE UP does not name the queue-position reason; output: $outw10"
fi
if grepq "$outw10" -F 'and it is still held'; then
  fail "W10e: GAVE UP falsely claims the lock 'is still held' when it was actually FREE; output: $outw10"
else
  pass "W10e: GAVE UP does not falsely claim the lock is held"
fi

# --------------------------------------------------------------------------
# Case W10b -- a DEAD older waiter does not wedge the queue. No manual sweep:
# the very next poll must prune this ticket on its own (PRUNING, above the
# queue helpers) and let this run through.
# --------------------------------------------------------------------------
echo "== Case W10b: a DEAD older waiter does not wedge the queue =="
sbw10b=$(new_sandbox)
cat > "$sbw10b/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/ran"
exit 0
SHEOF
lockw10b="$sbw10b/suite.lock"

# Same idiom as Case 2's dead pid: a trivial child spawned and reaped by this
# case, dead by construction on every platform (never a hardcoded constant --
# pid_max is tunable and could name a live process). The ticket dir is named
# for that SAME dead pid -- matching the shipped scheme, where a ticket's
# directory name IS its owner's pid.
bash -c 'exit 0' & w10b_dead_pid=$!
wait "$w10b_dead_pid" 2>/dev/null

mkdir -p "$lockw10b.q/$w10b_dead_pid"
printf 'pid=%s\nhost=%s\nstarted=%s\n' "$w10b_dead_pid" "$(this_host)" "$(date +%s)" \
  > "$lockw10b.q/$w10b_dead_pid/owner"

outw10b=$(SUITE_LOCK_DIR="$lockw10b" SUITE_LOCK_WAIT=5 SUITE_LOCK_WAIT_INTERVAL=1 bash "$RUNNER" "$sbw10b" 2>&1)
rcw10b=$?

if [ "$rcw10b" -eq 0 ]; then
  pass "W10ba: a dead older ticket is pruned, not honoured -> rc 0"
else
  fail "W10ba: expected rc 0 got $rcw10b; output: $outw10b"
fi
if [ -e "$sbw10b/ran" ]; then
  pass "W10bb: the suite ran -- the dead ticket did not wedge the queue"
else
  fail "W10bb: the suite never ran; output: $outw10b"
fi
if [ -d "$lockw10b.q/$w10b_dead_pid" ]; then
  fail "W10bc: the stale ticket directory is still present -- no manual sweep exists, this must self-heal"
else
  pass "W10bc: the stale ticket directory is gone"
fi

# --------------------------------------------------------------------------
# Case W11 -- two REAL waiters, the OLDER wins. Live two-process(-pair) race,
# not a simulation: this is the done-criterion evidence that the queue
# actually orders concurrent contenders, not just a single planted ticket.
# Ticket dirs are pid-named (HIMMEL-2623 round 3), so "ticket_a"/"ticket_b"
# below are the two waiters' OS pids, not a 1/2 sequence -- ordering is
# asserted on `started`, the actual invariant, never on pid magnitude.
# --------------------------------------------------------------------------
echo "== Case W11: two real waiters, the older wins =="
sbw11a=$(new_sandbox)
sbw11b=$(new_sandbox)
orderw11="$WORK/w11-order"
cat > "$sbw11a/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
printf 'A\n' >> "$(dirname "$0")/../w11-order"
exit 0
SHEOF
cat > "$sbw11b/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
printf 'B\n' >> "$(dirname "$0")/../w11-order"
exit 0
SHEOF
lockw11="$WORK/w11-suite.lock"
mkdir -p "$lockw11"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=other\n' \
  "$$" "$(this_host)" "$(date +%s)" > "$lockw11/owner"

SUITE_LOCK_DIR="$lockw11" SUITE_LOCK_WAIT=20 SUITE_LOCK_WAIT_INTERVAL=1 \
  bash "$RUNNER" "$sbw11a" >"$sbw11a/waiter.log" 2>&1 &
w11a_pid=$!

_spin=0
while [ -z "$(ticket_list "$lockw11.q" 2>/dev/null)" ] && [ "$_spin" -lt 100 ]; do
  sleep 0.1
  _spin=$((_spin + 1))
done
ticket_a=$(ticket_list "$lockw11.q" 2>/dev/null | sort -n | head -1)

if [ -z "$ticket_a" ]; then
  fail "W11 setup -- waiter A never took a ticket within 10s; cannot run the race"
  kill "$w11a_pid" 2>/dev/null
  wait "$w11a_pid" 2>/dev/null
else
  SUITE_LOCK_DIR="$lockw11" SUITE_LOCK_WAIT=20 SUITE_LOCK_WAIT_INTERVAL=1 \
    bash "$RUNNER" "$sbw11b" >"$sbw11b/waiter.log" 2>&1 &
  w11b_pid=$!

  _spin=0
  while [ "$(ticket_list "$lockw11.q" 2>/dev/null | wc -l)" -lt 2 ] && [ "$_spin" -lt 100 ]; do
    sleep 0.1
    _spin=$((_spin + 1))
  done
  # Select ticket B by IDENTITY -- "whichever ticket is not ticket_a" --
  # never by pid magnitude (HIMMEL-2623 round 5, codex-1). Pids wrap and are
  # not monotonic, so "the larger pid" can silently RE-SELECT A when B
  # happens to land on a lower pid than A -- a spurious, load- and
  # wraparound-dependent red reported as "waiter B never took a distinct
  # ticket," which would be maddening to chase since it is not reproducible
  # on demand. Assert exactly one non-A candidate rather than guessing.
  ticket_b_candidates=$(ticket_list "$lockw11.q" 2>/dev/null | grep -v -x -F "$ticket_a")
  ticket_b_count=0
  [ -n "$ticket_b_candidates" ] && ticket_b_count=$(printf '%s\n' "$ticket_b_candidates" | wc -l)

  if [ "$ticket_b_count" -eq 0 ]; then
    fail "W11 setup -- waiter B never took a distinct ticket within 10s; cannot run the race"
    kill "$w11a_pid" "$w11b_pid" 2>/dev/null
    wait "$w11a_pid" 2>/dev/null
    wait "$w11b_pid" 2>/dev/null
  elif [ "$ticket_b_count" -gt 1 ]; then
    fail "W11 setup -- more than one candidate ticket for waiter B, selection is ambiguous: $ticket_b_candidates"
    kill "$w11a_pid" "$w11b_pid" 2>/dev/null
    wait "$w11a_pid" 2>/dev/null
    wait "$w11b_pid" 2>/dev/null
  else
    ticket_b="$ticket_b_candidates"
    # NOT a ticket-NUMBER comparison (HIMMEL-2623 round 3): tickets are now
    # named for their owner's pid, which carries no ordering guarantee
    # relative to another process's pid. Order comes from `started` in each
    # ticket's own owner file -- assert THAT instead, which is the actual
    # invariant the shipped design provides (A joined strictly before B was
    # even launched, so A's `started` must not be later than B's).
    started_a=$(grep '^started=' "$lockw11.q/$ticket_a/owner" 2>/dev/null | cut -d= -f2)
    started_b=$(grep '^started=' "$lockw11.q/$ticket_b/owner" 2>/dev/null | cut -d= -f2)
    if [ -n "$started_a" ] && [ -n "$started_b" ] && [ "$started_a" -le "$started_b" ]; then
      pass "W11a: waiter A's ticket started ($started_a) is not later than waiter B's ($started_b)"
    else
      fail "W11a: waiter A started=$started_a, waiter B started=$started_b -- A should not sort after B"
    fi

    # Free the lock -- the case planted it directly (like W1/W2/W4), so
    # freeing it is a plain removal, not signalling a process.
    rm -rf "$lockw11"

    _spin=0
    # `wc -l < missing-file` fails in the SHELL's redirection, before wc runs,
    # so the command's own 2>/dev/null cannot suppress the resulting "No such
    # file or directory" — it has to be silenced at the substitution. Test for
    # the file first instead, which keeps the poll quiet until the waiters
    # create it.
    while [ "$([ -f "$orderw11" ] && wc -l < "$orderw11" || echo 0)" -lt 2 ] && [ "$_spin" -lt 200 ]; do
      sleep 0.1
      _spin=$((_spin + 1))
    done

    wait "$w11a_pid"
    rc11a=$?
    wait "$w11b_pid"
    rc11b=$?

    if [ "$rc11a" -eq 0 ] && [ "$rc11b" -eq 0 ]; then
      pass "W11b: both waiters eventually ran (rc 0 each)"
    else
      fail "W11b: waiter A rc=$rc11a, waiter B rc=$rc11b; A log: $(cat "$sbw11a/waiter.log" 2>/dev/null); B log: $(cat "$sbw11b/waiter.log" 2>/dev/null)"
    fi

    orderw11_content=$(cat "$orderw11" 2>/dev/null || echo "")
    if [ "$orderw11_content" = "$(printf 'A\nB')" ]; then
      pass "W11c: order file reads A before B -- the older ticket ran first"
    else
      fail "W11c: expected order 'A' then 'B', got: $orderw11_content"
    fi
  fi
fi

# --------------------------------------------------------------------------
# Case W12 -- the expiry line and its rc: printed to STDOUT (not stderr, where
# GAVE UP already lives), matching the exact regex, with a distinct rc 5.
# --------------------------------------------------------------------------
echo "== Case W12: the expiry line and its rc =="
sbw12=$(new_sandbox)
cat > "$sbw12/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/ran"
exit 0
SHEOF
lockw12="$sbw12/suite.lock"
mkdir -p "$lockw12"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=other\n' \
  "$$" "$(this_host)" "$(date +%s)" > "$lockw12/owner"

errw12="$sbw12/stderr.log"
outw12=$(SUITE_LOCK_DIR="$lockw12" SUITE_LOCK_WAIT=2 SUITE_LOCK_WAIT_INTERVAL=1 \
  bash "$RUNNER" "$sbw12" 2>"$errw12")
rcw12=$?
errcontentw12=$(cat "$errw12" 2>/dev/null || echo "")

if [ "$rcw12" -eq 5 ]; then
  pass "W12a: budget expiry against a still-held lock -> rc 5"
else
  fail "W12a: expected rc 5 got $rcw12; stdout: $outw12; stderr: $errcontentw12"
fi
if grepq "$outw12" -E '^LOCK-WAIT EXPIRED after [0-9]+s — run NOT executed$'; then
  pass "W12b: the exact LOCK-WAIT EXPIRED line is present, alone on its own line, on STDOUT"
else
  fail "W12b: stdout does not match the exact LOCK-WAIT EXPIRED line; stdout: $outw12"
fi
if grepq "$errcontentw12" -F 'LOCK-WAIT EXPIRED'; then
  fail "W12c: the LOCK-WAIT EXPIRED line leaked onto stderr; stderr: $errcontentw12"
else
  pass "W12c: the LOCK-WAIT EXPIRED line is NOT on stderr"
fi
if grepq "$errcontentw12" -F 'GAVE UP'; then
  pass "W12d: GAVE UP is still present on stderr"
else
  fail "W12d: no GAVE UP on stderr; stderr: $errcontentw12"
fi
ownerw12=$(cat "$lockw12/owner" 2>/dev/null || echo "")
if grepq "$ownerw12" -F "pid=$$"; then
  pass "W12e: the holder's owner file is intact"
else
  fail "W12e: the holder's owner file was disturbed; owner: $ownerw12"
fi

# --------------------------------------------------------------------------
# Case W13 -- coexistence with the OLD (pre-HIMMEL-2623) lock layout: a held
# lock with no .q sibling at all, exactly what a not-yet-upgraded holder
# leaves behind. A new waiter must still wait, never acquire early, and never
# add anything to the holder's own directory.
# --------------------------------------------------------------------------
echo "== Case W13: coexistence with the OLD lock layout =="
sbw13=$(new_sandbox)
cat > "$sbw13/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/ran"
exit 0
SHEOF
lockw13="$sbw13/suite.lock"
mkdir -p "$lockw13"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=other\n' \
  "$$" "$(this_host)" "$(date +%s)" > "$lockw13/owner"
ownerw13_before=$(cat "$lockw13/owner")

outw13=$(SUITE_LOCK_DIR="$lockw13" SUITE_LOCK_WAIT=3 SUITE_LOCK_WAIT_INTERVAL=1 bash "$RUNNER" "$sbw13" 2>&1)
rcw13=$?

if grepq "$outw13" -F 'WAITING:'; then
  pass "W13a: the new waiter queued behind the old-style lock (a WAITING: heartbeat appeared)"
else
  fail "W13a: no WAITING: heartbeat; output: $outw13"
fi
if [ "$rcw13" -eq 5 ]; then
  pass "W13b: never acquired -> rc 5"
else
  fail "W13b: expected rc 5 got $rcw13; output: $outw13"
fi
if [ -e "$sbw13/ran" ]; then
  fail "W13c: the suite RAN against a held old-style lock; output: $outw13"
else
  pass "W13c: the suite never ran"
fi
lockcontentsw13=""
for f in "$lockw13"/* "$lockw13"/.[!.]* "$lockw13"/..?*; do
  { [ -e "$f" ] || [ -L "$f" ]; } || continue
  lockcontentsw13="${lockcontentsw13}${f##*/} "
done
if [ "$lockcontentsw13" = "owner " ]; then
  pass "W13d: the holder's lock directory still contains ONLY owner -- nothing new was added inside it"
else
  fail "W13d: unexpected lock directory contents: $lockcontentsw13"
fi
ownerw13_after=$(cat "$lockw13/owner" 2>/dev/null || echo "")
if [ "$ownerw13_after" = "$ownerw13_before" ]; then
  pass "W13e: the owner file is byte-identical to what was planted"
else
  fail "W13e: owner file changed -- before: $ownerw13_before; after: $ownerw13_after"
fi

# --------------------------------------------------------------------------
# Case W14 -- RE-ENTRANCY beats the queue (HIMMEL-2623 round 2, Defect 1: a
# DEADLOCK the queue introduced into exactly the after-report path it exists
# to fix). HIMMEL_SUITE_LOCK_HELD is EXPORTED by _suite_lock_claim, and
# SUITE_LOCK_WAIT is inherited by every child suite process -- this file's own
# header unsets it for exactly that reason. A nested runner invocation under a
# real holder must pass straight through (suite_lock_acquire's own
# re-entrancy short-circuit), never join the queue, and never be blocked by
# an older waiter's ticket -- even a genuinely live one.
# --------------------------------------------------------------------------
echo "== Case W14: re-entrancy beats the queue =="
sbw14=$(new_sandbox)
cat > "$sbw14/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/ran"
exit 0
SHEOF
lockw14="$sbw14/suite.lock"

sleep 60 &
w14_helper_pid=$!
mkdir -p "$lockw14.q/$w14_helper_pid"
printf 'pid=%s\nhost=%s\nstarted=%s\n' "$w14_helper_pid" "$(this_host)" "$(date +%s)" \
  > "$lockw14.q/$w14_helper_pid/owner"

start14=$(date +%s)
outw14=$(SUITE_LOCK_DIR="$lockw14" HIMMEL_SUITE_LOCK_HELD="$lockw14" \
  SUITE_LOCK_WAIT=3 SUITE_LOCK_WAIT_INTERVAL=1 bash "$RUNNER" "$sbw14" 2>&1)
rcw14=$?
elapsedw14=$(( $(date +%s) - start14 ))

kill "$w14_helper_pid" 2>/dev/null
wait "$w14_helper_pid" 2>/dev/null

if [ "$rcw14" -eq 0 ]; then
  pass "W14a: re-entrant run acquires despite an older queued ticket -> rc 0"
else
  fail "W14a: expected rc 0 got $rcw14; output: $outw14"
fi
if [ -e "$sbw14/ran" ]; then
  pass "W14b: the suite ran"
else
  fail "W14b: the suite never ran; output: $outw14"
fi
if [ "$elapsedw14" -lt 3 ]; then
  pass "W14c: returned fast (${elapsedw14}s), well under the 3s budget -- never queued at all"
else
  fail "W14c: took ${elapsedw14}s -- spent (part of) the budget, meaning it queued instead of passing straight through; output: $outw14"
fi

# --------------------------------------------------------------------------
# Case W15 -- SUITE_LOCK=0 beats the queue (HIMMEL-2623 round 2, Defect 1):
# the documented escape hatch (Case 4) must never be gated by a queue a
# lock-disabled run does not participate in.
# --------------------------------------------------------------------------
echo "== Case W15: SUITE_LOCK=0 beats the queue =="
sbw15=$(new_sandbox)
cat > "$sbw15/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/ran"
exit 0
SHEOF
lockw15="$sbw15/suite.lock"

sleep 60 &
w15_helper_pid=$!
mkdir -p "$lockw15.q/$w15_helper_pid"
printf 'pid=%s\nhost=%s\nstarted=%s\n' "$w15_helper_pid" "$(this_host)" "$(date +%s)" \
  > "$lockw15.q/$w15_helper_pid/owner"

outw15=$(SUITE_LOCK_DIR="$lockw15" SUITE_LOCK=0 SUITE_LOCK_WAIT=3 bash "$RUNNER" "$sbw15" 2>&1)
rcw15=$?

kill "$w15_helper_pid" 2>/dev/null
wait "$w15_helper_pid" 2>/dev/null

if [ "$rcw15" -eq 0 ]; then
  pass "W15a: SUITE_LOCK=0 acquires despite an older queued ticket -> rc 0"
else
  fail "W15a: expected rc 0 got $rcw15; output: $outw15"
fi
if [ -e "$sbw15/ran" ]; then
  pass "W15b: the suite ran"
else
  fail "W15b: the suite never ran; output: $outw15"
fi

# --------------------------------------------------------------------------
# Case W16 (HIMMEL-2623 round 3, CR finding codex-1): scan-then-mkdir was NOT
# an atomic FIFO allocation -- a stalled contender's delayed mkdir could land
# on a ticket number freed out from under it, jumping a genuinely older,
# still-queued waiter. The fix drops the scan entirely: a ticket's identity
# is its owner's pid (unique by construction, no scan needed) and its ORDER
# is `started`, read fresh from the owner file on every comparison. This case
# is the deterministic regression proof of that property under the SHIPPED
# design: an older ticket (by `started`, planted a few seconds in the past on
# a real live pid) must still block a brand-new waiter, with no scan step
# left to race. The RED-control reproduction of the ORIGINAL bug (a scratch
# copy of the pre-round-3 scan+mkdir allocator, with a deterministic stall
# injected between the scan and the mkdir) is not committed here -- it lives
# only in the round-3 investigation notes; it is not repeatable against this
# shipped code because the scan it exploited no longer exists.
# --------------------------------------------------------------------------
echo "== Case W16: an older ticket (by started, not by pid magnitude) is never jumped =="
sbw16=$(new_sandbox)
cat > "$sbw16/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/ran"
exit 0
SHEOF
lockw16="$sbw16/suite.lock"

sleep 60 &
w16_helper_pid=$!
mkdir -p "$lockw16.q/$w16_helper_pid"
printf 'pid=%s\nhost=%s\nstarted=%s\n' "$w16_helper_pid" "$(this_host)" "$(( $(date +%s) - 5 ))" \
  > "$lockw16.q/$w16_helper_pid/owner"

outw16=$(SUITE_LOCK_DIR="$lockw16" SUITE_LOCK_WAIT=3 SUITE_LOCK_WAIT_INTERVAL=1 bash "$RUNNER" "$sbw16" 2>&1)
rcw16=$?

kill "$w16_helper_pid" 2>/dev/null
wait "$w16_helper_pid" 2>/dev/null

if [ "$rcw16" -eq 5 ]; then
  pass "W16a: blocked behind the earlier-started ticket despite a FREE lock -> rc 5"
else
  fail "W16a: expected rc 5 got $rcw16; output: $outw16"
fi
if [ -e "$sbw16/ran" ]; then
  fail "W16b: the suite RAN even though an earlier-started ticket was still queued; output: $outw16"
else
  pass "W16b: the suite never ran"
fi
if grepq "$outw16" -F "pid=$w16_helper_pid"; then
  pass "W16c: the blocker is named by pid, matching the shipped ticket identity"
else
  fail "W16c: output does not name the blocking helper's pid; output: $outw16"
fi

# --------------------------------------------------------------------------
# Case W17 (HIMMEL-2623 round 4, CR finding codex-1): a NO-WAIT run yields to
# a queued waiter even though the lock is completely FREE. Before this fix, a
# no-wait run made one direct attempt regardless of who was queued -- so the
# starvation this whole file exists to remove would have survived even a
# fleet where every runner is upgraded, because an ad-hoc no-wait invocation
# could always win a freshly-freed lock ahead of the oldest waiter's next
# poll. This is the RED-control-shaped regression proof: lock free, one live
# older ticket queued, a brand-new NO-WAIT run must refuse, not acquire.
# --------------------------------------------------------------------------
echo "== Case W17: a no-wait run yields to a queued waiter, even with a FREE lock =="
sbw17=$(new_sandbox)
cat > "$sbw17/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/ran"
exit 0
SHEOF
lockw17="$sbw17/suite.lock"

sleep 60 &
w17_helper_pid=$!
mkdir -p "$lockw17.q/$w17_helper_pid"
printf 'pid=%s\nhost=%s\nstarted=%s\n' "$w17_helper_pid" "$(this_host)" "$(( $(date +%s) - 5 ))" \
  > "$lockw17.q/$w17_helper_pid/owner"
ownerw17_before=$(cat "$lockw17.q/$w17_helper_pid/owner")

# No SUITE_LOCK_WAIT at all -- the default no-wait, ad-hoc path.
outw17=$(SUITE_LOCK_DIR="$lockw17" bash "$RUNNER" "$sbw17" 2>&1)
rcw17=$?

kill "$w17_helper_pid" 2>/dev/null
wait "$w17_helper_pid" 2>/dev/null

if [ "$rcw17" -eq 2 ]; then
  pass "W17a: no-wait run yields to the queued waiter -> rc 2"
else
  fail "W17a: expected rc 2 got $rcw17; output: $outw17"
fi
if grepq "$outw17" -F 'REFUSED'; then
  pass "W17b: the refusal is REFUSED-shaped, same as a held-lock refusal"
else
  fail "W17b: no REFUSED in output: $outw17"
fi
if grepq "$outw17" -F 'queued waiter'; then
  pass "W17c: the refusal names queued waiter(s), not a holder"
else
  fail "W17c: refusal does not mention a queued waiter; output: $outw17"
fi
if [ -e "$sbw17/ran" ]; then
  fail "W17d: the suite RAN despite the queued older waiter; output: $outw17"
else
  pass "W17d: the suite never ran"
fi
# READ-ONLY: a no-wait run must not take a ticket of its own. The queue must
# still hold EXACTLY the one ticket this case planted -- nothing added.
qcontentsw17=""
for f in "$lockw17.q"/*; do
  [ -d "$f" ] || continue
  qcontentsw17="${qcontentsw17}${f##*/} "
done
if [ "$qcontentsw17" = "$w17_helper_pid " ]; then
  pass "W17e: the no-wait run took no ticket of its own -- queue unchanged"
else
  fail "W17e: queue contents changed -- expected only '$w17_helper_pid', got: $qcontentsw17"
fi
ownerw17_after=$(cat "$lockw17.q/$w17_helper_pid/owner" 2>/dev/null || echo "")
if [ "$ownerw17_after" = "$ownerw17_before" ]; then
  pass "W17f: the planted ticket's owner file is untouched"
else
  fail "W17f: the planted ticket's owner file changed -- before: $ownerw17_before; after: $ownerw17_after"
fi

# --------------------------------------------------------------------------
# Case W18 -- CONTROL for W17: a no-wait run against a FREE lock with an
# EMPTY queue still acquires immediately. Without this, W17 alone would not
# distinguish "no-wait now refuses unconditionally" from "no-wait correctly
# yields only when something is actually queued."
# --------------------------------------------------------------------------
echo "== Case W18: control -- a no-wait run still acquires when the queue is empty =="
sbw18=$(new_sandbox)
cat > "$sbw18/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/ran"
exit 0
SHEOF
lockw18="$sbw18/suite.lock"

outw18=$(SUITE_LOCK_DIR="$lockw18" bash "$RUNNER" "$sbw18" 2>&1)
rcw18=$?

if [ "$rcw18" -eq 0 ]; then
  pass "W18a: no-wait run with an empty queue -> rc 0"
else
  fail "W18a: expected rc 0 got $rcw18; output: $outw18"
fi
if [ -e "$sbw18/ran" ]; then
  pass "W18b: the suite ran"
else
  fail "W18b: the suite never ran; output: $outw18"
fi

# --------------------------------------------------------------------------
# Case W19 (HIMMEL-2623 round 6, CR finding codex-1): a waiter whose own
# ticket is deleted out from under it -- another runner's SUITE_QUEUE_TTL
# prune in production, simulated here by just removing the directory, so the
# case is deterministic and fast rather than waiting out a real multi-hour
# TTL -- must RESTORE its own ticket at its ORIGINAL arrival stamp on its
# next poll, and must NOT treat the gap as "our turn": it still yields to
# the older waiter it was already behind. Before this fix,
# suite_lock_queue_is_our_turn read the missing owner file as empty,
# returned "our turn" (fail-open), and the waiter would have jumped the
# older ticket the instant the lock (which is FREE here) let it.
# --------------------------------------------------------------------------
echo "== Case W19: a waiter restores its own vanished ticket, and still yields =="
sbw19=$(new_sandbox)
cat > "$sbw19/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/ran"
exit 0
SHEOF
lockw19="$sbw19/suite.lock"

# An older, live, still-queued waiter this case owns directly.
sleep 60 &
w19_helper_pid=$!
mkdir -p "$lockw19.q/$w19_helper_pid"
printf 'pid=%s\nhost=%s\nstarted=%s\n' "$w19_helper_pid" "$(this_host)" "$(( $(date +%s) - 5 ))" \
  > "$lockw19.q/$w19_helper_pid/owner"

# The REAL waiter under test -- budget long enough to survive the deletion
# and one full poll interval, short enough to keep this case fast.
SUITE_LOCK_DIR="$lockw19" SUITE_LOCK_WAIT=8 SUITE_LOCK_WAIT_INTERVAL=1 \
  bash "$RUNNER" "$sbw19" >"$sbw19/waiter.log" 2>&1 &
w19_pid=$!

_spin=0
while [ ! -d "$lockw19.q/$w19_pid" ] && [ "$_spin" -lt 100 ]; do
  sleep 0.1
  _spin=$((_spin + 1))
done
if [ ! -d "$lockw19.q/$w19_pid" ]; then
  fail "W19 setup -- the waiter under test never took its own ticket within 10s; cannot run the case"
  kill "$w19_pid" "$w19_helper_pid" 2>/dev/null
  wait "$w19_pid" 2>/dev/null
  wait "$w19_helper_pid" 2>/dev/null
else
  w19_started_orig=$(grep '^started=' "$lockw19.q/$w19_pid/owner" 2>/dev/null | cut -d= -f2)

  # Delete it out from under the still-running waiter -- the deterministic
  # stand-in for a TTL prune by another runner.
  rm -rf "$lockw19.q/$w19_pid"

  # Wait for the BRANDED owner file, not the directory: the restore path
  # (run-shell-tests.sh: mkdir -p, then _suite_lock_queue_brand's temp-write
  # + mv) opens a window where the directory exists and owner does not --
  # polling the directory alone reads a false-empty started= inside that
  # window (HIMMEL-2921). Same 5s budget as before.
  _spin=0
  while ! grep -q '^started=.' "$lockw19.q/$w19_pid/owner" 2>/dev/null && [ "$_spin" -lt 50 ]; do
    sleep 0.1
    _spin=$((_spin + 1))
  done
  if grep -q '^started=.' "$lockw19.q/$w19_pid/owner" 2>/dev/null; then
    pass "W19a: the vanished ticket was restored on the waiter's next poll"
    w19_started_restored=$(grep '^started=' "$lockw19.q/$w19_pid/owner" 2>/dev/null | cut -d= -f2)
    if [ -n "$w19_started_orig" ] && [ "$w19_started_restored" = "$w19_started_orig" ]; then
      pass "W19b: restored at the ORIGINAL arrival stamp ($w19_started_orig), not a fresh one"
    else
      fail "W19b: restored started=$w19_started_restored, original was $w19_started_orig -- position was NOT preserved"
    fi
  elif [ -d "$lockw19.q/$w19_pid" ]; then
    fail "W19a: directory restored, owner never branded within 5s"
  else
    fail "W19a: the ticket was never restored within 5s; the waiter's queue position is lost"
  fi

  wait "$w19_pid"
  rcw19=$?

  if [ "$rcw19" -eq 5 ]; then
    pass "W19c: the waiter still yielded to the older ticket -> rc 5 (never jumped it)"
  else
    fail "W19c: expected rc 5 got $rcw19 -- a restored-but-jumping waiter is the exact bug; waiter log: $(cat "$sbw19/waiter.log" 2>/dev/null)"
  fi
  if [ -e "$sbw19/ran" ]; then
    fail "W19d: the suite RAN -- the waiter jumped the older, still-queued ticket"
  else
    pass "W19d: the suite never ran"
  fi

  kill "$w19_helper_pid" 2>/dev/null
  wait "$w19_helper_pid" 2>/dev/null
fi

# --------------------------------------------------------------------------
# Case W19e (HIMMEL-2921, RED control): replays the exact mkdir->mv window
# the restore path opens -- a PATH shim delays a _suite_lock_queue_brand
# `mv` by 0.5s, but ONLY once armed by a trigger file this case creates
# right after deleting the ticket (never sooner), so it is always the
# restore's own brand call that gets delayed -- never the initial join's or
# an interceding heartbeat refresh, whichever happens to land second. W19's
# own restore-wait above is the only thing standing between a correct
# started= read and the empty-started= misread that failed CI shard 5. Its
# own shim, not the shared race_shim_prepare one above (that shadows mkdir;
# this needs mv) -- same MSYS +x rationale applies.
# --------------------------------------------------------------------------
echo "== Case W19e: the restore-wait survives the mkdir->mv window (HIMMEL-2921) =="
sbw19e=$(new_sandbox)
cat > "$sbw19e/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/ran"
exit 0
SHEOF
lockw19e="$sbw19e/suite.lock"
mvshim=$(mktemp -d "$WORK/shimXXXXXX")
MV_REAL=$(command -v mv)
export MV_REAL
cat > "$mvshim/mv" <<'SHEOF'
#!/usr/bin/env bash
# Test shim, not a runtime component: shadows mv on PATH for one runner
# invocation, delaying a _suite_lock_queue_brand call (`mv -f "$tmp"
# "$dir/owner"` -- $2/$3, "-f" is $1) only once MV_TRIGGER exists -- armed
# by the case right after it deletes the ticket, so the delayed call is
# always the restore's own brand, deterministically.
case "$2" in
  */.brand.*.tmp) case "$3" in */owner)
    if [ -f "${MV_TRIGGER:?}" ]; then
      printf x >> "${MV_HITS:?}"
      sleep "${MV_DELAY:?}"
    fi
  ;; esac ;;
esac
exec "${MV_REAL:?}" "$@"
SHEOF
chmod +x "$mvshim/mv"

sleep 60 &
w19e_helper_pid=$!
mkdir -p "$lockw19e.q/$w19e_helper_pid"
printf 'pid=%s\nhost=%s\nstarted=%s\n' "$w19e_helper_pid" "$(this_host)" "$(( $(date +%s) - 5 ))" \
  > "$lockw19e.q/$w19e_helper_pid/owner"

PATH="$mvshim:$PATH" MV_HITS="$sbw19e/mv-hits" MV_TRIGGER="$sbw19e/mv-trigger" MV_DELAY=0.5 \
  SUITE_LOCK_DIR="$lockw19e" SUITE_LOCK_WAIT=8 SUITE_LOCK_WAIT_INTERVAL=1 \
  bash "$RUNNER" "$sbw19e" >"$sbw19e/waiter.log" 2>&1 &
w19e_pid=$!

_spin=0
while ! grep -q '^started=.' "$lockw19e.q/$w19e_pid/owner" 2>/dev/null && [ "$_spin" -lt 100 ]; do
  sleep 0.1
  _spin=$((_spin + 1))
done
if ! grep -q '^started=.' "$lockw19e.q/$w19e_pid/owner" 2>/dev/null; then
  fail "W19e setup -- the waiter under test never branded its own ticket within 10s; cannot run the case"
  kill "$w19e_pid" "$w19e_helper_pid" 2>/dev/null
  wait "$w19e_pid" 2>/dev/null
  wait "$w19e_helper_pid" 2>/dev/null
else
  w19e_started_orig=$(grep '^started=' "$lockw19e.q/$w19e_pid/owner" 2>/dev/null | cut -d= -f2)
  # Arm the shim BEFORE deleting the ticket (codex-2): the restore's brand
  # call happens strictly after the delete, so this leaves no gap where it
  # could slip through undelayed.
  : > "$sbw19e/mv-trigger"
  rm -rf "$lockw19e.q/$w19e_pid"

  _spin=0
  while ! grep -q '^started=.' "$lockw19e.q/$w19e_pid/owner" 2>/dev/null && [ "$_spin" -lt 50 ]; do
    sleep 0.1
    _spin=$((_spin + 1))
  done

  if [ -s "$sbw19e/mv-hits" ]; then
    pass "W19e precondition: the shim replayed the restore's mkdir->mv window"
  else
    fail "W19e precondition: the shim never fired after the ticket was deleted -- the mkdir->mv window did not replay, this case proves nothing"
  fi

  if grep -q '^started=.' "$lockw19e.q/$w19e_pid/owner" 2>/dev/null; then
    pass "W19a (mkdir->mv window): the vanished ticket was restored despite the mv delay"
    w19e_started_restored=$(grep '^started=' "$lockw19e.q/$w19e_pid/owner" 2>/dev/null | cut -d= -f2)
    if [ -n "$w19e_started_orig" ] && [ "$w19e_started_restored" = "$w19e_started_orig" ]; then
      pass "W19b (mkdir->mv window): restored at the ORIGINAL arrival stamp, not misread mid-window"
    else
      fail "W19b (mkdir->mv window): restored started=$w19e_started_restored, original was $w19e_started_orig -- misread the mkdir->mv window"
    fi
  elif [ -d "$lockw19e.q/$w19e_pid" ]; then
    fail "W19a (mkdir->mv window): directory restored, owner never branded within 5s -- restore-wait misread the mkdir->mv window"
  else
    fail "W19a (mkdir->mv window): the ticket was never restored within 5s"
  fi

  wait "$w19e_pid" 2>/dev/null
  kill "$w19e_helper_pid" 2>/dev/null
  wait "$w19e_helper_pid" 2>/dev/null
fi

# --------------------------------------------------------------------------
# Case W20 (HIMMEL-2623 round 7, CR finding codex-1; strengthened round 9,
# codex-2): a ticket whose owner keeps REFRESHING its heartbeat (`seen`)
# survives real pruning attempts well past a tiny SUITE_QUEUE_TTL, no matter
# how long the total wait. The waiter is a REAL runner process, kept blocked
# (and therefore still actively polling every SUITE_LOCK_WAIT_INTERVAL) by a
# lock this case holds and controls directly.
#
# STRENGTHENED, round 9: the original version of this case launched no peer
# to actually judge the ticket -- suite_lock_queue_prune always skips the
# CALLER's own ticket, so nothing here ever evaluated it for staleness, and
# the case passed for the wrong reason (codex-2). It now fires real,
# cheap no-wait probes against the SAME lock during the wait window; each one
# runs suite_lock_queue_prune as a side effect (via suite_lock_queue_live_count,
# HIMMEL-2623 round 4's no-wait yield check) before refusing, so the
# refreshing ticket is genuinely re-judged on every probe, not merely left
# alone.
#
# SCOPE, checked honestly rather than asserted: this is a regression guard on
# the HEARTBEAT-REFRESH MECHANISM ITSELF (a future bug that silently breaks
# `_suite_lock_queue_brand`'s refresh, or reverts staleness to judging
# `started` again, would still be caught here) -- it is NOT, and cannot be, a
# round-4-vs-round-5 discriminator. Checked directly against the pre-round-5
# commit (0fd3f8f8): round 4's "confirmed-alive pid exempts from TTL
# unconditionally" rule ALSO protects a real, continuously-alive,
# same-host process regardless of whether anything ever refreshes it, so this
# exact scenario passes under BOTH implementations -- round 4 was never wrong
# about protecting a genuinely healthy waiter; it was wrong about the
# CONVERSE (failing to reclaim a stopped-but-resident one), which is Case
# W21's job below, and which DOES fail against that same pre-round-5 commit
# (verified: rc 5, ticket survives -- the wedge -- instead of rc 0, pruned).
# --------------------------------------------------------------------------
echo "== Case W20: a ticket that keeps refreshing survives real pruning attempts =="
sbw20=$(new_sandbox)
cat > "$sbw20/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/ran"
exit 0
SHEOF
lockw20="$sbw20/suite.lock"
mkdir -p "$lockw20"
printf 'pid=%s\nhost=%s\nstarted=%s\nscan=other\n' \
  "$$" "$(this_host)" "$(date +%s)" > "$lockw20/owner"

SUITE_LOCK_DIR="$lockw20" SUITE_QUEUE_TTL=2 SUITE_LOCK_WAIT_INTERVAL=1 SUITE_LOCK_WAIT=8 \
  bash "$RUNNER" "$sbw20" >"$sbw20/waiter.log" 2>&1 &
w20_pid=$!

_spin=0
while [ ! -d "$lockw20.q/$w20_pid" ] && [ "$_spin" -lt 50 ]; do
  sleep 0.1
  _spin=$((_spin + 1))
done
if [ ! -d "$lockw20.q/$w20_pid" ]; then
  fail "W20 setup -- the waiter never took its own ticket within 5s; cannot run the case"
  kill "$w20_pid" 2>/dev/null
  wait "$w20_pid" 2>/dev/null
  rm -rf "$lockw20"
else
  # A PEER -- cheap no-wait probes against the same lock -- actually attempts
  # a prune of the refreshing ticket several times, well past SUITE_QUEUE_TTL=2s,
  # while the waiter keeps polling/refreshing every 1s (it is still blocked --
  # we still hold the lock, so each probe's own acquire attempt refuses too,
  # but suite_lock_queue_live_count has already pruned by then regardless).
  sbw20probe=$(new_sandbox)
  cat > "$sbw20probe/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
  _i=0
  while [ "$_i" -lt 5 ]; do
    sleep 0.9
    SUITE_LOCK_DIR="$lockw20" SUITE_QUEUE_TTL=2 SUITE_LOCK_WAIT_INTERVAL=1 \
      bash "$RUNNER" "$sbw20probe" >/dev/null 2>&1
    _i=$((_i + 1))
  done

  if [ -d "$lockw20.q/$w20_pid" ]; then
    pass "W20a: the actively-refreshed ticket survived repeated real prune attempts past a 2s TTL"
  else
    fail "W20a: the ticket was pruned despite continuous refreshing and real peer prune attempts -- the heartbeat mechanism is broken"
  fi

  rm -rf "$lockw20"
  wait "$w20_pid"
  rcw20=$?

  if [ "$rcw20" -eq 0 ]; then
    pass "W20b: the waiter went on to acquire normally (rc 0)"
  else
    fail "W20b: expected rc 0 got $rcw20; waiter log: $(cat "$sbw20/waiter.log" 2>/dev/null)"
  fi
  if [ -e "$sbw20/ran" ]; then
    pass "W20c: the suite ran"
  else
    fail "W20c: the suite never ran"
  fi
fi

# --------------------------------------------------------------------------
# Case W21 (HIMMEL-2623 round 7, CR finding codex-1): a ticket whose owner
# is CONFIRMED ALIVE but has STOPPED refreshing (stopped, wedged, hung) is
# reclaimed past a tiny SUITE_QUEUE_TTL -- restoring the wedge backstop
# round 4's alive-exempts-forever rule cost. Deterministic: a live helper
# pid the case owns, with `seen` planted stale, never a real hang.
# --------------------------------------------------------------------------
echo "== Case W21: a confirmed-alive but non-refreshing ticket IS pruned past TTL =="
sbw21=$(new_sandbox)
cat > "$sbw21/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/ran"
exit 0
SHEOF
lockw21="$sbw21/suite.lock"

sleep 60 &
w21_helper_pid=$!
mkdir -p "$lockw21.q/$w21_helper_pid"
printf 'pid=%s\nhost=%s\nstarted=%s\nseen=%s\n' "$w21_helper_pid" "$(this_host)" \
  "$(( $(date +%s) - 10 ))" "$(( $(date +%s) - 5 ))" \
  > "$lockw21.q/$w21_helper_pid/owner"

outw21=$(SUITE_LOCK_DIR="$lockw21" SUITE_QUEUE_TTL=2 SUITE_LOCK_WAIT=3 SUITE_LOCK_WAIT_INTERVAL=1 \
  bash "$RUNNER" "$sbw21" 2>&1)
rcw21=$?

if [ "$rcw21" -eq 0 ]; then
  pass "W21a: the stale-heartbeat ticket was pruned -> the new waiter acquired (rc 0)"
else
  fail "W21a: expected rc 0 got $rcw21 -- a confirmed-alive-but-wedged ticket must not wedge the queue forever; output: $outw21"
fi
if [ -d "$lockw21.q/$w21_helper_pid" ]; then
  fail "W21b: the stale ticket is still present -- it was not reclaimed"
else
  pass "W21b: the stale ticket is gone"
fi
if [ -e "$sbw21/ran" ]; then
  pass "W21c: the suite ran"
else
  fail "W21c: the suite never ran; output: $outw21"
fi

kill "$w21_helper_pid" 2>/dev/null
wait "$w21_helper_pid" 2>/dev/null

# --------------------------------------------------------------------------
# Case W22 (HIMMEL-2623 round 7, codex-1's sanity check): SUITE_QUEUE_STALE_AFTER
# clamps the effective staleness window to comfortably more than one
# SUITE_LOCK_WAIT_INTERVAL, so a waiter configured with an interval LONGER
# than SUITE_QUEUE_TTL cannot have its own heartbeat judged stale between
# its own polls. Deterministic: a planted ticket whose `seen` is already
# past the RAW TTL but well within the CLAMPED window.
# --------------------------------------------------------------------------
echo "== Case W22: the staleness window is clamped against a long wait interval =="
sbw22=$(new_sandbox)
cat > "$sbw22/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/ran"
exit 0
SHEOF
lockw22="$sbw22/suite.lock"

# seen is 3s stale. Raw TTL=1 would prune it (3 >= 1). Interval=5 means the
# clamp widens the effective window to max(1, 5*3=15)=15s, so it must survive.
sleep 60 &
w22_helper_pid=$!
mkdir -p "$lockw22.q/$w22_helper_pid"
printf 'pid=%s\nhost=%s\nstarted=%s\nseen=%s\n' "$w22_helper_pid" "$(this_host)" \
  "$(( $(date +%s) - 10 ))" "$(( $(date +%s) - 3 ))" \
  > "$lockw22.q/$w22_helper_pid/owner"

outw22=$(SUITE_LOCK_DIR="$lockw22" SUITE_QUEUE_TTL=1 SUITE_LOCK_WAIT_INTERVAL=5 SUITE_LOCK_WAIT=6 \
  bash "$RUNNER" "$sbw22" 2>&1)
rcw22=$?

if [ "$rcw22" -eq 5 ]; then
  pass "W22a: still blocked behind the ticket -> the clamp protected it from the raw (shorter) TTL"
else
  fail "W22a: expected rc 5 got $rcw22 -- the clamp did not protect a ticket younger than the effective window; output: $outw22"
fi
if [ -d "$lockw22.q/$w22_helper_pid" ]; then
  pass "W22b: the ticket survived the raw-TTL-but-clamp-safe window"
else
  fail "W22b: the ticket was pruned despite the clamp -- SUITE_QUEUE_STALE_AFTER is not being honoured"
fi
if [ -e "$sbw22/ran" ]; then
  fail "W22c: the suite RAN -- the clamp failed and the ticket was wrongly pruned"
else
  pass "W22c: the suite never ran"
fi

kill "$w22_helper_pid" 2>/dev/null
wait "$w22_helper_pid" 2>/dev/null

# --------------------------------------------------------------------------
# Case W23 (HIMMEL-2623 round 8, CR finding codex-1): the expiry window
# belongs to the TICKET, not to whoever is reading it. A ticket branded with
# a LONG `stale_after` must not be pruned by a reader whose OWN window
# (computed from its own short SUITE_QUEUE_TTL/SUITE_LOCK_WAIT_INTERVAL)
# would otherwise be far shorter -- round 7's clamp protected a process only
# from ITSELF; this protects a slow-polling owner's ticket from a
# fast-polling reader that would otherwise judge it by the wrong yardstick.
# --------------------------------------------------------------------------
echo "== Case W23: a ticket's own LONG stale_after protects it from a short-window reader =="
sbw23=$(new_sandbox)
cat > "$sbw23/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/ran"
exit 0
SHEOF
lockw23="$sbw23/suite.lock"

# Declares stale_after=20; seen is 10s stale -- well within ITS OWN window,
# but the READER below (SUITE_QUEUE_TTL=1, SUITE_LOCK_WAIT_INTERVAL=1) would
# compute its own SUITE_QUEUE_STALE_AFTER as only 3s for itself.
sleep 60 &
w23_helper_pid=$!
mkdir -p "$lockw23.q/$w23_helper_pid"
printf 'pid=%s\nhost=%s\nstarted=%s\nstale_after=20\nseen=%s\n' "$w23_helper_pid" "$(this_host)" \
  "$(( $(date +%s) - 30 ))" "$(( $(date +%s) - 10 ))" \
  > "$lockw23.q/$w23_helper_pid/owner"

outw23=$(SUITE_LOCK_DIR="$lockw23" SUITE_QUEUE_TTL=1 SUITE_LOCK_WAIT_INTERVAL=1 \
  bash "$RUNNER" "$sbw23" 2>&1)
rcw23=$?

if [ "$rcw23" -eq 2 ]; then
  pass "W23a: the reader yields to the ticket -> rc 2 (its OWN 20s window protected it)"
else
  fail "W23a: expected rc 2 got $rcw23 -- a reader's short window pruned an owner's healthy ticket; output: $outw23"
fi
if [ -d "$lockw23.q/$w23_helper_pid" ]; then
  pass "W23b: the ticket survived, judged by its OWN recorded window"
else
  fail "W23b: the ticket was pruned -- the reader used its own window instead of the ticket's"
fi
if [ -e "$sbw23/ran" ]; then
  fail "W23c: the suite RAN -- the ticket was wrongly pruned"
else
  pass "W23c: the suite never ran"
fi

kill "$w23_helper_pid" 2>/dev/null
wait "$w23_helper_pid" 2>/dev/null

# --------------------------------------------------------------------------
# Case W24 -- CONTROL for W23: the ticket's own recorded window is not a
# license for immortality. The SAME declared `stale_after` (20), but `seen`
# genuinely older than that OWN window, must still be pruned -- proving the
# field is honoured as a real threshold, not read once and ignored.
# --------------------------------------------------------------------------
echo "== Case W24: control -- a ticket's own window, once genuinely elapsed, is still pruned =="
sbw24=$(new_sandbox)
cat > "$sbw24/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/ran"
exit 0
SHEOF
lockw24="$sbw24/suite.lock"

# Same stale_after=20, but seen is 25s stale -- past its OWN window this time.
sleep 60 &
w24_helper_pid=$!
mkdir -p "$lockw24.q/$w24_helper_pid"
printf 'pid=%s\nhost=%s\nstarted=%s\nstale_after=20\nseen=%s\n' "$w24_helper_pid" "$(this_host)" \
  "$(( $(date +%s) - 30 ))" "$(( $(date +%s) - 25 ))" \
  > "$lockw24.q/$w24_helper_pid/owner"

outw24=$(SUITE_LOCK_DIR="$lockw24" SUITE_QUEUE_TTL=1 SUITE_LOCK_WAIT_INTERVAL=1 \
  bash "$RUNNER" "$sbw24" 2>&1)
rcw24=$?

if [ "$rcw24" -eq 0 ]; then
  pass "W24a: the ticket's own window genuinely elapsed -> pruned, reader acquired (rc 0)"
else
  fail "W24a: expected rc 0 got $rcw24 -- stale_after must not make a ticket immortal; output: $outw24"
fi
if [ -d "$lockw24.q/$w24_helper_pid" ]; then
  fail "W24b: the ticket is still present -- its own recorded window was not honoured as a real threshold"
else
  pass "W24b: the ticket is gone"
fi
if [ -e "$sbw24/ran" ]; then
  pass "W24c: the suite ran"
else
  fail "W24c: the suite never ran; output: $outw24"
fi

kill "$w24_helper_pid" 2>/dev/null
wait "$w24_helper_pid" 2>/dev/null

# --------------------------------------------------------------------------
# Case W25 (HIMMEL-2623 round 9, CR finding codex-1): the round-8 cap must be
# an ABSOLUTE, reader-independent ceiling, not a multiple of the READER's own
# SUITE_QUEUE_STALE_AFTER. A reader configured with a tiny TTL/interval has a
# tiny window of its own (here: 3s); under the round-8 cap (100x that = 300),
# a DEFAULT-configuration ticket's real stale_after=14400 exceeds the cap,
# falls back to the reader's tiny 3s window, and gets wrongly pruned between
# its normal polls -- a healthy waiter jumped by the very guard meant to
# protect it. This is the regression this finding names; it fails against
# the pre-round-9 code (confirmed: see the RED control in this round's
# report) and must pass against the fixed absolute ceiling.
# --------------------------------------------------------------------------
echo "== Case W25: a reader with a tiny window still honours a default-sized stale_after =="
sbw25=$(new_sandbox)
cat > "$sbw25/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/ran"
exit 0
SHEOF
lockw25="$sbw25/suite.lock"

# A ticket branded exactly as the DEFAULT config would (stale_after=14400),
# `seen` only 50s stale -- trivially healthy by any sane standard.
sleep 60 &
w25_helper_pid=$!
mkdir -p "$lockw25.q/$w25_helper_pid"
printf 'pid=%s\nhost=%s\nstarted=%s\nstale_after=14400\nseen=%s\n' "$w25_helper_pid" "$(this_host)" \
  "$(( $(date +%s) - 100 ))" "$(( $(date +%s) - 50 ))" \
  > "$lockw25.q/$w25_helper_pid/owner"

# A reader with a tiny TTL/interval -> its OWN SUITE_QUEUE_STALE_AFTER=3.
outw25=$(SUITE_LOCK_DIR="$lockw25" SUITE_QUEUE_TTL=1 SUITE_LOCK_WAIT_INTERVAL=1 \
  bash "$RUNNER" "$sbw25" 2>&1)
rcw25=$?

if [ "$rcw25" -eq 2 ]; then
  pass "W25a: the tiny-window reader still honours the default-sized declared window -> rc 2"
else
  fail "W25a: expected rc 2 got $rcw25 -- a reader-relative cap wrongly pruned a healthy default-config ticket; output: $outw25"
fi
if [ -d "$lockw25.q/$w25_helper_pid" ]; then
  pass "W25b: the ticket survived, judged by its own 14400s window, not the reader's 3s one"
else
  fail "W25b: the ticket was pruned -- the cap rejected a legitimate default-sized window"
fi
if [ -e "$sbw25/ran" ]; then
  fail "W25c: the suite RAN -- the healthy ticket was wrongly pruned and jumped"
else
  pass "W25c: the suite never ran"
fi

kill "$w25_helper_pid" 2>/dev/null
wait "$w25_helper_pid" 2>/dev/null

# --------------------------------------------------------------------------
# Leak guard -- this suite must not leave processes behind. Anything the
# harness failed to reap was already reported as a FAIL above; naming it here
# too makes the leak visible to whoever reads the log.
# --------------------------------------------------------------------------
if [ -n "${LEAKED_PIDS:-}" ]; then
  printf '  NOTE  leaked pids from failed reaping:%s\n' "$LEAKED_PIDS"
fi

# --------------------------------------------------------------------------
# Final tally
# --------------------------------------------------------------------------
echo
if [ "$failures" -eq 0 ]; then
  echo "OK: all cases passed"
  exit 0
else
  echo "FAIL: $failures case(s) failed"
  exit 1
fi
