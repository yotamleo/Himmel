#!/usr/bin/env bash
# scripts/ci/windows-nightly-issue.sh — maintain ONE consolidated issue for the
# nightly/dispatch-only Windows leg of ci.yml's bun-suites job (HIMMEL-3125).
#
# Windows dropped off the per-PR path (alpha tier, not CI-gated per-PR) so a
# red Windows run no longer blocks a merge — this script is what keeps that
# from going silent. Same one-issue-in-place convention as
# scripts/ci/fork-drift-issue.sh (HIMMEL-1046): never a new issue per run.
#
#   rc != 0 -> open the issue if absent, else refresh its body + add a "still
#              red" comment.
#   rc == 0 -> if an issue is open, comment "green again" and close it.
#
# Platform guard (gitbash-only): invoked from the windows-latest leg itself
# (ci.yml), so it must run under Git Bash on Windows -- pure bash + `gh`; no
# .ps1 twin needed.
#
# Usage:  windows-nightly-issue.sh <bun-suites-windows-outcome-rc> <run-url>
# Env:
#   GH_TOKEN / GITHUB_TOKEN  gh auth (issues:write) — supplied by the workflow.
#   WINDOWS_NIGHTLY_ISSUE_LABEL  marker label (default: windows-alpha-ci).
#   WINDOWS_NIGHTLY_ISSUE_TITLE  issue title (default below) — stable across runs.
#   DRY_RUN=1                print the gh commands instead of running them
#                            (used by the test harness; no network, no auth).
set -uo pipefail

RC="${1:-}"
RUN_URL="${2:-}"
LABEL="${WINDOWS_NIGHTLY_ISSUE_LABEL:-windows-alpha-ci}"
TITLE="${WINDOWS_NIGHTLY_ISSUE_TITLE:-Windows nightly CI is red (bun-suites, alpha tier)}"

if [ -z "$RC" ] || [ -z "$RUN_URL" ]; then
  echo "usage: windows-nightly-issue.sh <bun-suites-windows-outcome-rc> <run-url>" >&2
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
    echo "**Automated Windows-nightly report** — maintained in place by the"
    echo "\`bun-suites\` (windows-latest) nightly/dispatch leg. Do not"
    echo "open duplicates; this issue is refreshed each run and auto-closed once"
    echo "the leg goes green again."
    echo ""
    echo "Windows is alpha tier: this leg no longer gates PRs, so this issue is"
    echo "the only signal that the Windows path broke."
    echo ""
    echo "_Last red run: $(now)._"
    echo ""
    echo "Run: $RUN_URL"
  } > "$body_file"
}

if [ "$RC" != 0 ]; then
  if ! num="$(find_open_issue)"; then
    echo "windows-nightly-issue: could not query existing issues (gh lookup failed) — not creating/refreshing to avoid a duplicate. Retrying next run." >&2
    exit 1
  fi
  mut=0
  run gh label create "$LABEL" --color FBCA04 \
      --description "Nightly/dispatch Windows CI tracking (alpha tier)" --force || mut=1
  body_file="$(mktemp "${TMPDIR:-/tmp}/windows-nightly-issue.XXXXXX")" || {
    echo "windows-nightly-issue: mktemp failed" >&2
    exit 1
  }
  build_body "$body_file"
  if [ -n "$num" ]; then
    echo "windows-nightly-issue: refreshing existing issue #$num"
    run gh issue edit "$num" --body-file "$body_file" || mut=1
    run gh issue comment "$num" --body "Still red as of $(now): $RUN_URL" || mut=1
  else
    echo "windows-nightly-issue: opening new consolidated issue"
    run gh issue create --title "$TITLE" --label "$LABEL" --body-file "$body_file" || mut=1
  fi
  rm -f "$body_file"
  if [ "$mut" -ne 0 ]; then
    echo "windows-nightly-issue: an issue mutation failed (see above) — failing so the red run is not silently green." >&2
    exit 1
  fi
else
  if ! num="$(find_open_issue)"; then
    echo "windows-nightly-issue: green, but could not query existing issues (gh lookup failed) — failing so the unresolved reconciliation is visible. Retries next run." >&2
    exit 1
  fi
  if [ -n "$num" ]; then
    echo "windows-nightly-issue: green again — closing issue #$num"
    mut=0
    run gh issue comment "$num" --body "Green again as of $(now): $RUN_URL. Closing." || mut=1
    run gh issue close "$num" || mut=1
    if [ "$mut" -ne 0 ]; then
      echo "windows-nightly-issue: failed to close the issue (see above) — it will retry next run." >&2
      exit 1
    fi
  else
    echo "windows-nightly-issue: green, no open issue — nothing to do."
  fi
fi
