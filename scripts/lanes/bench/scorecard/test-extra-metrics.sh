#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/test-extra-metrics.sh - RED/GREEN suite for
# extra-metrics.sh's per-message operator-intervention window filter
# (HIMMEL-2977 /pr-check codex-5 fix). House check/contains style, per
# scripts/test-context-fill.sh.
#
# Platform guard: no .ps1 twin, by design. POSIX bash 3.2+; it runs under
# git bash unchanged.
#
# The fix-forward/revert (g) section calls `gh pr list`; extra-metrics.sh
# exits 1 if that call fails, which starves the operator-window assertions
# below of any output at all (HIMMEL-2977 CI fix: a CI runner has no `gh
# auth`). A PATH-prepended stub makes this hermetic - no CI-env skip, no
# `gh auth status` gate.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/extra-metrics.sh"
fails=0

STUB_BIN="$HERE/fixtures/stub-gh"
export PATH="$STUB_BIN:$PATH"
RESOLVED_GH=$(command -v gh)
if [ "$RESOLVED_GH" != "$STUB_BIN/gh" ]; then
    echo "FAIL - precondition: gh stub not first on PATH (resolved: ${RESOLVED_GH:-none})"
    exit 1
fi

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
# HIMMEL-3269: each metric is followed by the coverage of the input it read
check_contains "operator-window: transcript coverage triple beside the operator count" \
    "$OUT" "coverage: roots=1 discovered=1 parsed=1 skipped=0"
check_contains "operator-window: PR coverage beside the followups metric" \
    "$OUT" "coverage: prs discovered=0 parsed=0 skipped=0 (limit=1000 truncated=no)"

# --- operator-window-fractional: an in-window user message whose timestamp
# carries fractional seconds must still be counted (HIMMEL-2977 /pr-check
# codex-1 fix: jq's fromdateiso8601 rejects a fractional-second suffix
# unless it is stripped first, same as every bash-level to_epoch()).
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/operator-window-fractional"

OUT=$("$SCRIPT" --since 2026-01-15T00:00:00Z --repo yotamleo/Himmel 2>/dev/null)
check_contains "operator-window-fractional: fractional-second timestamp still counted" \
    "$OUT" "console_sessions=1 operator_msgs=1 per_session=1.0"

# --- operator-window-malformed: a transcript whose operator-intervention jq
# filter hits a parse error must be excluded and WARNED about, not silently
# mismeasured (HIMMEL-2977 /pr-check round-3 codex-2 fix: the old
# `jq ... 2>/dev/null | wc -l` pipeline reported wc -l's own exit status,
# masking a jq failure).
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/operator-window-malformed"
ERR_OUT=$(mktemp "${TMPDIR:-/tmp}/test-extra-metrics-stderr.XXXXXX")
OUT=$("$SCRIPT" --since 2026-01-15T00:00:00Z --repo yotamleo/Himmel 2>"$ERR_OUT")
check_contains "operator-window-malformed: malformed transcript excluded rather than silently mismeasured" \
    "$OUT" "console_sessions=0 operator_msgs=0 per_session=0.0"
check_contains "operator-window-malformed: the excluded transcript is counted as skipped, with its reason" \
    "$OUT" "coverage: roots=1 discovered=1 parsed=0 skipped=1 (jq-failed=1)"
check_contains "operator-window-malformed: jq failure is warned rather than swallowed" \
    "$(cat "$ERR_OUT")" "WARNING: 1 transcript(s) skipped due to jq failure"
rm -f "$ERR_OUT"

echo "---"
if [ "$fails" -eq 0 ]; then
    echo "PASS - test-extra-metrics.sh: 0 failures"
    exit 0
else
    echo "FAIL - test-extra-metrics.sh: $fails failure(s)"
    exit 1
fi
