#!/usr/bin/env bash
# test-inbox-hook.sh — HIMMEL-2788. Exercises scripts/lib/claudex-inbox.sh's
# cursor bookkeeping directly, and the two hook scripts
# (claudex-inbox-hook.sh / claudex-inbox-sessionstart.sh) end-to-end via a
# fabricated HANDOVER_DIR + session-name.sh's SESSION_NAME_CMDLINE_FILE test
# seam. bash 3.2-safe. Run: bash scripts/hooks/test-inbox-hook.sh
#
# PLATFORM GUARD: no .ps1 twin, by design, not oversight — tests a Linux-only
# claudex lane (see claudex-inbox-hook.sh's header).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/inbox-hook-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# --- direct inbox_new_bullets() tests --------------------------------------

# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/lib/handover-path.sh"
# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/lib/claudex-inbox.sh"

HANDOVER_DIR="$WORK/handover-root"
mkdir -p "$HANDOVER_DIR/inbox"
export HANDOVER_DIR
SESSION="HIMMEL-2788-test-leg"
INBOX="$HANDOVER_DIR/inbox/$SESSION.md"

# Case 1: no inbox file yet -> silent no-op, rc 0
out="$(inbox_new_bullets "$SESSION")"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "missing inbox: rc=0 silent"
else
    fail "missing inbox: rc=0 silent (rc=$rc out='$out')"
fi

# Case 2: one bullet appended -> delivered once
printf -- '- 09:00 first ruling\n' >> "$INBOX"
out="$(inbox_new_bullets "$SESSION")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF 'first ruling'; then
    pass "new bullet: injected"
else
    fail "new bullet: injected (rc=$rc out='$out')"
fi

# Case 3 (RED control): calling again with no new content -> nothing
out="$(inbox_new_bullets "$SESSION")"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "second call with no new content: nothing delivered (RED control)"
else
    fail "second call with no new content: nothing delivered (rc=$rc out='$out')"
fi

# Case 4: cursor survives "restart" (a fresh subshell re-reading the same
# cursor file from disk, not an in-memory value)
printf -- '- 09:05 second ruling\n' >> "$INBOX"
out="$(bash -c '. "$1/scripts/lib/handover-path.sh"; . "$1/scripts/lib/claudex-inbox.sh"; inbox_new_bullets "$2"' _ "$REPO_ROOT" "$SESSION")"
if printf '%s' "$out" | grep -qF 'second ruling' && ! printf '%s' "$out" | grep -qF 'first ruling'; then
    pass "cursor persists across process restart: only the new bullet delivered"
else
    fail "cursor persists across process restart (out='$out')"
fi

# --- claudex-inbox-hook.sh end-to-end (PostToolUse / JSON contract) --------

run_hook() { # <hook-script>
    CLAUDE_PROJECT_DIR="$REPO_ROOT" CLAUDE_PID=12345 \
        SESSION_NAME_CMDLINE_FILE="$CMDLINE_FILE" HANDOVER_DIR="$HANDOVER_DIR" \
        bash "$1"
}

CMDLINE_FILE="$WORK/cmdline"
printf 'claude\0--model\0claude-sonnet-5\0-n\0%s\0load\0doc.md\0' "$SESSION" > "$CMDLINE_FILE"

if command -v jq >/dev/null 2>&1; then
    printf -- '- 09:10 third ruling\n' >> "$INBOX"

    out="$(run_hook "$REPO_ROOT/scripts/hooks/claudex-inbox-hook.sh")"
    ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
    if printf '%s' "$ctx" | grep -qF 'third ruling'; then
        pass "claudex-inbox-hook.sh: delivers as hookSpecificOutput.additionalContext"
    else
        fail "claudex-inbox-hook.sh: delivers as hookSpecificOutput.additionalContext (out='$out')"
    fi

    # RED control: second run, nothing new -> silent, empty stdout
    out2="$(run_hook "$REPO_ROOT/scripts/hooks/claudex-inbox-hook.sh")"
    if [ -z "$out2" ]; then
        pass "claudex-inbox-hook.sh: second run with no new content is silent (RED control)"
    else
        fail "claudex-inbox-hook.sh: second run with no new content is silent (out='$out2')"
    fi
