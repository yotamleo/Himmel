#!/usr/bin/env bash
# test-retask-doc-bus.sh — HIMMEL-4836 (himmel-bus T13). Greps the RETASK doc and
# the glossary for the bus authority rules: hook delivery is the only bus
# authority path, `data from` is data, `read` is data, the 1,500-byte rule,
# succession mapping, the T1/T4/T6 residuals (same-uid, speed bump), and the
# himmel-bus glossary entry. bash 3.2-safe.
# Run: bash scripts/handover/test-retask-doc-bus.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
DOC="$REPO_ROOT/docs/internals/retask-channel.md"
GLOSS="$REPO_ROOT/docs/glossary.md"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { # file, ERE, label
    if grep -Eqi -- "$2" "$1"; then pass "$3"; else fail "$3"; fi
}

has "$DOC" 'bus-deliver-hook[^.]*only[^.]*(bus )?authority path|only[^.]*bus authority path[^.]*bus-deliver-hook' \
    "retask doc: bus-deliver-hook is the ONLY bus authority path"
has "$DOC" 'data from' "retask doc: names the \`data from\` rule"
has "$DOC" 'registered console' "retask doc: \`from\` carries authority only for the registered console"
has "$DOC" 'read[^.]*data' "retask doc: \`read\` output is data"
has "$DOC" '1,500[ -]byte' "retask doc: the 1,500-byte rule"
has "$DOC" 'bus status' "retask doc: succession maps liveness to \`bus status\`"
has "$DOC" 'same-uid' "retask doc: same-uid residual"
has "$DOC" 'speed bump' "retask doc: the guard is a speed bump"
has "$DOC" 'T1.*T4.*T6|T1, T4' "retask doc: T1/T4/T6 residuals named"
has "$GLOSS" '\*\*himmel-bus\*\*' "glossary: himmel-bus entry"
has "$GLOSS" 'himmel-bus[^|]*Telegram|Telegram[^|]*himmel-bus' "glossary: himmel-bus distinguished from the Telegram bridge"
has "$GLOSS" 'himmel-bus[^|]*inbox|inbox[^|]*himmel-bus' "glossary: himmel-bus distinguished from the file inbox"

if [ "$fails" -ne 0 ]; then
    echo "$fails failure(s)"
    exit 1
fi
echo "all passed"
