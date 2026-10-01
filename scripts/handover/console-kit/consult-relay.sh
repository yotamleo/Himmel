#!/usr/bin/env bash
# consult-relay.sh <consult-doc> <asker> (HIMMEL-4014)
#
# Prints the text a console SendMessages to the asking leg once its consult is
# done: a `CONSULT-ANSWER <asker> <doc>` header plus every `ANSWER` bullet the
# consult appended to its doc. Read-only: it never writes the doc and sends
# nothing itself (the console does the SendMessage, so no new inbox channel).
# Exit 0 with the text; exit 3 if the consult has not answered (no ANSWER
# bullet) so the console can tell "still running" from "answered"; exit 4 if
# the consult ended `BLOCKED` without an answer; exit 2 on bad usage.
set -u

if [ "$#" -ne 2 ] || [ ! -f "$1" ]; then
    echo "usage: consult-relay.sh <consult-doc> <asker>" >&2
    exit 2
fi
doc="$1"; asker="$2"
case "$asker" in
    ''|*[!A-Za-z0-9._-]*) echo "consult-relay: asker must be a session name ([A-Za-z0-9._-])" >&2; exit 2 ;;
esac

# Bullets look like `- HH:MM ANSWER <text>` (append-results.sh stamps the time).
answers="$(sed -n -E 's/^- [0-9]{2}:[0-9]{2} ANSWER[[:space:]]*(.*)$/\1/p' "$doc")"
if [ -z "$answers" ]; then
    if grep -q -E '^- [0-9]{2}:[0-9]{2} BLOCKED' "$doc"; then
        echo "consult-relay: the consult ended BLOCKED with no answer: $doc" >&2
        exit 4
    fi
    echo "consult-relay: no ANSWER bullet yet in $doc" >&2
    exit 3
fi
printf 'CONSULT-ANSWER %s %s\n%s\n' "$asker" "$doc" "$answers"
