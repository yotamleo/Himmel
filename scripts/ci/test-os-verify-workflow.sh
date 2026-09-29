#!/usr/bin/env bash
# scripts/ci/test-os-verify-workflow.sh -- static suite for HIMMEL-3839: the
# dispatch-only os-verify.yml that replaces ci.yml's force_all_os input.
# The workflow exists to verify impacted suites on ONE chosen OS on demand, so
# three properties must hold or it is worse than what it replaces:
#   1. it can only ever be DISPATCHED (a pull_request/push/schedule trigger
#      would put the paid macOS/Windows legs back on every PR);
#   2. every job name carries the `os-verify / ` prefix, so a dispatch on a PR
#      head can never post a check-run that satisfies (or shadows) one of the
#      required contexts by name -- the HIMMEL-3788 precedent;
#   3. a real failure fails the job (no continue-on-error).
# Pure text assertions over the workflow file plus mutation controls that prove
# each check can fail; no network.
#
# Usage: bash scripts/ci/test-os-verify-workflow.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="${OS_VERIFY_YML:-$ROOT/.github/workflows/os-verify.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

# The 24 required contexts on `main` (ruleset protect-main + classic branch
# protection carry the same list, read 2026-09-29 via
# `gh api repos/yotamleo/Himmel/branches/main/protection/required_status_checks`).
# ponytail: a frozen copy, so a context added later is not checked here;
# upgrade path is a live read once the check-ci.sh required_set is reusable.
REQUIRED_CONTEXTS='bun-suites (ubuntu-latest)
codeowner-review-gate
commit-lint
doc-invariants
guardrail-matrices
lanes-and-trust-suites
leak-classes
lint
node-suites (bitbucket)
node-suites (ci-orchestrator)
node-suites (himmel-run)
node-suites (jira)
secret-scan
security-scan
shell-unit-shard (ubuntu-latest, 1)
shell-unit-shard (ubuntu-latest, 2)
shell-unit-shard (ubuntu-latest, 3)
shell-unit-shard (ubuntu-latest, 4)
shell-unit-shard (ubuntu-latest, 5)
shell-unit-shard (ubuntu-latest, 6)
shell-unit-shard (ubuntu-latest, 7)
shell-unit-shard (ubuntu-latest, 8)
shell-unit (ubuntu-latest)
pr-title-lint'

# strip_comments <file> -- drop full-line and trailing ` # ...` comments so a
# comment can never satisfy (or trip) an assertion.
strip_comments() { sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]][[:space:]]*#.*$//' "$1"; }

# top_block <file> <key> -- the body of a column-0 `<key>:` block.
top_block() {
  strip_comments "$1" | awk -v k="$2" '$0 == k ":" {f=1; next} f && /^[^ ]/ {f=0} f'
}

# trigger_keys <file> -- the event names under `on:`.
trigger_keys() { top_block "$1" on | sed -n 's/^  \([a-z_]*\):.*$/\1/p'; }

# input_block <file> <input> -- the body of one workflow_dispatch input.
input_block() {
  top_block "$1" on | awk -v k="$2" '$0 == "      " k ":" {f=1; next} f && /^      [a-z_]+:/ {f=0} f'
}

# job_ids <file> -- the column-2 keys under `jobs:`.
job_ids() { top_block "$1" jobs | sed -n 's/^  \([A-Za-z0-9_-]*\):$/\1/p'; }

# job_block <file> <id> -- the body of one job.
job_block() {
  top_block "$1" jobs | awk -v k="$2" '$0 == "  " k ":" {f=1; next} f && /^  [A-Za-z0-9_-]+:$/ {f=0} f'
}

# check_dispatch_only <file> -- rc 0 iff workflow_dispatch is the only trigger.
check_dispatch_only() {
  [ "$(trigger_keys "$1")" = "workflow_dispatch" ]
}

# check_job_names <file> -- rc 0 iff every job declares a `os-verify / ` name.
check_job_names() {
  local ids id n=0
  ids="$(job_ids "$1")"
  [ -n "$ids" ] || return 1
  for id in $ids; do
    grep -q '^    name: os-verify / ' <<< "$(job_block "$1" "$id")" || return 1
    n=$((n + 1))
  done
  [ "$n" -gt 0 ]
}

# check_no_continue_on_error <file> -- rc 0 iff no job tolerates failure.
check_no_continue_on_error() {
  ! grep -q 'continue-on-error' <<< "$(strip_comments "$1")"
}

if [ -f "$WF" ]; then ok "os-verify.yml exists"
else bad "os-verify.yml does not exist at $WF"; echo "$fails failed" >&2; exit 1; fi

# --- 1. dispatch-only ------------------------------------------------------
if check_dispatch_only "$WF"; then ok "the only trigger is workflow_dispatch"
else bad "triggers are not workflow_dispatch alone: $(trigger_keys "$WF" | tr '\n' ' ')"; fi

