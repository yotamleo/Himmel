#!/usr/bin/env bash
# scripts/ci/queue-latency.sh — HIMMEL-3840
#
# One read-only line for the console tick: how saturated is GitHub Actions?
#   ci-queue: jobs_in_progress=N/20 macos=M/5 queued=Q oldest_wait=Xm
# Fails soft: any API error prints `ci-queue: unknown` and exits 0, so the
# tick is never blocked by it.
#
# Usage: queue-latency.sh [-R owner/repo]   (default: parsed from `origin`)
set -uo pipefail

# GitHub Free plan Actions limits (docs.github.com "Actions limits":
# 20 concurrent jobs, of which at most 5 macOS). ci-queue-saturated readers
# (tick.sh) compare jobs_in_progress against the first number printed here.
CI_MAX_JOBS=20
CI_MAX_MACOS=5
# Bound per-run API calls: in-progress runs are looked at first, so a storm of
# queued runs cannot starve the in-progress count.
# ponytail: runs past the cap are not counted, so a >40-run storm under-reports
# queued; raise the cap or switch to a jobs-level endpoint if that bites.
MAX_RUNS=40

unknown() { echo "ci-queue: unknown"; exit 0; }

REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    -R) [ $# -ge 2 ] || { echo "usage: queue-latency.sh [-R owner/repo]" >&2; exit 2; }
        REPO="$2"; shift 2 ;;
    *) echo "usage: queue-latency.sh [-R owner/repo]" >&2; exit 2 ;;
  esac
done
if [ -z "$REPO" ]; then
  url="$(git remote get-url origin 2>/dev/null)" || unknown
  REPO="$(printf '%s' "$url" | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#; s#\.git$##')"
fi
[ -n "$REPO" ] || unknown

# shellcheck source=../lib/timeout-bin.sh
. "$(dirname "$0")/../lib/timeout-bin.sh" 2>/dev/null
# GNU timeout (or gtimeout on macOS); no bound available = run unbounded.
gh_api() { ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" 15} gh api "$@" 2>/dev/null; }

RUNS_JQ='.workflow_runs[] | [.id, .status, (.created_at | fromdateiso8601)] | @tsv'
JOBS_JQ='[ ([.jobs[] | select(.status=="in_progress")] | length),
           ([.jobs[] | select(.status=="in_progress" and ((.labels // []) | join(",") | test("macos")))] | length),
           ([.jobs[] | select(.status=="queued")] | length),
           ([.jobs[] | select(.status=="queued") | .created_at | fromdateiso8601] | min // 0) ] | @tsv'

ip_runs="$(gh_api "repos/$REPO/actions/runs?status=in_progress&per_page=100" --jq "$RUNS_JQ")" || unknown
q_runs="$(gh_api "repos/$REPO/actions/runs?status=queued&per_page=100" --jq "$RUNS_JQ")" || unknown

# In-progress first, then queued; dedupe by id (a run can appear in both).
runs="$(printf '%s\n%s\n' "$ip_runs" "$q_runs" | awk 'NF && !seen[$1]++' | head -n "$MAX_RUNS")"

now="$(date +%s)"
ip=0; mac=0; q=0; oldest=0
while IFS=$'\t' read -r id status created; do
  [ -n "$id" ] || continue
  line="$(gh_api "repos/$REPO/actions/runs/$id/jobs?per_page=100" --jq "$JOBS_JQ")" || unknown
  IFS=$'\t' read -r jip jmac jq_ jold <<< "$line"
  ip=$((ip + jip)); mac=$((mac + jmac)); q=$((q + jq_))
  cand="$jold"
  # A queued run with no live jobs yet is still waiting; count it once.
  if [ "$status" = "queued" ] && [ $((jip + jq_)) -eq 0 ]; then
    q=$((q + 1)); cand="$created"
  fi
  if [ "${cand:-0}" -gt 0 ] && { [ "$oldest" -eq 0 ] || [ "$cand" -lt "$oldest" ]; }; then oldest="$cand"; fi
done <<< "$runs"

wait_min=0
[ "$oldest" -gt 0 ] && wait_min=$(( (now - oldest) / 60 ))
[ "$wait_min" -lt 0 ] && wait_min=0
echo "ci-queue: jobs_in_progress=$ip/$CI_MAX_JOBS macos=$mac/$CI_MAX_MACOS queued=$q oldest_wait=${wait_min}m"
