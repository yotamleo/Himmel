#!/usr/bin/env bash
# scripts/ci/fork-drift-issue.sh — maintain ONE consolidated upstream-drift
# tracking issue from the nightly fork-drift workflow (HIMMEL-1046).
#
# The drift guard (scripts/check-plugin-drift.sh) reports via an EXIT CODE:
#   0 = every tracked upstream CURRENT
#   2 = DRIFT (at least one fork/pin is behind upstream)
#   3 = INCOMPLETE (a check could not complete — expected in CI, where the
#       probe/checkout registry entries have no local install)
# This script turns that code into issue state, refreshing a single issue in
# place (keyed by the `fork-drift` label) rather than opening a new one per run:
#   rc 2 -> open the issue if absent, else refresh its body + add a "still
#           drifting" comment.
#   rc 0 -> if an issue is open, comment "cleared" and close it.
#   rc 3 (or anything else) -> leave existing issue state untouched (an
#           incomplete run must never open OR close — it proved nothing).
#
# Usage:  fork-drift-issue.sh <guard-exit-code> <report-file>
# Env:
#   GH_TOKEN / GITHUB_TOKEN  gh auth (issues:write) — supplied by the workflow.
#   DRIFT_ISSUE_LABEL        marker label (default: fork-drift).
#   DRIFT_ISSUE_TITLE        issue title (default below) — stable across runs.
#   DRY_RUN=1                print the gh commands instead of running them
#                            (used by the test harness; no network, no auth).
set -uo pipefail

RC="${1:-}"
REPORT="${2:-}"
LABEL="${DRIFT_ISSUE_LABEL:-fork-drift}"
TITLE="${DRIFT_ISSUE_TITLE:-Upstream fork drift detected (nightly fork-drift)}"

if [ -z "$RC" ] || [ -z "$REPORT" ]; then
  echo "usage: fork-drift-issue.sh <guard-exit-code> <report-file>" >&2
  exit 2
fi
if [ ! -f "$REPORT" ]; then
  echo "fork-drift-issue: report file not found: $REPORT" >&2
  exit 2
fi

# DRY_RUN prints the command instead of executing — lets the test harness
# assert behaviour with no gh, no auth, no network.
run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf 'DRY: %s\n' "$*"
    return 0
  fi
  "$@"
}

# UTC stamp — plain `date` (this runs in CI / a shell, not a Workflow script).
now() { date -u +'%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "unknown-time"; }

# Newest open issue carrying the marker label. Prints the number (empty when
# there is none) on a SUCCESSFUL lookup; returns nonzero when the lookup itself
# fails (network/auth) so callers can distinguish "no issue" from "don't know" —
# a swallowed failure would let the rc=2 branch open a DUPLICATE when an issue
# already exists but the query transiently failed (breaks the one-issue contract).
find_open_issue() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    # Test hook: simulate a failed gh lookup (returns nonzero, no output).
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
    echo "**Automated upstream-drift report** — maintained in place by the nightly"
    echo "\`fork-drift\` workflow (HIMMEL-1046). Do not open duplicates; this issue is"
    echo "refreshed each run and auto-closed when drift clears."
    echo ""
    echo "_Last drift detected: $(now)._"
    echo ""
    echo "Guard output:"
    echo ''
    echo '```'
    cat "$REPORT"
    echo '```'
    echo ""
    echo "To resolve: re-sync the named fork onto its newer upstream, bump the pin"
    echo "(and \`synced_base\` in \`scripts/upstreams.json\`), then this issue closes"
    echo "on the next nightly run."
  } > "$body_file"
}

case "$RC" in
  2)
    # A failed lookup (not "no issue") must NOT fall through to `gh issue create`
    # — that would open a duplicate when an issue already exists. Bail loudly; the
    # workflow step goes red so the transient failure is visible, and the next
    # nightly retries.
    if ! num="$(find_open_issue)"; then
      echo "fork-drift: could not query existing issues (gh lookup failed) — not creating/refreshing to avoid a duplicate. Retrying next run." >&2
      exit 1
    fi
    # Propagate EVERY mutation failure (mut=1) so a failed create/edit turns the
    # workflow step RED — a silent green run that failed to open the drift issue
    # would hide real drift. Cleanup runs before the exit either way.
    mut=0
    # Ensure the marker label exists (idempotent). --force updates an existing
    # label rather than erroring, so a re-run never fails here.
    run gh label create "$LABEL" --color B60205 \
        --description "Nightly upstream fork-drift tracking (HIMMEL-1046)" --force || mut=1
    body_file="$(mktemp)"
    build_body "$body_file"
    if [ -n "$num" ]; then
      echo "fork-drift: refreshing existing issue #$num"
      run gh issue edit "$num" --body-file "$body_file" || mut=1
      run gh issue comment "$num" --body "Still drifting as of $(now)." || mut=1
    else
      echo "fork-drift: opening new consolidated drift issue"
      run gh issue create --title "$TITLE" --label "$LABEL" --body-file "$body_file" || mut=1
    fi
    rm -f "$body_file"
    if [ "$mut" -ne 0 ]; then
      echo "fork-drift: an issue mutation failed (see above) — failing so the drift is not silently green." >&2
      exit 1
    fi
    ;;
  0)
    # A failed lookup here means we can't verify/close a possibly-open drift
    # issue — propagate it (red) for consistency with the rc=2 path rather than
    # exiting green on an unverified reconciliation. The next run retries.
    if ! num="$(find_open_issue)"; then
      echo "fork-drift: all current, but could not query existing issues (gh lookup failed) — failing so the unresolved reconciliation is visible. Retries next run." >&2
      exit 1
    fi
    if [ -n "$num" ]; then
      echo "fork-drift: drift cleared — closing issue #$num"
      mut=0
      run gh issue comment "$num" --body "Drift cleared as of $(now) — all tracked upstreams current. Closing." || mut=1
      run gh issue close "$num" || mut=1
      if [ "$mut" -ne 0 ]; then
        echo "fork-drift: failed to close the drift issue (see above) — it will retry next run." >&2
        exit 1
      fi
    else
      echo "fork-drift: all current, no open drift issue — nothing to do."
    fi
    ;;
  3)
    # INCOMPLETE — a documented, benign steady state in CI (the probe/checkout
    # registry entries have no local install). Proved nothing about drift, so
    # leave issue state as-is and exit 0.
    echo "fork-drift: guard exit 3 (incomplete — expected in CI) — leaving issue state unchanged."
    ;;
  *)
    # Any OTHER code (1 usage error, 127 not-found, a crash) is NOT the guard's
    # documented 0/2/3 contract — the guard is broken. Fail (red) rather than
    # exit green, so a broken nightly is visible instead of silently passing.
    echo "fork-drift: guard exited $RC (unexpected — not the documented 0/2/3; crash/usage error?) — failing so a broken guard is not silently green." >&2
    exit 1
    ;;
esac
