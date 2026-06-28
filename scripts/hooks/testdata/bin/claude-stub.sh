#!/usr/bin/env bash
# claude-stub.sh — a deterministic `claude` stand-in for crystallize-note tests
# (HIMMEL-576). Pointed at via CRYSTALLIZE_CLAUDE_BIN so the crystallizer tests
# stay hermetic (no real model call, no network, no billing).
#
# Behaviour via STUB_MODE (default: success):
#   success — edit the note at $CRYSTALLIZE_NOTE: rewrite the Summary body,
#             preserving all frontmatter. The `crystallized` flag is owned by
#             crystallize-note.sh (set from the body diff, HIMMEL-590 T1d) — NOT
#             here. This stub stands in for the LLM, which only touches body
#             sections, never the frontmatter.
#   fail    — exit 7 without writing (simulates a failed/non-zero claude run).
#   noop    — exit 0 without writing (simulates claude doing nothing).
#   slow    — sleep 1s, THEN behave as success (detach-survival timing contract).
#
# Always touches $CRYSTALLIZE_MARKER (if set) on invocation so a test can observe
# whether the spawn happened. Asserts CLAUDE_END_SESSION_WIKI=0 is exported by
# writing it to $CRYSTALLIZE_ENV_DUMP (if set). When $CRYSTALLIZE_ARGV_DUMP is
# set, records the spawn's cwd + every argv entry there so a test can assert the
# workspace shape (HIMMEL-590 T1c: note-dir cwd, --add-dir transcript, --settings).
set -uo pipefail

MODE="${STUB_MODE:-success}"

if [ -n "${CRYSTALLIZE_ARGV_DUMP:-}" ]; then
    {
        printf 'cwd=%s\n' "$PWD"
        _want_settings=0
        for _a in "$@"; do
            printf 'arg=%s\n' "$_a"
            # Capture the --settings fragment's CONTENT while it still exists
            # (crystallize-note.sh cleans it up on exit) so a test can assert it
            # actually wires the hook, not just that the flag is present.
            if [ "$_want_settings" = "1" ]; then
                _want_settings=0
                [ -r "$_a" ] && sed 's/^/settings:/' "$_a" 2>/dev/null
            fi
            [ "$_a" = "--settings" ] && _want_settings=1
        done
    } > "$CRYSTALLIZE_ARGV_DUMP" 2>/dev/null
fi

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

tmp="$(mktemp 2>/dev/null || printf '%s' "${NOTE}.stub.tmp")"

# Rewrite ONLY the Summary body with a deterministic crystallized line. Leave the
# frontmatter (incl. crystallized / crystallized_at) untouched — the script flips
# the flag from the body diff. Identity test asserts date/session_id/etc stay
# byte-stable.
awk '
    skip==1 { if ($0 ~ /^## /) { skip=0 } else { next } }
    /^## Summary$/ { print; print ""; print "_Crystallized by stub: session synthesized._"; print ""; skip=1; next }
    { print }
' "$NOTE" > "$tmp" && mv -f "$tmp" "$NOTE"
exit 0
