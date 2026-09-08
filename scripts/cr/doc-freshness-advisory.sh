#!/usr/bin/env bash
# scripts/cr/doc-freshness-advisory.sh - step-2.7 doc-freshness advisory for
# /pr-check (HIMMEL-2226, HIMMEL-587).
#
# WHY a script and not a bash fence: .claude/commands/pr-check.md's step-2.7
# fence sources scripts/lib/doc-freshness.sh (and load-dotenv.sh) with
#   . "${CLAUDE_PROJECT_DIR:?}"/scripts/lib/doc-freshness.sh
# — a runtime-determined path passed to `.` (source). Claude Code's
# worktree-isolation guard statically refuses that shape, and
# CLAUDE_PROJECT_DIR is unset in Bash-tool shells anyway. Moving the source
# into a script whose OWN location resolves the himmel root sidesteps both.
#
# ADVISORY ONLY - NEVER BLOCKS (HIMMEL-587): scripts/hooks/check-doc-guard.sh
# already enforces `block` rows at pre-push. This script always exits 0 - a
# missing lib, an inactive leg, or a df_detect failure all degrade to
# silence-plus-exit-0 rather than breaking /pr-check.
#
# Usage:
#   bash scripts/cr/doc-freshness-advisory.sh
#
# Stdout contract - same three shapes the fence printed, ASCII only:
#   Doc-freshness (advisory) - mapped sources changed without their docs:
#     - <src> -> update <doc>
#   (Advisory only - does not block this PR.)
# or, when the advise leg found no drift:
#   Doc-freshness: no mapped-source-vs-doc drift in range.
# or nothing at all, when the advise leg is inactive.
#
# Exit: always 0.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HIMMEL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# default_branch (main OR master, HIMMEL-297). Fail-open to "main" if
# guardrails/lib.sh cannot be sourced - never let a missing/broken substrate
# turn an advisory step into a hard failure.
db=""
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
if . "$HIMMEL_ROOT/scripts/guardrails/lib.sh" 2>/dev/null; then
    db="$(default_branch 2>/dev/null || true)"
fi
[ -n "$db" ] || db=main

# Pick up HIMMEL_DOC_FRESHNESS from .env for leg parity with the session/
# morning surfaces - process env still wins. --root pins the lookup to
# himmel's primary checkout (HIMMEL-2035); load_dotenv is a no-op on a
# missing .env either way.
# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/load-dotenv.sh"
load_dotenv --root "$(_load_dotenv_primary_for "$HIMMEL_ROOT")" HIMMEL_DOC_FRESHNESS || true

DF_LIB="$HIMMEL_ROOT/scripts/lib/doc-freshness.sh"
[ -f "$DF_LIB" ] || exit 0
# shellcheck source=../lib/doc-freshness.sh
# shellcheck disable=SC1091
. "$DF_LIB" 2>/dev/null || exit 0

if df_leg_active advise; then
    drift="$(df_detect "$db...HEAD" 2>/dev/null || true)"
    if [ -n "$drift" ]; then
        echo "Doc-freshness (advisory) - mapped sources changed without their docs:"
        printf '%s\n' "$drift" | awk -F'\t' 'NF>=2{printf "  - %s -> update %s\n", $(1), $(2)}'
        echo "(Advisory only - does not block this PR.)"
    else
        echo "Doc-freshness: no mapped-source-vs-doc drift in range."
    fi
fi

exit 0
