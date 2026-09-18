#!/usr/bin/env bash
# scripts/ci/shell-extended-nightly-issue.sh — maintain ONE consolidated issue
# for a red `shell-unit` gate on the nightly/dispatch-only extended tier
# (HIMMEL-3132, same convention as scripts/ci/windows-nightly-issue.sh /
# HIMMEL-3125).
#
# run-shell-tests.sh's SUITE_TIER_DEFAULT `extended` suites (currently
# test-arm-resume-identity.sh, test-arm-resume-queue-lock.sh and
# test-arm-resume-1879.sh) only execute under SUITE_TIER_MODE=all, which
# ci.yml sets only on the schedule/force_all_os leg of shell-unit-shard. A red
# extended suite therefore only ever reddens the `shell-unit` aggregating job
# on that nightly/dispatch run — a run nobody is watching interactively — so
# without this script the failure is silent even though the job itself goes
# red. This script does not distinguish which suite failed (same limitation
# as windows-nightly-issue.sh vs. which bun test failed); on a schedule/
# force_all_os run every fast-tier suite is already expected green (they gate
# every PR), so in practice a nightly-only red here points at the extended
# tier.
#
#   rc != 0 -> open the issue if absent, else refresh its body + add a "still
#              red" comment.
#   rc == 0 -> if an issue is open, comment "green again" and close it.
#
# Usage:  shell-extended-nightly-issue.sh <shell-unit-outcome-rc> <run-url>
# Env:
#   GH_TOKEN / GITHUB_TOKEN  gh auth (issues:write) — supplied by the workflow.
#   SHELL_EXTENDED_NIGHTLY_ISSUE_LABEL  marker label (default: shell-extended-nightly-ci).
#   SHELL_EXTENDED_NIGHTLY_ISSUE_TITLE  issue title (default below) — stable across runs.
#   DRY_RUN=1                print the gh commands instead of running them
#                            (used by the test harness; no network, no auth).
set -uo pipefail

RC="${1:-}"
RUN_URL="${2:-}"
LABEL="${SHELL_EXTENDED_NIGHTLY_ISSUE_LABEL:-shell-extended-nightly-ci}"
TITLE="${SHELL_EXTENDED_NIGHTLY_ISSUE_TITLE:-Shell extended-tier nightly CI is red (shell-unit)}"

if [ -z "$RC" ] || [ -z "$RUN_URL" ]; then
  echo "usage: shell-extended-nightly-issue.sh <shell-unit-outcome-rc> <run-url>" >&2
  exit 2
fi

run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf 'DRY: %s\n' "$*"
    return 0
  fi
  "$@"
}

now() { date -u +'%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "unknown-time"; }

# Newest open issue carrying the marker label. Prints the number (empty when
# there is none) on a successful lookup; returns nonzero when the lookup
# itself fails, so callers can tell "no issue" apart from "don't know" — a
# swallowed failure would let the red branch open a duplicate.
find_open_issue() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    [ "${DRY_RUN_LOOKUP_FAIL:-0}" = "1" ] && return 1
    printf '%s' "${DRY_RUN_OPEN_ISSUE:-}"
    return 0
  fi
  local out rc
  out="$(gh issue list --label "$LABEL" --state open --limit 1 \
    --json number --jq '.[0].number // empty' 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$out"
}

build_body() {
  local body_file="$1"
  {
    echo "**Automated shell extended-tier nightly report** — maintained in"
    echo "place by the \`shell-unit\` aggregating gate job's schedule/"
    echo "force_all_os leg. Do not open duplicates; this issue is refreshed"
    echo "each run and auto-closed once the leg goes green again."
    echo ""
    echo "The SUITE_TIER_DEFAULT \`extended\` suites (run-shell-tests.sh) only"
    echo "run under SUITE_TIER_MODE=all, i.e. only on this nightly/dispatch"
    echo "leg — never per-PR — so this issue is the only signal that one of"
    echo "them broke."
    echo ""
    echo "_Last red run: $(now)._"
    echo ""
    echo "Run: $RUN_URL"
  } > "$body_file"
}

if [ "$RC" != 0 ]; then
  if ! num="$(find_open_issue)"; then
    echo "shell-extended-nightly-issue: could not query existing issues (gh lookup failed) — not creating/refreshing to avoid a duplicate. Retrying next run." >&2
    exit 1
  fi
  mut=0
  run gh label create "$LABEL" --color FBCA04 \
      --description "Nightly/dispatch shell extended-tier CI tracking" --force || mut=1
  body_file="$(mktemp "${TMPDIR:-/tmp}/shell-extended-nightly-issue.XXXXXX")" || {
    echo "shell-extended-nightly-issue: mktemp failed" >&2
    exit 1
  }
  build_body "$body_file"
  if [ -n "$num" ]; then
    echo "shell-extended-nightly-issue: refreshing existing issue #$num"
    run gh issue edit "$num" --body-file "$body_file" || mut=1
    run gh issue comment "$num" --body "Still red as of $(now): $RUN_URL" || mut=1
  else
    echo "shell-extended-nightly-issue: opening new consolidated issue"
    run gh issue create --title "$TITLE" --label "$LABEL" --body-file "$body_file" || mut=1
  fi
  rm -f "$body_file"
  if [ "$mut" -ne 0 ]; then
    echo "shell-extended-nightly-issue: an issue mutation failed (see above) — failing so the red run is not silently green." >&2
    exit 1
  fi
else
  if ! num="$(find_open_issue)"; then
    echo "shell-extended-nightly-issue: green, but could not query existing issues (gh lookup failed) — failing so the unresolved reconciliation is visible. Retries next run." >&2
    exit 1
  fi
  if [ -n "$num" ]; then
    echo "shell-extended-nightly-issue: green again — closing issue #$num"
    mut=0
    run gh issue comment "$num" --body "Green again as of $(now): $RUN_URL. Closing." || mut=1
    run gh issue close "$num" || mut=1
    if [ "$mut" -ne 0 ]; then
      echo "shell-extended-nightly-issue: failed to close the issue (see above) — it will retry next run." >&2
      exit 1
    fi
  else
    echo "shell-extended-nightly-issue: green, no open issue — nothing to do."
  fi
fi
