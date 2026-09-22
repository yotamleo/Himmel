#!/usr/bin/env bash
# scripts/lib/merge-block-alert.sh — the ONE operator alert for "GitHub blocks
# this merge" (HIMMEL-3381).
#
# WHY: a merge/CI-watch path that GitHub blocks (a required check FAILED or never
# reported, a required review outstanding, a ruleset refusing) used to end in a
# generic exit and silence — or, worse, a retry. Every such path now fails fast
# and calls merge_block_alert ONCE, which prints one `MERGE-BLOCKED` line naming
# the rule and sends ONE Telegram DM to the operator through the existing bridge
# reply path (scripts/telegram/console-route.ts reply -> replyViaOutbox), so the
# alert lands in the same outbox every other bridge reply uses — no new session
# format.
#
#   merge_block_alert <owner/repo> <pr-number> <head-sha> <rule text...>
#
# Always returns 0. A delivery failure NEVER changes the caller's exit code: the
# alert is an addition to the verdict, not part of it.
#
# Dedupe: one DM per (repo, PR, head). The sentinel is created atomically
# (noclobber) BEFORE the send so two racing watchers cannot both send, and is
# removed again if the send fails so a later run may retry — the operator still
# receives at most one. A new head is a new PR state and alerts again.
#
# Seams (hermetic suites; a caller who can set these can already set PATH):
#   MERGE_BLOCK_ALERT_DIR   sentinel directory (default <git common dir>/himmel-merge-block-alert)
#   MERGE_BLOCK_ALERT_CMD   replaces the sender; called as `$CMD <chat_id> <text>`
#   TELEGRAM_ACCESS_PATH    access.json to read the operator id from (gate.ts's own override)
#
# Under HIMMEL_TEST_FIXTURE=1 the DEFAULT sender refuses unless BRIDGE_ROOT names
# a sandbox — a suite that reaches this by accident must not DM the operator
# (same guard restart-bridge.sh carries, HIMMEL-2551).
#
# ponytail: "operator" is access.json's first positive allowFrom entry, the same
# rule operatorChatId() in scripts/telegram/gate.ts applies; an access.json
# whose first entry is not the person to page gets that person paged.

_MBA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_mba_operator_chat() {
    local access="${TELEGRAM_ACCESS_PATH:-$HOME/.claude/channels/telegram/access.json}"
    [ -r "$access" ] && command -v jq >/dev/null 2>&1 || return 1
    jq -r '[.allowFrom[]? | tostring | select(test("^[1-9][0-9]*$"))] | first // empty' "$access" 2>/dev/null
}

_mba_send() {
    local chat="$1" text="$2"
    if [ -n "${MERGE_BLOCK_ALERT_CMD:-}" ]; then
        "$MERGE_BLOCK_ALERT_CMD" "$chat" "$text"
        return
    fi
    if [ "${HIMMEL_TEST_FIXTURE:-}" = "1" ] && [ -z "${BRIDGE_ROOT:-}" ]; then
        return 0
    fi
    command -v bun >/dev/null 2>&1 || return 1
    local tmo=""
    command -v timeout >/dev/null 2>&1 && tmo="timeout 30"
    # shellcheck disable=SC2086  # $tmo is deliberately word-split ("" or "timeout 30")
    $tmo bun "$_MBA_LIB_DIR/../telegram/console-route.ts" reply "$chat" "$text" >/dev/null 2>&1
}

