#!/usr/bin/env bash
# scripts/lib/check-pr-title.sh — HIMMEL-3616.
#
# WHY. The squash merge makes the PR TITLE main's commit subject, but no gate
# checked the title itself: check-commit-msg.sh runs at author time on local
# COMMITS, and the commit-lint CI job re-lints the same commit RANGE — neither
# ever looks at the title a leg typed into leg-pr-open.sh's title file. On
# 2026-09-25, 4 of 5 leg PRs opened with a type-less title even though every
# commit in the branch was conventional.
#
# This validates a title string against the EXACT SAME conventional-commit +
# ticket regex check-commit-msg.sh enforces, by invoking that script on a
# synthesized one-line message — the same reuse check-commit-range.sh already
# uses for a commit range (scripts/ci/check-commit-range.sh). The regex stays
# in ONE place (check-commit-msg.sh); leg-pr-open.sh, the commit-lint CI job
# and merge-on-green.sh all call through this wrapper instead of re-deriving
# it.
#
# Usage: check-pr-title.sh <title>
# Exit: 0 = title passes; 1 = fails (check-commit-msg.sh's own rejection,
#       plus a usage line naming the expected shape); 2 = bad invocation.
set -euo pipefail

TITLE="${1:-}"
if [ -z "$TITLE" ]; then
    echo "Usage: check-pr-title.sh <title>" >&2
    exit 2
fi

# HIMMEL-3616 (judge J1284O F5/minor): accept GitHub's own revert-button
# title shape, e.g. `Revert "fix(x): [HIMMEL-1] foo"`. check-commit-msg.sh's
# own revert exemption requires a `This reverts commit <hash>.` line whose
# hash resolves to a real commit object -- a bare title never has one, so
# that exemption can never fire here; refusing a legitimate merge path is
# worse than accepting this shape without ticket traceability.
if printf '%s\n' "$TITLE" | grep -Eq '^Revert ".+"$'; then
    exit 0
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_MSG="$HERE/../hooks/check-commit-msg.sh"
if [ ! -f "$CHECK_MSG" ]; then
    echo "check-pr-title: $CHECK_MSG not found" >&2
    exit 2
fi

TMP="$(mktemp "${TMPDIR:-/tmp}/check-pr-title.XXXXXX")" || { echo "check-pr-title: mktemp failed" >&2; exit 2; }
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$TITLE" > "$TMP"

if ! OUT=$(bash "$CHECK_MSG" "$TMP" 2>&1); then
    echo "check-pr-title: PR title fails the conventional-commit + ticket gate:" >&2
    printf '%s\n' "$OUT" >&2
    echo "  Got title: ${TITLE}" >&2
    echo "  Required shape: type(scope): [TICKET-ID] subject  (e.g. fix(x): [HIMMEL-1] foo)" >&2
    exit 1
fi
exit 0
