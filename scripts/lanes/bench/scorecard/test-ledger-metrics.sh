#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/test-ledger-metrics.sh - RED/GREEN suite for
# ledger-metrics.sh (HIMMEL-2977 P0 script shipped in #689 with no paired
# test; HIMMEL-2981). House check/contains style, per
# scripts/test-context-fill.sh.
#
# ledger-metrics.sh flags/branches covered:
#   --since (required, exit 2 if missing)
#   --until (optional; defaults the window's upper edge to epoch 9999999999)
#   --repo (passed through to `gh pr list -R`)
#   unknown argument -> exit 2
#   SCORECARD_LEDGER missing -> exit 2
#   bad --since value (to_epoch fails) -> exit 2
#   `gh pr list` failure -> exit 1
#   1000-PR-cap WARNING (non-fatal, --limit 1000 boundary)
#   mergedAt window: since inclusive (>=), until exclusive (<), fractional
#     seconds stripped before fromdateiso8601, --until omitted -> no upper edge
#   ledger row filter: (.artifact // "diff")=="diff" (default-to-diff AND
#     explicit-non-diff-excluded), kind in {finding, attempt} ("amend" and
#     other kinds excluded)
#   awk branch-join: only merged branches counted; per-branch crit/imp/sug
#     finding counts and rounds (distinct heads across finding+attempt rows)
#   final stat lines: crit/imp/sug/rounds (n/sum/mean/median/max), the
#     crit+imp combined line, and the merged-window summary line
#
# Platform guard: no .ps1 twin, by design. POSIX bash 3.2+ plus jq and gh
# (stubbed here for hermetic runs), same convention as test-extra-metrics.sh.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/ledger-metrics.sh"
FIXTURES="$HERE/fixtures/ledger-metrics"
fails=0

check_exit() {
    name="$1"; actual="$2"; expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "ok - $name"
    else
        echo "FAIL - $name: expected exit [$expected] got [$actual]"
        fails=$((fails + 1))
    fi
}

check_contains() {
    name="$1"; haystack="$2"; needle="$3"
    case "$haystack" in
        *"$needle"*) echo "ok - $name" ;;
        *) echo "FAIL - $name: expected to find [$needle] in [$haystack]"; fails=$((fails + 1)) ;;
    esac
}

use_stub() {
    export PATH="$HERE/fixtures/$1:$PATH_BASE"
    RESOLVED_GH=$(command -v gh)
    if [ "$RESOLVED_GH" != "$HERE/fixtures/$1/gh" ]; then
        echo "FAIL - precondition: gh stub $1 not first on PATH (resolved: ${RESOLVED_GH:-none}) — aborting before any real gh call"
        exit 1
    fi
}
PATH_BASE="$PATH"

# --- (a) usage: missing --since -> exit 2
export SCORECARD_LEDGER="$FIXTURES/empty-ledger.jsonl"
"$SCRIPT" >/dev/null 2>&1
check_exit "usage: missing --since exits 2" "$?" "2"

# --- (b) usage: unknown argument -> exit 2
"$SCRIPT" --since 2026-08-01T00:00:00Z --bogus foo >/dev/null 2>&1
check_exit "usage: unknown argument exits 2" "$?" "2"

# --- (c) missing ledger file -> exit 2
export SCORECARD_LEDGER="$FIXTURES/does-not-exist.jsonl"
ERR=$("$SCRIPT" --since 2026-08-01T00:00:00Z 2>&1 >/dev/null)
check_exit "missing ledger: exits 2" "$?" "2"
check_contains "missing ledger: error names the missing path" "$ERR" "no ledger at"

# --- (d) bad --since value -> to_epoch fails -> exit 2 (ledger exists, so
# this is a genuine to_epoch failure, not a ledger-missing false positive)
export SCORECARD_LEDGER="$FIXTURES/empty-ledger.jsonl"
ERR=$("$SCRIPT" --since not-a-date 2>&1 >/dev/null)
check_exit "bad --since: exits 2" "$?" "2"
check_contains "bad --since: error names the bad value" "$ERR" "bad --since: not-a-date"

# --- (e) gh pr list failure -> exit 1
export SCORECARD_LEDGER="$FIXTURES/empty-ledger.jsonl"
use_stub stub-gh-ledger-fail
ERR=$("$SCRIPT" --since 2026-08-01T00:00:00Z 2>&1 >/dev/null)
check_exit "gh failure: exits 1" "$?" "1"
check_contains "gh failure: error names gh pr list" "$ERR" "gh pr list failed"

