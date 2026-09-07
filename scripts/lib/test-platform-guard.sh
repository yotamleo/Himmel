#!/usr/bin/env bash
# test-platform-guard.sh — direct unit tests for platform_guard_ok
# (HIMMEL-2682). Exercises the predicate itself, not just its two consumers
# (scripts/hooks/check-new-shell-platform-guard.sh's suite and
# scripts/parity/test-ws5-invariants.sh's T15 both cover it end-to-end
# already; this asserts the function directly against a scratch file).
#
# Usage: bash scripts/lib/test-platform-guard.sh
# Exit:  0 = all pass, 1 = one or more failures.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib/platform-guard.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/platform-guard.sh"

TMPDIR_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-platform-guard.XXXXXX")" || {
    echo "FAIL: mktemp -d failed" >&2
    exit 1
}
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

_pass=0
_fail=0

assert_rc() {
    local test_name="$1" expected_rc="$2" actual_rc="$3"
    if [ "$actual_rc" -eq "$expected_rc" ]; then
        echo "PASS: $test_name (rc=$actual_rc)"
        _pass=$((_pass + 1))
    else
        echo "FAIL: $test_name -- expected rc=$expected_rc got rc=$actual_rc"
        _fail=$((_fail + 1))
    fi
}

# T1 -- no twin, no marker -> refused (rc=1).
f="$TMPDIR_ROOT/no-marker.sh"
printf '#!/usr/bin/env bash\necho hi\n' > "$f"
rc=0
platform_guard_ok "$f" || rc=$?
assert_rc "no twin/marker -> refused" 1 "$rc"

# T2 -- marker in first 60 lines -> ok (rc=0).
f="$TMPDIR_ROOT/marker.sh"
printf '#!/usr/bin/env bash\n# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.\necho hi\n' > "$f"
rc=0
platform_guard_ok "$f" || rc=$?
assert_rc "platform-guard marker -> ok" 0 "$rc"

# T3 -- 'gitbash' marker spelling -> ok.
f="$TMPDIR_ROOT/gitbash.sh"
printf '#!/usr/bin/env bash\n# gitbash only\necho hi\n' > "$f"
rc=0
platform_guard_ok "$f" || rc=$?
assert_rc "gitbash marker spelling -> ok" 0 "$rc"

# T4 -- .ps1 twin present, no marker -> ok.
f="$TMPDIR_ROOT/twin.sh"
printf '#!/usr/bin/env bash\necho hi\n' > "$f"
printf 'Write-Host "hi"\n' > "$TMPDIR_ROOT/twin.ps1"
rc=0
platform_guard_ok "$f" || rc=$?
assert_rc ".ps1 twin -> ok" 0 "$rc"

# T5 -- marker present but past line 60 -> refused.
f="$TMPDIR_ROOT/late-marker.sh"
{
    echo '#!/usr/bin/env bash'
    i=1
    while [ "$i" -le 65 ]; do
        echo "# filler line $i"
        i=$((i + 1))
    done
    echo '# Platform guard (gitbash-only)'
} > "$f"
rc=0
platform_guard_ok "$f" || rc=$?
assert_rc "marker past line 60 -> refused" 1 "$rc"

# T6 -- nonexistent path -> refused (rc=1), not a crash.
rc=0
platform_guard_ok "$TMPDIR_ROOT/does-not-exist.sh" || rc=$?
assert_rc "nonexistent path -> refused" 1 "$rc"

echo "-- $_pass passed, $_fail failed --"
[ "$_fail" -eq 0 ]