# --- 2. inputs -------------------------------------------------------------
os_in="$(input_block "$WF" os)"
suites_in="$(input_block "$WF" suites)"
if grep -q 'type: choice' <<< "$os_in" && grep -q 'default: macos' <<< "$os_in" \
   && grep -q -- '- macos' <<< "$os_in" && grep -q -- '- windows' <<< "$os_in" \
   && grep -q -- '- both' <<< "$os_in"; then
  ok "input os is a choice of macos|windows|both, default macos"
else bad "input os is not a choice of macos|windows|both defaulting to macos"; fi
if grep -q 'type: choice' <<< "$suites_in" && grep -q 'default: impacted' <<< "$suites_in" \
   && grep -q -- '- impacted' <<< "$suites_in" && grep -q -- '- all' <<< "$suites_in"; then
  ok "input suites is a choice of impacted|all, default impacted"
else bad "input suites is not a choice of impacted|all defaulting to impacted"; fi

# --- 3. job-name prefix + no required-context collision ---------------------
if grep -q '^name: os-verify$' "$WF"; then
  ok "workflow name is os-verify"
else bad "workflow name is not exactly os-verify"; fi

if check_job_names "$WF"; then ok "every job name starts with 'os-verify / '"
else bad "a job has no name or a name without the 'os-verify / ' prefix"; fi

shards="$(strip_comments "$WF" | sed -n 's/^[[:space:]]*shard:[[:space:]]*\[\(.*\)\].*$/\1/p' | head -1 | tr -d ' ' | tr ',' ' ')"
collided=0
resolved=0
for id in $(job_ids "$WF"); do
  expr="$(job_block "$WF" "$id" | sed -n 's/^    name:[[:space:]]*//p')"
  for os in macos-latest windows-latest; do
    for sh in ${shards:-1}; do
      name="${expr//\$\{\{ matrix.os \}\}/$os}"
      name="${name//\$\{\{ matrix.shard \}\}/$sh}"
      # shellcheck disable=SC2016  # a literal GitHub expression opener, not a shell expansion
      case "$name" in
        *'${{'*) bad "job $id name has an expression the test cannot resolve: $expr"; continue ;;
      esac
      resolved=$((resolved + 1))
      if grep -qxF -- "$name" <<< "$REQUIRED_CONTEXTS"; then
        bad "job $id resolves to the required context name '$name'"; collided=1
      fi
    done
  done
done
if [ "$resolved" -gt 0 ] && [ "$collided" -eq 0 ]; then
  ok "no resolved job name ($resolved checked) equals a required context"
elif [ "$resolved" -eq 0 ]; then bad "no job name could be resolved"; fi

# --- 4. the run: impacted suites against origin/main's merge-base ------------
body="$(strip_comments "$WF")"
if grep -q 'git merge-base origin/main HEAD' <<< "$body"; then ok "range base is the merge-base with origin/main"
else bad "no 'git merge-base origin/main HEAD' range base"; fi
if grep -q 'run-shell-tests.sh --impacted' <<< "$body"; then ok "runs run-shell-tests.sh --impacted"
else bad "does not run run-shell-tests.sh --impacted"; fi
if grep -q 'fetch-depth: 0' <<< "$body"; then ok "full-depth checkout (the merge-base needs history)"
else bad "checkout is shallow: git merge-base origin/main HEAD cannot resolve"; fi

# --- 5. the shard count is spelled twice and must agree ----------------------
nshards=$(wc -w <<< "$shards")
# shellcheck disable=SC2016  # a literal GitHub expression, not a shell expansion
argn="$(grep -o -- '--shard \${{ matrix.shard }}/[0-9]*' <<< "$body" | sed 's|.*/||' | sort -u)"
if [ "$nshards" -gt 0 ] && [ "$(wc -l <<< "$argn")" -eq 1 ] && [ "$argn" = "$nshards" ]; then
  ok "matrix shard list ($nshards) matches the --shard /N argument"
else bad "matrix has $nshards shards but --shard args say '${argn:-none}'"; fi

# --- 6. failures are real ----------------------------------------------------
if check_no_continue_on_error "$WF"; then ok "no continue-on-error: a red suite fails the job"
else bad "continue-on-error present: a red suite would not fail the job"; fi

# --- 7. mutation controls: each check above must be able to fail --------------
tmp="$(mktemp -d "${TMPDIR:-/tmp}/os-verify-test.XXXXXX")" || { bad "mktemp failed"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

awk '{print} /^on:$/ {print "  pull_request:"}' "$WF" > "$tmp/pr.yml"
if check_dispatch_only "$tmp/pr.yml"; then bad "control: an added pull_request trigger was not detected"
else ok "control: an added pull_request trigger is detected"; fi

sed 's/^    name: os-verify \/ /    name: /' "$WF" > "$tmp/noprefix.yml"
if check_job_names "$tmp/noprefix.yml"; then bad "control: a dropped os-verify prefix was not detected"
else ok "control: a dropped os-verify prefix is detected"; fi

awk '/^    runs-on:/ {print "    continue-on-error: true"} {print}' "$WF" > "$tmp/coe.yml"
if check_no_continue_on_error "$tmp/coe.yml"; then bad "control: an added continue-on-error was not detected"
else ok "control: an added continue-on-error is detected"; fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
