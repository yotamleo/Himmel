#!/usr/bin/env bash
# job-started-hook.sh — the runner-side fork guard for the himmel-vm
# self-hosted runner (HIMMEL-5037). Installed in the guest image and wired as
# ACTIONS_RUNNER_HOOK_JOB_STARTED, so the runner runs it before the first step
# of EVERY job; a non-zero exit fails the job before any workflow code runs.
#
# Why a runner-side guard as well as the ci.yml `if:`: the repo is public, and
# a fork PR can propose a workflow that names `runs-on: himmel-vm` itself. The
# workflow-level guard lives in the very file such a PR edits; this one lives
# in the VM image, outside anything a PR can change.
#
# Allowed (everything else exits 1):
#   push              to refs/heads/main only
#   pull_request      whose head repo IS this repo (never a fork)
#   workflow_dispatch / schedule   (on ANY ref a writer pushed: accepted
#                     because only the repo owner has write; revisit if a
#                     collaborator is ever added)
# GITHUB_REPOSITORY must equal HIMMEL_CI_RUNNER_REPO (baked into the image).
set -u

deny() { echo "himmel-vm fork guard: REFUSED — $1" >&2; exit 1; }

want="${HIMMEL_CI_RUNNER_REPO:-}"
[ -n "$want" ] || deny "HIMMEL_CI_RUNNER_REPO is not set in the runner environment"
[ "${GITHUB_REPOSITORY:-}" = "$want" ] || deny "repository '${GITHUB_REPOSITORY:-}' is not '$want'"
[ -r "${GITHUB_EVENT_PATH:-}" ] || deny "no readable event payload at '${GITHUB_EVENT_PATH:-}'"

case "${GITHUB_EVENT_NAME:-}" in
    push)
        [ "${GITHUB_REF:-}" = "refs/heads/main" ] || deny "push to '${GITHUB_REF:-}', not refs/heads/main"
        ;;
    pull_request)
        head=$(python3 -c '
import json, sys
try:
    e = json.load(open(sys.argv[1]))
    print(e["pull_request"]["head"]["repo"]["full_name"])
except Exception:
    pass
' "$GITHUB_EVENT_PATH")
        [ "$head" = "$want" ] || deny "pull_request head repo '${head:-<none>}' is not '$want' (fork PRs run on hosted runners)"
        ;;
    workflow_dispatch|schedule) ;;
    *) deny "event '${GITHUB_EVENT_NAME:-}' is not routed to this runner" ;;
esac
echo "himmel-vm fork guard: allowed ${GITHUB_EVENT_NAME} on ${GITHUB_REPOSITORY} (${GITHUB_REF:-})"
