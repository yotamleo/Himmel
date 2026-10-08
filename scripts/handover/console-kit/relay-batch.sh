#!/usr/bin/env bash
# relay-batch.sh — HIMMEL-4902. The outgoing console's succession relay to every
# inherited leg in ONE command instead of one hand-written message per leg.
#
#   relay-batch.sh <console doc> --successor <session> [--claudex <label>[,<label>...]]
#
# Reads the console doc's `## Live state` `legs:` entries (`<label>:<nonce>:<lock>:<pid>`)
# and its fleet manifest (label -> leg doc -> leg session name). Per leg it builds
# ONE relay message — "your console is now <successor>; token `<nonce>`; quote back
# to <successor>" — which is exactly the S1 relay of docs/handover/leg-preface.md
# ("Console succession"): sent by the outgoing console, naming its successor and
# quoting the leg's CURRENT token.
#   claudex legs (--claudex): delivered now through inbox-send.sh --token, the
#     console's existing authorised channel (it refuses outside a console).
#   every other leg: the SendMessage payload is PRINTED, one `SENDMESSAGE to=<leg
#     session> :: <text>` line per leg, for the console to send. A SendMessage
#     cannot be issued from a script; the console's `from` is what authenticates it.
# What it never does: mint a token or nonce, rotate one, adopt one, write a leg's
# Live state entry, or send LIVE. It copies the nonce the console already holds
# and the console still waits for each leg's quote-back before it sends LIVE.
# A leg with no manifest row has no session name to address: it is listed as
# `SKIPPED <label> (no manifest row)` for a hand relay.
#
# Seam (tests): INBOX_SEND replaces inbox-send.sh.
# Exit: 0 ok (skips are not errors); 1 a claudex delivery failed; 2 usage.
# PLATFORM GUARD: Linux-only kit, bash 3.2-safe; needs jq.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { echo "usage: relay-batch.sh <console doc> --successor <session> [--claudex <label>[,<label>...]]" >&2; exit 2; }
[ "$#" -ge 3 ] || usage
doc="$1"; shift
successor=""; claudex=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --successor) [ "$#" -ge 2 ] || usage; successor="$2"; shift 2 ;;
        --claudex) [ "$#" -ge 2 ] || usage; claudex=",$2,"; shift 2 ;;
        *) usage ;;
    esac
done
if [ -z "$successor" ] || [ ! -f "$doc" ]; then usage; fi
sender="$(basename "$doc" .md)"
send="${INBOX_SEND:-$HERE/inbox-send.sh}"
# shellcheck source=../../lib/leg-identity.sh
. "$HERE/../../lib/leg-identity.sh"
manifest="${doc%.md}.fleet.json"

# The legs: block of ## Live state: the legs: line plus the lines wrapped under it.
# shellcheck disable=SC2016  # the backticks are literal markers in the Live state
entries="$(awk '
    $0 == "## Live state" { s = 1; next }
    s && /^## / { exit }
    s && /^legs:/ { b = 1; print; next }
    b && (/^[[:space:]]*$/ || /^[0-9]+\. / || /^[A-Za-z][A-Za-z ]*:/ || /^[-*+>#]/) { b = 0 }
    b { print }
' "$doc" | grep -oE '`[A-Za-z0-9_.-]+:[^`:[:space:]]+:[^`:[:space:]]+:[^`:[:space:]]+`' | tr -d '`')"
[ -n "$entries" ] || { echo "relay-batch: no leg entries in $doc ## Live state" >&2; exit 0; }

rc=0
while IFS=: read -r label nonce _lock _pid; do
    [ -n "$label" ] || continue
    ldoc=""
    [ -f "$manifest" ] && ldoc="$(jq -r --arg l "$label" '.legs[] | select(.label == $l) | .doc' "$manifest" 2>/dev/null | head -n 1)"
    if [ -z "$ldoc" ]; then echo "SKIPPED $label (no manifest row)"; continue; fi
    # The launcher's session name carries neither the doc's -<date> nor its -RESUME:
    # leg_identity is the one sanctioned doc -> session mapping (its last name is the launch name).
    lnames="$(leg_identity "$ldoc")"; lnames="${lnames#*$'\t'}"; lsession="${lnames##*,}"
    text="SUCCESSION relay from $sender: your console is now $successor. Your current token \`$nonce\`. Verify this relay, send your quote-back to $successor, and keep working your sealed scope."
    case "$claudex" in
        *",$label,"*)
            if bash "$send" "$lsession" "$text" --token "$nonce" --doc "$ldoc" >/dev/null; then
                echo "SENT-INBOX $label ($lsession)"
            else
                echo "FAILED-INBOX $label ($lsession)"; rc=1
            fi ;;
        *) printf 'SENDMESSAGE to=%s :: %s\n' "$lsession" "$text" ;;
    esac
done <<EOF
$entries
EOF
# A manifest leg the Live state does not list is reported, never silently dropped.
if [ -f "$manifest" ]; then
    mrows="$(jq -r '.legs[] | "\(.label) \(.doc)"' "$manifest" 2>/dev/null)"
    while read -r mlabel mdoc; do
        [ -n "$mlabel" ] || continue
        if ! printf '%s\n' "$entries" | grep -q "^$mlabel:"; then
            echo "NOT-IN-LIVE-STATE $mlabel ($mdoc) — in the fleet manifest, not in ## Live state legs:; relay by hand if it is live"
        fi
    done <<EOF3
$mrows
EOF3
fi
exit "$rc"
