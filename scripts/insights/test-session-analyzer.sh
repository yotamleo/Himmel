#!/usr/bin/env bash
# test-session-analyzer.sh — Tests for scripts/insights/session-analyzer.sh.
#
# Usage: bash scripts/insights/test-session-analyzer.sh
#
# Cases covered:
#   1. subagent-exclusion : transcripts under subagents/ are NOT counted
#   2. session-count      : correct total count (excludes subagents)
#   3. date-range         : min FIRST_TS → max LAST_TS in report header
#   4. per-month buckets  : correct YYYY-MM → count breakdown
#   5. friction-signals   : guardrail denial marker detected and reported
#   6. --since filter     : sessions before date are excluded from count
#   7. --out flag         : output goes to file, not stdout
#   8. --help             : exits 0 and prints usage
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
#
# bash 3.2-safe; shellcheck-clean.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYZER="$SCRIPT_DIR/session-analyzer.sh"

[ -f "$ANALYZER" ] || { printf 'FAIL: session-analyzer.sh not found at %s\n' "$ANALYZER"; exit 1; }

PASS=0
FAIL=0
TMP_ROOT=""

cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() {
    printf '  FAIL: %s\n' "$1"
    if [ $# -ge 2 ]; then printf '        %s\n' "$2"; fi
    FAIL=$((FAIL + 1))
}
assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        pass "$label"
    else
        fail "$label" "missing: $needle"
    fi
}
assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        fail "$label" "unexpected: $needle"
    else
        pass "$label"
    fi
}

TMP_ROOT="$(mktemp -d)"

# ---------------------------------------------------------------------------
# Build fixture projects dir
#
# Layout:
#   $PROJ_ROOT/
#     proj-alpha/           (real project slug)
#       session-jan-01.jsonl   (2026-01, cwd=proj-alpha)
#       session-jan-02.jsonl   (2026-01, cwd=proj-alpha)
#       session-feb-01.jsonl   (2026-02, cwd=proj-alpha — has friction marker)
#     proj-beta/
#       session-feb-02.jsonl   (2026-02, cwd=proj-beta)
#     proj-alpha/subagents/
#       subagent-001.jsonl     (MUST be excluded)
# ---------------------------------------------------------------------------

PROJ_ROOT="$TMP_ROOT/projects"
mkdir -p "$PROJ_ROOT/proj-alpha/subagents"
mkdir -p "$PROJ_ROOT/proj-beta"

# Helper: write a minimal JSONL transcript
# Args: path, first_ts, last_ts, cwd, extra_content
_write_jsonl() {
    local path="$1" first_ts="$2" last_ts="$3" cwd="$4" extra="$5"
    printf '{"type":"system","timestamp":"%s","cwd":"%s","sessionId":"%s"}\n' \
        "$first_ts" "$cwd" "$(basename "$path" .jsonl)" > "$path"
    printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hello"}]},"timestamp":"%s"}\n' \
        "$first_ts" >> "$path"
    if [ -n "$extra" ]; then
        printf '%s\n' "$extra" >> "$path"
    fi
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]},"timestamp":"%s"}\n' \
        "$last_ts" >> "$path"
}

# 2026-01 sessions (proj-alpha)
_write_jsonl \
    "$PROJ_ROOT/proj-alpha/session-jan-01.jsonl" \
    "2026-01-10T08:00:00Z" "2026-01-10T09:00:00Z" \
    "/tmp/proj-alpha" ""

_write_jsonl \
    "$PROJ_ROOT/proj-alpha/session-jan-02.jsonl" \
    "2026-01-20T10:00:00Z" "2026-01-20T11:00:00Z" \
    "/tmp/proj-alpha" ""

# 2026-02 session (proj-alpha, WITH friction marker)
FRICTION_LINE='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Error: Permission denied by block-edit-on-main hook"}]},"timestamp":"2026-02-05T14:30:00Z"}'
_write_jsonl \
    "$PROJ_ROOT/proj-alpha/session-feb-01.jsonl" \
    "2026-02-05T14:00:00Z" "2026-02-05T15:00:00Z" \
    "/tmp/proj-alpha" "$FRICTION_LINE"

# 2026-02 session (proj-beta)
_write_jsonl \
    "$PROJ_ROOT/proj-beta/session-feb-02.jsonl" \
    "2026-02-15T09:00:00Z" "2026-02-15T10:00:00Z" \
    "/tmp/proj-beta" ""

# Subagent transcript (MUST be excluded)
_write_jsonl \
    "$PROJ_ROOT/proj-alpha/subagents/subagent-001.jsonl" \
    "2026-01-15T12:00:00Z" "2026-01-15T12:30:00Z" \
    "/tmp/proj-alpha" ""

# Total non-subagent sessions: 4 (jan-01, jan-02, feb-01, feb-02)
# Subagent sessions: 1
# Date range: 2026-01-10 → 2026-02-15
# Per-month: 2026-01=2, 2026-02=2
# Friction: 1 block-edit-on-main hit in feb-01

# ---------------------------------------------------------------------------
# Case 1+2+3+4: basic run — count, date range, months, subagent exclusion
# ---------------------------------------------------------------------------
printf '\nCase 1-4: session count, date range, monthly buckets, subagent exclusion\n'

