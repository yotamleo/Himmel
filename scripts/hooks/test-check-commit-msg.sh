#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-commit-msg.sh (HIMMEL-1483).
# Exercises default-off compatibility, strict Jira/custom patterns, and exemptions.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HOOKS/check-commit-msg.sh"
R=$(mktemp -d -t himmel-commit-msg.XXXXXX)
trap 'rm -rf "$R"' EXIT
git -C "$R" init -q
git -C "$R" config user.email t@t
git -C "$R" config user.name t
MSG="$R/COMMIT_MSG"

run_gate() {
  local message="$1"
  shift
  printf '%s\n' "$message" > "$MSG"
  ( cd "$R" && env -u TICKET_ID_REQUIRED -u TICKET_ID_PATTERN \
      -u TICKET_ID_EXEMPT_AUTHORS -u TICKET_ID_AUTHOR -u TICKET_ID_TRUSTED_AUTHOR -u JIRA_PROJECT_KEY \
      "$@" bash "$SCRIPT" "$MSG" )
}

failures=0
expect_rc() {
  local name="$1" want="$2" message="$3"
  shift 3
  local rc=0
  run_gate "$message" "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then
    printf '  PASS  %s\n' "$name"
  else
    printf '  FAIL  %s (rc=%s, want %s)\n' "$name" "$rc" "$want"
    failures=$((failures + 1))
  fi
}

expect_rc "default OFF keeps ticket optional" 0 "feat: add feature"
expect_rc "malformed conventional commit still rejects" 1 "not conventional"
expect_rc "strict Jira mode rejects missing ticket" 1 "feat: add feature" \
  TICKET_ID_REQUIRED=1 JIRA_PROJECT_KEY=ACME
expect_rc "strict Jira mode accepts PROJECT-N" 0 "feat: ACME-42 add feature" \
  TICKET_ID_REQUIRED=1 JIRA_PROJECT_KEY=ACME
expect_rc "custom regex supports no-Jira #N tickets" 0 "fix: close #73" \
  TICKET_ID_REQUIRED=1 'TICKET_ID_PATTERN=#[0-9]+'
expect_rc "strict mode fails closed without any pattern" 1 "feat: add feature" \
  TICKET_ID_REQUIRED=1
expect_rc "invalid custom regex fails closed" 1 "feat: [ add feature" \
  TICKET_ID_REQUIRED=1 'TICKET_ID_PATTERN=['
expect_rc "fake merge subject is not exempt" 1 "Merge branch 'main'" \
  TICKET_ID_REQUIRED=1 JIRA_PROJECT_KEY=ACME
expect_rc "bare revert subject is not exempt" 1 'Revert "feat: add feature"' \
  TICKET_ID_REQUIRED=1 JIRA_PROJECT_KEY=ACME
# HIMMEL-1483 CR1: the revert exemption now requires the reverted hash to
# resolve to a real commit (git cat-file -e). Seed one and use its SHA for the
# positive case; a fabricated hash must fall through and be rejected in strict.
git -C "$R" commit -q --allow-empty -m "feat: add feature"
REVERTED_SHA=$(git -C "$R" rev-parse HEAD)
expect_rc "Git-generated revert of a real commit is exempt" 0 \
  "Revert \"feat: add feature\"

This reverts commit ${REVERTED_SHA}." \
  TICKET_ID_REQUIRED=1
expect_rc "fabricated-hash revert shape falls through and is rejected" 1 \
  $'Revert "feat: add feature"\n\nThis reverts commit 0123456789abcdef0123456789abcdef01234567.' \
  TICKET_ID_REQUIRED=1 JIRA_PROJECT_KEY=ACME

BASE_BRANCH=$(git -C "$R" symbolic-ref --short HEAD)
printf 'base\n' > "$R/file"
git -C "$R" add file
git -C "$R" commit -q -m base
git -C "$R" checkout -q -b side
printf 'side\n' > "$R/file"
git -C "$R" commit -q -am side
git -C "$R" checkout -q "$BASE_BRANCH"
printf 'main\n' > "$R/file"
git -C "$R" commit -q -am main
git -C "$R" merge side >/dev/null 2>&1 || true
expect_rc "real merge is exempt" 0 "Merge branch 'side'" TICKET_ID_REQUIRED=1
git -C "$R" merge --abort

expect_rc "dependabot author is exempt locally" 0 "chore: bump dependency" \
  TICKET_ID_REQUIRED=1 'TICKET_ID_AUTHOR=dependabot[bot]'
expect_rc "trusted human blocks spoofed bot author" 1 "chore: bump dependency" \
  TICKET_ID_REQUIRED=1 JIRA_PROJECT_KEY=ACME 'TICKET_ID_AUTHOR=dependabot[bot]' TICKET_ID_TRUSTED_AUTHOR=human
expect_rc "trusted bot and bot author are exempt" 0 "chore: bump dependency" \
  TICKET_ID_REQUIRED=1 'TICKET_ID_AUTHOR=dependabot[bot]' 'TICKET_ID_TRUSTED_AUTHOR=dependabot[bot]'
expect_rc "custom author exemption list is data-driven" 0 "chore: generated update" \
  TICKET_ID_REQUIRED=1 TICKET_ID_AUTHOR=release-bot TICKET_ID_EXEMPT_AUTHORS=release-bot
# HIMMEL-1483 CR2: `dependabot[bot]` is a GLOB — a matching file in the hook's
# cwd (e.g. `dependabotb`) used to pathname-expand the unquoted list expansion
# and silently break the exemption. Globbing is now off around the split.
touch "$R/dependabotb"
expect_rc "glob-matching file in cwd does not break the bot exemption" 0 "chore: bump dependency" \
  TICKET_ID_REQUIRED=1 'TICKET_ID_AUTHOR=dependabot[bot]'
rm -f "$R/dependabotb"
expect_rc "fixup without ticket rejects in strict mode" 1 "fixup! feat: add feature" \
  TICKET_ID_REQUIRED=1 JIRA_PROJECT_KEY=ACME
expect_rc "fixup carrying ticket passes strict mode" 0 "fixup! feat: ACME-42 add feature" \
  TICKET_ID_REQUIRED=1 JIRA_PROJECT_KEY=ACME

printf 'TICKET_ID_REQUIRED=1\nJIRA_PROJECT_KEY=ENVKEY\n' > "$R/.env"
expect_rc "primary .env supplies strict mode and Jira key" 0 "docs: ENVKEY-9 update docs"
expect_rc "live env overrides the primary .env" 0 "docs: no ticket needed" TICKET_ID_REQUIRED=0

if [ "$failures" -eq 0 ]; then
  echo "OK: all cases passed"
  exit 0
fi
echo "FAIL: $failures case(s) failed"
exit 1