merge_block_alert() {
    local repo="${1:-}" pr="${2:-}" head="${3:-}"
    shift 3 2>/dev/null || shift $#
    local rule="$*"
    local short="${head:0:12}"
    echo "MERGE-BLOCKED ${repo}#${pr} @${short:-unknown-head}: ${rule}" >&2

    case "$repo$pr$head" in *[!A-Za-z0-9._/-]*|'') return 0 ;; esac
    [ -n "$repo" ] && [ -n "$pr" ] && [ -n "$head" ] || return 0

    local dir="${MERGE_BLOCK_ALERT_DIR:-}"
    if [ -z "$dir" ]; then
        dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 0
        dir="$dir/himmel-merge-block-alert"
    fi
    mkdir -p "$dir" 2>/dev/null || return 0
    local key="${repo//\//_}__${pr}__${head}"
    # Atomic create: the loser of a race sees the file and stays silent.
    ( set -o noclobber; : > "$dir/$key" ) 2>/dev/null || return 0

    local chat
    chat=$(_mba_operator_chat) || chat=""
    if [ -z "$chat" ]; then
        rm -f "$dir/$key" 2>/dev/null
        echo "merge-block-alert: no operator chat id readable — DM not sent (the line above is the only alert)" >&2
        return 0
    fi
    if ! _mba_send "$chat" "MERGE-BLOCKED ${repo}#${pr} @${short}: ${rule}"; then
        rm -f "$dir/$key" 2>/dev/null
        echo "merge-block-alert: DM delivery failed — exit code unchanged" >&2
    fi
    return 0
}

# shellcheck source=./go-gate.sh
# shellcheck disable=SC1091
. "$_MBA_LIB_DIR/go-gate.sh" 2>/dev/null || console_leg() {
    case "$(printf '%s' "${HIMMEL_CONSOLE_LEG:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        ''|0|false|off|no) return 1 ;;
        *) return 0 ;;
    esac
}

# HIMMEL-3430: merge_watch_alert — the alert for a MID-WORK check-ci red (this
# leg's own CI watch, not an actual merge attempt). merge_block_alert above is
# unchanged and still called directly by merge-on-green.sh/pr-merge.sh for a
# genuinely refused merge, so those always DM the operator regardless of
# console context.
#
# When this leg is console-spawned (console_leg(), from go-gate.sh) AND its
# console's session name is known (HIMMEL_CONSOLE_NAME — unset today; the
# launcher export is HIMMEL-3435, a follow-up), the alert is appended to that
# console's own bridge inbox instead: the console is already watching the PR,
# so an operator page mid-work is a false alarm. No console name, or the
# console's inbox was never armed (routeToConsole's own rule in
# scripts/telegram/console-route.ts: append only to a file that already
# exists, never create one) -> falls through to merge_block_alert, i.e.
# today's behaviour, one operator DM.
#
#   merge_watch_alert <owner/repo> <pr-number> <head-sha> <rule text...>
#
# Always returns 0. Dedupe: a SEPARATE sentinel per (repo, PR, head) from
# merge_block_alert's own (suffixed .watch), so a console-routed watch alert
# never suppresses a later real merge-refusal operator DM for the same head,
# and vice versa.
#
# Seam: MERGE_WATCH_ALERT_BRIDGE_ROOT overrides BRIDGE_ROOT for the console
# inbox path only (hermetic suites; a caller who can set this can already set
# PATH).
_mba_console_inbox_path() {
    local root="$1" name="$2"
    [ -n "$name" ] || return 1
    case "$name" in
        *[/\\]*|*..*) return 1 ;;
        *[[:space:]]*) return 1 ;;
    esac
    printf '%s/consoles/%s.md' "$root" "$name"
}

