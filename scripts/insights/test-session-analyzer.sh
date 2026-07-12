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
# Case 10: genuine-block vs mention discrimination (the metric-gaming gate)
#
# Friction tallies must distinguish a GENUINE gate block (the hook's ⛔ BLOCK
# exit text) from a mere mention — e.g. a passing `Platforms tested:` attestation
# trailer must count as a mention but NOT as a genuine block. Isolated in its own
# projects dir so the exact-count assertions above are untouched.
# ---------------------------------------------------------------------------
printf '\nCase 10: genuine-block vs mention discrimination\n'

PROJ_ROOT2="$TMP_ROOT/projects2"
mkdir -p "$PROJ_ROOT2/proj-x"

# Genuine PreToolUse block: real ⛔ exit text from block-edit-on-main.
BLOCK_MAIN='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Tool result: ⛔ block-edit-on-main: refusing to edit x.sh — its repo is on main/master."}]},"timestamp":"2026-03-01T10:00:00Z"}'
# Passing attestation trailer — mentions the gate names but is NOT a block.
TRAILER='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"commit body — Platforms tested: Windows ; Security reviewed: manual ; shellcheck passed clean"}]},"timestamp":"2026-03-02T10:00:00Z"}'
# Genuine pre-push gate blocks: real ⛔ exit text from both attestation gates.
BLOCK_PUSH='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"⛔ platforms-check: this push touches cross-platform-sensitive files but no Platforms tested: attestation found. ⛔ security-review: this push touches non-docs code but no Security reviewed: attestation."}]},"timestamp":"2026-03-03T10:00:00Z"}'
# Genuine pre-commit failure: real pre-commit output. Its block signature
# `- exit code: N` begins with a dash — a regression guard that the grep call
# uses `--` so the pattern is not parsed as a grep option.
BLOCK_PRECOMMIT='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"pre-commit hook failed: trailing-whitespace - hook id: trailing-whitespace - exit code: 1"}]},"timestamp":"2026-03-04T10:00:00Z"}'
# Genuine block-read-secrets block — exercises that gate's genuine ERE.
BLOCK_SECRETS='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"⛔ block-read-secrets: refusing Read of secret file: config/.env"}]},"timestamp":"2026-03-05T10:00:00Z"}'
# A shellcheck MENTION only (matches the mention ERE, NOT the genuine one) — the
# zero-genuine path: its `.block` tally must render 0 (missing-file default), NOT
# the mention count, and it must be absent from Top Sessions per Genuine Block.
MENTION_SHELLCHECK='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"discussion: a shellcheck error came up earlier but the commit went through fine"}]},"timestamp":"2026-03-06T10:00:00Z"}'

_write_jsonl "$PROJ_ROOT2/proj-x/s-block-main.jsonl"      "2026-03-01T09:00:00Z" "2026-03-01T11:00:00Z" "/tmp/proj-x" "$BLOCK_MAIN"
_write_jsonl "$PROJ_ROOT2/proj-x/s-trailer.jsonl"         "2026-03-02T09:00:00Z" "2026-03-02T11:00:00Z" "/tmp/proj-x" "$TRAILER"
_write_jsonl "$PROJ_ROOT2/proj-x/s-block-push.jsonl"      "2026-03-03T09:00:00Z" "2026-03-03T11:00:00Z" "/tmp/proj-x" "$BLOCK_PUSH"
_write_jsonl "$PROJ_ROOT2/proj-x/s-precommit.jsonl"       "2026-03-04T09:00:00Z" "2026-03-04T11:00:00Z" "/tmp/proj-x" "$BLOCK_PRECOMMIT"
_write_jsonl "$PROJ_ROOT2/proj-x/s-secrets-block.jsonl"   "2026-03-05T09:00:00Z" "2026-03-05T11:00:00Z" "/tmp/proj-x" "$BLOCK_SECRETS"
_write_jsonl "$PROJ_ROOT2/proj-x/s-shellcheck-ment.jsonl" "2026-03-06T09:00:00Z" "2026-03-06T11:00:00Z" "/tmp/proj-x" "$MENTION_SHELLCHECK"

