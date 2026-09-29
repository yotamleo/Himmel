#!/usr/bin/env bash
# scripts/ci/cancel-superseded-runs.sh — HIMMEL-3811
#
# Under runner backlog, superseded PR runs sit in workflow-level `queued` and
# the concurrency group does not cancel them; codeowner-review-gate (queue: max)
# and workflow_dispatch runs are never in that group at all. Each holds a slot
# of the account's 20-job cap. This cancels every live CI / codeowner-review-gate
# run on an open PR's branch whose headSha is not that PR's current headRefOid.
#
# Never touched: a run at the current head (HIMMEL-3588: a CANCELLED context on
# the current head blocks the rollup), a run on a branch with no open PR (main,
# schedule, anything whose PR head cannot be read), a completed run.
# Fails SAFE: every read happens before the first cancel, so any gh error or
# unparseable reply cancels nothing and exits 1. A cancel that itself fails is
# reported, the rest still go, and the exit is 1.
#
# Usage: cancel-superseded-runs.sh [--dry-run] [--branch <b>]
# One API call for the PR list + one per workflow; cancels are asynchronous
# (~20 s to take effect). Console-run only, not wired into any hook or workflow.
set -uo pipefail

WORKFLOWS="ci.yml codeowner-review-gate.yml"
# Newest runs first; a superseded run older than this window is not seen.
# ponytail: a >200-run backlog on one workflow hides its oldest runs, page the
# listing or filter by status server-side if that bites.
RUN_LIMIT=200

usage() { echo "usage: cancel-superseded-runs.sh [--dry-run] [--branch <b>]" >&2; exit 2; }

DRY=0; BRANCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --branch) [ $# -ge 2 ] || usage; BRANCH="$2"; shift 2 ;;
    *) usage ;;
  esac
done

die() { echo "cancel-superseded-runs: $*; nothing cancelled" >&2; exit 1; }

pr_args=(--state open --json "number,headRefName,headRefOid" --limit 200)
[ -n "$BRANCH" ] && pr_args+=(--head "$BRANCH")
prs="$(gh pr list "${pr_args[@]}")" || die "gh pr list failed"
printf '%s' "$prs" | jq -e 'type == "array"' >/dev/null 2>&1 || die "unparseable gh pr list output"

# Runs whose branch has an open PR, live, not a schedule run, at a head other
# than that PR's current one. Tab-separated: id, workflow, event, branch, sha, PR, PR head.
# shellcheck disable=SC2016 # $-names here are jq variables, not shell
PICK='
  ($prs | map({key: .headRefName, value: .}) | from_entries) as $by
  | .[]
  | select(.status | IN("queued", "pending", "in_progress", "waiting", "requested"))
  | select(.event != "schedule")
  | . as $r | $by[$r.headBranch] as $pr
  | select($pr != null and $r.headSha != $pr.headRefOid)
  | [$r.databaseId, $r.workflowName, $r.event, $r.headBranch, $r.headSha[0:8], $pr.number, $pr.headRefOid[0:8]]
  | @tsv'

picked=""
for wf in $WORKFLOWS; do
  runs="$(gh run list --workflow "$wf" --limit "$RUN_LIMIT" --json databaseId,status,event,headBranch,headSha,workflowName)" \
    || die "gh run list --workflow $wf failed"
  printf '%s' "$runs" | jq -e 'type == "array"' >/dev/null 2>&1 || die "unparseable gh run list output for $wf"
  lines="$(printf '%s' "$runs" | jq -r --argjson prs "$prs" "$PICK")" || die "jq filter failed for $wf"
  [ -n "$lines" ] && picked="$picked$lines"$'\n'
done

rc=0
while IFS=$'\t' read -r id wf event branch sha pr prhead; do
  [ -n "$id" ] || continue
  desc="$id $wf $event $branch@$sha (PR #$pr head $prhead)"
  if [ "$DRY" -eq 1 ]; then
    echo "would-cancel $desc"
  elif gh run cancel "$id" >/dev/null 2>&1; then
    echo "cancel $desc"
  else
    echo "cancel-failed $desc" >&2; rc=1
  fi
done <<< "$picked"
exit "$rc"
