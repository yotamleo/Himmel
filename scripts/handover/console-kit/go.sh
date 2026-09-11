#!/usr/bin/env bash
# scripts/handover/console-kit/go.sh - write the console's GO for one PR head
# (HIMMEL-2919). The file IS the GO: merge-on-green.sh, run from a
# console-spawned leg (HIMMEL_CONSOLE_LEG=1, exported by headed-arm-leg.sh),
# refuses with exit 17 unless <handover_root>/.locks/go/<pr>.<head sha> exists
# and carries head=<that sha>. The console's SendMessage GO is only the
# notification. A GO binds ONE head: a push after it needs a fresh GO.
#
# Usage: go.sh <pr-number> <full-40-hex-head-sha>
# Prints the written path. Re-running overwrites (idempotent).
#
# Exit codes:
#   0  written
#   1  handover root unresolvable, or the write failed
#   2  usage (arg count, non-digit PR, sha not exactly 40 lowercase hex)
#   3  refused: run from a console-spawned leg - a leg never writes its own GO
#
# Platform guard (gitbash-only): POSIX bash 3.2+, same as headed-arm-leg.sh.
set -u

usage() {
    echo "usage: go.sh <pr-number> <full-40-hex-head-sha>" >&2
}

if [ "$#" -ne 2 ]; then
    usage
    exit 2
fi
PR="$1"; SHA="$2"

case "$PR" in
    ''|0*|*[!0123456789]*)
        usage
        echo "go: pr-number must be digits without a leading zero (got '$PR')" >&2
        exit 2 ;;
esac
case "$SHA" in
    *[!0123456789abcdef]*) SHA_OK=0 ;;
    *) SHA_OK=1 ;;
esac
if [ "$SHA_OK" -ne 1 ] || [ "${#SHA}" -ne 40 ]; then
    usage
    echo "go: head sha must be the full 40-char lowercase hex sha (got '$SHA')" >&2
    exit 2
fi

# Same truthiness as merge-on-green.sh's _truthy.
case "$(printf '%s' "${HIMMEL_CONSOLE_LEG:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    ''|0|false|off|no) ;;
    *)
        echo "go: refusing - this is a console-spawned leg (HIMMEL_CONSOLE_LEG is set); only the console writes a GO. Send READY to your console and wait for GO." >&2
        exit 3 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/handover-path.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lib/handover-path.sh"; then
    echo "go: cannot load scripts/lib/handover-path.sh" >&2
    exit 1
fi
if ! ROOT=$(handover_root); then
    echo "go: cannot resolve the handover root (set HANDOVER_DIR)" >&2
    exit 1
fi

DIR="$ROOT/.locks/go"
DEST="$DIR/$PR.$SHA"
BY="${CONSOLE_SESSION_NAME:-${USER:-$(id -un 2>/dev/null || echo unknown)}@$(hostname 2>/dev/null || uname -n)}"
BY=$(printf '%s' "$BY" | tr -d '\r\n')
AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if ! mkdir -p "$DIR" || ! TMP=$(mktemp "$DIR/.go.XXXXXX"); then
    echo "go: cannot create a temp file under $DIR" >&2
    exit 1
fi
if ! printf 'pr=%s\nhead=%s\nby=%s\nat=%s\n' "$PR" "$SHA" "$BY" "$AT" > "$TMP" || ! mv -f "$TMP" "$DEST"; then
    rm -f "$TMP"
    echo "go: could not write $DEST" >&2
    exit 1
fi
printf '%s\n' "$DEST"
