#!/usr/bin/env bash
# scripts/ci/test-ci-job-timeouts.sh -- every job in .github/workflows/ci.yml
# carries an explicit job-level `timeout-minutes:` (HIMMEL-5036).
#
# Without one a job inherits GitHub's 360-minute default, so a hung job holds a
# runner slot for six hours. Note timeout-minutes counts from job START: Actions
# cannot cap QUEUED time. Pure text assertion (job keys are the 2-space-indented
# keys under `jobs:`, the timeout is a 4-space-indented key of the same job; a
# step-level timeout does not count). No network, no PyYAML.
#
# Usage: bash scripts/ci/test-ci-job-timeouts.sh
# Exit codes: 0 -- all jobs have a timeout; 1 -- at least one lacks one.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_YML="${CI_YML:-$ROOT/.github/workflows/ci.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

# One "<job> <yes|no>" line per job.
report="$(awk '
  function flush() { if (job != "") print job, (has ? "yes" : "no") }
  /^jobs:/ { in_jobs = 1; next }
  in_jobs && /^[^ #]/ { flush(); job = ""; in_jobs = 0 }
  in_jobs && /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/ { flush(); job = $1; sub(/:$/, "", job); has = 0; next }
  in_jobs && job != "" && /^    timeout-minutes:[ ]*[^ #]/ { has = 1 }
  END { flush() }
' "$CI_YML")"

if [ -z "$report" ]; then
  bad "no jobs found in $CI_YML (parse failure)"
else
  njobs=0
  while read -r job has; do
    njobs=$((njobs + 1))
    if [ "$has" = "yes" ]; then ok "job $job has timeout-minutes"
    else bad "job $job has no job-level timeout-minutes (defaults to 360)"; fi
  done <<< "$report"
  echo "checked $njobs job(s)"
fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
