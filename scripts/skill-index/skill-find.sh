#!/usr/bin/env bash
# scripts/skill-index/skill-find.sh — HIMMEL-2222
#
# /skill-find used to hand its query straight to `qmd_cmd query --collection
# skills ...`. When the `skills` collection was never built on a machine (or
# was wiped, or a plugin change stale-invalidated it), that call fails with
# qmd's bare `Collection not found: skills` — a message that reads like a qmd
# problem, not "run the two rebuild commands", so an agent burns calls
# rediscovering the fix the skill's own docs already state. This wrapper
# checks the collection is registered AND non-empty before ever querying, and
# on failure prints the exact rebuild commands instead of surfacing the raw
# qmd error.
#
# Usage: skill-find.sh <intent text> [limit]
#   intent text — passed to qmd as --intent/--lex/--vec (same string, hybrid
#                 search); limit — result count, default 5.
#
# Exit codes:
#   0    query ran (a real 0-hit search from qmd is still rc 0)
#   2    usage error (no intent text given)
#   3    the 'skills' collection is missing or empty — rebuild commands
#        printed to stderr, qmd was never queried
#   127  qmd is not resolvable on this machine at all
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/qmd-bin.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/qmd-bin.sh"

intent="${1:-}"
limit="${2:-${LIMIT:-5}}"
if [ -z "$intent" ]; then
    echo "Usage: skill-find.sh <intent text> [limit]" >&2
    exit 2
fi

print_rebuild_remedy() {
    # Print the EFFECTIVE index dir (same default as build-skill-index.sh), so
    # a customised SKILL_INDEX_DIR gets a remedy that rebuilds where it reads.
    # %q-quote it: the heredoc is unquoted only to splice this one value in,
    # and $q's text is emitted verbatim (no re-expansion) to stderr.
    local q
    q="$(printf '%q' "${SKILL_INDEX_DIR:-$HOME/.claude/skill-index}")"
    cat >&2 <<EOF
skill-find: the 'skills' qmd collection is missing or empty — /skill-find
would otherwise silently fall back to guessing skill/command names. Rebuild it:
  bash scripts/skill-index/build-skill-index.sh --out $q
  bash -c 'source scripts/lib/qmd-bin.sh; qmd_cmd ingest --collection skills "\$1"' _ $q
EOF
}

if ! has_qmd; then
    echo "skill-find: qmd is not resolvable on this machine" >&2
    qmd_install_hint >&2
    exit 127
fi

list_out="$(qmd_cmd collection list 2>/dev/null)"
# qmd's list shape is "<name> (qmd://<name>/)" followed a few lines later by
# "  Files:    N" — grep the pair and pull the count out of the second line.
files_line="$(printf '%s\n' "$list_out" | grep -A2 '^skills (' | grep 'Files:')"
count="$(printf '%s' "$files_line" | grep -oE '[0-9]+' || true)"
if [ -z "$count" ] || [ "$count" -eq 0 ]; then
    print_rebuild_remedy
    exit 3
fi

qmd_cmd query --collection skills --intent "$intent" --lex "$intent" --vec "$intent" --limit "$limit"
