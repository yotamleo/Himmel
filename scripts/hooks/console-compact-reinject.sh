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

# Set by resolve_console_doc. _RESOLVED_DOC on success, _REINJECT_WARN when
# a -console session name resolves but no doc is found under ANY searched
# root. resolve_console_doc is called directly below, never inside a $()
# capture -- a command substitution runs the function in a SUBSHELL, and a
# global it sets there never reaches the parent shell (HIMMEL-3160).
_RESOLVED_DOC=""
_REINJECT_WARN=""

# _find_doc_under_root <root> <session-name> -- prints the first
# <root>/**/<session-name>.md match, or nothing (rc 1).
_find_doc_under_root() {
    local root="$1" name="$2" hit=""
    [ -n "$root" ] && [ -d "$root" ] || return 1
    while IFS= read -r -d '' hit; do
        printf '%s\n' "$hit"
        return 0
    done < <(find "$root" -type f -name "${name}.md" -print0 2>/dev/null)
    return 1
}

resolve_console_doc() {
    _RESOLVED_DOC=""
    if [ -n "${HIMMEL_CONSOLE_DOC:-}" ]; then
        if [ -f "$HIMMEL_CONSOLE_DOC" ]; then
            _RESOLVED_DOC="$HIMMEL_CONSOLE_DOC"
            return 0
        fi
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
    local primary hit
    primary="$(handover_root 2>/dev/null)" || primary=""
    if hit="$(_find_doc_under_root "$primary" "$name")"; then
        _RESOLVED_DOC="$hit"
        return 0
    fi

    # HIMMEL-3160: handover_root missed -- with HANDOVER_DIR unset (the
    # common case: a console is usually launched by a pasted line with no
    # exported env) it resolves to THIS repo's own inline handovers/ stub,
    # not the registered state repo most consoles actually write their doc
    # to. Fall back to the exact registry candidates queue-lock.sh already
    # searches on a cross-root release/heartbeat
    # (_ql_candidate_roots, HIMMEL-2861: HANDOVER_DIR, then every
    # ~/.claude/handover/registry.json repo's inline handovers/ dir) instead
    # of re-parsing the registry a second way.
    # shellcheck source=scripts/handover/queue-lock.sh
    . "$REPO/scripts/handover/queue-lock.sh" || return 1

    local root searched="" tried=""
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        [ "$root" = "$primary" ] && continue
        case "$searched" in *"|$root|"*) continue ;; esac
        searched="$searched|$root|"
        tried="$tried$root, "
        if hit="$(_find_doc_under_root "$root" "$name")"; then
            _RESOLVED_DOC="$hit"
            return 0
        fi
    done <<EOF
$(_ql_candidate_roots)
EOF

    [ -n "$primary" ] && tried="$primary, $tried"
    _REINJECT_WARN="console-compact-reinject: no doc named '${name}.md' found under any handover root (searched: ${tried%, }) -- Live state was NOT re-injected."
    return 1
}

extract_section() {
    # $1 = heading (e.g. "## Live state"), $2 = doc path. Prints the
    # heading's body verbatim up to (not including) the next heading of
    # level >= 2 ("## ", "### ", ...), or nothing if the heading is absent.
    # A subheading appended AFTER the target section (e.g. a "### MILESTONE"
    # entry appended past "## Live state" under the last-section convention)
    # must still end it, not leak into the re-injection.
    #
    # Fence-aware: a ```-delimited block can itself contain a line that looks
    # like a heading (an example command, a quoted doc snippet). Toggling on
    # ``` lines (indentation allowed, HIMMEL-3137) and suppressing the
    # terminator check while inside one keeps that from truncating the
    # section and silently dropping real content (lock tokens, nonces) that
    # follows the fence.
    #
    # An UNTERMINATED fence (odd fence-line count) leaves the toggle stuck
    # on, so the fence-aware scan never finds its terminator and runs to
    # EOF, re-injecting the whole doc tail. Detect that first (a dry pass
    # that reports whether it reached EOF still "in fence") and fall back to
    # the plain, non-fence-aware terminator for this doc — bounded but
    # truncates any content after a genuine fence on malformed input, which
    # is visible and recoverable, versus unbounded re-injection on every
    # compaction. The warning goes to stderr only: stdout IS the re-injected
    # content.
    #
    # Marker-matched, not "any ``` line": CommonMark closes a fence only on
    # a line with the SAME character (backtick or tilde) and at LEAST the
    # opening run length. A 4-backtick fence may contain a 3-backtick
    # content line (a nested fenced example) without closing early.
    local heading="$1" doc="$2" stuck
    # shellcheck disable=SC2016  # literal awk source, no shell expansion wanted
    local fence_funcs='
        function fence_open(line,    rest, c, n) {
            match(line, /^[[:space:]]*/)
            rest = substr(line, RLENGTH + 1)
            c = substr(rest, 1, 1)
            if (c != "`" && c != "~") return 0
            n = 0
            while (substr(rest, n + 1, 1) == c) n++
            if (n < 3) return 0
            if (c == "`" && index(substr(rest, n + 1), "`") > 0) return 0
            fencechar = c
            fencelen = n
            return 1
        }
        function fence_close(line,    rest, n) {
            match(line, /^[[:space:]]*/)
            rest = substr(line, RLENGTH + 1)
            n = 0
            while (substr(rest, n + 1, 1) == fencechar) n++
            if (n < fencelen) return 0
            return substr(rest, n + 1) ~ /^[[:space:]]*$/
        }
    '
    stuck="$(awk -v want="$heading" "$fence_funcs"'
        $0 == want { f = 1; next }
        f && infence { if (fence_close($0)) infence = 0; next }
        f && !infence && fence_open($0) { infence = 1; next }
        f && /^##+ / { exit }
        f { next }
        END { if (f) print infence + 0 }
    ' "$doc")"

    if [ "$stuck" = "1" ]; then
        printf 'console-compact-reinject: %s — unterminated fence in "%s", falling back to the plain heading boundary.\n' "$doc" "$heading" >&2
        awk -v want="$heading" '
            $0 == want { f = 1; print; next }
            f && /^##+ / { exit }
            f { print }
        ' "$doc"
    else
        awk -v want="$heading" "$fence_funcs"'
            $0 == want { f = 1; print; next }
            f && infence { if (fence_close($0)) infence = 0; print; next }
            f && !infence && fence_open($0) { infence = 1; print; next }
            f && /^##+ / { exit }
            f { print }
        ' "$doc"
    fi
}

resolve_console_doc
_rc=$?
if [ "$_rc" -ne 0 ]; then
    [ -n "$_REINJECT_WARN" ] && printf '%s\n' "$_REINJECT_WARN"
    exit 0
fi
DOC="$_RESOLVED_DOC"
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
