#!/usr/bin/env bash
# test-crystallize-note.sh — hermetic smoke tests for crystallize-note.sh
# (HIMMEL-576). A `claude` stub (CRYSTALLIZE_CLAUDE_BIN) keeps the suite offline:
# no real model call, no network, no billing.
#
# Run: bash scripts/luna/test-crystallize-note.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRYS="$SCRIPT_DIR/crystallize-note.sh"
STUB="$SCRIPT_DIR/../hooks/testdata/bin/claude-stub.sh"
[ -r "$CRYS" ] || { echo "FAIL: crystallize-note.sh not found"; exit 1; }
[ -r "$STUB" ] || { echo "FAIL: claude-stub.sh not found"; exit 1; }
chmod +x "$STUB" 2>/dev/null || true

FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

write_note() {
    # $1 = path
    cat > "$1" <<'EOF'
---
date: 2026-06-20T08:00:00Z
type: session
repo: himmel
branch: feat/x
worktree: /tmp/x
duration_minutes: 5
files_touched: 0
tags:
  - session
  - autocapture
ai-first: true
session_id: sess-abc
source: live
crystallized: false
crystallized_at:
---

Auto-captured session.

## Summary

_Transcript unavailable; auto-summary not generated._ (speculation)

## Decisions

_None._

## Files Touched

_None._

## Commands

```bash
```

## Follow-ups

_None._

## Raw Conversation

> [!note]- Raw conversation
> _Transcript unavailable._
EOF
}

identity_lines() { grep -E '^(date|session_id|repo|branch|worktree|source):' "$1"; }

# --- Case 1: success — sections filled, crystallized true, identity preserved --
SB="$(mktemp -d)"
NOTE="$SB/note.md"; TR="$SB/t.jsonl"
write_note "$NOTE"; printf '{}\n' > "$TR"
ID_BEFORE="$(identity_lines "$NOTE")"
ENVD="$SB/env.txt"
env CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_ENV_DUMP="$ENVD" \
    bash "$CRYS" "$NOTE" "$TR"
if grep -q '^crystallized: true$' "$NOTE"; then pass "success: crystallized: true set"; else fail "success: crystallized not flipped"; fi
if grep -q '_Crystallized by stub' "$NOTE"; then pass "success: Summary section rewritten"; else fail "success: Summary not rewritten"; fi
if grep -q '^crystallized_at: 2026-06-28T12:00:00Z$' "$NOTE"; then pass "success: crystallized_at set"; else fail "success: crystallized_at not set"; fi
if [ "$ID_BEFORE" = "$(identity_lines "$NOTE")" ]; then pass "success: identity frontmatter byte-stable"; else fail "success: identity frontmatter changed"; fi
if grep -q '^CLAUDE_END_SESSION_WIKI=0$' "$ENVD" 2>/dev/null; then pass "recursion-guard: CLAUDE_END_SESSION_WIKI=0 exported to claude"; else fail "recursion-guard: end-session-wiki env not set"; fi
if grep -q '^HIMMEL_WHERE_ARE_WE=0$' "$ENVD" 2>/dev/null; then pass "recursion-guard: HIMMEL_WHERE_ARE_WE=0 exported (HIMMEL-572 fold-in)"; else fail "recursion-guard: where-are-we env not set"; fi
rm -rf "$SB"

# --- Case 2: fail — note unchanged, crystallized stays false -----------------
SB="$(mktemp -d)"
NOTE="$SB/note.md"; TR="$SB/t.jsonl"
write_note "$NOTE"; printf '{}\n' > "$TR"
SHA_BEFORE="$( { sha256sum "$NOTE" 2>/dev/null || shasum -a 256 "$NOTE"; } | awk '{print $1}')"
env CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=fail CRYSTALLIZE_PID_DIR="$SB/pids" bash "$CRYS" "$NOTE" "$TR"
SHA_AFTER="$( { sha256sum "$NOTE" 2>/dev/null || shasum -a 256 "$NOTE"; } | awk '{print $1}')"
if [ "$SHA_BEFORE" = "$SHA_AFTER" ]; then pass "fail: note byte-unchanged"; else fail "fail: note was modified on claude failure"; fi
if grep -q '^crystallized: false$' "$NOTE"; then pass "fail: crystallized stays false"; else fail "fail: crystallized wrongly changed"; fi
rm -rf "$SB"

