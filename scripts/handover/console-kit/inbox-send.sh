#!/usr/bin/env bash
# inbox-send.sh — console-side write for the claudex file inbox (HIMMEL-2788).
#
# PLATFORM GUARD: no .ps1 twin, by design, not oversight. The claudex lane
# (scripts/claude-codex, konsole + /proc/$CLAUDE_PID/cmdline session-name
# recovery) is Linux-only; this sender has no Windows-side consumer to serve.
#
# Appends one ruling bullet to <handover root>/inbox/<session-name>.md, which
# scripts/hooks/claudex-inbox-hook.sh (PostToolUse) and
# scripts/hooks/claudex-inbox-sessionstart.sh (SessionStart mirror) deliver to
# the named leg as additionalContext — no ListAgents/SendMessage, no operator
# paste. --doc additionally mirrors the same bullet under the leg's
# "## Console Rulings (newest at the bottom)" section, which stays the durable
# record; the inbox is delivery only.
#
# RETASK model (docs/internals/retask-channel.md): hookSpecificOutput.
# additionalContext is system-controlled, not a tool result, and the inbox
# lives in the operator's state repo, not the reviewed tree — so a bullet
# carrying the echoed RETASK token counts as a direct message for
# EXPANSION/REDIRECT; narrowing/halt needs no token (fail-safe, unchanged).
#
# Append-only: this script only ever appends one line to <inbox>; it never
# rewrites or truncates it (the cursor file, not the inbox, tracks delivery).
#
# Usage:
#   inbox-send.sh <session-name> <text> [--token <retask-token>] [--doc <path>]
#   inbox-send.sh <session-name> --file <path> [--token <retask-token>] [--doc <path>]
#   inbox-send.sh --pending
#     Lists every inbox/*.md whose size exceeds its cursor — i.e. a ruling
#     the named leg has not yet consumed. Leg doc HIMMEL-2788 fact 7: "the
#     console tick can list inbox/*.md whose size > cursor" so an
#     undelivered ruling stays visible instead of silently waiting on the
#     leg's next tool call / resume.
#
# bash 3.2-safe, shellcheck-clean. Linux/konsole-only lane (claudex legs run
# on Linux today, same as headed-arm-leg.sh's sibling in this directory) — no
# .ps1 twin.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/handover-path.sh
. "$HERE/../../lib/handover-path.sh"

usage() {
    printf 'usage: inbox-send.sh <session-name> (<text> | --file <path>) [--token <token>] [--doc <handover-doc>]\n' >&2
    exit 2
}

[ "$#" -ge 1 ] || usage

if [ "$1" = "--pending" ]; then
    root="$(handover_root 2>/dev/null)" || { printf 'inbox-send: cannot resolve handover root\n' >&2; exit 2; }
    inbox_dir="$root/inbox"
    [ -d "$inbox_dir" ] || exit 0
    for f in "$inbox_dir"/*.md; do
        [ -e "$f" ] || continue
        base="$(basename "$f" .md)"
        size="$(wc -c < "$f" 2>/dev/null | tr -d '[:space:]')"
        case "$size" in ''|*[!0-9]*) continue ;; esac
        cursor=0
        cursor_file="$inbox_dir/.cursor/$base"
        if [ -f "$cursor_file" ]; then
            cursor="$(cat "$cursor_file" 2>/dev/null)"
            case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
        fi
        if [ "$size" -gt "$cursor" ]; then
            printf '%s (size=%s cursor=%s)\n' "$base" "$size" "$cursor"
        fi
    done
    exit 0
fi

session="$1"; shift

# Same validation as scripts/lib/session-name.sh's current_session_name — the
# inbox path is built from this value, so a traversal-shaped name is refused
# here too, not just on the read side.
case "$session" in
    ''|*/*|*..*|*[[:space:]]*)
        printf 'inbox-send: refusing session name %s (empty, or traversal/whitespace-unsafe)\n' "$session" >&2
        exit 2
        ;;
esac

text=""
token=""
doc=""
from_file=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --file)
            [ "$#" -ge 2 ] || usage
            from_file="$2"; shift 2 ;;
        --token)
            [ "$#" -ge 2 ] || usage
            token="$2"; shift 2 ;;
        --doc)
            [ "$#" -ge 2 ] || usage
            doc="$2"; shift 2 ;;
        --)
            shift
            [ "$#" -ge 1 ] && { [ -z "$text" ] || usage; text="$1"; shift; }
            ;;
        -*)
            usage ;;
        *)
            [ -z "$text" ] || usage
            text="$1"; shift ;;
    esac
