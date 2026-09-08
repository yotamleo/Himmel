#!/usr/bin/env bash
# test-session-name.sh — HIMMEL-2788. current_session_name resolves the `-n`
# session name from a fabricated NUL-delimited cmdline fixture (via the
# SESSION_NAME_CMDLINE_FILE test seam — see session-name.sh's header for why
# a real pid's /proc/<pid>/cmdline can't be fabricated in a test).
# Run: bash scripts/lib/test-session-name.sh
#
# PLATFORM GUARD: no .ps1 twin, by design, not oversight — tests a Linux-only
# seam (see session-name.sh's header).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/session-name.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/session-name-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# fake_cmdline <arg> <arg> ... — writes a NUL-delimited argv fixture and
# points SESSION_NAME_CMDLINE_FILE + CLAUDE_PID at it.
fake_cmdline() {
    local f="$WORK/cmdline"
    printf '%s\0' "$@" > "$f"
    export SESSION_NAME_CMDLINE_FILE="$f"
    export CLAUDE_PID="12345"
}

# --- Case 1: happy path -------------------------------------------------
fake_cmdline claude --model claude-sonnet-5 -n HIMMEL-2788-legN54 load doc.md
out="$(current_session_name)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "HIMMEL-2788-legN54" ]; then
    pass "resolves -n value from argv"
else
    fail "resolves -n value from argv (rc=$rc out='$out')"
fi

# --- Case 2: no -n flag --------------------------------------------------
fake_cmdline claude --model claude-sonnet-5 load doc.md
out="$(current_session_name)"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "no -n flag: unresolvable (rc!=0, empty)"
else
    fail "no -n flag: unresolvable (rc=$rc out='$out')"
fi

# --- Case 3: no CLAUDE_PID -------------------------------------------------
unset CLAUDE_PID
export SESSION_NAME_CMDLINE_FILE="$WORK/cmdline"
out="$(current_session_name)"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "no CLAUDE_PID: unresolvable"
else
    fail "no CLAUDE_PID: unresolvable (rc=$rc out='$out')"
fi

# --- Case 4: traversal refused -------------------------------------------
fake_cmdline claude -n "../../etc/passwd" load doc.md
out="$(current_session_name)"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "traversal name (../..) refused"
else
    fail "traversal name (../..) refused (rc=$rc out='$out')"
fi

fake_cmdline claude -n "foo/bar" load doc.md
out="$(current_session_name)"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "slash in name refused"
else
    fail "slash in name refused (rc=$rc out='$out')"
fi

# --- Case 5: whitespace refused -------------------------------------------
fake_cmdline claude -n "foo bar" load doc.md
out="$(current_session_name)"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "whitespace in name refused"
else
    fail "whitespace in name refused (rc=$rc out='$out')"
fi

# --- Case 6: missing cmdline file -----------------------------------------
export CLAUDE_PID="12345"
export SESSION_NAME_CMDLINE_FILE="$WORK/does-not-exist"
out="$(current_session_name)"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "missing cmdline file: unresolvable, no crash"
else
    fail "missing cmdline file: unresolvable (rc=$rc out='$out')"
fi

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "SOME FAILED"; exit 1