# --- Case 3: noop — note unchanged -------------------------------------------
SB="$(mktemp -d)"
NOTE="$SB/note.md"; TR="$SB/t.jsonl"
write_note "$NOTE"; printf '{}\n' > "$TR"
SHA_BEFORE="$( { sha256sum "$NOTE" 2>/dev/null || shasum -a 256 "$NOTE"; } | awk '{print $1}')"
env CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=noop CRYSTALLIZE_PID_DIR="$SB/pids" bash "$CRYS" "$NOTE" "$TR"
SHA_AFTER="$( { sha256sum "$NOTE" 2>/dev/null || shasum -a 256 "$NOTE"; } | awk '{print $1}')"
if [ "$SHA_BEFORE" = "$SHA_AFTER" ]; then pass "noop: note byte-unchanged"; else fail "noop: note modified on no-op"; fi
rm -rf "$SB"

# --- Case 4: claude absent — exit 0, note unchanged --------------------------
SB="$(mktemp -d)"
NOTE="$SB/note.md"; TR="$SB/t.jsonl"
write_note "$NOTE"; printf '{}\n' > "$TR"
SHA_BEFORE="$( { sha256sum "$NOTE" 2>/dev/null || shasum -a 256 "$NOTE"; } | awk '{print $1}')"
# Minimal PATH keeps coreutils/bash but excludes `claude` (installed in
# ~/.local/bin / AppData, never /usr/bin) so `command -v claude` resolves empty.
RC=0
env -u CRYSTALLIZE_CLAUDE_BIN PATH="/usr/bin:/bin" CRYSTALLIZE_PID_DIR="$SB/pids" bash "$CRYS" "$NOTE" "$TR" || RC=$?
SHA_AFTER="$( { sha256sum "$NOTE" 2>/dev/null || shasum -a 256 "$NOTE"; } | awk '{print $1}')"
if [ "$RC" = "0" ]; then pass "claude-absent: exits 0"; else fail "claude-absent: exit was $RC"; fi
if [ "$SHA_BEFORE" = "$SHA_AFTER" ]; then pass "claude-absent: note unchanged (mechanical stub stays)"; else fail "claude-absent: note modified"; fi
rm -rf "$SB"

# --- Case 5: concurrency cap — over cap, no spawn (T2.7) ----------------------
SB="$(mktemp -d)"
NOTE="$SB/note.md"; TR="$SB/t.jsonl"; PIDS="$SB/pids"; MARK="$SB/marker.txt"
write_note "$NOTE"; printf '{}\n' > "$TR"; mkdir -p "$PIDS"
# Seed >= MAX (2) live pidfiles using THIS test's own pid (kill -0 succeeds).
printf '%s' "$$" > "$PIDS/a.pid"; printf '%s' "$$" > "$PIDS/b.pid"
env CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$PIDS" CRYSTALLIZE_MARKER="$MARK" CRYSTALLIZE_MAX_CONCURRENCY=2 \
    bash "$CRYS" "$NOTE" "$TR"
if [ ! -s "$MARK" ]; then pass "cap: no claude spawned when at/over cap"; else fail "cap: claude spawned despite cap"; fi
if grep -q '^crystallized: false$' "$NOTE"; then pass "cap: note stays crystallized: false"; else fail "cap: note wrongly crystallized"; fi
rm -rf "$SB"

# --- Case 6: detach survival — child outlives a process-group kill (T2.5) -----
# The `slow` stub sleeps 1s BEFORE touching its marker. We launch the crystallizer
# detached (setsid / double-fork) inside a subshell, kill that subshell's process
# group well within the 1s window, then wait past it: a surviving (truly detached)
# child still writes the marker; a child that died with the group does not.
SB="$(mktemp -d)"
NOTE="$SB/note.md"; TR="$SB/t.jsonl"; MARK="$SB/marker.txt"; PIDS="$SB/pids"
write_note "$NOTE"; printf '{}\n' > "$TR"
(
    if command -v setsid >/dev/null 2>&1; then
        env CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=slow CRYSTALLIZE_MARKER="$MARK" CRYSTALLIZE_PID_DIR="$PIDS" \
            setsid bash "$CRYS" "$NOTE" "$TR" </dev/null >/dev/null 2>&1 &
    else
        ( env CRYSTALLIZE_CLAUDE_BIN="$STUB" STUB_MODE=slow CRYSTALLIZE_MARKER="$MARK" CRYSTALLIZE_PID_DIR="$PIDS" \
            bash "$CRYS" "$NOTE" "$TR" </dev/null >/dev/null 2>&1 & )
    fi
) &
subpid=$!
sleep 0.3
# Kill the launching subshell's process group (negative pid) — within the slow
# stub's 1s pre-marker window.
kill -- "-${subpid}" 2>/dev/null || kill "$subpid" 2>/dev/null || true
if [ -s "$MARK" ]; then fail "detach: marker already present before window (test invalid)"; fi
i=0; while [ ! -s "$MARK" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
if [ -s "$MARK" ]; then pass "detach: crystallizer survived the process-group kill"; else fail "detach: child died with the hook's process group"; fi
rm -rf "$SB"

if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "SOME FAILED"; exit 1
