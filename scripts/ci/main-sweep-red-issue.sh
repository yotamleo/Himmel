#!/usr/bin/env bash
# scripts/ci/main-sweep-red-issue.sh -- maintain ONE `main-red` issue for the
# push-to-main CI sweep (HIMMEL-3841 slice E, spec HIMMEL-3815 section 6.1 B).
#
# ci.yml's push-to-main runs share one queued (never cancelled) concurrency
# group, so each COMPLETED sweep tests the tip at its start and completed sweeps
# cover contiguous ranges of merges. main-sweep-red.yml runs this once per
# completed sweep with the run id. A red job means "a green merge produced a red
# main" (CI red triage policy: fix main); the issue names the tested sha and the
# range since the last green sweep so the owning leg can be found by bisect.
#
#   any job failed  -> open the issue if absent, else refresh its body and add a
#                      "still red" comment. The failed set recorded in the body
#                      is (previous set minus jobs that passed now) plus the jobs
#                      that failed now.
#   no job failed   -> close the issue ONLY when it records a failed set and every
#                      recorded job ran and PASSED in this sweep. A job that was
#                      skipped, cancelled or absent proves nothing, so the issue
#                      stays open (never a false close). An issue with no recorded
#                      set (opened by hand) is never auto-closed.
#   run has 0 jobs  -> a superseded pending run (cancelled before any job
#                      started): no-op.
#
# Job identity: the job's name as the Jobs API reports it. The individual
# `shell-unit-shard (...)` jobs are dropped -- the fail-closed `shell-unit (...)`
# aggregator stands for them, and it only passes once EVERY shard passed, so
# shard membership shifting between sweeps cannot fake a clear. This script's
# own reporter job (`main-sweep-*`) is dropped too.
#
# Usage:  main-sweep-red-issue.sh <ci-run-id>
# Env:
#   GITHUB_REPOSITORY   owner/repo (required) -- set by Actions.
#   GH_TOKEN            gh auth (issues:write, actions:read) -- supplied by the workflow.
#   MAIN_RED_ISSUE_LABEL  marker label (default: main-red).
set -uo pipefail

RUN_ID="${1:-}"
REPO="${GITHUB_REPOSITORY:-}"
LABEL="${MAIN_RED_ISSUE_LABEL:-main-red}"
TITLE="main is red: the push-to-main CI sweep is failing (main-red)"
MAX_RANGE=40

case "$RUN_ID" in
  ''|*[!0-9]*) echo "usage: main-sweep-red-issue.sh <ci-run-id>  (GITHUB_REPOSITORY=owner/repo)" >&2; exit 2 ;;
esac
if [ -z "$REPO" ]; then
  echo "main-sweep-red-issue: GITHUB_REPOSITORY is unset" >&2
  exit 2
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/main-sweep-red.XXXXXX")" || { echo "main-sweep-red-issue: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

tab="$(printf '\t')"

# --- the swept run --------------------------------------------------------
if ! run_line="$(gh api "repos/$REPO/actions/runs/$RUN_ID" \
    --jq '"\(.head_sha) \(.conclusion // "none") \(.html_url)"')"; then
  echo "main-sweep-red-issue: could not read run $RUN_ID (gh api failed)" >&2
  exit 1
fi
SHA="${run_line%% *}"; rest="${run_line#* }"
RUN_CONCLUSION="${rest%% *}"; RUN_URL="${rest#* }"

# A cancelled sweep (an operator cancel) says nothing about main's health: the
# shell-unit aggregator runs under if: always() and fails on a cancelled rollup,
# so its job conclusion would read as a red. Touch no issue.
if [ "$RUN_CONCLUSION" = "cancelled" ]; then
  echo "main-sweep-red-issue: run $RUN_ID was cancelled -- not a verdict on main; nothing to report."
  exit 0
fi

if ! gh api "repos/$REPO/actions/runs/$RUN_ID/jobs?per_page=100" --paginate \
    --jq '.jobs[] | "\(.conclusion // "none")\t\(.name)"' > "$TMP/jobs"; then
  echo "main-sweep-red-issue: could not read the jobs of run $RUN_ID (gh api failed)" >&2
  exit 1
fi

: > "$TMP/failed"; : > "$TMP/passed"
n_jobs=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  concl="${line%%"$tab"*}"; name="${line#*"$tab"}"
  case "$name" in
    "shell-unit-shard"*|"main-sweep"*) continue ;;
  esac
  n_jobs=$((n_jobs + 1))
  case "$concl" in
    failure|timed_out) printf '%s\n' "$name" >> "$TMP/failed" ;;
    success)           printf '%s\n' "$name" >> "$TMP/passed" ;;
  esac
done < "$TMP/jobs"

if [ "$n_jobs" -eq 0 ]; then
  echo "main-sweep-red-issue: run $RUN_ID has no jobs (conclusion=$RUN_CONCLUSION) -- a superseded pending sweep; nothing to report."
  exit 0
fi

# --- the open issue (a failed lookup is never "no issue") ------------------
if ! num="$(gh issue list --label "$LABEL" --state open --limit 1 \
    --json number --jq '.[0].number // empty' 2>/dev/null)"; then
  echo "main-sweep-red-issue: could not query existing issues (gh lookup failed) -- not creating/closing, to avoid a duplicate or a blind close. Retrying next sweep." >&2
  exit 1
fi

