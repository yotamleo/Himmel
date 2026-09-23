#!/usr/bin/env bash
# test-inbox-follow.sh — HIMMEL-3356. Exercises inbox-follow.sh, the gap-free
# follower for a console's Telegram inbox: an unread tail is emitted from a
# persisted byte-offset cursor before following live, a re-arm replays nothing,
# a truncated/rotated inbox resets the cursor, a partial line waits for its
# newline. bash 3.2-safe.
#
# INBOX_FOLLOW overrides the script under test (used once, to show the plain
# `tail -n0 -F` shape fails cases (a)/(b) — the RED control).
#
# Run: bash scripts/handover/console-kit/test-inbox-follow.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FOLLOW="${INBOX_FOLLOW:-$HERE/inbox-follow.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/inbox-follow-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

export INBOX_FOLLOW_POLL_SEC=0.2

# arm <inbox>: one arm that drains the unread tail and exits.
arm() { bash "$FOLLOW" --once "$1" 2>&1; }
size_of() { wc -c < "$1" | tr -d ' '; }

# --- (a) a line appended while no follower runs is delivered by the next arm --
I="$WORK/a/consoles/c.md"
mkdir -p "$WORK/a/consoles"; : > "$I"
printf 'one\n' >> "$I"
out="$(arm "$I")"
check "(a) first arm delivers what is already in the inbox" "one" "$out"
printf 'two\nthree\n' >> "$I"
out="$(arm "$I")"
check "(a) lines appended between arms are delivered by the next arm" "$(printf 'two\nthree')" "$out"

# --- (b) a re-arm does not replay already-delivered lines --------------------
out="$(arm "$I")"
check "(b) a re-arm with nothing new emits nothing" "" "$out"
check "(b) the cursor sits at the inbox size" "$(size_of "$I")" "$(tr -d ' \n' < "$I.cursor")"

# --- (b2) a multi-byte line (foldLine's U+23CE) advances the cursor by BYTES --
I="$WORK/b2/consoles/c.md"
mkdir -p "$WORK/b2/consoles"; : > "$I"
printf -- '- 09:00 [telegram from=1 chat=2] a ⏎ b\nnext\n' >> "$I"
out="$(arm "$I")"
check "(b2) multi-byte line and its successor are both delivered" "$(printf -- '- 09:00 [telegram from=1 chat=2] a ⏎ b\nnext')" "$out"
check "(b2) multi-byte cursor is a byte offset, so the re-arm replays nothing" "" "$(arm "$I")"

# --- (c) a truncated or rotated inbox resets the cursor safely ---------------
I="$WORK/c/consoles/c.md"
mkdir -p "$WORK/c/consoles"; : > "$I"
printf 'long line number one\nlong line number two\n' >> "$I"
arm "$I" >/dev/null
: > "$I"
printf 'fresh\n' >> "$I"
out="$(arm "$I")"; rc=$?
check "(c) a truncated inbox (cursor beyond EOF) is re-read from the start" "fresh" "$out"
check "(c) a truncated inbox does not crash the follower" "0" "$rc"
rm -f "$I"; : > "$I"; printf 'new\n' >> "$I"
check "(c) a rotated (replaced, shorter) inbox is re-read from the start" "new" "$(arm "$I")"
printf 'not-a-number\n' > "$I.cursor"
check "(c) a corrupt cursor file is treated as offset 0" "new" "$(arm "$I")"

# --- (d) a partial line with no newline yet is not emitted -------------------
I="$WORK/d/consoles/c.md"
mkdir -p "$WORK/d/consoles"; : > "$I"
printf 'whole\nhal' >> "$I"
out="$(arm "$I")"
check "(d) only the complete line is emitted" "whole" "$out"
check "(d) re-arm before the newline still emits nothing" "" "$(arm "$I")"
printf 'f done\n' >> "$I"
check "(d) the line is emitted once complete" "half done" "$(arm "$I")"

# --- (e) an absent inbox is created, so the bridge will write to it ----------
I="$WORK/e/consoles/c.md"
out="$(arm "$I")"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$I" ]; then pass "(e) an absent inbox is created empty"; else fail "(e) an absent inbox is created empty (rc=$rc)"; fi

# --- (f) live follow: unread tail first, then new lines as they land ---------
I="$WORK/f/consoles/c.md"
OUT="$WORK/f/out"
mkdir -p "$WORK/f/consoles"; : > "$I"
printf 'backlog\n' >> "$I"
bash "$FOLLOW" "$I" > "$OUT" 2>&1 &
pid=$!
# The live line must land AFTER the initial drain, or a dead poll loop still passes.
i=0
while [ "$i" -lt 50 ]; do
    [ -s "$I.cursor" ] && break
    sleep 0.1; i=$((i + 1))
done
printf 'live\n' >> "$I"
# The follower emits BEFORE it writes the cursor, so two lines in $OUT does not mean
# the cursor moved: kill only once the cursor has caught up with the inbox.
i=0
while [ "$i" -lt 50 ]; do
    [ "$(tr -d ' \n' < "$I.cursor")" = "$(size_of "$I")" ] && break
    sleep 0.1; i=$((i + 1))
