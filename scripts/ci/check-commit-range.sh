#!/usr/bin/env bash
# check-commit-range.sh — lint every commit message in a range against the
# project's conventional-commit + ticket gate (scripts/hooks/check-commit-msg.sh),
# so a PR can't merge non-conventional or untraceable commits (HIMMEL-594/1483).
#
# Local parity: the commit-msg hook runs check-commit-msg.sh per commit at author
# time. This re-checks the WHOLE PR range in CI (covering commits authored where
# the local hook was bypassed). Bot exemptions require both the trusted PR author
# supplied by CI and each commit's author metadata to match the exemption list.
#
# Usage:
#   check-commit-range.sh [<base-ref-or-sha>]
# Range = <base>..HEAD. Base resolution order:
#   1. $1 if given
#   2. $COMMIT_RANGE_BASE if set
#   3. git merge-base origin/<default> HEAD   (default branch = main|master)
#   4. origin/<default>                        (fallback if merge-base fails)
#
# Exit: 0 = all commits clean; 1 = >=1 violation; 2 = cannot resolve the range.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_MSG="$SCRIPT_DIR/../hooks/check-commit-msg.sh"
[ -f "$CHECK_MSG" ] || { echo "ERR commit-range: $CHECK_MSG not found" >&2; exit 2; }

default_branch() {
  local b
  for b in main master; do
    if git rev-parse --verify --quiet "origin/$b" >/dev/null 2>&1; then echo "$b"; return; fi
  done
  echo main
}

BASE="${1:-${COMMIT_RANGE_BASE:-}}"
if [ -z "$BASE" ]; then
  db="$(default_branch)"
  BASE="$(git merge-base "origin/$db" HEAD 2>/dev/null || true)"
  [ -z "$BASE" ] && BASE="origin/$db"
fi

if ! git rev-parse --verify --quiet "$BASE" >/dev/null 2>&1; then
  echo "ERR commit-range: cannot resolve base ref '$BASE'" >&2
  exit 2
fi

# Fail CLOSED if the range can't be walked. `rev-parse --verify` above accepts a
# well-formed-but-nonexistent full SHA on some git versions, so a bad base would
# otherwise reach here and `rev-list` would error — DON'T swallow it to an empty
# "nothing to lint" pass. A genuinely empty range (base == HEAD) exits rev-list 0
# with no output and is handled below.
# --no-merges (HIMMEL-1483 CR1): the hook's merge exemption is live-MERGE_HEAD
# only, so a HISTORICAL merge commit in the range would be validated as an
# ordinary message and fail. Parent count is the unfakeable merge signal — a
# message SHAPED like a merge still has one parent and is still validated —
# so skipping real merges here keeps the r2 anti-spoof hardening intact.
if ! commits="$(git rev-list --no-merges "$BASE..HEAD" 2>/dev/null)"; then
  echo "ERR commit-range: cannot walk range $BASE..HEAD (unresolvable base?)" >&2
  exit 2
fi
if [ -z "$commits" ]; then
  echo "commit-range: no commits in $BASE..HEAD — nothing to lint"
  exit 0
fi

fails=0
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
for sha in $commits; do
  subject="$(git log -1 --format='%s' "$sha")"
  author="$(git log -1 --format='%an' "$sha")"
  git log -1 --format='%B' "$sha" > "$tmp"
  if ! TICKET_ID_AUTHOR="$author" TICKET_ID_TRUSTED_AUTHOR="${TICKET_ID_TRUSTED_AUTHOR:-}" \
      bash "$CHECK_MSG" "$tmp" >/dev/null 2>&1; then
    echo "FAIL ${sha} commit-message gate: ${subject}"
    fails=$((fails + 1))
  fi
done

if [ "$fails" -gt 0 ]; then
  echo "commit-range: ${fails} commit(s) failed the gate (base=${BASE})" >&2
  exit 1
fi
echo "commit-range: all commits clean (${BASE}..HEAD)"
exit 0