: > "$TMP/recorded"
if [ -n "$num" ]; then
  if ! body="$(gh issue view "$num" --json body --jq .body 2>/dev/null)"; then
    echo "main-sweep-red-issue: could not read issue #$num (gh failed) -- leaving it untouched." >&2
    exit 1
  fi
  printf '%s\n' "$body" | sed -n 's/^<!-- main-red-failed: \(.*\) -->[[:space:]]*$/\1/p' > "$TMP/recorded"
fi

# new set = (recorded minus passed-now) plus failed-now, one name per line.
{ grep -Fxv -f "$TMP/passed" "$TMP/recorded" 2>/dev/null; cat "$TMP/failed"; } | sort -u > "$TMP/newset"
# grep -f with an empty pattern file matches nothing (so -v keeps everything);
# an EMPTY passed file must not drop the recorded set.
[ -s "$TMP/passed" ] || { { cat "$TMP/recorded"; cat "$TMP/failed"; } | sort -u > "$TMP/newset"; }

now() { date -u +'%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "unknown-time"; }

# --- the range since the last green sweep ----------------------------------
range_text() {
  local green
  green="$(gh api "repos/$REPO/actions/workflows/ci.yml/runs?branch=main&event=push&status=success&per_page=5" \
    --jq "[.workflow_runs[] | select(.id < $RUN_ID)] | .[0].head_sha // empty" 2>/dev/null)" || green=""
  if [ -z "$green" ]; then
    echo "- since last green: unknown (no earlier green push sweep was found)"
    return
  fi
  echo "- since last green: $green"
  echo "- compare: https://github.com/$REPO/compare/$green...$SHA"
  local commits
  commits="$(gh api "repos/$REPO/compare/$green...$SHA" \
    --jq '.commits[] | "\(.sha[0:9]) \(.commit.message | split("\n")[0])"' 2>/dev/null | head -n "$MAX_RANGE")" || commits=""
  if [ -n "$commits" ]; then
    echo "- commits in the range (first $MAX_RANGE):"
    while IFS= read -r c; do echo "  - $c"; done <<< "$commits"
  else
    echo "- commit listing unavailable -- use the compare link"
  fi
}

# --- red: open or refresh ---------------------------------------------------
if [ -s "$TMP/failed" ]; then
  body_file="$TMP/body.md"
  {
    echo "**Automated main-red report** -- maintained in place by main-sweep-red.yml. Do not open duplicates; this issue is refreshed each completed push-to-main sweep and is closed automatically only after a later sweep runs and passes every job listed below."
    echo ""
    echo "Policy (CI red triage): a green merge followed by a red main means **fix main**. Find the owning PR from the range below and bisect by the failed jobs."
    echo ""
    echo "- tested sha: $SHA"
    echo "- sweep: $RUN_URL"
    echo "- last red sweep: $(now)"
    range_text
    echo ""
    echo "Failed jobs (still unresolved):"
    while IFS= read -r n; do echo "- failed: $n"; done < "$TMP/newset"
    echo ""
    while IFS= read -r n; do echo "<!-- main-red-failed: $n -->"; done < "$TMP/newset"
  } > "$body_file"
  # Echo what is filed so the run log (and the test) carries it.
  cat "$body_file"

  mut=0
  if [ -n "$num" ]; then
    echo "main-sweep-red-issue: refreshing existing issue #$num"
    gh issue edit "$num" --body-file "$body_file" || mut=1
    gh issue comment "$num" --body "Still red as of $(now) at $SHA: $RUN_URL" || mut=1
  else
    echo "main-sweep-red-issue: opening the main-red issue"
    gh label create "$LABEL" --color B60205 \
      --description "The push-to-main CI sweep is red (auto-maintained)" --force || mut=1
    gh issue create --title "$TITLE" --label "$LABEL" --body-file "$body_file" || mut=1
  fi
  if [ "$mut" -ne 0 ]; then
    echo "main-sweep-red-issue: an issue mutation failed (see above) -- failing so the red sweep is not silently green." >&2
    exit 1
  fi
  exit 0
fi

# --- no job failed -----------------------------------------------------------
if [ -z "$num" ]; then
  echo "main-sweep-red-issue: no failed job, no open $LABEL issue -- nothing to do."
  exit 0
fi

if [ ! -s "$TMP/recorded" ]; then
  echo "main-sweep-red-issue: #$num records no failed set (not opened by this script) -- leaving it open for a human to close."
  exit 0
fi

if [ ! -s "$TMP/newset" ]; then
  echo "main-sweep-red-issue: every recorded failed job ran and passed -- closing #$num"
  mut=0
  gh issue comment "$num" --body "Green as of $(now) at $SHA: every job that was red ran and passed in $RUN_URL. Closing." || mut=1
  gh issue close "$num" || mut=1
  if [ "$mut" -ne 0 ]; then
    echo "main-sweep-red-issue: failed to close #$num (see above) -- retries next sweep." >&2
    exit 1
  fi
  exit 0
fi

# Green, but some recorded job did not run (skipped / cancelled / absent): a
# green sweep that never ran the failed job does not clear it.
echo "main-sweep-red-issue: no job failed, but these recorded jobs did not run and pass in $RUN_ID -- keeping #$num open:"
sed 's/^/  not re-run: /' "$TMP/newset"
gh issue comment "$num" --body "Sweep $RUN_URL at $SHA had no failed job, but it did not run and pass: $(tr '\n' ',' < "$TMP/newset" | sed 's/,$//'). Keeping this open until a sweep runs them green." || {
  echo "main-sweep-red-issue: comment failed (see above)" >&2
  exit 1
}
exit 0
