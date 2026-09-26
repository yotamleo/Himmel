#!/usr/bin/env bash
# scripts/ci/check-macos-nightly-health.sh — HIMMEL-3699
#
# shell-unit-shard sets `continue-on-error: true` for macOS/windows so a red
# nightly leg stays advisory, but that also means the matrix ROLLUP the
# shell-unit job reads never reflects a macOS failure — the nightly run can
# read "success" while every macOS shard is red. This queries the Jobs API
# directly (it reports each job's real `conclusion`, unaffected by
# continue-on-error) so a red macOS job is never silently masked on the leg
# that is supposed to catch it. Extracted to a script (same convention as
# scripts/ci/shell-extended-nightly-issue.sh) so it is unit-testable with a
# stubbed `gh` instead of only observable on a real nightly run.
#
# Usage: REPO=<owner/repo> RUN_ID=<id> check-macos-nightly-health.sh
# Env:   GH_TOKEN  gh auth — supplied by the workflow.
set -uo pipefail

REPO="${REPO:?REPO required}"
RUN_ID="${RUN_ID:?RUN_ID required}"

FAILED=$(gh api "repos/$REPO/actions/runs/$RUN_ID/jobs?per_page=100" --paginate \
  --jq '.jobs[] | select(.name | test("macos-latest")) | select(.conclusion != "success" and .conclusion != "skipped" and .conclusion != null) | .name')
if [ -n "$FAILED" ]; then
  echo "::error::macOS nightly job(s) failed (continue-on-error hid this from the shell-unit-shard rollup):"
  echo "$FAILED"
  exit 1
fi
echo "OK: no failing macOS job on this run."
