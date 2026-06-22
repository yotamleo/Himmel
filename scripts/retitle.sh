#!/usr/bin/env bash
# retitle.sh — compute the himmel-canonical session name for Claude Code's
# built-in /rename, inferred from the current git branch (HIMMEL-432).
#
# WHY a "print for paste" helper and not an auto-setter: the agent cannot set
# the session name from inside a running session. It is set only by the user-
# typed built-in /rename (mid-session) or the -n/--name launch flag, and a slash
# command is a prompt handed to Claude, not a programmatic command bus, so Claude
# cannot invoke /rename itself. (The Bash tool also captures stdout, so an OSC
# title escape printed from a tool call never reaches the terminal.) So this
# INFERS the ticket-anchored "<TICKET[/TICKET...]> <name>" that the native
# auto-generate never produces, and PRINTS a ready-to-paste /rename line.
# Lean-invoke; no hook (operator runs /retitle on demand).
#
# Usage: retitle.sh [TICKET-ID ...]
#   No args: infers a single ticket from the current branch. Extra args are
#   additional ticket IDs (a session spanning tickets); joined with '/'.
#
# Inference source: the current git branch (override seam RETITLE_BRANCH for
# tests). himmel conventions are <type>/<ticket>-<slug> and handover/<TICKET>-<slug>.
#
# Exit codes (keyed on the final composed ticket part):
#   0  printed a /rename line WITH a ticket part (branch inference or args)
#   1  usage error (an explicit ticket arg failed validation)
#   2  no usable branch (not a git repo / detached HEAD) AND no ticket args
#   3  degraded: printed a /rename line with a name half only (no ticket part)
#
# bash 3.2-safe; shellcheck-clean; read-only (no network, no git writes).
set -uo pipefail

# _validate_key <raw> — echo the canonical uppercased key, or empty. Fully
# anchored so malformed multi-dash / trailing junk is rejected (mirrors
# arm-resume.sh, HIMMEL-540). errexit-safe: the `if` is the last command and
# returns rc 0 whether or not it matched.
_validate_key() {
    local k
    k=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
    if printf '%s' "$k" | grep -qE '^[A-Z][A-Z0-9]*-[0-9]+$'; then
        printf '%s' "$k"
    fi
}

usage() {
    echo "usage: retitle.sh [TICKET-ID ...]" >&2
    echo "  Infers <TICKET> <name> from the current git branch and prints a" >&2
    echo "  ready-to-paste /rename line. Extra args are additional ticket IDs." >&2
}

# Validate positional args as extra ticket keys; join valid ones with '/'.
extras=""
for a in "$@"; do
    k=$(_validate_key "$a")
    if [ -z "$k" ]; then
        echo "retitle: invalid ticket id: $a" >&2
        usage
        exit 1
    fi
    extras="${extras:+$extras/}$k"
done

# Resolve branch — empty ≡ unset, both fall through to git (so a stale empty
# RETITLE_BRANCH from a test harness behaves like no override). git rev-parse
# runs in the inherited cwd (no -C) so callers/tests control repo-ness via cwd.
branch="${RETITLE_BRANCH:-}"
if [ -z "$branch" ]; then
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
fi
# Detached HEAD resolves to the literal "HEAD" → no usable branch.
[ "$branch" = HEAD ] && branch=""

# slug = branch minus the leading <type>/ (or handover/) segment.
if [ -z "$branch" ]; then
    slug=""
else
    case "$branch" in
        */*) slug="${branch#*/}" ;;
        *)   slug="$branch" ;;
    esac
fi

# Primary ticket token: keep the original-case match (rawtoken) for the strip
# AND the uppercased validated key for printing. Left-bounded first match;
# `|| true` keeps the assignment errexit/pipefail-safe on no-match.
rawtoken=$(printf '%s' "$slug" | grep -oiE '[A-Za-z][A-Za-z0-9]*-[0-9]+' | head -1 || true)
validkey=$(_validate_key "$rawtoken")

# meaningful-name: strip the token ONLY when front-anchored, using the original-
# case rawtoken (never validkey — an uppercased key would no-op on a lowercase
# slug and leak the ticket into the name). Empty rawtoken → name is the whole
# slug (the `if` guard stops an empty token's "-*" arm from eating a leading dash).
if [ -n "$rawtoken" ]; then
    case "$slug" in
        "$rawtoken"-*|"$rawtoken") name="${slug#"$rawtoken"}"; name="${name#-}" ;;
        *)                         name="$slug" ;;
    esac
else
    name="$slug"
fi

# Compose the ticket part: inferred primary then extra args, joined with '/'.
ticketpart="$validkey"
if [ -n "$extras" ]; then
    ticketpart="${ticketpart:+$ticketpart/}$extras"
fi

# Final /rename name from the 3 compose cases.
if [ -n "$ticketpart" ] && [ -n "$name" ]; then
    final="$ticketpart $name"
elif [ -n "$ticketpart" ]; then
    final="$ticketpart"
else
    final="$name"
fi

# Nothing to suggest (no usable branch and no ticket args) → rc 2.
if [ -z "$final" ]; then
    echo "retitle: no usable git branch and no ticket args — nothing to infer." >&2
    echo "  Pass ticket IDs (e.g. /retitle HIMMEL-123) or run the built-in /rename directly." >&2
    exit 2
fi

if [ -n "$branch" ]; then
    srcdesc="branch '$branch'"
else
    srcdesc="ticket arguments"
fi

# Suggestion block. The /rename line is on the stable "  /rename …" form so
# callers/tests can assert on it alone. NO example /rename <TICKET> line in the
# prose (it would false-fail the no-ticket negative assertion).
echo "retitle: inferred from $srcdesc:"
echo
echo "  /rename $final"
echo
echo "Copy the line above and run it — Claude Code's built-in /rename sets the"
echo "session display name shown in the /resume picker and on the prompt bar."
echo "To also set your terminal tab title, relaunch with the name baked in:"
echo "  claude -n \"$final\""

# Degraded: a name half only (no ticket part) → WARN + rc 3.
if [ -z "$ticketpart" ]; then
    echo "retitle: WARN no ticket inferable from $srcdesc — suggestion has a name only." >&2
    echo "  Pass ticket IDs (e.g. /retitle HIMMEL-123) for a ticket-anchored name." >&2
    exit 3
fi
exit 0
