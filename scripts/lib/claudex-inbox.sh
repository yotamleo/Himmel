#!/usr/bin/env bash
# claudex-inbox.sh — cursor bookkeeping shared by the two claudex-inbox hook
# scripts (PostToolUse and the SessionStart mirror) and exercised directly by
# scripts/hooks/test-inbox-hook.sh (HIMMEL-2788).
#
# PLATFORM GUARD: no .ps1 twin, by design — the claudex lane is Linux-only.
# Source scripts/lib/handover-path.sh before this file for handover_root().
#
# Delivery transaction (HIMMEL-2790/2791): inbox_with_lock holds a session-keyed
# flock across peek, caller delivery, and commit. Call peek in the SAME shell,
# not command substitution: it sets inbox_bullets and a pending cursor without
# writing it. Commit only after successful serialization/stdout. The legacy
# inbox_new_bullets entry point follows the same contract for raw stdout.
# Missing flock retains unlocked delivery; other lock failures leave pending
# content untouched. Hooks remain fail-open. Absent inboxes need no lock.
#
# RETASK model (docs/internals/retask-channel.md): paths come ONLY from
# handover_root() + a validated session name, never from reviewed repo content.
inbox_with_lock() (
    local name="$1" root cursor_dir
    shift
    case "$name" in ''|*/*|*..*|*[[:space:]]*) return 0 ;; esac
    root="$(handover_root 2>/dev/null)" || return 0
    [ -n "$root" ] && [ -f "$root/inbox/$name.md" ] || return 0
    cursor_dir="$root/inbox/.cursor"
    mkdir -p "$cursor_dir" 2>/dev/null || return 0
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$cursor_dir/$name.lock" || return 0
        flock -x 9 || return 0
    fi
    # The subshell owns descriptor 9, so every exit releases the lock.
    "$@" "$name"
)

inbox_peek() {
    local name="$1" root inbox size cursor
    inbox_bullets=""
    inbox_cursor_file=""
    inbox_cursor_size=""
    root="$(handover_root 2>/dev/null)" || return 1
    inbox="$root/inbox/$name.md"
    size="$(wc -c < "$inbox" 2>/dev/null | tr -d '[:space:]')"
    case "$size" in ''|*[!0-9]*) return 1 ;; esac
    inbox_cursor_file="$root/inbox/.cursor/$name"
    cursor=0
    if [ -f "$inbox_cursor_file" ]; then
        cursor="$(cat "$inbox_cursor_file" 2>/dev/null)"
        case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
    fi
    [ "$size" -ne "$cursor" ] || return 0
    inbox_cursor_size="$size"
    # Rotation/corruption: resync without replaying stale rulings.
    [ "$size" -gt "$cursor" ] || return 0
    # Bound to the snapshot, keeping concurrent appends for the next call.
    # Read the prefix first so a large delta cannot SIGPIPE an upstream tail.
    # 10# forces base-10: a leading-zero value (e.g. "08") in a corrupted or
    # hand-recovered cursor file would otherwise be misparsed as an invalid
    # octal literal and abort delivery (CodeRabbit, HIMMEL-2790).
    inbox_bullets="$(head -c "$size" "$inbox" 2>/dev/null | tail -c "$((10#$size - 10#$cursor))")" || return 1
}

inbox_commit() {
    [ -n "$inbox_cursor_size" ] || return 0
    local tmp
    tmp="$(mktemp "$inbox_cursor_file.tmp.XXXXXX")" || return 1
    if printf '%s\n' "$inbox_cursor_size" > "$tmp" && mv -f "$tmp" "$inbox_cursor_file"; then
        inbox_cursor_size=""
    else
        rm -f "$tmp"
        return 1
    fi
}

inbox_deliver_stdout() {
    inbox_peek "$1" || return 1
    if [ -n "$inbox_bullets" ]; then
        printf '%s\n' "$inbox_bullets" || return 1
    fi
    inbox_commit
}

inbox_new_bullets() {
    inbox_with_lock "$1" inbox_deliver_stdout
    return 0
}
