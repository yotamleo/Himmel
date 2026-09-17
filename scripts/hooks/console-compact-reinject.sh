#!/usr/bin/env bash
# console-compact-reinject.sh — SessionStart:compact hook: give CONSOLE
# sessions the same post-compaction restore that legs already have
# (HIMMEL-2973 S1).
#
# THE PROBLEM: a console's `## Live state` (per-leg RETASK nonces, lock
# release tokens, the held queue, the last GO) lives in its context window
# and nowhere else once compaction runs — the console can no longer
# authentically re-task its own children or resume a held queue. Every LEG
# already survives this (`headed-arm-leg.sh --profile` wires a
# `SessionStart`/`"matcher": "compact"` hook that `cat`s its contract back,
# HIMMEL-2990); consoles had no equivalent. This is that equivalent.
#
# PLATFORM GUARD: no .ps1 twin, by design, not oversight — session
# resolution here is via scripts/lib/session-name.sh, which itself reads
# /proc/<pid>/cmdline (Linux-only). On macOS/Windows session-name.sh
# resolves to empty, this hook then finds no console doc, and — same as the
# "not a console session" case below — prints nothing. Safe no-op, never a
# wrong re-injection.
#
# TRUST CLASS (docs/internals/retask-channel.md §3): SessionStart hook
# stdout is harness-injected context — the harness writes it as a real turn,
# the same trusted-origin class as a genuine RETASK dispatch or the claudex
# inbox delivery, NOT a tool-result block. Vector 1 in that threat model
# (attacker text disguised as a coordinator message) lives inside tool
# results; this hook never reads one. Re-emitting a console doc's own nonces
# back to the SAME session that already held them opens no new vector: it is
# the session re-reading its own prior state, not receiving a new claim of
# identity from an untrusted source.
#
# SILENT NO-OP for every non-console session (exit 0, no output) — this
# fires on every compaction fleet-wide, and a leg or ad-hoc session dumping
# a console's authority state would be the exact failure this hook exists to
# prevent, not a feature. Detection is deliberately layered: an explicit
# `HIMMEL_CONSOLE_DOC` env var first, then a name-based fallback, because most
# consoles are launched by a pasted line carrying no exported env at all.
#
# FAIL-OPEN (workflow nudge, not a security fence, scripts/hooks/CLAUDE.md):
# an unresolvable session, a missing/unreadable doc, or a doc with no
# `## Live state` section all degrade to silence or a one-line warning, never
# to a block — there is no tool call here to deny. No bypass env var: nothing
# is ever refused, so there is nothing to bypass.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

resolve_console_doc() {
    if [ -n "${HIMMEL_CONSOLE_DOC:-}" ]; then
        [ -f "$HIMMEL_CONSOLE_DOC" ] && printf '%s\n' "$HIMMEL_CONSOLE_DOC" && return 0
        return 1
    fi

    # shellcheck source=scripts/lib/session-name.sh
    . "$REPO/scripts/lib/session-name.sh" || return 1
    local name
    name="$(current_session_name)" || return 1
    case "$name" in
        *-console) ;;
        *) return 1 ;;
    esac

    # shellcheck source=scripts/lib/handover-path.sh
    . "$REPO/scripts/lib/handover-path.sh" || return 1
    local root
    root="$(handover_root)" || return 1
    [ -n "$root" ] && [ -d "$root" ] || return 1

    local hit=""
    while IFS= read -r -d '' hit; do
        printf '%s\n' "$hit"
        return 0
    done < <(find "$root" -type f -name "${name}.md" -print0 2>/dev/null)

    return 1
}

extract_section() {
    # $1 = heading (e.g. "## Live state"), $2 = doc path. Prints the
    # heading's body verbatim up to (not including) the next heading of
    # level >= 2 ("## ", "### ", ...), or nothing if the heading is absent.
    # A subheading appended AFTER the target section (e.g. a "### MILESTONE"
    # entry appended past "## Live state" under the last-section convention)
    # must still end it, not leak into the re-injection.
    awk -v want="$1" '
        $0 == want { f = 1; print; next }
        f && /^##+ / { exit }
        f { print }
    ' "$2"
}

DOC="$(resolve_console_doc)" || exit 0
[ -n "$DOC" ] || exit 0

LIVE_STATE="$(extract_section "## Live state" "$DOC")"
COMPACT_INSTR="$(extract_section "## Compact instructions" "$DOC")"

if [ -z "$LIVE_STATE" ]; then
    printf 'console-compact-reinject: %s has no "## Live state" section — nothing to re-inject.\n' "$DOC"
    exit 0
fi

printf '%s\n\n' "$LIVE_STATE"
[ -z "$COMPACT_INSTR" ] || printf '%s\n\n' "$COMPACT_INSTR"
# shellcheck disable=SC2016  # literal backtick-quoted token name, not an expansion
printf 'You have just compacted. Your first action is the `COMPACTED` bullet, copied from the Live state above.\n'
