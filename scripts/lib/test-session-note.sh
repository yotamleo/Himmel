#!/usr/bin/env bash
# test-session-note.sh — focused tests for render_session_note's Summary heuristic
# (HIMMEL-590 F2). The mechanical Summary must drop LEADING preamble/meta lines
# (system-reminder reactions, bare acknowledgments) without dropping substantive
# content once it begins. bash 3.2-safe. Run: bash scripts/lib/test-session-note.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/session-note.sh"
command -v render_session_note >/dev/null 2>&1 || { echo "FATAL: render_session_note not defined"; exit 2; }

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# Render with a given LAST_ASSISTANT and echo just the Summary section body.
summary_of() { # <last_assistant_text>
    REPO_NAME="r" BRANCH="b" WORKTREE_ABS="/w" FILES_COUNT=0 FILES_RAW="" \
    NOW_ISO="2026-06-20T08:00:00Z" DURATION_MINUTES=1 SESSION_ID="s" SOURCE="live" \
    TRANSCRIPT_READABLE=1 KEPT_COMMANDS="" LAST_ASSISTANT="$1" render_session_note \
        | awk '/^## Summary$/{f=1;next} f&&/^## /{exit} f&&NF{print}'
}

# --- Case 1: leading system-reminder reaction is dropped ---------------------
out="$(summary_of "I'll ignore the TaskCreate reminder for now.
Fixed the off-by-one in the parser.
Added a regression test.")"
if printf '%s' "$out" | grep -q 'Fixed the off-by-one'; then pass "F2: substantive line surfaced"; else fail "F2: substantive line missing"; fi
if printf '%s' "$out" | grep -qi 'TaskCreate reminder'; then fail "F2: preamble reminder line leaked into Summary"; else pass "F2: leading TaskCreate-reminder preamble dropped"; fi

# --- Case 1b: substantive LEADING lines naming ONE token survive --------------
# The drop requires `reminder` to CO-OCCUR with `TaskCreate` (or the literal
# `system-reminder` tag), so a real first line that merely names one token is not
# eaten — neither a bare "reminder" nor a bare "TaskCreate".
out="$(summary_of "Reminder banner shipped to prod.
Wired the cron job.")"
if printf '%s' "$out" | grep -q 'Reminder banner shipped'; then pass "F2: leading 'reminder'-only line kept"; else fail "F2: leading 'reminder'-only line wrongly dropped"; fi
out="$(summary_of "TaskCreate was wired into the job queue.
Added retries.")"
if printf '%s' "$out" | grep -q 'TaskCreate was wired'; then pass "F2: leading 'TaskCreate'-only line kept (gptoss-1)"; else fail "F2: leading 'TaskCreate'-only line wrongly dropped"; fi

# --- Case 1c: case-insensitive + trailing-whitespace ack drop (twin parity) ---
ack_line="OKAY.   "   # uppercase + trailing whitespace
out="$(summary_of "${ack_line}
Wired the webhook handler.")"
if [ "$(printf '%s\n' "$out" | head -n1)" = "Wired the webhook handler." ]; then pass "F2: uppercase ack w/ trailing space dropped (case-insensitive, ws-tolerant)"; else fail "F2: 'OKAY.   ' not dropped (twin-divergence regression)"; fi

# --- Case 2: bare acknowledgment dropped, content kept -----------------------
out="$(summary_of "Sure.
Implemented the cache layer and wired it into the resolver.")"
if printf '%s' "$out" | grep -q 'Implemented the cache layer'; then pass "F2: content after bare-ack kept"; else fail "F2: content after bare-ack dropped"; fi
first="$(printf '%s\n' "$out" | head -n1)"
if [ "$first" = "Sure." ]; then fail "F2: bare 'Sure.' leaked as first line"; else pass "F2: bare acknowledgment dropped"; fi

# --- Case 3: a substantive line containing 'reminder' AFTER content is kept --
# Only LEADING meta is skipped; once content begins, nothing is dropped.
out="$(summary_of "Refactored the scheduler.
Added a reminder banner to the UI.")"
if printf '%s' "$out" | grep -q 'reminder banner'; then pass "F2: non-leading 'reminder' line preserved"; else fail "F2: wrongly dropped a substantive 'reminder' line"; fi

# --- Case 4: all-preamble turn falls back honestly (no false content) --------
out="$(summary_of "Sure.
Okay.")"
if printf '%s' "$out" | grep -q 'Transcript unavailable; auto-summary not generated'; then pass "F2: all-preamble turn falls back to honest unavailable"; else fail "F2: all-preamble produced bogus summary"; fi

# --- Case 5: a clean turn (no preamble) is unchanged (golden-stability) -------
out="$(summary_of "Implemented the session-transcript and session-note libs.
Extracted parsing into scripts/lib/session-transcript.sh.")"
if [ "$(printf '%s\n' "$out" | head -n1)" = "Implemented the session-transcript and session-note libs." ]; then pass "F2: clean turn unchanged (first line preserved)"; else fail "F2: clean turn altered"; fi

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "SOME FAILED"; exit 1
