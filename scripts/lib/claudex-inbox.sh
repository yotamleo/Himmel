#!/usr/bin/env bash
# claudex-inbox.sh — cursor bookkeeping shared by the two claudex-inbox hook
# scripts (PostToolUse and the SessionStart mirror) and exercised directly by
# scripts/hooks/test-inbox-hook.sh (HIMMEL-2788).
#
# PLATFORM GUARD: no .ps1 twin, by design, not oversight — the claudex lane
# this serves is Linux-only (see scripts/lib/session-name.sh's header).
#
# Source scripts/lib/handover-path.sh before this file — inbox_new_bullets
# calls handover_root(), which it does not itself source (callers already
# need it wired for other reasons, and sourcing it twice is harmless but this
# keeps the dependency explicit rather than silently re-sourcing).
#
# Cost model (HIMMEL-2767): this hook runs on every tool call in every
# session, native ones included. The no-op path (inbox absent, or present but
# not grown since the last cursor) is a handful of `[ -f ]` tests plus one
# `wc -c` (an O(1) seek on a regular file, not a full read) — no jq, no
# subshell fork beyond what POSIX test/wc already cost. jq is only invoked by
# the CALLER, and only once real new content exists to format.
#
# RETASK model (docs/internals/retask-channel.md): the inbox path is built
# ONLY from handover_root() + a validated session name — never from repo
# content — so this function cannot be tricked into reading a path an
# attacker-controlled file suggested.
inbox_new_bullets() {
    local name="$1"
    local root inbox cursor_dir cursor_file size cursor delta

    root="$(handover_root 2>/dev/null)" || return 0
    [ -n "$root" ] || return 0

    inbox="$root/inbox/$name.md"
    [ -f "$inbox" ] || return 0

    size="$(wc -c < "$inbox" 2>/dev/null | tr -d '[:space:]')"
    case "$size" in ''|*[!0-9]*) return 0 ;; esac

    cursor_dir="$root/inbox/.cursor"
    cursor_file="$cursor_dir/$name"

    cursor=0
    if [ -f "$cursor_file" ]; then
        cursor="$(cat "$cursor_file" 2>/dev/null)"
        case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
    fi

    # Append-only inbox: cursor > size should never happen. If it does
    # (rotation, corruption), resync to the current size rather than
    # re-injecting or erroring — the safe direction is "miss a ruling", never
    # "replay stale ones on every call".
    if [ "$cursor" -gt "$size" ]; then
        cursor="$size"
        mkdir -p "$cursor_dir" 2>/dev/null
        local resync_tmp="$cursor_file.tmp.$$"
        if printf '%s\n' "$cursor" > "$resync_tmp" 2>/dev/null; then
            mv -f "$resync_tmp" "$cursor_file" 2>/dev/null || rm -f "$resync_tmp" 2>/dev/null
        fi
    fi

    [ "$size" -gt "$cursor" ] || return 0

    # Bounded to the SNAPSHOTTED size, not to the file's current EOF: an
    # unbounded tail would pick up a concurrent inbox-send.sh append made
    # between the wc -c above and this read, deliver it now, then still set
    # the cursor to the old (smaller) size below -- so the next call would
    # deliver that same content a second time. Bounding the read here means
    # a late append is simply left for the NEXT call, never double-delivered.
    delta="$(tail -c "+$((cursor + 1))" "$inbox" 2>/dev/null | head -c "$((size - cursor))")"

    mkdir -p "$cursor_dir" 2>/dev/null || return 0
    local tmp="$cursor_file.tmp.$$"
    if printf '%s\n' "$size" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$cursor_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    fi

    # Passed through raw, unfiltered: inbox-send.sh's --file mode writes a
    # single multi-line bullet as one printf (embedded newlines included), so
    # a "^- " filter here would keep only the first line and silently drop
    # every continuation line -- data loss the caller can never recover,
    # since the cursor above has already moved past it. The size-bounded read
    # right above is what protects against a truncated fragment now (a
    # concurrent append is left for the next call, not read mid-write).
    printf '%s\n' "$delta"
    return 0
}
