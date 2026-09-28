#!/usr/bin/env bash
# test-ensure-qmd-daemon-leak.sh - HIMMEL-3775 regression: an early failure
# partway through test-ensure-qmd-daemon.sh (a forced assertion failure right
# after it starts a fake-daemon.sh stub, modeling a kill mid-run) must not
# leak that stub process.
#
# Matches on THIS run's own unique $work path (via QMD_TEST_WORK_MARKER),
# never a bare `pgrep fake-daemon`: other legs/stations may run the same
# suite concurrently.
set -u

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
suite="$repo_root/scripts/qmd/test-ensure-qmd-daemon.sh"
[ -f "$suite" ] || { echo "FAIL: $suite not found" >&2; exit 1; }
fail() { echo "FAIL: $1" >&2; exit 1; }
command -v pgrep >/dev/null 2>&1 || fail "pgrep not found - cannot check for a surviving stub"

marker="$(mktemp)"
log="$(mktemp)"
trap 'rm -f "$marker" "$log"' EXIT

# Redirect to a regular file, never $(...): a leaked stub inherits our fds and
# would hold a pipe's read side open forever, hanging this probe on the very
# leak it is trying to catch.
QMD_TEST_WORK_MARKER="$marker" QMD_TEST_FORCE_FAIL_AFTER=start_fake_daemon \
  bash "$suite" > "$log" 2>&1
rc=$?
[ "$rc" -ne 0 ] || fail "expected the forced failure to exit nonzero (got 0; out: $(cat "$log"))"
# A nonzero exit alone doesn't prove we reached the forced-failure point (an
# unrelated earlier failure would also exit nonzero without ever starting a
# stub, making this control pass vacuously) - require the suite's own
# forced-failure message.
grep -q 'forced failure after start_fake_daemon (HIMMEL-3775 leak-test hook)' "$log" \
  || fail "suite exited nonzero but never reached the forced failure after start_fake_daemon (out: $(cat "$log"))"

work_dir="$(cat "$marker")"
[ -n "$work_dir" ] || fail "suite never wrote its \$work path to the marker"

# The suite's own EXIT trap runs synchronously before it exits, so no extra
# wait is needed; poll briefly anyway to be robust against slow SIGTERM unwind.
i=0
while pgrep -f "$work_dir/fake-daemon.sh" >/dev/null 2>&1 && [ "$i" -lt 20 ]; do
  i=$((i + 1))
  sleep 0.1
done
if pgrep -f "$work_dir/fake-daemon.sh" >/dev/null 2>&1; then
  fail "leaked fake-daemon.sh stub survives a forced failure partway through: $(pgrep -af "$work_dir/fake-daemon.sh")"
fi
echo "ok: no fake-daemon.sh stub survives a forced kill/failure partway through the suite"