# HIMMEL-3440: append $2 (no trailing newline) to file $1 ONLY if it already
# exists — an O_WRONLY|O_APPEND open with NO O_CREAT, so a route attempt
# against an inbox deleted moments earlier can never recreate it (a separate
# `[ -f ]` check followed by `>>` has a TOCTOU window: `>>` implies O_CREAT,
# so a deletion between the two silently recreates the file and reports
# delivery). Bash has no redirection operator that opens
# append-only-without-create (`>>` and `<>` both imply O_CREAT), so this
# shells out to node. No node found is treated the same as ENOENT: "not
# delivered". Mirrors bus.ts's appendIfExists(file, line): the newline is
# added HERE, not by the caller — a `line=$(printf ...)` capture already
# strips any trailing newline the caller embedded, so a caller-supplied
# newline can never survive the shell round-trip.
_mba_append_if_exists() {
    local file="$1" line="$2" node
    # shellcheck source=./resolve-node.sh
    # shellcheck disable=SC1091
    node=$(. "$_MBA_LIB_DIR/resolve-node.sh" 2>/dev/null && resolve_node) || return 1
    [ -n "$node" ] || return 1
    _MBA_APPEND_FILE="$file" _MBA_APPEND_LINE="$line" "$node" -e '
        const fs = require("fs");
        const file = process.env._MBA_APPEND_FILE;
        const line = process.env._MBA_APPEND_LINE;
        let fd;
        try {
            fd = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_APPEND);
        } catch (e) {
            process.exit(1);
        }
        try {
            fs.writeSync(fd, line + "\n");
        } finally {
            fs.closeSync(fd);
        }
    ' 2>/dev/null
}

# Mirrors scripts/telegram/console-route.ts's consoleInboxPath + routeToConsole
# (bash-native: this lib is sourced by plain-bash callers, not bun). The open
# itself is the existence check (see _mba_append_if_exists above) — there is
# no separate check-then-act step left to race.
_mba_route_console() {
    local repo="$1" pr="$2" name="$3" text="$4"
    local root file
    root="${MERGE_WATCH_ALERT_BRIDGE_ROOT:-${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}}"
    file=$(_mba_console_inbox_path "$root" "$name") || return 1
    local folded
    folded=$(printf '%s' "$text" | tr '\n' ' ')
    local line
    line=$(printf -- '- %s [merge-watch %s#%s] %s' "$(date +%H:%M)" "$repo" "$pr" "$folded")
    _mba_append_if_exists "$file" "$line"
}

merge_watch_alert() {
    local repo="${1:-}" pr="${2:-}" head="${3:-}"
    shift 3 2>/dev/null || shift $#
    local rule="$*"
    local short="${head:0:12}"

    case "$repo$pr$head" in *[!A-Za-z0-9._/-]*|'') merge_block_alert "$repo" "$pr" "$head" "$rule"; return 0 ;; esac
    if [ -z "$repo" ] || [ -z "$pr" ] || [ -z "$head" ]; then
        merge_block_alert "$repo" "$pr" "$head" "$rule"
        return 0
    fi

    if console_leg; then
        local dir key
        dir="${MERGE_BLOCK_ALERT_DIR:-}"
        if [ -z "$dir" ]; then
            dir=$(git rev-parse --git-common-dir 2>/dev/null) && dir="$dir/himmel-merge-block-alert"
        fi
        if [ -n "$dir" ] && mkdir -p "$dir" 2>/dev/null; then
            key="${repo//\//_}__${pr}__${head}.watch"
            if ( set -o noclobber; : > "$dir/$key" ) 2>/dev/null; then
                if _mba_route_console "$repo" "$pr" "${HIMMEL_CONSOLE_NAME:-}" "MERGE-BLOCKED ${repo}#${pr} @${short}: ${rule}"; then
                    echo "MERGE-BLOCKED ${repo}#${pr} @${short:-unknown-head}: ${rule}" >&2
                    return 0
                fi
                rm -f "$dir/$key" 2>/dev/null
            elif [ -e "$dir/$key" ]; then
                # Sentinel already exists: already alerted for this
                # (repo, pr, head) — dedup, stay silent (no fallback).
                echo "MERGE-BLOCKED ${repo}#${pr} @${short:-unknown-head}: ${rule}" >&2
                return 0
            fi
            # Sentinel create failed for a reason OTHER than already
            # existing (unwritable dir, disk full, ...): unknown alert
            # state, so fall through to merge_block_alert below rather
            # than silently dropping the alert.
        fi
    fi

    merge_block_alert "$repo" "$pr" "$head" "$rule"
    return 0
}
