#!/usr/bin/env bash
# scripts/upstreams/test-upstream-watch-cadence.sh — hermetic suite for the
# daily upstream-watch scheduler cadence (HIMMEL-2367).
#
# Never touches the real scheduler or observability registry: schtasks is
# replaced by a fake via UPSTREAMWATCH_SCHTASKS, the runner dir by
# UPSTREAMWATCH_BAT_DIR, the himmel root by UPSTREAMWATCH_HIMMEL_ROOT pointing
# at a stub tree, and — critically — HIMMEL_OBSERVABILITY_CONFIG is pinned to
# a per-test scratch file on EVERY invocation below. Omitting that seam is
# exactly the HIMMEL-2367 leak this ticket caught live: a hand smoke-test that
# forgot it registered a real task into ~/.himmel/observability.json and paged
# on the resulting scheduled-task-missing alert.
#
# The Windows/schtasks half (win_arm/win_disarm, exercised via run_cadence)
# needs a real `cygpath` to convert paths for schtasks — schtasks itself is
# faked via UPSTREAMWATCH_SCHTASKS, but cygpath is NOT, so on a non-Windows
# host cmd_arm dies with "cygpath not on PATH; cannot convert paths for
# schtasks" (HIMMEL-2508). That half is gated below the same way
# scripts/luna/test-qmd-cadence.sh and scripts/graphify/test-ggs-cadence.sh
# gate their own Windows-only schtasks suites, loudly skipping on Linux/macOS
# rather than failing on a dependency this suite cannot fake.
#
# bash 3.2-safe: no mapfile, no associative arrays.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CADENCE="$SCRIPT_DIR/upstream-watch-cadence.sh"

fails=0
pass() { echo "  ok   — $1"; }
fail() { echo "  FAIL — $1"; fails=$((fails + 1)); }

assert_rc() {
  local want="$1" label="$2"; shift 2
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want" ]; then pass "$label (rc=$rc)"
  else fail "$label — expected rc=$want got rc=$rc; output: $out"; fi
}

assert_has() {
  local hay="$1" needle="$2" label="$3"
  case "$hay" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label — '$needle' not found in output" ;;
  esac
}

# Stub himmel root carrying exactly the payload file require_payload checks for.
make_root() {
  local root
  root=$(mktemp -d "${TMPDIR:-/tmp}/upstream-watch-cadence-test-root.XXXXXX")
  mkdir -p "$root/scripts/upstreams"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/scripts/upstreams/upstream-watch.sh"
  chmod +x "$root/scripts/upstreams/upstream-watch.sh"
  printf '%s' "$root"
}

# Fake schtasks — same shape as test-drift-fix-cadence.sh's, single task name.
make_fake_schtasks() {
  local state="$1" f="$1/schtasks"
  cat > "$f" <<'FAKE'
#!/usr/bin/env bash
state="$(dirname "$0")"
echo "$*" >> "$state/calls"
tn=""
prev=""
for a in "$@"; do
  if [ "$prev" = "/tn" ]; then tn="$a"; fi
  prev="$a"
done
armed_file="$state/armed_${tn:-_none_}"
case "$1" in
  /query)
    if [ -f "$state/query_fail" ]; then
      echo "some unrecognized localized failure" >&2; exit 1
    fi
    if [ -f "$armed_file" ]; then
      echo "TaskName: \\$tn"
      if [ ! -f "$state/no_next_run_$tn" ]; then
        echo "Next Run Time: 1/1/2027 6:00:00 AM"
      fi
      echo "Status: Ready"
      exit 0
    fi
    echo "ERROR: The system cannot find the file specified." >&2; exit 1 ;;
  /create) touch "$armed_file"; echo "SUCCESS: created"; exit 0 ;;
  /delete) rm -f "$armed_file"; echo "SUCCESS: deleted"; exit 0 ;;
esac
exit 0
FAKE
  chmod +x "$f"
  printf '%s' "$f"
}

