#!/usr/bin/env bash
# scripts/luna-vitals/connectors/test-pull-cadence-arm.sh — hermetic suite for
# the daily Google Health connector pull cadence's arm/status/disarm
# subcommands (HIMMEL-3068). Distinct from pull-cadence.test.ts, which covers
# the connector-pull path itself (bun/Bun.spawn, no args) — this covers ONLY
# the scheduler management this ticket adds.
#
# Platform guard: this file itself runs fine under Git Bash on Windows or any
# POSIX bash 3.2+ (plain bash, no .ps1 twin needed — same posture as its
# sibling suites). Its Windows/schtasks ASSERTIONS self-skip everywhere,
# including under real Git Bash, because the schtasks half needs a real
# cygpath to convert paths, which is faked nowhere in this suite (schtasks
# itself would be faked via PULLCADENCE_SCHTASKS, but cygpath is not) — same
# SKIP posture as scripts/upstreams/test-upstream-watch-cadence.sh's own
# Windows half.
#
# HIMMEL_OBSERVABILITY_CONFIG is pinned to a per-test scratch file on EVERY
# invocation — never omit it, or a hand run registers a real task into
# ~/.himmel/observability.json (the exact HIMMEL-2367 leak this pattern
# exists to avoid).
#
# bash 3.2-safe: no mapfile, no associative arrays.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CADENCE="$SCRIPT_DIR/pull-cadence.sh"

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

# Stub himmel root carrying exactly the payload file require_payload checks
# for on POSIX (the .sh path, invoked with no args by the armed cadence).
make_root() {
  local root
  root=$(mktemp -d "${TMPDIR:-/tmp}/pull-cadence-test-root.XXXXXX")
  mkdir -p "$root/scripts/luna-vitals/connectors"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/scripts/luna-vitals/connectors/pull-cadence.sh"
  chmod +x "$root/scripts/luna-vitals/connectors/pull-cadence.sh"
  printf '%s' "$root"
}

# Fake crontab — same shape as test-upstream-watch-cadence.sh's.
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
    cat > "$state/tab"; exit 0 ;;
esac
exit 0
FAKE
  chmod +x "$f"
  printf '%s' "$f"
}

new_scratch_posix() {
  local state
  state=$(mktemp -d "${TMPDIR:-/tmp}/pull-cadence-test-posix.XXXXXX")
  make_fake_crontab "$state" >/dev/null
  printf '%s' "$state"
}

# run_cadence <state> <args...> — pins PULLCADENCE_* + HIMMEL_OBSERVABILITY_CONFIG
# so nothing ever reaches a real crontab or the real observability registry.
run_cadence() {
  local state="$1"; shift
  PULLCADENCE_CRONTAB="$state/crontab" \
    PULLCADENCE_BAT_DIR="$state/bat" \
    PULLCADENCE_HIMMEL_ROOT="$state/root" \
    PULLCADENCE_PLATFORM=posix \
    HIMMEL_OBSERVABILITY_CONFIG="$state/observability.json" \
    bash "$CADENCE" "$@"
}

registry_has_task() {
  local reg="$1"
  [ -f "$reg" ] && jq -e '.expected_tasks // [] | index("HIMMEL-LunaVitalsPull")' "$reg" >/dev/null 2>&1
}

echo "SKIP: Windows/schtasks suite (Windows-only — needs a real cygpath, not faked here)"

