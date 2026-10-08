#!/usr/bin/env bash
# scripts/ci/test-ci-pr-fail-fast.sh -- fail-fast policy of .github/workflows/ci.yml
# (HIMMEL-5036): the shell-unit-shard and bun-suites matrices stop at the first red
# leg on pull_request ONLY; push-to-main and the nightly keep every leg running so a
# red stays attributable. A PR with one red shard plus fail-fast-cancelled siblings
# must still read FAILED: the shell-unit aggregator's first step is executed here
# for each rollup value. Pure text + a local bash run of one extracted step; no network.
#
# Usage: bash scripts/ci/test-ci-pr-fail-fast.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_YML="${CI_YML:-$ROOT/.github/workflows/ci.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

PR_ONLY="\${{ github.event_name == 'pull_request' }}"

# The 'fail-fast:' value of a job's strategy block.
failfast_of() {
  awk -v job="$1" '
    /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/ { cur = $1; sub(/:$/, "", cur) }
    cur == job && /^      fail-fast:/ { sub(/^      fail-fast:[ ]*/, ""); sub(/[ ]+#.*$/, ""); print; exit }
  ' "$CI_YML"
}

for job in shell-unit-shard bun-suites; do
  v="$(failfast_of "$job")"
  if [ "$v" = "$PR_ONLY" ]; then ok "$job fail-fast is pull_request only"
  else bad "$job fail-fast is '${v:-<absent>}' (expected: $PR_ONLY)"; fi
done

# The aggregator's rollup step: extract its run: body and execute it per rollup value.
body="$(awk '
  /^  shell-unit:/ { j = 1; next }
  j && /^  [A-Za-z0-9_-]+:/ { j = 0 }
  j && /- name: Every gating shell-unit shard must have passed/ { s = 1; next }
  s && /^        run: \|/ { r = 1; next }
  s && r && /^          / { sub(/^          /, ""); print; next }
  s && r { exit }
' "$CI_YML")"

if [ -z "$body" ]; then
  bad "could not extract the shell-unit rollup step"
else
  for res in failure cancelled skipped; do
    SHARDS_RESULT="$res" bash -c "$body" >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 1 ]; then ok "rollup '$res' fails the aggregator"
    else bad "rollup '$res' exited $rc (expected 1, never green)"; fi
  done
  SHARDS_RESULT=success bash -c "$body" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then ok "rollup 'success' passes the aggregator"
  else bad "rollup 'success' exited $rc (expected 0)"; fi
fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