REPORT="$(bash "$ANALYZER" --projects-dir "$PROJ_ROOT" 2>&1)"

# Session count (4 non-subagent)
if printf '%s' "$REPORT" | grep -qE 'Sessions analyzed: *4($|[^0-9])'; then
    pass "session-count: 4 non-subagent sessions counted"
elif printf '%s' "$REPORT" | grep -qE '[Ss]essions.*: *4($|[^0-9])'; then
    pass "session-count: 4 non-subagent sessions counted (variant format)"
else
    fail "session-count: expected 4 sessions" "$(printf '%s' "$REPORT" | grep -i session | head -5)"
fi

# Subagent excluded: total jsonl = 5, but count = 4
assert_not_contains "subagent-exclusion: 5 not reported as total" "5 sessions" "$REPORT"

# Date range contains both endpoints
assert_contains "date-range: min date present" "2026-01-10" "$REPORT"
assert_contains "date-range: max date present" "2026-02-15" "$REPORT"

# Monthly buckets
assert_contains "per-month: 2026-01 bucket" "2026-01" "$REPORT"
assert_contains "per-month: 2026-02 bucket" "2026-02" "$REPORT"
# Both months should show count 2
if printf '%s' "$REPORT" | grep -q "2026-01.*2" || printf '%s' "$REPORT" | grep -q "2.*2026-01"; then
    pass "per-month: 2026-01 count=2"
else
    fail "per-month: 2026-01 should have count 2" "$(printf '%s' "$REPORT" | grep '2026-01')"
fi
if printf '%s' "$REPORT" | grep -q "2026-02.*2" || printf '%s' "$REPORT" | grep -q "2.*2026-02"; then
    pass "per-month: 2026-02 count=2"
else
    fail "per-month: 2026-02 should have count 2" "$(printf '%s' "$REPORT" | grep '2026-02')"
fi

# ---------------------------------------------------------------------------
# Case 5: friction signals
# ---------------------------------------------------------------------------
printf '\nCase 5: friction signals (block-edit-on-main)\n'

assert_contains "friction: block-edit-on-main detected" "block-edit-on-main" "$REPORT"

# ---------------------------------------------------------------------------
# Case 6: --since filter
# ---------------------------------------------------------------------------
printf '\nCase 6: --since filter\n'

REPORT6="$(bash "$ANALYZER" --projects-dir "$PROJ_ROOT" --since 2026-02-01 2>&1)"

# Only sessions from 2026-02 should be counted (2 sessions)
if printf '%s' "$REPORT6" | grep -qE 'Sessions analyzed: *2($|[^0-9])'; then
    pass "--since: 2 sessions counted from 2026-02 onward"
elif printf '%s' "$REPORT6" | grep -qE '[Ss]essions.*: *2($|[^0-9])'; then
    pass "--since: 2 sessions counted from 2026-02 onward (variant format)"
else
    fail "--since: expected 2 sessions from 2026-02-01 onward" \
        "$(printf '%s' "$REPORT6" | grep -i session | head -5)"
fi

# 2026-01 bucket should NOT appear (those sessions filtered out)
assert_not_contains "--since: 2026-01 bucket absent" "2026-01" "$REPORT6"

# ---------------------------------------------------------------------------
# Case 7: --out flag writes to file
# ---------------------------------------------------------------------------
printf '\nCase 7: --out flag\n'

OUT_FILE="$TMP_ROOT/report.md"
bash "$ANALYZER" --projects-dir "$PROJ_ROOT" --out "$OUT_FILE" >/dev/null 2>&1
if [ -f "$OUT_FILE" ] && [ -s "$OUT_FILE" ]; then
    pass "--out: report written to file"
else
    fail "--out: report file missing or empty"
fi

# Verify content of file matches what stdout would give
if grep -qF "2026-01" "$OUT_FILE"; then
    pass "--out: file contains expected content"
else
    fail "--out: file missing expected content"
fi

# ---------------------------------------------------------------------------
# Case 8: --help
# ---------------------------------------------------------------------------
printf '\nCase 8: --help\n'

HELP_OUT="$(bash "$ANALYZER" --help 2>&1)"
HELP_EC=$?
if [ "$HELP_EC" -eq 0 ]; then
    pass "--help: exits 0"
else
    fail "--help: expected exit 0, got $HELP_EC"
fi
assert_contains "--help: mentions --projects-dir" "--projects-dir" "$HELP_OUT"
assert_contains "--help: mentions --since" "--since" "$HELP_OUT"

# ---------------------------------------------------------------------------
# Case 9: value-option with missing argument errors (no unbound-var crash)
# ---------------------------------------------------------------------------
printf '\nCase 9: value-option missing-argument guard\n'

for _opt in --projects-dir --out --since; do
    _err="$(bash "$ANALYZER" "$_opt" 2>&1)"
    _ec=$?
    if [ "$_ec" -ne 0 ] && printf '%s' "$_err" | grep -qF "requires a value"; then
        pass "missing-arg: $_opt errors cleanly (exit $_ec)"
    else
        fail "missing-arg: $_opt should error with 'requires a value'" "$_err"
    fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n====================================\n'
printf 'test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
printf '====================================\n'

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
