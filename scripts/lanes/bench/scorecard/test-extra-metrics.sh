#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/test-extra-metrics.sh - RED/GREEN suite for
# extra-metrics.sh's per-message operator-intervention window filter
# (HIMMEL-2977 /pr-check codex-5 fix). House check/contains style, per
# scripts/test-context-fill.sh.
#
# Platform guard: no .ps1 twin, by design. POSIX bash 3.2+; it runs under
# git bash unchanged.
#
# The fix-forward/revert (g) section calls `gh pr list` against a real repo,
# so this suite is network-dependent by construction (like extra-metrics.sh
# itself) - it points --repo at himmel's own upstream, which the local `gh`
# is already authenticated against.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/extra-metrics.sh"
fails=0

check_contains() {
    name="$1"; haystack="$2"; needle="$3"
    case "$haystack" in
        *"$needle"*) echo "ok - $name" ;;
        *) echo "FAIL - $name: expected to find [$needle]"; fails=$((fails + 1)) ;;
    esac
}

# --- operator-window: pre-window and in-window user messages in one
# console session; only the in-window message's own timestamp should count.
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/operator-window"

OUT=$("$SCRIPT" --since 2026-01-15T00:00:00Z --repo yotamleo/Himmel 2>/dev/null)
check_contains "operator-window: pre-window message excluded from operator_msgs" \
    "$OUT" "console_sessions=1 operator_msgs=1 per_session=1.0"

echo "---"
if [ "$fails" -eq 0 ]; then
    echo "PASS - test-extra-metrics.sh: 0 failures"
    exit 0
else
    echo "FAIL - test-extra-metrics.sh: $fails failure(s)"
    exit 1
fi
