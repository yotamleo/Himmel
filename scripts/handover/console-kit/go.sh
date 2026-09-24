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
#   1  handover root unresolvable, or the write failed; also scripts/lib/go-gate.sh
#      failed to source or did not define console_leg (fail closed - writing a GO
#      is sensitive enough that a broken shared lib must never read as "not a leg")
#   2  usage (arg count, non-digit PR, sha not exactly 40 lowercase hex); also
#      a relative-entry copy handed off (anchor-handoff.sh, HIMMEL-3437) and
#      refused - HIMMEL_REPO unset/empty, or the anchor carries no copy
#   3  refused: run from a console-spawned leg (a judge included - HIMMEL-3133,
#      "the judge is a leg") - a leg never writes its own GO
#   3  refused: run from a console relay - only the console writes a GO
#
# A relative entry (`bash scripts/handover/console-kit/go.sh`, the leg
# profile's pre-approved literal) hands off to the HIMMEL_REPO anchor's own
# copy before anything else runs (HIMMEL-3437) - same reasoning as
# merge-on-green.sh's own entry-script hand-off: a leg-writable worktree copy
# must never decide what its own GO writer does. An absolute entry (the
# console's own invocation) is unaffected - see anchor-handoff.sh's header.
#
# Platform guard (gitbash-only): POSIX bash 3.2+, same as headed-arm-leg.sh.
set -u
# HIMMEL-3437: a relative-entry copy that is not the anchor's hands off to it
# (the same one-hop, fail-closed pattern scripts/cr/anchor-handoff.sh uses).
. "$(dirname "${BASH_SOURCE[0]}")/../../cr/anchor-handoff.sh" || exit 2

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

HERE="$(cd "$(dirname "$0")" && pwd)"

# console_leg (HIMMEL-3149) is the same shared predicate merge-on-green.sh and
# block-unresolved-cr-merge.sh enforce with - go.sh is the writer those two
# gate against, so it must use their exact rule, not a hand-rolled copy of it.
# Fail closed: this write is sensitive enough that a broken/missing shared lib
# must never be read as "not a leg".
unset -f console_leg go_gate 2>/dev/null || true
# shellcheck source=scripts/lib/go-gate.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lib/go-gate.sh" 2>/dev/null || ! declare -F console_leg >/dev/null 2>&1; then
    echo "go: cannot load scripts/lib/go-gate.sh - refusing (the console-leg marker check must fail closed, not silently no-op)" >&2
    exit 1
fi
if console_leg; then
    echo "go: refusing - this is a console-spawned leg (HIMMEL_CONSOLE_LEG is set); only the console writes a GO. Send READY to your console and wait for GO." >&2
    exit 3
fi

case "$(printf '%s' "${HIMMEL_CONSOLE_RELAY:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    ''|0|false|off|no) ;;
    *)
        echo "go: refusing - this is a console relay (HIMMEL_CONSOLE_RELAY is set); only the console writes a GO. Escalate the READY to your console." >&2
        exit 3 ;;
esac

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