echo "== test: dry-run arm makes no changes =="
state=$(new_scratch_posix); root=$(make_root); mv "$root" "$state/root"
out=$(run_cadence "$state" arm --dry-run --time 07:15 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "dry-run arm: rc=0"; else fail "dry-run arm: expected rc=0 got rc=$rc; output: $out"; fi
assert_has "$out" "dry-run complete" "dry-run arm: reports dry-run complete"
if [ -f "$state/bat/pull-cadence.sh" ]; then
  fail "dry-run arm: runner should not be published"
else
  pass "dry-run arm: no runner published"
fi
if registry_has_task "$state/observability.json"; then
  fail "dry-run arm: registry should be untouched"
else
  pass "dry-run arm: registry untouched"
fi

echo "== test: arm =="
out=$(run_cadence "$state" arm --time 07:15 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "arm: rc=0"; else fail "arm: expected rc=0 got rc=$rc; output: $out"; fi
assert_has "$out" "ARMED" "arm: reports ARMED"
if [ -x "$state/bat/pull-cadence.sh" ]; then pass "arm: runner published + executable"; else fail "arm: runner not published/executable"; fi
if grep -qF 'HIMMEL-LunaVitalsPull' "$state/tab" 2>/dev/null; then pass "arm: cron entry installed"; else fail "arm: no cron entry installed"; fi
if registry_has_task "$state/observability.json"; then pass "arm: registered in scratch registry"; else fail "arm: not registered in scratch registry"; fi

echo "== test: status (armed) =="
out=$(run_cadence "$state" status 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "status: rc=0"; else fail "status: expected rc=0 got rc=$rc"; fi
assert_has "$out" "ARMED" "status: reports ARMED"

echo "== test: arm again — dedup =="
assert_rc 3 "dedup: re-arm without --force" run_cadence "$state" arm --time 08:00

echo "== test: arm --force replaces =="
out=$(run_cadence "$state" arm --time 09:00 --force 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "force re-arm: rc=0"; else fail "force re-arm: expected rc=0 got rc=$rc; output: $out"; fi
assert_has "$out" "--force set" "force re-arm: acknowledges force"
if [ "$(grep -cF 'HIMMEL-LunaVitalsPull' "$state/tab" 2>/dev/null)" = "1" ]; then
  pass "force re-arm: exactly one cron entry (no duplicate)"
else
  fail "force re-arm: expected exactly one cron entry"
fi

echo "== test: disarm removes task AND registry entry =="
out=$(run_cadence "$state" disarm 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "disarm: rc=0"; else fail "disarm: expected rc=0 got rc=$rc; output: $out"; fi
assert_has "$out" "cadence disarmed" "disarm: confirms disarmed"
if grep -qF 'HIMMEL-LunaVitalsPull' "$state/tab" 2>/dev/null; then fail "disarm: cron entry still present"; else pass "disarm: cron entry removed"; fi
if registry_has_task "$state/observability.json"; then fail "disarm: still registered"; else pass "disarm: registry entry removed"; fi

echo "== test: status (not armed) =="
out=$(run_cadence "$state" status 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "status after disarm: rc=0"; else fail "status after disarm: expected rc=0 got rc=$rc"; fi
assert_has "$out" "not armed" "status after disarm: reports not armed"

echo "== test: disarm is idempotent (no-op) =="
out=$(run_cadence "$state" disarm 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "second disarm: rc=0"; else fail "second disarm: expected rc=0 got rc=$rc"; fi
assert_has "$out" "disarm is a no-op" "second disarm: reports no-op"

echo "== test: bad --time rejected (rc=1, cross-platform contract) =="
state2=$(new_scratch_posix); root2=$(make_root); mv "$root2" "$state2/root"
out=$(run_cadence "$state2" arm --time nonsense 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "bad --time (rc=1)"; else fail "bad --time — expected rc=1 got rc=$rc; output: $out"; fi
assert_has "$out" "--time must be HH:MM" "bad --time: rejected for the right reason"

echo "== test: the existing bare (no-args) pull path is untouched =="
# The connector-pull path itself is covered by pull-cadence.test.ts; this
# only proves the arm/status/disarm addition did not change ITS dispatch —
# a bogus PULL_CMD should still reach the pull logic (rc from PULL_CMD, not
# a usage error), confirming "arm|status|disarm|-h|--help" is the ONLY
# intercepted $1 shape.
out=$(PULL_CMD='exit 75' bash "$CADENCE" 2>&1); rc=$?
if [ "$rc" -eq 75 ]; then pass "bare invocation: still reaches the pull path (rc=75 via PULL_CMD)"; else fail "bare invocation: expected rc=75 got rc=$rc; output: $out"; fi

echo
if [ "$fails" -eq 0 ]; then echo "SUMMARY: all tests passed"; else echo "SUMMARY: $fails failed"; exit 1; fi
