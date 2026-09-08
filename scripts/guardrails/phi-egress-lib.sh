#!/usr/bin/env bash
# scripts/guardrails/phi-egress-lib.sh — shared fail-closed predicates for the
# PHI/egress guard family (HIMMEL-1776: fence parity by extraction, ask 3).
#
# WHY: scripts/guardrails/graphify-fence.sh (the interactive path) and
# scripts/graphify/refresh-graph-map.sh (the scheduled path) each classify (a)
# PHI-root/egress-denylist file readability and (b) an Anthropic/Kimi endpoint
# URL down to a hostname. Before this file existed, each had its OWN copy of
# both checks, and the scheduled copy fell behind the fence's fail-closed
# behavior at least once (HIMMEL-1748 / PR #1680 fixed it after the drift was
# found in review). A parity TEST can only catch drift already committed;
# sourcing ONE implementation from both call sites makes the drift itself
# impossible instead of merely detectable.
#
# Contract: every predicate here fails CLOSED — an absent, unreadable, or
# unparseable input is never treated as an allow. Callers own the deny
# message and any exact-value allowlisting; these functions only classify.
#
# Deliberately does NOT call `set` itself: it is sourced into callers running
# under different shell options (graphify-fence.sh: `-uo pipefail`;
# refresh-graph-map.sh: `-euo pipefail`) — `set` mutates the CALLING shell
# once sourced, so declaring options here would silently drop the sourcing
# script's own `-e` (exactly the fail-open-by-accident shape this ticket is
# about).

# _guard_file_readable <path> -> rc 0 iff <path> exists, is a regular file,
# and is readable by this process; rc 1 otherwise (missing, a directory/
# special file, or present-but-unreadable). Callers must NOT collapse
# "unreadable" into "absent": an EXISTING-but-unreadable PHI-roots/denylist
# file must still deny, not silently proceed as if it declared nothing
# (the fail-open shape HIMMEL-1776 names).
_guard_file_readable() {
    [ -f "$1" ] && [ -r "$1" ]
}

# _guard_endpoint_host <url> -> prints the lowercased, syntactically-validated
# hostname on stdout and returns 0; returns 1 (nothing printed) when <url> is
# empty, contains a backslash (HIMMEL-1049: some HTTP clients fold `\` into
# `/`, so a backslash before the real authority can smuggle a different host
# past a naive parser), is not an explicit `https://` URL (plaintext,
# scheme-less, and arbitrary-scheme values all fail closed), or otherwise
# fails to yield a non-empty host. EXACT-host allowlisting downstream (never
# substring/prefix matching on the raw URL, which a lookalike host like
# api.anthropic.com.evil.example would pass) is the caller's job; this
# function only normalizes and validates the URL shape.
_guard_endpoint_host() {
    local u="$1" host
    [ -n "$u" ] || return 1
    u="$(printf '%s' "$u" | tr '[:upper:]' '[:lower:]')"
    case "$u" in *\\*) return 1 ;; esac
    case "$u" in https://*) : ;; *) return 1 ;; esac
    u="${u#*://}"       # strip the (validated) https:// scheme
    u="${u%%/*}"        # authority = up to the first '/'
    u="${u%%\?*}"       # strip ?query   (scheme-/path-less forms)
    u="${u%%#*}"        # strip #fragment
    host="${u##*@}"     # drop userinfo (user:pass@)
    host="${host%%:*}"  # drop :port
    [ -n "$host" ] || return 1
    printf '%s' "$host"
}
