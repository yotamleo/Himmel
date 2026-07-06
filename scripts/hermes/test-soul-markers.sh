#!/usr/bin/env bash
# Marker-diff assertion for the 559 free-tier + premium SOUL assets
# (HIMMEL-654 WS5 Task 4 / T11). Asserts:
#   - the FREE-tier SOUL carries the open-model markers: a literal
#     "Context budget:" line AND a fenced JSON / format-contract block;
#   - the PREMIUM himmel_agent SOUL carries the GPT-anatomy markers: a
#     precedence-ladder block AND XML spec tags;
#   - the two SOULs DIFFER on those NAMED markers (free lacks the
#     precedence/spec-tag block; premium lacks the context-budget + JSON
#     contract block) -- not a vague "differ on axes".
#
# Platform guard (gitbash-only): the hermes asset layout this script
# resolves against is exercised under MSYS / Git Bash. On any non-MINGW /
# non-MSYS shell the script SKIPs (exit 0) so a POSIX-only CI runner does
# not false-fail; the header comment is the durable "gitbash-only" note.
# Run with: bash scripts/hermes/test-soul-markers.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FREE="$SCRIPT_DIR/assets/free-tier.SOUL.md"
PREMIUM="$SCRIPT_DIR/assets/himmel-agent.SOUL.md"

case "${MSYSTEM:-}" in
    MINGW* | MSYS*) : ;; # Git Bash -- run.
    *)
        echo "SKIP: test-soul-markers.sh is gitbash-only (MSYSTEM=${MSYSTEM:-unset})."
        exit 0
        ;;
esac

[ -f "$FREE" ] || { echo "FAIL: free-tier SOUL asset absent: $FREE" >&2; exit 1; }
[ -f "$PREMIUM" ] || { echo "FAIL: premium SOUL asset absent: $PREMIUM" >&2; exit 1; }

fails=0
# has <label> <file> <pattern>  -- fixed-string grep; counts a fail if absent.
has() {
    if grep -qF -- "$3" "$2"; then
        echo "  ok: $1"
    else
        echo "  FAIL: $1 (missing in $(basename "$2"))" >&2
        fails=$((fails + 1))
    fi
}
# lacks <label> <file> <pattern> -- fixed-string grep; counts a fail if present.
lacks() {
    if grep -qF -- "$3" "$2"; then
        echo "  FAIL: $1 (unexpectedly present in $(basename "$2"))" >&2
        fails=$((fails + 1))
    else
        echo "  ok: $1"
    fi
}

echo "== free-tier SOUL: open-model markers present =="
has "free has Context budget line"        "$FREE"    "Context budget:"
has "free has fenced json contract block" "$FREE"    '```json'
has "free has format-contract label"      "$FREE"    "format-contract"

echo "== premium SOUL: GPT-anatomy markers present =="
has "premium has precedence-ladder"       "$PREMIUM" "Precedence ladder"
has "premium has spec-tag open"           "$PREMIUM" "<spec>"
has "premium has spec-tag close"          "$PREMIUM" "</spec>"

echo "== the two SOULs DIFFER on the named markers =="
lacks "free lacks precedence-ladder"      "$FREE"    "Precedence ladder"
lacks "free lacks spec-tag"               "$FREE"    "<spec>"
lacks "premium lacks Context budget"      "$PREMIUM" "Context budget:"
lacks "premium lacks JSON contract block" "$PREMIUM" '```json'

if [ "$fails" -eq 0 ]; then
    echo "PASS: soul markers diverge as specified"
    exit 0
fi
echo "FAIL: $fails marker assertion(s) failed" >&2
exit 1
