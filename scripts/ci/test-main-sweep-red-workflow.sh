#!/usr/bin/env bash
# scripts/ci/test-main-sweep-red-workflow.sh -- shape guard for
# .github/workflows/main-sweep-red.yml (HIMMEL-3841 slice E): the reporter that
# runs scripts/ci/main-sweep-red-issue.sh after each completed main CI sweep
# (cron / dispatch since HIMMEL-5113). Text assertions over the workflow with
# comments stripped; no network.
#
# It pins the properties that make the reporter safe: it triggers only on a
# completed CI run on main, only reports schedule / dispatch events, holds issues: write
# without any write to code, checks out the default branch (never the swept
# sha), serialises without cancelling, and runs the script with the run id.
#
# ponytail: line-oriented text checks, not a YAML parse (a reformatted-but-equal
# file would fail loudly rather than pass silently), upgrade to a real parser if
# the repo ever vendors one for workflows (HIMMEL-3841).
#
# Usage: bash scripts/ci/test-main-sweep-red-workflow.sh
# Env:   MAIN_SWEEP_RED_YML  workflow under test (default: the tracked file).
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="${MAIN_SWEEP_RED_YML:-$ROOT/.github/workflows/main-sweep-red.yml}"
CI_YML="$ROOT/.github/workflows/ci.yml"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

if [ ! -f "$WF" ]; then
  bad "workflow file missing: $WF"
  echo "$fails check(s) failed." >&2
  exit 1
fi

s="$(sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]][[:space:]]*#.*$//' "$WF")"
has() { grep -Eq -- "$1" <<< "$s"; }

# The trigger names ci.yml's workflow by its actual `name:`.
ci_name="$(sed -n 's/^name:[[:space:]]*//p' "$CI_YML" | head -n 1)"
if has "^[[:space:]]+workflows: \[$ci_name\]"; then
  ok "triggers on workflow_run of '$ci_name' (ci.yml's own name)"
else
  bad "workflow_run must name ci.yml's workflow '$ci_name'"
fi
if has '^[[:space:]]+types: \[completed\]'; then ok "fires on completed runs only"; else bad "types must be [completed]"; fi
if has '^[[:space:]]+branches: \[main\]'; then ok "limited to runs on main"; else bad "branches must be [main]"; fi

# Only the cron / dispatch sweep is main's health (HIMMEL-5113: no push run).
if has "github.event.workflow_run.event == 'schedule'" \
   && has "github.event.workflow_run.event == 'workflow_dispatch'" \
   && ! has "workflow_run.event == 'push'" \
   && ! has "workflow_run.event == 'pull_request'"; then
  ok "job is gated to the schedule and workflow_dispatch events"
else
  bad "job must be gated on workflow_run.event schedule / workflow_dispatch only"
fi

# Least privilege: issues:write to file the issue, read-only everything else.
perms="$(awk '/^permissions:/ {f=1; next} f && /^[a-z]/ {f=0} f' <<< "$s")"
if grep -Eq 'issues: write' <<< "$perms" && grep -Eq 'contents: read' <<< "$perms" \
   && grep -Eq 'actions: read' <<< "$perms" \
   && ! grep -Eq '(contents|pull-requests|actions|checks|statuses|packages): write' <<< "$perms"; then
  ok "permissions: issues write, contents/actions read, no other write"
else
  bad "permissions must be exactly issues:write + contents:read + actions:read"
fi

# The checkout is the default branch: no `ref:` and no swept-sha checkout.
if has '^[[:space:]]+ref:' || has 'workflow_run\.head_(sha|branch)'; then
  bad "checkout must not pin the swept commit (default-branch code holds issues: write)"
else
  ok "checkout is the default branch, not the swept commit"
fi

# Serialised, never cancelled.
if has '^[[:space:]]+group: main-sweep-red$' && has '^[[:space:]]+cancel-in-progress: false$'; then
  ok "concurrency: one main-sweep-red group, cancel-in-progress false"
else
  bad "concurrency must be group main-sweep-red with cancel-in-progress false"
fi

# The script is run with the swept run's id.
if has 'bash scripts/ci/main-sweep-red-issue\.sh "\$\{\{ github\.event\.workflow_run\.id \}\}"'; then
  ok "runs main-sweep-red-issue.sh with the swept run id"
else
  bad "must run scripts/ci/main-sweep-red-issue.sh with workflow_run.id"
fi
if has 'GH_TOKEN: \$\{\{ github\.token \}\}'; then ok "authenticates gh with the workflow token"; else bad "GH_TOKEN must be github.token"; fi

# It must not add a required context to any PR: no pull_request trigger.
if has '^[[:space:]]+pull_request(_target)?:'; then
  bad "reporter must not trigger on pull_request (it would add a PR context)"
else
  ok "no pull_request trigger"
fi

# RED control: the checks above must FAIL on a workflow that breaks the rules
# (cancelling, wrong event, extra write permission, PR trigger). Without this a
# broken has() would pass vacuously. SELF_CONTROL stops the recursion.
if [ -z "${SELF_CONTROL:-}" ]; then
  mut="$(mktemp "${TMPDIR:-/tmp}/main-sweep-red-mut.XXXXXX")"
  sed -e 's/cancel-in-progress: false/cancel-in-progress: true/' \
      -e "s/== 'schedule'/== 'pull_request'/" \
      -e 's/^  issues: write/  issues: write\n  contents: write/' \
      -e 's/^on:/on:\n  pull_request:/' "$WF" > "$mut"
  if SELF_CONTROL=1 MAIN_SWEEP_RED_YML="$mut" bash "$0" > /dev/null 2>&1; then
    bad "control: a mutated workflow (cancelling, wrong event, contents:write, PR trigger) passed"
  else
    ok "control: the same checks fail on a mutated workflow"
  fi
  rm -f "$mut"
fi

if [ "$fails" -gt 0 ]; then
  echo "$fails check(s) failed." >&2
  exit 1
fi
echo "all passed"
