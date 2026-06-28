#!/usr/bin/env bash
# claude-stub.sh — a deterministic `claude` stand-in for crystallize-note tests
# (HIMMEL-576). Pointed at via CRYSTALLIZE_CLAUDE_BIN so the crystallizer tests
# stay hermetic (no real model call, no network, no billing).
#
# Behaviour via STUB_MODE (default: success):
#   success — edit the note at $CRYSTALLIZE_NOTE: fill the 4 sections, set
#             crystallized: true / crystallized_at, preserve all other frontmatter.
#   fail    — exit 7 without writing (simulates a failed/non-zero claude run).
#   noop    — exit 0 without writing (simulates claude doing nothing).
#   slow    — sleep 1s, THEN behave as success (detach-survival timing contract).
#
# Always touches $CRYSTALLIZE_MARKER (if set) on invocation so a test can observe
# whether the spawn happened. Asserts CLAUDE_END_SESSION_WIKI=0 is exported by
# writing it to $CRYSTALLIZE_ENV_DUMP (if set).
set -uo pipefail

MODE="${STUB_MODE:-success}"

# `slow` sleeps BEFORE touching the marker so the detach-survival test (T2.5) can
# kill the launching process group during the sleep: the marker then proves the
# child OUTLIVED the kill. Every other mode signals immediately (marker = "was
# invoked", used by the spawn-fires + cap tests).
[ "$MODE" = "slow" ] && sleep 1

[ -n "${CRYSTALLIZE_MARKER:-}" ] && printf '%s\n' "invoked" >> "$CRYSTALLIZE_MARKER" 2>/dev/null
if [ -n "${CRYSTALLIZE_ENV_DUMP:-}" ]; then
    {
        printf 'CLAUDE_END_SESSION_WIKI=%s\n' "${CLAUDE_END_SESSION_WIKI:-<unset>}"
        printf 'HIMMEL_WHERE_ARE_WE=%s\n' "${HIMMEL_WHERE_ARE_WE:-<unset>}"
    } > "$CRYSTALLIZE_ENV_DUMP" 2>/dev/null
fi

case "$MODE" in
    fail) exit 7 ;;
    noop) exit 0 ;;
esac

NOTE="${CRYSTALLIZE_NOTE:-}"
[ -n "$NOTE" ] && [ -r "$NOTE" ] || exit 0

NOW="2026-06-28T12:00:00Z"
tmp="$(mktemp 2>/dev/null || printf '%s' "${NOTE}.stub.tmp")"

# Rewrite: set crystallized true + crystallized_at; replace the Summary body with
# a deterministic crystallized line. Preserve everything else (identity test
# asserts date/session_id/etc are byte-stable).
awk -v now="$NOW" '
    /^crystallized: false$/ { print "crystallized: true"; next }
    /^crystallized_at:$/    { print "crystallized_at: " now; next }
    skip==1 { if ($0 ~ /^## /) { skip=0 } else { next } }
    /^## Summary$/ { print; print ""; print "_Crystallized by stub: session synthesized._"; print ""; skip=1; next }
    { print }
' "$NOTE" > "$tmp" && mv -f "$tmp" "$NOTE"
exit 0
