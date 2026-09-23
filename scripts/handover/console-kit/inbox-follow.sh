#!/usr/bin/env bash
# inbox-follow.sh — HIMMEL-3356. Gap-free follow of a console's Telegram inbox.
#
#   inbox-follow.sh [--once|--peek] <inbox-file>
#
# The console armed `tail -n0 -F <inbox>` under a 30-min Monitor and re-armed it
# on expiry, so a line the bridge appended between the expiry and the re-arm was
# acked to the operator but never delivered. This keeps a byte-offset cursor
# next to the inbox (<inbox>.cursor): every arm first emits the unread tail from
# the cursor, then follows live, and the cursor advances after each emitted line.
# Nothing is lost, and a re-arm replays nothing.
#
# --once drains the unread tail and exits (no live follow).
# --peek delivers nothing and leaves the cursor alone: rc 0 when a complete
# unread line is waiting, rc 1 when not, rc 3 when the inbox cannot be read (HIMMEL-3509: console-wait.sh prints its
# WAKE header first, then lets --once stream, so no line's cursor moves before
# the line itself is out).
# INBOX_FOLLOW_POLL_SEC is the live poll interval (default 1s).
#
# Delivery is at-least-once: a line is emitted before its cursor advance, so a
# follower killed between the two replays that one line on the next arm — the
# operator's message is never the thing that gets dropped.
#
# A missing inbox is created empty (the bridge only writes to an inbox that
# already exists). A partial line (no newline yet) is held back until complete.
# A cursor beyond EOF (inbox truncated or replaced), a corrupt cursor file or a
# non-canonical one (leading zero: bash would read it as octal; 16+ digits:
# beyond shell integer range) resets to offset 0. A failed emit stops the
# follower before the cursor moves.
# A cursor that cannot be written stops the follower with rc 1 instead of
# replaying the same lines on every poll. So does a failed read of the inbox.
#
# ponytail: the cursor is a bare byte offset, so an inbox replaced by a file
# that is already LONGER than the old cursor is indistinguishable from an
# append — the reset only fires when the new file is shorter. The bridge only
# appends and the console never rotates the file, so this is a hand-edit hazard,
# not a normal path. Two followers armed on one inbox at once each emit every
# new line (the cursor is not locked); a re-arm follows an expiry, so they
# overlap only if the old Monitor's process outlives its expiry.
set -u
LC_ALL=C   # ${#line} must count bytes: the cursor is a byte offset
export LC_ALL

once=0; peek=0
case "${1:-}" in
    --once) once=1; shift ;;
    --peek) peek=1; shift ;;
esac
if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    echo "usage: inbox-follow.sh [--once|--peek] <inbox-file>" >&2
    exit 2
fi
inbox="$1"
cursor_file="$inbox.cursor"
poll="${INBOX_FOLLOW_POLL_SEC:-1}"

if ! mkdir -p "$(dirname "$inbox")" || ! : >> "$inbox"; then
    echo "inbox-follow: cannot create $inbox" >&2
    exit 1
fi

load_cursor() {
    cur=""
    [ -f "$cursor_file" ] && read -r cur < "$cursor_file"
    # 16+ digits overflow shell integer tests (a 15-digit offset is ~1 PB)
    case "$cur" in ''|*[!0-9]*|0?*|????????????????*) cur=0 ;; esac
}

save_cursor() {
    if ! { printf '%s\n' "$1" > "$cursor_file.tmp" && mv -f "$cursor_file.tmp" "$cursor_file"; }; then
        echo "inbox-follow: cannot write $cursor_file" >&2
        return 1
    fi
}

drain() {
    load_cursor
    size=$(( $(wc -c < "$inbox") ))
    if [ "$cur" -gt "$size" ]; then
        cur=0
        save_cursor 0 || return 1
    fi
    [ "$size" -gt "$cur" ] || return 0
    # `read` returns non-zero on a final line with no newline, so a partial line
    # never reaches the body and the cursor stays before it. pipefail: a pipeline
    # reports its last command, so a failed `tail` would otherwise look like an
    # empty drain (--once exiting 0 having delivered nothing).
    set -o pipefail
    tail -c +$((cur + 1)) "$inbox" | while IFS= read -r line; do
        printf '%s\n' "$line" || exit 1
        cur=$((cur + ${#line} + 1))
        save_cursor "$cur" || exit 1
    done || { echo "inbox-follow: cannot drain $inbox" >&2; return 1; }
}

if [ "$peek" = 1 ]; then
    load_cursor
    size=$(( $(wc -c < "$inbox") ))
    [ "$cur" -gt "$size" ] && cur=0
    # pipefail: a failed tail must not read as "nothing unread".
    set -o pipefail
    n="$(tail -c +$((cur + 1)) "$inbox" | tr -cd '\n' | wc -c)" \
        || { echo "inbox-follow: cannot read $inbox" >&2; exit 3; }
    [ "$((n))" -gt 0 ] && exit 0
    exit 1
fi

drain || exit 1
[ "$once" = 1 ] && exit 0
while :; do
    sleep "$poll"
    drain || exit 1
done