# Fake crontab — same shape as test-drift-fix-cadence.sh's: `-l` prints the
# stored tab (rc 1 + "no crontab" when absent, the trusted-empty signature);
# `-` installs from stdin. $state/install_fail fails ONLY the install path,
# leaving `-l` working, so cron_arm's publish-then-install ordering (round-3
# fix, HIMMEL-2367 codex-2) can be exercised without also tripping the
# fail-closed cron_read guard.
make_fake_crontab() {
  local state="$1" f="$1/crontab"
  cat > "$f" <<'FAKE'
#!/usr/bin/env bash
state="$(dirname "$0")"
echo "$*" >> "$state/calls"
case "${1:-}" in
  -l)
    if [ -f "$state/tab" ]; then cat "$state/tab"; exit 0; fi
    echo "no crontab for tester" >&2; exit 1 ;;
  -)
    if [ -f "$state/install_fail" ]; then
      echo "crontab: simulated install failure" >&2; exit 9
    fi
    cat > "$state/tab"; exit 0 ;;
esac
exit 0
FAKE
  chmod +x "$f"
  printf '%s' "$f"
}

new_scratch() {
  local state
  state=$(mktemp -d "${TMPDIR:-/tmp}/upstream-watch-cadence-test.XXXXXX")
  make_fake_schtasks "$state" >/dev/null
  printf '%s' "$state"
}

new_scratch_posix() {
  local state
  state=$(mktemp -d "${TMPDIR:-/tmp}/upstream-watch-cadence-test-posix.XXXXXX")
  make_fake_crontab "$state" >/dev/null
  printf '%s' "$state"
}

# run_cadence <state> <args...> — every call pins HIMMEL_OBSERVABILITY_CONFIG
# to the scratch state dir; nothing here may ever reach the real registry.
run_cadence() {
  local state="$1"; shift
  UPSTREAMWATCH_SCHTASKS="$state/schtasks" \
    UPSTREAMWATCH_BAT_DIR="$state/bat" \
    UPSTREAMWATCH_HIMMEL_ROOT="$state/root" \
    UPSTREAMWATCH_PLATFORM=windows \
    HIMMEL_OBSERVABILITY_CONFIG="$state/observability.json" \
    bash "$CADENCE" "$@"
}

# run_cadence_posix — same contract as run_cadence but the POSIX/crontab arm
# path (UPSTREAMWATCH_CRONTAB), never touching a real cygpath/wscript
# dependency the Windows path needs.
run_cadence_posix() {
  local state="$1"; shift
  UPSTREAMWATCH_CRONTAB="$state/crontab" \
    UPSTREAMWATCH_BAT_DIR="$state/bat" \
    UPSTREAMWATCH_HIMMEL_ROOT="$state/root" \
    UPSTREAMWATCH_PLATFORM=posix \
    HIMMEL_OBSERVABILITY_CONFIG="$state/observability.json" \
    bash "$CADENCE" "$@"
}

registry_has_task() {
  local reg="$1"
  [ -f "$reg" ] && jq -e '.expected_tasks // [] | index("HIMMEL-UpstreamWatch")' "$reg" >/dev/null 2>&1
}

# --- Windows (schtasks) suite — gated: cmd_arm's XML path shells out to a
# real cygpath, which is faked nowhere in this suite (unlike schtasks itself,
# via UPSTREAMWATCH_SCHTASKS). Same platform predicate + SKIP voice as
# scripts/luna/test-qmd-cadence.sh and scripts/graphify/test-ggs-cadence.sh.
case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    msys*|cygwin*|win32*|MINGW*) RUN_WINDOWS_SUITE=1 ;;
    *)
        RUN_WINDOWS_SUITE=0
        echo "SKIP: Windows/schtasks suite (Windows-only — needs a real cygpath, not faked here)"
        ;;
esac