done
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
check "(f) a live follower emits the backlog then the new line, once each" "$(printf 'backlog\nlive')" "$(cat "$OUT")"
check "(f) the live follower advanced the cursor to the inbox size" "$(size_of "$I")" "$(tr -d ' \n' < "$I.cursor")"
check "(f) a re-arm after the live follower was killed replays nothing" "" "$(arm "$I")"

# --- (h) a cursor that cannot be written stops the follower, it never replays -
I="$WORK/h/consoles/c.md"
mkdir -p "$WORK/h/consoles" "$I.cursor.tmp"; : > "$I"
printf 'one\n' >> "$I"
out="$(arm "$I")"; rc=$?
if [ "$rc" -ne 0 ]; then pass "(h) --once fails (rc $rc) when the cursor cannot be written"; else fail "(h) --once fails when the cursor cannot be written (rc=0)"; fi
bash "$FOLLOW" "$I" > "$WORK/h/out" 2>&1 &
pid=$!
i=0
while [ "$i" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$pid" 2>/dev/null; then
    fail "(h) a live follower stops when the cursor cannot be written (still running: replay loop)"
    kill "$pid" 2>/dev/null
else
    pass "(h) a live follower stops when the cursor cannot be written"
fi
wait "$pid" 2>/dev/null

# --- (i) a leading-zero cursor is reset, not read as octal -------------------
I="$WORK/i/consoles/c.md"
mkdir -p "$WORK/i/consoles"; : > "$I"
printf 'alpha\nbeta\n' >> "$I"
printf '08\n' > "$I.cursor"
out="$(arm "$I")"; rc=$?
check "(i) a leading-zero cursor is treated as offset 0" "$(printf 'alpha\nbeta')" "$out"
check "(i) a leading-zero cursor does not crash the follower" "0" "$rc"

# --- (j) an oversized cursor is reset, not compared as an overflowed integer --
I="$WORK/j/consoles/c.md"
mkdir -p "$WORK/j/consoles"; : > "$I"
printf 'alpha\nbeta\n' >> "$I"
printf '99999999999999999999\n' > "$I.cursor"
check "(j) a 20-digit cursor is treated as offset 0" "$(printf 'alpha\nbeta')" "$(arm "$I")"

# --- (k) a failed emit stops the follower before the cursor moves ------------
if [ -w /dev/full ]; then
    I="$WORK/k/consoles/c.md"
    mkdir -p "$WORK/k/consoles"; : > "$I"
    printf 'keep\n' >> "$I"
    bash "$FOLLOW" --once "$I" > /dev/full 2>/dev/null; rc=$?
    if [ "$rc" -ne 0 ]; then pass "(k) a failed emit exits non-zero (rc $rc)"; else fail "(k) a failed emit exits non-zero (rc=0)"; fi
    check "(k) the undelivered line is still unread on the next arm" "keep" "$(arm "$I")"
else
    pass "(k) skipped: /dev/full not available on this host"
fi

# --- (l) a failing tail is a visible failure, not an empty --once drain -------
# HIMMEL-3370: `tail | while read` reports the loop's status, so a tail that failed
# (inbox vanished, unreadable) delivered nothing and still exited 0.
I="$WORK/l/consoles/c.md"
mkdir -p "$WORK/l/consoles" "$WORK/l/bin"; : > "$I"
printf 'unread\n' >> "$I"
printf '#!/bin/sh\nexit 1\n' > "$WORK/l/bin/tail"; chmod +x "$WORK/l/bin/tail"
out="$(PATH="$WORK/l/bin:$PATH" bash "$FOLLOW" --once "$I" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then pass "(l) --once fails (rc $rc) when tail fails"; else fail "(l) --once fails when tail fails (rc=0, out='$out')"; fi
case "$out" in *"inbox-follow:"*) pass "(l) the tail failure is reported on stderr" ;; *) fail "(l) the tail failure is reported on stderr (out='$out')" ;; esac
check "(l) the unread line is still unread once tail works again" "unread" "$(arm "$I")"

# --- (m) --peek: rc 0 only for a complete unread line, cursor untouched -------
# HIMMEL-3509: console-wait.sh peeks, prints its WAKE header, then lets --once
# stream the lines, so every line is emitted before its cursor moves.
I="$WORK/m/consoles/c.md"
mkdir -p "$WORK/m/consoles"; : > "$I"
bash "$FOLLOW" --peek "$I" 2>/dev/null; rc=$?
check "(m) --peek on an empty inbox is rc 1" "1" "$rc"
printf 'half' >> "$I"
bash "$FOLLOW" --peek "$I" 2>/dev/null; rc=$?
check "(m) --peek on a partial line only is rc 1" "1" "$rc"
printf ' line\n' >> "$I"
bash "$FOLLOW" --peek "$I" 2>/dev/null; rc=$?
check "(m) --peek on a complete unread line is rc 0" "0" "$rc"
check "(m) --peek does not deliver or advance the cursor" "half line" "$(arm "$I")"
bash "$FOLLOW" --peek "$I" 2>/dev/null; rc=$?
check "(m) --peek after the line was delivered is rc 1" "1" "$rc"

# --- (g) usage ---------------------------------------------------------------
bash "$FOLLOW" >/dev/null 2>&1; rc=$?
check "(g) no argument is a usage error (rc 2)" "2" "$rc"

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-inbox-follow.sh'
    exit 0
fi
printf 'FAIL - test-inbox-follow.sh (%s failure(s))\n' "$fails"
exit 1