else
    fail "jq not available — cannot exercise claudex-inbox-hook.sh's JSON contract"
fi

# missing inbox (fresh unknown session name) -> rc 0, no stdout
CMDLINE_FILE2="$WORK/cmdline-unknown"
printf 'claude\0-n\0HIMMEL-2788-no-such-session\0' > "$CMDLINE_FILE2"
out="$(CLAUDE_PROJECT_DIR="$REPO_ROOT" CLAUDE_PID=12345 SESSION_NAME_CMDLINE_FILE="$CMDLINE_FILE2" \
    HANDOVER_DIR="$HANDOVER_DIR" bash "$REPO_ROOT/scripts/hooks/claudex-inbox-hook.sh")"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "claudex-inbox-hook.sh: missing inbox -> rc 0 silent"
else
    fail "claudex-inbox-hook.sh: missing inbox -> rc 0 silent (rc=$rc out='$out')"
fi

# bad (traversal-shaped) session name -> refused, rc 0, no stdout
CMDLINE_FILE3="$WORK/cmdline-bad"
printf 'claude\0-n\0../../etc/passwd\0' > "$CMDLINE_FILE3"
out="$(CLAUDE_PROJECT_DIR="$REPO_ROOT" CLAUDE_PID=12345 SESSION_NAME_CMDLINE_FILE="$CMDLINE_FILE3" \
    HANDOVER_DIR="$HANDOVER_DIR" bash "$REPO_ROOT/scripts/hooks/claudex-inbox-hook.sh")"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "claudex-inbox-hook.sh: traversal-shaped session name refused"
else
    fail "claudex-inbox-hook.sh: traversal-shaped session name refused (rc=$rc out='$out')"
fi

# --- claudex-inbox-sessionstart.sh (SessionStart / plain-text contract) ----

# Fresh session + fresh bullet so this is independent of the PostToolUse runs
# above (same cursor file would otherwise already be caught up).
SESSION2="HIMMEL-2788-test-leg-sessionstart"
INBOX2="$HANDOVER_DIR/inbox/$SESSION2.md"
printf -- '- 09:15 sessionstart ruling\n' >> "$INBOX2"
CMDLINE_FILE4="$WORK/cmdline-ss"
printf 'claude\0-n\0%s\0' "$SESSION2" > "$CMDLINE_FILE4"
out="$(CLAUDE_PROJECT_DIR="$REPO_ROOT" CLAUDE_PID=12345 SESSION_NAME_CMDLINE_FILE="$CMDLINE_FILE4" \
    HANDOVER_DIR="$HANDOVER_DIR" bash "$REPO_ROOT/scripts/hooks/claudex-inbox-sessionstart.sh")"
if printf '%s' "$out" | grep -qF 'sessionstart ruling' && ! printf '%s' "$out" | grep -q '{'; then
    pass "claudex-inbox-sessionstart.sh: plain-text delivery, no JSON envelope"
else
    fail "claudex-inbox-sessionstart.sh: plain-text delivery, no JSON envelope (out='$out')"
fi

# Shared cursor: PostToolUse hook run right after -> nothing left to deliver
CMDLINE_FILE="$CMDLINE_FILE4"
out2="$(run_hook "$REPO_ROOT/scripts/hooks/claudex-inbox-hook.sh")"
if [ -z "$out2" ]; then
    pass "shared cursor: PostToolUse hook delivers nothing after SessionStart already consumed it"
else
    fail "shared cursor: PostToolUse hook delivers nothing after SessionStart already consumed it (out='$out2')"
fi

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "SOME FAILED"; exit 1