# --- (f) --repo passthrough: the stub only succeeds if -R custom/repo is
# present, so a dropped --repo value fails the stub rather than silently
# querying the wrong repo. Also exercises the empty-merged-PR-list path.
export SCORECARD_LEDGER="$FIXTURES/empty-ledger.jsonl"
use_stub stub-gh-ledger-repo
OUT=$("$SCRIPT" --since 2026-08-01T00:00:00Z --repo custom/repo 2>/dev/null)
EXIT=$?
check_exit "repo passthrough: exits 0" "$EXIT" "0"
check_contains "repo passthrough: -R custom/repo reaches gh, no merged PRs" \
    "$OUT" "merged_branches=0 with_ledger_rows=0"
check_contains "repo passthrough: empty merged-PR list -> empty window summary" \
    "$OUT" "merged window: (empty) count=0"

# --- (g) 1000-PR-cap WARNING (non-fatal, --limit 1000 boundary)
export SCORECARD_LEDGER="$FIXTURES/empty-ledger.jsonl"
use_stub stub-gh-ledger-1000
ERR=$("$SCRIPT" --since 2000-01-01T00:00:00Z 2>&1 >/dev/null)
EXIT=$("$SCRIPT" --since 2000-01-01T00:00:00Z >/dev/null 2>/dev/null; echo $?)
check_contains "1000-PR cap: WARNING printed at exactly 1000 merged PRs" \
    "$ERR" "WARNING: gh pr list returned 1000 merged PRs"
check_exit "1000-PR cap: warning is non-fatal" "$EXIT" "0"

# --- (h) artifact filter default: a ledger row with no "artifact" field
# defaults to "diff" and is counted, not silently dropped.
export SCORECARD_LEDGER="$FIXTURES/artifact-default/ledger.jsonl"
use_stub stub-gh-ledger-only
OUT=$("$SCRIPT" --since 2026-08-01T00:00:00Z --until 2026-08-03T00:00:00Z 2>/dev/null)
EXIT=$?
check_exit "artifact-default: exits 0" "$EXIT" "0"
check_contains "artifact-default: merged branch with one counted finding" \
    "$OUT" "merged_branches=1 with_ledger_rows=1"
check_contains "artifact-default: crit stat reflects the one default-artifact row" \
    "$OUT" "crit: n=1 sum=1 mean=1.00 median=1.0 max=1"

# --- (i)-(n) main scenario: two merged branches (feat/alpha, fix/beta) in a
# --since (inclusive) .. --until (exclusive) window; verifies fractional-
# second mergedAt stripping, the artifact=="diff" filter (excludes an
# explicit "code" row), the kind filter (excludes an "amend" row), and that
# a ledger row for a branch NOT in the merged-PR list (orphan/branch) is
# excluded from every stat.
export SCORECARD_LEDGER="$FIXTURES/main/ledger.jsonl"
use_stub stub-gh-ledger
OUT=$("$SCRIPT" --since 2026-08-02T00:00:00Z --until 2026-08-05T00:00:00Z 2>/dev/null)
EXIT=$?
check_exit "main: exits 0" "$EXIT" "0"
check_contains "main: two merged branches, both with ledger rows" \
    "$OUT" "merged_branches=2 with_ledger_rows=2"
check_contains "main: crit stat excludes the artifact=code row (feat/alpha=1, fix/beta=2)" \
    "$OUT" "crit: n=2 sum=3 mean=1.50 median=1.5 max=2"
check_contains "main: imp stat" "$OUT" "imp:  n=2 sum=2 mean=1.00 median=1.0 max=1"
check_contains "main: sug stat" "$OUT" "sug:  n=2 sum=1 mean=0.50 median=0.5 max=1"
check_contains "main: rounds stat excludes the amend row and the orphan/branch row (feat/alpha=2, fix/beta=4)" \
    "$OUT" "rounds: n=2 sum=6 mean=3.00 median=3.0 max=4"
check_contains "main: crit+imp combined stat" "$OUT" "crit+imp: n=2 mean=2.50 median=2.5"
check_contains "main: merged window excludes the at-until PR, strips fractional seconds" \
    "$OUT" "merged window: 2026-08-02T00:00:00Z .. 2026-08-03T12:00:00.123Z count=2"

# --- (o) --until omitted: the window's upper edge defaults far into the
# future, so the same-branch PR sitting exactly at the (h)-scenario's
# --until edge is now included.
export SCORECARD_LEDGER="$FIXTURES/main/ledger.jsonl"
use_stub stub-gh-ledger
OUT=$("$SCRIPT" --since 2026-08-02T00:00:00Z 2>/dev/null)
EXIT=$?
check_exit "no --until: exits 0" "$EXIT" "0"
check_contains "no --until: the at-until PR is now included in the merged window" \
    "$OUT" "merged window: 2026-08-02T00:00:00Z .. 2026-08-05T00:00:00Z count=3"

echo "---"
if [ "$fails" -eq 0 ]; then
    echo "PASS - test-ledger-metrics.sh: 0 failures"
    exit 0
else
    echo "FAIL - test-ledger-metrics.sh: $fails failure(s)"
    exit 1
fi
