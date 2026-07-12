#!/usr/bin/env bash
# check-commit-range.sh — lint every commit message in a range against the
# project's conventional-commit gate (scripts/hooks/check-commit-msg.sh) PLUS a
# malformed-HIMMEL-ticket check, so a PR can't merge non-conventional or
# bad-ticket commits (HIMMEL-594).
#
# Local parity: the commit-msg hook already runs check-commit-msg.sh per commit
# at author time. This re-checks the WHOLE PR range in CI (covering commits
# authored where the local hook was bypassed) and ADDITIONALLY rejects a
# present-but-malformed `HIMMEL-` ref — which the shared hook treats as prose.
# CI being slightly stricter than the local gate is intentional (the operator
# wants CI to FAIL on commit/ticket issues).
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
if ! commits="$(git rev-list "$BASE..HEAD" 2>/dev/null)"; then
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
  git log -1 --format='%B' "$sha" > "$tmp"
  if ! bash "$CHECK_MSG" "$tmp" >/dev/null 2>&1; then
    echo "FAIL ${sha} non-conventional: ${subject}"
    fails=$((fails + 1))
    continue
  fi
  # A HIMMEL- ref in the ticket position MUST be HIMMEL-<digits> (the shared
  # hook silently treats a malformed ref as message text).
  body="${subject#*: }"
  case "$body" in
    HIMMEL-[0-9]*) : ;;
    HIMMEL-*) echo "FAIL ${sha} malformed HIMMEL- ticket: ${subject}"; fails=$((fails + 1)) ;;
  esac
done

if [ "$fails" -gt 0 ]; then
  echo "commit-range: ${fails} commit(s) failed the gate (base=${BASE})" >&2
  exit 1
fi
echo "commit-range: all commits clean (${BASE}..HEAD)"
exit 0