if [ "$RUN_WINDOWS_SUITE" = "1" ]; then
echo "== test: arm =="
state=$(new_scratch); root=$(make_root); mv "$root" "$state/root"
out=$(run_cadence "$state" arm 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "arm: rc=0"; else fail "arm: expected rc=0 got rc=$rc; output: $out"; fi
assert_has "$out" "ARMED" "arm: reports ARMED"
if registry_has_task "$state/observability.json"; then
  pass "arm: registered in scratch registry"
else
  fail "arm: HIMMEL-UpstreamWatch missing from scratch registry"
fi

echo "== test: status (armed) =="
out=$(run_cadence "$state" status 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "status: rc=0"; else fail "status: expected rc=0 got rc=$rc"; fi
assert_has "$out" "ARMED" "status: reports ARMED"

echo "== test: arm again — dedup =="
assert_rc 3 "dedup: re-arm without --force" run_cadence "$state" arm

echo "== test: arm --force replaces =="
out=$(run_cadence "$state" arm --time 07:15 --force 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "force re-arm: rc=0"; else fail "force re-arm: expected rc=0 got rc=$rc; output: $out"; fi
assert_has "$out" "--force set" "force re-arm: acknowledges force"

echo "== test: disarm removes task AND registry entry =="
out=$(run_cadence "$state" disarm 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "disarm: rc=0"; else fail "disarm: expected rc=0 got rc=$rc; output: $out"; fi
assert_has "$out" "cadence disarmed" "disarm: confirms disarmed"
if registry_has_task "$state/observability.json"; then
  fail "disarm: HIMMEL-UpstreamWatch still in registry"
else
  pass "disarm: registry entry removed"
fi

echo "== test: status (not armed) =="
out=$(run_cadence "$state" status 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "status after disarm: rc=0"; else fail "status after disarm: expected rc=0 got rc=$rc"; fi
assert_has "$out" "not armed" "status after disarm: reports not armed"

echo "== test: disarm no-op still cleans a stale registry entry =="
# Simulate the HIMMEL-2367 leak shape directly: a registry entry exists with
# no matching live task (e.g. the task was deleted outside this script).
state2=$(new_scratch); root2=$(make_root); mv "$root2" "$state2/root"
jq -n '{flows:[{name:"upstream-watch",cadence_seconds:86400}], expected_tasks:["HIMMEL-UpstreamWatch"]}' \
  > "$state2/observability.json"
if ! registry_has_task "$state2/observability.json"; then
  fail "setup: seeded registry should carry the stale entry"
fi
out=$(run_cadence "$state2" disarm 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "no-op disarm: rc=0"; else fail "no-op disarm: expected rc=0 got rc=$rc; output: $out"; fi
assert_has "$out" "disarm is a no-op" "no-op disarm: reports no-op"
if registry_has_task "$state2/observability.json"; then
  fail "no-op disarm: stale registry entry should be gone"
else
  pass "no-op disarm: stale registry entry cleaned"
fi

echo "== test: dry-run arm makes no changes (task or registry) =="
state3=$(new_scratch); root3=$(make_root); mv "$root3" "$state3/root"
out=$(run_cadence "$state3" arm --dry-run 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "dry-run arm: rc=0"; else fail "dry-run arm: expected rc=0 got rc=$rc"; fi
assert_has "$out" "dry-run complete" "dry-run arm: reports dry-run complete"
if [ -f "$state3/armed_HIMMEL-UpstreamWatch" ]; then
  fail "dry-run arm: task should not be created"
else
  pass "dry-run arm: no task created"
fi
if registry_has_task "$state3/observability.json"; then
  fail "dry-run arm: registry should be untouched"
else
  pass "dry-run arm: registry untouched"
fi

fi

# --time is validated BEFORE the platform gate in upstream-watch-cadence.sh
# (see its own comment: "Validate input BEFORE the platform gate so a bad
# value is rc 1 everywhere, not rc 2 on whichever platform happens to gate
# first") — confirmed empirically on this Linux box: run_cadence's
# UPSTREAMWATCH_PLATFORM=windows never reaches cygpath/schtasks for this
# input. So this assertion is a cross-platform contract of the production
# script, not part of the Windows/schtasks suite, and must run on every host.
#
# Asserted on the MESSAGE, not just rc=1 (CR [codex-1]): rc alone is vacuous
# here, because a failed setup (new_scratch/make_root/mv) would ALSO exit 1 —
# on a different error entirely — and read as a pass. --time is validated
# before the payload check, so the rc cannot distinguish the two; the
# diagnostic can.
echo "== test: bad --time rejected =="
state=$(new_scratch); root=$(make_root); mv "$root" "$state/root"
out=$(run_cadence "$state" arm --time nonsense 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "bad --time (rc=1)"; else fail "bad --time — expected rc=1 got rc=$rc; output: $out"; fi
assert_has "$out" "--time must be HH:MM" "bad --time: rejected for the right reason"

# --- POSIX (crontab) path — HIMMEL-2367 codex-3, round 4: the suite above
# only ever exercised win_arm/win_disarm via UPSTREAMWATCH_PLATFORM=windows;
# cron_arm/cron_disarm (including the round-3 codex-2 publish-before-install
# ordering fix) had zero coverage. No cygpath/wscript dependency here — the
# fake crontab is the only external tool cron_arm/cron_disarm touch.
echo "== test: POSIX arm =="
pstate=$(new_scratch_posix); proot=$(make_root); mv "$proot" "$pstate/root"
out=$(run_cadence_posix "$pstate" arm 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "posix arm: rc=0"; else fail "posix arm: expected rc=0 got rc=$rc; output: $out"; fi
assert_has "$out" "ARMED" "posix arm: reports ARMED"
if [ -f "$pstate/bat/upstream-watch.sh" ]; then
  pass "posix arm: runner published"
else
  fail "posix arm: runner not published at $pstate/bat/upstream-watch.sh"
fi
if [ -f "$pstate/tab" ] && grep -q "HIMMEL-UpstreamWatch" "$pstate/tab"; then
  pass "posix arm: cron entry installed"
else
  fail "posix arm: cron entry missing from fake tab"
fi
if registry_has_task "$pstate/observability.json"; then
  pass "posix arm: registered in scratch registry"
else
  fail "posix arm: HIMMEL-UpstreamWatch missing from scratch registry"
fi

echo "== test: POSIX status (armed) + dedup =="
out=$(run_cadence_posix "$pstate" status 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "posix status: rc=0"; else fail "posix status: expected rc=0 got rc=$rc"; fi
assert_has "$out" "ARMED" "posix status: reports ARMED"
assert_rc 3 "posix dedup: re-arm without --force" run_cadence_posix "$pstate" arm

echo "== test: POSIX arm publish-before-install ordering (round-3 fix) =="
# install_fail makes ONLY the crontab install step fail; the runner must
# already be published by the time that happens (publish-first ordering),
# and the fire time change proves this later arm attempt actually ran.
pstate2=$(new_scratch_posix); proot2=$(make_root); mv "$proot2" "$pstate2/root"
touch "$pstate2/install_fail"
out=$(run_cadence_posix "$pstate2" arm 2>&1); rc=$?
if [ "$rc" -eq 4 ]; then pass "posix install-fail: rc=4"; else fail "posix install-fail: expected rc=4 got rc=$rc; output: $out"; fi
assert_has "$out" "crontab install failed" "posix install-fail: reports install failure"
if [ -f "$pstate2/bat/upstream-watch.sh" ]; then
  pass "posix install-fail: runner still published despite failed install"
else
  fail "posix install-fail: runner missing — publish must happen BEFORE install"
fi
if [ -f "$pstate2/tab" ]; then
  fail "posix install-fail: no cron entry should have been installed"
else
  pass "posix install-fail: no cron entry installed"
fi

echo "== test: POSIX disarm removes cron entry AND registry entry =="
out=$(run_cadence_posix "$pstate" disarm 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "posix disarm: rc=0"; else fail "posix disarm: expected rc=0 got rc=$rc; output: $out"; fi
assert_has "$out" "cadence disarmed" "posix disarm: confirms disarmed"
if [ -f "$pstate/tab" ] && grep -q "HIMMEL-UpstreamWatch" "$pstate/tab"; then
  fail "posix disarm: cron entry still present"
else
  pass "posix disarm: cron entry removed"
fi
if registry_has_task "$pstate/observability.json"; then
  fail "posix disarm: HIMMEL-UpstreamWatch still in registry"
else
  pass "posix disarm: registry entry removed"
fi

echo "== test: POSIX dry-run arm makes no changes =="
pstate3=$(new_scratch_posix); proot3=$(make_root); mv "$proot3" "$pstate3/root"
out=$(run_cadence_posix "$pstate3" arm --dry-run 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "posix dry-run arm: rc=0"; else fail "posix dry-run arm: expected rc=0 got rc=$rc"; fi
assert_has "$out" "dry-run complete" "posix dry-run arm: reports dry-run complete"
if [ -f "$pstate3/bat/upstream-watch.sh" ]; then
  fail "posix dry-run arm: runner should not be published"
else
  pass "posix dry-run arm: no runner published"
fi
if [ -f "$pstate3/tab" ]; then
  fail "posix dry-run arm: cron entry should not be installed"
else
  pass "posix dry-run arm: no cron entry installed"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "SUMMARY: all tests passed"
  exit 0
else
  echo "SUMMARY: $fails test(s) FAILED"
  exit 1
fi
