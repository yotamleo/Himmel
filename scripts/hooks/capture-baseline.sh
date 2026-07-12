#!/usr/bin/env bash
# capture-baseline.sh — drive end-session-wiki.sh with ALL inputs pinned,
# verify determinism, capture the golden note, and run the safety gate.
#
# The baseline (session-note.baseline.md) is a static fixture captured before
# the session_id/source fields were added; it lives in version control.
# This script captures the current hook output as session-note.golden.md and
# verifies the safety gate: golden minus {session_id, source} == baseline.
#
# Usage:
#   bash scripts/hooks/capture-baseline.sh
#
# Exit codes:
#   0  — all checks passed
#   1  — something failed
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTDATA_DIR="${SCRIPT_DIR}/testdata"
HOOK="${SCRIPT_DIR}/end-session-wiki.sh"
FIXTURE="${TESTDATA_DIR}/fixture.jsonl"
BASELINE="${TESTDATA_DIR}/session-note.baseline.md"
GOLDEN="${TESTDATA_DIR}/session-note.golden.md"

FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

# ---------- Build stub directory -------------------------------------------

STUBS="$(mktemp -d)"
SB=""
SB2=""
# shellcheck disable=SC2317  # invoked via trap EXIT
cleanup() { rm -rf "$STUBS" "${SB:-}" "${SB2:-}"; }
trap cleanup EXIT

# --- stub date ---
# Pinned values for all date formats used by end-session-wiki.sh.
# Fixed time: 2026-06-20T08:00:00Z = Unix epoch 1750416000
# Fixture FIRST_TS: 2026-06-20T06:00:00Z = epoch 1750408800
# Duration: 1750416000 - 1750408800 = 7200s = 120 min
cat > "${STUBS}/date" << 'EOF'
#!/usr/bin/env bash
args="$*"
if   printf '%s' "$args" | grep -q '%s%3N';               then echo "1750416000000"
elif printf '%s' "$args" | grep -qE '^\-u \-d .* \+%s$'; then echo "1750408800"
elif printf '%s' "$args" | grep -q '%s';                  then echo "1750416000"
elif printf '%s' "$args" | grep -q '%Y-%m-%dT%H:%M:%SZ';  then echo "2026-06-20T08:00:00Z"
elif printf '%s' "$args" | grep -q '%Y-%m-%d';            then echo "2026-06-20"
elif printf '%s' "$args" | grep -q '%H%M';                then echo "0800"
elif printf '%s' "$args" | grep -qE '\+%Y$';              then echo "2026"
elif printf '%s' "$args" | grep -qE '\+%m$';              then echo "06"
else /usr/bin/date "$@"
fi
EOF
chmod +x "${STUBS}/date"

# --- stub git ---
cat > "${STUBS}/git" << 'EOF'
#!/usr/bin/env bash
args="$*"
if   printf '%s' "$args" | grep -q 'rev-parse --show-toplevel'; then
    echo "/tmp/himmel-test"
elif printf '%s' "$args" | grep -q 'remote get-url origin'; then
    echo "https://github.com/yotamleo/himmel.git"
elif printf '%s' "$args" | grep -q 'branch --show-current'; then
    echo "feat/luna-backfill"
elif printf '%s' "$args" | grep -q 'diff --name-only HEAD'; then
    printf 'scripts/lib/session-transcript.sh\nscripts/lib/session-note.sh\n'
else
    /usr/bin/git "$@"
fi
EOF
chmod +x "${STUBS}/git"

# ---------- Build sandbox ---------------------------------------------------

SB="$(mktemp -d)"
mkdir -p "${SB}/vault" "${SB}/proj/.claude"

# Use a FIXED cwd (/tmp/himmel-test) so the worktree field is deterministic
# across runs. The git stub handles all git -C /tmp/himmel-test commands.
FIXED_CWD="/tmp/himmel-test"

PAYLOAD="$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"test-session-id-001","reason":"other"}' \
    "$FIXTURE" "$FIXED_CWD")"

# ---------- Run hook (first time) -------------------------------------------

printf '%s' "$PAYLOAD" | \
    env PATH="${STUBS}:${PATH}" \
        OSTYPE="linux-gnu" OS="" \
        LUNA_VAULT_PATH="${SB}/vault" \
        OBSIDIAN_API_KEY="" \
        CLAUDE_PROJECT_DIR="${SB}/proj" \
    bash "$HOOK"

NOTE1="$(find "${SB}/vault/sessions" -type f -name '*.md' 2>/dev/null | head -1)"
if [ -z "$NOTE1" ]; then
    echo "Log output:" >&2
    cat "${SB}/proj/.claude/end-session-wiki.log" 2>/dev/null >&2 || true
    fail "first run wrote no note"
    exit 1
fi
pass "first run wrote note: $(basename "$NOTE1")"

# ---------- Save golden -----------------------------------------------------

# Write the golden with a trailing newline so it matches the committed form
# (end-of-file-fixer adds a trailing \n to tracked files; the hook writes with
# `printf '%s'` which has no trailing newline, so a plain `cp` produces a file
# without one and re-running always shows a spurious diff).
printf '%s\n' "$(cat "$NOTE1")" > "$GOLDEN"
pass "golden saved to: $GOLDEN"

# ---------- Run hook (second time — determinism check) ----------------------

SB2="$(mktemp -d)"
mkdir -p "${SB2}/vault" "${SB2}/proj/.claude"

printf '%s' "$PAYLOAD" | \
    env PATH="${STUBS}:${PATH}" \
        OSTYPE="linux-gnu" OS="" \
        LUNA_VAULT_PATH="${SB2}/vault" \
        OBSIDIAN_API_KEY="" \
        CLAUDE_PROJECT_DIR="${SB2}/proj" \
    bash "$HOOK"

NOTE2="$(find "${SB2}/vault/sessions" -type f -name '*.md' 2>/dev/null | head -1)"
if [ -z "$NOTE2" ]; then
    fail "second run wrote no note"
    exit 1
fi
pass "second run wrote note: $(basename "$NOTE2")"

# ---------- Determinism check -----------------------------------------------

if diff -q "$NOTE1" "$NOTE2" >/dev/null 2>&1; then
    pass "determinism: two runs are byte-identical"
else
    fail "determinism: two runs differ"
    diff "$NOTE1" "$NOTE2" || true
fi

# ---------- Safety gate -----------------------------------------------------
# golden minus {session_id:, source:} lines must equal baseline exactly.
# Normalize trailing newlines: both sides stripped via printf '%s' so that
# the end-of-file-fixer (which adds a trailing \n to committed files) doesn't
# cause false differences against hook output (which uses printf '%s' to write).

STRIPPED="$(grep -v '^session_id:' "$GOLDEN" | grep -v '^source:')"
# Trim any trailing newline from baseline too (end-of-file-fixer may add one)
BASELINE_CONTENT="$(cat "$BASELINE")"
if [ "$STRIPPED" = "$BASELINE_CONTENT" ]; then
    pass "safety gate: golden minus session_id/source == baseline"
else
    fail "safety gate: golden minus two new keys differs from baseline"
    printf '%s' "$BASELINE_CONTENT" > /tmp/himmel-baseline-check.md
    printf '%s' "$STRIPPED" > /tmp/himmel-golden-stripped.md
    diff /tmp/himmel-baseline-check.md /tmp/himmel-golden-stripped.md || true
    rm -f /tmp/himmel-baseline-check.md /tmp/himmel-golden-stripped.md
fi

if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS — golden captured at ${GOLDEN}"
    exit 0
fi
echo "SOME FAILED"
exit 1