REPORT10="$(bash "$ANALYZER" --projects-dir "$PROJ_ROOT2" 2>&1)"

assert_contains "genuine-block: friction table has Genuine Blocks column" "Genuine Blocks" "$REPORT10"

# block-edit-on-main: 1 mention (s-block-main), 1 genuine (s-block-main)
if printf '%s' "$REPORT10" | grep -qE 'block-edit-on-main *\| *1 *\| *1 *\|'; then
    pass "genuine-block: block-edit-on-main mentions=1 genuine=1"
else
    fail "genuine-block: block-edit-on-main should be 1/1" "$(printf '%s' "$REPORT10" | grep 'block-edit-on-main')"
fi

# platforms-tested-gate: 2 mentions (trailer + push-block), 1 genuine (push-block).
# This is the metric-gaming gate: the passing trailer inflates mentions but is
# NOT a genuine block.
if printf '%s' "$REPORT10" | grep -qE 'platforms-tested-gate *\| *2 *\| *1 *\|'; then
    pass "genuine-block: platforms-tested-gate mentions=2 genuine=1 (trailer excluded)"
else
    fail "genuine-block: platforms-tested-gate should be 2/1" "$(printf '%s' "$REPORT10" | grep 'platforms-tested-gate')"
fi

# security-reviewed-gate: same shape — 2 mentions, 1 genuine.
if printf '%s' "$REPORT10" | grep -qE 'security-reviewed-gate *\| *2 *\| *1 *\|'; then
    pass "genuine-block: security-reviewed-gate mentions=2 genuine=1 (trailer excluded)"
else
    fail "genuine-block: security-reviewed-gate should be 2/1" "$(printf '%s' "$REPORT10" | grep 'security-reviewed-gate')"
fi

# pre-commit-failure: the `- exit code: N` block signature begins with a dash —
# guards that grep -E -- reads it as a regex, not an option (genuine must be 1).
if printf '%s' "$REPORT10" | grep -qE 'pre-commit-failure *\| *1 *\| *1 *\|'; then
    pass "genuine-block: pre-commit-failure mentions=1 genuine=1 (dash-pattern guard)"
else
    fail "genuine-block: pre-commit-failure should be 1/1" "$(printf '%s' "$REPORT10" | grep 'pre-commit-failure')"
fi

# block-read-secrets: exercises that gate's genuine ⛔ ERE (1 mention, 1 genuine).
if printf '%s' "$REPORT10" | grep -qE 'block-read-secrets *\| *1 *\| *1 *\|'; then
    pass "genuine-block: block-read-secrets mentions=1 genuine=1"
else
    fail "genuine-block: block-read-secrets should be 1/1" "$(printf '%s' "$REPORT10" | grep 'block-read-secrets')"
fi

# Zero-genuine path: shellcheck is mentioned but never genuinely blocked, so its
# Genuine Blocks tally must be 0 (missing-.block default), NOT the mention count.
if printf '%s' "$REPORT10" | grep -qE 'shellcheck-failure *\| *1 *\| *0 *\|'; then
    pass "genuine-block: shellcheck-failure mentions=1 genuine=0 (zero-genuine default)"
else
    fail "genuine-block: shellcheck-failure should be 1/0" "$(printf '%s' "$REPORT10" | grep 'shellcheck-failure')"
fi

# Top Sessions per Genuine Block renders genuine-block session basenames (only
# this section prints session filenames, so a bare basename grep is section-scoped).
assert_contains "genuine-block: Top Sessions renders a genuine-block session" "s-block-push.jsonl" "$REPORT10"
# ...and omits a mention-only (zero-genuine) session.
assert_not_contains "genuine-block: Top Sessions omits the mention-only session" "s-shellcheck-ment.jsonl" "$REPORT10"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n====================================\n'
printf 'test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
printf '====================================\n'

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
