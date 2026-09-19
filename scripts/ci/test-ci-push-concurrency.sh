#!/usr/bin/env bash
# scripts/ci/test-ci-push-concurrency.sh -- HIMMEL-3217 regression suite for the
# top-level `concurrency:` block of .github/workflows/ci.yml.
#
# A newer push to main must cancel the superseded push-to-main run (they piled
# the Actions queue up to 5+ on 2026-09-19), but a PR, schedule or dispatch run
# must never be cancelled by -- or queue behind -- another run. Pure text
# assertions over the workflow file: no yq/python dependency, no network.
#
# Usage: bash scripts/ci/test-ci-push-concurrency.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_YML="${CI_YML:-$ROOT/.github/workflows/ci.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

# The workflow-level block: a column-0 `concurrency:` up to the next column-0 key.
# (The bun-suites job's concurrency is indented, so column 0 is unambiguous.)
block="$(awk '/^concurrency:/ {f=1; print; next} f && /^[^ #]/ {f=0} f' "$CI_YML")"

if [ -n "$block" ]; then ok "ci.yml has a workflow-level concurrency: block"
else bad "ci.yml has no workflow-level concurrency: block"; fi

group="$(sed -n 's/^  group:[[:space:]]*//p' <<< "$block")"
cancel="$(sed -n 's/^  cancel-in-progress:[[:space:]]*//p' <<< "$block")"

# Push runs share one group per ref (so a newer main push meets the older run)...
case "$group" in
  *"github.event_name == 'push' && github.ref"*) ok "push runs are grouped by github.ref" ;;
  *) bad "push runs are not grouped by github.ref; group='$group'" ;;
esac
# ...and every other event gets a unique group, so nothing else ever queues or
# cancels (a shared PR group would cancel a leg's earlier push run).
case "$group" in
  *"|| github.run_id"*) ok "non-push runs fall back to a unique group (run_id)" ;;
  *) bad "non-push runs do not get a unique group; group='$group'" ;;
esac
# cancel-in-progress is push-only: a bare `true` would cancel PR runs too if the
# group were ever widened.
if [ "$cancel" = "\${{ github.event_name == 'push' }}" ]; then
  ok "cancel-in-progress is scoped to push events"
else
  bad "cancel-in-progress is not scoped to push events; got '$cancel'"
fi

# The group key includes github.ref, so branches stay isolated from each other
# even if the trigger widens; but widening it would make every branch push start
# cancelling its own predecessor, so the comments/docs claim "push means main"
# only holds while the trigger stays restricted to main.
push_branches="$(awk '/^  push:/ {f=1; next} f && /branches:/ {print; exit} f && /^  [a-z_]+:/ {exit}' "$CI_YML")"
if [ "${push_branches#*'branches: [main]'}" != "$push_branches" ]; then
  ok "push trigger is restricted to branches: [main]"
else
  bad "push trigger is not restricted to branches: [main]"
fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
