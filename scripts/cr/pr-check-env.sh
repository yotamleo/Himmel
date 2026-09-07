#!/usr/bin/env bash
# scripts/cr/pr-check-env.sh - resolve /pr-check's CR_* / HIMMEL_DOC_FRESHNESS
# flags for the orchestrating session (HIMMEL-2226).
#
# WHY a script and not a bash fence: .claude/commands/pr-check.md's flag-
# resolution fences source scripts/lib/load-dotenv.sh with
#   . "${CLAUDE_PROJECT_DIR:?}"/scripts/lib/load-dotenv.sh
# — a runtime-determined path passed to `.` (source). Claude Code's
# worktree-isolation guard statically refuses that shape (it cannot verify a
# sourced path that depends on an env var), and CLAUDE_PROJECT_DIR is unset in
# Bash-tool shells anyway. Moving the source into a script whose OWN location
# resolves the himmel root sidesteps both problems.
#
# The --root pin below is load-bearing (HIMMEL-2035): the .env that steers
# gate policy is himmel's, never the reviewed repo's, and the gitignored .env
# exists ONLY in the primary checkout, never a linked worktree. Preserve the
# pin exactly - _load_dotenv_primary_for, never a bare --root.
#
# Usage:
#   bash scripts/cr/pr-check-env.sh [VAR ...]
# With no arguments, resolves the runbook's full set, in this order:
#   CR_PROFILE CR_CLAUDE_AGENTS CR_REQUIRE_CROSS_MODEL HIMMEL_DOC_FRESHNESS
#
# Stdout contract - one line per requested variable, in the order requested:
#   pr-check-env: <NAME>=<value>
# An unset/empty variable prints the runbook's own documented placeholder for
# that variable when one exists (currently only CR_CLAUDE_AGENTS, per step 3.5
# / HIMMEL-926: "<unset: inline adjudication, no Claude reviewer agents>");
# every other variable prints an empty value, same as the fences it replaces.
# When CR_REQUIRE_CROSS_MODEL is among the requested names, one extra line
# follows it (HIMMEL-2026):
#   pr-check-env: CR_REQUIRE_CROSS_MODEL_NORMALISED=<0|1>
# using the exact truthiness rule as clear-cr-marker.sh gate 3b and the
# step-2.5 docs-audit fence (1|true|on|yes, case-insensitive, trimmed).
#
# Process env wins over .env - load_dotenv is non-clobbering, so a value
# already live in the environment is never overwritten.
#
# Exit: 0 = resolved (even when every variable is unset); 2 = an argument is
# not a plausible env var name (^[A-Za-z_][A-Za-z0-9_]*$).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HIMMEL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
    cat <<'EOF'
Usage: pr-check-env.sh [VAR ...]

Resolves /pr-check's CR_* / HIMMEL_DOC_FRESHNESS flags via load-dotenv.sh,
pinned to the primary checkout's .env (HIMMEL-2035). Prints one
"pr-check-env: NAME=value" line per requested variable, in order. No args =
the runbook's default set (CR_PROFILE CR_CLAUDE_AGENTS CR_REQUIRE_CROSS_MODEL
HIMMEL_DOC_FRESHNESS).
EOF
}

if [ $# -gt 0 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
    usage
    exit 0
fi

VARS=("$@")
if [ "${#VARS[@]}" -eq 0 ]; then
    VARS=(CR_PROFILE CR_CLAUDE_AGENTS CR_REQUIRE_CROSS_MODEL HIMMEL_DOC_FRESHNESS)
fi

# Validate every name BEFORE resolving or printing anything - a junk name must
# not silently print a partial set (this script's output is read by the
# orchestrating session).
for v in "${VARS[@]}"; do
    case "$v" in
        [A-Za-z_]*) : ;;
        *) echo "pr-check-env: not a plausible env var name: '$v'" >&2; exit 2 ;;
    esac
    case "$v" in
        *[!A-Za-z0-9_]*) echo "pr-check-env: not a plausible env var name: '$v'" >&2; exit 2 ;;
        *) : ;;
    esac
done

# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/load-dotenv.sh"
load_dotenv --root "$(_load_dotenv_primary_for "$HIMMEL_ROOT")" "${VARS[@]}" || true

# Runbook-documented unset placeholder, by variable name. Only CR_CLAUDE_AGENTS
# has one today (step 3.5 / HIMMEL-926); every other variable falls through to
# an empty value, same as the fences it replaces.
_pce_unset_text() {
    case "$1" in
        CR_CLAUDE_AGENTS) printf '%s' '<unset: inline adjudication, no Claude reviewer agents>' ;;
        *) printf '%s' '' ;;
    esac
}

for v in "${VARS[@]}"; do
    val="${!v:-}"
    if [ -z "$val" ]; then
        val="$(_pce_unset_text "$v")"
    fi
    echo "pr-check-env: $v=$val"

    if [ "$v" = "CR_REQUIRE_CROSS_MODEL" ]; then
        # Same truthiness as clear-cr-marker.sh gate 3b / the step-2.5 fence.
        norm="$(printf '%s' "${CR_REQUIRE_CROSS_MODEL:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        case "$norm" in
            1|true|on|yes) normalised=1 ;;
            *) normalised=0 ;;
        esac
        echo "pr-check-env: CR_REQUIRE_CROSS_MODEL_NORMALISED=$normalised"
    fi
done

exit 0