done

if [ -n "$from_file" ]; then
    [ -z "$text" ] || usage
    [ -f "$from_file" ] || { printf 'inbox-send: no such file: %s\n' "$from_file" >&2; exit 2; }
    text="$(cat "$from_file")"
fi

[ -n "$text" ] || usage

root="$(handover_root_ensure)" || { printf 'inbox-send: cannot resolve handover root\n' >&2; exit 2; }

# --doc is validated BEFORE the inbox append below: appending first and then
# failing on a missing/unwritable --doc target would report failure after the
# ruling was already delivered, and a naive retry would duplicate it.
[ -z "$doc" ] || [ -f "$doc" ] || { printf 'inbox-send: --doc target not found: %s\n' "$doc" >&2; exit 2; }

inbox_dir="$root/inbox"
mkdir -p "$inbox_dir" || exit 2
inbox="$inbox_dir/$session.md"

stamp="$(date +%H:%M)"
if [ -n "$token" ]; then
    bullet="- ${stamp} [${token}] ${text}"
else
    bullet="- ${stamp} ${text}"
fi

if [ -n "$doc" ]; then
    # All mirror writers use the canonical doc path as the lock key. Keep
    # lock artifacts outside the vault, in a private per-user temp directory.
    doc="$(realpath -e -- "$doc")" || exit 2
    lock_dir="${TMPDIR:-/tmp}/himmel-inbox-doc-$UID"
    # shellcheck disable=SC2174 # Only the final, per-user directory is ours.
    if ! mkdir -m 700 -p "$lock_dir" || [ -L "$lock_dir" ] || [ ! -O "$lock_dir" ]; then
        printf 'inbox-send: cannot secure doc lock directory\n' >&2
        exit 2
    fi
    # mkdir -m only sets the mode at creation; a pre-existing directory (from
    # an older run, or a looser umask) is accepted above but never
    # tightened. Chmod it explicitly every time (CodeRabbit, HIMMEL-2790).
    chmod 700 "$lock_dir" || { printf 'inbox-send: cannot secure doc lock directory\n' >&2; exit 2; }
    lock_key="$(printf '%s' "$doc" | sha256sum)" || exit 2
    lock_key="${lock_key%% *}"
    if ! { exec 9>"$lock_dir/$lock_key.lock"; } || ! flock -x 9; then
        printf 'inbox-send: cannot lock %s\n' "$doc" >&2
        exit 2
    fi
    if grep -q '^## Console Rulings' "$doc"; then
        # Insert as the LAST line of the FIRST "## Console Rulings" section:
        # right before the next "## " heading, or at EOF if none follows.
        tmp="$doc.tmp.$$"
        # bullet is passed via ENVIRON, not -v: awk's -v assignment processes
        # backslash escapes (\n, \t, \\...) in the value, which would mangle
        # arbitrary ruling text containing a literal backslash. ENVIRON is
        # populated straight from the process environment, so it round-trips
        # the bullet verbatim.
        if ! bullet="$bullet" awk '
            BEGIN { in_section = 0; inserted = 0; bullet = ENVIRON["bullet"] }
            /^## Console Rulings/ { if (!inserted) in_section = 1; print; next }
            in_section && /^## / {
                print bullet
                inserted = 1
                in_section = 0
                print
                next
            }
            { print }
            END { if (in_section && !inserted) print bullet }
        ' "$doc" > "$tmp"
        then
            rm -f "$tmp"
            printf 'inbox-send: failed to update %s\n' "$doc" >&2
            exit 2
        fi
        if ! mv -f "$tmp" "$doc"; then
            rm -f "$tmp"
            printf 'inbox-send: failed to update %s\n' "$doc" >&2
            exit 2
        fi
    else
        {
            printf '\n## Console Rulings (newest at the bottom)\n'
            printf '%s\n' "$bullet"
        } >> "$doc" || { printf 'inbox-send: failed to update %s\n' "$doc" >&2; exit 2; }
    fi
    exec 9>&-
fi

printf '%s\n' "$bullet" >> "$inbox" || exit 2

printf 'inbox-send: appended to %s\n' "$inbox"
