#!/usr/bin/env bash
# relay-batch.sh — The outgoing console's succession relay to every
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
#   native legs, when the console has a bus identity (HIMMEL_BUS_NAME): the relay IS
#     a token-free himmel-bus record. The bus proves the sender, so a trusted record
#     from the leg's named console is an S1 relay with no token; the leg quotes back
#     in a Results bullet, so the console sends nothing per leg (`BUS-RELAY <label> ok`).
#     A record that fails (`BUS-RELAY-FAIL <label> (<reason>)`, never an error) falls
#     back to the printed SendMessage below, after every bus send. A manifest leg the
#     Live state does not list needs no token this way, so it is bus-relayed too.
#   native legs with no bus identity, or a failed record: the SendMessage payload is
#     PRINTED, one `SENDMESSAGE to=<leg session> :: <text>` line per leg, for the
#     console to send. A SendMessage cannot be issued from a script; the console's
#     `from` is what authenticates it.
#   claudex legs also get a token-free bus record naming the successor: their `bus
#     adopt` needs it while the outgoing console is still live; a hand relay leaves none.
# What it never does: mint a token or nonce, rotate one, adopt one, write a leg's
# Live state entry, or send LIVE. It copies the nonce the console already holds
# and the console still waits for each leg's quote-back before it sends LIVE.
# A leg with no manifest row has no doc to resolve: it is listed as
# `SKIPPED <label> (no manifest row)` for a hand relay. A leg whose session is not
# exactly one live `claude -n <name>` process (candidates: its full doc stem, then
# leg_identity's names) is `UNRESOLVED <label> (candidates: ...)`: nothing is sent
# and SENT / SENDMESSAGE are never printed without a resolved session.
#
# A WRAPPED leg (queue lock free and its newest marker bullet WRAPPED) is finished: it is
# neither relayed nor counted, whether or not the Live state still lists it. The run ends
# with `RELAYED <n> of <m>`: n legs delivered, m the manifest's non-lockless, non-wrapped
# legs (the live fleet), so a tick can flag drift.
#
# Seams (tests): INBOX_SEND replaces inbox-send.sh; RELAY_BATCH_CENSUS is a script
# printing claude_sessions-format census lines; RELAY_BATCH_BUS replaces the bus CLI;
# RELAY_BATCH_BUS_TIMEOUT is the one deadline for all bus sends (seconds, default 15).
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
# A console's session is its doc stem, so a successor given as its doc path is named by that.
case "$successor" in */*|*.md) successor="$(basename "$successor" .md)" ;; esac
sender="$(basename "$doc" .md)"
send="${INBOX_SEND:-$HERE/inbox-send.sh}"
# shellcheck source=../../lib/leg-identity.sh
. "$HERE/../../lib/leg-identity.sh"
# shellcheck source=../../lib/leg-tail-status.sh
. "$HERE/../../lib/leg-tail-status.sh"
# shellcheck source=../../lib/prim.sh
. "$HERE/../../lib/prim.sh"
# wrapped <leg doc>: lock free and newest marker WRAPPED (close-wrapped-leg.sh's gate).
wrapped() { bash "$HERE/../queue-lock.sh" status "$1" >/dev/null 2>&1 && [ "$(leg_tail_status "$1")" = WRAPPED ]; }
manifest="${doc%.md}.fleet.json"
bus="${RELAY_BATCH_BUS:-$HERE/../../../marketplace/plugins/himmel-bus/bin/bus}"
# relay_text [<nonce>]: the relay; the SendMessage form quotes the leg's token, the bus
# form carries none.
relay_text() {
    local tok=""
    [ -z "${1:-}" ] || tok=" Your current token \`$1\`."
    printf 'SUCCESSION relay from %s: your console is now %s.%s This is an S1 relay: accept it and keep working your sealed scope. Your quote-back (no reply needed) is a Results bullet containing exactly the following, with nothing after it on that line: SUCCESSION accepted: %s replaces %s\n' "$sender" "$successor" "$tok" "$successor" "$sender"
}
not_in_live() { echo "NOT-IN-LIVE-STATE $1 ($2) — in the fleet manifest, not in ## Live state legs:; relay by hand if it is live"; }
# relay_bus: sends each queued `<kind> <label> <session> <nonce> <leg doc>` line's bus
# record: kind relay (a Live-state native leg) and offlive (a native leg missing from
# Live state) get the relay itself; notice (a claudex leg, already relayed by inbox)
# gets the record its `bus adopt` needs. The sends run together under one deadline, so
# a stalled store cannot outlast relay-on-live's kill. Fail-soft: a failed relay record
# prints the SendMessage fallback; a failed offlive record is left for a hand relay.
relay_bus() {
    local dir="" kind label session nonce ldoc res i=0 n=0 wait_for="" limit="${RELAY_BATCH_BUS_TIMEOUT:-15}"
    [ -n "$bus_queue" ] || return 0
    command -v timeout >/dev/null 2>&1 && wait_for="timeout $limit"
    if dir="$(tmpdir)"; then
        relay_text "" > "$dir/relay"; cp "$dir/relay" "$dir/offlive"
        printf 'SUCCESSION bus record from %s: your console is now %s (no token here; the S1 relay quoting your token is the instruction).\n' "$sender" "$successor" > "$dir/notice"
        while read -r kind label session nonce ldoc; do
            [ -n "$label" ] || continue
            i=$((i + 1))
            (
                if err="$($wait_for "$bus" send "$session" "$dir/$kind" 2>&1 >/dev/null)"; then
                    echo "BUS-RELAY $label ok"
                else
                    [ "$?" -eq 124 ] && [ -n "$wait_for" ] && err="timed out after ${limit}s"
                    echo "BUS-RELAY-FAIL $label (${err%%$'\n'*})"
                fi
            ) > "$dir/$i" &
        done <<EOB
$bus_queue
EOB
        wait
    else
        dir=""; echo "BUS-RELAY-FAIL all (mktemp failed)"
    fi
    while read -r kind label session nonce ldoc; do
        [ -n "$label" ] || continue
        n=$((n + 1)); res=""
        [ -z "$dir" ] || res="$(cat "$dir/$n")"
        [ -z "$res" ] || echo "$res"
        case "$res:$kind" in
            "BUS-RELAY $label ok:relay" | "BUS-RELAY $label ok:offlive") sent=$((sent + 1)) ;;
            *:relay) printf 'SENDMESSAGE to=%s :: %s\n' "$session" "$(relay_text "$nonce")"; sent=$((sent + 1)) ;;
            *:offlive) not_in_live "$label" "$ldoc" ;;
        esac
    done <<EOB
$bus_queue
EOB
    [ -z "$dir" ] || rm -rf "$dir"
}
# resolve_session <leg doc>: the session name is read from the live census, never
# guessed: a leg launches under its full doc stem (dated, even -RESUME) or an undated
# name. Candidates: the full stem first, then leg_identity's names; exactly one live
# match (hits=1) is the session.
resolve_session() {
    local lnames
    lstem="$(basename "$1" .md)"
    lnames="$(leg_identity "$1")"; lnames="${lnames#*$'\t'}"
    cands=",$lstem,$lnames,"
    hits=0; lsession=""
    while IFS=$'\t' read -r _cpid cname _rest; do
        [ -n "$cname" ] || continue
        case "$cands" in *",$cname,"*) hits=$((hits + 1)); lsession="$cname" ;; esac
    done <<EOC
$census_lines
EOC
}
bus_queue=""
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
if [ -z "$entries" ]; then
    echo "relay-batch: no leg entries in $doc ## Live state" >&2
    # a console watching only lockless rows still reports them below.
    if [ -f "$manifest" ] && jq -e '[.legs[] | select(.lockless == true)] | length > 0' "$manifest" >/dev/null 2>&1; then :; else exit 0; fi
fi

# the claudex set comes from the manifest's per-leg lane. --claudex, when
# given, must name exactly the Live-state legs the manifest marks claudex (lockless
# rows are listed below, never relayed), or the relay refuses before sending anything.
if [ -n "$claudex" ]; then
    live_labels="$(printf '%s\n' "$entries" | cut -d: -f1)"
    mclaudex=""
    if [ -f "$manifest" ]; then
        mclaudex="$(jq -r '.legs[] | select(.lane == "claudex" and (.lockless == true | not)) | .label' "$manifest" 2>/dev/null \
            | grep -Fx -f <(printf '%s\n' "$live_labels") | sort -u | tr '\n' ',')"
    fi
    given="$(printf '%s\n' "${claudex//,/$'\n'}" | awk 'NF' | sort -u | tr '\n' ',')"
    if [ "$given" != "$mclaudex" ]; then
        echo "relay-batch: --claudex (${given%,}) disagrees with the fleet manifest's claudex legs (${mclaudex%,}); nothing sent" >&2
        exit 1
    fi
fi

rc=0; sent=0
while IFS=: read -r label nonce _lock _pid; do
    [ -n "$label" ] || continue
    ldoc=""; lane=unknown
    if [ -f "$manifest" ]; then
        # A live, locked leg is never a lockless row: the label is matched against the
        # locked rows only (lockless is the boolean true; anything else is locked and
        # visible). Two locked rows under one label are ambiguous, so nothing is sent.
        mrows="$(jq -r --arg l "$label" '.legs[] | select(.label == $l and (.lockless == true | not)) | [.doc, ((.lane // "") | if . == "" then "unknown" else . end)] | @tsv' "$manifest" 2>/dev/null)"
        nrows=0; [ -z "$mrows" ] || nrows="$(printf '%s\n' "$mrows" | wc -l)"
        if [ "$nrows" -gt 1 ]; then
            echo "UNRESOLVED $label ($nrows manifest rows share the label, nothing sent) — relay by hand"
            continue
        fi
        IFS=$'\t' read -r ldoc lane <<EOR
$mrows
EOR
        if [ -z "$ldoc" ] && jq -e --arg l "$label" 'any(.legs[]; .label == $l)' "$manifest" >/dev/null 2>&1; then
            echo "UNRESOLVED $label (the only manifest row for the label is lockless, nothing sent) — relay by hand"
            continue
        fi
    fi
    if [ -z "$ldoc" ]; then echo "SKIPPED $label (no manifest row)"; continue; fi
    if wrapped "$ldoc"; then continue; fi
    case "$lane" in
        native|claudex) ;;
        unknown)
            echo "UNRESOLVED-LANE $label (manifest lane unknown, nothing sent) — fleet-manifest.sh remove it, then add it with --lane, or relay by hand"
            continue ;;
        *)
            echo "UNRESOLVED-LANE $label (lane $lane has no relay path, nothing sent) — relay by hand"
            continue ;;
    esac
    if [ "$lane" = claudex ]; then
        # A claudex leg is not a `claude -n` process, so the census cannot resolve it:
        # its inbox is named for its doc stem.
        lstem="$(basename "$ldoc" .md)"; hits=1; lsession="$lstem"
    else
        resolve_session "$ldoc"
    fi
    if [ "$hits" -ne 1 ]; then
        echo "UNRESOLVED $label (candidates: ${cands#,}; $hits live match(es), nothing sent) — relay by hand"
        continue
    fi
    case "$lane" in
        claudex)
            if bash "$send" "$lsession" "$(relay_text "$nonce")" --token "$nonce" --doc "$ldoc" >/dev/null; then
                echo "SENT-INBOX $label ($lsession)"; sent=$((sent + 1))
                [ -n "${HIMMEL_BUS_NAME:-}" ] && bus_queue="${bus_queue}notice $label $lsession - $ldoc"$'\n'
            else
                echo "FAILED-INBOX $label ($lsession)"; rc=1
            fi ;;
        *) if [ -n "${HIMMEL_BUS_NAME:-}" ]; then
               bus_queue="${bus_queue}relay $label $lsession $nonce $ldoc"$'\n'
           else
               printf 'SENDMESSAGE to=%s :: %s\n' "$lsession" "$(relay_text "$nonce")"; sent=$((sent + 1))
           fi ;;
    esac
done <<EOF
$entries
EOF
# A manifest leg the Live state does not list is bus-relayed when it is a live native
# leg and the console has a bus identity, else reported, never silently dropped.
total="$(printf '%s\n' "$entries" | awk 'NF' | wc -l | tr -d ' ')"
if [ -f "$manifest" ]; then
    total=0
    mrows="$(jq -r '.legs[] | select(.lockless == true | not) | [.label, ((.lane // "") | if . == "" then "unknown" else . end), .doc] | @tsv' "$manifest" 2>/dev/null)"
    while IFS=$'\t' read -r mlabel mlane mdoc; do
        [ -n "$mlabel" ] || continue
        if wrapped "$mdoc"; then continue; fi
        total=$((total + 1))
        if ! printf '%s\n' "$entries" | cut -d: -f1 | grep -Fxq -- "$mlabel"; then
            if [ -n "${HIMMEL_BUS_NAME:-}" ] && [ "$mlane" = native ] && resolve_session "$mdoc" && [ "$hits" -eq 1 ]; then
                bus_queue="${bus_queue}offlive $mlabel $lsession - $mdoc"$'\n'
            else
                not_in_live "$mlabel" "$mdoc"
            fi
        fi
    done <<EOF3
$mrows
EOF3
fi
relay_bus
if [ -f "$manifest" ]; then
    # lockless watched rows hold no queue lock and no token, so there is
    # nothing to relay; they are listed so the successor watches them by mechanism.
    lrows="$(jq -r '.legs[] | select(.lockless == true) | "LOCKLESS \(.label) lane=\((.lane // "") | if . == "" then "unknown" else . end) doc=\(.doc)"' "$manifest" 2>/dev/null)"
    if [ -n "$lrows" ]; then
        echo "== lockless watched rows (no relay; the successor's tick judges them by tail marker) =="
        printf '%s\n' "$lrows"
    fi
fi
echo "RELAYED $sent of $total"
exit "$rc"
