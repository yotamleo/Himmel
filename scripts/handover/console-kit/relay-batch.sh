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
# A leg with no manifest row has no doc to resolve: it is listed as
# `SKIPPED <label> (no manifest row)` for a hand relay. A leg whose session is not
# exactly one live `claude -n <name>` process (candidates: its full doc stem, then
# leg_identity's names) is `UNRESOLVED <label> (candidates: ...)`: nothing is sent
# and SENT / SENDMESSAGE are never printed without a resolved session.
#
# Seams (tests): INBOX_SEND replaces inbox-send.sh; RELAY_BATCH_CENSUS is a script
# printing claude_sessions-format census lines.
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
# The live process census (pid<TAB>name<TAB>model<TAB>autocompact), taken once.
if [ -n "${RELAY_BATCH_CENSUS:-}" ]; then
    census_lines="$(bash "$RELAY_BATCH_CENSUS")" || { echo "relay-batch: census failed" >&2; exit 1; }
else
    # shellcheck source=../../lanes/lib/claude-sessions.sh
    . "$HERE/../../lanes/lib/claude-sessions.sh"
    census_lines="$(claude_sessions)"; crc=$?
    [ "$crc" -le 1 ] || { echo "relay-batch: process census failed (rc=$crc)" >&2; exit 1; }
fi

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

# HIMMEL-5074: the claudex set comes from the manifest's per-leg lane. --claudex, when
# given, must name exactly the Live-state legs the manifest marks claudex (lockless
# rows are listed below, never relayed), or the relay refuses before sending anything.
if [ -n "$claudex" ]; then
    live_labels="$(printf '%s\n' "$entries" | cut -d: -f1)"
    mclaudex=""
    if [ -f "$manifest" ]; then
        mclaudex="$(jq -r '.legs[] | select(.lane == "claudex" and (.lockless // false) != true) | .label' "$manifest" 2>/dev/null \
            | grep -Fx -f <(printf '%s\n' "$live_labels") | sort -u | tr '\n' ',')"
    fi
    given="$(printf '%s\n' "${claudex//,/$'\n'}" | awk 'NF' | sort -u | tr '\n' ',')"
    if [ "$given" != "$mclaudex" ]; then
        echo "relay-batch: --claudex (${given%,}) disagrees with the fleet manifest's claudex legs (${mclaudex%,}); nothing sent" >&2
        exit 1
    fi
fi

rc=0
while IFS=: read -r label nonce _lock _pid; do
    [ -n "$label" ] || continue
    ldoc=""; lane=unknown; lockless=false
    if [ -f "$manifest" ]; then
        mrow="$(jq -r --arg l "$label" '.legs[] | select(.label == $l) | [.doc, (.lane // "unknown"), ((.lockless // false) | tostring)] | @tsv' "$manifest" 2>/dev/null | head -n 1)"
        IFS=$'\t' read -r ldoc lane lockless <<EOR
$mrow
EOR
    fi
    if [ -z "$ldoc" ]; then echo "SKIPPED $label (no manifest row)"; continue; fi
    # A lockless row has no token to quote: the LOCKLESS section below carries it.
    [ "$lockless" != true ] || continue
    if [ "$lane" = unknown ]; then
        echo "UNRESOLVED-LANE $label (manifest lane unknown, nothing sent) — set it (fleet-manifest.sh add --lane) or relay by hand"
        continue
    fi
    # The session name is read from the live census, never guessed: a leg launches under
    # its full doc stem (dated, even -RESUME) or an undated name. Candidates: the full
    # stem first, then leg_identity's names; exactly one live match is the session.
    lstem="$(basename "$ldoc" .md)"
    lnames="$(leg_identity "$ldoc")"; lnames="${lnames#*$'\t'}"
    cands=",$lstem,$lnames,"
    hits=0; lsession=""
    if [ "$lane" = claudex ]; then
        # A claudex leg is not a `claude -n` process, so the census cannot resolve it:
        # its inbox is named for its doc stem.
        hits=1; lsession="$lstem"
    else
        while IFS=$'\t' read -r _cpid cname _rest; do
            [ -n "$cname" ] || continue
            case "$cands" in *",$cname,"*) hits=$((hits + 1)); lsession="$cname" ;; esac
        done <<EOC
$census_lines
EOC
    fi
    if [ "$hits" -ne 1 ]; then
        echo "UNRESOLVED $label (candidates: ${cands#,}; $hits live match(es), nothing sent) — relay by hand"
        continue
    fi
    text="SUCCESSION relay from $sender: your console is now $successor. Your current token \`$nonce\`. Verify this relay, send your quote-back to $successor, and keep working your sealed scope."
    case "$lane" in
        claudex)
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
    mrows="$(jq -r '.legs[] | select((.lockless // false) != true) | "\(.label) \(.doc)"' "$manifest" 2>/dev/null)"
    while read -r mlabel mdoc; do
        [ -n "$mlabel" ] || continue
        if ! printf '%s\n' "$entries" | cut -d: -f1 | grep -Fxq -- "$mlabel"; then
            echo "NOT-IN-LIVE-STATE $mlabel ($mdoc) — in the fleet manifest, not in ## Live state legs:; relay by hand if it is live"
        fi
    done <<EOF3
$mrows
EOF3
    # HIMMEL-5074: lockless watched rows hold no queue lock and no token, so there is
    # nothing to relay; they are listed so the successor watches them by mechanism.
    lrows="$(jq -r '.legs[] | select((.lockless // false) == true) | "LOCKLESS \(.label) lane=\(.lane // "unknown") doc=\(.doc)"' "$manifest" 2>/dev/null)"
    if [ -n "$lrows" ]; then
        echo "== lockless watched rows (no relay; the successor's tick judges them by tail marker) =="
        printf '%s\n' "$lrows"
    fi
fi
exit "$rc"
