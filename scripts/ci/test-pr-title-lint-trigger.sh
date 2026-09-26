#!/usr/bin/env bash
# scripts/ci/test-pr-title-lint-trigger.sh -- regression suite for judge
# J1284O's F1/F2 fix on HIMMEL-3616: the PR-title lint must (F1) thread the
# PR author into TICKET_ID_AUTHOR/TICKET_ID_TRUSTED_AUTHOR so the Dependabot
# exemption applies to a title the same way it already does to a commit
# (scripts/ci/check-commit-range.sh:86), and (F2) live in its own workflow
# triggered on `edited` with its own concurrency group, so a retitle re-runs
# it without a new push and without cancelling the required commit-lint/CI
# matrix on every `gh pr edit` of the body. Pure text assertions over the
# workflow files (trailing YAML comments stripped). No network.
#
# Usage: bash scripts/ci/test-pr-title-lint-trigger.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_YML="${CI_YML:-$ROOT/.github/workflows/ci.yml}"
TITLE_YML="${TITLE_YML:-$ROOT/.github/workflows/pr-title-lint.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }
strip() { sed 's/[[:space:]][[:space:]]*#.*$//' "$1"; }

# F2: the title-lint step must no longer live in ci.yml's required
# commit-lint job -- a step there only runs on ci.yml's own trigger, which
# has no `edited` type.
if strip "$CI_YML" | grep -q 'Lint the PR title'; then
  bad "ci.yml's commit-lint job still contains the PR-title-lint step (must move to its own workflow)"
else
  ok "ci.yml no longer lints the PR title inline in commit-lint"
fi

if [ -f "$TITLE_YML" ]; then
  ok "a dedicated pr-title-lint workflow file exists"
else
  bad "no dedicated pr-title-lint workflow file at $TITLE_YML"
  echo "$fails failed" >&2
  exit 1
fi

body="$(strip "$TITLE_YML")"

# F2: must trigger on `edited` (plus the usual opened/synchronize/reopened),
# so a bad->good retitle via `gh pr edit --title` re-runs the check without
# a new push.
types_line="$(awk '/^  pull_request:/ {f=1; next} f && /types:/ {print; exit} f && /^  [a-z_]+:/ {exit}' "$TITLE_YML")"
case "$types_line" in
  *edited*) ok "pr-title-lint triggers on the pull_request 'edited' type" ;;
  *) bad "pr-title-lint does not trigger on 'edited'; got: $types_line" ;;
esac
for t in opened synchronize reopened; do
  case "$types_line" in
    *"$t"*) ok "pr-title-lint also triggers on '$t'" ;;
    *) bad "pr-title-lint is missing the '$t' trigger type" ;;
  esac
done

# F2: its own concurrency group, scoped to the PR number and distinct from
# ci.yml's ci-pr-<N> group, so a retitle never cancels (or is cancelled by)
# the required CI matrix through a shared group.
title_group="$(sed -n 's/^  group:[[:space:]]*//p' <<< "$body")"
case "$title_group" in
  *'github.event.pull_request.number'*) ok "pr-title-lint's concurrency group is scoped to the PR number" ;;
  *) bad "pr-title-lint's concurrency group is not scoped to the PR number; got: $title_group" ;;
esac
if [ -n "$title_group" ] && ! grep -Fq -- "$title_group" "$CI_YML"; then
  ok "pr-title-lint's concurrency group is distinct from any group in ci.yml"
else
  bad "pr-title-lint's concurrency group string also appears in ci.yml (not distinct); got: $title_group"
fi

# F1: the PR author must be threaded into TICKET_ID_AUTHOR AND
# TICKET_ID_TRUSTED_AUTHOR so the dependabot[bot] exemption
# (scripts/hooks/check-commit-msg.sh) fires for a title the same way it
# already fires for a commit (check-commit-range.sh:86 threads the commit's
# own author the same way).
# shellcheck disable=SC2016 # literal YAML text, not meant to expand
case "$body" in
  *'TICKET_ID_AUTHOR: ${{ github.event.pull_request.user.login }}'*)
    ok "pr-title-lint threads TICKET_ID_AUTHOR from the PR author login" ;;
  *) bad "pr-title-lint does not thread TICKET_ID_AUTHOR from the PR author login" ;;
esac
# shellcheck disable=SC2016 # literal YAML text, not meant to expand
case "$body" in
  *'TICKET_ID_TRUSTED_AUTHOR: ${{ github.event.pull_request.user.login }}'*)
    ok "pr-title-lint threads TICKET_ID_TRUSTED_AUTHOR from the PR author login" ;;
  *) bad "pr-title-lint does not thread TICKET_ID_TRUSTED_AUTHOR from the PR author login" ;;
esac

# Security property carried over from the original ci.yml step: the title is
# attacker-controlled text, so it must reach the script via env:, never by
# inline ${{ }} interpolation into the run: shell.
if grep -Eq '^\s*run:.*\$\{\{\s*github\.event\.pull_request\.title' "$TITLE_YML"; then
  bad "pr-title-lint interpolates the PR title directly into run: (script-injection risk)"
else
  ok "pr-title-lint does not inline-interpolate the PR title into run:"
fi
# shellcheck disable=SC2016 # literal YAML text, not meant to expand
case "$body" in
  *'PR_TITLE: ${{ github.event.pull_request.title }}'*)
    ok "pr-title-lint passes the title through env: PR_TITLE" ;;
  *) bad "pr-title-lint does not pass the title through env: PR_TITLE" ;;
esac

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
