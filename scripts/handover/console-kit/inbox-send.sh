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
# Exit 3 (HIMMEL-2975): --token refused — either the caller is a console
# relay (HIMMEL_CONSOLE_RELAY is set; only the judge sends token-quoting
# bullets) or the sending session name cannot be resolved (no CLAUDE_PID /
# -n). Nothing is written in either case. A no-token bullet always carries
# from=<sender session>, falling back to from=unknown, and is never refused
# on this account.
#
# Exit 4 (HIMMEL-2980): the inbox append succeeded and the token bullet was
# delivered, but the judge-side sent-record ledger write that follows it
# failed (cannot secure/create the per-sender ledger directory, or cannot
# write the ledger line). The message is delivered either way — this is not
# a retry cue, it is the detection gap itself: scripts/handover/console-kit/
# inbox-audit.sh will name this bullet as UNMATCHED on the next per-shift
# audit, same as a genuinely forged one.
#
# bash 3.2-safe, shellcheck-clean. Linux/konsole-only lane (claudex legs run
# on Linux today, same as headed-arm-leg.sh's sibling in this directory) — no
# .ps1 twin.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/handover-path.sh
. "$HERE/../../lib/handover-path.sh"
# shellcheck source=../../lib/session-name.sh
. "$HERE/../../lib/session-name.sh"

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

author="$(current_session_name 2>/dev/null)" || author=""
case "$(printf '%s' "${HIMMEL_CONSOLE_RELAY:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    ''|0|false|off|no) is_relay=0 ;;
    *) is_relay=1 ;;
esac
stamp="$(date +%H:%M)"
if [ -n "$token" ]; then
    if [ "$is_relay" -eq 1 ]; then
        printf 'inbox-send: refusing --token from a console relay (HIMMEL-2975: only the judge sends token-quoting messages)\n' >&2
        exit 3
    fi
    if [ -z "$author" ]; then
        printf 'inbox-send: refusing --token: cannot resolve the sending session name (no CLAUDE_PID / -n)\n' >&2
        exit 3
    fi
    bullet="- ${stamp} [${token}] from=${author} ${text}"
else
    bullet="- ${stamp} from=${author:-unknown} ${text}"
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

# HIMMEL-2980: record every token bullet in a per-sender sent-record ledger,
# so a per-shift audit (inbox-audit.sh) can name any token bullet in an
# inbox that has no matching record — i.e. one this script never sent. Only
# for token bullets: a no-token bullet carries no RETASK authority to forge,
# so there is nothing here worth recording. Runs AFTER the inbox append
# above: a ledger failure must never block delivery of a bullet the judge
# already committed to sending (see exit 4 above).
if [ -n "$token" ]; then
    ledger_base="${HIMMEL_CONSOLE_RUNDIR:-}"
    if [ -z "$ledger_base" ]; then
        # Same per-uid convention as console.sh (scripts/handover/console/
        # console.sh lines 18-19, 430-440): prefer a systemd-provided,
        # already-owned XDG_RUNTIME_DIR, else the uid-qualified /tmp path.
        if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ -O "$XDG_RUNTIME_DIR" ]; then
            ledger_base="$XDG_RUNTIME_DIR/himmel-console"
        else
            ledger_base="${TMPDIR:-/tmp}/himmel-console-$(id -u)"
        fi
    fi
    ledger_dir="$ledger_base/${author:-unknown}"
    # Same lock-dir hardening shape as the --doc lock directory above:
    # mkdir -m at creation only sets the mode once, so a pre-existing or
    # symlinked directory is checked and re-chmod'd explicitly every time.
    # shellcheck disable=SC2174 # Only the final, per-sender directory is ours.
    if ! mkdir -m 700 -p "$ledger_dir" || [ -L "$ledger_dir" ] || [ ! -O "$ledger_dir" ]; then
        printf 'inbox-send: bullet delivered but NOT recorded — cannot secure ledger directory %s\n' "$ledger_dir" >&2
        exit 4
    fi
    if ! chmod 700 "$ledger_dir"; then
        printf 'inbox-send: bullet delivered but NOT recorded — cannot secure ledger directory %s\n' "$ledger_dir" >&2
        exit 4
    fi
    sha="$(printf '%s' "$bullet" | sha256sum)" || {
        printf 'inbox-send: bullet delivered but NOT recorded — cannot hash the bullet\n' >&2
        exit 4
    }
    sha="${sha%% *}"
    if ! printf '%s %s %s %s\n' "$stamp" "$author" "$token" "$sha" >> "$ledger_dir/inbox-sent.log"; then
        printf 'inbox-send: bullet delivered but NOT recorded — cannot write ledger %s\n' "$ledger_dir/inbox-sent.log" >&2
        exit 4
    fi
fi

printf 'inbox-send: appended to %s\n' "$inbox"
