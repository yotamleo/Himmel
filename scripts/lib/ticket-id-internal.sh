# shellcheck shell=bash
# scripts/lib/ticket-id-internal.sh — HIMMEL-3806. Sourced by the CI ticket-ID
# wrappers (scripts/ci/check-commit-range.sh, scripts/lib/check-pr-title.sh).
#
# ticket_id_author_is_external <login>
#   rc 0 = <login> is a known external contributor: skip ONLY the ticket-ID
#          requirement (prints a NOTE on stderr).
#   rc 1 = require the ticket ID. That is the answer for a listed internal
#          author, for a bot the hook already exempts (dependabot keeps its own
#          author-metadata check), and — fail-safe — for an EMPTY login or an
#          unreadable allowlist: missing data never exempts anyone.
# The allowlist is scripts/ci/ticket-id-internal-authors.txt (override the path
# with TICKET_ID_INTERNAL_AUTHORS_FILE, for tests).

ticket_id_author_is_external() {
  local login="${1:-}" here file line lc
  [ -n "$login" ] || return 1
  lc="$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')"
  case "$lc" in dependabot|'dependabot[bot]') return 1 ;; esac
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  file="${TICKET_ID_INTERNAL_AUTHORS_FILE:-$here/../ci/ticket-id-internal-authors.txt}"
  [ -r "$file" ] || return 1
  local listed=0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    [ -n "$line" ] || continue
    listed=1
    [ "$line" = "$lc" ] && return 1
  done < "$file"
  [ "$listed" -eq 1 ] || return 1
  echo "NOTE ticket-id: '${login}' is not an internal committer — ticket-ID requirement skipped (conventional shape still enforced)" >&2
  return 0
}
